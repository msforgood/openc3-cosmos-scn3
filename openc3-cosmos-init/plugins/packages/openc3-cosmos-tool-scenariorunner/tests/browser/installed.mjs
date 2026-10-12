// Explicitly authorized isolated integration only. Never use the original port 2900.
import { chromium, expect } from '@playwright/test'
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'

if (process.env.SCENARIO_INSTALLED_CONFIRM !== 'isolated-32900') throw new Error('This test is restricted to the approved isolated32900 project.')
const origin = 'http://localhost:32900'
const browser = await chromium.launch({ channel: 'chrome', headless: true })
const context = await browser.newContext({ viewport: { width: 1680, height: 1180 } })
const page = await context.newPage()
const errors = [], checks = []
let loginErrors = []
page.on('pageerror', (error) => errors.push(error.message))
await page.route('**/*', (route) => {
  if (new URL(route.request().url()).origin !== origin) return route.abort('blockedbyclient')
  return route.continue()
})
try {
  await page.goto(`${origin}/tools/scenariorunner`, { waitUntil: 'domcontentloaded' })
  const passwordInput = page.locator('input[type="password"]')
  await expect(passwordInput.or(page.locator('[data-test="target-select"]'))).toBeVisible({ timeout: 45000 })
  if (await passwordInput.isVisible()) {
    const passwordFile = process.env.SCENARIO_VALIDATION_PASSWORD_FILE
    if (!passwordFile) throw new Error('Set SCENARIO_VALIDATION_PASSWORD_FILE to the private isolated-environment credential file.')
    const password = (await readFile(resolve(passwordFile), 'utf8')).trim()
    try { await passwordInput.fill(password) } catch { throw new Error('Unable to enter the isolated login credential.') }
    await page.getByRole('button', { name: 'Login', exact: true }).click()
  }
  await expect(page.locator('[data-test="target-select"]')).toBeVisible({ timeout: 45000 })
  loginErrors = errors.splice(0)
  if (process.argv.includes('--inspect')) {
    console.log(JSON.stringify({ title: await page.title(), targetOptions: await page.locator('[data-test="target-select"] option').allTextContents(), scenarioOptions: await page.locator('[data-test="scenario-select"] option').allTextContents(), status: await page.locator('[data-test="run-status"]').textContent(), errors }, null, 2))
  } else {
    const labels = ['01. CS 1바이트 CRC 키 복원', '02. TC 로그 사진 경로 변경', '03. MM 포인터 변경']
    await expect(page.locator('#openc3-nav-drawer')).toContainText('Scenario Runner')
    await expect(page.locator('[data-test="target-select"]')).toHaveValue('CFS-1_QEMU', { timeout: 20000 })
    await expect(page.locator('[data-test="target-select"] option')).toHaveText(['설치된 대상을 선택하세요', 'CFS-1_QEMU', 'CFS-1_BBB'])
    checks.push('only CFS-1_QEMU and CFS-1_BBB appear in the target menu')

    const entries = [
      ['cs-crc-key-oracle', 'CS_CMD_ONE_SHOT'],
      ['tc-log-photo-traversal', 'TC_CAMERA_CAPTURE_CMD'],
      ['psp-mm-indirect-write', 'MM_CMD_DEBUG_WRITE'],
    ]
    for (const target of ['CFS-1_QEMU', 'CFS-1_BBB']) {
      await page.locator('[data-test="target-select"]').selectOption(target)
      await expect(page.locator('[data-test="scenario-select"] option')).toHaveText(labels)
      for (const [id, packet] of entries) {
        await page.locator('[data-test="scenario-select"]').selectOption(id)
        await expect(page.locator('[data-test="start"]')).toBeEnabled()
        await expect(page.locator('[data-test="steps"]')).toContainText(packet)
        await expect(page.locator('[data-test="steps"] button').first()).toHaveText('Run step')
      }
      checks.push(`${target} displays CS, TC log, and MM scenarios in 01/02/03 order with planned TC`)
    }

    await mkdir('evidence', { recursive: true })
    await page.screenshot({ path: 'evidence/installed-desktop.png', fullPage: true })
    const result = { passed: true, origin, targets: ['CFS-1_QEMU', 'CFS-1_BBB'], checks, loginPageErrors: loginErrors, authenticatedPageErrors: errors }
    if (errors.length) throw new Error('Unexpected installed page errors (see local debug log without credentials)')
    await writeFile('evidence/installed-result.json', JSON.stringify(result, null, 2))
    console.log(JSON.stringify(result, null, 2))
  }
} finally { await browser.close() }

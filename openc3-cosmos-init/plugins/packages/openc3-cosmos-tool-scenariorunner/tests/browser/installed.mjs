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
    await expect(page.locator('[data-test="target-select"]')).toHaveValue('CFS-1_QEMU', { timeout: 20000 })
    await expect(page.locator('#openc3-nav-drawer')).toContainText('Scenario Runner')
    await expect(page.locator('#openc3-nav-drawer')).toContainText('Command Sender')
    await expect(page.locator('#openc3-nav-drawer')).toContainText('Limits Monitor')
    await expect(page.locator('[data-test="target-select"] option')).toHaveCount(2)
    await expect(page.locator('[data-test="scenario-select"] option')).toHaveCount(2)
    await expect(page.locator('[data-test="start"]')).toBeEnabled({ timeout: 15000 })
    checks.push('actual installed menu includes Scenario Runner alongside existing tools; runtime intersection contains only CFS-1_QEMU and two fixed scenarios')
    await page.locator('[data-test="scenario-select"]').selectOption('qemu-es-housekeeping')
    await expect(page.locator('[data-test="screen-select"]')).toHaveValue('CFE_ES_HK_TLM_SCREEN')
    await expect(page.locator('.screen-item')).toContainText('cFE ES Housekeeping', { timeout: 15000 })
    await expect(page.locator('[data-test="communication"]')).toHaveText('Live telemetry', { timeout: 20000 })
    const value = page.locator('.screen-item [data-test="value"] input').first()
    await expect(value).toHaveValue(/^\d+$/, { timeout: 10000 })
    await value.click({ button: 'right' })
    await expect(page.getByText('Details', { exact: true })).not.toBeVisible()
    await value.press('Shift+F10')
    await expect(page.getByText('Details', { exact: true })).not.toBeVisible()
    checks.push('actual CFS ES HK renders live packet values; mouse/keyboard Details limits entry is blocked')
    await page.locator('[data-test="scenario-select"]').selectOption('qemu-evs-housekeeping')
    await expect(page.locator('[data-test="screen-select"]')).toHaveValue('CFE_EVS_HK_TLM_SCREEN')
    await expect(page.locator('.screen-item')).toContainText('cFE EVS Housekeeping', { timeout: 15000 })
    await expect(page.locator('[data-test="communication"]')).toHaveText('Live telemetry', { timeout: 20000 })
    checks.push('scenario selection automatically opens actual EVS HK screen with live telemetry')
    await page.locator('[data-test="scenario-select"]').selectOption('qemu-es-housekeeping')
    await expect(page.locator('[data-test="start"]')).toBeEnabled()
    const resumeId = process.argv.find((arg) => arg.startsWith('--resume='))?.slice(9)
    let started
    if (resumeId) {
      started = await page.evaluate(async (id) => {
        const response = await fetch(`/scenario-api/runs/${encodeURIComponent(id)}?scope=DEFAULT`, { headers: { Authorization: localStorage.openc3Token } })
        if (!response.ok) throw Error(`Read-only run recovery HTTP ${response.status}`)
        const run = await response.json()
        localStorage.setItem('openc3.scenariorunner.v1.DEFAULT.run.CFS-1_QEMU', JSON.stringify({ runId: run.id }))
        return run
      }, resumeId)
      await page.reload()
    } else {
      const startResponse = page.waitForResponse((response) => new URL(response.url()).origin === origin && new URL(response.url()).pathname === '/scenario-api/runs' && response.request().method() === 'POST')
      await page.locator('[data-test="start"]').click()
      const response = await startResponse
      if (![200, 201, 202].includes(response.status())) throw new Error(`Start rejected: HTTP ${response.status()}`)
      started = await response.json()
    }
    if (started.target !== 'CFS-1_QEMU') throw new Error('Unexpected target in accepted run')
    await expect(page.locator('[data-test="run-status"]')).toHaveText('Succeeded', { timeout: 60000 })
    await expect(page.locator('label[for="run-progress"]')).toHaveText('2 / 2 steps complete', { timeout: 5000 })
    await expect(page.getByText('Command accepted', { exact: true })).toBeVisible()
    await expect(page.getByText('Telemetry confirmed', { exact: false })).toBeVisible()
    checks.push('one actual fixed QEMU ES housekeeping run launched through UI and succeeded with two steps and fresh telemetry confirmation')
    await page.locator('[data-test="scenario-select"]').selectOption('qemu-evs-housekeeping')
    await expect(page.locator('label[for="run-progress"]')).toHaveText('0 / 3 steps complete')
    await expect(page.locator('[data-test="run-status"]')).toHaveText('Ready')
    await expect(page.getByText('Command accepted', { exact: true })).not.toBeVisible()
    checks.push('actual completed ES evidence is not reused by EVS preview')
    await page.locator('[data-test="scenario-select"]').selectOption('qemu-es-housekeeping')
    await expect(page.locator('.screen-item [data-test="value"] input').first()).toHaveValue(/^\d+$/, { timeout: 15000 })
    const apiCounter = await page.evaluate(async () => {
      const response = await fetch('/openc3-api/api', { method: 'POST', headers: { Authorization: localStorage.openc3Token, 'Content-Type': 'application/json-rpc' }, body: JSON.stringify({ jsonrpc: '2.0', id: 9001, method: 'get_tlm_values', params: [['CFS-1_QEMU__CFE_ES_HK__COMMAND_COUNTER__RAW']], keyword_params: { scope: 'DEFAULT', stale_time: 10, cache_timeout: 0 } }) })
      const result = await response.json()
      return result.result[0][0]
    })
    await expect(page.locator('.screen-item [data-test="value"] input').first()).toHaveValue(String(apiCounter))
    checks.push('actual rendered numeric COMMAND_COUNTER equals read-only OpenC3 get_tlm_values result after final screen switch')
    await mkdir('evidence', { recursive: true })
    await page.screenshot({ path: 'evidence/installed-desktop.png', fullPage: true })
    const result = { passed: true, origin, target: started.target, runId: started.id, scenario: started.scenario_id, recoveryOnly: Boolean(resumeId), displayedCounter: String(apiCounter), checks, loginPageErrors: loginErrors, authenticatedPageErrors: errors }
    if (errors.length) throw new Error('Unexpected installed page errors (see local debug log without credentials)')
    await writeFile('evidence/installed-result.json', JSON.stringify(result, null, 2))
    console.log(JSON.stringify(result, null, 2))
  }
} finally { await browser.close() }

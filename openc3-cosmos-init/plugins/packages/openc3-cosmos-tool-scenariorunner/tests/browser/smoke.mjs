import { chromium, expect } from '@playwright/test'
import { createServer } from 'vite'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'

// Loopback-only fixture: no connection to the user's OpenC3 deployment.
const server = await createServer({ server: { host: '127.0.0.1', port: 2931, strictPort: true } })
await server.listen()
let browser
const errors = [], checks = [], requests = []
const bundle = process.env.SCENARIO_BUNDLE === '1'
const evidenceDir = process.env.SCENARIO_EVIDENCE_DIR || 'evidence'
try {
  browser = await chromium.launch({ channel: process.env.SCENARIO_BROWSER_CHANNEL || 'chrome', headless: true })
  const page = await browser.newPage({ viewport: { width: 1600, height: 1120 } })
  page.on('pageerror', (error) => errors.push(error.message))
  let receipt = Date.now() / 1000, frozenReceipt = false, run = null, starts = 0, ws
  const fixtureLimits = { red_low: -10, yellow_low: -3, yellow_high: 30, red_high: 50 }
  const itemMetadata = [
    { name: 'COMMAND_COUNTER', description: 'Command counter', limits: {} },
    { name: 'BUS_VOLTAGE', description: 'Synthetic fixture voltage', units: 'V', limits: { enabled: true, DEFAULT: fixtureLimits } },
    { name: 'OPERATING_MODE', limits: { enabled: true }, states: { SAFE: { value: 1, color: 'RED' } } },
    { name: 'DISABLED', limits: { enabled: false, DEFAULT: fixtureLimits } },
    { name: 'MISSING', limits: { enabled: true, DEFAULT: fixtureLimits } },
    { name: 'OVERFLOW', limits: { enabled: true, DEFAULT: fixtureLimits } },
  ]
  const scenario = { schemaVersion: 1, id: 'qemu-es-housekeeping', version: '1.0.0', definition_hash: 'fixture-hash', name: 'QEMU executive services housekeeping',
    description: 'Request housekeeping once and confirm a newly received packet.', supportedTargets: ['CFS-1_QEMU', 'CFS-2_QEMU', 'CATALOG_ONLY'], timeoutSec: 30,
    telemetryItems: [{ packet: 'CFE_ES_HK', item: 'COMMAND_COUNTER' }],
    steps: [{ id: 'request-hk', type: 'command', packet: 'CFE_ES_SEND_HK_CMD', parameters: {}, timeoutSec: 3 },
      { id: 'confirm-hk', type: 'waitTelemetry', packet: 'CFE_ES_HK', item: 'COMMAND_COUNTER', operator: 'gte', value: 0, timeoutSec: 10 }] }
  const events = []
  const secondScenario = { ...scenario, id: 'qemu-evs-housekeeping', name: 'QEMU event services housekeeping', definition_hash: 'fixture-evs-hash', steps: scenario.steps.map((step) => ({ ...step, packet: step.packet?.replace('CFE_ES', 'CFE_EVS') })) }
  const json = (route, value, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(value) })
  await page.routeWebSocket('**/openc3-api/cable?**', (socket) => {
    ws = socket
    socket.send(JSON.stringify({ type: 'welcome' }))
    socket.onMessage((message) => {
      const data = JSON.parse(message)
      if (data.command === 'subscribe') {
        socket.send(JSON.stringify({ type: 'confirm_subscription', identifier: data.identifier }))
        socket.send(JSON.stringify({ identifier: data.identifier, message: [
          { event: JSON.stringify({ type: 'LIMITS_CHANGE', target_name: 'CFS-1_QEMU', packet_name: 'CFE_ES_HK', item_name: 'COMMAND_COUNTER', new_limits_state: 'YELLOW_HIGH', time_nsec: Date.now() * 1000000 }) },
          { event: JSON.stringify({ type: 'LIMITS_CHANGE', target_name: 'OTHER_TARGET', packet_name: 'DO_NOT_SHOW', item_name: 'VALUE', new_limits_state: 'RED_HIGH', time_nsec: Date.now() * 1000000 }) },
        ] }))
      }
    })
  })
  await page.route('**/*', async (route) => {
    const url = new URL(route.request().url()), path = url.pathname
    if (url.hostname !== '127.0.0.1') throw new Error(`Unexpected external request: ${url.origin}`)
    if (bundle && path === '/tools/scenariorunner') return route.fulfill({ contentType: 'text/html', body: await readFile('tests/browser/bundle.html') })
    if (bundle && /^\/(js|css)\/[\w.-]+$/.test(path)) return route.fulfill({ contentType: path.endsWith('.css') ? 'text/css' : 'application/javascript', body: await readFile(resolve('../openc3-tool-base/public', path.slice(1))) })
    if (bundle && /^\/tools\/scenariorunner\/[\w.-]+\.js$/.test(path)) return route.fulfill({ contentType: 'application/javascript', body: await readFile(path.slice(1)) })
    if (path.startsWith('/scenario-api') || path.startsWith('/openc3-api')) requests.push(`${route.request().method()} ${path}`)
    if (path === '/scenario-api/scenarios') return json(route, { items: [scenario, secondScenario] })
    if (path === '/scenario-api/runs' && route.request().method() === 'GET') return json(route, { items: run ? [run] : [] })
    if (path === '/scenario-api/runs') {
      starts++
      const data = route.request().postDataJSON()
      run = { id: 'fixture-run', scope: 'DEFAULT', target: data.target, scenario_id: scenario.id, definition_version: scenario.version, definition_hash: scenario.definition_hash, state: 'running', created_at: new Date().toISOString(), updated_at: new Date().toISOString(), deadline: new Date(Date.now() + 30000).toISOString() }
      events.push({ id: 1, type: 'step', created_at: new Date().toISOString(), data: { step_id: 'request-hk', status: 'succeeded', commandAccepted: true } })
      return json(route, run, 201)
    }
    if (path.endsWith('/events')) return json(route, { items: events.filter((event) => event.id > Number(url.searchParams.get('after') || 0)), next_cursor: events.length })
    if (path.endsWith('/prompt')) { run = { ...run, state: 'running', prompt: null }; return json(route, run) }
    if (path.endsWith('/stop')) { run = { ...run, state: 'stopping', prompt: null }; return json(route, run) }
    if (path.startsWith('/scenario-api/runs/')) return json(route, run)
    if (path === '/openc3-api/screens') return json(route, ['CFS-1_QEMU/screens/cfe_es_hk.txt', 'CFS-1_QEMU/screens/active.txt', 'CFS-1_QEMU/screens/limits_demo.txt', 'CFS-2_QEMU/screens/cfe_es_hk.txt', 'CFS-1_BBB/screens/cfe_es_hk.txt'])
    if (path === '/openc3-api/autocomplete/keywords/screen') return json(route, [])
    if (path.endsWith('/ACTIVE')) return route.fulfill({ contentType: 'text/plain', body: 'SCREEN AUTO AUTO 1.0\nBUTTON "Send command" "api.cmd()"' })
    if (path.endsWith('/LIMITS_DEMO')) return route.fulfill({ contentType: 'text/plain', body: `SCREEN AUTO AUTO 1.0\nVERTICAL\nTITLE "Synthetic limits fixture"\n${itemMetadata.map((item) => `LABELVALUE CFS-1_QEMU CFE_ES_HK ${item.name}`).join('\n')}\nEND\n` })
    if (path.startsWith('/openc3-api/screen/')) return route.fulfill({ contentType: 'text/plain', body: `SCREEN AUTO AUTO 1.0\nVERTICAL\nTITLE "Executive Services Housekeeping"\nLABELVALUE ${decodeURIComponent(path.split('/')[3])} CFE_ES_HK COMMAND_COUNTER\nEND\n` })
    if (path === '/openc3-api/api') {
      const data = route.request().postDataJSON()
      let result
      if (data.method === 'get_target_names') result = ['CFS-1_QEMU', 'CFS-2_QEMU', 'NOT_SUPPORTED', 'CFS-1_BBB', 'SYSTEM', 'SCENARIO_RUNNER', 'CFS-1_BBB']
      else if (data.method === 'get_all_tlm_names') result = ['CFE_ES_HK']
      else if (data.method === 'get_tlm_available') result = data.params[0]
      else if (data.method === 'get_tlm_values') {
        if (!frozenReceipt) receipt = Date.now() / 1000
        result = data.params[0].map((reference) => {
          const item = reference.split('__')[2]
          if (item === 'RECEIVED_TIMESECONDS') return [receipt, null]
          if (item === 'BUS_VOLTAGE') return [reference.endsWith('FORMATTED') ? '-4.00' : -4, 'YELLOW_LOW']
          if (item === 'OPERATING_MODE') return ['SAFE', 'RED']
          if (item === 'MISSING') return [null, 'GREEN']
          if (item === 'DISABLED') return [0, 'GREEN']
          if (item === 'OVERFLOW') return [900, 'RED_HIGH']
          return [7, null]
        })
      }
      else if (data.method === 'get_tlm') result = { items: itemMetadata }
      else if (data.method === 'get_limits_set') result = 'DEFAULT'
      else throw new Error(`Unexpected RPC ${data.method}`)
      return json(route, { jsonrpc: '2.0', id: data.id, result })
    }
    if (path.startsWith('/openc3-api')) throw new Error(`Unexpected API ${path}`)
    return route.continue()
  })
  await page.goto(`http://127.0.0.1:2931${bundle ? '/tools/scenariorunner' : '/tests/browser/index.html'}`)
  await expect(page.locator('[data-test="start"]')).toBeEnabled()
  await expect(page.locator('[data-test="communication"]')).toHaveText('Live telemetry')
  await expect(page.locator('.screen-item')).toContainText('Executive Services Housekeeping')
  await expect(page.locator('.screen-item [data-test="value"] input')).toHaveValue('7')
  await expect(page.locator('[data-test="item-state"]')).toContainText('No limits')
  await expect(page.locator('[data-test="sample-trend"]')).toBeVisible()
  await expect(page.locator('[data-test="overview-scope"]')).toContainText('CFS-1_QEMU / CFE_ES_HK')
  await expect(page.locator('[data-test="limits-set"]')).toContainText('DEFAULT')
  await expect(page.locator('[data-test="telemetry-overview"] button, [data-test="telemetry-overview"] input, [data-test="telemetry-overview"] select')).toHaveCount(0)
  await mkdir(evidenceDir, { recursive: true })
  await page.screenshot({ path: `${evidenceDir}/telemetry-no-limits.png`, fullPage: true })
  checks.push('actual two-element CVT pairs, no-limits numeric trend, scoped counts and read-only limits-set text above retained packet screen')
  await page.locator('.screen-item [data-test="value"] input').click({ button: 'right' })
  await expect(page.getByText('Details', { exact: true })).not.toBeVisible()
  await page.locator('.screen-item [data-test="value"] input').press('Shift+F10')
  await expect(page.getByText('Details', { exact: true })).not.toBeVisible()
  checks.push('real VALUE context menu and keyboard context gesture cannot expose mutable Details limits control')
  await expect(page.locator('[data-test="target-select"] option')).toHaveCount(7)
  await expect(page.locator('[data-test="target-select"] option')).toHaveText(['Select installed target', 'CFS-1_BBB', 'CFS-1_QEMU', 'CFS-2_QEMU', 'NOT_SUPPORTED', 'SCENARIO_RUNNER', 'SYSTEM'])
  await expect(page.locator('[data-test="limits-events"]')).toContainText('COMMAND_COUNTER')
  await expect(page.locator('[data-test="limits-events"]')).not.toContainText('DO_NOT_SHOW')
  const grid = await page.locator('.runner-grid').evaluate((element) => getComputedStyle(element).gridTemplateColumns.split(' ').map(parseFloat))
  if (Math.abs(grid[0] / (grid[0] + grid[1]) - .45) > .005) throw new Error('Expected 45:55 panel split')
  checks.push('real Openc3Screen renders current telemetry; complete deduplicated installed targets without catalog-only names; 45:55 layout; selected-target limits filter')
  await page.locator('[data-test="target-select"]').selectOption('CFS-1_BBB')
  await expect(page.locator('[data-test="no-scenarios"]')).toHaveText('No scenarios available for this target')
  await expect(page.locator('[data-test="scenario-select"]')).toBeDisabled()
  await expect(page.locator('[data-test="start"]')).toBeDisabled()
  await expect(page.locator('.telemetry-panel h2').first()).toHaveText('CFS-1_BBB · HK / TM')
  await expect(page.locator('[data-test="overview-scope"]')).toContainText('CFS-1_BBB / CFE_ES_HK')
  await expect(page.locator('.screen-item [data-test="value"] input')).toHaveValue('7')
  await expect(page.locator('[data-test="communication"]')).toHaveText('Live telemetry')
  if (starts !== 0) throw new Error('Unsupported target selection triggered a start')
  await page.locator('[data-test="target-select"]').selectOption('CFS-1_QEMU')
  await expect(page.locator('[data-test="start"]')).toBeEnabled()
  await expect(page.locator('[data-test="scenario-select"] option')).toHaveCount(2)
  await expect(page.locator('[data-test="overview-scope"]')).toContainText('CFS-1_QEMU / CFE_ES_HK')
  checks.push('unsupported installed BBB target retains real read-only telemetry with no scenarios and Start disabled; returning to supported QEMU restores scenario selection')
  await page.locator('[data-test="screen-select"]').selectOption('ACTIVE')
  await expect(page.getByText('BUTTON is not a passive HK widget', { exact: false })).toBeVisible()
  await expect(page.locator('.screen-item')).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Send command' })).toHaveCount(0)
  await page.locator('[data-test="screen-select"]').selectOption('CFE_ES_HK')
  await expect(page.locator('.screen-item [data-test="value"] input')).toHaveValue('7')
  checks.push('command-bearing installed screen refused before mounting; no command RPC available in fixture')
  await page.locator('[data-test="screen-select"]').selectOption('LIMITS_DEMO')
  await expect(page.locator('[data-test="overview-row"]')).toHaveCount(6)
  await expect(page.locator('[data-test="overview-row"]').filter({ hasText: 'BUS_VOLTAGE' })).toContainText('Caution')
  await expect(page.locator('[data-test="overview-row"]').filter({ hasText: 'OPERATING_MODE' })).toContainText('Alarm')
  await expect(page.locator('[data-test="overview-row"]').filter({ hasText: 'DISABLED' })).toContainText('Limits disabled')
  await expect(page.locator('[data-test="overview-row"]').filter({ hasText: 'MISSING' })).toContainText('No data')
  await expect(page.locator('[data-test="overview-row"]').filter({ hasText: 'OVERFLOW' })).toContainText('Above scale · pointer clamped')
  await expect(page.locator('.screen-item')).toContainText('Synthetic limits fixture')
  await page.screenshot({ path: `${evidenceDir}/telemetry-limits-fixture.png`, fullPage: true })
  checks.push('synthetic actual-limit gauge, enum alarm, explicit disabled/missing states and clamped overflow; packet screen remains expanded')
  await page.locator('[data-test="screen-select"]').selectOption('CFE_ES_HK')
  await expect(page.locator('[data-test="item-state"]')).toContainText('No limits')
  await page.locator('[data-test="start"]').click()
  await expect(page.locator('[data-test="run-status"]')).toHaveText('Running')
  await expect(page.locator('[data-test="target-select"]')).toBeDisabled()
  await expect(page.locator('[data-test="start"]')).toBeDisabled()
  if (starts !== 1) throw new Error('Duplicate start')
  checks.push('start request and target/duplicate-start locks')
  run = { ...run, state: 'waiting', prompt: { prompt_id: 'prompt-1', status: 'pending', message: 'Confirm fixture continuation', choices: ['continue', 'cancel'], deadline: new Date(Date.now() + 30000).toISOString() } }
  await expect(page.getByText('Confirm fixture continuation')).toBeVisible()
  await page.getByRole('button', { name: 'continue', exact: true }).click()
  await expect(page.getByText('Confirm fixture continuation')).not.toBeVisible()
  checks.push('real Vuetify managed prompt displays and submits offered choice')
  frozenReceipt = true; receipt = Date.now() / 1000 - 30
  await expect(page.locator('[data-test="communication"]')).toHaveText('Telemetry delayed')
  await expect(page.locator('.screen-stale')).toBeVisible()
  await expect(page.locator('[data-test="item-state"]')).toContainText('Stale')
  await expect(page.locator('[data-test="run-status"]')).toHaveText('Running')
  checks.push('stale packet timestamp overrides green display while run state stays independent')
  await page.locator('[data-test="stop"]').click()
  await expect(page.locator('[data-test="run-status"]')).toHaveText('Stopping')
  await expect(page.locator('[data-test="start"]')).toBeDisabled()
  run = { ...run, state: 'stopped', termination_confirmed: true, updated_at: new Date().toISOString() }
  await expect(page.locator('[data-test="run-status"]')).toHaveText('Stopped')
  await expect(page.locator('[data-test="start"]')).toBeEnabled()
  checks.push('stop keeps lock until authoritative terminal response')
  await expect(page.getByText('Command accepted', { exact: true })).toBeVisible()
  await page.locator('[data-test="scenario-select"]').selectOption(secondScenario.id)
  await expect(page.getByText('Command accepted', { exact: true })).not.toBeVisible()
  await expect(page.locator('label[for="run-progress"]')).toHaveText('0 / 2 steps complete')
  await expect(page.locator('[data-test="run-status"]')).toHaveText('Ready')
  checks.push('switching scenario after terminal run clears prior step confirmations and completed count')
  await page.locator('[data-test="scenario-select"]').selectOption(scenario.id)
  await expect(page.locator('[data-test="item-state"]')).toContainText('Stale')
  await mkdir(evidenceDir, { recursive: true })
  await page.screenshot({ path: `${evidenceDir}/${bundle ? 'bundle' : 'browser'}-desktop.png`, fullPage: true })
  await page.setViewportSize({ width: 760, height: 1100 })
  const columns = await page.locator('.runner-grid').evaluate((element) => getComputedStyle(element).gridTemplateColumns.split(' ').length)
  if (columns !== 1) throw new Error('Narrow layout did not stack')
  await page.screenshot({ path: `${evidenceDir}/${bundle ? 'bundle' : 'browser'}-narrow.png`, fullPage: true })
  await page.evaluate(() => window.unmountFixture())
  const count = requests.length
  await page.waitForTimeout(1600)
  if (requests.length !== count) throw new Error('Network polling continued after unmount')
  checks.push('responsive layout and unmount stops API polling')
  if (errors.length) throw new Error(`Browser errors: ${errors.join('; ')}`)
  await writeFile(resolve(`${evidenceDir}/${bundle ? 'bundle' : 'browser'}-result.json`), JSON.stringify({ passed: true, checks, pageErrors: errors, requestCount: requests.length, externalRequests: 0, starts }, null, 2))
  console.log(JSON.stringify({ passed: true, checks, pageErrors: errors, starts }, null, 2))
} finally {
  await browser?.close()
  await server.close()
}

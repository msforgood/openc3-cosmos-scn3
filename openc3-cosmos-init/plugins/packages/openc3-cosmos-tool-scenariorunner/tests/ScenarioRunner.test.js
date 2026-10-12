import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { STORAGE_PREFIX } from '../src/runtime.js'

const mocks = vi.hoisted(() => ({ targets: vi.fn(), api: { scenarios: vi.fn(), runs: vi.fn(), reconcile: vi.fn(), run: vi.fn(), events: vi.fn(), start: vi.fn(), answer: vi.fn() } }))
vi.mock('../src/scenarioApi.js', () => ({ createScenarioApi: () => mocks.api }))
vi.mock('@openc3/js-common/services', () => ({ OpenC3Api: class { get_target_names() { return mocks.targets() } } }))
vi.mock('@openc3/vue-common/components', () => ({ TopBar: { template: '<div />' } }))
vi.mock('../src/TelemetryPanel.vue', () => ({ default: { props: ['target', 'scope', 'telemetryItems'], template: '<div data-test="telemetry-target">{{ target }}</div>' } }))
import ScenarioRunner from '../src/ScenarioRunner.vue'
import TelemetryPanel from '../src/TelemetryPanel.vue'

const request = { request_id: 'legacy-request', target: 'CFS-1_QEMU', scenario_id: 'cs-crc-key-oracle', definition_version: '1.0.0', definition_hash: 'abc' }
const failure = { ...request, id: 'failed-request', scope: 'DEFAULT', state: 'failed', error: 'request_not_accepted', termination_confirmed: true, script_id: null }
const active = { ...request, id: 'actual-run', scope: 'DEFAULT', state: 'running', script_id: '101', created_at: '2026-09-27T00:00:00Z' }
let wrapper
beforeEach(() => {
  vi.useFakeTimers(); vi.clearAllMocks(); localStorage.clear()
  window.openc3Scope = 'DEFAULT'
  mocks.targets.mockResolvedValue(['CFS-1_QEMU'])
  mocks.api.scenarios.mockResolvedValue({ items: [{ id: 'cs-crc-key-oracle', version: '1.0.0', definition_hash: 'abc', name: 'Housekeeping', supportedTargets: ['CFS-1_QEMU'], steps: [], telemetryItems: [] }] })
  mocks.api.reconcile.mockResolvedValue(failure)
  mocks.api.runs.mockResolvedValue({ items: [] })
  mocks.api.run.mockResolvedValue(active)
  mocks.api.events.mockResolvedValue({ items: [], next_cursor: 0 })
  localStorage.setItem(`${STORAGE_PREFIX}.DEFAULT.run.CFS-1_QEMU`, JSON.stringify({ pendingRequest: request }))
})
afterEach(() => { wrapper?.unmount(); wrapper = null; vi.useRealTimers() })
const render = async () => {
  wrapper = mount(ScenarioRunner, { global: { stubs: { 'v-dialog': true, 'v-card': true, 'v-card-actions': true, 'v-btn': true } } })
  await flushPromises()
}

it('displays a failed request separately from an active actual run during disconnection', async () => {
  mocks.api.runs.mockResolvedValue({ items: [active] })
  mocks.api.run.mockRejectedValue(new Error('offline'))
  await render()
  expect(wrapper.get('[data-test="request-failure"]').text()).toContain('시작 요청 실패')
  expect(wrapper.get('[data-test="run-status"]').text()).toBe('Running')
  expect(wrapper.text()).not.toContain('actual-run')
  expect(wrapper.text()).not.toContain('legacy-request')
  expect(wrapper.find('.run-id').exists()).toBe(false)
  expect(wrapper.text()).toContain('마지막 실행 상태는 보존되며')
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(true)
  expect(wrapper.get('[data-test="stop"]').element.disabled).toBe(false)
  expect(mocks.api.start).not.toHaveBeenCalled()
})

it('renders recovered absence as Failed and enables Start without pretending an execution existed', async () => {
  await render()
  expect(wrapper.get('[data-test="run-status"]').text()).toBe('Failed')
  expect(wrapper.get('[data-test="request-failure"]').text()).toContain('실행할 수 없습니다')
  expect(wrapper.find('.run-id').exists()).toBe(false)
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(false)
  expect(wrapper.get('[data-test="stop"]').element.disabled).toBe(true)
})

it('shows the X-band result area when the CRC scenario is selected', async () => {
  mocks.api.scenarios.mockResolvedValue({ items: [{ id: 'cs-crc-key-oracle', version: '1.0.1',
    definition_hash: 'oracle', name: 'Key recovery', supportedTargets: ['CFS-1_QEMU'], telemetryItems: [],
    steps: [{ id: 'verify-xband-frame', type: 'verifyXbandFrame' }] }] })
  await render()
  expect(wrapper.get('[data-test="xband-evidence"]').text()).toContain('CS CRC 응답 16개로 키를 복원합니다')
  expect(wrapper.find('[data-test="recovered-key"]').exists()).toBe(false)
  expect(wrapper.find('[data-test="decrypted-flag"]').exists()).toBe(false)
})

it('localizes scenario guidance and step descriptions while preserving controls and packet identifiers', async () => {
  localStorage.clear()
  mocks.api.scenarios.mockResolvedValue({ items: [{ id: 'cs-crc-key-oracle', version: '1.0.1',
    definition_hash: 'oracle', name: 'CS one-byte CRC key recovery', description: 'Recover the X-band lab key',
    supportedTargets: ['CFS-1_QEMU'], telemetryItems: [], steps: [
      { id: 'locate-key', type: 'resolveAddress' },
      { id: 'recover-byte-00', type: 'crcByte', offset: 0 },
    ] }] })
  await render()
  expect(wrapper.get('[data-test="scenario-select"] option').text()).toBe('01. CS 1바이트 CRC 키 복원')
  expect(wrapper.text()).toContain('Run step은 단계를 순서대로 실행하고')
  expect(wrapper.text()).toContain('Execution result는 해당 단계가 끝난 뒤 표시됩니다')
  expect(wrapper.text()).toContain('CS CRC 요청을 1바이트씩 16회 보내')
  expect(wrapper.text()).not.toContain('Recover the X-band lab key')
  expect(wrapper.get('[data-test="steps"]').text()).toContain('XKEY_HK에서 키 주소와 채널 상태 확인')
  expect(wrapper.get('[data-test="steps"]').text()).not.toContain('recover-byte-00')
  expect(wrapper.get('[data-test="steps"]').text()).toContain('CS_CMD_ONE_SHOT')
  expect(wrapper.get('[data-test="start"]').text()).toBe('Start script')
  expect(wrapper.get('[data-test="step-run-locate-key"]').text()).toBe('Run step')
})

it('starts a manual run from the first step and keeps Start script automatic', async () => {
  localStorage.clear()
  mocks.api.scenarios.mockResolvedValue({ items: [{ id: 'cs-crc-key-oracle', version: '1.0.0', definition_hash: 'abc',
    name: 'Housekeeping', supportedTargets: ['CFS-1_QEMU'], telemetryItems: [],
    steps: [{ id: 'first', type: 'delay', seconds: 1 }, { id: 'second', type: 'delay', seconds: 1 }] }] })
  mocks.api.start.mockResolvedValue({ ...active, execution_mode: 'manual' })
  await render()
  expect(wrapper.get('[data-test="start"]').text()).toBe('Start script')
  expect(wrapper.findAll('.step-execution-result')).toHaveLength(0)
  expect(wrapper.get('[data-test="step-run-first"]').element.disabled).toBe(false)
  expect(wrapper.get('[data-test="step-run-second"]').element.disabled).toBe(true)
  await wrapper.get('[data-test="step-run-first"]').trigger('click'); await flushPromises()
  expect(mocks.api.start).toHaveBeenCalledWith(expect.objectContaining({ execution_mode: 'manual', scenario_id: 'cs-crc-key-oracle' }))
  expect(wrapper.findAll('.step-execution-result')).toHaveLength(0)
  expect(wrapper.get('[data-test="step-run-first"]').element.disabled).toBe(true)
  wrapper.unmount(); wrapper = null
  localStorage.clear()
  mocks.api.start.mockResolvedValue(active)
  await render()
  await wrapper.get('[data-test="start"]').trigger('click'); await flushPromises()
  expect(mocks.api.start.mock.lastCall[0]).not.toHaveProperty('execution_mode')
})

it('shows planned TC packets and parameter values before execution, including dynamic expressions', async () => {
  localStorage.clear()
  mocks.api.scenarios.mockResolvedValue({ items: [{ id: 'cs-crc-key-oracle', version: '1.0.0', definition_hash: 'abc',
    name: 'Preview', supportedTargets: ['CFS-1_QEMU'], telemetryItems: [], steps: [
      { id: 'normal', type: 'tcLogPhase', phase: 'record-normal' },
      { id: 'pointer', type: 'pspPhase', phase: 'write-pointer' },
      { id: 'byte', type: 'crcByte', offset: 7 },
      { id: 'read-only', type: 'verifyXbandFrame' },
    ] }] })
  await render()
  const normal = wrapper.get('[data-test="step-command-plan-normal"]').text()
  expect(normal).toContain('CFE_ES_SEND_HK_CMD')
  expect(normal).toContain('TC_CAMERA_CAPTURE_CMD')
  expect(normal).toContain('orbit.png')
  expect(normal).toContain('REQUEST_ID')
  const pointer = wrapper.get('[data-test="step-command-plan-pointer"]').text()
  expect(pointer).toContain('MM_CMD_DEBUG_WRITE')
  expect(pointer).toContain('"WIDTH_BYTES": 4')
  expect(pointer).toContain('GUARD_ADDRESS (baseline 단계 PAYLOAD_DATA_STATE)')
  expect(pointer).toContain('POINTER_SLOT (map 단계 결과)')
  const byte = wrapper.get('[data-test="step-command-plan-byte"]').text()
  expect(byte).toContain('CS_CMD_ONE_SHOT')
  expect(byte).toContain('XKEY_HK.KEY_ADDRESS (locate-key 단계 결과) + 7')
  expect(wrapper.get('[data-test="step-command-plan-read-only"]').text()).toContain('No TC')
  expect(wrapper.find('[data-test="step-result-normal"]').exists()).toBe(false)
})

it('enables only the prompted next step and shows its exact execution result', async () => {
  const scenario = { id: 'cs-crc-key-oracle', version: '1.0.0', definition_hash: 'abc', name: 'Housekeeping',
    supportedTargets: ['CFS-1_QEMU'], telemetryItems: [], steps: [
      { id: 'first', type: 'delay', seconds: 1 },
      { id: 'second', type: 'delay', seconds: 1 },
      { id: 'third', type: 'delay', seconds: 1 },
    ] }
  const parameters = '{"ADDRESS":18446744073709551615,"SIZE":1}'
  const waiting = { ...active, execution_mode: 'manual', state: 'waiting',
    prompt: { prompt_id: 'third', choices: ['continue'], status: 'pending', deadline: '2026-09-27T00:10:00Z' } }
  localStorage.setItem(`${STORAGE_PREFIX}.DEFAULT.run.CFS-1_QEMU`, JSON.stringify({ runId: waiting.id }))
  mocks.api.scenarios.mockResolvedValue({ items: [scenario] })
  mocks.api.run.mockResolvedValue(waiting)
  mocks.api.events.mockResolvedValue({ items: [
    { id: 1, type: 'step', data: { step_id: 'first', status: 'succeeded' } },
    { id: 2, type: 'command', data: { step_id: 'second', packet: 'CS_CMD_ONE_SHOT', parameters_json: parameters } },
    { id: 3, type: 'command', data: { step_id: 'second', packet: 'CFE_ES_SEND_HK_CMD', parameters_json: '{}' } },
    { id: 4, type: 'step', data: { step_id: 'second', status: 'succeeded',
      message: '0xb69f20b8: CRC 0xa3c1, byte 1/16 recovered' } },
  ], next_cursor: 4 })
  mocks.api.answer.mockResolvedValue({ ...waiting, state: 'running', prompt: { ...waiting.prompt, status: 'answered' } })
  await render()
  expect(wrapper.get('[data-test="step-run-first"]').element.disabled).toBe(true)
  expect(wrapper.get('[data-test="step-run-second"]').element.disabled).toBe(true)
  expect(wrapper.get('[data-test="step-run-third"]').element.disabled).toBe(false)
  expect(wrapper.get('[data-test="step-command-plan-first"]').text()).toContain('No TC')
  const result = wrapper.get('[data-test="step-result-second"]')
  expect(result.text()).toContain('Execution result')
  expect(result.get('pre').text()).toBe('0xb69f20b8: CRC 0xa3c1, byte 1/16 recovered')
  expect(wrapper.find('[data-test="step-result-third"]').exists()).toBe(false)
  expect(wrapper.get('[data-test="steps"]').text()).not.toContain('Accepted TC')
  expect(wrapper.get('[data-test="logs"]').text()).toContain(`2단계 · CS_CMD_ONE_SHOT · ${parameters}`)
  expect(wrapper.get('[data-test="logs"]').text()).not.toContain('second ·')
  expect(wrapper.text()).not.toContain('Respond by')
  await wrapper.get('[data-test="step-run-third"]').trigger('click'); await flushPromises()
  expect(mocks.api.answer).toHaveBeenCalledWith(waiting.id, 'third', 'continue')
})

it('uses a clear execution result when a successful or failed step has no message', async () => {
  const scenario = { id: 'cs-crc-key-oracle', version: '1.0.0', definition_hash: 'abc', name: 'Housekeeping',
    supportedTargets: ['CFS-1_QEMU'], telemetryItems: [], steps: [
      { id: 'telemetry', type: 'waitTelemetry', packet: 'CFE_ES_HK', item: 'COMMAND_COUNTER', operator: 'gte', value: 0, timeoutSec: 10 },
      { id: 'failed', type: 'delay', seconds: 1 },
    ] }
  localStorage.setItem(`${STORAGE_PREFIX}.DEFAULT.run.CFS-1_QEMU`, JSON.stringify({ runId: active.id }))
  mocks.api.scenarios.mockResolvedValue({ items: [scenario] })
  mocks.api.events.mockResolvedValue({ items: [
    { id: 1, type: 'step', data: { step_id: 'telemetry', status: 'succeeded', telemetryConfirmed: true,
      packet: 'CFE_ES_HK', item: 'COMMAND_COUNTER', value: 0 } },
    { id: 2, type: 'step', data: { step_id: 'failed', status: 'failed' } },
  ], next_cursor: 2 })
  await render()
  expect(wrapper.get('[data-test="step-result-telemetry"] pre').text()).toBe('CFE_ES_HK.COMMAND_COUNTER = 0')
  expect(wrapper.get('[data-test="step-result-failed"] pre').text()).toBe('Step failed')
})

it('shows a completed CRC result only after the current script executes', async () => {
  const key = '2c9a017e54e3b860114dfa820c9735d6'
  const scenario = { id: 'cs-crc-key-oracle', version: '1.0.1', definition_hash: 'oracle',
    name: 'Key recovery', supportedTargets: ['CFS-1_QEMU'], telemetryItems: [],
    steps: [{ id: 'verify-xband-frame', type: 'verifyXbandFrame' }] }
  const complete = { ...active, scenario_id: scenario.id, definition_version: scenario.version,
    definition_hash: scenario.definition_hash, state: 'succeeded', updated_at: '2026-09-27T00:01:00Z',
    result: { status: 'succeeded', message: `Recovered X-band lab key: ${key}` } }
  localStorage.clear()
  mocks.api.start.mockResolvedValue(complete)
  mocks.api.run.mockResolvedValue(complete)
  mocks.api.scenarios.mockResolvedValue({ items: [scenario] })
  mocks.api.events.mockResolvedValue({ items: [{ id: 1, type: 'step', data: {
    step_id: 'verify-xband-frame', status: 'succeeded', authenticated: true,
    message: 'XBD1 frame 42 AES-GCM authenticated; decrypted flag: flag{crc_oracle}',
  } }], next_cursor: 1 })
  await render()
  expect(wrapper.find('[data-test="recovered-key"]').exists()).toBe(false)
  expect(wrapper.find('[data-test="decrypted-flag"]').exists()).toBe(false)
  expect(wrapper.find('[data-test="step-result-verify-xband-frame"]').exists()).toBe(false)
  await wrapper.get('[data-test="start"]').trigger('click'); await flushPromises()
  expect(wrapper.get('[data-test="recovered-key"]').text()).toContain(key)
  expect(wrapper.get('[data-test="decrypted-flag"]').text()).toContain('flag{crc_oracle}')
  expect(wrapper.get('[data-test="decrypted-flag"]').text()).toContain('frame 42 · AES-GCM authenticated')
  expect(wrapper.get('[data-test="step-result-verify-xband-frame"]').text()).toContain('XBD1 frame 42 AES-GCM authenticated')
})

it('opens a fresh step list instead of showing a saved completed run', async () => {
  const scenario = { id: 'cs-crc-key-oracle', version: '1.0.0', definition_hash: 'abc', name: 'Housekeeping',
    supportedTargets: ['CFS-1_QEMU'], telemetryItems: [], steps: [{ id: 'first', type: 'delay', seconds: 1 }] }
  const complete = { ...active, state: 'succeeded', result: { status: 'succeeded' } }
  localStorage.setItem(`${STORAGE_PREFIX}.DEFAULT.run.CFS-1_QEMU`, JSON.stringify({ runId: complete.id, runState: 'succeeded' }))
  mocks.api.scenarios.mockResolvedValue({ items: [scenario] })
  mocks.api.run.mockResolvedValue(complete)
  mocks.api.events.mockResolvedValue({ items: [{ id: 1, type: 'step', data: {
    step_id: 'first', status: 'succeeded', message: 'Step completed',
  } }], next_cursor: 1 })
  await render()
  expect(wrapper.get('[data-test="run-status"]').text()).toBe('Ready')
  expect(wrapper.get('[data-test="step-run-first"]').element.disabled).toBe(false)
  expect(wrapper.find('[data-test="step-result-first"]').exists()).toBe(false)
  expect(wrapper.get('[data-test="logs"]').text()).not.toContain('Step completed')
  expect(mocks.api.run).not.toHaveBeenCalled()
})

it('shows a confirmed failed request while offline discovery keeps Start locked and cleans up retries on unmount', async () => {
  mocks.api.runs.mockRejectedValue(new Error('offline'))
  await render()
  expect(wrapper.get('[data-test="run-status"]').text()).toBe('Failed')
  expect(wrapper.text()).toContain('다른 실행이 진행 중인지 확인합니다')
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(true)
  const calls = mocks.api.runs.mock.calls.length
  wrapper.unmount(); wrapper = null
  window.dispatchEvent(new Event('online'))
  await vi.advanceTimersByTimeAsync(100000)
  expect(mocks.api.runs).toHaveBeenCalledTimes(calls)
  expect(vi.getTimerCount()).toBe(0)
})

const targetNames = () => wrapper.findAll('[data-test="target-select"] option').map((option) => option.element.value).filter(Boolean)
const scenarioNames = () => wrapper.findAll('[data-test="scenario-select"] option').map((option) => option.element.value)
const scenarioLabels = () => wrapper.findAll('[data-test="scenario-select"] option').map((option) => option.text())
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }

it('shows the same three scenarios in catalog order for QEMU and BBB', async () => {
  localStorage.clear()
  mocks.targets.mockResolvedValue(['CFS-1_BBB', 'SYSTEM', 'CFS-1_QEMU'])
  const sharedTargets = ['CFS-1_QEMU', 'CFS-1_BBB']
  const items = [
    { id: 'cs-crc-key-oracle', supportedTargets: sharedTargets, steps: [], telemetryItems: [] },
    { id: 'tc-log-photo-traversal', supportedTargets: sharedTargets, steps: [], telemetryItems: [] },
    { id: 'psp-mm-indirect-write', supportedTargets: sharedTargets, steps: [], telemetryItems: [] },
  ]
  mocks.api.scenarios.mockResolvedValue({ items })
  await render()
  expect(targetNames()).toEqual(['CFS-1_QEMU', 'CFS-1_BBB'])
  expect(scenarioNames()).toEqual(items.map((scenario) => scenario.id))
  const labels = ['01. CS 1바이트 CRC 키 복원', '02. TC 로그 사진 경로 변경', '03. MM 포인터 변경']
  expect(scenarioLabels()).toEqual(labels)
  await wrapper.get('[data-test="target-select"]').setValue('CFS-1_BBB'); await flushPromises()
  expect(scenarioNames()).toEqual(items.map((scenario) => scenario.id))
  expect(scenarioLabels()).toEqual(labels)
})

it.each(['CFS-1_QEMU', 'CFS-1_BBB'])('starts the same shared definition on %s', async (target) => {
  localStorage.clear()
  localStorage.setItem(`${STORAGE_PREFIX}.DEFAULT.target`, target)
  mocks.targets.mockResolvedValue(['CFS-1_QEMU', 'CFS-1_BBB'])
  const scenario = { id: 'cs-crc-key-oracle', version: '1.0.1', definition_hash: 'shared-hash',
    name: '01. CS 1바이트 CRC 키 복원', supportedTargets: ['CFS-1_QEMU', 'CFS-1_BBB'], steps: [], telemetryItems: [] }
  mocks.api.scenarios.mockResolvedValue({ items: [scenario] })
  const run = { ...active, target, scenario_id: scenario.id,
    definition_version: scenario.version, definition_hash: scenario.definition_hash }
  mocks.api.start.mockResolvedValue(run)
  mocks.api.run.mockResolvedValue(run)
  await render()
  expect(wrapper.get('[data-test="target-select"]').element.value).toBe(target)
  expect(scenarioNames()).toEqual([scenario.id])
  await wrapper.get('[data-test="start"]').trigger('click'); await flushPromises()
  expect(mocks.api.start).toHaveBeenCalledWith(expect.objectContaining({
    scenario_id: scenario.id, target, definition_version: scenario.version, definition_hash: scenario.definition_hash,
  }))
})

it('keeps a legacy active run visible without selecting an obsolete scenario ID', async () => {
  localStorage.clear()
  const legacy = { ...active, scenario_id: 'qemu-cs-crc-key-oracle' }
  mocks.api.scenarios.mockResolvedValue({ items: [{ id: 'cs-crc-key-oracle', version: '1.0.1',
    definition_hash: 'shared-hash', name: '01. CS 1바이트 CRC 키 복원',
    supportedTargets: ['CFS-1_QEMU', 'CFS-1_BBB'], steps: [], telemetryItems: [] }] })
  mocks.api.runs.mockResolvedValue({ items: [legacy] })
  mocks.api.run.mockResolvedValue(legacy)
  await render()
  expect(scenarioNames()).toEqual(['cs-crc-key-oracle'])
  expect(wrapper.get('[data-test="scenario-select"]').element.value).toBe('cs-crc-key-oracle')
  expect(wrapper.text()).toContain('이전 실행의 확인 결과는 해당 로그에서만 볼 수 있습니다')
  expect(wrapper.get('[data-test="run-status"]').text()).toBe('Running')
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(true)
})

it('shows only the two installed cFS targets in QEMU then BBB order', async () => {
  mocks.targets.mockResolvedValue(['SYSTEM', 'CFS-1_BBB', 'OTHER', 'CFS-1_QEMU', 'SCENARIO_RUNNER', 'CFS-1_BBB'])
  mocks.api.scenarios.mockResolvedValue({ items: [{ id: 'cs-crc-key-oracle', supportedTargets: ['CFS-1_QEMU', 'ABSENT'], steps: [] }] })
  await render()
  expect(targetNames()).toEqual(['CFS-1_QEMU', 'CFS-1_BBB'])
  expect(wrapper.get('[data-test="target-select"]').element.value).toBe('CFS-1_QEMU')
  expect(mocks.targets).toHaveBeenCalledTimes(1)
})

it('keeps a saved registered unsupported target selected and forwards it to telemetry without enabling Start', async () => {
  mocks.targets.mockResolvedValue(['CFS-1_QEMU', 'CFS-1_BBB'])
  localStorage.setItem(`${STORAGE_PREFIX}.DEFAULT.target`, 'CFS-1_BBB')
  await render()
  expect(wrapper.get('[data-test="target-select"]').element.value).toBe('CFS-1_BBB')
  expect(wrapper.get('[data-test="no-scenarios"]').text()).toBe('이 대상에서 실행할 수 있는 시나리오가 없습니다.')
  expect(wrapper.findComponent(TelemetryPanel).props()).toMatchObject({ target: 'CFS-1_BBB', scope: 'DEFAULT', telemetryItems: [] })
  expect(mocks.api.runs).toHaveBeenCalledWith('CFS-1_BBB')
  expect(wrapper.get('[data-test="scenario-select"]').element.disabled).toBe(true)
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(true)
  await wrapper.get('[data-test="start"]').trigger('click')
  expect(mocks.api.start).not.toHaveBeenCalled()
  expect(localStorage.getItem(`${STORAGE_PREFIX}.DEFAULT.target`)).toBe('CFS-1_BBB')
})

it('prefers an installed runnable default over an absent saved target', async () => {
  mocks.targets.mockResolvedValue(['CFS-1_BBB', 'CFS-1_QEMU'])
  localStorage.setItem(`${STORAGE_PREFIX}.DEFAULT.target`, 'ABSENT')
  await render()
  expect(targetNames()).toEqual(['CFS-1_QEMU', 'CFS-1_BBB'])
  expect(wrapper.get('[data-test="target-select"]').element.value).toBe('CFS-1_QEMU')
})

it('filters shared scenarios by support and permissions when switching targets', async () => {
  localStorage.clear()
  mocks.targets.mockResolvedValue(['CFS-1_QEMU', 'CFS-1_BBB', 'OTHER'])
  const base = { steps: [], telemetryItems: [] }
  mocks.api.scenarios.mockResolvedValue({ items: [
    { ...base, id: 'cs-crc-key-oracle', supportedTargets: ['CFS-1_QEMU', 'CFS-1_BBB'], telemetryItems: [{ packet: 'HK', item: 'VALUE' }] },
    { ...base, id: 'tc-log-photo-traversal', supportedTargets: ['CFS-1_QEMU', 'CFS-1_BBB'], permittedTargets: ['CFS-1_BBB'] },
    { ...base, id: 'psp-mm-indirect-write', supportedTargets: ['CFS-1_QEMU', 'CFS-1_BBB'], permittedTargets: [] },
  ] })
  await render()
  expect(scenarioNames()).toEqual(['cs-crc-key-oracle'])
  expect(wrapper.findComponent(TelemetryPanel).props('telemetryItems')).toEqual([{ packet: 'HK', item: 'VALUE' }])
  await wrapper.get('[data-test="target-select"]').setValue('CFS-1_BBB'); await flushPromises()
  expect(scenarioNames()).toEqual(['cs-crc-key-oracle', 'tc-log-photo-traversal'])
  expect(wrapper.findComponent(TelemetryPanel).props('target')).toBe('CFS-1_BBB')
  expect(wrapper.findComponent(TelemetryPanel).props('telemetryItems')).toEqual([{ packet: 'HK', item: 'VALUE' }])
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(false)
  expect(mocks.api.start).not.toHaveBeenCalled()
})

it.each(['empty', 'failed', 'malformed', 'malformed scenario'])('retains the installed cFS targets with a %s catalog', async (catalogState) => {
  mocks.targets.mockResolvedValue(['SYSTEM', 'CFS-1_BBB', 'CFS-1_QEMU'])
  if (catalogState === 'empty') mocks.api.scenarios.mockResolvedValue({ items: [] })
  else if (catalogState === 'malformed') mocks.api.scenarios.mockResolvedValue({})
  else if (catalogState === 'malformed scenario') mocks.api.scenarios.mockResolvedValue({ items: [{}] })
  else mocks.api.scenarios.mockRejectedValue(new Error('catalog offline'))
  await render()
  expect(targetNames()).toEqual(['CFS-1_QEMU', 'CFS-1_BBB'])
  expect(wrapper.get('[data-test="no-scenarios"]').exists()).toBe(true)
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(true)
  expect(wrapper.get('[data-test="target-select"]').element.disabled).toBe(false)
  expect(wrapper.text().includes('시나리오를 불러오지 못했습니다: catalog offline')).toBe(catalogState === 'failed')
  if (catalogState.startsWith('malformed')) expect(wrapper.text()).toContain('Invalid scenario catalog')
  await wrapper.get('[data-test="target-select"]').setValue('CFS-1_BBB'); await flushPromises()
  expect(wrapper.findComponent(TelemetryPanel).props('target')).toBe('CFS-1_BBB')
  expect(mocks.api.runs).toHaveBeenCalledWith('CFS-1_BBB')
  expect(mocks.api.start).not.toHaveBeenCalled()
})

it('reports target discovery failure separately and never uses catalog names as installed targets', async () => {
  mocks.targets.mockRejectedValue(new Error('target discovery offline'))
  await render()
  expect(targetNames()).toEqual([])
  expect(wrapper.text()).toContain('설치된 대상을 불러오지 못했습니다: target discovery offline')
  expect(wrapper.text()).not.toContain('시나리오를 불러오지 못했습니다:')
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(true)
  expect(mocks.api.runs).not.toHaveBeenCalled()
})

it('shows both independent discovery errors when both services fail', async () => {
  mocks.targets.mockRejectedValue(new Error('targets offline'))
  mocks.api.scenarios.mockRejectedValue(new Error('catalog offline'))
  await render()
  expect(wrapper.text()).toContain('설치된 대상을 불러오지 못했습니다: targets offline')
  expect(wrapper.text()).toContain('시나리오를 불러오지 못했습니다: catalog offline')
})

it('handles malformed installed names without synthesizing catalog targets', async () => {
  mocks.targets.mockResolvedValue({ names: ['CFS-1_QEMU'] })
  await render()
  expect(targetNames()).toEqual([])
  expect(wrapper.text()).toContain('설치된 대상을 불러오지 못했습니다: Invalid installed target list')
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(true)
})

it.each(['resolve', 'reject'])('ignores late catalog and target %s completions after unmount', async (completion) => {
  const installed = deferred(), catalog = deferred()
  mocks.targets.mockReturnValue(installed.promise)
  mocks.api.scenarios.mockReturnValue(catalog.promise)
  await render()
  wrapper.unmount(); wrapper = null
  if (completion === 'resolve') {
    installed.resolve(['CFS-1_BBB']); catalog.resolve({ items: [] })
  } else {
    installed.reject(new Error('late targets')); catalog.reject(new Error('late catalog'))
  }
  await flushPromises()
  await vi.advanceTimersByTimeAsync(100000)
  expect(mocks.api.runs).not.toHaveBeenCalled()
  expect(localStorage.getItem(`${STORAGE_PREFIX}.DEFAULT.target`)).toBeNull()
  expect(vi.getTimerCount()).toBe(0)
})

it('does not persist a late selection or schedule recovery after unmount during target run discovery', async () => {
  const runs = deferred()
  mocks.api.runs.mockReturnValue(runs.promise)
  await render()
  wrapper.unmount(); wrapper = null
  runs.reject(new Error('late discovery'))
  await flushPromises()
  await vi.advanceTimersByTimeAsync(100000)
  expect(localStorage.getItem(`${STORAGE_PREFIX}.DEFAULT.target`)).toBeNull()
  expect(vi.getTimerCount()).toBe(0)
})

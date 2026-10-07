import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { STORAGE_PREFIX } from '../src/runtime.js'

const mocks = vi.hoisted(() => ({ targets: vi.fn(), api: { scenarios: vi.fn(), runs: vi.fn(), reconcile: vi.fn(), run: vi.fn(), events: vi.fn(), start: vi.fn() } }))
vi.mock('../src/scenarioApi.js', () => ({ createScenarioApi: () => mocks.api }))
vi.mock('@openc3/js-common/services', () => ({ OpenC3Api: class { get_target_names() { return mocks.targets() } } }))
vi.mock('@openc3/vue-common/components', () => ({ TopBar: { template: '<div />' } }))
vi.mock('../src/TelemetryPanel.vue', () => ({ default: { props: ['target', 'scope', 'telemetryItems'], template: '<div data-test="telemetry-target">{{ target }}</div>' } }))
import ScenarioRunner from '../src/ScenarioRunner.vue'
import TelemetryPanel from '../src/TelemetryPanel.vue'

const request = { request_id: 'legacy-request', target: 'A', scenario_id: 'hk', definition_version: '1.0.0', definition_hash: 'abc' }
const failure = { ...request, id: 'failed-request', scope: 'DEFAULT', state: 'failed', error: 'request_not_accepted', termination_confirmed: true, script_id: null }
const active = { ...request, id: 'actual-run', scope: 'DEFAULT', state: 'running', script_id: '101', created_at: '2026-09-27T00:00:00Z' }
let wrapper
beforeEach(() => {
  vi.useFakeTimers(); vi.clearAllMocks(); localStorage.clear()
  window.openc3Scope = 'DEFAULT'
  mocks.targets.mockResolvedValue(['A'])
  mocks.api.scenarios.mockResolvedValue({ items: [{ id: 'hk', version: '1.0.0', definition_hash: 'abc', name: 'Housekeeping', supportedTargets: ['A'], steps: [], telemetryItems: [] }] })
  mocks.api.reconcile.mockResolvedValue(failure)
  mocks.api.runs.mockResolvedValue({ items: [] })
  mocks.api.run.mockResolvedValue(active)
  mocks.api.events.mockResolvedValue({ items: [], next_cursor: 0 })
  localStorage.setItem(`${STORAGE_PREFIX}.DEFAULT.run.A`, JSON.stringify({ pendingRequest: request }))
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
  expect(wrapper.get('[data-test="request-failure"]').text()).toContain('Start request FAILED')
  expect(wrapper.get('[data-test="run-status"]').text()).toBe('Running')
  expect(wrapper.text()).toContain('Run actual-run')
  expect(wrapper.text()).toContain('The last actual run state is retained')
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(true)
  expect(wrapper.get('[data-test="stop"]').element.disabled).toBe(false)
  expect(mocks.api.start).not.toHaveBeenCalled()
})

it('renders recovered absence as Failed and enables Start without pretending an execution existed', async () => {
  await render()
  expect(wrapper.get('[data-test="run-status"]').text()).toBe('Failed')
  expect(wrapper.get('[data-test="request-failure"]').text()).toContain('cannot launch')
  expect(wrapper.find('.run-id').exists()).toBe(false)
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(false)
  expect(wrapper.get('[data-test="stop"]').element.disabled).toBe(true)
})

it('shows a confirmed failed request while offline discovery keeps Start locked and cleans up retries on unmount', async () => {
  mocks.api.runs.mockRejectedValue(new Error('offline'))
  await render()
  expect(wrapper.get('[data-test="run-status"]').text()).toBe('Failed')
  expect(wrapper.text()).toContain('The request failed; checking for other active runs')
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
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }

it('lists every distinct installed target in sorted order without fabricating catalog-only targets', async () => {
  mocks.targets.mockResolvedValue(['SYSTEM', 'CFS-1_BBB', 'OTHER', 'A', 'SCENARIO_RUNNER', 'CFS-1_BBB'])
  mocks.api.scenarios.mockResolvedValue({ items: [{ id: 'hk', supportedTargets: ['A', 'ABSENT'], steps: [] }] })
  await render()
  expect(targetNames()).toEqual(['A', 'CFS-1_BBB', 'OTHER', 'SCENARIO_RUNNER', 'SYSTEM'])
  expect(wrapper.get('[data-test="target-select"]').element.value).toBe('A')
  expect(mocks.targets).toHaveBeenCalledTimes(1)
})

it('keeps a saved registered unsupported target selected and forwards it to telemetry without enabling Start', async () => {
  mocks.targets.mockResolvedValue(['A', 'CFS-1_BBB'])
  localStorage.setItem(`${STORAGE_PREFIX}.DEFAULT.target`, 'CFS-1_BBB')
  await render()
  expect(wrapper.get('[data-test="target-select"]').element.value).toBe('CFS-1_BBB')
  expect(wrapper.get('[data-test="no-scenarios"]').text()).toBe('No scenarios available for this target')
  expect(wrapper.findComponent(TelemetryPanel).props()).toMatchObject({ target: 'CFS-1_BBB', scope: 'DEFAULT', telemetryItems: [] })
  expect(mocks.api.runs).toHaveBeenCalledWith('CFS-1_BBB')
  expect(wrapper.get('[data-test="scenario-select"]').element.disabled).toBe(true)
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(true)
  await wrapper.get('[data-test="start"]').trigger('click')
  expect(mocks.api.start).not.toHaveBeenCalled()
  expect(localStorage.getItem(`${STORAGE_PREFIX}.DEFAULT.target`)).toBe('CFS-1_BBB')
})

it('prefers an installed runnable default over unsupported names or an absent saved target', async () => {
  mocks.targets.mockResolvedValue(['0_UNSUPPORTED', 'A'])
  localStorage.setItem(`${STORAGE_PREFIX}.DEFAULT.target`, 'ABSENT')
  await render()
  expect(targetNames()).toEqual(['0_UNSUPPORTED', 'A'])
  expect(wrapper.get('[data-test="target-select"]').element.value).toBe('A')
})

it('preserves supportedTargets and permittedTargets scenario filtering when browsing all targets', async () => {
  localStorage.clear()
  mocks.targets.mockResolvedValue(['A', 'B', 'OTHER'])
  const base = { steps: [], telemetryItems: [] }
  mocks.api.scenarios.mockResolvedValue({ items: [
    { ...base, id: 'a', supportedTargets: ['A'], telemetryItems: [{ packet: 'HK', item: 'VALUE' }] },
    { ...base, id: 'b', supportedTargets: ['A', 'B'], permittedTargets: ['B'] },
    { ...base, id: 'denied', supportedTargets: ['A', 'B'], permittedTargets: [] },
  ] })
  await render()
  expect(scenarioNames()).toEqual(['a'])
  expect(wrapper.findComponent(TelemetryPanel).props('telemetryItems')).toEqual([{ packet: 'HK', item: 'VALUE' }])
  await wrapper.get('[data-test="target-select"]').setValue('OTHER'); await flushPromises()
  expect(scenarioNames()).toEqual([])
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(true)
  expect(wrapper.findComponent(TelemetryPanel).props('target')).toBe('OTHER')
  expect(wrapper.findComponent(TelemetryPanel).props('telemetryItems')).toEqual([])
  await wrapper.get('[data-test="target-select"]').setValue('B'); await flushPromises()
  expect(scenarioNames()).toEqual(['b'])
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(false)
  expect(mocks.api.start).not.toHaveBeenCalled()
})

it.each(['empty', 'failed', 'malformed', 'malformed scenario'])('retains installed target and telemetry browsing with a %s catalog', async (catalogState) => {
  mocks.targets.mockResolvedValue(['SYSTEM', 'CFS-1_BBB'])
  if (catalogState === 'empty') mocks.api.scenarios.mockResolvedValue({ items: [] })
  else if (catalogState === 'malformed') mocks.api.scenarios.mockResolvedValue({})
  else if (catalogState === 'malformed scenario') mocks.api.scenarios.mockResolvedValue({ items: [{}] })
  else mocks.api.scenarios.mockRejectedValue(new Error('catalog offline'))
  await render()
  expect(targetNames()).toEqual(['CFS-1_BBB', 'SYSTEM'])
  expect(wrapper.get('[data-test="no-scenarios"]').exists()).toBe(true)
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(true)
  expect(wrapper.get('[data-test="target-select"]').element.disabled).toBe(false)
  expect(wrapper.text().includes('Unable to load scenarios: catalog offline')).toBe(catalogState === 'failed')
  if (catalogState.startsWith('malformed')) expect(wrapper.text()).toContain('Invalid scenario catalog')
  await wrapper.get('[data-test="target-select"]').setValue('SYSTEM'); await flushPromises()
  expect(wrapper.findComponent(TelemetryPanel).props('target')).toBe('SYSTEM')
  expect(mocks.api.runs).toHaveBeenCalledWith('SYSTEM')
  expect(mocks.api.start).not.toHaveBeenCalled()
})

it('reports target discovery failure separately and never uses catalog names as installed targets', async () => {
  mocks.targets.mockRejectedValue(new Error('target discovery offline'))
  await render()
  expect(targetNames()).toEqual([])
  expect(wrapper.text()).toContain('Unable to load installed targets: target discovery offline')
  expect(wrapper.text()).not.toContain('Unable to load scenarios:')
  expect(wrapper.get('[data-test="start"]').element.disabled).toBe(true)
  expect(mocks.api.runs).not.toHaveBeenCalled()
})

it('shows both independent discovery errors when both services fail', async () => {
  mocks.targets.mockRejectedValue(new Error('targets offline'))
  mocks.api.scenarios.mockRejectedValue(new Error('catalog offline'))
  await render()
  expect(wrapper.text()).toContain('Unable to load installed targets: targets offline')
  expect(wrapper.text()).toContain('Unable to load scenarios: catalog offline')
})

it('handles malformed installed names without synthesizing catalog targets', async () => {
  mocks.targets.mockResolvedValue({ names: ['A'] })
  await render()
  expect(targetNames()).toEqual([])
  expect(wrapper.text()).toContain('Unable to load installed targets: Invalid installed target list')
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

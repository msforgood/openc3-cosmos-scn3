import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'

const mocks = vi.hoisted(() => ({ apiGet: vi.fn(), packetNames: vi.fn(), values: vi.fn(), limitsSet: vi.fn(), metadata: vi.fn(), cables: [], pending: [], screenPackets: ['HK'] }))
vi.mock('@openc3/js-common/services', () => ({
  Api: { get: mocks.apiGet },
  OpenC3Api: class {
    get_all_tlm_names(...args) { return mocks.packetNames(...args) }
    get_tlm_values(...args) { return mocks.values(...args) }
    get_limits_set(...args) { return mocks.limitsSet(...args) }
    get_tlm(...args) { return mocks.metadata(...args) }
  },
  Cable: class {
    constructor() { this.disconnect = vi.fn(); this.unsubscribe = vi.fn(); mocks.cables.push(this) }
    createSubscription(channel, scope, callbacks) {
      this.callbacks = callbacks
      return new Promise((resolve) => mocks.pending.push(() => resolve({ unsubscribe: this.unsubscribe })))
    }
  },
}))
vi.mock('@openc3/vue-common/components', () => ({ Openc3Screen: { props: ['target', 'screen', 'definition'], computed: { screenItems() { return mocks.screenPackets.map((packet) => `${this.target}__${packet}__VALUE__RAW`) } }, template: '<div data-test="real-screen-contract">{{ target }}:{{ screen }}:{{ definition }}</div>' } }))
import TelemetryPanel from '../src/TelemetryPanel.vue'

let wrapper
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(new Date('2026-09-27T00:00:00Z'))
  mocks.cables.length = 0; mocks.pending.length = 0
  mocks.screenPackets = ['HK']
  mocks.apiGet.mockImplementation(async (path) => ({ data: path.endsWith('/screens') ? ['A/screens/a_hk.txt', 'B/screens/b_hk.txt'] : path.includes('/keywords/') ? [] : `SCREEN AUTO AUTO 1.0\nTITLE "definition for ${path}"\n${mocks.screenPackets.map((packet) => `VALUE ${path.split('/')[3]} ${packet} VALUE`).join('\n')}` }))
  mocks.packetNames.mockResolvedValue(['HK'])
  mocks.values.mockImplementation(async (items) => items.map((item) => [item.includes('RECEIVED_TIMESECONDS') ? Date.now() / 1000 : 7, null]))
  mocks.limitsSet.mockResolvedValue('DEFAULT')
  mocks.metadata.mockResolvedValue({ items: [{ name: 'VALUE', limits: {} }] })
})
afterEach(() => { wrapper?.unmount(); vi.useRealTimers(); vi.clearAllMocks() })

it('renders installed selected-target screen and clears old target subscriptions/events on change', async () => {
  wrapper = mount(TelemetryPanel, { props: { target: 'A', scope: 'DEFAULT' } })
  await flushPromises()
  expect(wrapper.find('[data-test="real-screen-contract"]').text()).toContain('A:A_HK')
  mocks.pending[0](); await flushPromises()
  mocks.cables[0].callbacks.received([{ event: JSON.stringify({ type: 'LIMITS_CHANGE', target_name: 'A', packet_name: 'OLD', item_name: 'VALUE' }) }])
  await vi.advanceTimersByTimeAsync(250)
  expect(wrapper.find('[data-test="limits-events"]').text()).toContain('OLD')
  await wrapper.setProps({ target: 'B' }); await flushPromises()
  expect(mocks.cables[0].unsubscribe).toHaveBeenCalledTimes(1)
  expect(mocks.cables[0].disconnect).toHaveBeenCalledTimes(1)
  expect(wrapper.find('[data-test="limits-events"]').text()).not.toContain('OLD')
  expect(wrapper.find('[data-test="real-screen-contract"]').text()).toContain('B:B_HK')
  mocks.cables[0].callbacks.received([{ event: JSON.stringify({ type: 'LIMITS_CHANGE', target_name: 'A', packet_name: 'LATE' }) }])
  await vi.advanceTimersByTimeAsync(250)
  expect(wrapper.text()).not.toContain('LATE')
})

it('disposes subscriptions that resolve after target changes or unmount, with no remaining timers', async () => {
  wrapper = mount(TelemetryPanel, { props: { target: 'A', scope: 'DEFAULT' } })
  await flushPromises(); await wrapper.setProps({ target: 'B' }); await flushPromises()
  mocks.pending[0](); await flushPromises()
  expect(mocks.cables[0].unsubscribe).toHaveBeenCalledTimes(1)
  wrapper.unmount(); wrapper = null
  mocks.pending[1](); await flushPromises()
  expect(mocks.cables[1].unsubscribe).toHaveBeenCalledTimes(1)
  expect(mocks.cables[1].disconnect).toHaveBeenCalledTimes(2)
  expect(vi.getTimerCount()).toBe(0)
})

it('shows delayed telemetry even while polling succeeds, grays old screen colors, and shows disconnect separately', async () => {
  const receipt = Date.now() / 1000
  mocks.values.mockImplementation(async (items) => items.map((item) => [item.includes('RECEIVED_TIMESECONDS') ? receipt : 7, null]))
  wrapper = mount(TelemetryPanel, { props: { target: 'A', scope: 'DEFAULT' } })
  await flushPromises()
  await vi.advanceTimersByTimeAsync(1000)
  expect(wrapper.find('[data-test="communication"]').text()).toBe('Live telemetry')
  const displayedTime = wrapper.find('[data-test="receipt"]').text()
  await vi.advanceTimersByTimeAsync(11000)
  expect(wrapper.find('[data-test="communication"]').text()).toBe('Telemetry delayed')
  expect(wrapper.find('.screen-stale').exists()).toBe(true)
  expect(wrapper.find('[data-test="receipt"]').text()).toBe(displayedTime)
  mocks.values.mockRejectedValue(new Error('offline'))
  await vi.advanceTimersByTimeAsync(1000)
  expect(wrapper.find('[data-test="communication"]').text()).toBe('Telemetry disconnected')
})

it('does not allow one fresh packet to conceal a stale packet in the selected screen', async () => {
  mocks.screenPackets = ['HK', 'SECOND']
  mocks.packetNames.mockResolvedValue(['HK', 'SECOND', 'NOT_ON_SCREEN'])
  mocks.values.mockImplementation(async (items) => items.map((item) => [item.includes('RECEIVED_TIMESECONDS') ? Date.now() / 1000 - (item.includes('SECOND') ? 20 : 0) : 7, null]))
  wrapper = mount(TelemetryPanel, { props: { target: 'A', scope: 'DEFAULT' } })
  await flushPromises(); await vi.advanceTimersByTimeAsync(1000)
  expect(mocks.values.mock.lastCall[0]).toEqual(['A__HK__RECEIVED_TIMESECONDS__RAW', 'A__SECOND__RECEIVED_TIMESECONDS__RAW', 'A__HK__VALUE__CONVERTED', 'A__HK__VALUE__FORMATTED', 'A__SECOND__VALUE__CONVERTED', 'A__SECOND__VALUE__FORMATTED'])
  expect(wrapper.find('[data-test="communication"]').text()).toBe('Telemetry delayed')
  expect(wrapper.find('.screen-stale').exists()).toBe(true)
})

it('ignores a late old-target screen response', async () => {
  let finishOld
  mocks.apiGet.mockImplementation(async (path) => {
    if (path.endsWith('/screens')) return { data: ['A/screens/a_hk.txt', 'B/screens/b_hk.txt'] }
    if (path.includes('/keywords/')) return { data: [] }
    if (path.includes('/A/')) return new Promise((resolve) => { finishOld = resolve })
    return { data: 'SCREEN AUTO AUTO 1.0\nTITLE "new target definition"\nVALUE B HK VALUE' }
  })
  wrapper = mount(TelemetryPanel, { props: { target: 'A', scope: 'DEFAULT' } })
  await flushPromises(); await wrapper.setProps({ target: 'B' }); await flushPromises()
  finishOld({ data: 'SCREEN AUTO AUTO 1.0\nTITLE "old target definition"\nVALUE A HK VALUE' }); await flushPromises()
  expect(wrapper.text()).toContain('new target definition')
  expect(wrapper.text()).not.toContain('old target definition')
})

it('chooses the scenario HK and never mounts an installed command-bearing screen', async () => {
  mocks.apiGet.mockImplementation(async (path) => {
    if (path.endsWith('/screens')) return { data: ['A/screens/unrelated_hk.txt', 'A/screens/es_hk_tlm_screen.txt', 'A/screens/active.txt'] }
    if (path.includes('/keywords/')) return { data: [] }
    if (path.endsWith('/ACTIVE')) return { data: 'SCREEN AUTO AUTO 1.0\nBUTTON "Send" "api.cmd()"' }
    return { data: 'SCREEN AUTO AUTO 1.0\nVALUE A ES_HK COUNT' }
  })
  wrapper = mount(TelemetryPanel, { props: { target: 'A', scope: 'DEFAULT', telemetryItems: [{ packet: 'ES_HK', item: 'COUNT' }] } })
  await flushPromises()
  expect(wrapper.find('[data-test="screen-select"]').element.value).toBe('ES_HK_TLM_SCREEN')
  await wrapper.find('[data-test="screen-select"]').setValue('ACTIVE'); await flushPromises()
  expect(wrapper.find('[data-test="real-screen-contract"]').exists()).toBe(false)
  expect(wrapper.text()).toContain('BUTTON is not a passive HK widget')
  expect(mocks.apiGet.mock.calls.every(([path]) => !path.includes('cmd'))).toBe(true)
})

it('keeps the packet screen below a bounded no-limits overview and samples only new receipts', async () => {
  let receipt = Date.now() / 1000
  mocks.values.mockImplementation(async (items) => items.map((item) => [item.includes('RECEIVED_TIMESECONDS') ? receipt : 0, null]))
  wrapper = mount(TelemetryPanel, { props: { target: 'A', scope: 'DEFAULT' } })
  await flushPromises(); await vi.advanceTimersByTimeAsync(1000)
  expect(wrapper.find('[data-test="overview-scope"]').text()).toContain('A / A_HK')
  expect(wrapper.find('[data-test="overview-row"]').text()).toContain('VALUE')
  expect(wrapper.find('[data-test="item-state"]').text()).toContain('No limits')
  expect(wrapper.find('[data-test="overview-row"]').text()).toContain('1/30 samples')
  expect(wrapper.find('[data-test="sample-trend"]').attributes('aria-label')).toContain('not a normal range')
  expect(wrapper.find('[data-test="limits-gauge"]').exists()).toBe(false)
  expect(wrapper.html().indexOf('telemetry-overview')).toBeLessThan(wrapper.html().indexOf('screen-container'))
  expect(wrapper.find('[data-test="real-screen-contract"]').exists()).toBe(true)
  await vi.advanceTimersByTimeAsync(5000)
  expect(wrapper.find('[data-test="overview-row"]').text()).toContain('1/30 samples')
  receipt = Date.now() / 1000
  await vi.advanceTimersByTimeAsync(1000)
  expect(wrapper.find('[data-test="overview-row"]').text()).toContain('2/30 samples')
  expect(mocks.metadata).toHaveBeenCalledTimes(1)
  expect(mocks.limitsSet).toHaveBeenCalledTimes(1)
})

it('uses converted numeric values for the gauge while rendering formatted values/units and neutralizing stale green', async () => {
  const receipt = Date.now() / 1000
  mocks.metadata.mockResolvedValue({ items: [{ name: 'VALUE', units: 'V', limits: { enabled: true, DEFAULT: { red_low: -10, yellow_low: -5, yellow_high: 30, red_high: 50 } } }] })
  mocks.values.mockImplementation(async (items) => items.map((item) => [item.includes('RECEIVED_TIMESECONDS') ? receipt : item.endsWith('FORMATTED') ? '0.00' : 0, 'GREEN']))
  wrapper = mount(TelemetryPanel, { props: { target: 'A', scope: 'DEFAULT' } })
  await flushPromises(); await vi.advanceTimersByTimeAsync(1000)
  expect(wrapper.find('.overview-value').text()).toBe('0.00V')
  expect(wrapper.find('[data-test="item-state"]').text()).toContain('Within limits')
  expect(wrapper.find('[data-test="limits-gauge"]').attributes('aria-label')).toContain('converted value 0')
  await vi.advanceTimersByTimeAsync(11000)
  expect(wrapper.find('[data-test="item-state"]').text()).toContain('Stale')
  expect(wrapper.find('.gauge-inactive').exists()).toBe(true)
  expect(wrapper.find('[data-test="overview-row"] .state-within').exists()).toBe(false)
  mocks.values.mockRejectedValue(new Error('offline')); await vi.advanceTimersByTimeAsync(1000)
  expect(wrapper.find('[data-test="item-state"]').text()).toContain('Disconnected')
})

it('fails metadata safely and continues receipt/value reads, then recovers metadata in the serial poll', async () => {
  mocks.metadata.mockRejectedValue(new Error('metadata offline'))
  wrapper = mount(TelemetryPanel, { props: { target: 'A', scope: 'DEFAULT' } })
  await flushPromises(); await vi.advanceTimersByTimeAsync(1000)
  expect(wrapper.find('[data-test="communication"]').text()).toBe('Live telemetry')
  expect(wrapper.find('[data-test="item-state"]').text()).toContain('Limits unknown')
  expect(wrapper.text()).toContain('Limits metadata unavailable')
  mocks.metadata.mockResolvedValue({ items: [{ name: 'VALUE', limits: {} }] })
  await vi.advanceTimersByTimeAsync(30000)
  expect(wrapper.find('[data-test="item-state"]').text()).toContain('No limits')
  expect(wrapper.text()).not.toContain('Limits metadata unavailable')
})

it.each(['target', 'scope', 'screen', 'unmount'])('ignores metadata resolving after %s selection cleanup', async (change) => {
  let finish
  mocks.metadata.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve }))
  mocks.apiGet.mockImplementation(async (path) => ({ data: path.endsWith('/screens') ? ['A/screens/a_hk.txt', 'A/screens/second.txt', 'B/screens/b_hk.txt'] : path.includes('/keywords/') ? [] : `SCREEN AUTO AUTO 1\nVALUE ${path.split('/')[3]} HK VALUE` }))
  wrapper = mount(TelemetryPanel, { props: { target: 'A', scope: 'DEFAULT' } })
  await flushPromises(); await vi.advanceTimersByTimeAsync(1000)
  if (change === 'target') await wrapper.setProps({ target: 'B' })
  if (change === 'scope') await wrapper.setProps({ scope: 'OTHER' })
  if (change === 'screen') await wrapper.find('[data-test="screen-select"]').setValue('SECOND')
  if (change === 'unmount') { wrapper.unmount(); wrapper = null }
  await flushPromises()
  finish({ items: [{ name: 'VALUE', units: 'OLD-METADATA', limits: { enabled: true, DEFAULT: { red_low: 0, yellow_low: 1, yellow_high: 2, red_high: 3 } } }] })
  await flushPromises(); await vi.advanceTimersByTimeAsync(1000)
  if (wrapper) {
    expect(wrapper.text()).not.toContain('OLD-METADATA')
    expect(wrapper.find('[data-test="limits-gauge"]').exists()).toBe(false)
  } else expect(vi.getTimerCount()).toBe(0)
})

it('serializes slow value reads and ignores old-screen values and errors, clearing trends on selection', async () => {
  mocks.apiGet.mockImplementation(async (path) => ({ data: path.endsWith('/screens') ? ['A/screens/a_hk.txt', 'A/screens/second.txt'] : path.includes('/keywords/') ? [] : 'SCREEN AUTO AUTO 1\nVALUE A HK VALUE' }))
  wrapper = mount(TelemetryPanel, { props: { target: 'A', scope: 'DEFAULT' } })
  await flushPromises(); await vi.advanceTimersByTimeAsync(1000)
  expect(wrapper.text()).toContain('1/30 samples')
  let finish
  mocks.values.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve }))
  await vi.advanceTimersByTimeAsync(1000)
  const calls = mocks.values.mock.calls.length
  await vi.advanceTimersByTimeAsync(4000)
  expect(mocks.values).toHaveBeenCalledTimes(calls)
  await wrapper.find('[data-test="screen-select"]').setValue('SECOND'); await flushPromises()
  expect(wrapper.find('[data-test="sample-trend"]').exists()).toBe(false)
  finish([[Date.now() / 1000, null], [999, 'RED'], ['OLD-VALUE', 'RED']]); await flushPromises()
  expect(wrapper.text()).not.toContain('OLD-VALUE')
  await vi.advanceTimersByTimeAsync(1000)
  expect(wrapper.find('[data-test="overview-row"]').text()).toContain('1/30 samples')
  expect(mocks.metadata).toHaveBeenCalledTimes(2)
})

it('caps poll item count and sample history and exposes no mutable overview controls', async () => {
  const items = Array.from({ length: 50 }, (_, i) => `ITEM_${i}`)
  mocks.apiGet.mockImplementation(async (path) => ({ data: path.endsWith('/screens') ? ['A/screens/a_hk.txt'] : path.includes('/keywords/') ? [] : `SCREEN AUTO AUTO 1\n${items.map((item) => `VALUE A HK ${item}`).join('\n')}` }))
  mocks.metadata.mockResolvedValue({ items: items.map((name) => ({ name, limits: {} })) })
  wrapper = mount(TelemetryPanel, { props: { target: 'A', scope: 'DEFAULT', telemetryItems: [{ packet: 'HK', item: 'ITEM_49' }] } })
  await flushPromises(); await vi.advanceTimersByTimeAsync(41000)
  expect(wrapper.findAll('[data-test="overview-row"]')).toHaveLength(24)
  expect(wrapper.find('[data-test="overview-row"]').text()).toContain('ITEM_49')
  expect(wrapper.find('[data-test="overview-row"]').text()).toContain('30/30 samples')
  expect(wrapper.find('[data-test="overview-scope"]').text()).toContain('24 of 50')
  expect(mocks.values.mock.calls.every(([items]) => items.length === 49)).toBe(true)
  expect(wrapper.find('[data-test="telemetry-overview"]').findAll('button, input, select')).toHaveLength(0)
  await wrapper.find('[data-test="overview-row"]').trigger('contextmenu')
  expect(wrapper.text()).not.toContain('Details')
  wrapper.unmount(); wrapper = null
  expect(vi.getTimerCount()).toBe(0)
})

it('preserves a pending installed-screen load when scenario items change within that screen', async () => {
  let finishScreen
  mocks.apiGet.mockImplementation(async (path) => {
    if (path.endsWith('/screens')) return { data: ['A/screens/hk.txt'] }
    if (path.includes('/keywords/')) return { data: [] }
    return new Promise((resolve) => { finishScreen = resolve })
  })
  wrapper = mount(TelemetryPanel, { props: { target: 'A', scope: 'DEFAULT' } })
  await flushPromises()
  await wrapper.setProps({ telemetryItems: [{ packet: 'HK', item: 'VALUE' }] })
  finishScreen({ data: 'SCREEN AUTO AUTO 1\nVALUE A HK VALUE' }); await flushPromises()
  expect(wrapper.find('[data-test="real-screen-contract"]').exists()).toBe(true)
  await vi.advanceTimersByTimeAsync(1000)
  expect(wrapper.find('[data-test="item-state"]').text()).toContain('No limits')
})

import { afterEach, describe, expect, it, vi } from 'vitest'
import { communicationStatus, packetReceipt, SerialPoller, supportedTargets, TargetLimitsSubscription } from '../src/runtime.js'

const deferred = () => { let resolve; const promise = new Promise((r) => { resolve = r }); return { promise, resolve } }
afterEach(() => vi.useRealTimers())
describe('packet freshness', () => {
  it('intersects runtime targets with canonical supportedTargets', () => {
    expect(supportedTargets(['CFS', 'CFS-1_QEMU', 'OTHER'], [{ supportedTargets: ['CFS-1_QEMU', 'ABSENT'] }])).toEqual(['CFS-1_QEMU'])
  })
  it('does not use a successful poll as packet receipt time', () => {
    const now = 100000, lastReceipt = packetReceipt([[80, 'GREEN', 80], [null, null, 0]])
    expect(lastReceipt).toBe(80000)
    expect(communicationStatus({ connected: true, lastReceipt, lastSuccess: now }, now)).toBe('delayed')
  })
  it('distinguishes no data, disconnect, live, clock skew and stalled requests', () => {
    expect(packetReceipt([[0], [null], ['NaN']])).toBeNull()
    expect(communicationStatus({ connected: true, lastReceipt: null, lastSuccess: 100000 }, 100000)).toBe('no_data')
    expect(communicationStatus({ connected: false, lastReceipt: 100000, lastSuccess: 100000 }, 100000)).toBe('disconnected')
    expect(communicationStatus({ connected: true, lastReceipt: 99000, lastSuccess: 100000 }, 100000)).toBe('live')
    expect(communicationStatus({ connected: true, lastReceipt: 200000, lastSuccess: 100000 }, 100000)).toBe('delayed')
    expect(communicationStatus({ connected: true, lastReceipt: 110000, lastSuccess: 99000 }, 110001)).toBe('disconnected')
  })
})
describe('serialized polling', () => {
  it('never overlaps slow requests and does not reschedule after disposal', async () => {
    vi.useFakeTimers()
    const pending = deferred(), work = vi.fn(() => pending.promise)
    const poller = new SerialPoller(work)
    poller.start(); poller.start()
    await vi.advanceTimersByTimeAsync(5000)
    expect(work).toHaveBeenCalledTimes(1)
    pending.resolve()
    await vi.advanceTimersByTimeAsync(999)
    expect(work).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(work).toHaveBeenCalledTimes(2)
    poller.stop()
    await vi.advanceTimersByTimeAsync(5000)
    expect(work).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })
})
describe('target limits subscription ownership', () => {
  it('unsubscribes late subscriptions and disconnects a socket created after disposal', async () => {
    const pending = deferred(), unsubscribe = vi.fn(), disconnect = vi.fn()
    const cable = { createSubscription: vi.fn(() => pending.promise), disconnect }
    const onEvents = vi.fn()
    const stream = new TargetLimitsSubscription({ createCable: () => cable, target: 'A', scope: 'DEFAULT', onEvents, onConnection: vi.fn() })
    const callbacks = cable.createSubscription.mock.calls[0][2]
    stream.dispose()
    callbacks.received([{ event: JSON.stringify({ type: 'LIMITS_CHANGE', target_name: 'A' }) }])
    pending.resolve({ unsubscribe }); await stream.ready
    expect(unsubscribe).toHaveBeenCalledTimes(1)
    expect(disconnect).toHaveBeenCalledTimes(2)
    expect(onEvents).not.toHaveBeenCalled()
  })
  it('accepts only exact target LIMITS_CHANGE events and uses the 6.10.1 history_count key', async () => {
    const cable = { createSubscription: vi.fn(() => Promise.resolve({ unsubscribe: vi.fn() })), disconnect: vi.fn() }
    const onEvents = vi.fn()
    const stream = new TargetLimitsSubscription({ createCable: () => cable, target: 'CFS-1', scope: 'DEFAULT', onEvents, onConnection: vi.fn() })
    const args = cable.createSubscription.mock.calls[0]
    expect(args[3]).toEqual({ history_count: 1000 })
    args[2].received([
      { event: '{bad' },
      { event: JSON.stringify({ type: 'LIMITS_SET', target_name: 'CFS-1' }) },
      { event: JSON.stringify({ type: 'LIMITS_CHANGE', target_name: 'CFS-10' }) },
      { event: JSON.stringify({ type: 'LIMITS_CHANGE', target_name: 'CFS-1', item_name: 'VALUE' }) },
    ])
    expect(onEvents.mock.calls[0][0]).toEqual([{ type: 'LIMITS_CHANGE', target_name: 'CFS-1', item_name: 'VALUE' }])
    await stream.ready; stream.dispose()
  })
})

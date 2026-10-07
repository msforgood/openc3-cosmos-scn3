import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { initialRunnerState, RunnerController, runStatus, runMatchesScenario, START_WAIT_MS, RECOVERY_DELAYS } from '../src/runnerController.js'

const deferred = () => { let resolve, reject; const promise = new Promise((r, j) => { resolve = r; reject = j }); return { promise, resolve, reject } }
const scenario = { id: 'hk', version: 1, definition_hash: 'abc', supportedTargets: ['A'] }
const run = (state = 'running') => ({ id: 'run-1', scope: 'DEFAULT', target: 'A', scenario_id: 'hk', state, prompt: null })
const recovered = (request, status = 'failed') => ({ ...run(status), ...request,
  error: status === 'failed' ? 'request_not_accepted' : null, termination_confirmed: ['failed', 'succeeded'].includes(status), script_id: status === 'failed' ? null : '101' })
const savedRequest = { target: 'A', request_id: 'legacy-request', scenario_id: 'hk', definition_version: 1, definition_hash: 'abc' }
let api, state, controller
beforeEach(() => {
  vi.useFakeTimers(); localStorage.clear()
  api = { runs: vi.fn(async () => ({ items: [] })), start: vi.fn(async () => run()), reconcile: vi.fn(async (request) => recovered(request)), run: vi.fn(async () => run()), events: vi.fn(async () => ({ items: [], next_cursor: 0 })), stop: vi.fn(async () => run('stopping')), answer: vi.fn() }
  state = initialRunnerState()
  controller = new RunnerController({ api, state, scope: 'DEFAULT' })
})
afterEach(() => { controller.dispose(); vi.useRealTimers() })

describe('run locks and contract', () => {
  it('correlates progress to exact target, scenario id, version and definition hash', () => {
    const completed = { ...run('succeeded'), definition_version: scenario.version, definition_hash: scenario.definition_hash }
    expect(runMatchesScenario(completed, scenario, 'A')).toBe(true)
    for (const changed of [{ ...scenario, id: 'evs' }, { ...scenario, version: 2 }, { ...scenario, definition_hash: 'changed' }]) {
      expect(runMatchesScenario(completed, changed, 'A')).toBe(false)
    }
    expect(runMatchesScenario(completed, scenario, 'B')).toBe(false)
  })
  it('maps every API status, keeping unknown active', () => {
    expect(['launching','running','waiting','stopping','unknown','succeeded','failed','stopped'].map((state) => runStatus(run(state))))
      .toEqual(['running','running','waiting_input','stopping','needs_attention','succeeded','failed','stopped'])
  })
  it('locks synchronously before start resolves and forbids target change / duplicate start', async () => {
    await controller.selectTarget('A')
    const pending = deferred(); api.start.mockReturnValue(pending.promise)
    const first = controller.start(scenario)
    expect(controller.locked).toBe(true)
    expect(await controller.start(scenario)).toBe(false)
    expect(await controller.selectTarget('B')).toBe(false)
    expect(api.start).toHaveBeenCalledTimes(1)
    expect(api.start.mock.calls[0][0]).toMatchObject({ target: 'A', scenario_id: 'hk', definition_version: 1, definition_hash: 'abc' })
    expect(api.start.mock.calls[0][0]).not.toHaveProperty('parameters')
    pending.resolve(run()); await first
    expect(controller.locked).toBe(true)
  })
  it('recovers an active server run before allowing another start', async () => {
    api.runs.mockResolvedValue({ items: [run('unknown')] })
    api.run.mockResolvedValue(run('unknown'))
    await controller.selectTarget('A')
    expect(state.status).toBe('needs_attention')
    expect(controller.locked).toBe(true)
    expect(await controller.start(scenario)).toBe(false)
  })
  it('retains ambiguous start across page reload without resending it', async () => {
    await controller.selectTarget('A')
    api.start.mockRejectedValue(new Error('network lost'))
    api.reconcile.mockRejectedValue(new Error('offline'))
    await controller.start(scenario)
    expect(state.status).toBe('needs_attention')
    controller.dispose()
    state = initialRunnerState(); controller = new RunnerController({ api, state, scope: 'DEFAULT' })
    await controller.selectTarget('A')
    expect(state.status).toBe('needs_attention')
    expect(controller.locked).toBe(true)
    expect(api.start).toHaveBeenCalledTimes(1)
  })
  it('does not transform run polling failure into a terminal state or release its lock', async () => {
    await controller.selectTarget('A')
    api.run.mockRejectedValue(new Error('offline'))
    await controller.start(scenario); await vi.advanceTimersByTimeAsync(1)
    expect(state.status).toBe('running')
    expect(state.apiConnected).toBe(false)
    expect(controller.locked).toBe(true)
  })
  it('serializes polling and ignores late results after disposal', async () => {
    await controller.selectTarget('A')
    const pending = deferred(); api.run.mockReturnValue(pending.promise)
    await controller.start(scenario)
    await vi.advanceTimersByTimeAsync(5000)
    expect(api.run).toHaveBeenCalledTimes(1)
    controller.dispose(); pending.resolve(run('succeeded'))
    await vi.advanceTimersByTimeAsync(10000)
    expect(state.status).toBe('running')
    expect(vi.getTimerCount()).toBe(0)
  })
  it('does not let an older poll overwrite a stop response', async () => {
    await controller.selectTarget('A')
    const pending = deferred(); api.run.mockReturnValue(pending.promise)
    await controller.start(scenario)
    await controller.action('stop')
    expect(state.status).toBe('stopping')
    pending.resolve(run()); await vi.advanceTimersByTimeAsync(1)
    expect(state.status).toBe('stopping')
  })
  it('bounds logs to the last 1000, ignores cursor replays and records progress', () => {
    const items = Array.from({ length: 1200 }, (_, i) => ({ id: i + 1, type: 'log', data: { message: String(i) } }))
    controller.applyEvents({ items, next_cursor: 1200 })
    expect(state.logs).toHaveLength(1000); expect(state.logs[0].id).toBe(201)
    controller.applyEvents({ items: [items[1199]], next_cursor: 1200 })
    expect(state.logs).toHaveLength(1000)
    controller.applyEvents({ items: [{ id: 1201, type: 'step', data: { step_id: 'hk', status: 'succeeded', telemetryConfirmed: true } }], next_cursor: 1201 })
    expect(state.steps.hk.telemetryConfirmed).toBe(true)
  })
  it('sends managed prompt choice without arbitrary input or duplicate submission', async () => {
    await controller.selectTarget('A')
    const waiting = { ...run('waiting'), prompt: { prompt_id: 'p1', status: 'pending' } }
    controller.applyRun(waiting)
    const pending = deferred(); api.answer.mockReturnValue(pending.promise)
    const answer = controller.action('answer', 'continue')
    await controller.action('answer', 'continue')
    expect(api.answer).toHaveBeenCalledTimes(1)
    expect(api.answer).toHaveBeenCalledWith('run-1', 'p1', 'continue')
    pending.resolve(run()); await answer
    expect(state.prompt).toBeNull()
  })
  it('drains terminal event pages at the API page size before ending polling', async () => {
    await controller.selectTarget('A')
    api.run.mockResolvedValue(run('succeeded'))
    const items = Array.from({ length: 100 }, (_, i) => ({ id: i + 1, type: 'log', data: {} }))
    api.events.mockResolvedValueOnce({ items, next_cursor: 100 }).mockResolvedValue({ items: [{ id: 101, type: 'result', data: { status: 'succeeded' } }], next_cursor: 101 })
    await controller.start(scenario); await vi.advanceTimersByTimeAsync(1001)
    expect(state.logs).toHaveLength(101)
    expect(state.logs.at(-1).type).toBe('result')
    expect(api.events).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })
})

describe('request recovery', () => {
  it('fails a never accepted lost request and unlocks an explicit retry with a new identity', async () => {
    await controller.selectTarget('A')
    api.start.mockRejectedValueOnce(new Error('lost response'))
    await controller.start(scenario)
    const request = api.start.mock.calls[0][0]
    expect(api.reconcile).toHaveBeenCalledWith(request)
    expect(state.status).toBe('failed')
    expect(state.requestFailure).toMatchObject({ request_id: request.request_id, error: 'request_not_accepted' })
    expect(state.run).toBeNull()
    expect(state.pendingRequest).toBeNull()
    expect(controller.locked).toBe(false)
    await vi.advanceTimersByTimeAsync(0)
    expect(vi.getTimerCount()).toBe(0)
    await controller.start(scenario)
    expect(api.start).toHaveBeenCalledTimes(2)
    expect(api.start.mock.calls[1][0].request_id).not.toBe(request.request_id)
    expect(state.requestFailure).toBeNull()
  })

  it.each(['launching', 'running', 'unknown', 'stopping', 'succeeded'])('recovers the exact accepted %s request without a second start', async (status) => {
    await controller.selectTarget('A')
    api.start.mockRejectedValue(new Error('lost response'))
    api.reconcile.mockImplementation(async (request) => recovered(request, status))
    api.run.mockImplementation(async () => recovered(api.start.mock.calls[0][0], status))
    api.runs.mockResolvedValue({ items: [{ ...run('failed'), id: 'newer-unrelated' }] })
    await controller.start(scenario)
    expect(state.run.id).toBe('run-1')
    expect(state.run.state).toBe(status)
    expect(state.pendingRequest).toBeNull()
    expect(state.requestFailure).toBeNull()
    expect(controller.locked).toBe(status !== 'succeeded')
    expect(api.start).toHaveBeenCalledTimes(1)
  })

  it('settles the failed request while retaining another active target run and its stop behavior', async () => {
    await controller.selectTarget('A')
    api.start.mockRejectedValue(new Error('lost response'))
    api.runs.mockResolvedValue({ items: [run('unknown')] })
    api.run.mockResolvedValue(run('unknown'))
    await controller.start(scenario)
    expect(state.requestFailure.error).toBe('request_not_accepted')
    expect(state.run.state).toBe('unknown')
    expect(state.status).toBe('needs_attention')
    expect(controller.locked).toBe(true)
    expect(await controller.start(scenario)).toBe(false)
    await controller.action('stop')
    expect(state.run.state).toBe('stopping')
    expect(controller.locked).toBe(true)
    expect(state.requestFailure.error).toBe('request_not_accepted')
    expect(api.stop).toHaveBeenCalledWith('run-1')
  })

  it('recovers a legacy saved pendingRequest, persists the failure and reloads without resubmitting', async () => {
    state.target = 'A'; controller.save({ pendingRequest: savedRequest }); state.target = ''
    await controller.selectTarget('A')
    expect(api.reconcile).toHaveBeenCalledWith(savedRequest)
    expect(state.status).toBe('failed')
    controller.dispose()
    state = initialRunnerState(); controller = new RunnerController({ api, state, scope: 'DEFAULT' })
    await controller.selectTarget('A')
    expect(state.status).toBe('failed')
    expect(controller.locked).toBe(false)
    expect(api.reconcile).toHaveBeenCalledTimes(1)
    expect(api.start).not.toHaveBeenCalled()
  })

  it('two tabs reconcile the same saved request without either submitting a start', async () => {
    state.target = 'A'; controller.save({ pendingRequest: savedRequest }); state.target = ''
    const otherState = initialRunnerState()
    const other = new RunnerController({ api, state: otherState, scope: 'DEFAULT' })
    try {
      await Promise.all([controller.selectTarget('A'), other.selectTarget('A')])
      expect(api.reconcile.mock.calls).toEqual([[savedRequest], [savedRequest]])
      expect(otherState.requestFailure).toEqual(state.requestFailure)
      expect(other.locked).toBe(false)
      expect(controller.locked).toBe(false)
      expect(api.start).not.toHaveBeenCalled()
    } finally { other.dispose() }
  })

  it('bounds offline retries and resumes the same request on network recovery', async () => {
    await controller.selectTarget('A')
    api.start.mockRejectedValue(new Error('offline'))
    api.reconcile.mockRejectedValue(new Error('offline'))
    await controller.start(scenario)
    const request = state.pendingRequest
    await vi.advanceTimersByTimeAsync(100000)
    expect(api.reconcile).toHaveBeenCalledTimes(1 + RECOVERY_DELAYS.length)
    expect(api.start).toHaveBeenCalledTimes(1)
    expect(state.pendingRequest).toEqual(request)
    expect(controller.locked).toBe(true)
    expect(vi.getTimerCount()).toBe(0)
    api.reconcile.mockImplementation(async (input) => recovered(input))
    window.dispatchEvent(new Event('online'))
    await vi.advanceTimersByTimeAsync(0)
    expect(state.status).toBe('failed')
    expect(controller.locked).toBe(false)
    expect(api.reconcile.mock.lastCall).toEqual([request])
  })

  it('does not overlap recovery calls and ignores late completions and online events after disposal', async () => {
    state.target = 'A'; controller.save({ pendingRequest: savedRequest }); state.target = ''
    const pending = deferred(); api.reconcile.mockReturnValue(pending.promise)
    const discovery = controller.selectTarget('A')
    for (let i = 0; i < 3; i++) { void controller.discover(); window.dispatchEvent(new Event('online')) }
    await vi.advanceTimersByTimeAsync(60000)
    expect(api.reconcile).toHaveBeenCalledTimes(1)
    controller.dispose()
    pending.resolve(recovered(savedRequest)); await discovery
    window.dispatchEvent(new Event('online'))
    await vi.advanceTimersByTimeAsync(60000)
    expect(state.pendingRequest).toEqual(savedRequest)
    expect(state.requestFailure).toBeNull()
    expect(api.reconcile).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('bounds start waiting at 30 seconds and an old response cannot override recovery or a newer run', async () => {
    await controller.selectTarget('A')
    const original = deferred(); api.start.mockReturnValueOnce(original.promise)
    const starting = controller.start(scenario)
    await vi.advanceTimersByTimeAsync(START_WAIT_MS - 1)
    expect(state.starting).toBe(true)
    expect(api.reconcile).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1); await starting
    expect(state.status).toBe('failed')
    expect(state.starting).toBe(false)
    expect(controller.locked).toBe(false)
    api.start.mockResolvedValue({ ...run(), id: 'new-run' })
    api.run.mockResolvedValue({ ...run(), id: 'new-run' })
    await controller.start(scenario)
    original.resolve(run('succeeded')); await vi.advanceTimersByTimeAsync(1)
    expect(state.run.id).toBe('new-run')
    expect(state.status).toBe('running')
    expect(api.start).toHaveBeenCalledTimes(2)
  })

  it('clears start waiting on disposal without recovering or applying its late response', async () => {
    await controller.selectTarget('A')
    const pending = deferred(); api.start.mockReturnValue(pending.promise)
    const starting = controller.start(scenario)
    controller.dispose(); await starting
    pending.resolve(run()); await vi.advanceTimersByTimeAsync(60000)
    expect(api.reconcile).not.toHaveBeenCalled()
    expect(state.run).toBeNull()
    expect(state.pendingRequest).not.toBeNull()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('retains a confirmed failed request during discovery outage and unlocks only after checking other runs', async () => {
    await controller.selectTarget('A')
    api.start.mockRejectedValue(new Error('lost'))
    api.runs.mockRejectedValue(new Error('offline'))
    await controller.start(scenario)
    expect(state.status).toBe('failed')
    expect(state.requestFailure.error).toBe('request_not_accepted')
    expect(state.pendingRequest).toBeNull()
    expect(state.apiConnected).toBe(false)
    expect(controller.locked).toBe(true)
    api.runs.mockResolvedValue({ items: [run()] })
    await vi.advanceTimersByTimeAsync(1000)
    expect(api.reconcile).toHaveBeenCalledTimes(1)
    expect(state.run.state).toBe('running')
    expect(controller.locked).toBe(true)
  })

  it('accepts a fenced response to the original start and ignores unrelated recovery identities', async () => {
    await controller.selectTarget('A')
    api.start.mockImplementation(async (request) => recovered(request))
    await controller.start(scenario)
    expect(state.status).toBe('failed')
    expect(controller.locked).toBe(false)
    api.start.mockRejectedValue(new Error('lost'))
    api.reconcile.mockImplementation(async (request) => recovered({ ...request, request_id: 'wrong-request' }))
    await controller.start(scenario)
    expect(state.pendingRequest).not.toBeNull()
    expect(state.requestFailure).toBeNull()
    expect(controller.locked).toBe(true)
  })

  it('a recovery list captured before stop cannot overwrite the accepted stop response', async () => {
    await controller.selectTarget('A')
    await controller.start(scenario)
    const pending = deferred(); api.runs.mockReturnValue(pending.promise)
    const discovery = controller.discover()
    await controller.action('stop')
    api.run.mockResolvedValue(run('stopping'))
    pending.resolve({ items: [run()] }); await discovery
    expect(state.status).toBe('stopping')
    expect(state.run.state).toBe('stopping')
    expect(controller.locked).toBe(true)
  })
})

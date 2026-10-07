import { ACTIVE_STATUSES, EVENT_PAGE_SIZE, MAX_LOGS, SerialPoller, STORAGE_PREFIX, errorMessage } from './runtime.js'

const terminal = new Set(['succeeded', 'failed', 'stopped'])
export const START_WAIT_MS = 30000
export const RECOVERY_DELAYS = [1000, 2000, 5000, 10000, 30000]
const failedRequest = (run) => run?.state === 'failed' && run.error === 'request_not_accepted'
export function runMatchesScenario(run, scenario, target) {
  return Boolean(run && scenario && run.target === target && run.scenario_id === scenario.id &&
    run.definition_version === scenario.version && run.definition_hash === scenario.definition_hash)
}
export function runStatus(run) {
  if (!run) return 'ready'
  return ({ launching: 'running', running: 'running', waiting: 'waiting_input', stopping: 'stopping', unknown: 'needs_attention', succeeded: 'succeeded', failed: 'failed', stopped: 'stopped' })[run.state] || 'needs_attention'
}
export function initialRunnerState() {
  return { target: '', run: null, status: 'ready', discovering: false, starting: false, acting: false,
    error: '', apiConnected: null, lastContact: null, logs: [], steps: {}, cursor: 0, prompt: null,
    pendingRequest: null, requestFailure: null, recoveryNeeded: false }
}
export class RunnerController {
  constructor({ api, scope, state, storage = localStorage, connection = globalThis.window }) {
    Object.assign(this, { api, scope, state, storage, connection })
    this.generation = 0
    this.disposed = false
    this.poller = null
    this.actionEpoch = 0
    this.discovery = null
    this.recoveryTimer = null
    this.recoveryAttempts = 0
    this.cancelStartWait = null
    this.onOnline = () => {
      if (this.disposed || !this.state.recoveryNeeded) return
      this.recoveryAttempts = 0
      void this.discover()
    }
    connection?.addEventListener('online', this.onOnline)
  }
  get locked() { return Boolean(this.state.starting || this.state.discovering || this.state.pendingRequest ||
    this.state.recoveryNeeded || ACTIVE_STATUSES.has(this.state.status) || (this.state.run && !terminal.has(this.state.run.state))) }
  get key() { return `${STORAGE_PREFIX}.${this.scope}.run.${this.state.target}` }
  save(value) { try { this.storage.setItem(this.key, JSON.stringify(value)) } catch { /* Storage can be disabled. */ } }
  saved() { try { return JSON.parse(this.storage.getItem(this.key) || 'null') } catch { return null } }
  persist() { this.save({ runId: this.state.run?.id, pendingRequest: this.state.pendingRequest, requestFailure: this.state.requestFailure }) }
  current(id) { return !this.disposed && this.generation === id }
  async selectTarget(target) {
    if (this.disposed || this.locked) return false
    this.poller?.stop()
    this.clearRecoveryTimer()
    this.recoveryAttempts = 0
    const id = ++this.generation
    Object.assign(this.state, initialRunnerState(), { target, discovering: true })
    await this.discover(id)
    return true
  }
  discover(id = this.generation, automatic = false) {
    if (!this.current(id) || this.state.starting || this.state.acting) return Promise.resolve()
    if (this.discovery) return this.discovery
    if (!automatic) this.recoveryAttempts = 0
    this.clearRecoveryTimer()
    this.poller?.stop()
    this.discovery = this.discoverOnce(id).finally(() => { this.discovery = null })
    return this.discovery
  }
  async discoverOnce(id) {
    const state = this.state
    const actionEpoch = this.actionEpoch
    if (!state.target) { state.discovering = false; return }
    state.discovering = true
    try {
      const saved = this.saved()
      state.pendingRequest ||= saved?.pendingRequest || null
      state.requestFailure ||= saved?.requestFailure || null
      if (state.pendingRequest) {
        const request = state.pendingRequest
        if (request.target !== state.target || (request.scope && request.scope !== this.scope)) throw new Error('Saved request belongs to a different target or scope.')
        const recovered = await this.api.reconcile(request)
        if (!this.current(id)) return
        this.validateRun(recovered)
        if (['request_id', 'scenario_id', 'definition_version', 'definition_hash'].some((key) => recovered[key] !== request[key])) {
          throw new Error('Recovered request identity does not match the saved request.')
        }
        state.pendingRequest = null
        if (failedRequest(recovered)) {
          state.requestFailure = recovered
          if (!state.run || terminal.has(state.run.state)) { state.run = null; state.prompt = null; state.status = 'failed' }
          this.persist()
        } else this.applyDiscoveredRun(recovered, actionEpoch)
      }
      const result = await this.api.runs(state.target)
      if (!this.current(id)) return
      let run = result.items.find((item) => !terminal.has(item.state))
      // A list miss is not evidence that a known execution terminated.
      run ||= state.run
      if (!run && saved?.runId) run = await this.api.run(saved.runId)
      if (!this.current(id)) return
      if (run) this.validateRun(run)
      state.recoveryNeeded = false
      this.recoveryAttempts = 0
      state.error = ''; state.apiConnected = true; state.lastContact = Date.now()
      if (run) { this.applyDiscoveredRun(run, actionEpoch); this.beginPolling(id) }
      else { state.status = state.requestFailure ? 'failed' : 'ready'; this.persist() }
    } catch (error) {
      if (this.current(id)) {
        state.apiConnected = false; state.recoveryNeeded = true
        if (!state.run) state.status = state.requestFailure ? 'failed' : 'needs_attention'
        state.error = `Recovery unavailable: ${errorMessage(error)}`
      }
    } finally {
      if (this.current(id)) {
        state.discovering = false
        if (state.recoveryNeeded) this.scheduleRecovery(id)
      }
    }
  }
  validateRun(run) {
    if (!run || run.target !== this.state.target || run.scope !== this.scope) throw new Error('Recovered run belongs to a different target or scope.')
  }
  applyDiscoveredRun(run, actionEpoch) {
    if (run.id === this.state.run?.id && (actionEpoch !== this.actionEpoch || this.state.acting)) return
    this.applyRun(run)
  }
  clearRecoveryTimer() { clearTimeout(this.recoveryTimer); this.recoveryTimer = null }
  scheduleRecovery(id) {
    if (this.recoveryTimer !== null || this.recoveryAttempts >= RECOVERY_DELAYS.length) return
    const delay = RECOVERY_DELAYS[this.recoveryAttempts++]
    this.recoveryTimer = setTimeout(() => {
      this.recoveryTimer = null
      if (this.current(id) && this.state.recoveryNeeded) void this.discover(id, true)
    }, delay)
  }
  waitForStart(request) {
    // Bound UI waiting, not server execution. Reconciliation fences any late
    // admission; the original response is consumed but cannot change UI state.
    return new Promise((resolve, reject) => {
      let timer
      const finish = (complete, value) => {
        clearTimeout(timer)
        if (this.cancelStartWait === cancel) this.cancelStartWait = null
        complete(value)
      }
      const cancel = () => finish(reject, new Error('Start wait disposed.'))
      this.cancelStartWait = cancel
      timer = setTimeout(() => finish(reject, new Error('Start response timed out; recovering request.')), START_WAIT_MS)
      try { Promise.resolve(this.api.start(request)).then((run) => finish(resolve, run), (error) => finish(reject, error)) }
      catch (error) { finish(reject, error) }
    })
  }
  async start(scenario) {
    const state = this.state
    if (this.disposed || this.locked || !scenario || !scenario.supportedTargets.includes(state.target)) return false
    const id = this.generation
    this.poller?.stop()
    this.clearRecoveryTimer()
    state.starting = true; state.error = ''; state.logs = []; state.steps = {}; state.cursor = 0
    state.run = null; state.prompt = null; state.requestFailure = null
    const request = { scenario_id: scenario.id, definition_version: scenario.version, definition_hash: scenario.definition_hash,
      target: state.target, request_id: crypto.randomUUID() }
    state.pendingRequest = request
    this.save({ pendingRequest: request })
    try {
      const run = await this.waitForStart(request)
      if (!this.current(id)) return false
      this.validateRun(run)
      state.pendingRequest = null
      if (failedRequest(run)) {
        state.requestFailure = run; state.status = 'failed'; this.persist()
        state.starting = false
        await this.discover(id)
        return false
      }
      this.applyRun(run)
      state.apiConnected = true; state.lastContact = Date.now()
      this.beginPolling(id)
      return true
    } catch (error) {
      if (!this.current(id)) return false
      state.error = errorMessage(error)
      // A received 4xx is a definite rejection; network/5xx may hide an accepted start.
      const code = error?.response?.status
      if (code >= 400 && code < 500 && code !== 408) {
        state.pendingRequest = null
        this.persist()
        state.status = 'ready'
        state.starting = false
        if (code === 409) await this.discover(id)
      } else {
        state.status = 'needs_attention'; state.apiConnected = false; state.recoveryNeeded = true
        state.starting = false
        await this.discover(id)
      }
      return false
    } finally { if (this.current(id)) state.starting = false }
  }
  applyRun(run) {
    if (this.state.run?.id !== run.id) { this.state.logs = []; this.state.steps = {}; this.state.cursor = 0 }
    this.state.run = run
    this.state.status = runStatus(run)
    this.state.prompt = run.prompt?.status === 'pending' ? run.prompt : null
    this.persist()
  }
  applyEvents(result) {
    const fresh = result.items.filter((event) => event.id > this.state.cursor)
    for (const event of fresh) {
      if (event.type === 'step' && event.data?.step_id) this.state.steps[event.data.step_id] = event.data
    }
    this.state.logs = [...this.state.logs, ...fresh].slice(-MAX_LOGS)
    this.state.cursor = Math.max(this.state.cursor, result.next_cursor || 0)
  }
  beginPolling(id) {
    this.poller?.stop()
    this.poller = new SerialPoller(async (current) => {
      const actionEpoch = this.actionEpoch
      const runId = this.state.run?.id
      if (!runId) return
      const [run, events] = await Promise.all([this.api.run(runId), this.api.events(runId, this.state.cursor)])
      if (!current() || !this.current(id)) return
      if (actionEpoch === this.actionEpoch && !this.state.acting) this.applyRun(run)
      this.applyEvents(events)
      this.state.apiConnected = true; this.state.lastContact = Date.now(); this.state.error = ''
      // Drain a full page before stopping so terminal runs retain their final logs.
      if (terminal.has(this.state.run.state) && events.items.length < EVENT_PAGE_SIZE) this.poller.stop()
    }, { onError: (error) => {
      if (!this.current(id)) return
      this.state.apiConnected = false
      this.state.error = `Run updates disconnected: ${errorMessage(error)}`
      // Preserve run state and lock; transport loss is never a completed run.
    } })
    this.poller.start()
  }
  async action(kind, answer) {
    const state = this.state, id = this.generation
    if (this.disposed || state.acting || !state.run || terminal.has(state.run.state) || (kind !== 'stop' && !state.prompt)) return
    state.acting = true
    this.actionEpoch++
    const runId = state.run.id
    try {
      const run = kind === 'stop' ? await this.api.stop(runId) : await this.api.answer(runId, state.prompt.prompt_id, answer)
      if (!this.current(id) || state.run?.id !== runId) return
      this.applyRun(run); state.apiConnected = true; state.lastContact = Date.now(); state.error = ''
    } catch (error) { if (this.current(id)) state.error = errorMessage(error) }
    finally { if (this.current(id)) state.acting = false }
  }
  dispose() {
    this.disposed = true; this.generation++; this.poller?.stop(); this.clearRecoveryTimer()
    this.cancelStartWait?.()
    this.connection?.removeEventListener('online', this.onOnline)
  }
}

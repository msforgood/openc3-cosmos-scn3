export const ACTIVE_STATUSES = new Set(['running', 'waiting_input', 'stopping', 'needs_attention'])
export const RUN_STATUSES = new Set(['ready', ...ACTIVE_STATUSES, 'succeeded', 'failed', 'stopped'])
export const MAX_LOGS = 1000
export const EVENT_PAGE_SIZE = 100
export const STORAGE_PREFIX = 'openc3.scenariorunner.v1'

export function supportedTargets(installed, scenarios) {
  const supported = new Set(scenarios.flatMap((s) => (s.supportedTargets || []).filter((target) => !s.permittedTargets || s.permittedTargets.includes(target))))
  return [...new Set(installed)].filter((target) => supported.has(target)).sort()
}

// This time is decoded from the packet's RECEIVED_TIMESECONDS item, never Date.now().
export function packetReceipt(values) {
  const seconds = values.map((v) => Number(v?.[0])).filter((v) => Number.isFinite(v) && v > 0)
  return seconds.length ? Math.max(...seconds) * 1000 : null
}

export function communicationStatus({ connected, lastReceipt, lastSuccess }, now, staleMs = 10000) {
  if (connected === false || (lastSuccess !== null && now - lastSuccess > staleMs)) return 'disconnected'
  if (lastReceipt === null) return 'no_data'
  if (lastReceipt > now + 5000 || now - lastReceipt > staleMs) return 'delayed'
  return 'live'
}

// A recursive timeout serializes slow requests. stop() invalidates late completions.
export class SerialPoller {
  constructor(work, { interval = 1000, onError = () => {} } = {}) {
    this.work = work
    this.interval = interval
    this.onError = onError
    this.generation = 0
    this.timer = null
    this.running = false
  }
  start() {
    if (this.running) return
    this.running = true
    const generation = ++this.generation
    const current = () => this.running && this.generation === generation
    const tick = async () => {
      try { await this.work(current) } catch (error) { if (current()) this.onError(error) }
      if (current()) this.timer = setTimeout(tick, this.interval)
    }
    void tick()
  }
  stop() {
    this.running = false
    this.generation++
    clearTimeout(this.timer)
    this.timer = null
  }
}

// Every target owns a distinct Cable. Late auth/subscription resolution cannot
// attach itself to the next target or leave a newly-created socket behind.
export class TargetLimitsSubscription {
  constructor({ createCable, scope, target, onEvents, onConnection }) {
    this.cable = createCable()
    this.active = true
    this.subscription = null
    const current = () => this.active
    this.ready = this.cable.createSubscription('LimitsEventsChannel', scope, {
      connected: () => { if (current()) onConnection(true) },
      disconnected: () => { if (current()) onConnection(false) },
      rejected: () => { if (current()) onConnection(false) },
      received: (messages) => {
        if (!current() || !Array.isArray(messages)) return
        const selected = []
        for (const message of messages.slice(-MAX_LOGS)) {
          try {
            const event = typeof message.event === 'string' ? JSON.parse(message.event) : message.event
            // Never infer a target from free-form text or include global settings.
            if (event?.target_name === target && event.type === 'LIMITS_CHANGE') selected.push(event)
          } catch { /* Invalid event must not break the subscription. */ }
        }
        if (selected.length) onEvents(selected)
      },
    }, { history_count: MAX_LOGS }).then((subscription) => {
      if (current()) this.subscription = subscription
      else { subscription.unsubscribe(); this.cable.disconnect() }
    }).catch(() => { if (current()) onConnection(false) })
  }
  dispose() {
    this.active = false
    this.subscription?.unsubscribe()
    this.subscription = null
    this.cable.disconnect()
  }
}

export function errorMessage(error) {
  return error?.response?.data?.error?.message || error?.response?.data?.detail || error?.message || String(error)
}

export function formatTime(value) {
  if (!value) return '—'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? '—' : date.toLocaleString()
}

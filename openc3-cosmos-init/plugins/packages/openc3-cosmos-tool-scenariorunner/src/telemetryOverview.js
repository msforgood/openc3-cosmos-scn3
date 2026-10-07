// Read-only interpretations of OpenC3 6.10.1 CVT pairs and get_tlm item metadata.
export const MAX_OVERVIEW_ITEMS = 24
export const MAX_SAMPLES = 30
export const METADATA_INTERVAL = 30000
export const STALE_MS = 10000
export const itemKey = (item) => `${item.packet}__${item.name || item.item}`
const finite = (value) => typeof value === 'number' && Number.isFinite(value)
const numeric = (value) => finite(value) && (!Number.isInteger(value) || Number.isSafeInteger(value)) ? value : null

export function overviewItems(items, scenarioItems = []) {
  const visible = items.filter(({ item }) => !/^(RECEIVED_|PACKET_|BUFFER$)/.test(item))
  const preferred = new Set(scenarioItems.map(itemKey))
  const ordered = [...visible.filter((item) => preferred.has(itemKey(item))), ...visible.filter((item) => !preferred.has(itemKey(item)))]
  return { items: ordered.slice(0, MAX_OVERVIEW_ITEMS), total: ordered.length }
}

// There is no timestamp or counter in this pair. Never interpret tuple[2] as one.
export function telemetryPair(tuple, index = null) {
  let value = Array.isArray(tuple) ? tuple[0] : null
  if (index !== null) value = Array.isArray(value) ? value[index] : null
  return { value: value ?? null, numeric: numeric(value), state: typeof tuple?.[1] === 'string' ? tuple[1] : null }
}

export function displayValue(value) {
  if (value === null || value === undefined) return '—'
  if (typeof value === 'object') {
    if (value.raw) return String(value.raw)
    if (Array.isArray(value)) return `[${value.slice(0, 8).map(displayValue).join(', ')}${value.length > 8 ? ', …' : ''}]`
    return 'Unsupported value'
  }
  return String(value).slice(0, 160)
}

export function itemLimits(metadata, currentSet) {
  if (!metadata || !currentSet) return { known: false, configured: false, enabled: false, thresholds: null, set: null }
  const limits = metadata.limits || {}
  const set = Object.hasOwn(limits, currentSet) ? currentSet : 'DEFAULT'
  const values = limits[set]
  const stateLimits = Object.values(metadata.states || {}).some((state) => typeof state?.color === 'string')
  const configured = !!values || stateLimits
  let thresholds = null
  if (values && typeof values === 'object' && !Array.isArray(values)) {
    thresholds = ['red_low', 'yellow_low', 'yellow_high', 'red_high'].map((name) => values[name])
    if (values.green_low !== undefined || values.green_high !== undefined) thresholds.push(values.green_low, values.green_high)
  }
  return { known: true, configured, enabled: typeof limits.enabled === 'boolean' ? limits.enabled : null, thresholds, set, stateLimits }
}

export function limitsGauge(thresholds, value) {
  if (!Array.isArray(thresholds) || ![4, 6].includes(thresholds.length) || !thresholds.every(finite)) return null
  const [rl, yl, yh, rh, gl, gh] = thresholds
  if (!(rl <= yl && yl <= yh && yh <= rh) || (thresholds.length === 6 && !(yl <= gl && gl <= gh && gh <= yh))) return null
  // Fixed linear domain anchored in actual thresholds, including small, explicit
  // overflow tails. Equal thresholds have no honest numeric scale: show text.
  const span = rh - rl
  if (!finite(span) || span <= 0) return null
  const min = rl - span / 8, max = rh + span / 8, width = max - min
  if (![min, max, width].every(finite) || width <= 0) return null
  const position = (v) => Math.max(0, Math.min(100, (v - min) / width * 100))
  const boundaries = thresholds.length === 6 ? [min, rl, yl, gl, gh, yh, rh, max] : [min, rl, yl, yh, rh, max]
  const colors = thresholds.length === 6 ? ['alarm', 'caution', 'within', 'blue', 'within', 'caution', 'alarm'] : ['alarm', 'caution', 'within', 'caution', 'alarm']
  const segments = colors.map((color, i) => ({ color, width: position(boundaries[i + 1]) - position(boundaries[i]) }))
  const pointer = numeric(value) === null ? null : position(value)
  const overflow = pointer === null ? '' : value < min ? 'Below scale' : value > max ? 'Above scale' : ''
  const labels = ['RL', 'YL', 'YH', 'RH', 'GL', 'GH']
  return { min, max, segments, pointer, overflow, description: thresholds.map((v, i) => `${labels[i]} ${v}`).join(' · ') }
}

export function itemStatus({ pair, receipt, connected, lastSuccess, metadata, limitsSet }, now) {
  const status = (kind, label, icon) => ({ kind, label, icon })
  if (connected === false || (lastSuccess !== null && now - lastSuccess > STALE_MS)) return status('disconnected', 'Disconnected', '×')
  if (pair.state === 'STALE' || (receipt !== null && (now - receipt > STALE_MS || receipt > now + 5000))) return status('stale', 'Stale', '◷')
  if (connected !== true || receipt === null || pair.value === null || (typeof pair.value === 'number' && !finite(pair.value)) || typeof pair.value === 'object') return status('unknown', 'No data', '?')
  const limits = itemLimits(metadata, limitsSet)
  if (!limits.known) return status('unknown', 'Limits unknown', '?')
  if (!limits.configured) return status('unconfigured', 'No limits', '—')
  if (limits.enabled === false) return status('disabled', 'Limits disabled', '⊘')
  if (limits.enabled !== true) return status('unknown', 'Limits enable state unknown', '?')
  if (['RED', 'RED_LOW', 'RED_HIGH'].includes(pair.state)) return status('alarm', `Alarm · ${pair.state}`, '!')
  if (['YELLOW', 'YELLOW_LOW', 'YELLOW_HIGH'].includes(pair.state)) return status('caution', `Caution · ${pair.state}`, '△')
  if (['GREEN', 'GREEN_LOW', 'GREEN_HIGH'].includes(pair.state)) return status('within', 'Within limits', '✓')
  if (pair.state === 'BLUE') return status('within', 'Within limits · BLUE', '◆')
  return status('unknown', 'State unknown', '?')
}

export function appendSample(samples, value, receipt, now, fresh = true) {
  if (!fresh || numeric(value) === null || !finite(receipt) || receipt > now + 5000 || now - receipt > STALE_MS || (samples.length && receipt <= samples.at(-1).time)) return samples
  return [...samples, { time: receipt, value }].slice(-MAX_SAMPLES)
}

export function sampleTrend(samples) {
  if (!samples.length) return null
  const min = Math.min(...samples.map((s) => s.value)), max = Math.max(...samples.map((s) => s.value))
  const start = samples[0].time, duration = samples.at(-1).time - start
  const span = max - min
  if (!finite(span) || !finite(duration)) return null
  return {
    min, max, count: samples.length,
    points: samples.map((s) => `${duration ? (s.time - start) / duration * 100 : 50},${span ? 26 - (s.value - min) / span * 22 : 15}`).join(' '),
  }
}

export function countStates(rows) {
  const counts = { alarm: 0, caution: 0, within: 0, unconfigured: 0, stale: 0, disconnected: 0, disabled: 0, unknown: 0 }
  for (const row of rows) counts[row.status.kind]++
  return counts
}

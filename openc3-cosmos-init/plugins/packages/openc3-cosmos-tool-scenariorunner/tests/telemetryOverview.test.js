import { describe, expect, it } from 'vitest'
import { appendSample, countStates, displayValue, itemLimits, itemStatus, limitsGauge, overviewItems, sampleTrend, telemetryPair } from '../src/telemetryOverview.js'

const metadata = { units: 'V', limits: { enabled: true, DEFAULT: { red_low: -10, yellow_low: -5, yellow_high: 30, red_high: 50 } } }
const now = 1790467200000
const live = { pair: telemetryPair([0, 'GREEN']), receipt: now, connected: true, lastSuccess: now, metadata, limitsSet: 'DEFAULT' }

it('reads the real value/state pair, preserves zero/null/strings, and never fabricates timestamps', () => {
  expect(telemetryPair([0, null])).toEqual({ value: 0, numeric: 0, state: null })
  expect(telemetryPair([12, 'RED_HIGH', 999])).toEqual({ value: 12, numeric: 12, state: 'RED_HIGH' })
  expect(telemetryPair(['12.5 V', 'GREEN']).numeric).toBeNull()
  expect(telemetryPair(['12', null]).numeric).toBeNull()
  expect(telemetryPair([null, 'GREEN']).numeric).toBeNull()
  expect(telemetryPair([[1, 2], null], 1).numeric).toBe(2)
  expect(telemetryPair([9007199254740993n, null]).numeric).toBeNull()
  expect(displayValue(9007199254740993n)).toBe('9007199254740993')
})

it('reads named thresholds, explicit enabled and enum colors; falls back to DEFAULT like BarColumn', () => {
  expect(itemLimits(metadata, 'TVAC')).toMatchObject({ known: true, configured: true, enabled: true, set: 'DEFAULT', thresholds: [-10, -5, 30, 50] })
  expect(itemLimits({ limits: {} }, 'DEFAULT')).toMatchObject({ known: true, configured: false })
  expect(itemLimits({ limits: { enabled: true }, states: { OK: { color: 'GREEN' } } }, 'DEFAULT')).toMatchObject({ configured: true, stateLimits: true, thresholds: null })
  expect(itemLimits(undefined, 'DEFAULT').known).toBe(false)
})

describe('fixed actual-limit gauge', () => {
  it('uses proportional negative/asymmetric ranges and clamps overflow with an explicit label', () => {
    const gauge = limitsGauge([-10, -5, 30, 50], 0)
    expect(gauge.min).toBe(-17.5)
    expect(gauge.max).toBe(57.5)
    expect(gauge.pointer).toBeCloseTo(23.333333)
    expect(gauge.segments.map((s) => s.color)).toEqual(['alarm', 'caution', 'within', 'caution', 'alarm'])
    expect(gauge.segments.reduce((sum, s) => sum + s.width, 0)).toBeCloseTo(100)
    expect(limitsGauge([-10, -5, 30, 50], -100)).toMatchObject({ pointer: 0, overflow: 'Below scale' })
    expect(limitsGauge([-10, -5, 30, 50], 100)).toMatchObject({ pointer: 100, overflow: 'Above scale' })
    expect(limitsGauge([-10, -5, 30, 50], null).pointer).toBeNull()
  })
  it('handles optional blue band and equal adjacent thresholds without mutating metadata', () => {
    const thresholds = [-10, -10, 50, 50, 0, 20]
    const gauge = limitsGauge(thresholds, 0)
    expect(gauge.segments[1].width).toBe(0)
    expect(gauge.segments[3].color).toBe('blue')
    expect(thresholds).toEqual([-10, -10, 50, 50, 0, 20])
  })
  it.each([[0, 0, 0, 0], [0, 2, 1, 4], [0, 1, 2, Infinity], [null, 1, 2, 3], [0, 1, 2, 3, -1, 2], [0, 1, 2], [0, 1, 2, 3, 2], [-1e308, 0, 1, 1e308]])('refuses a deceptive or invalid scale %j', (...values) => {
    expect(limitsGauge(values, 0)).toBeNull()
  })
})

it.each([
  [{ connected: false }, 'disconnected'], [{ lastSuccess: now - 11000 }, 'disconnected'],
  [{ receipt: now - 11000 }, 'stale'], [{ receipt: now + 6000 }, 'stale'],
  [{ receipt: null }, 'unknown'], [{ pair: telemetryPair([null, 'GREEN']) }, 'unknown'],
  [{ pair: telemetryPair([NaN, 'GREEN']) }, 'unknown'], [{ pair: telemetryPair([0, 'STALE']) }, 'stale'],
  [{ pair: telemetryPair([{ raw: 'NaN' }, 'GREEN']) }, 'unknown'],
  [{ metadata: { limits: { DEFAULT: metadata.limits.DEFAULT } } }, 'unknown'],
  [{ metadata: { limits: {} } }, 'unconfigured'], [{ metadata: undefined }, 'unknown'],
  [{ metadata: { ...metadata, limits: { ...metadata.limits, enabled: false } } }, 'disabled'],
  [{ pair: telemetryPair([0, 'PURPLE']) }, 'unknown'], [{ pair: telemetryPair([0, null]) }, 'unknown'],
  [{ pair: telemetryPair([0, 'RED_LOW']) }, 'alarm'], [{ pair: telemetryPair([0, 'YELLOW_HIGH']) }, 'caution'],
  [{ pair: telemetryPair([0, 'BLUE']) }, 'within'],
])('never promotes stale/unknown/disabled data to healthy: %j', (overrides, kind) => {
  expect(itemStatus({ ...live, ...overrides }, now).kind).toBe(kind)
})

it('counts only supplied displayed rows and separates no-limits from within-limits', () => {
  expect(countStates([{ status: itemStatus(live, now) }, { status: itemStatus({ ...live, metadata: { limits: {} } }, now) }])).toEqual({ alarm: 0, caution: 0, within: 1, unconfigured: 1, stale: 0, disconnected: 0, disabled: 0, unknown: 0 })
})

it('prioritizes scenario items that are actually displayed, omits reserved headers, caps rows', () => {
  const items = ['RECEIVED_TIMESECONDS', 'PACKET_TIMEFORMATTED', 'BUFFER', ...Array.from({ length: 40 }, (_, i) => `ITEM${i}`)].map((item) => ({ packet: 'HK', item }))
  const selection = overviewItems(items, [{ packet: 'HK', item: 'ITEM39' }, { packet: 'HIDDEN', item: 'INJECTED' }])
  expect(selection.total).toBe(40)
  expect(selection.items).toHaveLength(24)
  expect(selection.items[0].item).toBe('ITEM39')
  expect(selection.items.some((row) => row.item === 'INJECTED')).toBe(false)
})

it('bounds neutral trends to 30 fresh packet receipts, ignoring repeated/stale/backward cache reads', () => {
  let samples = []
  for (let i = 0; i < 50; i++) samples = appendSample(samples, i, now + i * 1000, now + i * 1000)
  expect(samples).toHaveLength(30)
  expect(samples[0].value).toBe(20)
  for (const [value, receipt, tick, fresh] of [[99, now + 49000, now + 50000, true], [99, now, now + 50000, true], [99, now + 99000, now, true], [null, now + 50000, now + 50000, true], [99, now + 50000, now + 50000, false]]) {
    expect(appendSample(samples, value, receipt, tick, fresh)).toBe(samples)
  }
  expect(sampleTrend(samples)).toMatchObject({ min: 20, max: 49, count: 30 })
  expect(sampleTrend([{ value: 0, time: now }, { value: 0, time: now + 1000 }]).points).toBe('0,15 100,15')
  expect(sampleTrend([{ value: 0, time: now }]).points).toBe('50,15')
})

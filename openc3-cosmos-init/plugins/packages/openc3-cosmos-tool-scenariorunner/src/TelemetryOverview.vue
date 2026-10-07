<template>
  <section class="telemetry-overview" aria-label="Displayed telemetry overview" data-test="telemetry-overview">
    <div class="overview-heading">
      <h3>Telemetry overview</h3>
      <span class="small muted" data-test="limits-set">Limits set: <strong>{{ limitsSet || 'Unknown' }}</strong> · read-only</span>
    </div>
    <p class="small muted" data-test="overview-scope">{{ target }} / {{ screen }} · {{ rows.length }} of {{ total }} eligible screen items<span v-if="total > rows.length"> (24-row cap)</span></p>
    <p class="small muted">Counts apply only to these displayed items. Times are packet receipts; trends are observed samples, not limits.</p>
    <div class="overview-counts" aria-label="Displayed item state counts" data-test="overview-counts">
      <span v-for="entry in summaries" :key="entry.kind" :class="['overview-count', `state-${entry.kind}`]">
        {{ entry.icon }} {{ entry.label }} <strong>{{ counts[entry.kind] }}</strong>
      </span>
    </div>
    <p v-if="metadataError" class="small error-text" role="status">Limits metadata unavailable; retrying. Values and receipt monitoring continue.</p>
    <div v-if="rows.length" class="overview-scroll" tabindex="0" aria-label="Telemetry items; scroll for remaining rows">
      <table class="overview-table">
        <thead><tr><th scope="col">Item / packet receipt</th><th scope="col">Value</th><th scope="col">State</th><th scope="col">Limits / recent samples</th></tr></thead>
        <tbody>
          <tr v-for="row in rows" :key="row.key" data-test="overview-row" :data-state="row.status.kind">
            <th scope="row"><strong>{{ row.name }}</strong><span class="small muted">{{ row.packet }}</span><time class="small muted" :datetime="receiptDateTime(row.receipt)">{{ formatTime(row.receipt) }}</time></th>
            <td :class="['overview-value', `state-${row.status.kind}`]"><span>{{ row.display }}</span><span v-if="row.units" class="small muted">{{ row.units }}</span></td>
            <td><span :class="['overview-state', `state-${row.status.kind}`]" data-test="item-state">{{ row.status.icon }} {{ row.status.label }}</span></td>
            <td>
              <div v-if="row.gauge" class="overview-gauge" :class="{ 'gauge-inactive': !['alarm', 'caution', 'within'].includes(row.status.kind) }" role="img"
                :aria-label="`${row.gauge.description}; converted value ${row.numeric ?? 'unavailable'}; scale ${row.gauge.min} to ${row.gauge.max}; ${row.gauge.overflow}`" :title="row.gauge.description" data-test="limits-gauge">
                <div class="gauge-track"><span v-for="(segment, index) in row.gauge.segments" :key="index" :class="`segment-${segment.color}`" :style="{ width: `${segment.width}%` }" /></div>
                <span v-if="row.gauge.pointer !== null" class="gauge-pointer" :style="{ left: `${row.gauge.pointer}%` }" />
                <div class="gauge-endpoints"><span>{{ row.gauge.min }}</span><span>{{ row.gauge.max }}</span></div>
              </div>
              <span v-if="row.gauge" class="small muted gauge-description">{{ row.gauge.description }}<template v-if="row.limits.set !== limitsSet"> · {{ row.limits.set }} fallback</template></span>
              <strong v-if="row.gauge?.overflow" class="small">{{ row.gauge.overflow }} · pointer clamped</strong>
              <template v-if="!row.gauge">
                <svg v-if="row.trend" viewBox="0 0 100 30" class="sample-trend" role="img" :aria-label="`Observed values ${row.trend.min} to ${row.trend.max}, ${row.trend.count} fresh samples; not a normal range`" data-test="sample-trend">
                  <polyline :points="row.trend.points" fill="none" stroke="currentColor" stroke-width="1.5" vector-effect="non-scaling-stroke" />
                  <circle v-if="row.trend.count === 1" cx="50" cy="15" r="2" fill="currentColor" />
                </svg>
                <span class="small muted gauge-description">{{ row.limits.thresholds ? 'No valid numeric scale' : row.limits.configured ? 'State limits · no numeric range' : row.limits.known ? 'No numeric limits' : 'Limits unknown' }}</span>
                <span v-if="row.trend" class="small muted gauge-description">Observed {{ row.trend.min }}–{{ row.trend.max }} · {{ row.trend.count }}/30 samples</span>
                <span v-else class="small muted gauge-description">{{ row.numeric === null ? 'No numeric sample' : 'Waiting for fresh samples' }}</span>
              </template>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <p v-else class="empty">No eligible item references in this screen.</p>
  </section>
</template>

<script setup>
import { computed } from 'vue'
import { formatTime } from './runtime.js'
import { countStates } from './telemetryOverview.js'
const props = defineProps({ target: String, screen: String, rows: { type: Array, default: () => [] }, total: Number, limitsSet: String, metadataError: Boolean })
const counts = computed(() => countStates(props.rows))
function receiptDateTime(receipt) {
  const date = new Date(receipt)
  return receipt && Number.isFinite(date.getTime()) ? date.toISOString() : undefined
}
const summaries = [
  { kind: 'alarm', label: 'Alarm', icon: '!' }, { kind: 'caution', label: 'Caution', icon: '△' },
  { kind: 'within', label: 'Within limits', icon: '✓' }, { kind: 'unconfigured', label: 'No limits', icon: '—' },
  { kind: 'stale', label: 'Stale', icon: '◷' }, { kind: 'disconnected', label: 'Disconnected', icon: '×' },
  { kind: 'disabled', label: 'Disabled', icon: '⊘' }, { kind: 'unknown', label: 'Unknown', icon: '?' },
]
</script>

<style scoped>
.telemetry-overview { margin-top: 16px; padding: 12px; border: 1px solid var(--sr-border, #435265); border-radius: 6px; background: #111e2c; }
.overview-heading { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; flex-wrap: wrap; }
.overview-heading h3 { font-size: 15px; }
.overview-counts { display: flex; flex-wrap: wrap; gap: 5px 10px; margin: 9px 0; }
.overview-count { font-size: 11px; }
.overview-count strong { margin-left: 3px; }
.state-alarm { color: #ffb0a8; }
.state-caution { color: #ffdb91; }
.state-within { color: #96e8b6; }
.state-unconfigured, .state-disabled, .state-unknown { color: #bfccdc; }
.state-stale { color: #dbb9ff; }
.state-disconnected { color: #ffb0a8; }
.overview-scroll { max-height: 265px; overflow: auto; margin-top: 10px; scrollbar-gutter: stable; }
.overview-scroll:focus-visible { outline: 2px solid #9dcfff; outline-offset: 2px; }
.overview-table { width: 100%; border-collapse: collapse; font-size: 12px; text-align: left; table-layout: fixed; }
.overview-table th, .overview-table td { padding: 9px 7px; border-bottom: 1px solid #354458; vertical-align: top; overflow-wrap: anywhere; }
.overview-table thead th { position: sticky; top: 0; z-index: 2; background: #26364a; font-size: 11px; }
.overview-table th:nth-child(1) { width: 30%; }
.overview-table th:nth-child(2) { width: 13%; }
.overview-table th:nth-child(3) { width: 23%; }
.overview-table th:nth-child(4) { width: 34%; }
.overview-table tbody th { font-weight: normal; }
.overview-table tbody th > *, .overview-value > * { display: block; }
.overview-table time { margin-top: 5px; font-size: 10px; }
.overview-value { font-variant-numeric: tabular-nums; font-size: 14px; }
.overview-state { display: inline-block; padding: 3px 5px; border: 1px solid currentColor; border-radius: 4px; font-size: 10px; }
.overview-gauge { position: relative; margin: 6px 0 4px; }
.gauge-track { display: flex; height: 9px; background: #526277; }
.segment-alarm { background: #e57e78; }.segment-caution { background: #ddbc61; }.segment-within { background: #6ebc8a; }.segment-blue { background: #68b8e8; }
.gauge-inactive .gauge-track { filter: grayscale(1); opacity: .45; }
.gauge-pointer { position: absolute; top: -5px; height: 18px; width: 2px; background: #fff; transform: translateX(-1px); }
.gauge-pointer::before { content: ''; position: absolute; top: 0; left: -3px; border-left: 4px solid transparent; border-right: 4px solid transparent; border-top: 4px solid white; }
.gauge-endpoints { display: flex; justify-content: space-between; font-size: 9px; padding-top: 4px; }
.gauge-description { display: block; font-size: 10px; line-height: 1.4; }
.sample-trend { width: 100%; height: 25px; display: block; color: #b9c8da; background: #1c2b3d; }
@media (max-width: 560px) { .overview-table { min-width: 530px; }.telemetry-overview { padding: 8px; } }
</style>

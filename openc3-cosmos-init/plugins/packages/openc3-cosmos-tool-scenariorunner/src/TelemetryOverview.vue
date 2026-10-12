<template>
  <section class="telemetry-overview" aria-label="표시된 텔레메트리 개요" data-test="telemetry-overview">
    <div class="overview-heading">
      <h3>텔레메트리 개요</h3>
      <span class="small muted" data-test="limits-set">Limits 설정: <strong>{{ limitsSet || '알 수 없음' }}</strong> · 읽기 전용</span>
    </div>
    <p class="small muted" data-test="overview-scope">{{ target }} / {{ screen }} · 표시 항목 {{ rows.length }} / {{ total }}개<span v-if="total > rows.length"> (최대 24개)</span></p>
    <p class="small muted">아래 상태 건수는 표시된 항목만 집계합니다. 시각은 패킷 수신 시각이며, 추세는 관측값을 나타냅니다.</p>
    <div class="overview-counts" aria-label="표시 항목 상태 건수" data-test="overview-counts">
      <span v-for="entry in summaries" :key="entry.kind" :class="['overview-count', `state-${entry.kind}`]">
        {{ entry.icon }} {{ entry.label }} <strong>{{ counts[entry.kind] }}</strong>
      </span>
    </div>
    <p v-if="metadataError" class="small error-text" role="status">Limits 메타데이터를 가져올 수 없습니다. 다시 시도하는 동안 값과 수신 상태는 계속 확인합니다.</p>
    <div v-if="rows.length" class="overview-scroll" tabindex="0" aria-label="텔레메트리 항목 목록, 스크롤하면 나머지 항목 표시">
      <table class="overview-table">
        <thead><tr><th scope="col">항목 / 패킷 수신</th><th scope="col">값</th><th scope="col">상태</th><th scope="col">Limits / 최근 샘플</th></tr></thead>
        <tbody>
          <tr v-for="row in rows" :key="row.key" data-test="overview-row" :data-state="row.status.kind">
            <th scope="row"><strong>{{ row.name }}</strong><span class="small muted">{{ row.packet }}</span><time class="small muted" :datetime="receiptDateTime(row.receipt)">{{ formatTime(row.receipt) }}</time></th>
            <td :class="['overview-value', `state-${row.status.kind}`]"><span>{{ row.display }}</span><span v-if="row.units" class="small muted">{{ row.units }}</span></td>
            <td><span :class="['overview-state', `state-${row.status.kind}`]" data-test="item-state">{{ row.status.icon }} {{ row.status.label }}</span></td>
            <td>
              <div v-if="row.gauge" class="overview-gauge" :class="{ 'gauge-inactive': !['alarm', 'caution', 'within'].includes(row.status.kind) }" role="img"
                :aria-label="`${row.gauge.description}; 변환된 값 ${row.numeric ?? '없음'}; 눈금 ${row.gauge.min}~${row.gauge.max}; ${row.gauge.overflow}`" :title="row.gauge.description" data-test="limits-gauge">
                <div class="gauge-track"><span v-for="(segment, index) in row.gauge.segments" :key="index" :class="`segment-${segment.color}`" :style="{ width: `${segment.width}%` }" /></div>
                <span v-if="row.gauge.pointer !== null" class="gauge-pointer" :style="{ left: `${row.gauge.pointer}%` }" />
                <div class="gauge-endpoints"><span>{{ row.gauge.min }}</span><span>{{ row.gauge.max }}</span></div>
              </div>
              <span v-if="row.gauge" class="small muted gauge-description">{{ row.gauge.description }}<template v-if="row.limits.set !== limitsSet"> · {{ row.limits.set }} 설정 사용</template></span>
              <strong v-if="row.gauge?.overflow" class="small">{{ row.gauge.overflow }} · 표시 위치를 눈금 끝에 고정함</strong>
              <template v-if="!row.gauge">
                <svg v-if="row.trend" viewBox="0 0 100 30" class="sample-trend" role="img" :aria-label="`관측값 ${row.trend.min}~${row.trend.max}, 새 샘플 ${row.trend.count}개; 정상 범위를 뜻하지 않음`" data-test="sample-trend">
                  <polyline :points="row.trend.points" fill="none" stroke="currentColor" stroke-width="1.5" vector-effect="non-scaling-stroke" />
                  <circle v-if="row.trend.count === 1" cx="50" cy="15" r="2" fill="currentColor" />
                </svg>
                <span class="small muted gauge-description">{{ row.limits.thresholds ? '유효한 숫자 눈금 없음' : row.limits.configured ? '상태 Limits · 숫자 범위 없음' : row.limits.known ? '숫자 Limits 없음' : 'Limits 정보 없음' }}</span>
                <span v-if="row.trend" class="small muted gauge-description">관측값 {{ row.trend.min }}–{{ row.trend.max }} · {{ row.trend.count }}/30개 샘플</span>
                <span v-else class="small muted gauge-description">{{ row.numeric === null ? '숫자 샘플 없음' : '새 샘플 대기 중' }}</span>
              </template>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <p v-else class="empty">이 화면에 표시할 수 있는 항목 참조가 없습니다.</p>
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
  { kind: 'alarm', label: '경보', icon: '!' }, { kind: 'caution', label: '주의', icon: '△' },
  { kind: 'within', label: '정상 범위', icon: '✓' }, { kind: 'unconfigured', label: 'Limits 없음', icon: '—' },
  { kind: 'stale', label: '오래됨', icon: '◷' }, { kind: 'disconnected', label: '연결 끊김', icon: '×' },
  { kind: 'disabled', label: '비활성', icon: '⊘' }, { kind: 'unknown', label: '알 수 없음', icon: '?' },
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

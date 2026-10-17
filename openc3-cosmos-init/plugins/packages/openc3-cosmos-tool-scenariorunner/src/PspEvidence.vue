<template>
  <section class="scenario-preview psp-evidence" aria-label="MM 간접 쓰기 증거" data-test="psp-evidence">
    <h2>포인터 변경과 cFS 종료</h2>
    <p class="muted small">PAYLOAD_DATA_APP은 정상적으로 버퍼에 샘플을 기록합니다. MM이 앱 내부 포인터를 쓰기 금지 코드 영역으로 바꾸면, 다음 기록에서 cFS 프로세스가 SIGSEGV로 종료됩니다. 종료 판정은 비행 TM이 아닌 지상 관측 결과입니다.</p>
    <div class="psp-evidence-grid">
      <div><h3>정상 기록과 MM 범위</h3>
        <p>cFS PID: <code>{{ baseline?.pid ?? '—' }}</code></p>
        <p>정상 버퍼: <code>{{ hex(baseline?.buffer_address) }}</code></p>
        <p>완료된 샘플: <strong>{{ baseline?.sample_count ?? '—' }}</strong></p>
        <p>MM 허용 영역: <code>{{ range || 'MM map 대기 중…' }}</code></p>
        <p>포인터 위치: <code>{{ hex(map?.pointer_slot) }}</code></p>
        <p>쓰기 금지 코드 영역 (r-x): <code>{{ hex(map?.code_address) }}</code></p>
        <p :class="denial ? 'evidence-pass' : 'muted'">{{ denial ? '모듈 밖 정상 버퍼 직접 MM 쓰기 거부됨 (status 3)' : 'MM 범위 검사 대기 중' }}</p>
      </div>
      <div><h3>포인터와 쓰기 대상</h3>
        <p>수정 전: <code>{{ hex(read?.pointer_before) }}</code></p>
        <p>MM 4바이트 쓰기: <code>{{ hex(edit?.pointer_after) }}</code></p>
        <p>수정 후: <code>{{ hex(verify?.pointer_after) }}</code></p>
        <p>재개 후 쓰기 대상: <code>{{ hex(resume?.write_target) }}</code></p>
      </div>
      <div><h3>cFS 프로세스 실행 결과</h3>
        <p :class="exit ? 'evidence-pass' : 'muted'">{{ exit ? `${exit.signal_name} · signal ${exit.exit_signal}` : '지상 종료 관측 대기 중' }}</p>
        <p v-if="exit?.observed_at">종료 관측: <code>{{ exit.observed_at }}</code></p>
        <p class="muted small">재개 후 cFS가 종료되므로 새 비행 TM은 기대하지 않습니다. Runner는 시작할 때 확인한 동일 프로세스의 종료 기록을 비교합니다.</p>
      </div>
    </div>
  </section>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({ steps: { type: Object, required: true } })
const completed = (phase) => props.steps[phase]?.status === 'succeeded' ? props.steps[phase] : null
const baseline = computed(() => completed('baseline'))
const map = computed(() => completed('map'))
const denial = computed(() => completed('deny-direct-write')?.debug_status === 3)
const read = computed(() => completed('read-pointer'))
const edit = computed(() => completed('write-pointer'))
const verify = computed(() => completed('verify-pointer'))
const resume = computed(() => completed('resume'))
const exit = computed(() => {
  const result = completed('confirm-sigsegv')
  return result?.exit_signal === 11 && result.signal_name === 'SIGSEGV' ? result : null
})
const range = computed(() => map.value?.module_start !== undefined ? `${hex(map.value.module_start)} – ${hex(map.value.module_end)} (종료 주소 미포함)` : '')
function hex(value) { return Number.isSafeInteger(value) ? `0x${value.toString(16).padStart(8, '0')}` : '—' }
</script>

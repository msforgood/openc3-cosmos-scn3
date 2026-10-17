<template>
  <section class="tc-log-evidence scenario-preview" aria-label="위성 탑재 TC 로그 증거" data-test="tc-log-evidence">
    <h2>위성 탑재 TC 로그</h2>
    <p class="muted small">아래 자료는 CI_LAB 텔레메트리를 통해 받은 위성의 <code>/cf/log</code> 파일 내용입니다. OpenC3의 지상 명령 이력은 별도로 저장됩니다.</p>
    <p v-if="targetIndex" class="small">선택한 파일: <code>/cf/log/tc{{ String(targetIndex).padStart(4, '0') }}.log</code>
      <span v-if="attack?.filename"> · 카메라 파일명: <code>{{ attack.filename }}</code></span></p>
    <div class="tc-log-evidence-grid">
      <div><h3>카메라 TC 전</h3><p class="muted small">{{ before?.file_size ?? '—' }}바이트 · TCLOG v1 텍스트</p>
        <pre data-test="tc-log-before">{{ before?.before_text || '닫힌 로그 파일을 읽을 때까지 대기 중…' }}</pre>
      </div>
      <div><h3>카메라 TC 후</h3><p class="muted small">{{ after?.file_size ?? '—' }}바이트 · PNG 바이너리를 ASCII 문자로 해석한 결과</p>
        <pre data-test="tc-log-after">{{ afterText ?? '같은 파일을 다시 읽을 때까지 대기 중…' }}</pre>
      </div>
    </div>
    <p v-if="continuity" class="small" data-test="tc-log-continuity">tc{{ String(continuity.active_index).padStart(4, '0') }}.log에 기록 계속 · TC 패킷 {{ continuity.total_logged }}개 기록 · 쓰기 오류 {{ continuity.write_errors }}건</p>
  </section>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({ steps: { type: Object, required: true } })
const before = computed(() => props.steps['read-before'])
const after = computed(() => props.steps['read-after'])
const afterText = computed(() => after.value?.after_text ?? asciiFromHex(after.value?.after_hex))
const attack = computed(() => props.steps['overwrite-log'])
const continuity = computed(() => props.steps['confirm-continuity'])
const targetIndex = computed(() => before.value?.file_index || props.steps['seal-target']?.file_index)

// Older runs only stored after_hex. Match Python's ASCII errors="replace" byte for byte.
function asciiFromHex(hex) {
  if (typeof hex !== 'string' || hex.length % 2 !== 0 || !/^[0-9a-f]*$/i.test(hex)) return null
  let text = ''
  for (let index = 0; index < hex.length; index += 2) {
    const byte = Number.parseInt(hex.slice(index, index + 2), 16)
    text += byte < 0x80 ? String.fromCharCode(byte) : '\uFFFD'
  }
  return text
}
</script>

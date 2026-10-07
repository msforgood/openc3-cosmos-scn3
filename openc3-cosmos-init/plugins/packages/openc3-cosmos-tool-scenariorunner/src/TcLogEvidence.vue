<template>
  <section class="tc-log-evidence scenario-preview" aria-label="Onboard TC log evidence" data-test="tc-log-evidence">
    <h2>Onboard TC log</h2>
    <p class="muted small">The evidence below comes from the satellite's <code>/cf/log</code> file through CI_LAB telemetry. OpenC3's ground command history is stored separately.</p>
    <p v-if="targetIndex" class="small">Selected file: <code>/cf/log/tc{{ String(targetIndex).padStart(4, '0') }}.log</code>
      <span v-if="attack?.filename"> · Camera filename: <code>{{ attack.filename }}</code></span></p>
    <div class="tc-log-evidence-grid">
      <div><h3>Before camera TC</h3><p class="muted small">{{ before?.file_size ?? '—' }} bytes · TCLOG v1 text</p>
        <pre data-test="tc-log-before">{{ before?.before_text || 'Waiting for the sealed log readback…' }}</pre>
      </div>
      <div><h3>After camera TC</h3><p class="muted small">{{ after?.file_size ?? '—' }} bytes · PNG signature and bytes (hex)</p>
        <pre data-test="tc-log-after">{{ after?.after_hex || 'Waiting for the same file readback…' }}</pre>
      </div>
    </div>
    <p v-if="continuity" class="small" data-test="tc-log-continuity">Logging continues in tc{{ String(continuity.active_index).padStart(4, '0') }}.log · {{ continuity.total_logged }} TC packets recorded · {{ continuity.write_errors }} write errors.</p>
  </section>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({ steps: { type: Object, required: true } })
const before = computed(() => props.steps['read-before'])
const after = computed(() => props.steps['read-after'])
const attack = computed(() => props.steps['overwrite-log'])
const continuity = computed(() => props.steps['confirm-continuity'])
const targetIndex = computed(() => before.value?.file_index || props.steps['seal-target']?.file_index)
</script>

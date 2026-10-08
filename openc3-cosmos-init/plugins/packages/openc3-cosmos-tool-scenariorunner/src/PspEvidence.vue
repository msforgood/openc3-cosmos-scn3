<template>
  <section class="scenario-preview psp-evidence" aria-label="MM indirect write evidence" data-test="psp-evidence">
    <h2>Indirect payload memory write</h2>
    <p class="muted small">MM resolves the running pulse module. The direct write to the protected controller is denied; the permitted one-byte pointer edit changes where the pulse app writes.</p>
    <div class="psp-evidence-grid">
      <div><h3>MM scope</h3>
        <p>Pulse module: <code>{{ range || 'Waiting for MM map…' }}</code></p>
        <p>Pointer slot: <code>{{ hex(map?.pointer_slot) }}</code></p>
        <p>Protected mode: <code>{{ hex(baseline?.mode_address) }}</code></p>
        <p :class="denial ? 'evidence-pass' : 'muted'">{{ denial ? 'Direct MM write denied (status 3)' : 'Direct write check pending' }}</p>
      </div>
      <div><h3>Pointer and write target</h3>
        <p>Before: <code>{{ hex(read?.pointer_before) }}</code></p>
        <p>One byte: <code>{{ hexByte(edit?.byte_before) }} → {{ hexByte(edit?.byte_after) }}</code></p>
        <p>After: <code>{{ hex(verify?.pointer_after) }}</code></p>
        <p>Pulse target: <code>{{ hex(resume?.pulse_target) }}</code></p>
      </div>
      <div><h3>Controller result</h3>
        <p>Mode: <code>{{ baseline?.mode_before ?? '—' }} → {{ fault?.mode_after ?? '—' }}</code></p>
        <p>Fault count: <strong>{{ fault?.fault_count ?? '—' }}</strong></p>
        <p>Pulse halt ACK: <strong>{{ fault?.halt_acked === 1 ? 'received' : 'pending' }}</strong></p>
        <p :class="esExit ? 'evidence-pass' : 'muted'">{{ esExit ? `cFE ES APP_ERROR cleanup · event ${esExit.es_event_id}` : 'cFE ES exit event pending' }}</p>
        <p :class="survived ? 'evidence-pass' : 'muted'">{{ survived ? 'Pulse app alive in fault-halted state' : 'Pulse survival pending' }}</p>
        <p class="muted small">The controller reports the mode fault, then cFE ES confirms its error exit. The pulse app remains available for STATUS.</p>
      </div>
    </div>
  </section>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({ steps: { type: Object, required: true } })
const baseline = computed(() => props.steps.baseline)
const map = computed(() => props.steps.map)
const denial = computed(() => props.steps['deny-direct-write']?.debug_status === 3)
const read = computed(() => props.steps['read-pointer'])
const edit = computed(() => props.steps['write-pointer-byte'])
const verify = computed(() => props.steps['verify-pointer'])
const resume = computed(() => props.steps.resume)
const fault = computed(() => props.steps['observe-fault'])
const esExit = computed(() => props.steps['confirm-es-exit']?.es_event_id === 14 ? props.steps['confirm-es-exit'] : null)
const survived = computed(() => props.steps['confirm-pulse']?.status === 'succeeded')
const range = computed(() => map.value?.module_start !== undefined ? `${hex(map.value.module_start)} – ${hex(map.value.module_end)} (end exclusive)` : '')
function hex(value) { return Number.isSafeInteger(value) ? `0x${value.toString(16).padStart(8, '0')}` : '—' }
function hexByte(value) { return Number.isInteger(value) ? `0x${value.toString(16).padStart(2, '0')}` : '—' }
</script>

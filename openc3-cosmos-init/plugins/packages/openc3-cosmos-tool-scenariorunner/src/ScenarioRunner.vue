<template>
  <main class="scenario-runner">
    <TopBar title="Scenario Runner" />
    <div class="runner-title"><div><p class="eyebrow">FIXED PROCEDURES</p><h1>Scenario Runner</h1></div><span class="scope-label">{{ scope }}</span></div>
    <p v-if="catalogError" class="error-text" role="alert">{{ catalogError }} <button @click="loadCatalog" :disabled="loading">Retry catalog</button></p>
    <p v-if="targetError" class="error-text" role="alert">{{ targetError }} <button @click="loadCatalog" :disabled="loading">Retry targets</button></p>
    <div class="runner-grid">
      <section class="run-panel" aria-label="Scenario selection and execution">
        <header class="panel-heading"><h2>Run a scenario</h2><span :class="['badge', `run-${displayStatus}`]" data-test="run-status">{{ state.starting ? 'Starting' : labels[displayStatus] }}</span></header>
        <div class="selection-grid">
          <div><label for="scenario-target">Target</label><select id="scenario-target" :value="state.target" :disabled="locked || loading" @change="selectTarget($event.target.value)" data-test="target-select">
            <option value="" disabled>Select installed target</option><option v-for="target in targets" :key="target" :value="target">{{ target }}</option>
          </select></div>
          <div><label for="scenario-definition">Scenario</label><select id="scenario-definition" v-model="scenarioId" :disabled="locked || loading || !availableScenarios.length" data-test="scenario-select">
            <option v-for="scenario in availableScenarios" :key="scenario.id" :value="scenario.id">{{ scenario.name }}</option>
          </select></div>
        </div>
        <p v-if="loading" class="empty">Loading installed targets and scenarios…</p>
        <p v-else-if="!targets.length && !targetError" class="empty">No installed targets available.</p>
        <p v-else-if="state.target && !availableScenarios.length" class="empty" data-test="no-scenarios">No scenarios available for this target</p>
        <div v-if="selectedScenario" class="scenario-preview">
          <p>{{ selectedScenario.description }}</p>
          <p class="muted small">Version {{ selectedScenario.version }} · Timeout {{ selectedScenario.timeoutSec }}s · Fixed parameters</p>
          <ol class="step-list" data-test="steps">
            <li v-for="(step, index) in selectedScenario.steps" :key="step.id" :class="`step-${displaySteps[step.id]?.status || 'pending'}`">
              <span class="step-number">{{ index + 1 }}</span><div><strong>{{ step.id }}</strong><p class="small">{{ stepDescription(step) }}</p>
                <p v-if="displaySteps[step.id]?.commandAccepted" class="small muted">Command accepted</p>
                <p v-if="displaySteps[step.id]?.telemetryConfirmed" class="small muted">Telemetry confirmed · {{ formatTime(displaySteps[step.id].received_at) }}</p>
                <p v-if="displaySteps[step.id]?.message" class="small">{{ displaySteps[step.id].message }}</p>
              </div><span class="step-state">{{ displaySteps[step.id]?.status || 'Pending' }}</span>
            </li>
          </ol>
        </div>
        <div v-if="isCrcScenario && matchesRun" class="scenario-preview" data-test="xband-evidence">
          <strong>X-band frame verification</strong>
          <p>{{ displaySteps['verify-xband-frame']?.message || 'Waiting for a fresh encrypted frame after the 16 CRC probes.' }}</p>
          <p class="muted small">The recovered key stays inside the running procedure and is not stored in the run result.</p>
        </div>
        <TcLogEvidence v-if="isTcLogScenario" :steps="displaySteps" />
        <PspEvidence v-if="isPspScenario" :steps="displaySteps" />
        <div class="run-progress"><label for="run-progress">{{ completedSteps }} / {{ selectedScenario?.steps.length || 0 }} steps complete</label>
          <progress id="run-progress" :value="completedSteps" :max="selectedScenario?.steps.length || 1" />
          <div class="time-row"><span>Elapsed {{ matchesRun ? elapsed : 0 }}s</span><span v-if="matchesRun && state.run?.deadline">Deadline {{ formatTime(state.run.deadline) }}</span></div>
        </div>
        <p v-if="state.run && !matchesRun" class="muted small">This preview differs from the last run's scenario or definition. Prior confirmations are shown only in its log.</p>
        <p v-if="state.error" class="error-text" role="alert">{{ state.error }}</p>
        <p v-if="state.requestFailure" class="error-text" role="status" data-test="request-failure">Start request FAILED: this request was not accepted and cannot launch. Request {{ state.requestFailure.request_id }}.</p>
        <p v-if="state.pendingRequest" class="connection-alert" role="status" data-test="pending-request">Start request unconfirmed. Recovering its outcome before another start is allowed.</p>
        <p v-if="apiDisconnected" class="connection-alert" role="status">Run API disconnected. {{ state.run ? 'The last actual run state is retained; execution may still be active.' : state.requestFailure ? 'The request failed; checking for other active runs before enabling Start.' : 'The request outcome and target availability are not yet confirmed.' }}</p>
        <p v-if="locked" class="muted small">Target and scenario selection are locked while the run is active or needs reconciliation.</p>
        <div class="run-actions">
          <button class="primary-button" data-test="start" :disabled="locked || loading || !selectedScenario || !targets.includes(state.target) || Boolean(catalogError) || Boolean(targetError)" @click="controller.start(selectedScenario)">Start scenario</button>
          <button class="stop-button" data-test="stop" :disabled="!state.run || !locked || state.acting || state.status === 'stopping' || ['failed', 'succeeded', 'stopped'].includes(state.run.state)" @click="controller.action('stop')">{{ state.status === 'stopping' ? 'Stopping…' : 'Stop' }}</button>
          <button v-if="state.status === 'needs_attention' || state.recoveryNeeded" :disabled="state.discovering || state.starting || state.acting" @click="controller.discover()">Recover run</button>
        </div>
        <p v-if="state.run" class="muted small run-id">Run {{ state.run.id }} · {{ state.run.scenario_id }} · {{ labels[state.status] }} · API {{ apiDisconnected ? 'unavailable' : locked ? 'connected' : 'last response received' }}</p>
        <header class="panel-heading logs-heading"><h2>Run log</h2><span class="muted">Last {{ state.logs.length }} / 1000</span></header>
        <div class="log-list" aria-label="Run event log" data-test="logs">
          <p v-if="!state.logs.length" class="empty">Run events will appear here.</p>
          <article v-for="event in state.logs" :key="event.id"><time>{{ formatTime(event.created_at) }}</time><strong>{{ event.type }}</strong><span>{{ logMessage(event) }}</span></article>
        </div>
      </section>
      <TelemetryPanel :target="state.target" :scope="scope" :telemetry-items="telemetryItems" />
    </div>
    <v-dialog :model-value="Boolean(state.prompt)" persistent max-width="560" aria-label="Scenario input required">
      <v-card v-if="state.prompt" class="pa-5">
        <h2>Scenario input required</h2><p class="my-4">{{ state.prompt.message }}</p>
        <p class="muted">Respond by {{ formatTime(state.prompt.deadline) }} · {{ promptRemaining }}s remaining</p>
        <p v-if="promptRemaining === 0" role="alert">Prompt expired. Waiting for the server to stop the run.</p>
        <p v-if="state.error" role="alert">{{ state.error }}</p>
        <v-card-actions><v-btn v-for="choice in state.prompt.choices.filter((choice) => choice !== 'cancel')" :key="choice" :disabled="state.acting || promptRemaining === 0" @click="controller.action('answer', choice)">{{ choice }}</v-btn>
          <v-btn :disabled="state.acting" @click="controller.action('answer', 'cancel')">Cancel run</v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>
  </main>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { OpenC3Api } from '@openc3/js-common/services'
import { TopBar } from '@openc3/vue-common/components'
import TelemetryPanel from './TelemetryPanel.vue'
import TcLogEvidence from './TcLogEvidence.vue'
import PspEvidence from './PspEvidence.vue'
import { createScenarioApi } from './scenarioApi.js'
import { initialRunnerState, RunnerController, runMatchesScenario } from './runnerController.js'
import { supportedTargets, formatTime, errorMessage, STORAGE_PREFIX } from './runtime.js'
import './style.css'

const scope = window.openc3Scope || 'DEFAULT'
const state = reactive(initialRunnerState())
const api = createScenarioApi(scope)
const controller = new RunnerController({ api, scope, state })
const scenarios = ref([]), targets = ref([]), scenarioId = ref(''), loading = ref(true), catalogError = ref(''), targetError = ref(''), now = ref(Date.now())
let disposed = false, catalogGeneration = 0
const clock = setInterval(() => { now.value = Date.now() }, 1000)
const labels = { ready: 'Ready', running: 'Running', waiting_input: 'Waiting for input', stopping: 'Stopping', succeeded: 'Succeeded', failed: 'Failed', stopped: 'Stopped', needs_attention: 'Needs attention' }
const locked = computed(() => controller.locked)
const apiDisconnected = computed(() => state.apiConnected === false || (locked.value && state.lastContact !== null && now.value - state.lastContact > 10000))
const availableScenarios = computed(() => scenarios.value.filter((s) => s.supportedTargets.includes(state.target) && (!s.permittedTargets || s.permittedTargets.includes(state.target))))
const selectedScenario = computed(() => availableScenarios.value.find((s) => s.id === scenarioId.value))
const emptyTelemetry = []
const telemetryItems = computed(() => selectedScenario.value?.telemetryItems || emptyTelemetry)
const matchesRun = computed(() => runMatchesScenario(state.run, selectedScenario.value, state.target))
const displaySteps = computed(() => matchesRun.value ? state.steps : {})
const displayStatus = computed(() => state.run && !matchesRun.value && !locked.value ? 'ready' : state.status)
const completedSteps = computed(() => selectedScenario.value?.steps.filter((step) => displaySteps.value[step.id]?.status === 'succeeded').length || 0)
const isCrcScenario = computed(() => ['qemu-cs-crc-key-oracle', 'bbb-cs-crc-key-oracle'].includes(selectedScenario.value?.id))
const isTcLogScenario = computed(() => ['qemu-tc-log-photo-traversal', 'bbb-tc-log-photo-traversal'].includes(selectedScenario.value?.id))
const isPspScenario = computed(() => ['qemu-psp-mm-indirect-write', 'bbb-psp-mm-indirect-write'].includes(selectedScenario.value?.id))
const elapsed = computed(() => {
  if (!state.run) return 0
  const end = ['succeeded', 'failed', 'stopped'].includes(state.status) ? Date.parse(state.run.updated_at) : now.value
  return Math.max(0, Math.floor((end - Date.parse(state.run.created_at)) / 1000))
})
const promptRemaining = computed(() => Math.max(0, Math.ceil((Date.parse(state.prompt?.deadline) - now.value) / 1000)) || 0)
watch(availableScenarios, (items) => { if (!items.some((s) => s.id === scenarioId.value)) scenarioId.value = items[0]?.id || '' })
watch(() => state.run?.scenario_id, (id) => { if (id) scenarioId.value = id })
watch(scenarioId, () => controller.clearStartRejection())
async function selectTarget(target) {
  if (await controller.selectTarget(target) && !disposed) {
    try { localStorage.setItem(`${STORAGE_PREFIX}.${scope}.target`, target) } catch { /* optional preference */ }
  }
}
async function loadCatalog() {
  const id = ++catalogGeneration
  loading.value = true; catalogError.value = ''; targetError.value = ''
  try {
    const [installed, catalog] = await Promise.allSettled([
      Promise.resolve().then(() => new OpenC3Api().get_target_names()).then((names) => {
        if (!Array.isArray(names) || !names.every((name) => typeof name === 'string' && name.length)) throw new Error('Invalid installed target list')
        return names
      }),
      Promise.resolve().then(() => api.scenarios()).then((catalog) => {
        if (!Array.isArray(catalog?.items) || !catalog.items.every((scenario) => scenario && Array.isArray(scenario.supportedTargets) &&
          Array.isArray(scenario.steps) && (!scenario.permittedTargets || Array.isArray(scenario.permittedTargets)))) throw new Error('Invalid scenario catalog')
        return catalog
      }),
    ])
    if (disposed || id !== catalogGeneration) return
    scenarios.value = catalog.status === 'fulfilled' ? catalog.value.items : []
    if (catalog.status === 'rejected') catalogError.value = `Unable to load scenarios: ${errorMessage(catalog.reason)}`
    targets.value = installed.status === 'fulfilled' ? [...new Set(installed.value)].sort() : []
    if (installed.status === 'rejected') targetError.value = `Unable to load installed targets: ${errorMessage(installed.reason)}`
    let saved
    try { saved = localStorage.getItem(`${STORAGE_PREFIX}.${scope}.target`) } catch { /* optional preference */ }
    // Scenario support chooses only the default; every installed name remains browsable.
    if (!state.target) await selectTarget(targets.value.includes(saved) ? saved : supportedTargets(targets.value, scenarios.value)[0] || targets.value[0] || '')
  } catch (error) { if (!disposed && id === catalogGeneration) catalogError.value = `Unable to load scenarios: ${errorMessage(error)}` }
  finally { if (!disposed && id === catalogGeneration) loading.value = false }
}
function stepDescription(step) {
  if (step.type === 'command') return `Command ${step.packet} · ${JSON.stringify(step.parameters || {})}`
  if (step.type === 'delay') return `Wait ${step.seconds}s`
  if (step.type === 'waitTelemetry') return `Wait for ${step.packet}.${step.item} ${step.operator} ${step.value} · timeout ${step.timeoutSec}s`
  if (step.type === 'resolveAddress') return 'Read key location and channel status from XKEY_HK'
  if (step.type === 'crcByte') return `CS OneShot: offset ${step.offset}, size 1 · confirm fresh CS_HK and invert CRC`
  if (step.type === 'verifyXbandFrame') return 'Receive a fresh X-band UDP frame and authenticate/decrypt it with the recovered key'
  if (step.type === 'tcLogPhase') return ({
    'seal-baseline': 'Close the previous onboard log and start a fresh file',
    'record-normal': 'Send a housekeeping TC and save a normal photo',
    'seal-target': 'Close the TC log chosen for the demonstration',
    'read-before': 'Read the closed log through CI_LAB telemetry',
    'overwrite-log': 'Save a photo named ../log/tcNNNN.log',
    'read-after': 'Read the same path and verify the PNG signature',
    'confirm-continuity': 'Confirm later commands are recorded in the next log',
  })[step.phase] || step.phase
  if (step.type === 'pspPhase') return ({
    baseline: 'Read normal pulse and protected controller state',
    map: 'MM finds the permitted app module and feed pointer slot',
    'deny-direct-write': 'Verify MM rejects a direct write to controller mode',
    pause: 'Pause periodic pulse writes',
    'read-pointer': 'Read the four-byte feed pointer from the permitted app',
    'write-pointer-byte': 'Change only the pointer low byte through MM/PSP',
    'verify-pointer': 'Read back the pointer and confirm the mode address',
    resume: 'Resume the pulse app and let its normal write use the new pointer',
    'observe-fault': 'Observe controller mode fault and internal halt acknowledgement',
    'confirm-es-exit': 'Confirm cFE ES event 14 for controller APP_ERROR cleanup',
    'confirm-pulse': 'Confirm the pulse app remains alive in fault-halted state',
  })[step.phase] || step.phase
  return step.type
}
function logMessage(event) {
  const data = event.data || {}
  return [data.step_id, data.status, data.message].filter(Boolean).join(' · ') || JSON.stringify(data)
}
function beforeUnload(event) { if (locked.value) { event.preventDefault(); event.returnValue = '' } }
onMounted(() => { window.addEventListener('beforeunload', beforeUnload); void loadCatalog() })
onBeforeUnmount(() => { disposed = true; catalogGeneration++; controller.dispose(); clearInterval(clock); window.removeEventListener('beforeunload', beforeUnload) })
</script>

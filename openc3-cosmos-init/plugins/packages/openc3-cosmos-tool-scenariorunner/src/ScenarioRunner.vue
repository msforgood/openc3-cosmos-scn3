<template>
  <main class="scenario-runner">
    <TopBar title="Scenario Runner" />
    <p v-if="catalogError" class="error-text" role="alert">{{ catalogError }} <button @click="loadCatalog" :disabled="loading">Retry catalog</button></p>
    <p v-if="targetError" class="error-text" role="alert">{{ targetError }} <button @click="loadCatalog" :disabled="loading">Retry targets</button></p>
    <div class="runner-grid">
      <section class="run-panel" aria-label="시나리오 선택 및 실행">
        <header class="panel-heading"><h2>시나리오 실행</h2><span :class="['badge', `run-${displayStatus}`]" data-test="run-status">{{ state.starting ? 'Starting' : labels[displayStatus] }}</span></header>
        <div class="selection-grid">
          <div><label for="scenario-target">대상</label><select id="scenario-target" :value="state.target" :disabled="locked || loading" @change="selectTarget($event.target.value)" data-test="target-select">
            <option value="" disabled>설치된 대상을 선택하세요</option><option v-for="target in targets" :key="target" :value="target">{{ target }}</option>
          </select></div>
          <div><label for="scenario-definition">시나리오</label><select id="scenario-definition" v-model="scenarioId" :disabled="locked || loading || !availableScenarios.length" data-test="scenario-select">
            <option v-for="scenario in availableScenarios" :key="scenario.id" :value="scenario.id">{{ scenarioDisplayName(scenario) }}</option>
          </select></div>
        </div>
        <p v-if="loading" class="empty">설치된 대상과 시나리오를 불러오는 중…</p>
        <p v-else-if="!targets.length && !targetError" class="empty">설치된 대상이 없습니다.</p>
        <p v-else-if="state.target && !availableScenarios.length" class="empty" data-test="no-scenarios">이 대상에서 실행할 수 있는 시나리오가 없습니다.</p>
        <div v-if="selectedScenario" class="scenario-preview">
          <p>{{ scenarioDisplayDescription(selectedScenario) }}</p>
          <p class="muted small">Run step은 단계를 순서대로 실행하고, Start script는 전체 데모를 실행합니다. Planned TC는 전송할 패킷과 파라미터를 보여줍니다. Execution result는 해당 단계가 끝난 뒤 표시됩니다. 실제 전송값은 실행 로그에서 확인할 수 있습니다.</p>
          <ol class="step-list" data-test="steps">
            <li v-for="(step, index) in selectedScenario.steps" :key="step.id" :class="`step-${displaySteps[step.id]?.status || 'pending'}`">
              <span class="step-number">{{ index + 1 }}</span><div class="step-detail"><strong>{{ stepDescription(step) }}</strong>
                <div class="step-command-plan" :data-test="`step-command-plan-${step.id}`">
                  <span class="small step-command-heading">Planned TC</span>
                  <p v-if="stepCommandPlan(step) === null" class="small muted">TC 계획을 확인할 수 없습니다.</p>
                  <p v-else-if="stepCommandPlan(step).length === 0" class="small muted">No TC</p>
                  <div v-for="(command, commandIndex) in stepCommandPlan(step) || []" :key="commandIndex" class="step-command">
                    <span class="small">{{ command.packet }}</span>
                    <pre>{{ formatPlannedParameters(command.parameters) }}</pre>
                  </div>
                </div>
                <div v-if="['succeeded', 'failed', 'stopped'].includes(displaySteps[step.id]?.status)" :class="['step-execution-result', `step-execution-${displaySteps[step.id].status}`]" :data-test="`step-result-${step.id}`">
                  <span class="small step-execution-heading">Execution result</span>
                  <pre>{{ stepResultMessage(displaySteps[step.id]) }}</pre>
                </div>
              </div><div class="step-controls"><span class="step-state">{{ displaySteps[step.id]?.status || 'Pending' }}</span>
                <button type="button" class="step-run-button" :data-test="`step-run-${step.id}`" :aria-label="`Run step ${index + 1}: ${step.id}`" :disabled="!canRunStep(step, index)" @click="runStep(step, index)">Run step</button>
              </div>
            </li>
          </ol>
        </div>
        <div v-if="isCrcScenario" class="scenario-preview" data-test="xband-evidence">
          <strong>Recovered X-band lab key</strong>
          <p v-if="recoveredKey" data-test="recovered-key"><code>{{ recoveredKey }}</code></p>
          <p v-else class="muted small">이 시나리오를 실행하면 CS CRC 응답 16개로 키를 복원합니다.</p>
          <div v-if="verifiedFrame" data-test="decrypted-flag">
            <strong>X-band frame {{ verifiedFrame.sequence }} · AES-GCM authenticated</strong>
            <p>Decrypted flag: <code>{{ verifiedFrame.flag }}</code></p>
          </div>
          <p v-else class="muted small">새 X-band frame 인증이 끝나면 Decrypted flag가 표시됩니다.</p>
        </div>
        <TcLogEvidence v-if="isTcLogScenario" :steps="displaySteps" />
        <PspEvidence v-if="isPspScenario" :steps="displaySteps" />
        <div class="run-progress"><label for="run-progress">{{ completedSteps }} / {{ selectedScenario?.steps.length || 0 }}단계 완료</label>
          <progress id="run-progress" :value="completedSteps" :max="selectedScenario?.steps.length || 1" />
          <div class="time-row"><span>경과 {{ matchesRun ? elapsed : 0 }}초</span></div>
        </div>
        <p v-if="state.run && !matchesRun" class="muted small">현재 선택한 시나리오 또는 정의가 마지막 실행과 다릅니다. 이전 실행의 확인 결과는 해당 로그에서만 볼 수 있습니다.</p>
        <p v-if="state.error" class="error-text" role="alert">{{ state.error }}</p>
        <p v-if="state.requestFailure" class="error-text" role="status" data-test="request-failure">시작 요청 실패: 요청이 수락되지 않아 실행할 수 없습니다.</p>
        <p v-if="state.pendingRequest" class="connection-alert" role="status" data-test="pending-request">시작 요청의 처리 결과를 아직 확인하지 못했습니다. 결과를 복구한 뒤 새로 시작할 수 있습니다.</p>
        <p v-if="apiDisconnected" class="connection-alert" role="status">실행 API 연결이 끊어졌습니다. {{ state.run ? '마지막 실행 상태는 보존되며, 실행이 아직 진행 중일 수 있습니다.' : state.requestFailure ? '요청이 실패했습니다. Start를 활성화하기 전에 다른 실행이 진행 중인지 확인합니다.' : '요청 결과와 대상 사용 가능 여부를 아직 확인하지 못했습니다.' }}</p>
        <p v-if="locked" class="muted small">실행 중이거나 상태를 다시 확인해야 할 때는 대상과 시나리오를 바꿀 수 없습니다.</p>
        <div class="run-actions">
          <button class="primary-button" data-test="start" :disabled="!canStart" @click="controller.start(selectedScenario)">Start script</button>
          <button class="stop-button" data-test="stop" :disabled="!state.run || !locked || state.acting || state.status === 'stopping' || ['failed', 'succeeded', 'stopped'].includes(state.run.state)" @click="controller.action('stop')">{{ state.status === 'stopping' ? 'Stopping…' : 'Stop' }}</button>
          <button v-if="state.status === 'needs_attention' || state.recoveryNeeded" :disabled="state.discovering || state.starting || state.acting" @click="controller.discover()">Recover run</button>
        </div>
        <header class="panel-heading logs-heading"><h2>실행 로그</h2></header>
        <div class="log-list" aria-label="실행 이벤트 로그" data-test="logs">
          <p v-if="!state.logs.length" class="empty">실행 이벤트가 여기에 표시됩니다.</p>
          <article v-for="event in state.logs" :key="event.id"><time>{{ formatTime(event.created_at) }}</time><strong>{{ event.type }}</strong><span>{{ logMessage(event) }}</span></article>
        </div>
      </section>
      <TelemetryPanel :target="state.target" :scope="scope" :telemetry-items="telemetryItems" />
    </div>
    <v-dialog :model-value="Boolean(state.prompt) && state.run?.execution_mode !== 'manual'" persistent max-width="560" aria-label="시나리오 입력 필요">
      <v-card v-if="state.prompt && state.run?.execution_mode !== 'manual'" class="pa-5">
        <h2>시나리오 입력 필요</h2><p class="my-4">{{ state.prompt.message }}</p>
        <p class="muted">응답 기한 {{ formatTime(state.prompt.deadline) }} · {{ promptRemaining }}초 남음</p>
        <p v-if="promptRemaining === 0" role="alert">응답 기한이 지났습니다. 서버가 실행을 중단하기를 기다리는 중입니다.</p>
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
import { formatPlannedParameters, stepCommandPlan } from './stepCommandPlan.js'
import { createScenarioApi } from './scenarioApi.js'
import { initialRunnerState, RunnerController, runMatchesScenario } from './runnerController.js'
import { formatTime, errorMessage, STORAGE_PREFIX } from './runtime.js'
import './style.css'

const scope = window.openc3Scope || 'DEFAULT'
const targetOrder = ['CFS-1_QEMU', 'CFS-1_BBB']
const scenarioCopy = {
  'tc-log-photo-traversal': {
    name: '02. TC 로그 사진 경로 변경',
    description: '온보드 TC 로그에 명령을 기록하고 파일을 닫아 읽은 뒤, 파일명에 ../를 넣은 사진 명령으로 닫힌 로그를 고정 이미지로 덮어씁니다. 지상국 명령 이력은 별도로 유지됩니다.',
  },
  'psp-mm-indirect-write': {
    name: '03. MM 포인터 변경',
    description: 'PAYLOAD_DATA_APP은 탑재체 샘플을 메모리 버퍼에 주기적으로 기록합니다. MM은 이 앱의 .so 쓰기 가능 영역만 직접 수정할 수 있습니다. 앱 내부의 4바이트 쓰기 포인터를 보호 페이지 주소로 바꾸고 샘플 기록을 재개한 뒤, 지상 관측기로 cFS 프로세스의 SIGSEGV 종료를 확인합니다.',
  },
  'cs-crc-key-oracle': {
    name: '01. CS 1바이트 CRC 키 복원',
    description: 'CS CRC 요청을 1바이트씩 16회 보내 X-band 실습 키를 복원한 다음, 새 X-band frame을 인증하고 암호화된 실습 flag를 확인합니다.',
  },
}
function scenarioDisplayName(scenario) { return scenarioCopy[scenario.id]?.name || scenario.name }
function scenarioDisplayDescription(scenario) { return scenarioCopy[scenario.id]?.description || scenario.description }
const state = reactive(initialRunnerState())
const api = createScenarioApi(scope)
const controller = new RunnerController({ api, scope, state })
const scenarios = ref([]), targets = ref([]), scenarioId = ref(''), loading = ref(true), catalogError = ref(''), targetError = ref(''), now = ref(Date.now())
let disposed = false, catalogGeneration = 0
const clock = setInterval(() => { now.value = Date.now() }, 1000)
const labels = { ready: 'Ready', running: 'Running', waiting_input: 'Waiting for input', stopping: 'Stopping', succeeded: 'Succeeded', failed: 'Failed', stopped: 'Stopped', needs_attention: 'Needs attention' }
const locked = computed(() => controller.locked)
const apiDisconnected = computed(() => state.apiConnected === false || (locked.value && state.lastContact !== null && now.value - state.lastContact > 10000))
function supportsTarget(scenario, target) {
  return scenario.supportedTargets.includes(target) &&
    (!scenario.permittedTargets || scenario.permittedTargets.includes(target))
}
const availableScenarios = computed(() => scenarios.value.filter((scenario) => supportsTarget(scenario, state.target)))
const selectedScenario = computed(() => availableScenarios.value.find((s) => s.id === scenarioId.value))
const emptyTelemetry = []
const telemetryItems = computed(() => selectedScenario.value?.telemetryItems || emptyTelemetry)
const matchesRun = computed(() => runMatchesScenario(state.run, selectedScenario.value, state.target))
const displaySteps = computed(() => matchesRun.value ? state.steps : {})
const displayStatus = computed(() => state.run && !matchesRun.value && !locked.value ? 'ready' : state.status)
const completedSteps = computed(() => selectedScenario.value?.steps.filter((step) => displaySteps.value[step.id]?.status === 'succeeded').length || 0)
const canStart = computed(() => !locked.value && !loading.value && Boolean(selectedScenario.value) &&
  targets.value.includes(state.target) && !catalogError.value && !targetError.value)
const isCrcScenario = computed(() => selectedScenario.value?.id === 'cs-crc-key-oracle')
const recoveredKey = computed(() => matchesRun.value ? /^Recovered X-band lab key: ([0-9a-f]{32})$/.exec(state.run?.result?.message || '')?.[1] || '' : '')
const verifiedFrame = computed(() => {
  if (!recoveredKey.value || state.status !== 'succeeded') return null
  const step = displaySteps.value['verify-xband-frame']
  if (step?.status !== 'succeeded' || step.authenticated !== true) return null
  const match = /^XBD1 frame ([1-9][0-9]*) AES-GCM authenticated; decrypted flag: (flag\{[a-z0-9_]{10}\})$/.exec(step.message || '')
  return match ? { sequence: match[1], flag: match[2] } : null
})
const isTcLogScenario = computed(() => selectedScenario.value?.id === 'tc-log-photo-traversal')
const isPspScenario = computed(() => selectedScenario.value?.id === 'psp-mm-indirect-write')
const elapsed = computed(() => {
  if (!state.run) return 0
  const end = ['succeeded', 'failed', 'stopped'].includes(state.status) ? Date.parse(state.run.updated_at) : now.value
  return Math.max(0, Math.floor((end - Date.parse(state.run.created_at)) / 1000))
})
const promptRemaining = computed(() => Math.max(0, Math.ceil((Date.parse(state.prompt?.deadline) - now.value) / 1000)) || 0)
function canRunStep(step, index) {
  if (index === 0) return canStart.value
  return Boolean(matchesRun.value && state.run?.execution_mode === 'manual' &&
    state.status === 'waiting_input' && !state.acting && !state.discovering &&
    !state.recoveryNeeded && !apiDisconnected.value &&
    state.prompt?.status === 'pending' && state.prompt.prompt_id === step.id &&
    state.prompt.choices?.includes('continue') &&
    selectedScenario.value.steps.slice(0, index).every((prior) => displaySteps.value[prior.id]?.status === 'succeeded'))
}
function runStep(step, index) {
  if (!canRunStep(step, index)) return
  if (index === 0) void controller.start(selectedScenario.value, 'manual')
  else void controller.action('answer', 'continue', step.id)
}
watch(availableScenarios, (items) => { if (!items.some((s) => s.id === scenarioId.value)) scenarioId.value = items[0]?.id || '' })
watch(() => state.run?.scenario_id, (id) => { if (id && availableScenarios.value.some((scenario) => scenario.id === id)) scenarioId.value = id })
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
    if (catalog.status === 'rejected') catalogError.value = `시나리오를 불러오지 못했습니다: ${errorMessage(catalog.reason)}`
    targets.value = installed.status === 'fulfilled' ? targetOrder.filter((target) => installed.value.includes(target)) : []
    if (installed.status === 'rejected') targetError.value = `설치된 대상을 불러오지 못했습니다: ${errorMessage(installed.reason)}`
    let saved
    try { saved = localStorage.getItem(`${STORAGE_PREFIX}.${scope}.target`) } catch { /* optional preference */ }
    if (!state.target) await selectTarget(targets.value.includes(saved) ? saved :
      targets.value.find((target) => scenarios.value.some((scenario) => supportsTarget(scenario, target))) || targets.value[0] || '')
  } catch (error) { if (!disposed && id === catalogGeneration) catalogError.value = `시나리오를 불러오지 못했습니다: ${errorMessage(error)}` }
  finally { if (!disposed && id === catalogGeneration) loading.value = false }
}
function stepDescription(step) {
  if (step.type === 'command') return `${step.packet} 명령 전송 · ${JSON.stringify(step.parameters || {})}`
  if (step.type === 'delay') return `${step.seconds}초 대기`
  if (step.type === 'waitTelemetry') return `${step.packet}.${step.item} ${step.operator} ${step.value} 수신 대기 · 제한 시간 ${step.timeoutSec}초`
  if (step.type === 'resolveAddress') return 'XKEY_HK에서 키 주소와 채널 상태 확인'
  if (step.type === 'crcByte') return `CS OneShot: offset ${step.offset}, size 1 · 새 CS_HK를 확인하고 CRC에서 바이트 값 복원`
  if (step.type === 'verifyXbandFrame') return '새 X-band UDP frame을 수신하고 복원한 키로 인증·복호화'
  if (step.type === 'tcLogPhase') return ({
    'seal-baseline': '이전 온보드 로그를 닫고 새 파일 시작',
    'record-normal': 'HK TC를 보내고 정상 사진 저장',
    'seal-target': '데모에 사용할 TC 로그를 닫기',
    'read-before': 'CI_LAB TM으로 닫힌 로그 읽기',
    'overwrite-log': '../log/tcNNNN.log 이름으로 사진 저장',
    'read-after': '같은 경로를 읽어 PNG 시그니처 확인',
    'confirm-continuity': '이후 명령이 다음 로그에 기록되는지 확인',
  })[step.phase] || step.phase
  if (step.type === 'pspPhase') return ({
    baseline: 'PAYLOAD_DATA_APP의 정상 샘플 기록과 cFS 프로세스 상태 확인',
    map: 'MM으로 PAYLOAD_DATA_APP 모듈 범위와 쓰기 포인터 슬롯 찾기',
    'deny-direct-write': 'MM이 모듈 밖 정상 버퍼에 직접 쓰기를 거부하는지 확인',
    pause: 'PAYLOAD_DATA_APP의 주기적 샘플 기록 중지',
    'read-pointer': '앱 내부의 4바이트 쓰기 포인터 읽기',
    'write-pointer': 'MM/PSP로 포인터 4바이트를 보호 페이지 주소로 변경',
    'verify-pointer': '포인터를 다시 읽어 보호 페이지 주소와 비교',
    resume: '샘플 기록을 재개해 변경된 포인터 적용',
    'confirm-sigsegv': '지상 관측기로 동일 cFS 프로세스의 SIGSEGV 종료 확인',
  })[step.phase] || step.phase
  return step.type
}
function stepResultMessage(step) {
  if (typeof step.message === 'string' && step.message.trim()) return step.message
  if (step.status === 'failed') return 'Step failed'
  if (step.status === 'stopped') return 'Step stopped'
  if (step.telemetryConfirmed && step.packet && step.item && step.value !== undefined) return `${step.packet}.${step.item} = ${step.value}`
  if (step.telemetryConfirmed) return step.received_at ? `Telemetry confirmed · ${formatTime(step.received_at)}` : 'Telemetry confirmed'
  if (step.commandAccepted) return 'Command accepted'
  return 'Step completed'
}
function logMessage(event) {
  const data = event.data || {}
  const stepIndex = matchesRun.value ? selectedScenario.value?.steps.findIndex((step) => step.id === data.step_id) : -1
  const stepLabel = stepIndex >= 0 ? `${stepIndex + 1}단계` : ''
  if (event.type === 'command') return [stepLabel, data.packet, data.parameters_json].filter((value) => value !== undefined && value !== null && value !== '').join(' · ')
  return [stepLabel, data.status, data.message].filter(Boolean).join(' · ') || JSON.stringify(data)
}
function beforeUnload(event) { if (locked.value) { event.preventDefault(); event.returnValue = '' } }
onMounted(() => { window.addEventListener('beforeunload', beforeUnload); void loadCatalog() })
onBeforeUnmount(() => { disposed = true; catalogGeneration++; controller.dispose(); clearInterval(clock); window.removeEventListener('beforeunload', beforeUnload) })
</script>

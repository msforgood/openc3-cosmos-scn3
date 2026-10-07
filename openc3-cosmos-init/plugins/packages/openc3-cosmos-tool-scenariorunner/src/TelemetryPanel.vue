<template>
  <section class="telemetry-panel" aria-label="Selected target telemetry">
    <header class="panel-heading"><h2>{{ target || 'No target' }} · HK / TM</h2>
      <span :class="['badge', `comm-${commStatus}`]" data-test="communication">{{ communicationLabel }}</span>
    </header>
    <p class="muted" data-test="receipt">Last packet received: {{ formatTime(lastReceipt) }}</p>
    <p class="muted small">Receipt time comes from packets referenced by this screen. Delayed if any is older than 10 seconds.</p>
    <label for="scenario-screen">Read-only telemetry screen</label>
    <select id="scenario-screen" v-model="screen" :disabled="!screens.length" data-test="screen-select">
      <option v-for="name in screens" :key="name" :value="name">{{ name }}</option>
    </select>
    <p v-if="error" role="alert" class="error-text">{{ error }}</p>
    <p v-if="!screens.length && !error" class="empty">No installed telemetry screens for this target.</p>
    <TelemetryOverview v-if="definition" :target="target" :screen="screen" :rows="overviewRows" :total="selectedItems.total"
      :limits-set="limitsSet" :metadata-error="metadataError" />
    <div v-if="definition" class="screen-container">
      <h3 class="small muted">Packet screen · {{ screen }}</h3>
      <p v-if="commStatus !== 'live'" class="telemetry-warning" role="status">{{ communicationLabel }} — displayed values may be unavailable or old.</p>
      <div class="screen-item" :class="{ 'screen-stale': commStatus !== 'live' }"
        @contextmenu.capture.stop.prevent @keydown.capture="blockContextKey">
        <Openc3Screen ref="screenRef" :key="`${scope}:${target}:${screen}:${screenRevision}`" :target="target" :screen="screen"
          :definition="definition" :keywords="keywords" :inline="true" :show-close="false" :fix-floated="true" />
      </div>
    </div>
    <header class="panel-heading limits-heading"><h2>Limits events</h2><span class="muted">{{ limitsConnected ? 'Connected' : 'Disconnected' }}</span></header>
    <p class="muted small">Read-only · {{ target || 'No target' }} only · latest {{ events.length }} / 1000 events</p>
    <p v-if="!events.length" class="empty">No limits changes received for this target. This does not establish telemetry health.</p>
    <div class="event-list" data-test="limits-events">
      <article v-for="(event, index) in events" :key="`${event.time_nsec}:${index}`" class="limit-event">
        <time>{{ eventTime(event.time_nsec) }}</time>
        <strong>{{ event.packet_name }} / {{ event.item_name }}</strong>
        <span>{{ event.new_limits_state }}{{ event.value !== undefined ? ` · ${event.value}` : '' }}</span>
      </article>
    </div>
  </section>
</template>

<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { Api, Cable, OpenC3Api } from '@openc3/js-common/services'
import { Openc3Screen } from '@openc3/vue-common/components'
import { SerialPoller, TargetLimitsSubscription, communicationStatus, packetReceipt, formatTime, errorMessage, MAX_LOGS } from './runtime.js'
import { preferredScreen, validatePassiveScreen } from './passiveScreen.js'
import TelemetryOverview from './TelemetryOverview.vue'
import { appendSample, displayValue, itemKey, itemLimits, itemStatus, limitsGauge, METADATA_INTERVAL, overviewItems, sampleTrend, telemetryPair } from './telemetryOverview.js'

const props = defineProps({ target: { type: String, default: '' }, scope: { type: String, required: true }, telemetryItems: { type: Array, default: () => [] } })
const screens = ref([]), screen = ref(''), definition = ref(''), keywords = ref([]), error = ref('')
const events = ref([]), limitsConnected = ref(false), connected = ref(null), lastReceipt = ref(null), lastSuccess = ref(null)
const freshnessReceipt = ref(null), screenRef = ref(null)
const validatedPackets = ref([])
const validatedItems = ref([]), observations = ref({}), metadata = ref({}), limitsSet = ref(null), metadataError = ref(false)
let metadataAt = null
const now = ref(Date.now()), screenRevision = ref(0)
let generation = 0, screenGeneration = 0, overviewGeneration = 0, disposed = false, monitor, subscription, flushTimer, pendingEvents = []
const clock = setInterval(() => { now.value = Date.now() }, 1000)
const commStatus = computed(() => communicationStatus({ connected: connected.value, lastReceipt: freshnessReceipt.value, lastSuccess: lastSuccess.value }, now.value))
const communicationLabel = computed(() => ({ live: 'Live telemetry', no_data: 'No telemetry data', delayed: 'Telemetry delayed', disconnected: 'Telemetry disconnected' })[commStatus.value])
const selectedItems = computed(() => overviewItems(validatedItems.value, props.telemetryItems))
const overviewRows = computed(() => selectedItems.value.items.map((item) => {
  const key = itemKey(item), observation = observations.value[key]
  const pair = observation?.pair || telemetryPair(null)
  const details = metadata.value[key], receipt = observation?.receipt ?? null
  const limits = itemLimits(details, limitsSet.value)
  return { ...item, key, receipt, numeric: pair.numeric, limits,
    display: displayValue(pair.value === null ? null : observation?.formatted ?? pair.value), units: details?.units || '',
    status: itemStatus({ pair, receipt, connected: connected.value, lastSuccess: lastSuccess.value, metadata: details, limitsSet: limitsSet.value }, now.value),
    gauge: limitsGauge(limits.thresholds, pair.numeric), trend: sampleTrend(observation?.samples || []),
  }
}))
function clearOverview() {
  observations.value = {}; metadata.value = {}; limitsSet.value = null; metadataError.value = false; metadataAt = null
}
function eventTime(nsec) { return formatTime(Number(nsec) / 1000000) }
// VWidget's Details context menu contains a limits enable switch in 6.10.1.
// Capture before the widget listener, while allowing read-only tab navigation.
function blockContextKey(event) {
  if (event.key === 'ContextMenu' || (event.shiftKey && event.key === 'F10')) {
    event.preventDefault(); event.stopPropagation()
  }
}

function cleanup() {
  monitor?.stop()
  subscription?.dispose()
  clearTimeout(flushTimer)
  flushTimer = null
  pendingEvents = []
}
watch(() => [props.target, props.scope], async ([target, scope]) => {
  cleanup()
  const id = ++generation
  ++screenGeneration
  const current = () => !disposed && id === generation
  screens.value = []; screen.value = ''; definition.value = ''; validatedPackets.value = []; events.value = []; error.value = ''
  validatedItems.value = []; clearOverview()
  connected.value = null; limitsConnected.value = false; lastReceipt.value = null; freshnessReceipt.value = null; lastSuccess.value = null
  if (!target) return
  subscription = new TargetLimitsSubscription({
    createCable: () => new Cable(), scope, target,
    onConnection: (value) => { if (current()) limitsConnected.value = value },
    onEvents: (batch) => {
      if (!current()) return
      pendingEvents = [...pendingEvents, ...batch].slice(-MAX_LOGS)
      if (!flushTimer) flushTimer = setTimeout(() => {
        flushTimer = null
        if (!current()) return
        events.value = [...pendingEvents.reverse(), ...events.value].slice(0, MAX_LOGS)
        pendingEvents = []
      }, 250)
    },
  })
  // Discovery uses real installed packet names, never a scenario status timestamp.
  const api = new OpenC3Api()
  let packetNames
  monitor = new SerialPoller(async (pollCurrent) => {
    const selection = screenGeneration, overviewSelection = overviewGeneration
    const valid = () => current() && pollCurrent() && selection === screenGeneration && overviewSelection === overviewGeneration
    try {
      if (!packetNames) packetNames = await api.get_all_tlm_names(target)
      if (!valid()) return
      const screenPackets = validatedPackets.value
      const names = screenPackets.filter((name) => packetNames.includes(name))
      if (!screenPackets.length) return
      const rows = selectedItems.value.items.filter((item) => names.includes(item.packet))
      // Packet definitions contain units, limits.enabled, named threshold objects,
      // and state colors. Batch by packet and refresh within this same serial loop.
      if (metadataAt === null || Date.now() - metadataAt >= METADATA_INTERVAL) {
        const packets = [...new Set(rows.map((item) => item.packet))]
        const results = await Promise.allSettled([api.get_limits_set(), ...packets.map((packet) => api.get_tlm(target, packet))])
        if (!valid()) return
        const next = {}
        for (const row of rows) {
          const result = results[packets.indexOf(row.packet) + 1]
          if (result.status === 'fulfilled') {
            const detail = result.value?.items?.find((item) => item.name === row.item)
            if (detail) next[itemKey(row)] = detail
          }
        }
        limitsSet.value = results[0].status === 'fulfilled' && typeof results[0].value === 'string' ? results[0].value : null
        metadata.value = next
        metadataError.value = !limitsSet.value || Object.keys(next).length !== rows.length
        metadataAt = Date.now()
      }
      const items = names.map((name) => `${target}__${name}__RECEIVED_TIMESECONDS__RAW`)
      for (const row of rows) items.push(`${target}__${row.packet}__${row.item}__CONVERTED`, `${target}__${row.packet}__${row.item}__FORMATTED`)
      const values = await api.get_tlm_values(items, 10, 0)
      if (!valid()) return
      if (!Array.isArray(values) || values.length !== items.length) throw new Error('Incomplete telemetry response')
      const receiptValues = values.slice(0, names.length)
      lastReceipt.value = packetReceipt(receiptValues)
      const receipts = receiptValues.map((value) => packetReceipt([value]))
      freshnessReceipt.value = receipts.length && names.length === screenPackets.length && receipts.every((value) => value !== null) ? Math.min(...receipts) : null
      const updatedAt = Date.now(), next = {}
      rows.forEach((row, index) => {
        const key = itemKey(row), pair = telemetryPair(values[names.length + index * 2], row.index)
        const formatted = telemetryPair(values[names.length + index * 2 + 1], row.index).value
        const receipt = receipts[names.indexOf(row.packet)]
        const samples = appendSample(observations.value[key]?.samples || [], pair.numeric, receipt, updatedAt, pair.state !== 'STALE')
        next[key] = { pair, formatted, receipt, samples }
      })
      observations.value = next
      lastSuccess.value = updatedAt
      connected.value = true
    } catch { if (valid()) connected.value = false }
  })
  monitor.start()
  try {
    const [list, hints] = await Promise.all([
      Api.get('/openc3-api/screens', { params: { scope } }),
      Api.get('/openc3-api/autocomplete/keywords/screen', { params: { scope } }),
    ])
    if (!current()) return
    keywords.value = hints.data
    screens.value = [...new Set(list.data.filter((path) => path.split('/')[0] === target)
      .map((path) => path.split('/').at(-1).replace(/\.[^.]+$/, '').toUpperCase()))].sort()
    screen.value = preferredScreen(screens.value, props.telemetryItems)
  } catch (cause) { if (current()) error.value = `Unable to load telemetry screens: ${errorMessage(cause)}` }
}, { immediate: true, flush: 'sync' })

watch(screen, async (name) => {
  const id = ++screenGeneration, target = props.target, scope = props.scope
  definition.value = ''
  validatedPackets.value = []; error.value = ''
  validatedItems.value = []; clearOverview()
  lastReceipt.value = null; freshnessReceipt.value = null
  if (!name) return
  try {
    const result = await Api.get(`/openc3-api/screen/${encodeURIComponent(target)}/${encodeURIComponent(name)}`, { params: { scope }, headers: { Accept: 'text/plain' } })
    if (disposed || id !== screenGeneration) return
    const validation = validatePassiveScreen(result.data, target)
    validatedPackets.value = validation.packets
    validatedItems.value = validation.items
    definition.value = result.data
    screenRevision.value++
  } catch (cause) { if (!disposed && id === screenGeneration) error.value = `Unable to load screen: ${errorMessage(cause)}` }
}, { flush: 'sync' })
watch(() => props.telemetryItems, (items) => {
  const next = preferredScreen(screens.value, items)
  if (screen.value === next) { ++overviewGeneration; clearOverview() }
  else screen.value = next
}, { flush: 'sync' })

// Existing screen navigation stays inside the selected target's installed screens.
function showScreen(target, name) { if (target === props.target && screens.value.includes(name)) screen.value = name }
function closeScreenByName() { definition.value = '' }
function closeAll() { definition.value = '' }
defineExpose({ showScreen, closeScreenByName, closeAll })
onBeforeUnmount(() => { disposed = true; generation++; screenGeneration++; cleanup(); clearInterval(clock) })
</script>

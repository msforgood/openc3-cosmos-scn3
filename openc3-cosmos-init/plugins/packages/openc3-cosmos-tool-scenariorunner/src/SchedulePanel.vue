<template>
  <section class="telemetry-panel schedule-panel" aria-label="캘린더에 예약된 TC 스케줄">
    <header class="panel-heading"><h2>예약된 TC 스케줄 · Calendar</h2>
      <span :class="['badge', error ? 'comm-stale' : 'comm-live']" data-test="calendar-status">{{ error ? '조회 실패' : `${timelines.length}개 타임라인` }}</span>
    </header>
    <p v-if="error" role="alert" class="error-text">{{ error }}</p>
    <div class="schedule-week" data-test="schedule-week">
      <button v-for="day in days" :key="day.key" type="button" :class="['schedule-day', { selected: day.key === selectedDay, today: day.today }]"
        :data-test="`schedule-day-${day.key}`" @click="selectedDay = day.key">
        <span class="small">{{ day.weekday }}</span><strong>{{ day.date }}</strong>
        <span class="schedule-dots"><i v-for="activity in day.activities.slice(0, 4)" :key="activity.key" :style="{ background: activity.color }" /></span>
      </button>
    </div>
    <div class="schedule-day-view" data-test="schedule-list">
      <p v-if="!selectedActivities.length" class="empty">이 날짜에 예약된 TC가 없습니다.</p>
      <template v-for="(activity, index) in selectedActivities" :key="activity.key">
        <div v-if="nowIndex === index" class="schedule-now"><span>지금 {{ clock(now) }}</span></div>
        <button type="button" class="schedule-item" :style="{ borderLeftColor: activity.color }" :data-test="`schedule-item-${activity.uuid}`" @click="open(activity)">
          <span class="schedule-time">{{ clock(activity.start * 1000) }} – {{ clock(activity.stop * 1000) }}</span>
          <strong>{{ activity.title }}</strong>
          <span class="small muted">{{ activity.timeline }} · {{ activity.kind }}</span>
          <span :class="['badge', 'schedule-status', `schedule-${activity.status}`]">{{ statusLabel(activity) }}</span>
        </button>
      </template>
      <div v-if="selectedActivities.length && nowIndex === selectedActivities.length" class="schedule-now"><span>지금 {{ clock(now) }}</span></div>
    </div>

    <header class="panel-heading limits-heading"><h2>TM 메시지 수신 · {{ target }} {{ messagePacket }}</h2>
      <span class="muted small">{{ messages.length ? `${messages.length}건` : '대기 중' }}</span>
    </header>
    <div class="event-list" data-test="tm-messages">
      <p v-if="!messages.length" class="empty">{{ messagePacket }} 패킷이 수신되면 여기에 표시됩니다.</p>
      <article v-for="message in messages" :key="message.count" class="limit-event tm-message">
        <time>{{ formatTime(message.received) }}</time>
        <strong>SEQ {{ message.seq }}</strong><code>{{ message.text }}</code>
      </article>
    </div>

    <v-dialog v-model="dialog" max-width="720" aria-label="예약 TC 상세 정보">
      <v-card v-if="detail" class="pa-5 schedule-detail" data-test="schedule-detail">
        <h2>{{ detail.title }}</h2>
        <dl>
          <dt>타임라인</dt><dd>{{ detail.timeline }}</dd>
          <dt>종류</dt><dd>{{ detail.kind }}</dd>
          <dt>실행 시각</dt><dd>{{ fullTime(detail.start) }} – {{ clock(detail.stop * 1000) }}</dd>
          <dt>상태</dt><dd>{{ statusLabel(detail) }}{{ detail.start * 1000 > now ? ` · ${countdown(detail.start)} 후 실행` : '' }}</dd>
          <dt v-if="detail.script">스크립트</dt><dd v-if="detail.script"><code>{{ detail.script }}</code></dd>
          <dt v-if="detail.command">명령</dt><dd v-if="detail.command"><code>{{ detail.command }}</code></dd>
        </dl>
        <h3 class="small">이벤트</h3>
        <div class="event-list">
          <article v-for="(event, index) in detail.events" :key="index" class="limit-event"><time>{{ formatTime(event.time) }}</time><strong>{{ event.event }}</strong><span>{{ event.message }}</span></article>
        </div>
        <v-card-actions><v-spacer /><v-btn @click="dialog = false">Close</v-btn></v-card-actions>
      </v-card>
    </v-dialog>
  </section>
</template>

<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { Api, OpenC3Api } from '@openc3/js-common/services'
import { SerialPoller, formatTime, errorMessage } from './runtime.js'

const props = defineProps({
  target: { type: String, default: '' }, scope: { type: String, required: true },
  messagePacket: { type: String, default: 'MESSAGE' }, refreshKey: { type: [String, Number], default: '' },
})
const DAY = 86400000
const timelines = ref([]), activities = ref([]), error = ref(''), now = ref(Date.now())
const messages = ref([]), dialog = ref(false), detail = ref(null)
const dayKey = (ms) => { const d = new Date(ms); return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}` }
const startOfDay = (ms) => { const d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime() }
const selectedDay = ref(dayKey(Date.now()))
const clock = (ms) => new Date(ms).toLocaleTimeString('ko-KR', { hour12: false })
const fullTime = (seconds) => new Date(seconds * 1000).toLocaleString('ko-KR', { hour12: false })
function countdown(seconds) {
  const left = Math.max(0, Math.round(seconds - now.value / 1000))
  return `${Math.floor(left / 60)}분 ${left % 60}초`
}

function status(activity) {
  const last = (activity.events || []).at(-1)?.event || ''
  if (/error|fail/i.test(last)) return 'failed'
  if (/complete/i.test(last)) return 'completed'
  if (/start|running|paused/i.test(last) || activity.fulfillment) return 'running'
  if (/disable/i.test(last)) return 'disabled'
  return activity.stop * 1000 < now.value ? 'missed' : 'scheduled'
}
const labels = { scheduled: '예약됨', running: '실행 중', completed: '완료', failed: '실패', disabled: '비활성', missed: '미실행' }
const statusLabel = (activity) => labels[activity.status] || activity.status

const days = computed(() => {
  const first = startOfDay(now.value) - DAY
  return Array.from({ length: 7 }, (_, index) => {
    const ms = first + index * DAY
    const key = dayKey(ms)
    return {
      key, today: key === dayKey(now.value),
      weekday: new Date(ms).toLocaleDateString('ko-KR', { weekday: 'short' }),
      date: new Date(ms).getDate(),
      activities: activities.value.filter((activity) => dayKey(activity.start * 1000) === key),
    }
  })
})
const selectedActivities = computed(() => days.value.find((day) => day.key === selectedDay.value)?.activities || [])
const nowIndex = computed(() => selectedDay.value !== dayKey(now.value) ? -1
  : selectedActivities.value.findIndex((activity) => activity.start * 1000 > now.value) === -1 ? selectedActivities.value.length
    : selectedActivities.value.findIndex((activity) => activity.start * 1000 > now.value))

async function loadCalendar() {
  const list = (await Api.get('/openc3-api/timeline', { params: { scope: props.scope } })).data
  if (!Array.isArray(list)) throw new Error('Invalid timeline list')
  const start = new Date(startOfDay(Date.now()) - DAY).toISOString()
  const stop = new Date(startOfDay(Date.now()) + 6 * DAY).toISOString()
  const results = await Promise.all(list.map((timeline) =>
    Api.get(`/openc3-api/timeline/${encodeURIComponent(timeline.name)}/activities`, { params: { scope: props.scope, start, stop } })
      .then((response) => (Array.isArray(response.data) ? response.data : []).map((activity) => ({ ...activity, timeline: timeline.name, color: timeline.color || '#1e88e5' })))))
  timelines.value = list
  activities.value = results.flat().map((activity) => {
    const script = activity.kind === 'script' ? activity.data?.script || '' : ''
    const command = activity.kind === 'command' ? activity.data?.command || '' : ''
    return {
      ...activity, key: `${activity.timeline}:${activity.start}:${activity.uuid}`, script, command,
      title: script ? script.split('/').pop().replace(/\.(py|rb)$/, '') : command || activity.kind,
      events: (activity.events || []).map((event) => ({ ...event, time: event.time ? event.time * 1000 : null })),
      status: status(activity),
    }
  }).sort((a, b) => a.start - b.start)
  if (detail.value) detail.value = activities.value.find((activity) => activity.key === detail.value.key) || detail.value
  error.value = ''
}

let messageCount = null
async function loadMessages() {
  if (!props.target) return
  const names = ['SEQ', 'TEXT', 'RECEIVED_COUNT', 'RECEIVED_TIMESECONDS']
  const rows = await new OpenC3Api().get_tlm_values(names.map((name) => `${props.target}__${props.messagePacket}__${name}__CONVERTED`))
  const [seq, text, count, received] = rows.map((row) => row[0])
  if (typeof count !== 'number' || count === messageCount) return
  // Show the latest frame already received when the panel opens, then every new one.
  if (count > 0) messages.value = [{ count, seq, text, received: received * 1000 }, ...messages.value].slice(0, 50)
  messageCount = count
}

function open(activity) {
  detail.value = activity
  dialog.value = true
}

const calendarPoller = new SerialPoller(async (current) => { await loadCalendar(); if (!current()) return }, { interval: 5000, onError: (e) => { error.value = `캘린더를 불러오지 못했습니다: ${errorMessage(e)}` } })
const messagePoller = new SerialPoller(() => loadMessages(), { interval: 500, onError: () => {} })
const clockTimer = setInterval(() => { now.value = Date.now() }, 1000)
calendarPoller.start()
messagePoller.start()
watch(() => props.refreshKey, () => { calendarPoller.stop(); calendarPoller.start() })
watch(() => props.target, () => { messages.value = []; messageCount = null })
onBeforeUnmount(() => { calendarPoller.stop(); messagePoller.stop(); clearInterval(clockTimer) })
</script>

<!--
# Copyright 2026 OpenC3, Inc.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU Affero General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# This file may also be used under the terms of a commercial license
# if purchased from OpenC3, Inc.
-->

<template>
  <div class="calendar-view" data-test="calendar-view">
    <!-- MONTH VIEW -->
    <div v-if="type === 'month'" class="month">
      <div class="month-header">
        <div v-for="day in weekDayNames" :key="day" class="month-header-cell">
          {{ day }}
        </div>
      </div>
      <div class="month-grid" :style="{ gridTemplateRows: monthRows }">
        <div
          v-for="day in monthDays"
          :key="day.key"
          class="month-cell"
          :class="{
            'month-cell--outside': !day.inMonth,
            'month-cell--today': day.today,
          }"
          :data-test="`calendar-day-${day.key}`"
          @contextmenu.prevent="openContextMenu($event, day.date, null)"
        >
          <div class="month-cell-date">
            <a href="#" @click.prevent="$emit('show-day', day.date)">
              {{ day.date.getDate() }}
            </a>
          </div>
          <div
            v-for="event in day.events.slice(0, maxMonthEvents)"
            :key="`${day.key}-${event.id}`"
            class="event-chip"
            :style="chipStyle(event)"
            :title="eventTooltip(event)"
            :data-test="`event-${event.type}`"
            @click.stop="$emit('select', event)"
            @contextmenu.stop.prevent
          >
            <activity-status-icon
              v-if="event.type === 'activity'"
              :activity="event.activity"
              :progress-icon="progressIcon"
              class="mr-1"
            />
            <v-icon v-else size="x-small" class="mr-1">
              {{ typeIcon(event.type) }}
            </v-icon>
            <span class="event-time">{{ timeLabel(event.start) }}</span>
            <span class="event-name">{{ event.name }}</span>
          </div>
          <div
            v-if="day.events.length > maxMonthEvents"
            class="more-events"
            @click.stop="$emit('show-day', day.date)"
          >
            +{{ day.events.length - maxMonthEvents }} more
          </div>
        </div>
      </div>
    </div>

    <!-- WEEK / DAY VIEW -->
    <div v-else class="timegrid">
      <div class="timegrid-header">
        <div class="timegrid-gutter" />
        <div
          v-for="day in gridDays"
          :key="`header-${day.key}`"
          class="timegrid-header-cell"
          :class="{ 'timegrid-header-cell--today': day.today }"
        >
          <a href="#" @click.prevent="$emit('show-day', day.date)">
            {{ dayHeader(day.date) }}
          </a>
        </div>
      </div>
      <div ref="scroller" class="timegrid-body">
        <div class="timegrid-inner" :style="{ height: `${24 * hourHeight}px` }">
          <div class="timegrid-gutter">
            <div
              v-for="hour in 24"
              :key="`hour-${hour}`"
              class="timegrid-hour-label"
              :style="{ height: `${hourHeight}px` }"
            >
              {{ hourLabel(hour - 1) }}
            </div>
          </div>
          <div
            v-for="day in gridDays"
            :key="`col-${day.key}`"
            class="timegrid-column"
            :data-test="`calendar-column-${day.key}`"
            @contextmenu.prevent="columnContextMenu($event, day.date)"
          >
            <div
              v-for="hour in 24"
              :key="`slot-${day.key}-${hour}`"
              class="timegrid-slot"
              :style="{ height: `${hourHeight}px` }"
            />
            <div
              v-if="day.today"
              class="now-line"
              :style="{ top: `${nowOffset}px` }"
            />
            <div
              v-for="seg in day.segments"
              :key="`${day.key}-${seg.event.id}`"
              class="timegrid-event"
              :style="segmentStyle(seg)"
              :title="eventTooltip(seg.event)"
              :data-test="`event-${seg.event.type}`"
              @click.stop="$emit('select', seg.event)"
              @contextmenu.stop.prevent
            >
              <div class="d-flex align-center">
                <activity-status-icon
                  v-if="seg.event.type === 'activity'"
                  :activity="seg.event.activity"
                  :progress-icon="progressIcon"
                  class="mr-1"
                />
                <v-icon v-else size="x-small" class="mr-1">
                  {{ typeIcon(seg.event.type) }}
                </v-icon>
                <span class="event-name">{{ seg.event.name }}</span>
              </div>
              <div v-if="seg.height > 30" class="event-time">
                {{ timeLabel(seg.event.start) }}
                <span v-if="seg.event.type !== 'metadata'">
                  - {{ timeLabel(seg.event.end) }}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- RIGHT CLICK MENU -->
    <v-menu v-model="contextMenu" :target="contextTarget" location="end">
      <v-list density="compact">
        <v-list-subheader>{{ contextLabel }}</v-list-subheader>
        <v-list-item
          data-test="context-create-activity"
          prepend-icon="mdi-calendar-clock"
          title="Create Activity"
          @click="create('activity')"
        />
        <v-list-item
          data-test="context-create-note"
          prepend-icon="mdi-note-text"
          title="Create Note"
          @click="create('note')"
        />
        <v-list-item
          data-test="context-create-metadata"
          prepend-icon="mdi-tag-text"
          title="Create Metadata"
          @click="create('metadata')"
        />
      </v-list>
    </v-menu>
  </div>
</template>

<script>
import {
  addDays,
  addMinutes,
  endOfMonth,
  endOfWeek,
  format,
  isSameDay,
  isSameMonth,
  startOfDay,
  startOfMonth,
  startOfWeek,
} from 'date-fns'
import ActivityStatusIcon from './ActivityStatusIcon.vue'
import { toDisplay } from './util'

const MIN_EVENT_MINUTES = 15

export default {
  components: {
    ActivityStatusIcon,
  },
  props: {
    events: {
      type: Array,
      required: true,
    },
    type: {
      type: String,
      default: 'week', // month, week, day
    },
    // Focus date in display space
    focus: {
      type: Date,
      required: true,
    },
    weekStart: {
      type: Number,
      default: 0,
    },
    timeZone: {
      type: String,
      default: 'local',
    },
    progressIcon: {
      type: String,
      default: 'mdi-loading',
    },
  },
  emits: ['select', 'create', 'show-day'],
  data() {
    return {
      hourHeight: 48,
      maxMonthEvents: 4,
      contextMenu: false,
      contextTarget: [0, 0],
      contextDate: null,
      contextTime: null,
      now: toDisplay(new Date(), this.timeZone),
      nowTimer: null,
    }
  },
  computed: {
    displayEvents: function () {
      return this.events
        .map((event) => {
          return {
            event,
            start: toDisplay(event.start, this.timeZone),
            end: toDisplay(event.end, this.timeZone),
          }
        })
        .sort((a, b) => a.start - b.start)
    },
    weekDayNames: function () {
      const start = startOfWeek(new Date(), { weekStartsOn: this.weekStart })
      return [...Array(7).keys()].map((i) => format(addDays(start, i), 'EEE'))
    },
    monthDays: function () {
      const first = startOfWeek(startOfMonth(this.focus), {
        weekStartsOn: this.weekStart,
      })
      const last = endOfWeek(endOfMonth(this.focus), {
        weekStartsOn: this.weekStart,
      })
      const days = []
      for (let day = first; day <= last; day = addDays(day, 1)) {
        days.push({
          key: format(day, 'yyyy-MM-dd'),
          date: day,
          inMonth: isSameMonth(day, this.focus),
          today: isSameDay(day, this.now),
          events: this.eventsForDay(day).map((e) => e.event),
        })
      }
      return days
    },
    monthRows: function () {
      return `repeat(${this.monthDays.length / 7}, minmax(110px, 1fr))`
    },
    gridDays: function () {
      let start = startOfDay(this.focus)
      let count = 1
      if (this.type === 'week') {
        start = startOfWeek(this.focus, { weekStartsOn: this.weekStart })
        count = 7
      }
      return [...Array(count).keys()].map((i) => {
        const day = addDays(start, i)
        return {
          key: format(day, 'yyyy-MM-dd'),
          date: day,
          today: isSameDay(day, this.now),
          segments: this.layoutDay(day),
        }
      })
    },
    nowOffset: function () {
      return (
        ((this.now.getHours() * 60 + this.now.getMinutes()) / 60) *
        this.hourHeight
      )
    },
    contextLabel: function () {
      if (!this.contextDate) return ''
      if (this.contextTime) {
        return `${this.contextDate} ${this.contextTime.substring(0, 5)}`
      }
      return this.contextDate
    },
  },
  watch: {
    type: function () {
      this.$nextTick(this.scrollToWorkingHours)
    },
    timeZone: function () {
      this.now = toDisplay(new Date(), this.timeZone)
    },
  },
  mounted: function () {
    this.scrollToWorkingHours()
    this.nowTimer = setInterval(() => {
      this.now = toDisplay(new Date(), this.timeZone)
    }, 30000)
  },
  unmounted: function () {
    clearInterval(this.nowTimer)
  },
  methods: {
    scrollToWorkingHours: function () {
      if (this.$refs.scroller) {
        const hour = Math.max(this.now.getHours() - 2, 0)
        this.$refs.scroller.scrollTop = hour * this.hourHeight
      }
    },
    eventsForDay: function (day) {
      const dayStart = startOfDay(day)
      const dayEnd = addDays(dayStart, 1)
      return this.displayEvents.filter((e) => {
        if (e.end.getTime() === e.start.getTime()) {
          return e.start >= dayStart && e.start < dayEnd
        }
        return e.start < dayEnd && e.end > dayStart
      })
    },
    // Compute positioned segments for a single day with simple overlap columns
    layoutDay: function (day) {
      const dayStart = startOfDay(day)
      const dayEnd = addDays(dayStart, 1)
      const segments = this.eventsForDay(day).map((e) => {
        const start = e.start < dayStart ? dayStart : e.start
        let end = e.end > dayEnd ? dayEnd : e.end
        if (end - start < MIN_EVENT_MINUTES * 60000) {
          end = addMinutes(start, MIN_EVENT_MINUTES)
        }
        const top = ((start - dayStart) / 3600000) * this.hourHeight
        const height = Math.max(((end - start) / 3600000) * this.hourHeight, 14)
        return { event: e.event, start, end, top, height, col: 0, cols: 1 }
      })
      // Group overlapping segments into clusters and assign columns
      let cluster = []
      let clusterEnd = null
      const finish = () => {
        const columns = []
        cluster.forEach((seg) => {
          let col = columns.findIndex((colEnd) => colEnd <= seg.start)
          if (col === -1) {
            col = columns.length
            columns.push(seg.end)
          } else {
            columns[col] = seg.end
          }
          seg.col = col
        })
        cluster.forEach((seg) => (seg.cols = columns.length))
      }
      segments.forEach((seg) => {
        if (clusterEnd && seg.start >= clusterEnd) {
          finish()
          cluster = []
          clusterEnd = null
        }
        cluster.push(seg)
        if (!clusterEnd || seg.end > clusterEnd) clusterEnd = seg.end
      })
      if (cluster.length) finish()
      return segments
    },
    segmentStyle: function (seg) {
      const width = 100 / seg.cols
      return {
        top: `${seg.top}px`,
        height: `${seg.height}px`,
        left: `calc(${seg.col * width}% + 1px)`,
        width: `calc(${width}% - 3px)`,
        backgroundColor: seg.event.color,
      }
    },
    chipStyle: function (event) {
      return { backgroundColor: event.color }
    },
    typeIcon: function (type) {
      return type === 'note' ? 'mdi-note-text' : 'mdi-tag-text'
    },
    timeLabel: function (date) {
      return format(toDisplay(date, this.timeZone), 'HH:mm')
    },
    hourLabel: function (hour) {
      return `${String(hour).padStart(2, '0')}:00`
    },
    dayHeader: function (date) {
      return format(date, 'EEE M/d')
    },
    eventTooltip: function (event) {
      const start = format(
        toDisplay(event.start, this.timeZone),
        'yyyy-MM-dd HH:mm:ss',
      )
      if (event.type === 'metadata') {
        return `${event.name}\n${start}`
      }
      const end = format(
        toDisplay(event.end, this.timeZone),
        'yyyy-MM-dd HH:mm:ss',
      )
      return `${event.name}\n${start} - ${end}`
    },
    openContextMenu: function (mouseEvent, date, time) {
      this.contextDate = format(date, 'yyyy-MM-dd')
      this.contextTime = time
      this.contextTarget = [mouseEvent.clientX, mouseEvent.clientY]
      this.contextMenu = true
    },
    columnContextMenu: function (mouseEvent, date) {
      const rect = mouseEvent.currentTarget.getBoundingClientRect()
      const y = mouseEvent.clientY - rect.top
      // Round down to the nearest 30 minute slot
      let minutes = Math.floor(((y / this.hourHeight) * 60) / 30) * 30
      minutes = Math.min(Math.max(minutes, 0), 23 * 60 + 30)
      const hh = String(Math.floor(minutes / 60)).padStart(2, '0')
      const mm = String(minutes % 60).padStart(2, '0')
      this.openContextMenu(mouseEvent, date, `${hh}:${mm}:00`)
    },
    create: function (kind) {
      this.contextMenu = false
      this.$emit('create', {
        kind,
        date: this.contextDate,
        time: this.contextTime,
      })
    },
  },
}
</script>

<style scoped>
.calendar-view {
  height: 100%;
  user-select: none;
}
.month-header,
.timegrid-header {
  display: flex;
  border-bottom: 1px solid rgba(255, 255, 255, 0.2);
}
.month-header-cell {
  flex: 1;
  text-align: center;
  font-weight: bold;
  padding: 4px;
}
.month-grid {
  display: grid;
  grid-template-columns: repeat(7, minmax(0, 1fr));
}
.month-cell {
  border-right: 1px solid rgba(255, 255, 255, 0.1);
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  padding: 2px;
  overflow: hidden;
  min-width: 0;
}
.month-cell--outside {
  opacity: 0.5;
}
.month-cell--today .month-cell-date a {
  background-color: rgb(var(--v-theme-primary));
  border-radius: 50%;
  padding: 0 6px;
}
.month-cell-date {
  text-align: center;
  font-size: 0.85rem;
  margin-bottom: 2px;
}
.month-cell-date a,
.timegrid-header-cell a {
  color: inherit;
  text-decoration: none;
}
.event-chip {
  display: flex;
  align-items: center;
  border-radius: 3px;
  padding: 0 4px;
  margin-bottom: 1px;
  font-size: 0.75rem;
  color: white;
  cursor: pointer;
  white-space: nowrap;
  overflow: hidden;
}
.event-time {
  margin-right: 4px;
  font-size: 0.7rem;
  opacity: 0.9;
}
.event-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.more-events {
  font-size: 0.75rem;
  cursor: pointer;
  padding-left: 4px;
}
.timegrid {
  display: flex;
  flex-direction: column;
  height: 100%;
}
.timegrid-header-cell {
  flex: 1;
  text-align: center;
  padding: 4px;
  font-weight: bold;
}
.timegrid-header-cell--today {
  color: rgb(var(--v-theme-primary));
}
.timegrid-gutter {
  width: 56px;
  flex: 0 0 56px;
}
.timegrid-body {
  overflow-y: auto;
  height: calc(100vh - 260px);
  min-height: 400px;
}
.timegrid-inner {
  display: flex;
  position: relative;
}
.timegrid-hour-label {
  font-size: 0.7rem;
  text-align: right;
  padding-right: 6px;
  transform: translateY(-6px);
}
.timegrid-column {
  flex: 1;
  position: relative;
  border-left: 1px solid rgba(255, 255, 255, 0.1);
  min-width: 0;
}
.timegrid-slot {
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  box-sizing: border-box;
}
.timegrid-event {
  position: absolute;
  border-radius: 3px;
  padding: 1px 4px;
  font-size: 0.75rem;
  color: white;
  overflow: hidden;
  cursor: pointer;
  border: 1px solid rgba(0, 0, 0, 0.3);
  box-sizing: border-box;
}
.now-line {
  position: absolute;
  left: 0;
  right: 0;
  height: 2px;
  background-color: #ff3838;
  z-index: 2;
  pointer-events: none;
}
</style>

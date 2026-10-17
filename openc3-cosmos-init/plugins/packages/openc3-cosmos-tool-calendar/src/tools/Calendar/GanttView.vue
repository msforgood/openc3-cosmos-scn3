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
  <div class="gantt" data-test="gantt-view">
    <div class="gantt-row gantt-axis">
      <div class="gantt-label" />
      <div class="gantt-track">
        <div
          v-for="hour in 24"
          :key="`tick-${hour}`"
          class="gantt-tick"
          :style="{ left: `${((hour - 1) / 24) * 100}%` }"
        >
          {{ String(hour - 1).padStart(2, '0') }}
        </div>
      </div>
    </div>
    <div v-if="rows.length === 0" class="pa-4 text-center">
      Nothing selected to display
    </div>
    <div
      v-for="row in rows"
      :key="row.key"
      class="gantt-row"
      :data-test="`gantt-row-${row.key}`"
    >
      <div class="gantt-label" :title="row.label">
        <v-icon :color="row.color" size="small" class="mr-1">
          {{ row.icon }}
        </v-icon>
        <span class="gantt-label-text">{{ row.label }}</span>
      </div>
      <div
        class="gantt-track"
        :style="{ height: `${Math.max(row.lanes, 1) * laneHeight + 8}px` }"
        @contextmenu.prevent="trackContextMenu($event)"
      >
        <div
          v-for="hour in 24"
          :key="`grid-${row.key}-${hour}`"
          class="gantt-grid"
          :style="{ left: `${((hour - 1) / 24) * 100}%` }"
        />
        <div
          v-if="isToday"
          class="gantt-now"
          :style="{ left: `${nowPercent}%` }"
        />
        <div
          v-for="bar in row.bars"
          :key="bar.event.id"
          class="gantt-bar"
          :class="{ 'gantt-bar--point': bar.point }"
          :style="barStyle(bar)"
          :title="tooltip(bar.event)"
          :data-test="`gantt-${bar.event.type}`"
          @click.stop="$emit('select', bar.event)"
          @contextmenu.stop.prevent
        >
          <activity-status-icon
            v-if="bar.event.type === 'activity'"
            :activity="bar.event.activity"
            :progress-icon="progressIcon"
            class="mr-1"
          />
          <span v-if="!bar.point" class="gantt-bar-text">
            {{ bar.event.name }}
          </span>
        </div>
      </div>
    </div>

    <v-menu v-model="contextMenu" :target="contextTarget" location="end">
      <v-list density="compact">
        <v-list-subheader>{{ contextDate }} {{ contextTime }}</v-list-subheader>
        <v-list-item
          prepend-icon="mdi-calendar-clock"
          title="Create Activity"
          data-test="gantt-create-activity"
          @click="create('activity')"
        />
        <v-list-item
          prepend-icon="mdi-note-text"
          title="Create Note"
          data-test="gantt-create-note"
          @click="create('note')"
        />
        <v-list-item
          prepend-icon="mdi-tag-text"
          title="Create Metadata"
          data-test="gantt-create-metadata"
          @click="create('metadata')"
        />
      </v-list>
    </v-menu>
  </div>
</template>

<script>
import { addDays, format, isSameDay, startOfDay } from 'date-fns'
import ActivityStatusIcon from './ActivityStatusIcon.vue'
import { toDisplay } from './util'

const DAY_MS = 86400000

export default {
  components: {
    ActivityStatusIcon,
  },
  props: {
    events: {
      type: Array,
      required: true,
    },
    timelines: {
      type: Array,
      required: true,
    },
    showMetadata: {
      type: Boolean,
      default: true,
    },
    showNotes: {
      type: Boolean,
      default: true,
    },
    focus: {
      type: Date,
      required: true,
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
  emits: ['select', 'create'],
  data() {
    return {
      laneHeight: 24,
      contextMenu: false,
      contextTarget: [0, 0],
      contextDate: '',
      contextTime: '',
      now: toDisplay(new Date(), this.timeZone),
      nowTimer: null,
    }
  },
  computed: {
    dayStart: function () {
      return startOfDay(this.focus)
    },
    isToday: function () {
      return isSameDay(this.now, this.focus)
    },
    nowPercent: function () {
      return ((this.now - this.dayStart) / DAY_MS) * 100
    },
    dayEvents: function () {
      const dayEnd = addDays(this.dayStart, 1)
      return this.events
        .map((event) => ({
          event,
          start: toDisplay(event.start, this.timeZone),
          end: toDisplay(event.end, this.timeZone),
        }))
        .filter((e) => {
          if (e.start.getTime() === e.end.getTime()) {
            return e.start >= this.dayStart && e.start < dayEnd
          }
          return e.start < dayEnd && e.end > this.dayStart
        })
        .sort((a, b) => a.start - b.start)
    },
    rows: function () {
      const rows = [...this.timelines]
        .sort((a, b) => (a.name > b.name ? 1 : -1))
        .map((timeline) => {
          return this.makeRow(
            `timeline-${timeline.name}`,
            timeline.name,
            'mdi-timeline-clock',
            timeline.color,
            this.dayEvents.filter(
              (e) =>
                e.event.type === 'activity' &&
                e.event.timeline === timeline.name,
            ),
          )
        })
      if (this.showNotes) {
        rows.push(
          this.makeRow(
            'notes',
            'Notes',
            'mdi-note-text',
            undefined,
            this.dayEvents.filter((e) => e.event.type === 'note'),
          ),
        )
      }
      if (this.showMetadata) {
        rows.push(
          this.makeRow(
            'metadata',
            'Metadata',
            'mdi-tag-text',
            undefined,
            this.dayEvents.filter((e) => e.event.type === 'metadata'),
          ),
        )
      }
      return rows
    },
  },
  watch: {
    timeZone: function () {
      this.now = toDisplay(new Date(), this.timeZone)
    },
  },
  mounted: function () {
    this.nowTimer = setInterval(() => {
      this.now = toDisplay(new Date(), this.timeZone)
    }, 30000)
  },
  unmounted: function () {
    clearInterval(this.nowTimer)
  },
  methods: {
    makeRow: function (key, label, icon, color, items) {
      const dayEnd = addDays(this.dayStart, 1)
      const laneEnds = []
      const bars = items.map((item) => {
        const start = item.start < this.dayStart ? this.dayStart : item.start
        const end = item.end > dayEnd ? dayEnd : item.end
        const point = item.start.getTime() === item.end.getTime()
        // Point events take a small visual width for lane assignment
        const visualEnd = point ? new Date(start.getTime() + 10 * 60000) : end
        let lane = laneEnds.findIndex((laneEnd) => laneEnd <= start)
        if (lane === -1) {
          lane = laneEnds.length
          laneEnds.push(visualEnd)
        } else {
          laneEnds[lane] = visualEnd
        }
        return {
          event: item.event,
          left: ((start - this.dayStart) / DAY_MS) * 100,
          width: ((end - start) / DAY_MS) * 100,
          lane,
          point,
        }
      })
      return { key, label, icon, color, bars, lanes: laneEnds.length }
    },
    barStyle: function (bar) {
      const style = {
        left: `${bar.left}%`,
        top: `${bar.lane * this.laneHeight + 4}px`,
        height: `${this.laneHeight - 4}px`,
        backgroundColor: bar.event.color,
      }
      if (!bar.point) {
        style.width = `max(${bar.width}%, 6px)`
      }
      return style
    },
    tooltip: function (event) {
      const fmt = 'yyyy-MM-dd HH:mm:ss'
      const start = format(toDisplay(event.start, this.timeZone), fmt)
      if (event.type === 'metadata') {
        return `${event.name}\n${start}`
      }
      const end = format(toDisplay(event.end, this.timeZone), fmt)
      return `${event.name}\n${start} - ${end}`
    },
    trackContextMenu: function (mouseEvent) {
      const rect = mouseEvent.currentTarget.getBoundingClientRect()
      const ratio = (mouseEvent.clientX - rect.left) / rect.width
      let minutes = Math.floor((ratio * 24 * 60) / 30) * 30
      minutes = Math.min(Math.max(minutes, 0), 23 * 60 + 30)
      const hh = String(Math.floor(minutes / 60)).padStart(2, '0')
      const mm = String(minutes % 60).padStart(2, '0')
      this.contextDate = format(this.dayStart, 'yyyy-MM-dd')
      this.contextTime = `${hh}:${mm}:00`
      this.contextTarget = [mouseEvent.clientX, mouseEvent.clientY]
      this.contextMenu = true
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
.gantt {
  user-select: none;
}
.gantt-row {
  display: flex;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}
.gantt-axis {
  height: 24px;
  font-size: 0.7rem;
}
.gantt-label {
  flex: 0 0 180px;
  width: 180px;
  display: flex;
  align-items: center;
  padding: 0 8px;
  overflow: hidden;
  border-right: 1px solid rgba(255, 255, 255, 0.2);
}
.gantt-label-text {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.gantt-track {
  flex: 1;
  position: relative;
  min-height: 32px;
}
.gantt-axis .gantt-track {
  min-height: 24px;
}
.gantt-tick {
  position: absolute;
  top: 4px;
  transform: translateX(-50%);
}
.gantt-tick:first-child {
  transform: none;
}
.gantt-grid {
  position: absolute;
  top: 0;
  bottom: 0;
  border-left: 1px solid rgba(255, 255, 255, 0.07);
}
.gantt-now {
  position: absolute;
  top: 0;
  bottom: 0;
  width: 2px;
  background-color: #ff3838;
  z-index: 2;
  pointer-events: none;
}
.gantt-bar {
  position: absolute;
  display: flex;
  align-items: center;
  border-radius: 3px;
  padding: 0 4px;
  font-size: 0.75rem;
  color: white;
  overflow: hidden;
  cursor: pointer;
  border: 1px solid rgba(0, 0, 0, 0.3);
  box-sizing: border-box;
}
.gantt-bar--point {
  width: 14px;
  padding: 0;
  justify-content: center;
  border-radius: 50%;
  transform: translateX(-7px);
}
.gantt-bar-text {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>

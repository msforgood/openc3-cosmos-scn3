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
  <div>
    <top-bar :menus="menus" :title="title" />
    <div class="d-flex calendar-layout">
      <!-- SIDEBAR -->
      <div class="calendar-sidebar pa-1">
        <v-date-picker
          :model-value="focus"
          :first-day-of-week="settings.weekStart"
          hide-header
          show-adjacent-months
          density="compact"
          width="100%"
          data-test="mini-calendar"
          @update:model-value="setFocus"
        />
        <calendar-selector
          v-model:hidden="hiddenTimelines"
          v-model:show-metadata="showMetadata"
          v-model:show-notes="showNotes"
          class="mt-2"
          :timelines="timelines"
          @create-timeline="showTimelineCreate = true"
        />
      </div>

      <!-- MAIN -->
      <div class="calendar-main pa-1">
        <v-card variant="flat" class="calendar-card">
          <div class="d-flex align-center flex-wrap pa-2 calendar-toolbar">
            <v-btn
              variant="outlined"
              size="small"
              class="mr-2"
              data-test="calendar-today"
              @click="today"
            >
              Today
            </v-btn>
            <v-btn
              icon="mdi-chevron-left"
              variant="text"
              size="small"
              data-test="calendar-prev"
              :aria-label="isDayOnly ? 'Previous Day' : 'Previous'"
              @click="prev"
            />
            <v-btn
              icon="mdi-chevron-right"
              variant="text"
              size="small"
              data-test="calendar-next"
              :aria-label="isDayOnly ? 'Next Day' : 'Next'"
              @click="next"
            />
            <span class="text-h6 ml-2" data-test="calendar-title">
              {{ rangeTitle }}
            </span>
            <span class="text-caption ml-2">({{ timeZoneLabel }})</span>
            <v-spacer />
            <v-btn-toggle
              v-if="view === 'calendar'"
              v-model="calendarType"
              mandatory
              density="compact"
              variant="outlined"
              divided
              class="mr-4"
              data-test="calendar-type"
            >
              <v-btn value="month" data-test="calendar-type-month">Month</v-btn>
              <v-btn value="week" data-test="calendar-type-week">Week</v-btn>
              <v-btn value="day" data-test="calendar-type-day">Day</v-btn>
            </v-btn-toggle>
            <v-btn-toggle
              v-model="view"
              mandatory
              density="compact"
              variant="outlined"
              divided
              color="primary"
              data-test="calendar-view-toggle"
            >
              <v-btn
                value="calendar"
                prepend-icon="mdi-calendar"
                data-test="view-calendar"
              >
                Calendar
              </v-btn>
              <v-btn
                value="gantt"
                prepend-icon="mdi-chart-gantt"
                data-test="view-gantt"
              >
                Gantt
              </v-btn>
              <v-btn
                value="list"
                prepend-icon="mdi-format-list-bulleted"
                data-test="view-list"
              >
                List
              </v-btn>
            </v-btn-toggle>
          </div>
          <v-divider />
          <div class="pa-2">
            <calendar-view
              v-if="view === 'calendar'"
              :events="visibleEvents"
              :type="calendarType"
              :focus="focus"
              :week-start="settings.weekStart"
              :time-zone="timeZone"
              :progress-icon="settings.progressIcon"
              @select="selectEvent"
              @create="createFromContext"
              @show-day="showDay"
            />
            <gantt-view
              v-else-if="view === 'gantt'"
              :events="visibleEvents"
              :timelines="visibleTimelines"
              :show-metadata="showMetadata"
              :show-notes="showNotes"
              :focus="focus"
              :time-zone="timeZone"
              :progress-icon="settings.progressIcon"
              @select="selectEvent"
              @create="createFromContext"
            />
            <list-view
              v-else
              :events="visibleEvents"
              :focus="focus"
              :time-zone="timeZone"
              :progress-icon="settings.progressIcon"
              @select="selectEvent"
            />
          </div>
        </v-card>
      </div>
    </div>

    <!-- DIALOGS -->
    <timeline-create-dialog
      v-if="showTimelineCreate"
      v-model="showTimelineCreate"
      :timelines="timelines"
    />
    <activity-create-dialog
      v-if="showActivityCreate"
      v-model="showActivityCreate"
      :timelines="timelines"
      :activity="editActivity"
      :date="createDate"
      :time="createTime"
      :time-zone="dialogTimeZone"
      @update="refresh"
    />
    <note-create-dialog
      v-if="showNoteCreate"
      v-model="showNoteCreate"
      :note="editNote"
      :date="createDate"
      :time="createTime"
      :time-zone="dialogTimeZone"
      @update="updateEvents"
    />
    <metadata-create-dialog
      v-if="showMetadataCreate"
      v-model="showMetadataCreate"
      :metadata="editMetadata"
      :date="createDate"
      :time="createTime"
      :time-zone="dialogTimeZone"
      @update="updateEvents"
    />
    <event-details-dialog
      v-if="showDetails"
      v-model="showDetails"
      :event="selectedEvent"
      :time-zone="timeZone"
      :progress-icon="settings.progressIcon"
      @edit="editEvent"
      @deleted="refresh"
    />
    <options-dialog
      v-if="showOptions"
      v-model="showOptions"
      :settings="settings"
      @save="saveSettings"
    />
    <environment-dialog v-if="showEnvironment" v-model="showEnvironment" />
  </div>
</template>

<script>
import {
  addDays,
  addMonths,
  addWeeks,
  endOfWeek,
  format,
  parse,
  startOfDay,
  startOfWeek,
  subDays,
  subMonths,
  subWeeks,
} from 'date-fns'
import { Api, Cable, OpenC3Api } from '@openc3/js-common/services'
import { EnvironmentDialog, TopBar } from '@openc3/vue-common/components'
import {
  ActivityCreateDialog,
  MetadataCreateDialog,
  NoteCreateDialog,
} from '@openc3/vue-common/tools/calendar'
import CalendarSelector from './CalendarSelector.vue'
import CalendarView from './CalendarView.vue'
import EventDetailsDialog from './EventDetailsDialog.vue'
import GanttView from './GanttView.vue'
import ListView from './ListView.vue'
import OptionsDialog from './OptionsDialog.vue'
import TimelineCreateDialog from './TimelineCreateDialog.vue'
import {
  DEFAULT_SETTINGS,
  SETTINGS_KEY,
  fromDisplay,
  makeActivityEvent,
  makeMetadataEvent,
  makeNoteEvent,
  toDisplay,
} from './util'

export default {
  components: {
    ActivityCreateDialog,
    CalendarSelector,
    CalendarView,
    EnvironmentDialog,
    EventDetailsDialog,
    GanttView,
    ListView,
    MetadataCreateDialog,
    NoteCreateDialog,
    OptionsDialog,
    TimelineCreateDialog,
    TopBar,
  },
  data() {
    return {
      title: 'Calendar',
      api: new OpenC3Api(),
      cable: new Cable(),
      subscriptions: [],
      timeZone: 'local',
      settings: { ...DEFAULT_SETTINGS },
      rawSettings: {},
      view: DEFAULT_SETTINGS.defaultView,
      calendarType: DEFAULT_SETTINGS.calendarType,
      focus: startOfDay(new Date()),
      timelines: [],
      hiddenTimelines: [],
      showMetadata: true,
      showNotes: true,
      activities: {},
      metadata: [],
      notes: [],
      loadedRange: null,
      refreshTimer: null,
      eventsTimer: null,
      // Dialogs
      showTimelineCreate: false,
      showActivityCreate: false,
      showNoteCreate: false,
      showMetadataCreate: false,
      showDetails: false,
      showOptions: false,
      showEnvironment: false,
      selectedId: null,
      editActivity: null,
      editNote: null,
      editMetadata: null,
      createDate: undefined,
      createTime: undefined,
    }
  },
  computed: {
    menus: function () {
      return [
        {
          label: 'File',
          items: [
            {
              label: 'Options',
              icon: 'mdi-cog',
              command: () => {
                this.showOptions = true
              },
            },
            {
              label: 'Refresh Display',
              icon: 'mdi-refresh',
              command: () => {
                this.refresh()
              },
            },
            {
              label: 'Global Environment',
              icon: 'mdi-library',
              command: () => {
                this.showEnvironment = true
              },
            },
            {
              label: 'Download Event List',
              icon: 'mdi-download',
              command: () => {
                this.downloadEvents()
              },
            },
          ],
        },
        {
          label: 'Create',
          items: [
            {
              label: 'Timeline',
              icon: 'mdi-timeline-plus',
              command: () => {
                this.showTimelineCreate = true
              },
            },
            {
              label: 'Activity',
              icon: 'mdi-calendar-clock',
              command: () => {
                this.openCreate('activity')
              },
            },
            {
              label: 'Note',
              icon: 'mdi-note-text',
              command: () => {
                this.openCreate('note')
              },
            },
            {
              label: 'Metadata',
              icon: 'mdi-tag-text',
              command: () => {
                this.openCreate('metadata')
              },
            },
          ],
        },
      ]
    },
    // The create dialogs only understand local or UTC
    dialogTimeZone: function () {
      return this.timeZone === 'local' ? 'local' : 'UTC'
    },
    timeZoneLabel: function () {
      return this.timeZone === 'local' ? 'Local Time' : this.timeZone
    },
    isDayOnly: function () {
      return this.view !== 'calendar' || this.calendarType === 'day'
    },
    rangeTitle: function () {
      if (this.view === 'calendar' && this.calendarType === 'month') {
        return format(this.focus, 'MMMM yyyy')
      }
      if (this.view === 'calendar' && this.calendarType === 'week') {
        const start = startOfWeek(this.focus, {
          weekStartsOn: this.settings.weekStart,
        })
        const end = endOfWeek(this.focus, {
          weekStartsOn: this.settings.weekStart,
        })
        return `${format(start, 'MMM d')} - ${format(end, 'MMM d, yyyy')}`
      }
      return format(this.focus, 'EEEE, MMMM d, yyyy')
    },
    visibleTimelines: function () {
      return this.timelines.filter(
        (timeline) => !this.hiddenTimelines.includes(timeline.name),
      )
    },
    allEvents: function () {
      const events = []
      this.timelines.forEach((timeline) => {
        ;(this.activities[timeline.name] || []).forEach((activity) => {
          events.push(makeActivityEvent(timeline, activity))
        })
      })
      this.notes.forEach((note) => events.push(makeNoteEvent(note)))
      this.metadata.forEach((metadata) =>
        events.push(makeMetadataEvent(metadata)),
      )
      return events
    },
    visibleEvents: function () {
      return this.allEvents.filter((event) => {
        switch (event.type) {
          case 'activity':
            return !this.hiddenTimelines.includes(event.timeline)
          case 'note':
            return this.showNotes
          case 'metadata':
            return this.showMetadata
          default:
            return false
        }
      })
    },
    selectedEvent: function () {
      return this.allEvents.find((event) => event.id === this.selectedId)
    },
    eventHandlerFunctions: function () {
      return {
        timeline: {
          created: this.createdTimeline,
          refresh: () => {},
          updated: this.updatedTimeline,
          deleted: this.deletedTimeline,
        },
        activity: {
          event: this.upsertActivityEvent,
          created: this.upsertActivityEvent,
          updated: this.updatedActivity,
          deleted: this.deletedActivity,
        },
      }
    },
  },
  watch: {
    focus: function () {
      this.scheduleRefresh()
    },
    view: function () {
      this.scheduleRefresh()
    },
    calendarType: function () {
      this.scheduleRefresh()
    },
    hiddenTimelines: function () {
      // Clear the unseen message count once a timeline is shown again
      this.timelines.forEach((timeline) => {
        if (!this.hiddenTimelines.includes(timeline.name)) {
          timeline.messages = 0
        }
      })
    },
    selectedEvent: function (value) {
      // Close the details if the event was removed
      if (this.showDetails && !value) {
        this.showDetails = false
      }
    },
  },
  created: function () {
    this.api.ensure_offline_access()
    this.api
      .get_setting('time_zone')
      .then((response) => {
        if (response) {
          this.timeZone = response
          this.focus = startOfDay(toDisplay(new Date(), this.timeZone))
        }
      })
      .catch(() => {
        // Do nothing
      })
    this.loadSettings()
    this.subscribe()
    this.refresh()
  },
  unmounted: function () {
    clearTimeout(this.refreshTimer)
    clearTimeout(this.eventsTimer)
    this.subscriptions.forEach((subscription) => {
      subscription.unsubscribe()
    })
    this.cable.disconnect()
  },
  methods: {
    // ---------------- Settings ----------------
    loadSettings: function () {
      this.api
        .load_config(SETTINGS_KEY, 'default')
        .then((response) => {
          if (response) {
            this.rawSettings = JSON.parse(response)
            this.applySettings(this.rawSettings)
          }
        })
        .catch(() => {
          // No saved settings
        })
    },
    applySettings: function (saved) {
      const settings = { ...DEFAULT_SETTINGS }
      Object.keys(DEFAULT_SETTINGS).forEach((key) => {
        if (saved[key] !== undefined && saved[key] !== null) {
          settings[key] = saved[key]
        }
      })
      settings.weekStart = parseInt(settings.weekStart) === 1 ? 1 : 0
      this.settings = settings
      this.view = settings.defaultView
      this.calendarType = settings.calendarType
    },
    saveSettings: function (settings) {
      // Merge so we preserve any other keys stored in the calendar settings
      this.rawSettings = { ...this.rawSettings, ...settings }
      this.applySettings(this.rawSettings)
      this.api
        .save_config(SETTINGS_KEY, 'default', JSON.stringify(this.rawSettings))
        .then(() => {
          this.$notify.normal({
            title: 'Saved Calendar Options',
            body: 'Calendar options have been saved',
          })
        })
    },

    // ---------------- Navigation ----------------
    setFocus: function (date) {
      if (date) {
        this.focus = startOfDay(new Date(date))
      }
    },
    today: function () {
      this.focus = startOfDay(toDisplay(new Date(), this.timeZone))
    },
    prev: function () {
      if (this.isDayOnly) {
        this.focus = subDays(this.focus, 1)
      } else if (this.calendarType === 'week') {
        this.focus = subWeeks(this.focus, 1)
      } else {
        this.focus = subMonths(this.focus, 1)
      }
    },
    next: function () {
      if (this.isDayOnly) {
        this.focus = addDays(this.focus, 1)
      } else if (this.calendarType === 'week') {
        this.focus = addWeeks(this.focus, 1)
      } else {
        this.focus = addMonths(this.focus, 1)
      }
    },
    showDay: function (date) {
      this.focus = startOfDay(date)
      this.view = 'calendar'
      this.calendarType = 'day'
    },

    // ---------------- Data ----------------
    // Return the [start, stop] ISO strings to request for the current view.
    // We go wide to account for the display time zone shift and multi-day activities.
    fetchRange: function () {
      let days = 2
      if (this.view === 'calendar' && this.calendarType === 'month') {
        days = 45
      } else if (this.view === 'calendar' && this.calendarType === 'week') {
        days = 9
      }
      return {
        start: subDays(this.focus, days).toISOString(),
        stop: addDays(this.focus, days).toISOString(),
      }
    },
    scheduleRefresh: function () {
      clearTimeout(this.refreshTimer)
      this.refreshTimer = setTimeout(() => {
        this.refresh()
      }, 200)
    },
    refresh: function () {
      this.loadedRange = this.fetchRange()
      this.getTimelines().then(() => {
        this.timelines.forEach((timeline) =>
          this.updateActivities(timeline.name),
        )
      })
      this.updateEvents()
    },
    getTimelines: function () {
      return Api.get('/openc3-api/timeline').then((response) => {
        const previous = {}
        this.timelines.forEach((t) => (previous[t.name] = t.messages || 0))
        this.timelines = response.data.map((timeline) => ({
          ...timeline,
          messages: previous[timeline.name] || 0,
        }))
      })
    },
    updateActivities: function (name) {
      const { start, stop } = this.loadedRange || this.fetchRange()
      return Api.get(`/openc3-api/timeline/${name}/activities`, {
        params: { start, stop },
      }).then((response) => {
        this.activities = { ...this.activities, [name]: response.data }
      })
    },
    updateEvents: function () {
      const { start, stop } = this.loadedRange || this.fetchRange()
      Api.get('/openc3-api/metadata', { params: { start, stop } }).then(
        (response) => {
          this.metadata = response.data
        },
      )
      Api.get('/openc3-api/notes', { params: { start, stop } }).then(
        (response) => {
          this.notes = response.data
        },
      )
    },
    downloadEvents: function () {
      const output = JSON.stringify(
        this.visibleEvents.map((event) => ({
          type: event.type,
          name: event.name,
          start: event.start.toISOString(),
          end: event.end.toISOString(),
          data: event.activity || event.note || event.metadata,
        })),
        null,
        2,
      )
      const blob = new Blob([output], { type: 'application/json' })
      const link = document.createElement('a')
      link.href = URL.createObjectURL(blob)
      link.setAttribute(
        'download',
        `${format(Date.now(), 'yyyy_MM_dd_HH_mm_ss')}_calendar_events.json`,
      )
      link.click()
    },

    // ---------------- Dialogs ----------------
    openCreate: function (kind, date = undefined, time = undefined) {
      this.createDate = date || undefined
      this.createTime = time || undefined
      switch (kind) {
        case 'activity':
          if (this.timelines.length === 0) {
            this.$notify.caution({
              title: 'No Timelines',
              body: 'Create a timeline before scheduling activities',
            })
            this.showTimelineCreate = true
            return
          }
          this.editActivity = null
          this.showActivityCreate = true
          break
        case 'note':
          this.editNote = null
          this.showNoteCreate = true
          break
        case 'metadata':
          this.editMetadata = null
          this.showMetadataCreate = true
          break
      }
    },
    createFromContext: function ({ kind, date, time }) {
      // The create dialogs only understand local or UTC so convert slots
      // displayed in any other time zone into UTC date / time strings
      if (
        this.timeZone !== 'local' &&
        this.timeZone !== 'UTC' &&
        date &&
        time
      ) {
        const display = parse(
          `${date} ${time}`,
          'yyyy-MM-dd HH:mm:ss',
          new Date(),
        )
        const utc = toDisplay(fromDisplay(display, this.timeZone), 'UTC')
        date = format(utc, 'yyyy-MM-dd')
        time = format(utc, 'HH:mm:ss')
      }
      this.openCreate(kind, date, time)
    },
    selectEvent: function (event) {
      this.selectedId = event.id
      this.showDetails = true
    },
    editEvent: function (event) {
      this.showDetails = false
      this.createDate = undefined
      this.createTime = undefined
      switch (event.type) {
        case 'activity':
          this.editActivity = event.activity
          this.showActivityCreate = true
          break
        case 'note':
          this.editNote = event.note
          this.showNoteCreate = true
          break
        case 'metadata':
          this.editMetadata = event.metadata
          this.showMetadataCreate = true
          break
      }
    },

    // ---------------- Streaming ----------------
    subscribe: function () {
      this.cable
        .createSubscription('TimelineEventsChannel', window.openc3Scope, {
          received: (data) => this.receivedTimeline(data),
        })
        .then((subscription) => {
          this.subscriptions.push(subscription)
        })
      this.cable
        .createSubscription('CalendarEventsChannel', window.openc3Scope, {
          received: () => this.receivedCalendar(),
        })
        .then((subscription) => {
          this.subscriptions.push(subscription)
        })
    },
    receivedTimeline: function (messages) {
      this.cable.recordPing()
      messages.forEach((message) => {
        try {
          message.data = JSON.parse(message.data)
        } catch (error) {
          return
        }
        const handler = this.eventHandlerFunctions[message.type]?.[message.kind]
        if (handler) handler(message)
      })
    },
    receivedCalendar: function () {
      // Notes and metadata changed, debounce a refresh of them
      clearTimeout(this.eventsTimer)
      this.eventsTimer = setTimeout(() => {
        this.updateEvents()
      }, 250)
    },
    createdTimeline: function (message) {
      if (!this.timelines.find((t) => t.name === message.timeline)) {
        this.timelines.push({ ...message.data, messages: 0 })
        this.activities = { ...this.activities, [message.timeline]: [] }
      }
    },
    updatedTimeline: function (message) {
      const index = this.timelines.findIndex((t) => t.name === message.timeline)
      if (index >= 0) {
        this.timelines[index] = {
          ...message.data,
          messages: this.timelines[index].messages,
        }
      }
    },
    deletedTimeline: function (message) {
      this.timelines = this.timelines.filter((t) => t.name !== message.timeline)
      const activities = { ...this.activities }
      delete activities[message.timeline]
      this.activities = activities
      this.hiddenTimelines = this.hiddenTimelines.filter(
        (name) => name !== message.timeline,
      )
    },
    incrementMessages: function (name) {
      if (this.hiddenTimelines.includes(name)) {
        const timeline = this.timelines.find((t) => t.name === name)
        if (timeline) timeline.messages = (timeline.messages || 0) + 1
      }
    },
    setTimelineActivities: function (name, list) {
      list.sort((a, b) => a.start - b.start)
      this.activities = { ...this.activities, [name]: list }
    },
    upsertActivityEvent: function (message) {
      const name = message.timeline
      const activity = message.data
      this.incrementMessages(name)
      const list = [...(this.activities[name] || [])]
      const index = list.findIndex(
        (a) =>
          a.uuid === activity.uuid ||
          (!a.uuid && !activity.uuid && a.start === activity.start),
      )
      if (index >= 0) {
        list[index] = activity
      } else {
        list.push(activity)
      }
      this.setTimelineActivities(name, list)
    },
    updatedActivity: function (message) {
      const name = message.timeline
      const oldUuid = message.old_uuid
      const oldStart = parseInt(message.old_start)
      let list = [...(this.activities[name] || [])]
      list = list.filter((a) => {
        if (oldUuid) return a.uuid !== oldUuid
        return a.start !== oldStart
      })
      this.activities = { ...this.activities, [name]: list }
      this.upsertActivityEvent(message)
    },
    deletedActivity: function (message) {
      const name = message.timeline
      const data = message.data
      this.incrementMessages(name)
      let list = [...(this.activities[name] || [])]
      if (data.stop !== undefined && data.uuid === undefined) {
        // Range delete (expired activities)
        list = list.filter((a) => a.start < data.start || a.start > data.stop)
      } else if (data.uuid) {
        list = list.filter(
          (a) => a.uuid !== data.uuid && a.recurring?.uuid !== data.uuid,
        )
      } else {
        list = list.filter((a) => a.start !== data.start || a.uuid)
      }
      this.activities = { ...this.activities, [name]: list }
    },
  },
}
</script>

<style scoped>
.calendar-layout {
  align-items: flex-start;
}
.calendar-sidebar {
  flex: 0 0 300px;
  width: 300px;
}
.calendar-main {
  flex: 1;
  min-width: 0;
}
.calendar-card {
  background-color: var(--color-background-surface-default) !important;
}
.calendar-toolbar {
  gap: 4px;
}
</style>

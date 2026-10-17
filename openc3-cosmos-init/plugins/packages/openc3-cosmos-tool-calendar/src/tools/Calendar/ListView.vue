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
  <div data-test="list-view">
    <v-text-field
      v-model="search"
      label="Search"
      prepend-inner-icon="mdi-magnify"
      clearable
      variant="outlined"
      density="compact"
      single-line
      hide-details
      class="mb-2"
      style="max-width: 400px"
    />
    <v-data-table
      :headers="headers"
      :items="items"
      :search="search"
      density="compact"
      :items-per-page="-1"
      hide-default-footer
      hover
      @click:row="(_e, { item }) => $emit('select', item.event)"
    >
      <template #no-data>
        <span>No events on this day</span>
      </template>
      <template #item.status="{ item }">
        <activity-status-icon
          v-if="item.event.type === 'activity'"
          :activity="item.event.activity"
          :progress-icon="progressIcon"
          size="small"
        />
        <v-icon v-else size="small" :color="item.event.color">
          {{ item.event.type === 'note' ? 'mdi-note-text' : 'mdi-tag-text' }}
        </v-icon>
      </template>
      <template #item.calendar="{ item }">
        <v-icon :color="item.event.color" size="x-small" class="mr-1">
          mdi-square
        </v-icon>
        {{ item.calendar }}
      </template>
      <template #item.actions="{ item }">
        <v-btn
          icon="mdi-open-in-new"
          variant="text"
          size="small"
          data-test="list-view-details"
          aria-label="Show Details"
          @click.stop="$emit('select', item.event)"
        />
      </template>
    </v-data-table>
  </div>
</template>

<script>
import { addDays, format, startOfDay } from 'date-fns'
import ActivityStatusIcon from './ActivityStatusIcon.vue'
import { latestEvent, toDisplay } from './util'

export default {
  components: {
    ActivityStatusIcon,
  },
  props: {
    events: {
      type: Array,
      required: true,
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
  emits: ['select'],
  data() {
    return {
      search: '',
      headers: [
        { title: 'Status', key: 'status', sortable: false, width: 60 },
        { title: 'Start', key: 'start', width: 180 },
        { title: 'Stop', key: 'stop', width: 180 },
        { title: 'Type', key: 'type', width: 100 },
        { title: 'Timeline', key: 'calendar', width: 160 },
        { title: 'Description', key: 'description' },
        { title: 'Last Event', key: 'lastEvent', width: 140 },
        { title: '', key: 'actions', sortable: false, width: 60 },
      ],
    }
  },
  computed: {
    items: function () {
      const dayStart = startOfDay(this.focus)
      const dayEnd = addDays(dayStart, 1)
      const fmt = 'yyyy-MM-dd HH:mm:ss'
      return this.events
        .map((event) => ({
          event,
          s: toDisplay(event.start, this.timeZone),
          e: toDisplay(event.end, this.timeZone),
        }))
        .filter(({ s, e }) => {
          if (s.getTime() === e.getTime()) {
            return s >= dayStart && s < dayEnd
          }
          return s < dayEnd && e > dayStart
        })
        .sort((a, b) => a.s - b.s)
        .map(({ event, s, e }) => {
          const latest =
            event.type === 'activity' ? latestEvent(event.activity) : null
          return {
            event,
            start: format(s, fmt),
            stop: event.type === 'metadata' ? '' : format(e, fmt),
            type: event.type.charAt(0).toUpperCase() + event.type.slice(1),
            calendar:
              event.type === 'activity'
                ? event.timeline
                : event.type === 'note'
                  ? 'Notes'
                  : 'Metadata',
            description: this.description(event),
            lastEvent: latest ? latest.event : '',
          }
        })
    },
  },
  methods: {
    description: function (event) {
      switch (event.type) {
        case 'note':
          return event.note.description
        case 'metadata':
          return Object.entries(event.metadata.metadata || {})
            .map(([key, value]) => `${key}: ${value}`)
            .join(', ')
        default:
          return event.name
      }
    },
  },
}
</script>

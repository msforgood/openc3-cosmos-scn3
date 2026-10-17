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
  <v-dialog v-model="show" width="800" @keydown.esc="show = false">
    <v-card v-if="event" data-test="event-details">
      <v-toolbar height="24">
        <v-spacer />
        <span>{{ typeLabel }} Details</span>
        <v-spacer />
        <v-btn
          icon="mdi-close-box"
          variant="text"
          density="compact"
          data-test="close-event-details"
          aria-label="Close Dialog"
          @click="show = false"
        />
      </v-toolbar>
      <v-card-title class="d-flex align-center">
        <activity-status-icon
          v-if="isActivity"
          :activity="event.activity"
          :progress-icon="progressIcon"
          size="small"
          class="mr-2"
        />
        <v-icon v-else :color="event.color" class="mr-2">
          {{ event.type === 'note' ? 'mdi-note-text' : 'mdi-tag-text' }}
        </v-icon>
        <span>{{ event.name }}</span>
      </v-card-title>
      <v-card-subtitle>
        {{ formatDateTimeHMS(event.start, timeZone) }}
        <span v-if="event.type !== 'metadata'">
          - {{ formatDateTimeHMS(event.end, timeZone) }}
        </span>
      </v-card-subtitle>
      <v-card-text>
        <v-table density="compact">
          <tbody>
            <tr v-for="row in rows" :key="row.label">
              <th class="text-left" style="width: 160px">{{ row.label }}</th>
              <td style="white-space: pre-wrap">{{ row.value }}</td>
            </tr>
          </tbody>
        </v-table>

        <template v-if="isActivity">
          <div class="text-subtitle-1 mt-4 mb-1">Status History</div>
          <v-data-table
            :headers="eventHeaders"
            :items="activityEvents"
            density="compact"
            :items-per-page="-1"
            hide-default-footer
            data-test="activity-events"
          >
            <template #item.status="{ item }">
              <activity-status-icon
                :event="item.event"
                :progress-icon="progressIcon"
                :show-progress="false"
                size="small"
              />
            </template>
            <template #item.time="{ item }">
              {{ formatSeconds(item.time, timeZone) }}
            </template>
          </v-data-table>
        </template>
      </v-card-text>
      <v-card-actions class="px-4 pb-4">
        <v-btn
          v-if="canDeleteRecurring"
          variant="outlined"
          color="error"
          data-test="delete-recurring"
          @click="deleteItem(true)"
        >
          Delete All Recurring
        </v-btn>
        <v-spacer />
        <v-btn
          variant="outlined"
          data-test="delete-event"
          @click="deleteItem()"
        >
          Delete
        </v-btn>
        <v-btn
          v-if="canEdit"
          variant="flat"
          color="primary"
          data-test="edit-event"
          @click="$emit('edit', event)"
        >
          Edit
        </v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
</template>

<script>
import { Api } from '@openc3/js-common/services'
import { TimeFilters } from '@openc3/vue-common/util'
import ActivityStatusIcon from './ActivityStatusIcon.vue'

export default {
  components: {
    ActivityStatusIcon,
  },
  mixins: [TimeFilters],
  props: {
    modelValue: Boolean,
    event: {
      type: Object,
      default: null,
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
  emits: ['update:modelValue', 'edit', 'deleted'],
  data() {
    return {
      eventHeaders: [
        { title: '', key: 'status', sortable: false, width: 40 },
        { title: 'Time', key: 'time', width: 200 },
        { title: 'Event', key: 'event', width: 140 },
        { title: 'Message', key: 'message' },
      ],
    }
  },
  computed: {
    show: {
      get() {
        return this.modelValue
      },
      set(value) {
        this.$emit('update:modelValue', value)
      },
    },
    isActivity: function () {
      return this.event && this.event.type === 'activity'
    },
    typeLabel: function () {
      if (!this.event) return ''
      return this.event.type.charAt(0).toUpperCase() + this.event.type.slice(1)
    },
    activityEvents: function () {
      if (!this.isActivity) return []
      return [...(this.event.activity.events || [])].reverse().map((e) => ({
        ...e,
        message: e.message || '',
      }))
    },
    canEdit: function () {
      if (!this.event) return false
      if (this.isActivity) {
        const activity = this.event.activity
        return !activity.fulfillment && activity.start * 1000 > Date.now()
      }
      return true
    },
    canDeleteRecurring: function () {
      return this.isActivity && !!this.event.activity.recurring?.uuid
    },
    rows: function () {
      if (!this.event) return []
      switch (this.event.type) {
        case 'activity': {
          const activity = this.event.activity
          const data = activity.data || {}
          const kind = (activity.kind || '').toLowerCase()
          const rows = [
            { label: 'Timeline', value: activity.name },
            { label: 'Kind', value: kind.toUpperCase() },
          ]
          if (kind !== 'reserve') {
            rows.push({ label: kind.toUpperCase(), value: data[kind] })
          }
          if (data.environment && data.environment.length > 0) {
            rows.push({
              label: 'Environment',
              value: data.environment
                .map((env) => `${env.key}=${env.value}`)
                .join('\n'),
            })
          }
          if (data.notes) {
            rows.push({ label: 'Notes', value: data.notes })
          }
          rows.push({
            label: 'Fulfilled',
            value: activity.fulfillment ? 'Yes' : 'No',
          })
          if (activity.recurring?.uuid) {
            rows.push({
              label: 'Recurring',
              value: `Every ${activity.recurring.frequency} ${activity.recurring.span} until ${this.formatSeconds(activity.recurring.end, this.timeZone)}`,
            })
          }
          if (data.username) {
            rows.push({ label: 'Created By', value: data.username })
          }
          rows.push({ label: 'UUID', value: activity.uuid })
          if (activity.updated_at) {
            rows.push({
              label: 'Last Update',
              value: this.formatNanoseconds(activity.updated_at, this.timeZone),
            })
          }
          return rows
        }
        case 'note':
          return [{ label: 'Description', value: this.event.note.description }]
        case 'metadata':
          return Object.entries(this.event.metadata.metadata || {}).map(
            ([key, value]) => ({ label: key, value }),
          )
        default:
          return []
      }
    },
  },
  methods: {
    deleteItem: function (recurring = false) {
      const event = this.event
      let url = null
      let text = `Are you sure you want to remove this ${event.type} at ${this.formatDateTimeHMS(event.start, this.timeZone)}?`
      switch (event.type) {
        case 'activity': {
          const activity = event.activity
          if (recurring) {
            url = `/openc3-api/timeline/${activity.name}/activity/${activity.start}/${activity.recurring.uuid}?recurring=true`
            text = `Are you sure you want to remove ALL recurring activities in this series on ${activity.name}?`
          } else {
            url = `/openc3-api/timeline/${activity.name}/activity/${activity.start}/${activity.uuid}`
          }
          break
        }
        case 'metadata':
          url = `/openc3-api/metadata/${event.metadata.start}`
          break
        case 'note':
          url = `/openc3-api/notes/${event.note.start}`
          break
      }
      this.$dialog
        .confirm(text, { okText: 'Delete', cancelText: 'Cancel' })
        .then(() => Api.delete(url))
        .then(() => {
          this.$notify.normal({
            title: `Deleted ${this.typeLabel}`,
            body: `Deleted ${event.name}`,
          })
          this.$emit('deleted', event)
          this.show = false
        })
        .catch(() => {
          // Cancelled
        })
    },
  },
}
</script>

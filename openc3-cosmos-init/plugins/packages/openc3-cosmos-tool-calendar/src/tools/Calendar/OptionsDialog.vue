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
  <v-dialog v-model="show" persistent width="500" @keydown.esc="cancel">
    <v-card>
      <v-toolbar height="24">
        <v-spacer />
        <span>Calendar Options</span>
        <v-spacer />
      </v-toolbar>
      <v-card-text class="pt-4">
        <v-select
          v-model="local.weekStart"
          :items="weekStarts"
          label="Week Start"
          density="compact"
          variant="outlined"
          data-test="options-week-start"
        />
        <v-select
          v-model="local.defaultView"
          :items="views"
          label="Default View"
          density="compact"
          variant="outlined"
          data-test="options-default-view"
        />
        <v-select
          v-model="local.calendarType"
          :items="calendarTypes"
          label="Default Calendar Type"
          density="compact"
          variant="outlined"
          data-test="options-calendar-type"
        />
        <v-select
          v-model="local.progressIcon"
          :items="progressIcons"
          label="Running Progress Icon"
          density="compact"
          variant="outlined"
          data-test="options-progress-icon"
        >
          <template #selection="{ item }">
            <v-icon class="mr-2">{{ item.value }}</v-icon>
            {{ item.title }}
          </template>
          <template #item="{ props, item }">
            <v-list-item v-bind="props">
              <template #prepend>
                <v-icon>{{ item.value }}</v-icon>
              </template>
            </v-list-item>
          </template>
        </v-select>
      </v-card-text>
      <v-card-actions class="px-4 pb-4">
        <v-spacer />
        <v-btn variant="outlined" data-test="options-cancel" @click="cancel">
          Cancel
        </v-btn>
        <v-btn
          variant="flat"
          color="primary"
          data-test="options-save"
          @click="save"
        >
          Save
        </v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
</template>

<script>
import { PROGRESS_ICONS } from './util'

export default {
  props: {
    modelValue: Boolean,
    settings: {
      type: Object,
      required: true,
    },
  },
  emits: ['update:modelValue', 'save'],
  data() {
    return {
      local: { ...this.settings },
      weekStarts: [
        { title: 'Sunday - Saturday', value: 0 },
        { title: 'Monday - Sunday', value: 1 },
      ],
      views: [
        { title: 'Calendar', value: 'calendar' },
        { title: 'Gantt', value: 'gantt' },
        { title: 'List', value: 'list' },
      ],
      calendarTypes: [
        { title: 'Month', value: 'month' },
        { title: 'Week', value: 'week' },
        { title: 'Day', value: 'day' },
      ],
      progressIcons: PROGRESS_ICONS,
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
  },
  methods: {
    cancel: function () {
      this.show = false
    },
    save: function () {
      this.$emit('save', { ...this.local })
      this.show = false
    },
  },
}
</script>

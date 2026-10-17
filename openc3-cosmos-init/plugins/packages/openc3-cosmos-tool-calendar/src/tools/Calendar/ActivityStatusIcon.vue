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
  <span class="activity-status" :title="title">
    <v-icon
      v-if="inProgress"
      :icon="progressIcon"
      :size="size"
      :class="{ 'activity-status--spin': spin }"
      :color="color"
      data-test="activity-status-progress"
    />
    <v-icon
      v-else
      :icon="icon"
      :size="size"
      :color="color"
      :data-test="`activity-status-${level}`"
    />
  </span>
</template>

<script>
import {
  STATUS_COLORS,
  isInProgress,
  latestEvent,
  statusIcon,
  statusLevel,
} from './util'

const SPINNING_ICONS = ['mdi-loading', 'mdi-cog', 'mdi-autorenew']

export default {
  props: {
    activity: {
      type: Object,
      default: null,
    },
    // Optionally pass an event name directly (used in the events table)
    event: {
      type: String,
      default: null,
    },
    progressIcon: {
      type: String,
      default: 'mdi-loading',
    },
    size: {
      type: [String, Number],
      default: 'x-small',
    },
    // Only show the progress icon for the latest activity status
    showProgress: {
      type: Boolean,
      default: true,
    },
  },
  computed: {
    eventName: function () {
      if (this.event) return this.event
      const latest = latestEvent(this.activity)
      return latest ? latest.event : 'created'
    },
    level: function () {
      return statusLevel(this.eventName)
    },
    icon: function () {
      return statusIcon(this.level)
    },
    color: function () {
      return STATUS_COLORS[this.level]
    },
    inProgress: function () {
      return this.showProgress && isInProgress(this.eventName)
    },
    spin: function () {
      return SPINNING_ICONS.includes(this.progressIcon)
    },
    title: function () {
      return this.eventName
    },
  },
}
</script>

<style scoped>
.activity-status {
  display: inline-flex;
  align-items: center;
}
.activity-status--spin {
  animation: activity-status-spin 1.2s linear infinite;
}
@keyframes activity-status-spin {
  from {
    transform: rotate(0deg);
  }
  to {
    transform: rotate(360deg);
  }
}
</style>

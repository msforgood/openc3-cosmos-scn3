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
  <v-card class="calendar-selector" variant="flat">
    <v-list density="compact" class="py-0">
      <v-list-subheader>Calendar Events</v-list-subheader>
      <v-list-item data-test="select-metadata" @click="toggleMetadata">
        <template #prepend>
          <v-checkbox-btn
            :model-value="showMetadata"
            density="compact"
            @click.stop="toggleMetadata"
          />
        </template>
        <v-list-item-title>Metadata</v-list-item-title>
      </v-list-item>
      <v-list-item data-test="select-note" @click="toggleNotes">
        <template #prepend>
          <v-checkbox-btn
            :model-value="showNotes"
            density="compact"
            @click.stop="toggleNotes"
          />
        </template>
        <v-list-item-title>Notes</v-list-item-title>
      </v-list-item>

      <v-list-subheader>
        Timelines
        <v-btn
          icon="mdi-plus"
          size="x-small"
          variant="text"
          class="ml-1"
          data-test="create-timeline"
          aria-label="Create Timeline"
          @click="$emit('create-timeline')"
        />
      </v-list-subheader>
      <div v-if="sortedTimelines.length === 0" class="px-4 pb-2 text-caption">
        No timelines. Use Create -> Timeline to add one.
      </div>
      <v-list-item
        v-for="timeline in sortedTimelines"
        :key="`timeline-${timeline.name}`"
        :data-test="`select-timeline-${timeline.name}`"
        @click="toggleTimeline(timeline.name)"
      >
        <template #prepend>
          <v-checkbox-btn
            :model-value="!hidden.includes(timeline.name)"
            :color="timeline.color"
            density="compact"
            @click.stop="toggleTimeline(timeline.name)"
          />
        </template>
        <v-list-item-title class="d-flex align-center">
          <v-icon :color="timeline.color" size="small" class="mr-2">
            mdi-square
          </v-icon>
          <span>{{ timeline.name }}</span>
          <v-badge
            v-if="timeline.messages"
            :content="timeline.messages"
            inline
            color="primary"
            class="ml-1"
          />
          <v-icon
            v-if="timeline.execute === false"
            size="small"
            class="ml-1"
            color="warning"
            title="Execution disabled"
          >
            mdi-pause-circle
          </v-icon>
        </v-list-item-title>
        <template #append>
          <v-menu :close-on-content-click="false">
            <template #activator="{ props }">
              <v-btn
                v-bind="props"
                icon="mdi-dots-vertical"
                size="small"
                variant="text"
                :data-test="`${timeline.name}-options`"
                :aria-label="`${timeline.name} options`"
                @click.stop
              />
            </template>
            <v-card min-width="220">
              <v-card-subtitle class="pt-2">Color</v-card-subtitle>
              <div class="swatches pa-2">
                <v-btn
                  v-for="color in swatches"
                  :key="color"
                  icon
                  size="x-small"
                  variant="text"
                  :data-test="`${timeline.name}-color-${color}`"
                  :aria-label="`Set color ${color}`"
                  @click="updateColor(timeline, color)"
                >
                  <v-icon :color="color">
                    {{
                      color === timeline.color
                        ? 'mdi-checkbox-marked'
                        : 'mdi-square'
                    }}
                  </v-icon>
                </v-btn>
              </div>
              <v-divider />
              <v-list density="compact">
                <v-list-item
                  :data-test="`${timeline.name}-execute`"
                  @click="toggleExecute(timeline)"
                >
                  <template #prepend>
                    <v-icon>
                      {{
                        timeline.execute === false
                          ? 'mdi-play-circle'
                          : 'mdi-pause-circle'
                      }}
                    </v-icon>
                  </template>
                  <v-list-item-title>
                    {{
                      timeline.execute === false
                        ? 'Enable Execution'
                        : 'Disable Execution'
                    }}
                  </v-list-item-title>
                </v-list-item>
                <v-list-item
                  :data-test="`${timeline.name}-delete`"
                  @click="deleteTimeline(timeline)"
                >
                  <template #prepend>
                    <v-icon>mdi-delete</v-icon>
                  </template>
                  <v-list-item-title>Delete Timeline</v-list-item-title>
                </v-list-item>
              </v-list>
            </v-card>
          </v-menu>
        </template>
      </v-list-item>
    </v-list>
  </v-card>
</template>

<script>
import { Api } from '@openc3/js-common/services'

export default {
  props: {
    timelines: {
      type: Array,
      required: true,
    },
    hidden: {
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
  },
  emits: [
    'update:hidden',
    'update:showMetadata',
    'update:showNotes',
    'create-timeline',
  ],
  computed: {
    sortedTimelines: function () {
      return [...this.timelines].sort((a, b) => (a.name > b.name ? 1 : -1))
    },
    swatches: function () {
      return [
        // Standard ASTRO visualization colors
        '#00c7cb',
        '#938bdb',
        '#4dacff',
        '#70dde0',
        '#c9c5ed',
        '#92cbff',
        '#005a8f',
        '#003784',
        '#2d9437',
        '#db7200',
        '#df1368',
        '#9f0010',
      ]
    },
  },
  methods: {
    toggleMetadata: function () {
      this.$emit('update:showMetadata', !this.showMetadata)
    },
    toggleNotes: function () {
      this.$emit('update:showNotes', !this.showNotes)
    },
    toggleTimeline: function (name) {
      if (this.hidden.includes(name)) {
        this.$emit(
          'update:hidden',
          this.hidden.filter((n) => n !== name),
        )
      } else {
        this.$emit('update:hidden', [...this.hidden, name])
      }
    },
    updateColor: function (timeline, color) {
      Api.post(`/openc3-api/timeline/${timeline.name}/color`, {
        data: { color },
      }).then(() => {
        this.$notify.normal({
          title: 'Timeline color updated',
          body: `Timeline: ${timeline.name} color updated to ${color}`,
        })
      })
    },
    toggleExecute: function (timeline) {
      const enable = timeline.execute === false
      Api.post(`/openc3-api/timeline/${timeline.name}/execute`, {
        data: { enable },
      }).then(() => {
        this.$notify.normal({
          title: `Timeline execution ${enable ? 'enabled' : 'disabled'}`,
          body: `Timeline: ${timeline.name}`,
        })
      })
    },
    deleteTimeline: function (timeline) {
      const name = timeline.name
      this.$dialog
        .confirm(`Are you sure you want to remove timeline: ${name}`, {
          okText: 'Delete',
          cancelText: 'Cancel',
        })
        .then(() => {
          return Api.get(`/openc3-api/timeline/${name}/count`)
        })
        .then((response) => {
          if (response.data.count > 0) {
            return this.$dialog
              .confirm(
                `Timeline ${name} has ${response.data.count} activities. Remove ALL activities?`,
                {
                  okText: 'Remove ALL',
                  cancelText: 'Cancel',
                },
              )
              .then(() => Api.delete(`/openc3-api/timeline/${name}?force=true`))
          } else {
            return Api.delete(`/openc3-api/timeline/${name}`)
          }
        })
        .then(() => {
          this.$notify.normal({
            title: 'Deleted Timeline',
            body: `${name} has been deleted.`,
          })
        })
        .catch(() => {
          // Cancelled
        })
    },
  },
}
</script>

<style scoped>
.calendar-selector {
  background-color: var(--color-background-surface-default) !important;
}
.swatches {
  display: grid;
  grid-template-columns: repeat(6, 1fr);
  gap: 2px;
}
</style>

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
  <v-dialog v-model="show" persistent width="500" @keydown.esc="clear">
    <v-card>
      <form @submit.prevent="submit">
        <v-toolbar height="24">
          <v-spacer />
          <span>Create Timeline</span>
          <v-spacer />
          <v-btn
            icon="mdi-close-box"
            variant="text"
            density="compact"
            data-test="close-timeline-icon"
            aria-label="Close Dialog"
            @click="clear"
          />
        </v-toolbar>
        <v-card-text>
          <div class="mb-3">
            Add a timeline to schedule activities on. Activities on a single
            timeline can not overlap. Each timeline runs its own microservice so
            only create timelines as necessary.
          </div>
          <v-text-field
            v-model="timelineName"
            autofocus
            label="Timeline Name"
            density="compact"
            variant="outlined"
            data-test="input-timeline-name"
          />
          <color-select-form v-model="color" />
          <div v-show="error" class="text-red" v-text="error" />
        </v-card-text>
        <v-card-actions class="px-4 pb-4">
          <v-spacer />
          <v-btn
            variant="outlined"
            data-test="create-timeline-cancel-btn"
            @click="clear"
          >
            Cancel
          </v-btn>
          <v-btn
            type="submit"
            variant="flat"
            color="primary"
            data-test="create-timeline-submit-btn"
            :disabled="!!error"
          >
            Ok
          </v-btn>
        </v-card-actions>
      </form>
    </v-card>
  </v-dialog>
</template>

<script>
import { Api } from '@openc3/js-common/services'
import { ColorSelectForm } from '@openc3/vue-common/tools/calendar'

export default {
  components: {
    ColorSelectForm,
  },
  props: {
    modelValue: Boolean,
    timelines: {
      type: Array,
      required: true,
    },
  },
  emits: ['update:modelValue', 'created'],
  data() {
    return {
      timelineName: '',
      color: '#005a8f',
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
    error: function () {
      if (this.timelineName === '') {
        return 'Timeline name can not be blank.'
      }
      if (!/^[A-Za-z0-9_\-.]+$/.test(this.timelineName)) {
        return 'Timeline name may only contain letters, numbers, underscore, dash and period.'
      }
      if (this.timelineName.includes('__')) {
        return 'Timeline name can not contain a double underscore.'
      }
      const dup = this.timelines.find(
        (timeline) => timeline.name === this.timelineName,
      )
      if (dup) {
        return `Timeline must have a unique name. Duplicate timeline name found: ${dup.name}`
      }
      return null
    },
  },
  methods: {
    clear: function () {
      this.show = false
      this.timelineName = ''
    },
    submit: function () {
      if (this.error) return
      const name = this.timelineName
      Api.post('/openc3-api/timeline', {
        data: { name, color: this.color },
      }).then((response) => {
        this.$notify.normal({
          title: 'Created new Timeline',
          body: `Ready to schedule activities on: ${response.data.name}`,
        })
        this.$emit('created', response.data)
      })
      this.clear()
    },
  },
}
</script>

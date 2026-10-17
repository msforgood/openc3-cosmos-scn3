/*
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
*/

// Activity event statuses as committed by the timeline microservice and the
// script lifecycle hooks. Grouped according to the AstroUX status levels.
const NOMINAL = [
  'created',
  'queued',
  'updated',
  'started',
  'running',
  'completed',
]
const WARNING = [
  'stopped',
  'paused',
  'breakpoint',
  'waiting',
  'completed_errors',
  'disabled',
  'killed',
]
const ERROR = ['error', 'failed', 'crashed']
const IN_PROGRESS = ['started', 'running']

const STATUS_COLORS = {
  nominal: '#56f000',
  warning: '#fce83a',
  error: '#ff3838',
}

const PROGRESS_ICONS = [
  { title: 'Loading', value: 'mdi-loading' },
  { title: 'Progress Clock', value: 'mdi-progress-clock' },
  { title: 'Run', value: 'mdi-run-fast' },
  { title: 'Cog', value: 'mdi-cog' },
  { title: 'Timer Sand', value: 'mdi-timer-sand' },
  { title: 'Autorenew', value: 'mdi-autorenew' },
]

const DEFAULT_SETTINGS = {
  weekStart: 0, // 0 = Sunday, 1 = Monday
  defaultView: 'calendar', // calendar, gantt, list
  calendarType: 'week', // month, week, day
  progressIcon: 'mdi-loading',
}

const SETTINGS_KEY = 'calendar-settings'

function latestEvent(activity) {
  if (!activity || !activity.events || activity.events.length === 0) {
    return null
  }
  return activity.events[activity.events.length - 1]
}

function statusLevel(eventName) {
  const name = (eventName || '').toLowerCase()
  if (ERROR.includes(name)) return 'error'
  if (WARNING.includes(name)) return 'warning'
  if (NOMINAL.includes(name)) return 'nominal'
  return 'nominal'
}

function isInProgress(eventName) {
  return IN_PROGRESS.includes((eventName || '').toLowerCase())
}

function statusIcon(level) {
  switch (level) {
    case 'error':
      return 'mdi-triangle'
    case 'warning':
      return 'mdi-square'
    default:
      return 'mdi-circle'
  }
}

const formatters = {}
function zoneFields(date, timeZone) {
  if (!formatters[timeZone]) {
    formatters[timeZone] = new Intl.DateTimeFormat('en-US', {
      timeZone,
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    })
  }
  const fields = {}
  formatters[timeZone].formatToParts(date).forEach((part) => {
    fields[part.type] = parseInt(part.value)
  })
  return fields
}

// When displaying in a time zone other than the browser's we shift the Date
// so the local getters return the values in that time zone. All calendar
// layout math is then done in this "display" space.
function toDisplay(date, timeZone) {
  if (!timeZone || timeZone === 'local') {
    return new Date(date.getTime())
  }
  if (timeZone === 'UTC') {
    return new Date(date.getTime() + date.getTimezoneOffset() * 60000)
  }
  const f = zoneFields(date, timeZone)
  return new Date(
    f.year,
    f.month - 1,
    f.day,
    f.hour,
    f.minute,
    f.second,
    date.getMilliseconds(),
  )
}

// Inverse of toDisplay: convert a display space Date back to the real instant
function fromDisplay(display, timeZone) {
  if (!timeZone || timeZone === 'local') {
    return new Date(display.getTime())
  }
  const guess = Date.UTC(
    display.getFullYear(),
    display.getMonth(),
    display.getDate(),
    display.getHours(),
    display.getMinutes(),
    display.getSeconds(),
    display.getMilliseconds(),
  )
  const shown = toDisplay(new Date(guess), timeZone)
  const shownUtc = Date.UTC(
    shown.getFullYear(),
    shown.getMonth(),
    shown.getDate(),
    shown.getHours(),
    shown.getMinutes(),
    shown.getSeconds(),
    shown.getMilliseconds(),
  )
  return new Date(guess - (shownUtc - guess))
}

function activityTitle(activity) {
  const data = activity.data || {}
  if (data.customTitle) {
    return data.customTitle
  }
  const kind = (activity.kind || '').toLowerCase()
  if (kind === 'reserve') {
    return `${activity.name}: RESERVE`
  }
  let value = data[kind]
  if (value === undefined || value === null) value = ''
  return `${activity.name}: ${kind.toUpperCase()} ${value}`.trim()
}

function makeActivityEvent(timeline, activity) {
  return {
    id: `activity-${activity.name}-${activity.start}-${activity.uuid}`,
    type: 'activity',
    name: activityTitle(activity),
    start: new Date(activity.start * 1000),
    end: new Date(activity.stop * 1000),
    color: timeline ? timeline.color : '#005a8f',
    timeline: activity.name,
    activity,
  }
}

function makeNoteEvent(note) {
  const name =
    note.description.length > 32
      ? `${note.description.substring(0, 32)}...`
      : note.description
  return {
    id: `note-${note.start}`,
    type: 'note',
    name,
    start: new Date(note.start * 1000),
    end: new Date(note.stop * 1000),
    color: note.color,
    note,
  }
}

function makeMetadataEvent(metadata) {
  return {
    id: `metadata-${metadata.start}`,
    type: 'metadata',
    name: 'Metadata',
    start: new Date(metadata.start * 1000),
    // Metadata only has a start so give it a nominal duration for display
    end: new Date(metadata.start * 1000),
    color: metadata.color,
    metadata,
  }
}

export {
  NOMINAL,
  WARNING,
  ERROR,
  STATUS_COLORS,
  PROGRESS_ICONS,
  DEFAULT_SETTINGS,
  SETTINGS_KEY,
  latestEvent,
  statusLevel,
  statusIcon,
  isInProgress,
  toDisplay,
  fromDisplay,
  activityTitle,
  makeActivityEvent,
  makeNoteEvent,
  makeMetadataEvent,
}

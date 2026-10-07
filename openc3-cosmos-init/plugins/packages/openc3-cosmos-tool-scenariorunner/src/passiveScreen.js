// Deliberately limited to the passive widgets used by the installed CFS HK
// screens. Grounded in OpenC3 6.10.1 Openc3Screen, Widget and VWidget sources.
// Do not add a keyword here without checking its widget implementation.
const layouts = new Set(['VERTICAL', 'HORIZONTAL', 'VERTICALBOX', 'HORIZONTALBOX', 'TABBOOK', 'TABITEM'])
const values = new Set(['VALUE', 'LABELVALUE', 'LABELVALUEDESC'])
const display = new Set(['TITLE', 'LABEL', 'SPACER', 'HORIZONTALLINE'])
const settings = new Set(['TEXTCOLOR', 'BACKCOLOR', 'BORDERCOLOR', 'TEXTALIGN', 'PADDING', 'MARGIN', 'WIDTH', 'HEIGHT'])

export function validatePassiveScreen(definition, target) {
  if (typeof definition !== 'string' || definition.length > 1000000) throw new Error('Invalid or oversized screen definition.')
  const packets = new Set()
  const items = new Map()
  let hasScreen = false
  for (const [index, source] of definition.split(/\r?\n/).entries()) {
    const line = source.trim()
    if (!line || line.startsWith('#')) continue
    const tokens = [...line.matchAll(/"([^"\n]*)"|'([^'\n]*)'|(\S+)/g)].map((m) => m[1] ?? m[2] ?? m[3])
    const keyword = tokens[0]?.toUpperCase()
    const reject = (reason) => { throw new Error(`Read-only screen rejected at line ${index + 1}: ${reason}`) }
    if (keyword === 'SCREEN') {
      if (hasScreen || !Number.isFinite(Number(tokens[3])) || Number(tokens[3]) < 1) reject('screen polling must be at least 1 second')
      hasScreen = true
    } else if (keyword === 'SETTING') {
      if (!settings.has(tokens[1]?.toUpperCase())) reject('unsupported setting')
    } else if (values.has(keyword)) {
      if (tokens[1] !== target || !/^[A-Z0-9_]+$/.test(tokens[2] || '')) reject('telemetry must belong to the selected target')
      const match = /^([A-Z0-9_]+)(?:\[(\d+)\])?$/.exec(tokens[3] || '')
      if (!match || match[1].includes('__') || tokens[2].includes('__')) reject('invalid telemetry item reference')
      const type = tokens[keyword === 'LABELVALUEDESC' ? 5 : 4] || 'WITH_UNITS'
      if (!['RAW', 'CONVERTED', 'FORMATTED', 'WITH_UNITS'].includes(type)) reject('unsupported telemetry value type')
      packets.add(tokens[2])
      const key = `${tokens[2]}__${tokens[3]}`
      if (!items.has(key)) items.set(key, { packet: tokens[2], item: match[1], index: match[2] === undefined ? null : Number(match[2]), name: tokens[3] })
    } else if (keyword !== 'END' && !layouts.has(keyword) && !display.has(keyword)) {
      reject(`${keyword || 'unknown'} is not a passive HK widget`)
    }
  }
  if (!hasScreen) throw new Error('Read-only screen requires a SCREEN header.')
  return { packets: [...packets], items: [...items.values()] }
}

export function preferredScreen(screens, telemetryItems = []) {
  for (const { packet } of telemetryItems) {
    const name = screens.find((screen) => screen === packet || screen.startsWith(`${packet}_`))
    if (name) return name
  }
  return screens.find((screen) => screen.includes('HK')) || screens[0] || ''
}

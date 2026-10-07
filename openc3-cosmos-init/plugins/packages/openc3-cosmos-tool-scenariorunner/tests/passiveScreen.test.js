import { expect, it } from 'vitest'
import { preferredScreen, validatePassiveScreen } from '../src/passiveScreen.js'

it('accepts the passive grammar used by CFS ES/EVS screens and returns packet references', () => {
  const definition = 'SCREEN AUTO AUTO 1.0\nVERTICAL\nTITLE "HK" Courier 20 Normal true\nSETTING TEXTCOLOR blue\nLABELVALUEDESC CFS-1_QEMU CFE_ES_HK COMMAND_COUNTER "Count"\nTABBOOK\nTABITEM "Page"\nVALUE CFS-1_QEMU CFE_ES_HK RECEIVED_COUNT\nEND\nEND\nEND'
  expect(validatePassiveScreen(definition, 'CFS-1_QEMU')).toEqual({ packets: ['CFE_ES_HK'], items: [
    { packet: 'CFE_ES_HK', item: 'COMMAND_COUNTER', index: null, name: 'COMMAND_COUNTER' },
    { packet: 'CFE_ES_HK', item: 'RECEIVED_COUNT', index: null, name: 'RECEIVED_COUNT' },
  ] })
})
it.each(['BUTTON "Send" "api.cmd()"', 'DYNAMIC CUSTOM', 'CUSTOM_WIDGET', 'SETTING RAW onclick anything', 'GLOBAL_SETTING VALUE RAW color anything', 'VALUE OTHER_TARGET HK VALUE', 'SCREEN AUTO AUTO 0.01'])('rejects active/custom/cross-target or unbounded definition: %s', (line) => {
  expect(() => validatePassiveScreen(`SCREEN AUTO AUTO 1.0\n${line}`, 'CFS-1_QEMU')).toThrow()
})
it('prefers telemetryItems packet names to alphabetical HK', () => {
  expect(preferredScreen(['CF_HK_TLM_SCREEN', 'CFE_ES_HK_TLM_SCREEN', 'CFE_EVS_HK_TLM_SCREEN'], [{ packet: 'CFE_EVS_HK' }])).toBe('CFE_EVS_HK_TLM_SCREEN')
})
it('extracts unique validated item and array references across widget types', () => {
  const result = validatePassiveScreen('SCREEN AUTO AUTO 1\nVALUE A HK COUNT RAW\nLABELVALUE A HK COUNT\nLABELVALUEDESC A HK ARRAY[2] "Array" CONVERTED', 'A')
  expect(result.items).toEqual([{ packet: 'HK', item: 'COUNT', name: 'COUNT', index: null }, { packet: 'HK', item: 'ARRAY', name: 'ARRAY[2]', index: 2 }])
})
it.each(['VALUE A HK', 'VALUE A HK ITEM__RAW', 'VALUE A HK ARRAY[-1]', 'VALUE A HK X UNSUPPORTED', 'VALUE A HK__OTHER X'])('rejects malformed item references: %s', (line) => {
  expect(() => validatePassiveScreen(`SCREEN AUTO AUTO 1\n${line}`, 'A')).toThrow()
})

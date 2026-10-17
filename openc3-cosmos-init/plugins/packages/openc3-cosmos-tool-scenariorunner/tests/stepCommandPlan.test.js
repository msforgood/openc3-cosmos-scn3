import { expect, it } from 'vitest'
import { formatPlannedParameters, stepCommandPlan } from '../src/stepCommandPlan.js'

const packets = (step) => stepCommandPlan(step)?.map((command) => command.packet)
const parameters = (step) => stepCommandPlan(step)?.map((command) => command.parameters)

it('shows ordinary command parameters and identifies read-only steps', () => {
  expect(parameters({ type: 'command', packet: 'CFE_ES_SEND_HK_CMD', parameters: {} })).toEqual([{}])
  for (const type of ['delay', 'waitTelemetry', 'resolveAddress', 'verifyXbandFrame']) {
    expect(stepCommandPlan({ type })).toEqual([])
  }
  expect(stepCommandPlan({ type: 'unexpected' })).toBeNull()
  expect(formatPlannedParameters({ VALUE: 255 })).toBe('{\n  "VALUE": 255\n}')
})

it('maps every TC log phase to the commands sent by the runner', () => {
  const expected = {
    'seal-baseline': ['CI_LOG_SEAL_CMD'],
    'record-normal': ['CFE_ES_SEND_HK_CMD', 'TC_CAMERA_CAPTURE_CMD'],
    'seal-target': ['CI_LOG_SEAL_CMD'],
    'read-before': ['CI_LOG_READ_CMD'],
    'overwrite-log': ['TC_CAMERA_CAPTURE_CMD'],
    'read-after': ['CI_LOG_READ_CMD'],
    'confirm-continuity': ['CI_LOG_STATUS_CMD'],
  }
  for (const [phase, names] of Object.entries(expected)) expect(packets({ type: 'tcLogPhase', phase })).toEqual(names)
  expect(parameters({ type: 'tcLogPhase', phase: 'record-normal' })[1]).toEqual({
    FILENAME: 'orbit.png', REQUEST_ID: expect.stringContaining('16-bit'),
  })
  expect(parameters({ type: 'tcLogPhase', phase: 'read-before' })[0]).toEqual({
    FILE_INDEX: expect.stringContaining('seal-target'), OFFSET: 0, REQUEST_ID: expect.stringContaining('16-bit'),
  })
  expect(parameters({ type: 'tcLogPhase', phase: 'overwrite-log' })[0]).toEqual({
    FILENAME: '../log/tc<LAST_CLOSED_INDEX:04d>.log', REQUEST_ID: expect.stringContaining('16-bit'),
  })
})

it('maps every PSP phase, including observation-only steps and dynamic addresses', () => {
  const expected = {
    baseline: ['PAYLOAD_DATA_STATUS_CMD'],
    map: ['MM_CMD_DEBUG_MAP'],
    'deny-direct-write': ['MM_CMD_DEBUG_WRITE'],
    pause: ['PAYLOAD_DATA_PAUSE_CMD'],
    'read-pointer': ['MM_CMD_DEBUG_READ'],
    'write-pointer': ['MM_CMD_DEBUG_WRITE'],
    'verify-pointer': ['MM_CMD_DEBUG_READ'],
    resume: ['PAYLOAD_DATA_RESUME_CMD'],
    'confirm-sigsegv': [],
  }
  for (const [phase, names] of Object.entries(expected)) expect(packets({ type: 'pspPhase', phase })).toEqual(names)
  expect(parameters({ type: 'pspPhase', phase: 'deny-direct-write' })[0]).toEqual({
    WIDTH_BYTES: 1, ADDRESS: expect.stringContaining('BUFFER_ADDRESS'),
    VALUE: 0, RESERVED: 0,
    REQUEST_ID: expect.stringContaining('32-bit'),
  })
  expect(parameters({ type: 'pspPhase', phase: 'write-pointer' })[0]).toEqual({
    WIDTH_BYTES: 4, ADDRESS: expect.stringContaining('POINTER_SLOT'),
    VALUE: 'MM_DEBUG_MAP.ADDRESS (map 단계 쓰기 금지 코드 영역)', RESERVED: 0,
    REQUEST_ID: expect.stringContaining('32-bit'),
  })
})

it('shows the CRC address expression and fixed size for each byte step', () => {
  for (let offset = 0; offset < 16; offset++) {
    const step = { type: 'crcByte', offset }
    expect(packets(step)).toEqual(['CS_CMD_ONE_SHOT'])
    expect(parameters(step)).toEqual([{
      ADDRESS: `XKEY_HK.KEY_ADDRESS (locate-key 단계 결과) + ${offset}`, SIZE: 1, MAX_BYTES_PER_CYCLE: 1,
    }])
  }
})

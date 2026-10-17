import { expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import PspEvidence from '../src/PspEvidence.vue'

it('reveals pointer and SIGSEGV evidence only after each step succeeds', async () => {
  const wrapper = mount(PspEvidence, { props: { steps: {
    baseline: { status: 'running', pid: 231, buffer_address: 0x1000, reserved_word: 0 },
    map: { status: 'running', code_address: 0x4000 },
    'write-pointer': { status: 'running', pointer_after: 0x4000 },
    'confirm-sigsegv': { status: 'running', process_instance: 'private-instance-id', exit_signal: 11, signal_name: 'SIGSEGV' },
  } } })
  expect(wrapper.text()).toContain('지상 종료 관측 대기 중')
  expect(wrapper.text()).not.toContain('0x00004000')
  expect(wrapper.text()).not.toContain('private-instance-id')

  await wrapper.setProps({ steps: {
    baseline: { status: 'succeeded', pid: 231, buffer_address: 0x1000, reserved_word: 0, sample_count: 12 },
    map: { status: 'succeeded', module_start: 0x8000, module_end: 0x9000, pointer_slot: 0x8100, code_address: 0x4000 },
    'deny-direct-write': { status: 'succeeded', debug_status: 3 },
    'read-pointer': { status: 'succeeded', pointer_before: 0x1000 },
    'write-pointer': { status: 'succeeded', pointer_after: 0x4000 },
    'verify-pointer': { status: 'succeeded', pointer_after: 0x4000 },
    resume: { status: 'succeeded', write_target: 0x4000 },
    'confirm-sigsegv': { status: 'succeeded', process_instance: 'private-instance-id', exit_signal: 11,
      signal_name: 'SIGSEGV', observed_at: '2026-10-10T00:00:01Z' },
  } })
  expect(wrapper.text()).toContain('cFS PID: 231')
  expect(wrapper.text()).toContain('0x00008100')
  expect(wrapper.text()).toContain('쓰기 금지 코드 영역 (r-x): 0x00004000')
  expect(wrapper.text()).not.toContain('RESERVED_WORD')
  expect(wrapper.text()).not.toContain('보호 페이지')
  expect(wrapper.text()).toContain('모듈 밖 정상 버퍼 직접 MM 쓰기 거부됨')
  expect(wrapper.text()).toContain('SIGSEGV · signal 11')
  expect(wrapper.text()).not.toContain('private-instance-id')
})

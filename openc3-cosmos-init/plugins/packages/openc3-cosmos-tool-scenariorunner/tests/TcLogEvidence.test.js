import { expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import TcLogEvidence from '../src/TcLogEvidence.vue'

it('shows the original TC log before the camera TC and decoded binary after it', async () => {
  const wrapper = mount(TcLogEvidence, { props: { steps: {
    'read-before': { file_index: 2, file_size: 18, before_text: 'TCLOG v1\ncmd=CAMERA' },
    'overwrite-log': { filename: '../log/tc0002.log' },
  } } })
  expect(wrapper.get('[data-test="tc-log-before"]').element.textContent).toBe('TCLOG v1\ncmd=CAMERA')
  expect(wrapper.get('[data-test="tc-log-after"]').text()).toContain('다시 읽을 때까지 대기 중')

  await wrapper.setProps({ steps: {
    'read-before': { file_index: 2, file_size: 18, before_text: 'TCLOG v1\ncmd=CAMERA' },
    'overwrite-log': { filename: '../log/tc0002.log' },
    'read-after': { file_index: 2, file_size: 8, after_text: '�PNG\r\n�', after_hex: '89504e470d0a1a0a' },
  } })
  expect(wrapper.get('[data-test="tc-log-after"]').element.textContent).toBe('�PNG\r\n�')
  expect(wrapper.text()).toContain('PNG 바이너리를 ASCII 문자로 해석한 결과')
  expect(wrapper.text()).not.toContain('89504e470d0a1a0a')
})

it('decodes historical hex-only run evidence using ASCII replacement semantics', () => {
  const wrapper = mount(TcLogEvidence, { props: { steps: {
    'read-after': { file_size: 12, after_hex: '89504e470d0a1a0a00ff41' },
  } } })
  expect(wrapper.get('[data-test="tc-log-after"]').element.textContent).toBe('�PNG\r\n\u001a\n\u0000�A')
})

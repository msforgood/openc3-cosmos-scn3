import { beforeEach, expect, it, vi } from 'vitest'
const transport = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn() }))
vi.mock('@openc3/js-common/services', () => ({ Api: transport }))
import { createScenarioApi } from '../src/scenarioApi.js'
beforeEach(() => {
  vi.clearAllMocks()
  transport.get.mockResolvedValue({ data: { items: [] } })
  transport.post.mockResolvedValue({ data: { id: 'run-id' } })
})
it('uses the published /scenario-api routes, scope and 100-event page bound', async () => {
  const api = createScenarioApi('DEFAULT')
  await api.scenarios(); await api.runs('CFS-1_QEMU'); await api.events('run-id', 12)
  expect(transport.get.mock.calls).toEqual([
    ['/scenario-api/scenarios', { params: { scope: 'DEFAULT' } }],
    ['/scenario-api/runs', { params: { scope: 'DEFAULT', target: 'CFS-1_QEMU', limit: 100 } }],
    ['/scenario-api/runs/run-id/events', { params: { scope: 'DEFAULT', after: 12, limit: 100 } }],
  ])
})
it('passes fixed version/hash/request identity and managed prompt to authenticated common Api', async () => {
  const api = createScenarioApi('DEFAULT')
  const request = { scenario_id: 'hk', target: 'CFS-1_QEMU', definition_version: '1.0.0', definition_hash: 'abc', request_id: 'unique-request' }
  await api.start(request); await api.reconcile(request); await api.stop('run-id'); await api.answer('run-id', 'prompt-id', 'cancel')
  expect(transport.post.mock.calls).toEqual([
    ['/scenario-api/runs', { data: { scope: 'DEFAULT', ...request } }],
    ['/scenario-api/runs/reconcile', { data: { scope: 'DEFAULT', ...request } }],
    ['/scenario-api/runs/run-id/stop', { data: { scope: 'DEFAULT' } }],
    ['/scenario-api/runs/run-id/prompt', { data: { scope: 'DEFAULT', prompt_id: 'prompt-id', answer: 'cancel' } }],
  ])
})

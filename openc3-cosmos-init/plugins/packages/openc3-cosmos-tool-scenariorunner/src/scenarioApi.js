import { Api } from '@openc3/js-common/services'
import { EVENT_PAGE_SIZE } from './runtime.js'

export function createScenarioApi(scope) {
  const get = async (path, params = {}) => (await Api.get(`/scenario-api${path}`, { params: { scope, ...params } })).data
  const post = async (path, data = {}) => (await Api.post(`/scenario-api${path}`, { data: { scope, ...data } })).data
  return {
    scenarios: () => get('/scenarios'),
    runs: (target) => get('/runs', { target, limit: 100 }),
    run: (id) => get(`/runs/${encodeURIComponent(id)}`),
    events: (id, after) => get(`/runs/${encodeURIComponent(id)}/events`, { after, limit: EVENT_PAGE_SIZE }),
    start: (request) => post('/runs', request),
    reconcile: (request) => post('/runs/reconcile', request),
    stop: (id) => post(`/runs/${encodeURIComponent(id)}/stop`),
    answer: (id, prompt_id, answer) => post(`/runs/${encodeURIComponent(id)}/prompt`, { prompt_id, answer }),
  }
}

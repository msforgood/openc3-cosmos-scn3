require_relative 'test_helper'
require 'rack/test'
require_relative '../config/environment'

class ApiTest < ScenarioTest
  include Rack::Test::Methods
  def app
    Rails.application
  end
  def setup
    super
    Scenario::Runtime.service = @service
    header 'Host', 'localhost'
    header 'Authorization', TOKEN
  end
  def json_post(path, data, **headers)
    post path, JSON.generate(data), { 'CONTENT_TYPE' => 'application/json' }.merge(headers)
  end
  def parsed
    JSON.parse(last_response.body)
  end

  def test_authenticated_catalog_run_events_context_and_stop_end_to_end
    get '/scenario-api/scenarios', scope: 'DEFAULT'
    assert_equal 200, last_response.status, last_response.body
    assert_equal 8, parsed['items'].size
    json_post '/scenario-api/runs', input
    assert_equal 201, last_response.status, last_response.body
    id = parsed['id']
    get "/scenario-api/runs/#{id}", scope: 'DEFAULT'
    assert_equal 200, last_response.status
    assert_equal 'running', parsed['state']
    get '/scenario-api/runs', scope: 'DEFAULT', target: 'CFS-1_QEMU'
    assert_equal id, parsed['items'].first['id']
    get "/scenario-api/runs/#{id}/events", scope: 'DEFAULT'
    assert_operator parsed['next_cursor'], :>, 0
    get "/scenario-api/runs/#{id}/context", scope: 'DEFAULT'
    assert_equal 'qemu-es-housekeeping', parsed.dig('definition', 'id')
    json_post "/scenario-api/runs/#{id}/stop", { scope: 'DEFAULT' }
    assert_equal 200, last_response.status
    assert_equal 'stopping', parsed['state']
    refute parsed['termination_confirmed']
  end

  def test_idempotency_header_and_conflicting_body
    body = input.reject { |k, _| k == 'request_id' }
    2.times { json_post '/scenario-api/runs', body, 'HTTP_IDEMPOTENCY_KEY' => 'header-key-0001' }
    assert_equal 200, last_response.status
    assert_equal 1, @backend.launches.size
    json_post '/scenario-api/runs', input, 'HTTP_IDEMPOTENCY_KEY' => 'different-key'
    assert_equal 400, last_response.status
  end

  def test_reconcile_route_fences_absent_request_and_replays_late_create
    json_post '/scenario-api/runs/reconcile', input
    assert_equal 200, last_response.status, last_response.body
    failed = parsed
    assert_equal 'request_not_accepted', failed['error']
    json_post '/scenario-api/runs', input
    assert_equal 200, last_response.status
    assert_equal failed, parsed
    assert_empty @backend.launches
    json_post '/scenario-api/runs/reconcile', input.merge('definition_version' => '2.0.0')
    assert_equal 409, last_response.status
  end

  def test_reconcile_route_scope_auth_header_and_body_validation
    header 'Authorization', nil
    json_post '/scenario-api/runs/reconcile', input
    assert_equal 401, last_response.status
    header 'Authorization', TOKEN
    json_post '/scenario-api/runs/reconcile?scope=OTHER', input
    assert_equal 400, last_response.status
    post '/scenario-api/runs/reconcile', '{', 'CONTENT_TYPE' => 'application/json'
    assert_equal 400, last_response.status
    json_post '/scenario-api/runs/reconcile', input.merge('credentials' => TOKEN)
    assert_equal 400, last_response.status
    json_post '/scenario-api/runs/reconcile', input.reject { |k, _| k == 'request_id' }, 'HTTP_IDEMPOTENCY_KEY' => 'header-recovery'
    assert_equal 200, last_response.status
    assert_equal 'header-recovery', parsed['request_id']
    assert_empty @backend.launches
  end

  def test_unauthenticated_requests_and_scope_mismatch
    header 'Authorization', nil
    get '/scenario-api/scenarios', scope: 'DEFAULT'
    assert_equal 401, last_response.status
    header 'Authorization', TOKEN
    json_post '/scenario-api/runs?scope=OTHER', input
    # Creation must not accept a contradictory scope hidden in the URL.
    assert_equal 400, last_response.status
    assert_empty @backend.launches
  end

  def test_invalid_json_content_type_oversized_body_and_arbitrary_command
    post '/scenario-api/runs', '{', 'CONTENT_TYPE' => 'application/json'
    assert_equal 400, last_response.status
    post '/scenario-api/runs', '{}'
    assert_equal 415, last_response.status
    post '/scenario-api/runs', 'x' * 16_385, 'CONTENT_TYPE' => 'application/json'
    assert_equal 413, last_response.status
    json_post '/scenario-api/runs', input.merge('command' => 'anything')
    assert_equal 400, last_response.status
    assert_empty @backend.launches
  end

  def test_errors_do_not_include_upstream_exception_or_credentials
    @backend.validation_error = RuntimeError.new("upstream Authorization=#{TOKEN}")
    json_post '/scenario-api/runs', input
    assert_equal 503, last_response.status
    assert_equal 'service_unavailable', parsed.dig('error', 'code')
    refute_includes last_response.body, TOKEN
    refute_includes last_response.body, 'upstream'
  end

  def test_health_and_unknown_route
    header 'Authorization', nil
    get '/scenario-api/health'
    assert_equal 200, last_response.status
    assert_equal 1, parsed['contract_version']
  end

  def test_body_limit_precedes_rails_parsing_without_content_length
    invoked = false
    limiter = Scenario::RequestLimits.new(->(_env) { invoked = true; [200, {}, []] })
    response = limiter.call('rack.input' => StringIO.new('a' * 16_385), 'QUERY_STRING' => '')
    assert_equal 413, response.first
    refute invoked
  end
end

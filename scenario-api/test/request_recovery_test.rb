require_relative 'test_helper'

class RequestRecoveryTest < ScenarioTest
  def recover(request = input)
    @service.reconcile_request(request, token: TOKEN)
  end

  def test_unaccepted_request_is_durably_failed_without_lock_and_late_create_replays
    failed = recover
    assert_equal 'failed', failed['state']
    assert_equal 'request_not_accepted', failed['error']
    assert failed['termination_confirmed']
    assert_nil failed['script_id']
    assert_empty @store.transaction { |s| s.active }
    @store.close
    @store = Scenario::Store.new(@db)
    @service = build_service
    assert_equal failed, create
    assert_equal failed, recover
    assert_empty @backend.launches
    assert_equal 'running', create('request-0002')['state']
    refute_includes JSON.generate(@store.transaction { |s| s.get(failed['id']) }), TOKEN
  end

  def test_recovery_fences_create_already_in_preflight_on_another_connection
    entered, resume = Queue.new, Queue.new
    @backend.define_singleton_method(:validate_definition!) { |*_args| entered << true; resume.pop }
    other_store = Scenario::Store.new(@db)
    other = build_service(other_store)
    original = Thread.new { other.create(input, token: TOKEN) }
    Timeout.timeout(5) { entered.pop }
    failed = recover
    resume << true
    run, code = Timeout.timeout(5) { original.value }
    assert_equal failed, run
    assert_equal 200, code
    assert_empty @backend.launches
    assert_empty @store.transaction { |s| s.active }
  ensure
    resume << true if original&.alive?
    original&.join(5)
    other_store&.close
  end

  def test_accepted_inflight_and_running_requests_are_never_failed_by_recovery
    @backend.during_launch = lambda do |run, _|
      recovered = recover
      assert_equal run['id'], recovered['id']
      assert_equal 'launching', recovered['state']
      refute recovered['termination_confirmed']
    end
    run = create
    assert_equal run, recover
    assert_equal 1, @backend.launches.size
    assert_error('target_locked') { create('request-0002') }
  end

  def test_exact_completed_request_replays_instead_of_latest_or_active_run
    run = create
    callback(run, 'result', { 'status' => 'succeeded' })
    terminal(run)
    @time += 1
    active = create('request-0002')
    assert_equal detail(run), recover
    assert_equal 'succeeded', recover['state']
    assert_equal [active['id']], @store.transaction { |s| s.active.map { |r| r['id'] } }
  end

  def test_absent_request_recovery_does_not_acquire_or_release_another_run_lock
    @service = build_service(max_active: 1)
    active = create('request-active')
    failed = recover
    assert_equal 'request_not_accepted', failed['error']
    assert_equal [active['id']], @store.transaction { |s| s.active.map { |r| r['id'] } }
    assert_error('target_locked') { create('request-0003') }
    assert_equal 1, @backend.launches.size
  end

  def test_two_tabs_and_database_connections_recover_same_request_once
    other_store = Scenario::Store.new(@db)
    other = build_service(other_store)
    results = [@service, other].map do |service|
      Thread.new { service.reconcile_request(input, token: TOKEN) }
    end.map(&:value)
    assert_equal results.first, results.last
    assert_equal 1, @store.transaction { |s| s.list(scope: 'DEFAULT').size }
    assert_equal 1, @service.events(results.first['id'], scope: 'DEFAULT', token: TOKEN)['items'].size
    assert_empty @backend.launches
  ensure
    other_store&.close
  end

  def test_target_listing_keeps_lock_owner_visible_despite_failed_request_history
    active = create('request-active')
    @time += 1
    101.times { |i| recover(input("request-history-#{i}")) }
    page = @service.list(scope: 'DEFAULT', target: 'CFS-1_QEMU', token: TOKEN, limit: 100)
    assert_equal 100, page.size
    assert_equal active['id'], page.first['id']
    assert_equal 'running', page.first['state']
    assert_equal 1, @backend.launches.size
  end

  def test_unknown_and_stopping_execution_retains_lock
    @backend.launch_error = IOError.new
    run = create
    assert_equal 'unknown', recover['state']
    refute recover['termination_confirmed']
    @service.stop(run['id'], scope: 'DEFAULT', token: TOKEN)
    assert_equal 'stopping', recover['state']
    assert_error('target_locked') { create('request-0002') }
    assert_equal 1, @backend.launches.size
  end

  def test_recovery_enforces_auth_scope_target_fingerprint_and_definition
    assert_error('unauthenticated') { @service.reconcile_request(input, token: nil) }
    @auth.deny = ->(args) { args[:target] == 'CFS-1_QEMU' && args[:permission] == 'script_run' }
    assert_error('forbidden') { recover }
    @auth.deny = nil
    assert_error('invalid_target') { recover(input.merge('target' => '../target')) }
    assert_error('invalid_request_definition') { recover(input.merge('definition_hash' => 'stale')) }
    assert_error('invalid_request_definition') { recover(input.merge('scenario_id' => 'a' * 65)) }
    assert_error('invalid_request_definition') { recover(input.merge('definition_version' => TOKEN)) }
    assert_error('unexpected_fields') { recover(input.merge('token' => TOKEN)) }
    failed = recover
    assert_error('idempotency_conflict') { recover(input.merge('definition_version' => '2.0.0')) }
    assert_error('idempotency_conflict') { @service.create(input.merge('target' => 'CFS-1_BBB'), token: TOKEN) }
    assert_error('idempotency_key_mismatch') { @service.reconcile_request(input, token: TOKEN, request_key: 'other-key') }
    refute_equal failed['id'], recover(input(scope: 'OTHER'))['id']
    assert_empty @backend.launches
  end

  def test_old_or_removed_catalog_request_is_fenced_without_current_definition
    old = input.merge('scenario_id' => 'removed-scenario', 'definition_version' => '0.1.0', 'definition_hash' => 'a' * 64)
    failed = recover(old)
    assert_equal 'request_not_accepted', failed['error']
    assert_nil @store.transaction { |s| s.get(failed['id'])['definition'] }
    assert_equal failed, @service.create(old, token: TOKEN).first
    assert_empty @backend.launches
  end

  def test_record_capacity_failure_does_not_claim_request_fenced
    failed = recover
    # Fill the real table in one transaction; failure must leave no request record.
    @store.transaction do |s|
      template = s.get(failed['id'])
      (Scenario::Store::MAX_RUNS - 1).times do |i|
        s.insert_failed_request(template.merge('id' => "capacity-#{i}", 'request_id' => "capacity-#{i}"))
      end
    end
    assert_equal failed, recover
    assert_error('record_capacity') { recover(input('request-overflow')) }
    assert_nil @store.transaction { |s| s.by_request('DEFAULT', 'request-overflow') }
    assert_empty @store.transaction { |s| s.active }
  end
end

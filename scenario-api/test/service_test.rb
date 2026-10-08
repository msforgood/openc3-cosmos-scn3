require_relative 'test_helper'

class ServiceTest < ScenarioTest
  def test_persists_run_and_lock_before_launch
    @backend.during_launch = lambda do |run, _|
      persisted = @store.transaction { |s| s.get(run['id']) }
      assert_equal 'launching', persisted['state']
      assert_equal 1, @store.transaction { |s| s.active.size }
    end
    run = create
    assert_equal 'running', run['state']
    assert_equal '101', run['script_id']
  end

  def test_identical_concurrent_requests_launch_once
    threads = 12.times.map { Thread.new { @service.create(input, token: TOKEN) } }
    results = threads.map(&:value)
    assert_equal 1, @backend.launches.size
    assert_equal 1, results.map { |r, _| r['id'] }.uniq.size
    assert_equal 1, results.count { |_, code| code == 201 }
  end

  def test_competing_requests_atomic_target_lock_across_database_connections
    other_store = Scenario::Store.new(@db)
    other = build_service(other_store)
    results = [@service, other].each_with_index.map do |svc, i|
      Thread.new do
        svc.create(input("request-#{i}000"), token: TOKEN).first
      rescue Scenario::Error => error
        error.code
      end
    end.map(&:value)
    assert_equal 1, results.count { |r| r == 'target_locked' }
    assert_equal 1, @backend.launches.size
  ensure
    other_store&.close
  end

  def test_same_target_in_different_scope_has_independent_lock
    create
    run = create('request-0002', scope: 'OTHER')
    assert_equal 'OTHER', run['scope']
    assert_equal 2, @backend.launches.size
  end

  def test_global_active_limit
    @service = build_service(max_active: 1)
    create
    assert_error('active_capacity') { create('request-0002', scope: 'OTHER') }
  end

  def test_changed_key_payload_is_conflict
    create
    changed = input.merge('definition_version' => '2.0.0')
    assert_error('idempotency_conflict') { @service.create(changed, token: TOKEN) }
    assert_equal 1, @backend.launches.size
  end

  def test_stale_hash_and_version_do_not_launch_or_persist
    %w[definition_version definition_hash].each do |field|
      assert_error('definition_mismatch') { @service.create(input.merge(field => 'stale'), token: TOKEN) }
    end
    assert_empty @backend.launches
    assert_empty @store.transaction { |s| s.active }
  end

  def test_arbitrary_commands_parameters_and_targets_rejected
    assert_error('unexpected_fields') { @service.create(input.merge('parameters' => {}), token: TOKEN) }
    assert_error('unexpected_fields') { @service.create(input.merge('environment' => []), token: TOKEN) }
    assert_error('unsupported_target') { @service.create(input.merge('target' => 'CFS-1_BBB'), token: TOKEN) }
    assert_empty @backend.launches
  end

  def test_bbb_crc_oracle_authorizes_one_shot_only_on_its_target
    definition = @catalog.get('bbb-cs-crc-key-oracle')
    request = { 'scope' => 'DEFAULT', 'target' => 'CFS-1_BBB', 'scenario_id' => definition['id'],
                'definition_version' => definition['version'], 'definition_hash' => Scenario::Canonical.hash(definition),
                'request_id' => 'request-bbb-crc-0001' }
    run, code = @service.create(request, token: TOKEN)
    assert_equal 201, code
    assert_equal 'running', run['state']
    assert_equal 'CFS-1_BBB', @backend.launches.last['target']
    assert @auth.calls.any? { |call| call[:permission] == 'cmd' && call[:target] == 'CFS-1_BBB' && call[:packet] == 'CS_CMD_ONE_SHOT' }
    assert_error('unsupported_target') do
      @service.create(request.merge('target' => 'CFS-1_QEMU', 'request_id' => 'request-bbb-crc-0002'), token: TOKEN)
    end
  end

  def test_xband_authentication_callback_is_bound_to_verification_step
    definition = @catalog.get('qemu-cs-crc-key-oracle')
    request = input.merge('scenario_id' => definition['id'],
                          'definition_version' => definition['version'],
                          'definition_hash' => Scenario::Canonical.hash(definition))
    run = @service.create(request, token: TOKEN).first
    data = { 'step_id' => 'verify-xband-frame', 'status' => 'succeeded',
             'packet' => 'XBAND_FRAME', 'telemetryConfirmed' => true,
             'authenticated' => true, 'message' => 'XBD1 frame authenticated and decrypted' }
    callback(run, 'step', data)
    events = @service.events(run['id'], scope: 'DEFAULT', token: TOKEN)
    assert events['items'].any? { |event| event.dig('data', 'authenticated') == true }
    assert_error('invalid_event_data') { callback(run, 'step', data.merge('authenticated' => false)) }
    assert_error('invalid_event_data') { callback(run, 'step', data.merge('step_id' => 'recover-byte-15')) }
    assert_error('invalid_event_data') { callback(run, 'log', data) }
  end

  def test_installed_validation_failure_prevents_launch
    @backend.validation_error = Scenario::Error.new('installed_definition_mismatch', nil, 409)
    assert_error('installed_definition_mismatch') { create }
    assert_empty @store.transaction { |s| s.active }
    assert_empty @backend.launches
  end

  def test_ambiguous_launch_retains_lock_and_replay_never_relaunches
    @backend.launch_error = Timeout::Error.new('secret upstream text')
    run, code = @service.create(input, token: TOKEN)
    assert_equal 202, code
    assert_equal 'unknown', run['state']
    assert_nil run['script_id']
    3.times { assert_equal run['id'], create['id'] }
    assert_error('target_locked') { create('request-0002') }
    assert_equal 1, @backend.launches.size
    refute_includes JSON.generate(run), 'secret upstream text'
  end

  def test_ambiguous_launch_reconciles_by_environment_without_second_launch
    @backend.launch_error = IOError.new
    run = create
    @service.reconcile(run['id'])
    assert_equal '101', detail(run)['script_id']
    assert_equal 'running', detail(run)['state']
    assert_equal 1, @backend.launches.size
  end

  def test_callback_can_arrive_before_launch_response
    @backend.during_launch = lambda do |run, script_id|
      context = @service.context(run['id'], scope: 'DEFAULT', token: TOKEN)
      assert_equal run['definition_hash'], context['definition_hash']
      callback(run, 'started', {}, script_id: script_id)
    end
    run = create
    assert_equal 'running', run['state']
    assert_equal '101', run['script_id']
  end

  def test_result_does_not_release_lock_until_authoritative_termination
    run = create
    callback(run, 'result', { 'status' => 'succeeded' })
    assert_equal 'running', detail(run)['state']
    assert_error('target_locked') { create('request-0002') }
    terminal(run)
    assert_equal 'succeeded', detail(run)['state']
    assert detail(run)['termination_confirmed']
    assert_equal 'running', create('request-0002')['state']
  end

  def test_completed_without_success_callback_is_failed
    run = create
    terminal(run)
    assert_equal 'failed', detail(run)['state']
  end

  def test_completion_racing_stop_is_not_claimed_cancelled
    run = create
    callback(run, 'result', { 'status' => 'succeeded' })
    @service.stop(run['id'], scope: 'DEFAULT', token: TOKEN)
    terminal(run)
    final = detail(run)
    assert_equal 'failed', final['state']
    assert_equal 'stop_unconfirmed_completed', final['error']
    assert_equal 'succeeded', final.dig('result', 'status')
    assert final['termination_confirmed']
    assert final['stop_requested']
  end

  def test_native_error_state_is_not_terminal_and_requests_stop
    run = create
    @backend.statuses[['DEFAULT', '101']]['state'] = 'error'
    @service.reconcile(run['id'])
    assert_equal 'stopping', detail(run)['state']
    refute detail(run)['termination_confirmed']
    assert_equal 1, @backend.stops.size
    assert_error('target_locked') { create('request-0002') }
  end

  def test_terminal_state_without_end_time_retains_lock
    run = create
    @backend.statuses[['DEFAULT', '101']]['state'] = 'completed'
    @service.reconcile(run['id'])
    assert_equal 'unknown', detail(run)['state']
    assert_error('target_locked') { create('request-0002') }
  end

  def test_stop_is_request_only_until_confirmed
    run = create
    2.times { @service.stop(run['id'], scope: 'DEFAULT', token: TOKEN) }
    assert_equal 1, @backend.stops.size
    assert_equal 'stopping', detail(run)['state']
    refute detail(run)['termination_confirmed']
    terminal(run, 'stopped')
    assert_equal 'stopped', detail(run)['state']
    assert detail(run)['termination_confirmed']
  end

  def test_disappeared_status_and_unavailable_backend_retain_lock
    run = create
    @backend.statuses.clear
    @service.reconcile(run['id'])
    assert_equal 'unknown', detail(run)['state']
    @backend.status_error = IOError.new
    @service.reconcile(run['id'])
    assert_error('target_locked') { create('request-0002') }
    assert_equal 1, @backend.launches.size
  end

  def test_restart_recovers_ambiguous_and_stopping_records_without_launch
    @backend.launch_error = IOError.new
    run = create
    @store.close
    @store = Scenario::Store.new(@db)
    @service = build_service
    @service.recover!
    assert_equal '101', detail(run)['script_id']
    @service.stop(run['id'], scope: 'DEFAULT', token: TOKEN)
    @service = build_service
    @service.recover!
    assert_equal 'stopping', detail(run)['state']
    assert_equal 1, @backend.launches.size
    assert_error('target_locked') { create('request-0002') }
  end

  def test_restart_never_dispatches_persisted_launching_record
    @backend.during_launch = ->(_run, _id) { raise IOError }
    run = create
    @store.transaction { |s| r = s.get(run['id']); r['state'] = 'launching'; s.save(r) }
    @backend.statuses.clear
    @service.recover!
    assert_equal 'unknown', detail(run)['state']
    assert_equal 1, @backend.launches.size
    assert_error('target_locked') { create('request-0002') }
  end

  def test_wrong_script_correlation_rejected
    run = create
    @backend.statuses[['DEFAULT', '101']]['environment']['SCENARIO_DEFINITION_HASH'] = 'wrong'
    assert_error('runner_unverified') { callback(run, 'started') }
    @service.reconcile(run['id'])
    assert_equal 'unknown', detail(run)['state']
  end

  def test_callback_dedupe_and_conflict
    run = create
    2.times { callback(run, 'log', { 'message' => 'hello' }, event_id: 'event-1') }
    events = @service.events(run['id'], scope: 'DEFAULT', token: TOKEN)['items']
    assert_equal 1, events.count { |event| event['type'] == 'log' }
    assert_error('event_conflict') { callback(run, 'log', { 'message' => 'changed' }, event_id: 'event-1') }
  end

  def test_prompt_answer_and_deadline
    run = create
    data = { 'prompt_id' => 'confirm-1', 'message' => 'Continue?', 'choices' => %w[continue cancel], 'deadline' => (@time + 5).iso8601 }
    callback(run, 'prompt', data)
    assert_equal 'waiting', detail(run)['state']
    @service.answer(run['id'], scope: 'DEFAULT', token: TOKEN, prompt_id: 'confirm-1', answer: 'continue')
    assert_equal 'continue', @service.context(run['id'], scope: 'DEFAULT', token: TOKEN).dig('prompt', 'answer')
    callback(run, 'prompt', data.merge('prompt_id' => 'confirm-2'))
    @time += 6
    @service.reconcile(run['id'])
    assert_equal 'stopping', detail(run)['state']
    assert_equal 'expired', detail(run).dig('prompt', 'status')
    assert_error('prompt_expired') { @service.answer(run['id'], scope: 'DEFAULT', token: TOKEN, prompt_id: 'confirm-2', answer: 'continue') }
  end

  def test_run_deadline_requests_stop_with_bounded_retries
    run = create
    8.times { @time += 31; @service.reconcile(run['id']) }
    assert_equal 3, @backend.stops.size
    assert_equal 'stopping', detail(run)['state']
    assert_error('target_locked') { create('request-0002') }
  end

  def test_auth_scope_target_and_command_permissions
    assert_error('unauthenticated') { @service.create(input, token: nil) }
    assert_error('unauthenticated') { @service.create(input, token: 'wrong') }
    @auth.deny = ->(args) { args[:permission] == 'cmd' }
    assert_error('forbidden') { create }
    @auth.deny = nil
    run = create
    assert_error('run_not_found') { @service.get(run['id'], scope: 'OTHER', token: TOKEN) }
    @auth.deny = ->(args) { args[:target] == 'CFS-1_QEMU' }
    assert_error('forbidden') { detail(run) }
    assert_error('forbidden') { @service.stop(run['id'], scope: 'DEFAULT', token: TOKEN) }
    assert_error('forbidden') { @service.context(run['id'], scope: 'DEFAULT', token: TOKEN) }
  end

  def test_credentials_never_persist_and_event_bounds
    run = create
    callback(run, 'log', { 'message' => "token=#{TOKEN} Authorization=opaque" })
    assert_error('event_text_too_large') { callback(run, 'log', { 'message' => 'a' * 2049 }) }
    assert_error('invalid_event_data') { callback(run, 'log', { 'password' => 'secret' }) }
    all_data = @store.transaction { |s| [s.get(run['id']), s.events(run['id'], after: 0, limit: 100)] }
    refute_includes JSON.generate(all_data), TOKEN
    refute_includes File.binread(@db), TOKEN
  end

  def test_pagination_bounds_and_cursors
    run = create
    3.times { |i| callback(run, 'log', { 'message' => i.to_s }) }
    first = @service.events(run['id'], scope: 'DEFAULT', token: TOKEN, limit: 2)
    second = @service.events(run['id'], scope: 'DEFAULT', token: TOKEN, after: first['next_cursor'], limit: 2)
    assert_empty first['items'].map { |e| e['id'] } & second['items'].map { |e| e['id'] }
    assert_error('invalid_pagination') { @service.events(run['id'], scope: 'DEFAULT', token: TOKEN, limit: 1000) }
  end

  def test_conflicting_launch_and_callback_ids_never_release_lock
    original_launch = @backend.method(:launch)
    @backend.during_launch = ->(run, id) { callback(run, 'started', {}, script_id: id) }
    @backend.define_singleton_method(:launch) { |run, token| original_launch.call(run, token); '999' }
    run = create
    assert_equal 'unknown', run['state']
    @backend.statuses[['DEFAULT', '101']].merge!('state' => 'completed', 'end_time' => @time.iso8601)
    2.times { @service.reconcile(run['id']) }
    refute detail(run)['termination_confirmed']
    assert_error('target_locked') { create('request-0002') }
  end

  def test_multiple_correlations_remain_unknown_even_if_one_disappears
    @backend.launch_error = IOError.new
    run = create
    @backend.statuses[['DEFAULT', '102']] = @backend.statuses[['DEFAULT', '101']].merge('name' => '102')
    @service.reconcile(run['id'])
    @backend.statuses.delete(['DEFAULT', '102'])
    @backend.statuses[['DEFAULT', '101']].merge!('state' => 'stopped', 'end_time' => @time.iso8601)
    @service.reconcile(run['id'])
    refute detail(run)['termination_confirmed']
    assert_error('target_locked') { create('request-0002') }
  end

  def test_event_capacity_rolls_back_callback_and_requests_stop
    run = create
    @store.transaction do |s|
      Scenario::Store::MAX_EVENTS.times { |i| s.event(run['id'], 'log', {}, time: @time.iso8601, event_id: nil) }
    end
    assert_error('event_capacity') { callback(run, 'result', { 'status' => 'succeeded' }) }
    assert_nil detail(run)['result']
    assert_equal 'stopping', detail(run)['state']
  end

  def test_prompt_cancel_and_reused_prompt_id
    run = create
    data = { 'prompt_id' => 'confirm-1', 'message' => 'Continue?', 'choices' => %w[continue cancel], 'deadline' => (@time + 5).iso8601 }
    callback(run, 'prompt', data)
    @service.answer(run['id'], scope: 'DEFAULT', token: TOKEN, prompt_id: 'confirm-1', answer: 'continue')
    assert_error('prompt_id_reused') { callback(run, 'prompt', data) }
    callback(run, 'prompt', data.merge('prompt_id' => 'confirm-2'))
    @service.answer(run['id'], scope: 'DEFAULT', token: TOKEN, prompt_id: 'confirm-2', answer: 'cancel')
    assert_equal 'stopping', detail(run)['state']
    assert_equal 1, @backend.stops.size
  end
end

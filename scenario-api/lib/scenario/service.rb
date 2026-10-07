require 'securerandom'
require 'time'
require_relative 'catalog'
require_relative 'store'

module Scenario
  class Service
    PROCEDURE = 'SCENARIO_RUNNER/procedures/run_scenario.py'
    TERMINAL = Store::TERMINAL
    RUNNER_TERMINAL = %w[completed completed_errors stopped crashed killed].freeze
    PUBLIC_FIELDS = %w[id scope target scenario_id definition_version definition_hash request_id state script_id created_at updated_at deadline stop_requested termination_confirmed prompt result error].freeze
    CALLBACK_TYPES = %w[started step log prompt result].freeze
    DATA_KEYS = %w[step_id status commandAccepted telemetryConfirmed authenticated packet item value received_at message prompt_id choices deadline level file_index file_size before_text before_hex after_hex photo_bytes active_index total_logged write_errors filename kick_address mode_address mode_before mode_after pulse_count module_start module_end pointer_slot denied_address debug_status pointer_before pointer_after byte_before byte_after pulse_target fault_count halt_acked es_event_id es_event_message].freeze

    def initialize(store:, catalog:, backend:, auth:, clock: -> { Time.now.utc }, max_active: 4)
      @store, @catalog, @backend, @auth, @clock, @max_active = store, catalog, backend, auth, clock, max_active
      @reconcile_mutex = Mutex.new
    end

    def now
      @clock.call.utc
    end

    def timestamp
      now.iso8601(6)
    end

    def scope!(scope)
      raise Error.new('invalid_scope') unless scope.is_a?(String) && Catalog::NAME.match?(scope)
      scope
    end

    def authorize!(scope, target, token, permission = 'script_view', packet = nil)
      scope!(scope)
      raise Error.new('unauthenticated', nil, 401) unless token.is_a?(String) && !token.empty? && token.bytesize <= 16_384
      @auth.authorize!(permission: permission, scope: scope, target: target, packet: packet, token: token)
    end

    def scenarios(scope:, token:)
      authorize!(scope, nil, token)
      @catalog.definitions.filter_map do |d|
        allowed = d['supportedTargets'].select { |t| permitted?(scope, t, token) }
        next if allowed.empty?
        @catalog.presentation(d).merge('permittedTargets' => allowed)
      end
    end

    def scenario(id, scope:, target: nil, token:)
      d = @catalog.get(id)
      allowed = d['supportedTargets'].select { |t| permitted?(scope, t, token) }
      raise Error.new('forbidden', nil, 403) if allowed.empty? || (target && !allowed.include?(target))
      @catalog.presentation(d).merge('permittedTargets' => allowed)
    end

    def create(input, token:, request_key: nil)
      scope, target, key, fingerprint = request_identity!(input, token, request_key)
      previous = @store.transaction { |s| s.by_request(scope, key) }
      if previous
        replay!(previous, fingerprint)
        return [present(previous), 200]
      end
      d = request_definition!(input)
      authorize!(scope, 'SCENARIO_RUNNER', token, 'script_run')
      d['steps'].each do |step|
        authorize!(scope, target, token, 'cmd', step['packet']) if step['type'] == 'command'
        authorize!(scope, target, token, 'tlm', step['packet']) if step['type'] == 'waitTelemetry'
        authorize!(scope, target, token, 'cmd', 'CS_CMD_ONE_SHOT') if step['type'] == 'crcByte'
      end
      if d['steps'].any? { |step| step['type'] == 'tcLogPhase' }
        %w[CI_LOG_STATUS_CMD CI_LOG_SEAL_CMD CI_LOG_READ_CMD TC_CAMERA_CAPTURE_CMD CFE_ES_SEND_HK_CMD].each do |packet|
          authorize!(scope, target, token, 'cmd', packet)
        end
      end
      if d['steps'].any? { |step| step['type'] == 'pspPhase' }
        %w[MM_CMD_DEBUG_MAP MM_CMD_DEBUG_READ MM_CMD_DEBUG_WRITE PAYLOAD_PULSE_PAUSE_CMD PAYLOAD_PULSE_RESUME_CMD PAYLOAD_PULSE_STATUS_CMD PAYLOAD_CTRL_STATUS_CMD].each do |packet|
          authorize!(scope, target, token, 'cmd', packet)
        end
        authorize!(scope, target, token, 'tlm', 'CFE_EVS_LONG_EVENT_MSG')
      end
      d['telemetryItems'].each { |t| authorize!(scope, target, token, 'tlm', t['packet']) }
      @backend.validate_definition!(scope, target, d)
      time = timestamp
      run = {
        'id' => SecureRandom.uuid, 'scope' => scope, 'target' => target, 'request_id' => key,
        'fingerprint' => fingerprint, 'scenario_id' => d['id'], 'definition_version' => d['version'],
        'definition_hash' => Canonical.hash(d), 'definition' => d, 'state' => 'launching',
        'script_id' => nil, 'created_at' => time, 'updated_at' => time,
        'deadline' => (now + d['timeoutSec']).iso8601(6), 'stop_requested' => false,
        'termination_confirmed' => false, 'prompt' => nil, 'result' => nil, 'error' => nil,
        'stop_attempts' => 0, 'last_stop_at' => nil, 'launch_pending' => true
      }
      inserted = @store.transaction do |s|
        raced = s.by_request(scope, key)
        if raced
          replay!(raced, fingerprint)
          run = raced
          false
        else
          s.insert(run, max_active: @max_active)
          s.event(run['id'], 'state', { 'state' => 'launching' }, time: time)
          true
        end
      end
      return [present(run), 200] unless inserted

      # Persist before the one and only launch attempt. Any uncertain transport result is unretriable.
      begin
        script_id = @backend.launch(run, token)
        raise Error.new('invalid_runner_id') unless valid_script_id?(script_id)
        @store.transaction do |s|
          current = s.get(run['id'])
          current['launch_pending'] = false
          if current['script_id'] && current['script_id'] != script_id
            current['association_conflict'] = true
            transition(s, current, 'unknown', 'runner_id_conflict') unless TERMINAL.include?(current['state'])
          else
            current['script_id'] = script_id
            transition(s, current, 'running') if current['state'] == 'launching'
            s.save(current)
          end
          run = current
        end
        [present(run), 201]
      rescue StandardError
        run = @store.transaction do |s|
          current = s.get(run['id'])
          current['launch_pending'] = false
          transition(s, current, 'unknown', 'launch_ambiguous') if current['state'] == 'launching'
          s.save(current)
          current
        end
        [present(run), 202]
      end
    end

    # Linearizes with create's admission transaction, never with an execution's
    # lifetime. An existing execution (including unknown) is only read here.
    def reconcile_request(input, token:, request_key: nil)
      scope, target, key, fingerprint = request_identity!(input, token, request_key)
      @store.transaction do |s|
        previous = s.by_request(scope, key)
        if previous
          replay!(previous, fingerprint)
          next present(previous)
        end
        # A request from an older catalog still needs a fence. These bounded
        # identifiers are retained without a definition or executable context.
        valid = input['scenario_id'].is_a?(String) && /\A[a-z][a-z0-9-]{0,63}\z/.match?(input['scenario_id']) &&
                input['definition_version'].is_a?(String) && input['definition_version'].bytesize <= 32 &&
                /\A[0-9]+\.[0-9]+\.[0-9]+\z/.match?(input['definition_version']) &&
                input['definition_hash'].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(input['definition_hash'])
        raise Error.new('invalid_request_definition') unless valid
        time = timestamp
        run = {
          'id' => SecureRandom.uuid, 'scope' => scope, 'target' => target, 'request_id' => key,
          'fingerprint' => fingerprint, 'scenario_id' => input['scenario_id'], 'definition_version' => input['definition_version'],
          'definition_hash' => input['definition_hash'], 'definition' => nil, 'state' => 'failed',
          'script_id' => nil, 'created_at' => time, 'updated_at' => time, 'deadline' => time,
          'stop_requested' => false, 'termination_confirmed' => true, 'launch_pending' => false,
          'prompt' => nil, 'result' => nil, 'error' => 'request_not_accepted',
          'stop_attempts' => 0, 'last_stop_at' => nil
        }
        s.insert_failed_request(run)
        s.event(run['id'], 'state', { 'state' => 'failed', 'error' => run['error'] }, time: time)
        present(run)
      end
    end

    def get(id, scope:, token:)
      run = authorized_run(id, scope, token)
      present(run)
    end

    def list(scope:, target:, token:, limit: 25)
      raise Error.new('target_required') unless target.is_a?(String) && Catalog::NAME.match?(target)
      authorize!(scope, target, token)
      @store.transaction { |s| s.list(scope: scope, target: target, limit: bounded_integer(limit, 1, 100)) }.map { |r| present(r) }
    end

    def events(id, scope:, token:, after: 0, limit: 100)
      authorized_run(id, scope, token)
      cursor = bounded_integer(after, 0, 9_223_372_036_854_775_000)
      items = @store.transaction { |s| s.events(id, after: cursor, limit: bounded_integer(limit, 1, 100)) }
      { 'items' => items, 'next_cursor' => items.last&.fetch('id') || cursor }
    end

    def context(id, scope:, token:)
      run = authorized_run(id, scope, token, 'script_run')
      context_for(run)
    end

    def stop(id, scope:, token:)
      authorized_run(id, scope, token, 'script_run')
      request_stop(id, 'user_stop')
      dispatch_stop(id)
      @store.transaction { |s| present(s.get(id)) }
    end

    def answer(id, scope:, token:, prompt_id:, answer:)
      authorized_run(id, scope, token, 'script_run')
      run = @store.transaction do |s|
        r = s.get(id)
        p = r['prompt']
        raise Error.new('prompt_not_found', nil, 404) unless p && p['prompt_id'] == prompt_id
        raise Error.new('prompt_expired', nil, 409) if now >= Time.iso8601(p['deadline']) || TERMINAL.include?(r['state']) || r['stop_requested']
        raise Error.new('invalid_answer') unless (p['choices'] + ['cancel']).include?(answer)
        if p['status'] == 'answered'
          raise Error.new('prompt_already_answered', nil, 409) unless p['answer'] == answer
          next r
        end
        p['answer'], p['status'] = answer, 'answered'
        r['stop_requested'] = true if answer == 'cancel'
        transition(s, r, answer == 'cancel' ? 'stopping' : 'running')
        s.event(id, 'prompt_answered', { 'prompt_id' => prompt_id, 'answer' => answer }, time: timestamp)
        r
      end
      dispatch_stop(id) if run['stop_requested']
      present(run)
    end

    def callback(id, scope:, token:, payload:)
      run = authorized_run(id, scope, token, 'script_run')
      raise Error.new('unexpected_fields') unless (payload.keys - %w[scope script_id event_id type data]).empty?
      type, script_id, event_id = payload.values_at('type', 'script_id', 'event_id')
      raise Error.new('invalid_callback') unless CALLBACK_TYPES.include?(type) && valid_script_id?(script_id)
      raise Error.new('invalid_event_id') unless event_id.is_a?(String) && /\A[a-zA-Z0-9_.:-]{1,128}\z/.match?(event_id)
      data = sanitize_data(payload['data'], token)
      if data.key?('authenticated')
        verification_step = run.dig('definition', 'steps')&.find { |step| step['id'] == data['step_id'] }
        unless type == 'step' && data['authenticated'] == true && data['status'] == 'succeeded' &&
               data['telemetryConfirmed'] == true && verification_step&.fetch('type', nil) == 'verifyXbandFrame'
          raise Error.new('invalid_event_data')
        end
      end
      fingerprint = Canonical.hash(payload.reject { |k, _| k == 'scope' }.merge('data' => data))
      replay = @store.transaction { |s| s.event_replay(id, event_id, fingerprint) }
      return context_for(@store.transaction { |s| s.get(id) }) if replay
      status = @backend.status(scope, script_id)
      raise Error.new('runner_unverified', nil, 409) unless matches?(run, status) && status['name'].to_s == script_id
      run = @store.transaction do |s|
        r = s.get(id)
        next r if s.event_replay(id, event_id, fingerprint)
        raise Error.new('run_terminated', nil, 409) if TERMINAL.include?(r['state'])
        raise Error.new('runner_id_conflict', nil, 409) if r['script_id'] && r['script_id'] != script_id
        r['script_id'] = script_id
        if type == 'prompt'
          raise Error.new('stop_pending', nil, 409) if r['stop_requested']
          raise Error.new('prompt_id_reused', nil, 409) if s.prompt_used?(id, data['prompt_id'])
          install_prompt!(r, data)
        elsif type == 'result'
          raise Error.new('invalid_result') unless %w[succeeded failed].include?(data['status'])
          raise Error.new('result_conflict', nil, 409) if r['result'] && r['result'] != data
          r['result'] = data
        elsif type == 'step'
          raise Error.new('invalid_step') unless r['definition']['steps'].any? { |step| step['id'] == data['step_id'] }
        end
        s.event(id, type, data, time: timestamp, event_id: event_id, fingerprint: fingerprint)
        r['updated_at'] = timestamp
        r['state'] = 'running' if %w[launching unknown].include?(r['state']) && !r['stop_requested']
        s.save(r)
        r
      end
      context_for(run)
    rescue Error => e
      request_stop(id, 'event_capacity') if e.code == 'event_capacity'
      raise
    end

    def recover!
      @store.transaction do |s|
        s.active.each do |r|
          r['launch_pending'] = false
          transition(s, r, 'unknown', 'restart_reconciliation') if r['state'] == 'launching'
          s.save(r)
        end
      end
      reconcile_all
    end

    def reconcile_all
      return unless @reconcile_mutex.try_lock
      begin
        @store.transaction { |s| s.active }.each { |r| reconcile(r['id']) }
      ensure
        @reconcile_mutex.unlock
      end
    end

    def reconcile(id)
      run = @store.transaction { |s| s.get(id) }
      return if !run || TERMINAL.include?(run['state'])
      if run['association_conflict']
        mark_unknown(id, 'runner_id_conflict')
        expire(id)
        return
      end
      status = if run['script_id']
                 @backend.status(run['scope'], run['script_id'])
               else
                 candidates = @backend.find(run).select { |r| matches?(run, r) }
                 if candidates.size > 1
                   @store.transaction do |s|
                     current = s.get(id)
                     current['association_conflict'] = true
                     transition(s, current, 'unknown', 'runner_id_conflict')
                   end
                 end
                 candidates.one? ? candidates.first : nil
               end
      if status && matches?(run, status)
        @store.transaction do |s|
          current = s.get(id)
          next if TERMINAL.include?(current['state'])
          current['script_id'] ||= status['name'].to_s
          if current['script_id'] != status['name'].to_s
            transition(s, current, 'unknown', 'runner_id_conflict')
          elsif RUNNER_TERMINAL.include?(status['state']) && valid_end_time?(status['end_time'])
            next if current['launch_pending']
            current['termination_confirmed'] = true
            final = if status['state'] == 'stopped' || (current['stop_requested'] && status['state'] == 'killed')
                      'stopped'
                    elsif status['state'] == 'completed' && current.dig('result', 'status') == 'succeeded' && !current['stop_requested']
                      'succeeded'
                    else
                      'failed'
                    end
            error = if final == 'failed'
                      status['state'] == 'completed' && current['stop_requested'] && current.dig('result', 'status') == 'succeeded' ? 'stop_unconfirmed_completed' : 'execution_failed_or_unconfirmed_result'
                    end
            transition(s, current, final, error)
          elsif %w[paused error breakpoint].include?(status['state'])
            current['stop_requested'] = true
            transition(s, current, 'stopping', 'unattended_runner_pause')
          elsif %w[spawning running waiting].include?(status['state'])
            desired = current['stop_requested'] ? 'stopping' : (current.dig('prompt', 'status') == 'pending' ? 'waiting' : 'running')
            transition(s, current, desired)
          else
            transition(s, current, 'unknown', 'unconfirmed_runner_state')
          end
          s.save(current)
        end
      else
        mark_unknown(id, 'runner_unavailable')
      end
      expire(id)
      dispatch_stop(id)
    rescue StandardError
      mark_unknown(id, 'reconciliation_unavailable')
      expire(id)
    end

    private

    def request_identity!(input, token, request_key)
      raise Error.new('invalid_request') unless input.is_a?(Hash)
      allowed = %w[scope scenario_id definition_version definition_hash target request_id]
      raise Error.new('unexpected_fields') unless (input.keys - allowed).empty?
      scope, target = input.values_at('scope', 'target')
      raise Error.new('invalid_target') unless target.is_a?(String) && Catalog::NAME.match?(target)
      authorize!(scope, target, token, 'script_run')
      key = request_key || input['request_id']
      if request_key && input['request_id'] && request_key != input['request_id']
        raise Error.new('idempotency_key_mismatch')
      end
      raise Error.new('invalid_request_id') unless key.is_a?(String) && /\A[a-zA-Z0-9_.:-]{8,128}\z/.match?(key)
      [scope, target, key, Canonical.hash(input.reject { |k, _| k == 'request_id' })]
    end

    def request_definition!(input)
      d = @catalog.get(input['scenario_id'])
      raise Error.new('unsupported_target') unless d['supportedTargets'].include?(input['target'])
      unless input['definition_version'] == d['version'] && input['definition_hash'] == Canonical.hash(d)
        raise Error.new('definition_mismatch', nil, 409)
      end
      d
    end

    def permitted?(scope, target, token)
      authorize!(scope, target, token)
      true
    rescue Error => e
      raise unless e.status == 403
      false
    end

    def present(run)
      run.slice(*PUBLIC_FIELDS)
    end

    def context_for(run)
      { 'run_id' => run['id'], 'scope' => run['scope'], 'target' => run['target'],
        'definition' => run['definition'], 'definition_hash' => run['definition_hash'],
        'stop_requested' => run['stop_requested'], 'deadline' => run['deadline'], 'prompt' => run['prompt'] }
    end

    def authorized_run(id, scope, token, permission = 'script_view')
      authorize!(scope, nil, token, permission)
      run = @store.transaction { |s| s.get(id) }
      raise Error.new('run_not_found', nil, 404) unless run && run['scope'] == scope
      authorize!(scope, run['target'], token, permission)
      run
    end

    def replay!(run, fingerprint)
      raise Error.new('idempotency_conflict', nil, 409) unless run['fingerprint'] == fingerprint
    end

    def bounded_integer(value, min, max)
      text = value.to_s
      raise Error.new('invalid_pagination') unless /\A\d{1,19}\z/.match?(text)
      number = Integer(text, 10)
      raise Error.new('invalid_pagination') unless number.between?(min, max)
      number
    end

    def valid_script_id?(id)
      id.is_a?(String) && /\A[1-9][0-9]{0,19}\z/.match?(id)
    end

    def valid_end_time?(value)
      value.is_a?(String) && Time.iso8601(value) <= now + 5
    rescue ArgumentError
      false
    end

    def matches?(run, status)
      status.is_a?(Hash) && valid_script_id?(status['name'].to_s) && status['filename'] == PROCEDURE &&
        status.dig('environment', 'SCENARIO_RUN_ID') == run['id'] &&
        status.dig('environment', 'SCENARIO_DEFINITION_HASH') == run['definition_hash']
    end

    def transition(store, run, state, error = nil)
      changed = run['state'] != state || run['error'] != error
      run['state'], run['error'], run['updated_at'] = state, error, timestamp
      store.save(run)
      store.event(run['id'], 'state', { 'state' => state, 'error' => error }, time: timestamp) if changed
    end

    def mark_unknown(id, error)
      @store.transaction do |s|
        r = s.get(id)
        transition(s, r, 'unknown', error) if r && !TERMINAL.include?(r['state'])
      end
    end

    def request_stop(id, reason)
      @store.transaction do |s|
        r = s.get(id)
        next if !r || TERMINAL.include?(r['state'])
        r['stop_requested'] = true
        transition(s, r, 'stopping', reason)
      end
    end

    def dispatch_stop(id)
      run = @store.transaction do |s|
        r = s.get(id)
        next unless r && r['stop_requested'] && r['script_id'] && !TERMINAL.include?(r['state'])
        next if r['stop_attempts'] >= 3 || (r['last_stop_at'] && now - Time.iso8601(r['last_stop_at']) < 5)
        r['stop_attempts'] += 1
        r['last_stop_at'] = timestamp
        s.save(r)
        r
      end
      @backend.stop(run) if run
    rescue StandardError
      mark_unknown(id, 'stop_unconfirmed')
    end

    def expire(id)
      @store.transaction do |s|
        r = s.get(id)
        next unless r && !TERMINAL.include?(r['state'])
        expired_prompt = r['prompt'] && r['prompt']['status'] == 'pending' && now >= Time.iso8601(r['prompt']['deadline'])
        next unless expired_prompt || now >= Time.iso8601(r['deadline'])
        r['prompt']['status'] = 'expired' if expired_prompt
        r['stop_requested'] = true
        transition(s, r, 'stopping', expired_prompt ? 'prompt_deadline' : 'run_deadline')
      end
    end

    def install_prompt!(run, data)
      raise Error.new('prompt_pending', nil, 409) if run.dig('prompt', 'status') == 'pending'
      check = data['prompt_id'].is_a?(String) && Catalog::ID.match?(data['prompt_id']) &&
              data['message'].is_a?(String) && data['choices'].is_a?(Array) && data['choices'].size.between?(1, 8) &&
              data['choices'].all? { |c| c.is_a?(String) && Catalog::ID.match?(c) }
      raise Error.new('invalid_prompt') unless check
      deadline = Time.iso8601(data['deadline']) rescue nil
      raise Error.new('invalid_prompt_deadline') unless deadline && deadline > now && deadline <= now + 120 && deadline <= Time.iso8601(run['deadline'])
      run['prompt'] = data.slice('prompt_id', 'message', 'choices', 'deadline').merge('status' => 'pending', 'answer' => nil)
      run['state'] = 'waiting'
    end

    def sanitize_data(data, token)
      raise Error.new('invalid_event_data') unless data.is_a?(Hash) && (data.keys - DATA_KEYS).empty?
      raise Error.new('event_too_large', nil, 413) if JSON.generate(data).bytesize > 4096
      sanitized = JSON.parse(JSON.generate(data))
      walk = lambda do |value|
        case value
        when String
          raise Error.new('event_text_too_large', nil, 413) if value.bytesize > 2048
          value.gsub(token, '[REDACTED]').gsub(/(?:Bearer\s+\S+|(?:password|token|authorization|secret)\s*[:=]\s*\S+)/i, '[REDACTED]')
        when Array then value.map { |v| walk.call(v) }
        when Hash then raise Error.new('nested_event_data')
        else value
        end
      end
      sanitized.transform_values { |value| walk.call(value) }
    end
  end
end

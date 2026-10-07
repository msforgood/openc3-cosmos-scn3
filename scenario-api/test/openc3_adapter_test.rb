require_relative 'test_helper'
require 'minitest/mock'
require_relative '../lib/scenario/openc3_adapter'

class OpenC3AdapterTest < ScenarioTest
  def setup
    super
    @adapter = Scenario::OpenC3Adapter.new(script_api_url: 'http://runner:2902', public_api_url: 'http://scenario-api:2910/scenario-api')
    @policy = JSON.parse(File.read(File.expand_path('../config/safety_policy.json', __dir__)))
  end

  def packet(_target, name, type:, scope:)
    assert_equal 'DEFAULT', scope
    if type == :CMD
      defaults = @policy['headerDefaults'].merge('CCSDS_STREAMID' => @policy['commands'][name]['streamId'])
      items = defaults.map { |key, value| { 'name' => key, 'default' => value, 'id_value' => value, 'data_type' => 'UINT' } }
      items += OpenC3::Packet::RESERVED_ITEM_NAMES.map { |key| { 'name' => key, 'data_type' => 'DERIVED' } }
    else
      items = [{ 'name' => 'COMMAND_COUNTER', 'data_type' => 'UINT', 'bit_size' => 8 }]
      items += %w[RECEIVED_TIMESECONDS RECEIVED_COUNT].map { |key| { 'name' => key, 'data_type' => 'DERIVED' } }
    end
    { 'target_name' => 'CFS-1_QEMU', 'packet_name' => name, 'items' => items }
  end

  def target_file(_scope, path)
    case path
    when /scenarios.json$/ then JSON.generate(@catalog.definitions)
    when /safety_policy.json$/ then JSON.generate(@policy)
    else 'print("fixed procedure")'
    end
  end

  def test_installed_real_model_shapes_validate_before_launch
    OpenC3::TargetModel.stub(:packet, method(:packet)) do
      OpenC3::TargetFile.stub(:body, method(:target_file)) do
        assert @adapter.validate_definition!('DEFAULT', 'CFS-1_QEMU', @catalog.definitions.first)
      end
    end
  end

  def test_altered_hidden_command_field_is_rejected
    changed = lambda do |target, name, **args|
      p = packet(target, name, **args)
      p['items'] << { 'name' => 'EXTRA_PARAM', 'default' => 1 } if args[:type] == :CMD
      p
    end
    OpenC3::TargetModel.stub(:packet, changed) do
      assert_error('command_parameter_mismatch') { @adapter.validate_definition!('DEFAULT', 'CFS-1_QEMU', @catalog.definitions.first) }
    end
  end

  def test_missing_telemetry_receipt_fields_prevent_launch
    changed = lambda do |target, name, **args|
      p = packet(target, name, **args)
      p['items'].reject! { |item| item['name'] == 'RECEIVED_COUNT' } if args[:type] == :TLM
      p
    end
    OpenC3::TargetModel.stub(:packet, changed) do
      assert_error('telemetry_item_missing') { @adapter.validate_definition!('DEFAULT', 'CFS-1_QEMU', @catalog.definitions.first) }
    end
  end

  def test_installed_catalog_hash_mismatch
    changed = ->(scope, path) { path.end_with?('/scenarios.json') ? '[]' : target_file(scope, path) }
    OpenC3::TargetModel.stub(:packet, method(:packet)) do
      OpenC3::TargetFile.stub(:body, changed) do
        assert_error('installed_definition_mismatch') { @adapter.validate_definition!('DEFAULT', 'CFS-1_QEMU', @catalog.definitions.first) }
      end
    end
  end

  def test_actual_6101_status_model_checks_running_then_completed
    assert_equal '6.10.1', Gem.loaded_specs.fetch('openc3').version.to_s
    calls = []
    fake = Object.new
    fake.define_singleton_method(:hget) do |key, name|
      calls << [key, name]
      key == "#{OpenC3::ScriptStatusModel::COMPLETED_PRIMARY_KEY}__DEFAULT" ? JSON.generate('name' => name, 'state' => 'completed', 'end_time' => '2026-09-27T12:00:00Z') : nil
    end
    OpenC3::ScriptStatusModel.stub(:store, fake) do
      result = @adapter.status('DEFAULT', '123')
      assert_equal 'completed', result['state']
      assert_equal [["#{OpenC3::ScriptStatusModel::RUNNING_PRIMARY_KEY}__DEFAULT", '123'], ["#{OpenC3::ScriptStatusModel::COMPLETED_PRIMARY_KEY}__DEFAULT", '123']], calls
    end
  end

  def test_actual_terminal_states_exclude_native_error_and_pause
    %w[completed completed_errors stopped crashed killed].each do |state|
      model = OpenC3::ScriptStatusModel.new(name: '1', state: state, scope: 'DEFAULT', filename: Scenario::Service::PROCEDURE, username: 'test', user_full_name: 'Test', start_time: @time.iso8601)
      assert model.is_complete?, state
    end
    %w[error paused waiting running].each do |state|
      model = OpenC3::ScriptStatusModel.new(name: '1', state: state, scope: 'DEFAULT', filename: Scenario::Service::PROCEDURE, username: 'test', user_full_name: 'Test', start_time: @time.iso8601)
      refute model.is_complete?, state
    end
  end

  def test_stop_uses_source_defined_publish_channel_and_json_string
    run = create
    record = @backend.statuses.fetch(['DEFAULT', run['script_id']])
    sent = []
    # Store forwards Redis verbs through method_missing, so install only the test singleton stub.
    OpenC3::Store.define_singleton_method(:publish) { |*args| sent << args }
    OpenC3::ScriptStatusModel.stub(:get, record) do
      @adapter.stop(run)
    end
    assert_equal [["script-api:cmd-running-script-channel:#{run['script_id']}", '"stop"']], sent
  ensure
    OpenC3::Store.singleton_class.remove_method(:publish)
  end

  def test_core_auth_is_enabled_and_verifies_existing_token
    auth = Scenario::Authentication.new
    assert $openc3_authorize
    OpenC3::AuthModel.stub(:verify, false) do
      assert_error('unauthenticated') { auth.authorize!(permission: 'script_run', scope: 'DEFAULT', target: 'CFS-1_QEMU', packet: nil, token: 'invalid') }
    end
    OpenC3::AuthModel.stub(:verify, true) do
      auth.authorize!(permission: 'script_run', scope: 'DEFAULT', target: 'CFS-1_QEMU', packet: nil, token: TOKEN)
    end
  end

  def test_launch_http_exact_route_body_auth_and_no_retries
    run = create
    captured = nil
    fake = Object.new
    %i[use_ssl open_timeout read_timeout write_timeout max_retries].each do |name|
      fake.singleton_class.attr_accessor(name)
    end
    fake.define_singleton_method(:start) { |&block| block.call(fake) }
    response = Object.new
    response.define_singleton_method(:code) { '200' }
    response.define_singleton_method(:read_body) { |&block| block.call('456') }
    fake.define_singleton_method(:request) { |request, &block| captured = request; block.call(response) }
    Net::HTTP.stub(:new, fake) do
      assert_equal '456', @adapter.launch(run, TOKEN)
    end
    assert_equal '/script-api/scripts/SCENARIO_RUNNER/procedures/run_scenario.py/run', captured.path
    assert_equal TOKEN, captured['Authorization']
    assert_equal 0, fake.max_retries
    sent = JSON.parse(captured.body)
    assert_equal %w[environment scope], sent.keys.sort
    assert_equal %w[SCENARIO_API_URL SCENARIO_CONTRACT_VERSION SCENARIO_DEFINITION_HASH SCENARIO_RUN_ID], sent['environment'].map { |e| e['key'] }.sort
    refute_includes captured.body, TOKEN
  end
end

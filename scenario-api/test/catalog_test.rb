require_relative 'test_helper'

class CatalogTest < ScenarioTest
  def definition
    housekeeping_fixture
  end

  def test_published_catalog_has_four_ordered_scenarios
    assert_equal %w[cs-crc-key-oracle tc-log-photo-traversal psp-mm-indirect-write ground-station-tc-schedule],
                 @catalog.definitions.map { |item| item['id'] }
    assert_equal ['INST'], @catalog.get('ground-station-tc-schedule')['supportedTargets']
    %w[CFS-1_QEMU CFS-1_BBB].each do |target|
      items = @catalog.definitions.select { |item| item['supportedTargets'].include?(target) }
      assert_equal %w[cs-crc-key-oracle tc-log-photo-traversal psp-mm-indirect-write],
                   items.map { |item| item['id'] }
      assert_equal ['01. CS 1바이트 CRC 키 복원', '02. TC 로그 사진 경로 변경', '03. MM 포인터 변경'],
                   items.map { |item| item['name'] }
    end
  end

  def test_catalog_loads_korean_names_when_openc3_sets_binary_encoding
    original_external, original_internal = Encoding.default_external, Encoding.default_internal
    Encoding.default_external = Encoding::BINARY
    Encoding.default_internal = Encoding::BINARY
    catalog = Scenario::Catalog.new(path: File.expand_path('../config/scenarios.json', __dir__))
    assert_equal '01. CS 1바이트 CRC 키 복원', catalog.definitions.first['name']
  ensure
    Encoding.default_external = original_external
    Encoding.default_internal = original_internal
  end

  def validate(d)
    Scenario::Catalog.new(definitions: [d])
  end

  def test_schema_valid_zero_delay_is_accepted
    d = definition
    d['steps'].insert(1, { 'id' => 'settle', 'type' => 'delay', 'seconds' => 0 })
    assert validate(d)
  end

  def test_schema_rejects_extra_fields_and_unknown_parameters
    d = definition
    d['extra'] = 'ignored-by-no-one'
    assert_error('invalid_catalog') { validate(d) }
    d = definition
    d['steps'][0]['parameters'] = { 'CUSTOM' => 1 }
    assert_error('invalid_catalog') { validate(d) }
    d = definition
    d['steps'][1]['extra'] = true
    assert_error('invalid_catalog') { validate(d) }
  end

  def test_bounds_match_canonical_schema
    [
      ->(d) { d['timeoutSec'] = 121 },
      ->(d) { d['steps'][0]['timeoutSec'] = 5.1 },
      ->(d) { d['steps'][1]['timeoutSec'] = 30.1 },
      ->(d) { d['steps'][1]['pollIntervalSec'] = 0.24 },
      ->(d) { d['steps'][1]['pollIntervalSec'] = 2.1 },
      ->(d) { d['steps'][1]['operator'] = 'gt' },
      ->(d) { d['steps'][1]['value'] = 256 },
      ->(d) { d['steps'][1]['value'] = 1.0 },
      ->(d) { d['steps'].insert(1, { 'id' => 'settle', 'type' => 'delay', 'seconds' => 5.1 }) }
    ].each do |mutation|
      d = definition
      mutation.call(d)
      assert_error('invalid_catalog') { validate(d) }
    end
  end

  def test_semantics_require_wait_for_each_command_and_total_deadline
    d = definition
    d['steps'].reverse!
    assert_error('invalid_catalog') { validate(d) }
    d = definition
    d['timeoutSec'] = 10
    assert_error('invalid_catalog') { validate(d) }
    d = definition
    d['telemetryItems'] << { 'packet' => 'CFE_EVS_HK', 'item' => 'COMMAND_COUNTER' }
    assert_error('invalid_catalog') { validate(d) }
  end

  def test_tc_log_demo_is_fixed_for_both_targets
    d = @catalog.get('tc-log-photo-traversal')
    assert validate(d)
    d['steps'][4]['phase'] = 'read-after'
    assert_error('invalid_catalog') { validate(d) }
    d = @catalog.get('tc-log-photo-traversal')
    d['telemetryItems'] << {'packet' => 'CFE_ES_HK', 'item' => 'COMMAND_COUNTER'}
    assert_error('invalid_catalog') { validate(d) }
  end

  def test_crc_oracle_requires_both_targets_and_xband_authentication
    definition = @catalog.get('cs-crc-key-oracle')
    assert_equal %w[CFS-1_QEMU CFS-1_BBB], definition['supportedTargets']
    assert_equal 18, definition['steps'].size
    assert validate(definition)
    [%w[CFS-1_QEMU], %w[CFS-1_BBB CFS-1_BBB], %w[CFS-1_QEMU OTHER]].each do |targets|
      changed = @catalog.get('cs-crc-key-oracle')
      changed['supportedTargets'] = targets
      assert_error('invalid_catalog') { validate(changed) }
    end
    definition['steps'].pop
    assert_error('invalid_catalog') { validate(definition) }
  end

  def test_psp_crash_scenario_requires_observer_outcome_and_fixed_steps
    definition = @catalog.get('psp-mm-indirect-write')
    assert_equal false, definition.dig('successCriteria', 'requireFreshTelemetry')
    assert_equal 'confirm-sigsegv', definition['steps'].last['id']
    assert validate(definition)
    definition['successCriteria']['requireFreshTelemetry'] = true
    assert_error('invalid_catalog') { validate(definition) }
    definition = @catalog.get('psp-mm-indirect-write')
    definition['steps'].pop
    assert_error('invalid_catalog') { validate(definition) }
  end

  def test_ground_station_schedule_is_pinned_to_inst
    definition = @catalog.get('ground-station-tc-schedule')
    changes = [
      ->(d) { d['supportedTargets'] = ['CFS-1_QEMU'] },
      ->(d) { d['supportedTargets'] = %w[INST INST2] },
      ->(d) { d['steps'].reverse! },
      ->(d) { d['telemetryItems'].pop },
      ->(d) { d['timeoutSec'] = 120 }
    ]
    changes.each do |change|
      candidate = JSON.parse(JSON.generate(definition))
      change.call(candidate)
      assert_raises(Scenario::Error) { Scenario::Catalog.new(definitions: [candidate]) }
    end
    psp = @catalog.get('psp-mm-indirect-write')
    psp['supportedTargets'] = ['INST']
    assert_raises(Scenario::Error) { Scenario::Catalog.new(definitions: [psp]) }
  end
end

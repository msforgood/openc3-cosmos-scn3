require_relative 'test_helper'

class CatalogTest < ScenarioTest
  def definition
    @catalog.get('qemu-es-housekeeping')
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

  def test_tc_log_demo_is_fixed_for_each_target
    assert_error('scenario_not_found') { @catalog.get('qemu-cs-crc-key-oracle') }
    %w[qemu bbb].each do |platform|
      d = @catalog.get("#{platform}-tc-log-photo-traversal")
      assert validate(d)
      d['steps'][4]['phase'] = 'read-after'
      assert_error('invalid_catalog') { validate(d) }
      d = @catalog.get("#{platform}-tc-log-photo-traversal")
      d['telemetryItems'] << {'packet' => 'CFE_ES_HK', 'item' => 'COMMAND_COUNTER'}
      assert_error('invalid_catalog') { validate(d) }
    end
  end
end

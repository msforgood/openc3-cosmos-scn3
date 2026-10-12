require 'minitest/autorun'

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(ROOT, 'targets/CFS/lib'))
require 'cfs_cmd_tlm_list'
require 'cfs_intf_configs'
require_relative '../targets/CFS_FLEET/lib/cfs_fleet_globals'

class TcLogContractTest < Minitest::Test
  def section(filename, kind, packet)
    source = File.read(File.join(ROOT, 'targets/CFS/cmd_tlm', filename))
    marker = /^<%= cfs_#{kind}_hdr\(target_name, '#{Regexp.escape(packet)}',.*$\n?/
    match = source.match(marker)
    refute_nil match, "missing #{packet} definition"
    tail = source[match.end(0)..]
    tail.split(/^<%= cfs_(?:cmd|tlm)_hdr\(/, 2).first
  end

  def fields(source, kind)
    source.lines.filter_map do |line|
      match = line.match(/^\s*APPEND_(#{kind}|ARRAY_ITEM)\s+(\w+)\s+(\d+)\s+(\w+)(?:\s+(\d+))?/)
      next unless match
      [match[2], match[3].to_i, match[4], match[1] == 'ARRAY_ITEM' ? match[5].to_i : nil]
    end
  end

  def test_dual_cpu1_targets_share_packet_ids_and_use_distinct_telemetry_ports
    assert_equal ['CFS-1_BBB', 'CFS-1_QEMU'], cfs_fleet_target_names
    cfs_fleet_target_names.each do |target|
      assert_equal 1, cfs_cpu_num_from_target_name(target)
      assert_equal '1234', cfs_get_port_num_cmd(target)
    end
    assert_equal '1235', cfs_get_port_num_tlm('CFS-1_BBB')
    assert_equal '1236', cfs_get_port_num_tlm('CFS-1_QEMU')
    {
      'CI_LOG_STATUS_CMD' => '0x1884', 'CI_LOG_SEAL_CMD' => '0x1884',
      'CI_LOG_READ_CMD' => '0x1884', 'TC_CAMERA_CAPTURE_CMD' => '0x18E2',
      'CI_LOG_STATUS' => '0x08E0', 'CI_LOG_CHUNK' => '0x08E1',
      'TC_CAMERA_RESULT' => '0x08E2'
    }.each do |packet, mid|
      assert_equal mid, get_cfs_pkt_msg_id(packet, 1), packet
    end
  end

  def test_command_payloads_match_flight_wire_layout
    cmd = 'ci_lab_cmd_def.txt'
    assert_equal [['REQUEST_ID', 16, 'UINT', nil], ['RESERVED', 16, 'UINT', nil]],
                 fields(section(cmd, 'cmd', 'CI_LOG_STATUS_CMD'), 'PARAMETER')
    assert_equal fields(section(cmd, 'cmd', 'CI_LOG_STATUS_CMD'), 'PARAMETER'),
                 fields(section(cmd, 'cmd', 'CI_LOG_SEAL_CMD'), 'PARAMETER')
    assert_equal [['REQUEST_ID', 16, 'UINT', nil], ['FILE_INDEX', 16, 'UINT', nil],
                  ['OFFSET', 32, 'UINT', nil]],
                 fields(section(cmd, 'cmd', 'CI_LOG_READ_CMD'), 'PARAMETER')
    assert_equal [['REQUEST_ID', 16, 'UINT', nil], ['FILENAME', 256, 'STRING', nil]],
                 fields(section('tc_camera_cmd_def.txt', 'cmd', 'TC_CAMERA_CAPTURE_CMD'), 'PARAMETER')
  end

  def test_telemetry_payloads_match_flight_wire_layout
    status = fields(section('ci_log_tlm_def.txt', 'tlm', 'CI_LOG_STATUS'), 'ITEM')
    assert_equal %w[REQUEST_ID RESULT ACTIVE_INDEX LAST_CLOSED_INDEX ACTIVE_RECORDS TOTAL_LOGGED WRITE_ERRORS READ_ERRORS], status.map(&:first)
    assert_equal [16, 16, 16, 16, 32, 32, 32, 32], status.map { |field| field[1] }
    assert_equal 192, status.sum { |field| field[1] }

    chunk = fields(section('ci_log_tlm_def.txt', 'tlm', 'CI_LOG_CHUNK'), 'ITEM')
    assert_equal %w[REQUEST_ID RESULT FILE_INDEX DATA_LENGTH OFFSET FILE_SIZE DATA], chunk.map(&:first)
    assert_equal ['DATA', 8, 'UINT', 2048], chunk.last
    assert_equal 2176, chunk.sum { |field| field[3] || field[1] }

    camera = fields(section('tc_camera_tlm_def.txt', 'tlm', 'TC_CAMERA_RESULT'), 'ITEM')
    assert_equal %w[REQUEST_ID STATUS BYTES_WRITTEN FILENAME], camera.map(&:first)
    assert_equal [16, 16, 32, 256], camera.map { |field| field[1] }
    assert_equal 320, camera.sum { |field| field[1] }
  end
end

require 'minitest/autorun'

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(ROOT, 'targets/CFS/lib'))
$LOAD_PATH.unshift(File.join(ROOT, 'targets/CFS_FLEET/lib'))
require 'cfs_globals'
require 'cfs_cmd_tlm_list'
require 'cfs_intf_configs'
require 'cfs_fleet_globals'

class AllScenariosContractTest < Minitest::Test
  def test_bbb_and_qemu_have_separate_ccsds_and_xband_receivers
    assert_equal %w[CFS-1_BBB CFS-1_QEMU], cfs_fleet_target_names
    assert_equal '1235', cfs_get_port_num_tlm('CFS-1_BBB')
    assert_equal '1236', cfs_get_port_num_tlm('CFS-1_QEMU')
    assert_equal '4322', cfs_get_port_num_xband('CFS-1_BBB')
    assert_equal '4323', cfs_get_port_num_xband('CFS-1_QEMU')
    assert_raises(ArgumentError) { cfs_get_port_num_xband('CFS-2') }

    plugin = File.read(File.join(ROOT, 'plugin.txt'))
    assert_includes plugin, 'TARGET CFS_XBAND <%= instance_target %>_XBAND'
    assert_includes plugin, 'MAP_TLM_TARGET <%= instance_target %>_XBAND'
    refute_includes plugin, 'MAP_TARGET <%= instance_target %>_XBAND'
    assert File.file?(File.join(ROOT, 'targets/CFS_XBAND/cmd_tlm/xband_tlm_def.txt'))
  end

  def test_one_plugin_retains_all_scenario_message_ids
    {
      # Scenario 1: the custom CS build and separate encrypted X-band sender.
      'CS_CMD_ONE_SHOT' => '0x18D0',
      'CS_SEND_HK_CMD' => '0x18D1',
      'CS_HK' => '0x08D3',
      'XKEY_SEND_HK_CMD' => '0x18A2',
      'XKEY_HK' => '0x08A2',
      # Scenario 2: command logging and camera capture.
      'CI_LOG_STATUS_CMD' => '0x1884',
      'CI_LOG_CHUNK' => '0x08E1',
      'TC_CAMERA_CAPTURE_CMD' => '0x18E2',
      # Scenario 3: bounded MM access and payload state.
      'MM_CMD_DEBUG_MAP' => '0x18E6',
      'MM_DEBUG' => '0x08E6',
      'PAYLOAD_DATA_STATE' => '0x08E4'
    }.each do |packet, expected_mid|
      assert_equal expected_mid, get_cfs_pkt_msg_id(packet, 1), packet
    end
  end

  def test_single_payload_data_app_packet_contract
    command = File.read(File.join(ROOT, 'targets/CFS/cmd_tlm/payload_data_cmd_def.txt'))
    telemetry = File.read(File.join(ROOT, 'targets/CFS/cmd_tlm/payload_data_tlm_def.txt'))
    assert_equal '0x18E4', get_cfs_pkt_msg_id('PAYLOAD_DATA_RESUME_CMD', 1)
    assert_equal '0x08E4', get_cfs_pkt_msg_id('PAYLOAD_DATA_STATE', 1)
    assert_includes command, "'PAYLOAD_DATA_RESUME_CMD', 3"
    assert_equal %w[STATE LAST_SAMPLE RESERVED SAMPLE_COUNT POINTER_SLOT WRITE_TARGET_ADDRESS BUFFER_ADDRESS GUARD_ADDRESS LAST_ACTION LAST_ERROR],
                 telemetry.scan(/^\s*APPEND_ITEM\s+(\S+)/).flatten
    refute File.exist?(File.join(ROOT, 'targets/CFS/cmd_tlm/payload_ctrl_tlm_def.txt'))
    refute_includes $CFS_CMD_TLM_LIST.keys, 'PAYLOAD_CTRL_STATE'
  end

  def test_cs_housekeeping_screen_items_exist_for_bbb_and_qemu
    definition = File.read(File.join(ROOT, 'targets/CFS/cmd_tlm/cs_tlm_def.txt'))
    screen = File.read(File.join(ROOT, 'targets/CFS/screens/cs_hk_tlm_screen.txt'))
    packet_items = definition.scan(/^\s*APPEND_ITEM\s+(\S+)/).flatten
    packet_items.concat(%w[PACKET_TIMEFORMATTED RECEIVED_TIMEFORMATTED RECEIVED_COUNT])

    cfs_fleet_target_names.each do |target|
      rendered = screen.gsub('<%= target_name %>', target)
      references = rendered.scan(/^\s*(?:LABELVALUEDESC|VALUE)\s+#{Regexp.escape(target)}\s+CS_HK\s+(\S+)/).flatten
      refute_empty references, "#{target}: no CS_HK screen references found"
      assert_empty references - packet_items, "#{target}: undefined CS_HK screen items"
    end
  end

  def test_cs_housekeeping_screen_uses_scenario_runner_passive_widgets
    screen = File.read(File.join(ROOT, 'targets/CFS/screens/cs_hk_tlm_screen.txt'))
    allowed = %w[SCREEN SETTING END VERTICAL HORIZONTAL VERTICALBOX HORIZONTALBOX
                 TABBOOK TABITEM VALUE LABELVALUE LABELVALUEDESC TITLE LABEL
                 SPACER HORIZONTALLINE]
    keywords = screen.lines.filter_map do |line|
      line = line.strip
      next if line.empty? || line.start_with?('<%', '#')
      line.split.first.upcase
    end
    assert_empty keywords - allowed
  end
end

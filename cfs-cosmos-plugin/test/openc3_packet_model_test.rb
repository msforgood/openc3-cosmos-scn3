require 'minitest/autorun'
require 'erb'
require 'tempfile'

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(ROOT, 'targets/CFS/lib'))
require 'cfs_packet_headers'
require 'openc3/packets/packet_config'

class Openc3PacketModelTest < Minitest::Test
  TARGET = 'CFS-1_QEMU'

  def setup
    cfs_globals_set_eds_enabled('false')
    cfs_globals_set_mem_addr_size('32')
    cfs_globals_set_endianness('LITTLE_ENDIAN')
    @config = OpenC3::PacketConfig.new
    target_name = TARGET
    %w[ci_lab_cmd_def.txt ci_log_tlm_def.txt tc_camera_cmd_def.txt tc_camera_tlm_def.txt].each do |filename|
      source = File.read(File.join(ROOT, 'targets/CFS/cmd_tlm', filename))
      Tempfile.create(['packet_', '.txt']) do |file|
        file.write(ERB.new(source).result(binding))
        file.flush
        @config.process_file(file.path, TARGET)
      end
    end
  end

  def command(name, mid, fc, length)
    packet = @config.commands.fetch(TARGET).fetch(name)
    assert_equal length, packet.defined_length, name
    {
      'CCSDS_STREAMID' => mid,
      'CCSDS_SEQUENCE' => 0xC000,
      'CCSDS_LENGTH' => 1,
      'CCSDS_FC' => fc,
      'CCSDS_CHECKSUM' => 0
    }.each do |field, expected|
      assert_equal expected, packet.get_item(field).default, "#{name}.#{field}"
    end
    packet
  end

  def item(packet, name, offset, size, type)
    field = packet.get_item(name)
    assert_equal offset * 8, field.bit_offset, "#{packet.packet_name}.#{name} offset"
    assert_equal size, field.bit_size, "#{packet.packet_name}.#{name} size"
    assert_equal type, field.data_type, "#{packet.packet_name}.#{name} type"
    field
  end

  def test_commands_match_wire_layout
    command('CI_LAB_SEND_HK_CMD', 0x1885, 0, 8)

    status = command('CI_LOG_STATUS_CMD', 0x1884, 2, 12)
    item(status, 'REQUEST_ID', 8, 16, :UINT)
    item(status, 'RESERVED', 10, 16, :UINT)

    seal = command('CI_LOG_SEAL_CMD', 0x1884, 3, 12)
    item(seal, 'REQUEST_ID', 8, 16, :UINT)
    item(seal, 'RESERVED', 10, 16, :UINT)

    read = command('CI_LOG_READ_CMD', 0x1884, 4, 16)
    item(read, 'REQUEST_ID', 8, 16, :UINT)
    item(read, 'FILE_INDEX', 10, 16, :UINT)
    item(read, 'OFFSET', 12, 32, :UINT)

    camera = command('TC_CAMERA_CAPTURE_CMD', 0x18E2, 2, 42)
    item(camera, 'REQUEST_ID', 8, 16, :UINT)
    item(camera, 'FILENAME', 10, 256, :STRING)
  end

  def test_telemetry_matches_wire_layout
    status = @config.telemetry.fetch(TARGET).fetch('CI_LOG_STATUS')
    assert_equal 40, status.defined_length
    item(status, 'REQUEST_ID', 16, 16, :UINT)
    item(status, 'RESULT', 18, 16, :UINT)
    item(status, 'ACTIVE_INDEX', 20, 16, :UINT)
    item(status, 'LAST_CLOSED_INDEX', 22, 16, :UINT)
    item(status, 'ACTIVE_RECORDS', 24, 32, :UINT)
    item(status, 'TOTAL_LOGGED', 28, 32, :UINT)
    item(status, 'WRITE_ERRORS', 32, 32, :UINT)
    item(status, 'READ_ERRORS', 36, 32, :UINT)

    chunk = @config.telemetry.fetch(TARGET).fetch('CI_LOG_CHUNK')
    assert_equal 288, chunk.defined_length
    item(chunk, 'REQUEST_ID', 16, 16, :UINT)
    item(chunk, 'RESULT', 18, 16, :UINT)
    item(chunk, 'FILE_INDEX', 20, 16, :UINT)
    item(chunk, 'DATA_LENGTH', 22, 16, :UINT)
    item(chunk, 'OFFSET', 24, 32, :UINT)
    item(chunk, 'FILE_SIZE', 28, 32, :UINT)
    data = item(chunk, 'DATA', 32, 8, :UINT)
    assert_equal 2048, data.array_size
    raw_chunk = ("\0" * 32) + (0...256).to_a.pack('C*')
    assert_equal (0...256).to_a, chunk.read('DATA', :RAW, raw_chunk)

    camera = @config.telemetry.fetch(TARGET).fetch('TC_CAMERA_RESULT')
    assert_equal 56, camera.defined_length
    item(camera, 'REQUEST_ID', 16, 16, :UINT)
    item(camera, 'STATUS', 18, 16, :UINT)
    item(camera, 'BYTES_WRITTEN', 20, 32, :UINT)
    item(camera, 'FILENAME', 24, 256, :STRING)
  end
end

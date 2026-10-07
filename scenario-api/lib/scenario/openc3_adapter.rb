require 'net/http'
require 'uri'
require 'timeout'
require 'openc3'
require 'openc3/utilities/authorization'
require 'openc3/models/target_model'
require 'openc3/models/script_status_model'
require 'openc3/utilities/target_file'
require_relative 'service'

# Core's module gates token verification on this global. This service never permits anonymous mode.
$openc3_authorize = true

module Scenario
  class Authentication
    include OpenC3::Authorization

    def authorize!(permission:, scope:, target:, packet:, token:)
      Timeout.timeout(5) do
        authorize(permission: permission, scope: scope, target_name: target, packet_name: packet, token: token, manual: false)
      end
    rescue OpenC3::AuthError
      raise Error.new('unauthenticated', nil, 401)
    rescue OpenC3::ForbiddenError
      raise Error.new('forbidden', nil, 403)
    rescue StandardError
      raise Error.new('authorization_unavailable', nil, 503)
    end
  end

  class OpenC3Adapter
    MAX_STATUS_SCAN = 1000
    def initialize(script_api_url:, public_api_url:, policy_path: File.expand_path('../../config/safety_policy.json', __dir__))
      @script_api_url = safe_url(script_api_url)
      @public_api_url = safe_url(public_api_url).to_s.sub(%r{/$}, '')
      raise Error.new('invalid_policy') if File.size(policy_path) > 65_536
      @policy = JSON.parse(File.read(policy_path, encoding: 'UTF-8'))
      raise Error.new('invalid_policy') unless @policy['version'] == 1
    end

    def validate_definition!(scope, target, definition)
      raise Error.new('unsupported_target') unless @policy.fetch('allowedTargets').include?(target)
      Timeout.timeout(8) do
        validate_tc_log(scope, target) if definition['steps'].any? { |step| step['type'] == 'tcLogPhase' }
        validate_psp(scope, target) if definition['steps'].any? { |step| step['type'] == 'pspPhase' }
        definition['steps'].each do |step|
          if step['type'] == 'command'
            # Policy is packaged identically with the procedure, not duplicated packet names in code.
            command_policy = @policy.fetch('commands')[step['packet']]
            unless command_policy && step['parameters'] == {}
              raise Error.new('unsupported_command')
            end
            packet = OpenC3::TargetModel.packet(target, step['packet'], type: :CMD, scope: scope)
            unless packet['target_name'] == target && packet['packet_name'] == step['packet'] &&
                   %w[hazardous disabled hidden].none? { |key| packet[key] }
              raise Error.new('unsafe_command_definition', nil, 409)
            end
            expected = @policy.fetch('headerDefaults').merge('CCSDS_STREAMID' => command_policy.fetch('streamId'))
            items = packet.fetch('items', []).to_h { |item| [item['name'], item] }
            expected.each do |name, value|
              item = items[name]
              raise Error.new('command_header_mismatch', nil, 409) unless item && item['default'] == value
            end
            # Extra hidden/defaulted parameters can change the meaning of an apparently empty command.
            reserved = OpenC3::Packet::RESERVED_ITEM_NAMES
            unless (items.keys - expected.keys - reserved).empty? &&
                   (items.keys & reserved).all? { |name| items[name]['data_type'] == 'DERIVED' } &&
                   items['CCSDS_STREAMID']['id_value'] == command_policy.fetch('streamId')
              raise Error.new('command_parameter_mismatch', nil, 409)
            end
          elsif step['type'] == 'crcByte'
            validate_crc_command(scope, target) if step['offset'] == 0
          elsif step['type'] == 'waitTelemetry'
            validate_item(scope, target, step)
          end
        end
        definition['telemetryItems'].each { |item| validate_item(scope, target, item) }
        catalog_text = OpenC3::TargetFile.body(scope, 'SCENARIO_RUNNER/lib/scenarios.json')
        raise Error.new('installed_definition_missing', nil, 409) unless catalog_text && catalog_text.bytesize <= 262_144
        installed = JSON.parse(catalog_text).find { |d| d['id'] == definition['id'] }
        unless installed && Canonical.hash(installed) == Canonical.hash(definition)
          raise Error.new('installed_definition_mismatch', nil, 409)
        end
        policy_text = OpenC3::TargetFile.body(scope, 'SCENARIO_RUNNER/lib/safety_policy.json')
        unless policy_text && policy_text.bytesize <= 65_536 && Canonical.hash(JSON.parse(policy_text)) == Canonical.hash(@policy)
          raise Error.new('installed_policy_mismatch', nil, 409)
        end
        procedure = OpenC3::TargetFile.body(scope, Service::PROCEDURE)
        raise Error.new('procedure_missing', nil, 409) unless procedure && procedure.bytesize.between?(1, 65_536)
      end
      true
    rescue Error
      raise
    rescue StandardError
      raise Error.new('installed_definition_unavailable', nil, 503)
    end

    def launch(run, token)
      uri = @script_api_url.dup
      uri.path = "#{uri.path.sub(%r{/$}, '')}/script-api/scripts/#{Service::PROCEDURE}/run"
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = token
      request['Content-Type'] = 'application/json'
      environment = {
        'SCENARIO_RUN_ID' => run['id'], 'SCENARIO_API_URL' => @public_api_url,
        'SCENARIO_DEFINITION_HASH' => run['definition_hash'], 'SCENARIO_CONTRACT_VERSION' => '1'
      }.map { |key, value| { 'key' => key, 'value' => value } }
      request.body = JSON.generate('scope' => run['scope'], 'environment' => environment)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout, http.read_timeout, http.write_timeout = 3, 5, 3
      http.max_retries = 0
      body = +''
      Timeout.timeout(10) do
        http.start do |session|
          session.request(request) do |response|
            raise Error.new('launch_ambiguous', nil, 503) unless response.code == '200'
            response.read_body do |part|
              raise Error.new('launch_ambiguous', nil, 503) if body.bytesize + part.bytesize > 128
              body << part
            end
          end
        end
      end
      body.strip
    end

    def status(scope, script_id)
      Timeout.timeout(5) { OpenC3::ScriptStatusModel.get(name: script_id, scope: scope) }
    end

    def find(run)
      Timeout.timeout(8) do
        # Both stores are needed: ScriptStatusModel.update moves completed runs out of running.
        %w[running completed].flat_map do |type|
          OpenC3::ScriptStatusModel.all(scope: run['scope'], type: type, offset: 0, limit: MAX_STATUS_SCAN).compact
        end.select do |status|
          status.dig('environment', 'SCENARIO_RUN_ID') == run['id']
        end
      end
    end

    def stop(run)
      # Mirrors running_script_publish in 6.10.1. This is a stop request, never proof of process exit.
      status_record = status(run['scope'], run['script_id'])
      unless status_record && status_record['filename'] == Service::PROCEDURE &&
             status_record.dig('environment', 'SCENARIO_RUN_ID') == run['id'] &&
             status_record.dig('environment', 'SCENARIO_DEFINITION_HASH') == run['definition_hash']
        raise Error.new('runner_unverified', nil, 409)
      end
      Timeout.timeout(5) { OpenC3::Store.publish("script-api:cmd-running-script-channel:#{run['script_id']}", JSON.generate('stop')) }
    end

    private

    def validate_tc_log(scope, target)
      policy = @policy.fetch('tcLogTraversal')
      raise Error.new('unsupported_target') unless policy.fetch('scenarioIds').key?(target)
      command_fields = {
        'CI_LOG_STATUS_CMD' => [2, {'REQUEST_ID' => ['UINT', 16], 'RESERVED' => ['UINT', 16]}],
        'CI_LOG_SEAL_CMD' => [3, {'REQUEST_ID' => ['UINT', 16], 'RESERVED' => ['UINT', 16]}],
        'CI_LOG_READ_CMD' => [4, {'REQUEST_ID' => ['UINT', 16], 'FILE_INDEX' => ['UINT', 16], 'OFFSET' => ['UINT', 32]}],
        'TC_CAMERA_CAPTURE_CMD' => [2, {'REQUEST_ID' => ['UINT', 16], 'FILENAME' => ['STRING', 256]}],
        'CFE_ES_SEND_HK_CMD' => [0, {}]
      }
      command_fields.each do |name, (function_code, fields)|
        packet = OpenC3::TargetModel.packet(target, name, type: :CMD, scope: scope)
        unless packet['target_name'] == target && packet['packet_name'] == name &&
               %w[hazardous disabled hidden].none? { |flag| packet[flag] }
          raise Error.new('unsafe_command_definition', nil, 409)
        end
        items = packet.fetch('items', []).to_h { |item| [item['name'], item] }
        header = @policy.fetch('headerDefaults').merge('CCSDS_STREAMID' => @policy.fetch('commands').fetch(name).fetch('streamId'),
                                                       'CCSDS_FC' => function_code)
        reserved = OpenC3::Packet::RESERVED_ITEM_NAMES
        unless (items.keys - header.keys - reserved).sort == fields.keys.sort &&
               header.all? { |item, value| items.dig(item, 'default') == value } &&
               items.dig('CCSDS_STREAMID', 'id_value') == header.fetch('CCSDS_STREAMID') &&
               fields.all? { |item, (kind, size)| items.dig(item, 'data_type') == kind && items.dig(item, 'bit_size') == size }
          raise Error.new('command_parameter_mismatch', nil, 409)
        end
      end
      telemetry_fields = {
        'CI_LOG_STATUS' => {'REQUEST_ID' => 16, 'RESULT' => 16, 'ACTIVE_INDEX' => 16, 'LAST_CLOSED_INDEX' => 16,
                            'ACTIVE_RECORDS' => 32, 'TOTAL_LOGGED' => 32, 'WRITE_ERRORS' => 32, 'READ_ERRORS' => 32},
        'CI_LOG_CHUNK' => {'REQUEST_ID' => 16, 'RESULT' => 16, 'FILE_INDEX' => 16,
                           'DATA_LENGTH' => 16, 'OFFSET' => 32, 'FILE_SIZE' => 32, 'DATA' => 8},
        'TC_CAMERA_RESULT' => {'REQUEST_ID' => 16, 'STATUS' => 16, 'BYTES_WRITTEN' => 32, 'FILENAME' => 256}
      }
      telemetry_fields.each do |name, fields|
        packet = OpenC3::TargetModel.packet(target, name, type: :TLM, scope: scope)
        raise Error.new('telemetry_definition_mismatch', nil, 409) unless packet['target_name'] == target && packet['packet_name'] == name
        items = packet.fetch('items', []).to_h { |item| [item['name'], item] }
        unless fields.all? { |item, size| items.dig(item, 'data_type') == (item == 'FILENAME' ? 'STRING' : 'UINT') && items.dig(item, 'bit_size') == size } &&
               %w[RECEIVED_TIMESECONDS RECEIVED_COUNT].all? { |item| items.dig(item, 'data_type') == 'DERIVED' }
          raise Error.new('telemetry_definition_mismatch', nil, 409)
        end
      end
    end

    def validate_psp(scope, target)
      policy = @policy.fetch('pspIndirectWrite')
      raise Error.new('unsupported_target') unless policy.fetch('scenarioIds').key?(target)
      command_fields = {
        'MM_CMD_DEBUG_MAP' => [13, {'REQUEST_ID' => ['UINT', 32]}],
        'MM_CMD_DEBUG_READ' => [14, {'REQUEST_ID' => ['UINT', 32], 'WIDTH_BYTES' => ['UINT', 32], 'ADDRESS' => ['UINT', 64]}],
        'MM_CMD_DEBUG_WRITE' => [15, {'REQUEST_ID' => ['UINT', 32], 'WIDTH_BYTES' => ['UINT', 32],
                                     'ADDRESS' => ['UINT', 64], 'VALUE' => ['UINT', 32], 'RESERVED' => ['UINT', 32]}],
        'PAYLOAD_PULSE_PAUSE_CMD' => [2, {}],
        'PAYLOAD_PULSE_RESUME_CMD' => [3, {}],
        'PAYLOAD_PULSE_STATUS_CMD' => [4, {}],
        'PAYLOAD_CTRL_STATUS_CMD' => [2, {}]
      }
      raise Error.new('invalid_policy') unless command_fields.keys.sort == policy.fetch('commandPackets').sort
      command_fields.each do |name, (function_code, fields)|
        packet = OpenC3::TargetModel.packet(target, name, type: :CMD, scope: scope)
        unless packet['target_name'] == target && packet['packet_name'] == name &&
               %w[hazardous disabled hidden].none? { |flag| packet[flag] }
          raise Error.new('unsafe_command_definition', nil, 409)
        end
        items = packet.fetch('items', []).to_h { |item| [item['name'], item] }
        header = @policy.fetch('headerDefaults').merge('CCSDS_STREAMID' => @policy.fetch('commands').fetch(name).fetch('streamId'),
                                                       'CCSDS_FC' => function_code)
        reserved = OpenC3::Packet::RESERVED_ITEM_NAMES
        unless (items.keys - header.keys - reserved).sort == fields.keys.sort &&
               header.all? { |item, value| items.dig(item, 'default') == value } &&
               items.dig('CCSDS_STREAMID', 'id_value') == header.fetch('CCSDS_STREAMID') &&
               fields.all? { |item, (kind, size)| items.dig(item, 'data_type') == kind && items.dig(item, 'bit_size') == size }
          raise Error.new('command_parameter_mismatch', nil, 409)
        end
      end
      telemetry_fields = {
        'MM_DEBUG' => {'REQUEST_ID' => 32, 'OPERATION' => 32, 'STATUS' => 32, 'WIDTH_BYTES' => 32,
                       'MODULE_START' => 64, 'MODULE_END' => 64, 'POINTER_SLOT' => 64,
                       'ADDRESS' => 64, 'VALUE' => 64},
        'PAYLOAD_PULSE_STATE' => {'STATE' => 8, 'BOUND' => 8, 'LAST_VALUE' => 8, 'FAULT_LATCH' => 8,
                                  'PULSE_COUNT' => 32, 'SLOT_ADDRESS' => 32,
                                  'FEED_TARGET_ADDRESS' => 32, 'AUTHORIZED_KICK_ADDRESS' => 32,
                                  'BIND_COUNT' => 32, 'LAST_ACTION' => 32, 'LAST_ERROR' => 32},
        'PAYLOAD_CTRL_STATE' => {'MODE' => 8, 'KICK' => 8, 'FAULT' => 8, 'HALT_ACKED' => 8,
                                 'SEEN_TRANSITIONS' => 32, 'FAULT_COUNT' => 32,
                                 'KICK_ADDRESS' => 32, 'MODE_ADDRESS' => 32,
                                 'LAST_FAULT_VALUE' => 32, 'LAST_CONTROL_SEQUENCE' => 32}
      }
      raise Error.new('invalid_policy') unless telemetry_fields.keys.sort == policy.fetch('telemetryPackets').sort
      telemetry_fields.each do |name, fields|
        packet = OpenC3::TargetModel.packet(target, name, type: :TLM, scope: scope)
        raise Error.new('telemetry_definition_mismatch', nil, 409) unless packet['target_name'] == target && packet['packet_name'] == name
        items = packet.fetch('items', []).to_h { |item| [item['name'], item] }
        unless fields.all? { |item, size| items.dig(item, 'data_type') == 'UINT' && items.dig(item, 'bit_size') == size } &&
               %w[RECEIVED_TIMESECONDS RECEIVED_COUNT].all? { |item| items.dig(item, 'data_type') == 'DERIVED' }
          raise Error.new('telemetry_definition_mismatch', nil, 409)
        end
      end
      event_packet = OpenC3::TargetModel.packet(target, policy.fetch('eventPacket'), type: :TLM, scope: scope)
      unless event_packet['target_name'] == target && event_packet['packet_name'] == policy.fetch('eventPacket')
        raise Error.new('telemetry_definition_mismatch', nil, 409)
      end
      event_items = event_packet.fetch('items', []).to_h { |item| [item['name'], item] }
      unless event_items.dig('PACKET_ID_APP_NAME', 'data_type') == 'STRING' &&
             event_items.dig('PACKET_ID_APP_NAME', 'bit_size') == 160 &&
             event_items.dig('PACKET_ID_EVENT_ID', 'data_type') == 'UINT' &&
             event_items.dig('PACKET_ID_EVENT_ID', 'bit_size') == 16 &&
             event_items.dig('MESSAGE', 'data_type') == 'STRING' &&
             event_items.dig('MESSAGE', 'bit_size') == 976 &&
             %w[RECEIVED_TIMESECONDS RECEIVED_COUNT].all? { |item| event_items.dig(item, 'data_type') == 'DERIVED' }
        raise Error.new('telemetry_definition_mismatch', nil, 409)
      end
    end

    def validate_item(scope, target, item)
      packets = @policy.fetch('commands').values.map { |command| command.fetch('telemetryPacket') }
      unless packets.include?(item['packet']) && @policy.fetch('telemetryItems').include?(item['item'])
        raise Error.new('unsupported_telemetry')
      end
      packet = OpenC3::TargetModel.packet(target, item['packet'], type: :TLM, scope: scope)
      unless packet['target_name'] == target && packet['packet_name'] == item['packet']
        raise Error.new('telemetry_definition_mismatch', nil, 409)
      end
      items = packet.fetch('items', []).to_h { |i| [i['name'], i] }
      data = items[item['item']]
      expected_size = @policy.fetch('telemetryTypes', {}).fetch("#{item['packet']}.#{item['item']}", 8)
      unless data && data['data_type'] == 'UINT' && data['bit_size'] == expected_size &&
             %w[RECEIVED_TIMESECONDS RECEIVED_COUNT].all? { |name| items.dig(name, 'data_type') == 'DERIVED' }
        raise Error.new('telemetry_item_missing', nil, 409)
      end
    end

    def validate_crc_command(scope, target)
      policy = @policy.fetch('crcKeyOracle')
      %w[checksumSizeItem checksumBusyItem].each do |name|
        validate_item(scope, target, {'packet' => policy.fetch('checksumPacket'), 'item' => policy.fetch(name)})
      end
      packet = OpenC3::TargetModel.packet(target, policy.fetch('command'), type: :CMD, scope: scope)
      unless packet['target_name'] == target && packet['packet_name'] == policy.fetch('command') &&
             %w[hazardous disabled hidden].none? { |key| packet[key] }
        raise Error.new('unsafe_command_definition', nil, 409)
      end
      items = packet.fetch('items', []).to_h { |item| [item['name'], item] }
      expected = @policy.fetch('headerDefaults').merge('CCSDS_STREAMID' => policy.fetch('streamId'))
      expected.each do |name, value|
        raise Error.new('command_header_mismatch', nil, 409) unless items.dig(name, 'default') == value
      end
      fields = %w[ADDRESS SIZE MAX_BYTES_PER_CYCLE]
      reserved = OpenC3::Packet::RESERVED_ITEM_NAMES
      unless (items.keys - expected.keys - reserved).sort == fields.sort &&
             fields.all? { |name| items.dig(name, 'data_type') == 'UINT' && items.dig(name, 'bit_size') == 32 } &&
             (items.keys & reserved).all? { |name| items[name]['data_type'] == 'DERIVED' } &&
             items.dig('CCSDS_STREAMID', 'id_value') == policy.fetch('streamId')
        raise Error.new('command_parameter_mismatch', nil, 409)
      end
    end

    def safe_url(value)
      uri = URI.parse(value)
      raise Error.new('invalid_service_url') unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
      uri
    end
  end
end

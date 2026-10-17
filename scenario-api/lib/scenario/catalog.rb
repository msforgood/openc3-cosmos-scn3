require 'json'
require 'digest'
require_relative 'errors'

module Scenario
  class Catalog
    ID = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}\z/
    NAME = /\A[A-Z][A-Z0-9_-]{0,95}\z/
    attr_reader :definitions

    def initialize(path: nil, definitions: nil, policy_path: nil)
      raise Error.new('catalog_too_large') if path && File.size(path) > 65_536
      policy_path ||= File.join(path ? File.dirname(path) : File.expand_path('../../config', __dir__), 'safety_policy.json')
      # OpenC3 sets Ruby's default internal encoding to BINARY. Read UTF-8 JSON
      # without implicit transcoding so localized scenario names remain valid.
      @policy = JSON.parse(File.binread(policy_path).force_encoding(Encoding::UTF_8))
      @definitions = definitions || JSON.parse(File.binread(path).force_encoding(Encoding::UTF_8))
      raise Error.new('invalid_catalog') unless @definitions.is_a?(Array) && @definitions.size.between?(1, 32)
      raise Error.new('catalog_too_large') if Canonical.json(@definitions).bytesize > 65_536
      check(@definitions.all? { |d| d.is_a?(Hash) })
      raise Error.new('duplicate_scenario') unless @definitions.map { |d| d['id'] }.uniq.size == @definitions.size
      @definitions.each { |d| validate!(d) }
      @definitions = JSON.parse(Canonical.json(@definitions))
    end

    def get(id)
      d = @definitions.find { |item| item['id'] == id }
      raise Error.new('scenario_not_found', nil, 404) unless d
      JSON.parse(JSON.generate(d))
    end

    def presentation(d)
      d.merge('definition_hash' => Canonical.hash(d))
    end

    private

    def validate!(d)
      keys!(d, %w[schemaVersion id version name description supportedTargets timeoutSec steps telemetryItems successCriteria])
      check(d['schemaVersion'].is_a?(Integer) && d['schemaVersion'] == 1)
      definition_id!(d['id'])
      check(d['version'].is_a?(String) && d['version'].length <= 32 && /\A[0-9]+\.[0-9]+\.[0-9]+\z/.match?(d['version']))
      { 'name' => 120, 'description' => 1000 }.each { |key, max| check(d[key].is_a?(String) && d[key].length.between?(1, max)) }
      targets = d['supportedTargets']
      schedule = schedule?(d)
      # The ground-station schedule runs on the demo INST target, never on cFS.
      allowed_targets = schedule ? @policy.fetch('groundStationSchedule').fetch('targets') : @policy.fetch('allowedTargets')
      check(targets.is_a?(Array) && targets.size.between?(1, allowed_targets.size) &&
            targets.uniq == targets && (targets - allowed_targets).empty?)
      if targets.include?('CFS-1_BBB')
        check([@policy.fetch('tcLogTraversal').fetch('scenarioId'),
               @policy.fetch('pspIndirectWrite').fetch('scenarioId'),
               @policy.fetch('crcKeyOracle').fetch('scenarioId')].include?(d['id']))
      end
      number!(d['timeoutSec'], 1, 120)
      is_psp = d['steps'].is_a?(Array) && d['steps'].any? { |step| step.is_a?(Hash) && step['type'] == 'pspPhase' }
      check(d['successCriteria'] == { 'type' => 'allStepsSucceeded', 'requireFreshTelemetry' => !is_psp })
      return validate_schedule!(d) if schedule
      check(d['telemetryItems'].is_a?(Array) && d['telemetryItems'].size.between?(1, 20))
      refs = d['telemetryItems'].map { |t| reference!(t) }
      check(refs.uniq.size == refs.size)
      check(d['steps'].is_a?(Array) && d['steps'].size.between?(2, 18) && d['steps'].all? { |s| s.is_a?(Hash) })
      check(d['steps'].map { |s| s['id'] }.uniq.size == d['steps'].size)
      return validate_crc_oracle!(d, refs) if d['steps'].any? { |s| %w[resolveAddress crcByte].include?(s['type']) }
      return validate_tc_log!(d, refs) if d['steps'].any? { |s| s['type'] == 'tcLogPhase' }
      return validate_psp!(d, refs) if d['steps'].any? { |s| s['type'] == 'pspPhase' }
      pending, waited, total, commands = [], [], 0, 0
      d['steps'].each do |s|
        definition_id!(s['id'])
        case s['type']
        when 'command'
          keys!(s, %w[id type packet parameters timeoutSec])
          command = @policy.fetch('commands')[s['packet']]
          check(command && s['parameters'] == {})
          number!(s['timeoutSec'], 0.1, 5)
          packet = command.fetch('telemetryPacket')
          check(!pending.include?(packet))
          pending << packet
          commands += 1
          total += s['timeoutSec'] + 1
        when 'waitTelemetry'
          keys!(s, %w[id type packet item operator value timeoutSec pollIntervalSec])
          ref = reference!(s.slice('packet', 'item'))
          check(refs.include?(ref) && pending.include?(s['packet']))
          check(%w[eq gte lte].include?(s['operator']))
          check(s['value'].is_a?(Integer) && s['value'].between?(0, 255))
          number!(s['timeoutSec'], 0.1, 30)
          number!(s['pollIntervalSec'], 0.25, 2)
          pending.delete(s['packet'])
          waited << ref
          total += s['timeoutSec']
        when 'delay'
          keys!(s, %w[id type seconds])
          number!(s['seconds'], 0, 5)
          total += s['seconds']
        else
          check(false)
        end
      end
      check(commands.between?(1, 4) && pending.empty? && waited.uniq.sort == refs.sort && total <= d['timeoutSec'])
    end

    def validate_crc_oracle!(definition, refs)
      policy = @policy.fetch('crcKeyOracle')
      steps = definition['steps']
      check(definition['id'] == policy.fetch('scenarioId') &&
            definition['supportedTargets'] == @policy.fetch('allowedTargets') && definition['timeoutSec'] == 120)
      check(steps.size == policy.fetch('keyBytes') + 2)
      check(refs.sort == [
        [policy.fetch('keyPacket'), policy.fetch('keyAddressItem')],
        [policy.fetch('keyPacket'), policy.fetch('keyLengthItem')],
        [policy.fetch('keyPacket'), policy.fetch('channelReadyItem')],
        [policy.fetch('checksumPacket'), policy.fetch('checksumAddressItem')],
        [policy.fetch('checksumPacket'), policy.fetch('checksumValueItem')],
        [policy.fetch('checksumPacket'), policy.fetch('checksumCommandCounterItem')],
        [policy.fetch('checksumPacket'), policy.fetch('checksumErrorCounterItem')],
        *%w[MAGIC IV_PREFIX COUNTER CIPHERTEXT_0 CIPHERTEXT_1 CIPHERTEXT_2 CIPHERTEXT_3 TAG_0 TAG_1 TAG_2 TAG_3].map { |item| [policy.fetch('xbandPacket'), item] }
      ].sort)
      first = steps.first
      keys!(first, %w[id type timeoutSec pollIntervalSec])
      check(first['id'] == 'locate-key' && first['type'] == 'resolveAddress')
      check(first['timeoutSec'] == 10 && first['pollIntervalSec'] == 0.5)
      steps[1...-1].each_with_index do |step, offset|
        keys!(step, %w[id type offset timeoutSec pollIntervalSec])
        check(step == {'id' => format('recover-byte-%02d', offset), 'type' => 'crcByte',
                       'offset' => offset, 'timeoutSec' => 6, 'pollIntervalSec' => 0.25})
      end
      check(steps.last == {'id' => 'verify-xband-frame', 'type' => 'verifyXbandFrame',
                           'timeoutSec' => 8, 'pollIntervalSec' => 0.25})
    end

    def validate_tc_log!(definition, refs)
      policy = @policy.fetch('tcLogTraversal')
      check(definition['id'] == policy.fetch('scenarioId') &&
            definition['supportedTargets'] == @policy.fetch('allowedTargets') && definition['timeoutSec'] == 120)
      check(refs.sort == [['CI_LOG_STATUS', 'RESULT'], ['CI_LOG_CHUNK', 'RESULT'], ['TC_CAMERA_RESULT', 'STATUS']].sort)
      phases = policy.fetch('phases')
      check(definition['steps'].size == phases.size)
      definition['steps'].zip(phases).each do |step, phase|
        keys!(step, %w[id type phase])
        check(step == {'id' => phase, 'type' => 'tcLogPhase', 'phase' => phase})
      end
    end

    def schedule?(definition)
      definition['id'] == @policy.fetch('groundStationSchedule').fetch('scenarioId') ||
        (definition['steps'].is_a?(Array) && definition['steps'].any? { |step| step.is_a?(Hash) && step['type'] == 'schedulePhase' })
    end

    def validate_schedule!(definition)
      policy = @policy.fetch('groundStationSchedule')
      check(definition['id'] == policy.fetch('scenarioId') &&
            definition['supportedTargets'] == policy.fetch('targets') && definition['timeoutSec'] == 60)
      link = policy.fetch('linkPacket')
      message = policy.fetch('messagePacket')
      check(definition['telemetryItems'] == [{ 'packet' => link, 'item' => policy.fetch('acceptCountItem') },
                                             { 'packet' => link, 'item' => policy.fetch('attitudeItem') },
                                             { 'packet' => message, 'item' => policy.fetch('sequenceItem') },
                                             { 'packet' => message, 'item' => policy.fetch('textItem') }])
      phases = policy.fetch('phases')
      check(definition['steps'].is_a?(Array) && definition['steps'].size == phases.size)
      definition['steps'].zip(phases).each do |step, phase|
        keys!(step, %w[id type phase])
        check(step == {'id' => phase, 'type' => 'schedulePhase', 'phase' => phase})
      end
    end

    def validate_psp!(definition, refs)
      policy = @policy.fetch('pspIndirectWrite')
      check(definition['id'] == policy.fetch('scenarioId') &&
            definition['supportedTargets'] == @policy.fetch('allowedTargets') && definition['timeoutSec'] == 120)
      check(refs.sort == [['MM_DEBUG', 'STATUS'], ['MM_DEBUG', 'POINTER_SLOT'], ['MM_DEBUG', 'ADDRESS'],
                          ['PAYLOAD_DATA_STATE', 'STATE'], ['PAYLOAD_DATA_STATE', 'WRITE_TARGET_ADDRESS'],
                          ['PAYLOAD_DATA_STATE', 'SAMPLE_COUNT']].sort)
      phases = policy.fetch('phases')
      check(definition['steps'].size == phases.size)
      definition['steps'].zip(phases).each do |step, phase|
        keys!(step, %w[id type phase])
        check(step == {'id' => phase, 'type' => 'pspPhase', 'phase' => phase})
      end
    end

    def keys!(value, keys)
      check(value.is_a?(Hash) && value.keys.sort == keys.sort)
    end

    def definition_id!(value)
      check(value.is_a?(String) && /\A[a-z][a-z0-9-]{0,63}\z/.match?(value))
    end

    def number!(value, min, max)
      check((value.is_a?(Integer) || value.is_a?(Float)) && value.finite? && value.between?(min, max))
    end

    def reference!(ref)
      keys!(ref, %w[packet item])
      packets = @policy.fetch('commands').values.map { |c| c['telemetryPacket'] } +
                @policy.fetch('passiveTelemetryPackets')
      check(packets.include?(ref['packet']) && @policy.fetch('telemetryItems').include?(ref['item']))
      [ref['packet'], ref['item']]
    end

    def check(ok)
      raise Error.new('invalid_catalog') unless ok
    end
  end
end

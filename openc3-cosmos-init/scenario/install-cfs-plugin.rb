require 'digest'
require 'rbconfig'
require 'rubygems/package'
require 'timeout'
require_relative 'bounded-process'

module CfsBootstrap
  GEM_PATH = '/openc3/plugins/gems/openc3-cosmos-cfs-7.0.5.pre.all.3.gem'.freeze
  GEM_SHA256 = '5971a987ca91e18303f84ed23761b81b0d4e837704e3034df216aae5355b8ccb'.freeze
  TARGETS = %w[CFS-1_QEMU CFS-1_BBB CFS-1_QEMU_XBAND CFS-1_BBB_XBAND CFS_FLEET].freeze
  INTERFACES = %w[CFS-1_QEMU_INTF CFS-1_BBB_INTF CFS-1_QEMU_XBAND_INTF CFS-1_BBB_XBAND_INTF].freeze
  REQUIRED_FILES = %w[
    plugin.txt
    targets/CFS/cmd_tlm/mm_cmd_def.txt
    targets/CFS/cmd_tlm/payload_data_cmd_def.txt
    targets/CFS/cmd_tlm/payload_data_tlm_def.txt
    targets/CFS_FLEET/lib/cfs_fleet_globals.rb
  ].freeze

  def self.artifact!
    raise ScenarioBootstrap::Failure, 'Bundled cFS gem is missing' unless File.file?(GEM_PATH)
    raise ScenarioBootstrap::Failure, 'Bundled cFS gem checksum mismatch' unless Digest::SHA256.file(GEM_PATH).hexdigest == GEM_SHA256

    package = Gem::Package.new(GEM_PATH)
    package.verify
    unless package.spec.name == 'openc3-cosmos-cfs' && package.spec.version.to_s == '7.0.5.pre.all.3' &&
           (REQUIRED_FILES - package.contents).empty?
      raise ScenarioBootstrap::Failure, 'Bundled cFS gem has unexpected identity or missing definitions'
    end
  end

  def self.plugin_names(scope)
    Timeout.timeout(10) { OpenC3::PluginModel.names(scope: scope).grep(/\Aopenc3-cosmos-cfs-\d/) }
  end

  def self.install!(scope:)
    artifact!
    require 'openc3/models/plugin_model'
    require 'openc3/models/target_model'
    require 'openc3/models/interface_model'

    raise ScenarioBootstrap::Failure, 'Multiple cFS target plugins are installed' if plugin_names(scope).length > 1
    ScenarioBootstrap.run_process(
      [RbConfig.ruby, '/openc3/bin/openc3cli', 'load', GEM_PATH, scope, '--variables',
       File.join(__dir__, 'empty-variables.json')],
      seconds: 300,
      env: { 'BUNDLE_GEMFILE' => nil, 'RUBYOPT' => nil, 'OPENC3_LOCAL_MODE' => nil }
    )

    expected = File.basename(GEM_PATH)
    installed = plugin_names(scope)
    unless installed.length == 1 && installed.first.split('__', 2).first == expected
      raise ScenarioBootstrap::Failure, 'Bundled cFS target plugin was not installed'
    end
    TARGETS.each do |name|
      target = Timeout.timeout(10) { OpenC3::TargetModel.get(name: name, scope: scope) }
      raise ScenarioBootstrap::Failure, "Missing installed cFS target: #{name}" unless target && target['plugin'] == installed.first
    end
    INTERFACES.each do |name|
      interface = Timeout.timeout(10) { OpenC3::InterfaceModel.get(name: name, scope: scope) }
      raise ScenarioBootstrap::Failure, "Missing installed cFS interface: #{name}" unless interface
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    scope = ENV.fetch('SCENARIO_SCOPE', 'DEFAULT')
    raise ScenarioBootstrap::Failure, 'Invalid scope' unless /\A[A-Z0-9_-]+\z/.match?(scope)
    CfsBootstrap.install!(scope: scope)
    puts 'Bundled cFS target plugin and QEMU/BBB interfaces ready.'
  rescue StandardError => error
    warn "cFS target plugin installation stopped (#{error.class}); inspect the packaged gem and installed plugin state."
    exit 1
  end
end

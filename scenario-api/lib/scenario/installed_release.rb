require 'json'
require 'digest'
require 'timeout'

module Scenario
  # These pins are code-owned; a runtime environment override cannot bless a
  # mismatched init/API pair. Build and publish both images as one release.
  class InstalledRelease
    RELEASE = '1.0.4'.freeze
    CORE_VERSION = '6.10.1'.freeze
    NAMES = %w[openc3-cosmos-cfs-scenario-runner openc3-cosmos-tool-scenariorunner].freeze
    FILES = {
      'catalog_sha256' => ['scenarios.json', 'SCENARIO_RUNNER/lib/scenarios.json'],
      'policy_sha256' => ['safety_policy.json', 'SCENARIO_RUNNER/lib/safety_policy.json'],
      'procedure_sha256' => ['run_scenario.py', 'SCENARIO_RUNNER/procedures/run_scenario.py']
    }.freeze
    class Failure < StandardError; end

    class Backend
      def initialize(scope:)
        require 'openc3/models/plugin_model'
        require 'openc3/models/target_model'
        require 'openc3/models/tool_model'
        require 'openc3/utilities/target_file'
        require 'openc3/utilities/bucket'
        @scope = scope
      end

      def names
        OpenC3::PluginModel.names(scope: @scope)
      end

      def plugin_for(name)
        model = if name == NAMES[0]
                  OpenC3::TargetModel.get(name: 'SCENARIO_RUNNER', scope: @scope)
                else
                  return nil unless OpenC3::Bucket.getClient.check_object(bucket: ENV.fetch('OPENC3_TOOLS_BUCKET'), key: 'scenariorunner/main.js', retries: false)
                  OpenC3::ToolModel.get(name: 'Scenario Runner', scope: @scope)
                end
        model && model['plugin']
      end

      def body(path)
        OpenC3::TargetFile.body(@scope, path)
      end

      def ui_body
        response = OpenC3::Bucket.getClient.get_object(bucket: ENV.fetch('OPENC3_TOOLS_BUCKET'), key: 'scenariorunner/main.js')
        response&.body&.read
      end
    end

    def initialize(state_directory:, catalog:, scope: 'DEFAULT', backend: nil, gem_home: '/gems')
      @directory, @catalog, @scope, @gem_home = state_directory, catalog, scope, gem_home
      @backend = backend
    end

    def verify!
      unless ENV.fetch('SCENARIO_VERSION', RELEASE) == RELEASE
        raise Failure, 'API image release does not match SCENARIO_VERSION'
      end
      raise Failure, 'Scenario installation is incomplete; maintenance recovery required' if File.exist?(File.join(@directory, '.scenario-install-incomplete'))
      ready = File.join(@directory, 'scenario-installed.json')
      raise Failure, 'Scenario installed-release record is missing or invalid' unless File.file?(ready) && File.size(ready).between?(1, 65_536)
      record = JSON.parse(File.read(ready))
      unless record.is_a?(Hash) && record.values_at('schema', 'version', 'core_version', 'scope') == [1, RELEASE, CORE_VERSION, @scope] &&
             record['gems'].is_a?(Hash) && record['gems'].keys.sort == NAMES.sort &&
             (record['gems'].values + [record['manifest_sha256'], record['ui_sha256']]).all? { |hash| hash.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(hash) }
        raise Failure, 'Scenario installed release does not match this API image'
      end
      hashes = FILES.to_h do |key, (local, _remote)|
        path = local == 'scenarios.json' ? @catalog : File.join(File.dirname(@catalog), local)
        expected = Digest::SHA256.file(path).hexdigest
        raise Failure, 'Scenario installed catalog, policy or procedure does not match this API image' unless record[key] == expected
        [key, expected]
      end
      @backend ||= Backend.new(scope: @scope)
      Timeout.timeout(45) do
        names = @backend.names
        NAMES.each do |name|
          matching = names.select { |item| item.start_with?("#{name}-") }
          pattern = /\A#{Regexp.escape(name)}-#{Regexp.escape(RELEASE)}\.gem(?:__\d+)?\z/
          unless matching.size == 1 && pattern.match?(matching.first) && @backend.plugin_for(name) == matching.first
            raise Failure, 'Installed Scenario plugin identity is incomplete or mismatched'
          end
        end
        FILES.each do |key, (_local, remote)|
          installed = File.join(@gem_home, 'gems', "#{NAMES[0]}-#{RELEASE}", 'targets', remote)
          body = @backend.body(remote)
          unless File.file?(installed) && Digest::SHA256.file(installed).hexdigest == hashes[key] && body && Digest::SHA256.hexdigest(body) == hashes[key]
            raise Failure, 'Installed Scenario procedure/configuration content is mismatched'
          end
        end
        ui = File.join(@gem_home, 'gems', "#{NAMES[1]}-#{RELEASE}", 'tools/scenariorunner/main.js')
        body = @backend.ui_body
        unless File.file?(ui) && Digest::SHA256.file(ui).hexdigest == record['ui_sha256'] && body && Digest::SHA256.hexdigest(body) == record['ui_sha256']
          raise Failure, 'Installed Scenario UI is missing or mismatched'
        end
      end
      true
    rescue Failure
      raise
    rescue StandardError
      # Redis, object-store and filesystem errors may embed credentials/URLs.
      raise Failure, 'Scenario installed release cannot be verified; startup refused'
    end
  end
end

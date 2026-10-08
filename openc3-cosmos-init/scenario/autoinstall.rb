require 'json'
require 'digest'
require 'rubygems/package'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'
require 'net/http'
require_relative 'bounded-process'

module ScenarioBootstrap
  RELEASE = '1.0.13'.freeze
  CORE_VERSION = '6.10.1'.freeze
  NAMES = %w[openc3-cosmos-cfs-scenario-runner openc3-cosmos-tool-scenariorunner].freeze
  REQUIRED = {
    NAMES[0] => 'targets/SCENARIO_RUNNER/procedures/run_scenario.py',
    NAMES[1] => 'tools/scenariorunner/main.js'
  }.freeze

  class Artifacts
    attr_reader :version, :paths, :file_hashes

    def initialize(directory:, version:, catalog:)
      raise Failure, 'Invalid Scenario release version' unless /\A\d+\.\d+\.\d+\z/.match?(version)
      @directory, @version, @catalog = directory, version, catalog
      @paths = NAMES.to_h { |name| [name, File.join(directory, "#{name}-#{version}.gem")] }
    end

    def verify!
      manifest = File.join(@directory, "manifest-#{version}.json")
      raise Failure, 'Scenario artifact manifest is missing; restore the shipped artifacts directory' unless File.file?(manifest)
      entries = JSON.parse(File.read(manifest))
      expected = paths.values.map { |path| File.basename(path) }.sort
      unless entries.is_a?(Array) && entries.size == 2 && entries.map { |e| e.fetch('file') }.sort == expected
        raise Failure, 'Manifest must identify exactly the two Scenario gems'
      end
      paths.each do |name, path|
        raise Failure, "Missing shipped artifact: #{File.basename(path)}" unless File.file?(path)
        sha = entries.find { |entry| entry['file'] == File.basename(path) }.fetch('sha256')
        raise Failure, "Artifact checksum mismatch: #{name}" unless sha == Digest::SHA256.file(path).hexdigest
        package = Gem::Package.new(path)
        package.verify
        raise Failure, 'Unexpected gem identity' unless package.spec.name == name && package.spec.version.to_s == version
        files = package.contents
        unless files.include?('plugin.txt') && files.include?(REQUIRED.fetch(name)) &&
               files.none? { |file| file.start_with?('/', '\\') || file.split(/[\\\/]/).include?('..') }
          raise Failure, "Incomplete or unsafe package: #{name}"
        end
      end
      @file_hashes = {}
      paths.each do |name, path|
        Dir.mktmpdir do |directory|
          Gem::Package.new(path).extract_files(directory)
          files = ['plugin.txt', REQUIRED.fetch(name)]
          files += %w[scenarios.json safety_policy.json].map { |f| "targets/SCENARIO_RUNNER/lib/#{f}" } if name == NAMES[0]
          @file_hashes[name] = files.to_h { |file| [file, Digest::SHA256.file(File.join(directory, file)).hexdigest] }
        end
      end
      Dir.mktmpdir do |directory|
        Gem::Package.new(paths.fetch(NAMES[0])).extract_files(directory)
        %w[scenarios.json safety_policy.json].each do |file|
          shipped = File.join(directory, 'targets/SCENARIO_RUNNER/lib', file)
          api = File.join(File.dirname(@catalog), file)
          raise Failure, 'API image and procedure catalog/policy differ; restore matching release artifacts' unless File.binread(shipped) == File.binread(api)
        end
      end
    end

    def ready_record(scope:)
      {
        'schema' => 1, 'version' => version, 'core_version' => CORE_VERSION, 'scope' => scope,
        'manifest_sha256' => Digest::SHA256.file(File.join(@directory, "manifest-#{version}.json")).hexdigest,
        'gems' => paths.transform_values { |path| Digest::SHA256.file(path).hexdigest },
        'catalog_sha256' => @file_hashes.fetch(NAMES[0]).fetch('targets/SCENARIO_RUNNER/lib/scenarios.json'),
        'policy_sha256' => @file_hashes.fetch(NAMES[0]).fetch('targets/SCENARIO_RUNNER/lib/safety_policy.json'),
        'procedure_sha256' => @file_hashes.fetch(NAMES[0]).fetch(REQUIRED.fetch(NAMES[0])),
        'ui_sha256' => @file_hashes.fetch(NAMES[1]).fetch(REQUIRED.fetch(NAMES[1]))
      }
    end
  end

  class DatabaseGuard
    def initialize(path)
      @path = path
    end

    def while_idle
      require 'sqlite3'
      # Use the API's own instance lock so an already-running API cannot start a
      # new run between this inspection and plugin installation.
      File.open("#{@path}.instance-lock", File::RDWR | File::CREAT, 0o600) do |lock|
        raise Failure, 'Scenario API is already running; stop it before installing missing plugins' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        if File.exist?(@path)
          begin
            db = SQLite3::Database.new(@path, readonly: true)
            db.busy_timeout = 2000
            raise Failure, 'Unknown Scenario database schema; installation refused' unless db.get_first_value('PRAGMA user_version') == 1
            busy = db.get_first_value('SELECT COUNT(*) FROM locks').positive? ||
                   db.get_first_value("SELECT COUNT(*) FROM runs WHERE state IS NULL OR state NOT IN ('succeeded','failed','stopped')").positive?
            raise Failure, 'Active or unknown Scenario runs exist; installation refused' if busy
          ensure
            db&.close
          end
        end
        yield
      end
    rescue SQLite3::Exception
      raise Failure, 'Scenario database cannot be verified; installation refused'
    end
  end

  class Backend
    def initialize(scope:)
      require 'openc3/models/plugin_model'
      require 'openc3/models/script_status_model'
      require 'openc3/models/target_model'
      require 'openc3/models/tool_model'
      require 'openc3/utilities/bucket'
      require 'openc3/utilities/target_file'
      @scope = scope
    end

    def names
      Timeout.timeout(10) { OpenC3::PluginModel.names(scope: @scope) }
    end

    def wait_ready!
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
      loop do
        begin
          names
          uri = URI('http://openc3-cosmos-script-runner-api:2902/script-api/ping')
          response = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 3) { |http| http.get(uri.path) }
          return if response.code == '200' && response.body.strip == 'OK'
        rescue StandardError
          # Bounded readiness retry; never echo backend exceptions or URLs.
        end
        raise Failure, 'Redis or Script Runner not ready after 120 seconds' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 2
      end
    end

    def assert_idle!
      rows = Timeout.timeout(10) { OpenC3::ScriptStatusModel.all(scope: @scope, type: 'running', offset: 0, limit: 1000) }
      if !rows.is_a?(Array) || !rows.empty?
        raise Failure, 'Active or unverifiable Script Runner records exist; installation refused'
      end
    end

    def complete?(name, version)
      Timeout.timeout(15) do
        path = File.join(ENV.fetch('GEM_HOME'), 'gems', "#{name}-#{version}", REQUIRED.fetch(name))
        return false unless File.file?(path)
        if name == NAMES[0]
          model = OpenC3::TargetModel.get(name: 'SCENARIO_RUNNER', scope: @scope)
        else
          model = OpenC3::ToolModel.get(name: 'Scenario Runner', scope: @scope)
          return false unless OpenC3::Bucket.getClient.check_object(bucket: ENV.fetch('OPENC3_TOOLS_BUCKET'), key: 'scenariorunner/main.js', retries: false)
        end
        matching = names.select { |item| item.start_with?("#{name}-") }
        model && matching.size == 1 && model['plugin'] == matching.first &&
          /\A#{Regexp.escape(name)}-#{Regexp.escape(version)}\.gem(?:__\d+)?\z/.match?(matching.first)
      end
    end

    def verify_release!(artifacts)
      Timeout.timeout(30) do
        artifacts.file_hashes.each do |name, hashes|
          raise Failure, "Installed plugin is incomplete: #{name}" unless complete?(name, artifacts.version)
          hashes.each do |relative, expected|
            path = File.join(ENV.fetch('GEM_HOME'), 'gems', "#{name}-#{artifacts.version}", relative)
            unless File.file?(path) && Digest::SHA256.file(path).hexdigest == expected
              raise Failure, "Installed plugin content mismatch: #{name}"
            end
            if relative.start_with?('targets/')
              body = OpenC3::TargetFile.body(@scope, relative.delete_prefix('targets/'))
            elsif relative == REQUIRED.fetch(NAMES[1])
              response = OpenC3::Bucket.getClient.get_object(bucket: ENV.fetch('OPENC3_TOOLS_BUCKET'), key: 'scenariorunner/main.js')
              body = response&.body&.read
            else
              next
            end
            unless body && Digest::SHA256.hexdigest(body) == expected
              raise Failure, 'Installed procedure/configuration differs from shipped release'
            end
          end
        end
      end
    end

    def install(path)
      ScenarioBootstrap.run_process(
        [RbConfig.ruby, '/openc3/bin/openc3cli', 'load', path, @scope, '--variables', File.join(__dir__, 'empty-variables.json')],
        seconds: 300,
        # Local mode would export definitions into /plugins. The Scenario job
        # changes only these two plugin records, never the source definitions.
        env: { 'OPENC3_LOCAL_MODE' => nil, 'BUNDLE_GEMFILE' => nil, 'RUBYOPT' => nil }
      )
    end
  end

  class Installer
    def initialize(artifacts:, backend:, guard:, state_directory:, output: $stdout, scope: 'DEFAULT', upgrade_from: nil)
      @artifacts, @backend, @guard, @output = artifacts, backend, guard, output
      @scope, @upgrade_from = scope, upgrade_from
      @marker = File.join(state_directory, '.scenario-install-incomplete')
      @lock_path = File.join(state_directory, '.scenario-install-lock')
      @ready = File.join(state_directory, 'scenario-installed.json')
    end

    def matching(installed, name, version)
      rows = installed.select { |item| item.start_with?("#{name}-") }
      expected = /\A#{Regexp.escape(name)}-#{Regexp.escape(version)}\.gem(?:__\d+)?\z/
      rows.size == 1 && expected.match?(rows.first)
    end

    def plan(installed)
      if @upgrade_from && (@upgrade_from != '1.0.12' || @artifacts.version != RELEASE)
        raise Failure, 'Only explicit SCENARIO_UPGRADE_FROM=1.0.12 to release 1.0.13 is supported; no downgrade is allowed'
      end
      if NAMES.all? { |name| matching(installed, name, @artifacts.version) }
        NAMES.each do |name|
          raise Failure, "Existing plugin is incomplete: #{name}; inspect it before retrying" unless @backend.complete?(name, @artifacts.version)
        end
        return :skip
      end
      existing = installed.select { |item| NAMES.any? { |name| item.start_with?("#{name}-") } }
      return :install if existing.empty? && !@upgrade_from
      if @upgrade_from && NAMES.all? { |name| matching(installed, name, @upgrade_from) && @backend.complete?(name, @upgrade_from) }
        return :upgrade
      end
      raise Failure, 'Automatic version changes, duplicate instances, partial or incomplete releases are refused; maintenance upgrade requires exactly the complete expected source release'
    end

    def write_ready!
      record = @artifacts.ready_record(scope: @scope)
      if File.file?(@ready)
        begin
          return if JSON.parse(File.read(@ready)) == record
        rescue JSON::ParserError
          # Verified installed content can repair an invalid ready record atomically.
        end
      end
      temporary = "#{@ready}.#{Process.pid}.tmp"
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(JSON.generate(record) + "\n")
          file.flush
          file.fsync
        end
        File.rename(temporary, @ready)
      ensure
        File.delete(temporary) if File.exist?(temporary)
      end
    end

    def run
      @artifacts.verify!
      File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        raise Failure, 'Another Scenario installer is running' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        raise Failure, 'Previous Scenario install was interrupted; inspect partial plugin state before removing /data/.scenario-install-incomplete' if File.exist?(@marker)
        @backend.wait_ready!
        operation = plan(@backend.names)
        if operation == :skip
          @backend.verify_release!(@artifacts)
          write_ready!
          NAMES.each { |name| @output.puts "SKIP #{name}-#{@artifacts.version}.gem (already installed)" }
        else
          @guard.while_idle do
            @backend.assert_idle!
            # Recheck under the API lock immediately before the first mutation.
            raise Failure, 'Installed release changed during preflight' unless plan(@backend.names) == operation
            File.open(@marker, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
              file.write(JSON.generate('operation' => operation, 'from' => @upgrade_from, 'to' => @artifacts.version) + "\n")
              file.flush
              file.fsync
            end
            # A failed multi-gem upgrade is nontransactional. Keep this marker and
            # the previous ready record until every installed component verifies.
            NAMES.each do |name|
              @backend.assert_idle!
              @output.puts "#{operation.to_s.upcase} #{name}-#{@artifacts.version}.gem"
              @backend.install(@artifacts.paths.fetch(name))
              unless matching(@backend.names, name, @artifacts.version) && @backend.complete?(name, @artifacts.version)
                raise Failure, "Plugin verification failed: #{name}; installation marker retained"
              end
            end
            @backend.verify_release!(@artifacts)
            write_ready!
            File.delete(@marker)
          end
        end
        @output.puts 'Scenario plugins ready; existing CFS plugins and definitions were not changed.'
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  %w[TERM INT].each { |signal| Signal.trap(signal) { raise ScenarioBootstrap::Failure, 'Installation interrupted; inspect retained marker before retrying' } }
  begin
    scope = ENV.fetch('SCENARIO_SCOPE', 'DEFAULT')
    raise ScenarioBootstrap::Failure, 'Invalid scope' unless /\A[A-Z0-9_-]+\z/.match?(scope)
    version = ENV.fetch('SCENARIO_VERSION', ScenarioBootstrap::RELEASE)
    raise ScenarioBootstrap::Failure, 'Init image release does not match SCENARIO_VERSION' unless version == ScenarioBootstrap::RELEASE
    db = ENV.fetch('SCENARIO_DB', '/data/scenario.sqlite3')
    artifacts = ScenarioBootstrap::Artifacts.new(directory: '/openc3/plugins/gems', version: version, catalog: '/openc3/scenario/catalog/scenarios.json')
    artifacts.verify!
    FileUtils.mkdir_p(File.dirname(db))
    ScenarioBootstrap::Installer.new(artifacts: artifacts, backend: ScenarioBootstrap::Backend.new(scope: scope), guard: ScenarioBootstrap::DatabaseGuard.new(db),
      state_directory: File.dirname(db), scope: scope, upgrade_from: ENV['SCENARIO_UPGRADE_FROM']).run
  rescue ScenarioBootstrap::Failure => error
    warn "Scenario installation stopped: #{error.message}"
    exit 1
  rescue StandardError => error
    warn "Scenario installation stopped (#{error.class}); check artifacts, service readiness and permissions. Backend details are suppressed."
    exit 1
  end
end

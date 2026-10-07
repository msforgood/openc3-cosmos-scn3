require 'json'
require 'rubygems/package'
require_relative 'bounded-process'

module ScenarioBootstrap
  # LocalMode.local_init runs inside core init and can ignore load failures.
  # Inspect its input before starting core, without loading OpenC3 or evaluating
  # plugin ERB. These are trusted operator exports, held stable during startup.
  class LocalModePreflight
    NAMES = %w[openc3-cosmos-cfs-scenario-runner openc3-cosmos-tool-scenariorunner].freeze
    RESERVED = /(?<![a-z0-9_])(?:SCENARIO_RUNNER|scenariorunner|openc3-cosmos-cfs-scenario-runner|openc3-cosmos-tool-scenariorunner)(?![a-z0-9_])/i
    MAX_ENTRIES = 10_000
    MAX_GEM_BYTES = 256 * 1024 * 1024
    MAX_TOTAL_BYTES = 1024 * 1024 * 1024
    MAX_JSON_BYTES = 4 * 1024 * 1024

    def initialize(env: ENV, max_entries: MAX_ENTRIES, max_bytes: MAX_TOTAL_BYTES)
      @env, @entries_left, @bytes_left = env, max_entries, max_bytes
    end

    def verify!
      # Ruby LocalMode treats any present value (including "false" and "") as enabled.
      return unless @env['OPENC3_LOCAL_MODE']

      root = @env['OPENC3_LOCAL_MODE_PATH'] || '/plugins'
      begin
        File.lstat(root)
      rescue Errno::ENOENT
        return # An absent root also disables core local_init.
      end
      # Follow links just as File.directory? in LocalMode does. Broken links,
      # unreadable inputs and other inspection errors must refuse, not look absent.
      raise Failure unless File.stat(root).directory?
      children(root) do |scope, scope_stat|
        next unless scope_stat.directory?
        children(scope) do |plugin, plugin_stat|
          next unless plugin_stat.directory?
          case File.basename(plugin)
          when 'targets_modified'
            children(plugin) do |target, _stat|
              raise Failure if File.basename(target).casecmp?('SCENARIO_RUNNER')
            end
          when 'tool_config', 'settings'
            next # Reserved non-plugin folders in LocalMode.local_init.
          else
            inspect_plugin(plugin)
          end
        end
      end
      true
    rescue StandardError
      # Never propagate filenames, JSON contents, gem metadata or OS diagnostics.
      raise Failure, 'Local-mode preflight refused conflicting or unreadable exports; core init was not started', cause: nil
    end

    private

    def children(directory)
      Dir.each_child(directory) do |name|
        @entries_left -= 1
        raise Failure if @entries_left.negative?
        path = File.join(directory, name)
        yield path, File.stat(path)
      end
    end

    def inspect_plugin(directory)
      # Match scan_plugin_dir's immediate children, including symlinked files.
      # Inspect every candidate conservatively, even if core would skip a
      # multiple-gem directory or an instance currently has no matching gem.
      children(directory) do |path, stat|
        next if stat.directory?
        if File.extname(path) == '.gem'
          charge_file(stat, MAX_GEM_BYTES)
          raise Failure if RESERVED.match?(File.basename(path))
          spec = Gem::Package.new(path).spec
          raise Failure if NAMES.include?(spec.name.downcase)
          raise Failure if spec.files.any? { |file| %r{\A(?:targets/SCENARIO_RUNNER|tools/scenariorunner)(?:/|\z)}i.match?(file) }
        elsif File.basename(path) == 'plugin_instance.json'
          charge_file(stat, MAX_JSON_BYTES)
          data = File.binread(path, MAX_JSON_BYTES + 1)
          raise Failure if data.bytesize > MAX_JSON_BYTES
          instance = JSON.parse(data, allow_nan: true, create_additions: false)
          raise Failure unless instance.is_a?(Hash)
          # Inspect decoded strings, including plugin_txt_lines, variables,
          # target/tool declarations and instance identity. Do not evaluate ERB.
          raise Failure if scenario_declaration?(instance)
        end
      end
    end

    def charge_file(stat, maximum)
      raise Failure unless stat.file? && stat.size <= maximum
      @bytes_left -= stat.size
      raise Failure if @bytes_left.negative?
    end

    def scenario_declaration?(value)
      case value
      when String then RESERVED.match?(value)
      when Array then value.any? { |item| scenario_declaration?(item) }
      when Hash then value.any? { |key, item| scenario_declaration?(key) || scenario_declaration?(item) }
      else false
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    ScenarioBootstrap::LocalModePreflight.new.verify!
  rescue StandardError
    warn 'Local-mode preflight refused conflicting or unreadable exports; core init was not started.'
    exit 1
  end
end

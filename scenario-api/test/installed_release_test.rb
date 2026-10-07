require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require_relative '../lib/scenario/installed_release'

class InstalledReleaseTest < Minitest::Test
  class Backend
    attr_accessor :names, :bodies, :plugins
    def initialize
      @names = Scenario::InstalledRelease::NAMES.map { |name| "#{name}-1.0.4.gem__0" }
      @plugins = Scenario::InstalledRelease::NAMES.zip(@names).to_h
      @bodies = {}
    end
    def plugin_for(name); @plugins[name]; end
    def body(path); @bodies[path]; end
    def ui_body; 'fixture'; end
  end

  def setup
    @directory = Dir.mktmpdir
    @backend = Backend.new
    @gem_home = File.join(@directory, 'gems')
    @catalog = File.join(@directory, 'scenarios.json')
    @record = { 'schema' => 1, 'version' => '1.0.4', 'core_version' => '6.10.1', 'scope' => 'DEFAULT',
                'manifest_sha256' => 'a' * 64, 'ui_sha256' => Digest::SHA256.hexdigest('fixture'),
                'gems' => Scenario::InstalledRelease::NAMES.to_h { |name| [name, 'b' * 64] } }
    Scenario::InstalledRelease::FILES.each do |key, (local, remote)|
      body = "fixture #{local}\n"
      File.write(File.join(@directory, local), body)
      @record[key] = Digest::SHA256.hexdigest(body)
      @backend.bodies[remote] = body
      installed = File.join(@gem_home, 'gems', 'openc3-cosmos-cfs-scenario-runner-1.0.4', 'targets', remote)
      FileUtils.mkdir_p(File.dirname(installed))
      File.write(installed, body)
    end
    ui = File.join(@gem_home, 'gems', 'openc3-cosmos-tool-scenariorunner-1.0.4', 'tools/scenariorunner/main.js')
    FileUtils.mkdir_p(File.dirname(ui))
    File.write(ui, 'fixture')
    @ready = File.join(@directory, 'scenario-installed.json')
    write_record
    @original_version = ENV['SCENARIO_VERSION']
    ENV['SCENARIO_VERSION'] = '1.0.4'
  end

  def teardown
    ENV['SCENARIO_VERSION'] = @original_version
    FileUtils.remove_entry(@directory)
  end

  def write_record; File.write(@ready, JSON.generate(@record)); end
  def verify
    Scenario::InstalledRelease.new(state_directory: @directory, catalog: @catalog,
                                   backend: @backend, gem_home: @gem_home).verify!
  end

  def test_matching_release_is_read_only
    original = File.stat(@ready).mtime
    assert verify
    assert_equal original, File.stat(@ready).mtime
    refute File.exist?(File.join(@directory, 'scenario.sqlite3'))
  end

  def test_missing_ready_record_refuses_startup
    File.delete(@ready)
    assert_raises(Scenario::InstalledRelease::Failure) { verify }
  end

  def test_incomplete_marker_overrides_old_ready_record
    File.write(File.join(@directory, '.scenario-install-incomplete'), 'in progress')
    assert_raises(Scenario::InstalledRelease::Failure) { verify }
  end

  def test_mixed_release_core_scope_or_hash_refuses_startup
    { 'version' => '1.0.3', 'core_version' => '6.9.0', 'scope' => 'OTHER', 'catalog_sha256' => 'c' * 64,
      'policy_sha256' => 'c' * 64, 'procedure_sha256' => 'c' * 64 }.each do |key, value|
      original = @record[key]
      @record[key] = value
      write_record
      assert_raises(Scenario::InstalledRelease::Failure) { verify }
      @record[key] = original
    end
  end

  def test_runtime_version_override_cannot_bless_mixed_images
    ENV['SCENARIO_VERSION'] = '1.0.3'
    @record['version'] = '1.0.3'
    write_record
    assert_raises(Scenario::InstalledRelease::Failure) { verify }
  end

  def test_missing_duplicate_or_stale_plugin_refuses_startup
    original = @backend.names.dup
    @backend.names.pop
    assert_raises(Scenario::InstalledRelease::Failure) { verify }
    @backend.names = original + [original.first.sub('__0', '__1')]
    assert_raises(Scenario::InstalledRelease::Failure) { verify }
    @backend.names = original
    @backend.plugins[Scenario::InstalledRelease::NAMES.first] = original.first.sub('__0', '__1')
    assert_raises(Scenario::InstalledRelease::Failure) { verify }
  end

  def test_remote_modified_procedure_or_configuration_refuses_startup
    @backend.bodies.keys.each do |key|
      original = @backend.bodies[key]
      @backend.bodies[key] = 'modified'
      assert_raises(Scenario::InstalledRelease::Failure) { verify }
      @backend.bodies[key] = original
    end
  end

  def test_local_installed_procedure_mismatch_refuses_startup
    path = File.join(@gem_home, 'gems/openc3-cosmos-cfs-scenario-runner-1.0.4/targets/SCENARIO_RUNNER/procedures/run_scenario.py')
    File.write(path, 'modified')
    assert_raises(Scenario::InstalledRelease::Failure) { verify }
  end

  def test_backend_errors_do_not_expose_credentials
    def @backend.names; raise 'secret-test-credential'; end
    error = assert_raises(Scenario::InstalledRelease::Failure) { verify }
    refute_includes error.message, 'secret-test-credential'
  end

  def test_modified_ui_object_refuses_startup
    def @backend.ui_body; 'modified'; end
    assert_raises(Scenario::InstalledRelease::Failure) { verify }
  end

  def test_plugin_storage_default_is_independent_of_ruby_dependency_gem_home
    original = ENV['GEM_HOME']
    ENV['GEM_HOME'] = '/system/ruby/gems'
    verifier = Scenario::InstalledRelease.new(state_directory: @directory, catalog: @catalog, backend: @backend)
    assert_equal '/gems', verifier.instance_variable_get(:@gem_home)
  ensure
    ENV['GEM_HOME'] = original
  end

  def test_runtime_refusal_precedes_database_open_and_releases_instance_lock
    File.delete(@ready)
    library = File.expand_path('../lib/scenario', __dir__)
    # Substitute only the external adapter import; the real runtime, verifier
    # and filesystem lock execute, with no service/network dependencies.
    code = <<~'RUBY'
      require 'fileutils'
      $LOADED_FEATURES << File.join(ARGV[0], 'openc3_adapter.rb')
      require File.join(ARGV[0], 'runtime.rb')
      module Scenario
        class Store
          def self.new(*)
            abort 'Store was opened before release verification'
          end
        end
      end
      begin
        Scenario::Runtime.start!
        abort 'Unverified runtime started'
      rescue Scenario::InstalledRelease::Failure
      end
      abort 'Database was created' if File.exist?(ENV.fetch('SCENARIO_DB'))
      abort 'Service became available' if Scenario::Runtime.service
      File.open("#{ENV.fetch('SCENARIO_DB')}.instance-lock", 'r+') do |lock|
        abort 'Instance lock leaked' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      end
    RUBY
    env = { 'SCENARIO_DB' => File.join(@directory, 'scenario.sqlite3'), 'SCENARIO_CATALOG' => @catalog }
    _, error, status = Open3.capture3(env, RbConfig.ruby, '-e', code, library)
    assert status.success?, error
  end
end

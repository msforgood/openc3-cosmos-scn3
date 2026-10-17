require 'minitest/autorun'
require_relative 'autoinstall'

class ScenarioInstallerPlanTest < Minitest::Test
  Artifacts = Struct.new(:version)

  class Backend
    attr_accessor :incomplete

    def initialize
      @incomplete = []
    end

    def complete?(name, version)
      !@incomplete.include?([name, version])
    end
  end

  def setup
    @backend = Backend.new
  end

  def installer(upgrade_from = nil)
    ScenarioBootstrap::Installer.new(
      artifacts: Artifacts.new('1.0.29'), backend: @backend, guard: nil,
      state_directory: '/unused', upgrade_from: upgrade_from
    )
  end

  def installed(version, suffix = '')
    ScenarioBootstrap::NAMES.map { |name| "#{name}-#{version}.gem#{suffix}" }
  end

  def test_fresh_install_and_current_release
    assert_equal :install, installer.plan([])
    assert_equal :skip, installer.plan(installed('1.0.29'))
    assert_raises(ScenarioBootstrap::Failure) { installer('1.0.13').plan([]) }
  end

  def test_all_supported_prior_releases_upgrade_without_a_version_hint
    %w[1.0.8 1.0.9 1.0.10 1.0.11 1.0.12 1.0.13 1.0.14 1.0.15 1.0.16 1.0.17 1.0.18 1.0.19 1.0.20 1.0.21 1.0.22 1.0.23 1.0.24 1.0.25 1.0.26 1.0.27 1.0.28].each do |version|
      assert_equal :upgrade, installer.plan(installed(version, '__2')), version
      assert_equal :upgrade, installer(version).plan(installed(version)), version
    end
  end

  def test_explicit_version_hint_must_match_the_detected_release
    error = assert_raises(ScenarioBootstrap::Failure) do
      installer('1.0.12').plan(installed('1.0.13'))
    end
    assert_match(/does not match/, error.message)
    assert_raises(ScenarioBootstrap::Failure) { installer('1.0.7').plan(installed('1.0.13')) }
  end

  def test_unsupported_releases_and_downgrade_are_refused
    %w[1.0.7 1.0.30 2.0.0].each do |version|
      assert_raises(ScenarioBootstrap::Failure) { installer.plan(installed(version)) }
    end
  end

  def test_mixed_duplicate_and_partial_releases_are_refused
    assert_raises(ScenarioBootstrap::Failure) do
      installer.plan([installed('1.0.12').first, installed('1.0.13').last])
    end
    assert_raises(ScenarioBootstrap::Failure) do
      installer.plan(installed('1.0.13') + [installed('1.0.13', '__1').first])
    end
    assert_raises(ScenarioBootstrap::Failure) { installer.plan([installed('1.0.13').first]) }
  end

  def test_incomplete_old_or_current_plugin_is_refused
    @backend.incomplete = [[ScenarioBootstrap::NAMES.first, '1.0.13']]
    assert_raises(ScenarioBootstrap::Failure) { installer.plan(installed('1.0.13')) }
    @backend.incomplete = [[ScenarioBootstrap::NAMES.first, '1.0.29']]
    assert_raises(ScenarioBootstrap::Failure) { installer.plan(installed('1.0.29')) }
  end
end

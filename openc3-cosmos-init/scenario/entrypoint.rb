require 'rbconfig'
require_relative 'bounded-process'

module ScenarioBootstrap
  # Teardown deliberately runs after installation so Istio remains available.
  def self.initialize_image(runner: method(:run_process), output: $stdout)
    output.puts 'Local-mode preflight: checking for conflicting Scenario exports (maximum 30 seconds).'
    runner.call([RbConfig.ruby, File.expand_path('local-mode-preflight.rb', __dir__)], seconds: 30,
                env: { 'BUNDLE_GEMFILE' => nil, 'RUBYOPT' => nil })
    output.puts 'Core init: preparing OpenC3 buckets and stock tools (maximum 900 seconds).'
    runner.call(['/bin/sh', '/openc3/init.sh'], seconds: 900, env: { 'SCENARIO_INIT_PHASE' => 'core' })
    output.puts 'Core init complete; guarded Scenario installation (maximum 900 seconds).'
    runner.call([RbConfig.ruby, '/openc3/scenario/autoinstall.rb'], seconds: 900, termination_grace: 1,
                env: { 'SCENARIO_INIT_PHASE' => nil, 'BUNDLE_GEMFILE' => nil, 'RUBYOPT' => nil, 'OPENC3_LOCAL_MODE' => nil })
    output.puts 'Scenario installation complete; finishing init.'
    runner.call(['/bin/sh', '/openc3/init.sh'], seconds: 60, env: { 'SCENARIO_INIT_PHASE' => 'teardown' })
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  %w[TERM INT].each { |signal| Signal.trap(signal) { raise ScenarioBootstrap::Failure, 'Init interrupted' } }
  begin
    ScenarioBootstrap.initialize_image
  rescue StandardError => error
    warn "Guarded init failed (#{error.class}); Scenario API remains blocked. Check packaged artifacts, service readiness and installation marker. Child output is suppressed."
    exit 1
  end
end

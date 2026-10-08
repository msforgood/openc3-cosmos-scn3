Gem::Specification.new do |spec|
  spec.name = 'openc3-cosmos-cfs-scenario-runner'
  spec.version = ENV.fetch('VERSION', '1.0.12')
  spec.summary = 'Bounded QEMU housekeeping scenarios for OpenC3 6.10.1'
  spec.description = 'Independent procedure-only plugin using existing CFS command and telemetry APIs.'
  spec.authors = ['CFS Scenario Runner maintainers']
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0'
  spec.files = Dir.glob('{lib,targets}/**/*').select { |path| File.file?(path) && !path.include?('__pycache__') } + %w[plugin.txt README.md LICENSE.txt]
end

# Verify the two Scenario gems before writing the installer checksum manifest.
require 'json'
require 'digest'
require 'rubygems/package'
require 'tmpdir'

version, artifacts, catalog = ARGV
abort 'Expected VERSION ARTIFACT_DIRECTORY CATALOG_DIRECTORY' unless catalog && /\A\d+\.\d+\.\d+\z/.match?(version)
required = {
  'openc3-cosmos-cfs-scenario-runner' => 'targets/SCENARIO_RUNNER/procedures/run_scenario.py',
  'openc3-cosmos-tool-scenariorunner' => 'tools/scenariorunner/main.js'
}
entries = required.map do |name, payload|
  filename = "#{name}-#{version}.gem"
  path = File.join(artifacts, filename)
  package = Gem::Package.new(path)
  package.verify
  abort "Unexpected gem identity: #{filename}" unless package.spec.name == name && package.spec.version.to_s == version
  files = package.contents
  abort "Missing payload: #{filename}" unless [payload, 'plugin.txt', 'LICENSE.txt'].all? { |file| files.include?(file) }
  abort "Unsafe gem path: #{filename}" if files.any? { |file| file.start_with?('/', '\\') || file.split(/[\\\/]/).include?('..') }
  if name == 'openc3-cosmos-cfs-scenario-runner'
    Dir.mktmpdir do |directory|
      package.extract_files(directory)
      %w[scenarios.json safety_policy.json].each do |file|
        packaged = File.join(directory, 'targets/SCENARIO_RUNNER/lib', file)
        abort "Catalog mismatch: #{file}" unless File.binread(packaged) == File.binread(File.join(catalog, file))
      end
    end
  end
  { 'file' => filename, 'sha256' => Digest::SHA256.file(path).hexdigest }
end
File.write(File.join(artifacts, "manifest-#{version}.json"), JSON.pretty_generate(entries) + "\n")

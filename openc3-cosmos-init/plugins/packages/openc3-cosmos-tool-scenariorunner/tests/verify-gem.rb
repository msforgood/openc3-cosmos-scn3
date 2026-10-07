require 'rubygems/package'
require 'tmpdir'
require 'digest'
require 'json'

path = ARGV.fetch(0, 'openc3-cosmos-tool-scenariorunner-1.0.0.gem')
package = Gem::Package.new(path)
package.verify
raise 'Unexpected gem identity' unless package.spec.name == 'openc3-cosmos-tool-scenariorunner' && package.spec.version.to_s == '1.0.0'
required = %w[plugin.txt LICENSE.txt NOTICE.md README.md src/main.js src/ScenarioRunner.vue src/TelemetryPanel.vue src/passiveScreen.js tools/scenariorunner/main.js package-lock.json]
missing = required - package.contents
raise "Missing files: #{missing.join(', ')}" unless missing.empty?
assets = package.contents.grep(%r{\Atools/scenariorunner/.+\.js\z})
raise 'Missing widget chunks' unless assets.length > 10
Dir.mktmpdir('scenario-gem-verify') do |directory|
  package.extract_files(directory)
  assets.each do |asset|
    raise "Asset mismatch #{asset}" unless Digest::SHA256.file(asset).hexdigest == Digest::SHA256.file(File.join(directory, asset)).hexdigest
  end
end
result = { verified: true, name: package.spec.name, version: package.spec.version.to_s, files: package.contents.length,
           javascript_assets: assets.length, bytes: File.size(path), sha256: Digest::SHA256.file(path).hexdigest }
File.write('evidence/gem-result.json', JSON.pretty_generate(result))
puts JSON.pretty_generate(result)

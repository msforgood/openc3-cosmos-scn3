# encoding: ascii-8bit
# OpenC3 tool packaging convention derived from OpenC3 6.10.1.
# Copyright 2022 Ball Aerospace & Technologies Corp.
# Modified by OpenC3, Inc.; Copyright 2025 OpenC3, Inc.
# AGPL version 3 with attribution addendums; see LICENSE.txt.

Gem::Specification.new do |s|
  s.name = 'openc3-cosmos-tool-scenariorunner'
  s.version = ENV.fetch('VERSION', '1.0.14')
  s.summary = 'OpenC3 COSMOS Scenario Runner Tool'
  s.description = 'Independent fixed-scenario runner with selected-target telemetry and read-only limits events for OpenC3 6.10.1.'
  s.authors = ['Scenario Runner contributors']
  s.homepage = 'https://openc3.com'
  s.platform = Gem::Platform::RUBY
  s.required_ruby_version = '>= 3.0'
  s.licenses = ['AGPL-3.0-only', 'Nonstandard']
  s.files = Dir.glob('{tools,src,tests}/**/*').select { |path| File.file?(path) } +
    %w[Rakefile LICENSE.txt NOTICE.md README.md plugin.txt package.json vite.config.js]
end

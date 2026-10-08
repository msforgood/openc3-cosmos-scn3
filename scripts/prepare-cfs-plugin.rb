# Back up only the cFS plugin and prepare an explicit in-place upgrade.
require 'json'
require 'fileutils'
require 'openc3/models/plugin_model'
require 'openc3/models/gem_model'

gem_path, variables_path, backup_dir = ARGV
raise 'Expected gem, variables, backup directory' unless backup_dir
FileUtils.mkdir_p(backup_dir)
existing = OpenC3::PluginModel.all(scope: 'DEFAULT').select { |name, _| /\Aopenc3-cosmos-cfs-\d/.match?(name) }
raise 'Multiple cFS installations found; select one explicitly before updating' if existing.length > 1
variables = JSON.parse(File.read(variables_path))
prepared = OpenC3::PluginModel.install_phase1(gem_path, existing_variables: variables, scope: 'DEFAULT', validate_only: true)
if existing.any?
  old_name, old_config = existing.first
  File.write(File.join(backup_dir, 'previous-plugin.json'), JSON.pretty_generate(old_config))
  old_gem_path = OpenC3::GemModel.get(old_name.split('__').first)
  FileUtils.cp(old_gem_path, File.join(backup_dir, File.basename(old_gem_path)))
  # The CLI requires the OLD name to select the installation to replace.
  prepared['name'] = old_name
end
File.write(File.join(backup_dir, 'install.json'), JSON.pretty_generate(prepared))
puts "Prepared cFS plugin update; backup: #{backup_dir}"

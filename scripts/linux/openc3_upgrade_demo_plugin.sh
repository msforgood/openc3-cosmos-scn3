#!/bin/sh
# Upgrade the installed openc3-cosmos-demo plugin in place with the gem built into the
# current init image (same as Admin > Plugins > Upgrade). The existing plugin instance
# name and variables are kept.
#
# init only upgrades a plugin when its version changes, so use this after changing the
# demo plugin source without bumping the version:
#   ./openc3.sh start            # builds the init image with the new demo gem
#   ./scripts/linux/openc3_upgrade_demo_plugin.sh
set -e
cd "$(dirname -- "$0")/../.."

if docker info 2>/dev/null | grep -q -e "rootless$" -e "rootless: true"; then
  export OPENC3_USER_ID=0 OPENC3_GROUP_ID=0
else
  export OPENC3_USER_ID=$(id -u) OPENC3_GROUP_ID=$(id -g)
fi

docker compose -f compose.yaml run --rm --no-deps --entrypoint /bin/sh openc3-cosmos-init -c '
set -e
GEM=$(ls /openc3/plugins/gems/openc3-cosmos-demo-*.gem)
cd /tmp
ruby -ropenc3 -ropenc3/models/plugin_model -rjson -e "
existing_name = OpenC3::PluginModel.names(scope: %q(DEFAULT)).find { |n| n.start_with?(%q(openc3-cosmos-demo-)) }
abort(%q(demo plugin not installed)) unless existing_name
existing = OpenC3::PluginModel.get(name: existing_name, scope: %q(DEFAULT))
hash = OpenC3::PluginModel.install_phase1(ARGV[0], existing_variables: existing[%q(variables)], scope: %q(DEFAULT))
hash[%q(name)] = existing_name
File.write(%q(/tmp/plugin_hash.json), JSON.generate(hash, allow_nan: true))
puts %Q(Upgrading #{existing_name})
" "$GEM"
# force: the version is unchanged so openc3cli would otherwise skip the upgrade
ruby /openc3/bin/openc3cli load "$GEM" DEFAULT /tmp/plugin_hash.json force
'

#!/bin/sh
# Install (or upgrade) the cFS communications plugin openc3-cosmos-cfs-<version>.gem
# following docs/tc-log-photo-traversal.md / docs/psp-mm-indirect-write.md:
#   1. scripts/prepare-cfs-plugin.rb backs up any existing cFS plugin (gem + config)
#      and prepares install.json from the plugin variables
#   2. openc3cli load installs the gem from the init service (writable /gems)
#
# Usage:
#   ./scripts/linux/openc3_install_cfs_plugin.sh path/to/openc3-cosmos-cfs-<version>.gem [variables.json]
# The variables default to cfs-plugin-variables.json (QEMU qemu-cfs / BBB 192.168.7.2).
# Set FORCE=1 to reinstall a gem with the same version as the installed one.
set -e
cd "$(dirname -- "$0")/../.."

GEM=${1:?"usage: $0 path/to/openc3-cosmos-cfs-<version>.gem [variables.json]"}
VARIABLES=${2:-cfs-plugin-variables.json}
[ -f "$GEM" ] || { echo "gem not found: $GEM" >&2; exit 1; }
[ -f "$VARIABLES" ] || { echo "variables not found: $VARIABLES" >&2; exit 1; }
case "$(basename "$GEM")" in
  openc3-cosmos-cfs-scenario-runner-*) echo "This is the Scenario Runner gem, not the cFS communications plugin" >&2; exit 1 ;;
  openc3-cosmos-cfs-*.gem) ;;
  *) echo "Expected openc3-cosmos-cfs-<version>.gem: $GEM" >&2; exit 1 ;;
esac

if docker info 2>/dev/null | grep -q -e "rootless$" -e "rootless: true"; then
  export OPENC3_USER_ID=0 OPENC3_GROUP_ID=0
else
  export OPENC3_USER_ID=$(id -u) OPENC3_GROUP_ID=$(id -g)
fi

GEM_NAME=$(basename "$GEM")
BACKUP_DIR="backups/cfs-plugin-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
FORCE_ARG=""
[ "${FORCE:-0}" = "1" ] && FORCE_ARG="force"

echo "Installing $GEM_NAME with $VARIABLES (backup: $BACKUP_DIR)"
docker compose -f compose.yaml run --rm --no-deps \
  -v "$(realpath "$GEM"):/tmp/cfs/$GEM_NAME:ro" \
  -v "$(realpath "$VARIABLES"):/tmp/cfs/variables.json:ro" \
  -v "$(realpath scripts/prepare-cfs-plugin.rb):/tmp/cfs/prepare-cfs-plugin.rb:ro" \
  -v "$(realpath "$BACKUP_DIR"):/tmp/cfs/backup" \
  --entrypoint /bin/sh openc3-cosmos-init -c "
set -e
cd /tmp
ruby -ropenc3 /tmp/cfs/prepare-cfs-plugin.rb /tmp/cfs/$GEM_NAME /tmp/cfs/variables.json /tmp/cfs/backup
ruby /openc3/bin/openc3cli load /tmp/cfs/$GEM_NAME DEFAULT /tmp/cfs/backup/install.json $FORCE_ARG
"
echo "Done. Check Admin > Plugins and CmdTlmServer > Interfaces for the cFS targets."

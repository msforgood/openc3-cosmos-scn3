#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
container="${OPENC3_OPERATOR_CONTAINER:-openc3-openc3-operator-1}"

if [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)" != true ]]; then
  printf 'OpenC3 operator container is not running: %s\n' "$container" >&2
  printf 'Set OPENC3_OPERATOR_CONTAINER if your Compose project uses another name.\n' >&2
  exit 1
fi

docker cp "$script_dir/scenario4_demo.rb" "$container:/tmp/scenario4_demo.rb" >/dev/null
docker exec "$container" ruby /tmp/scenario4_demo.rb "$@"

#!/bin/sh
set -eu

PLUGINS="/openc3/plugins"
GEMS="${PLUGINS}/gems"
OPENC3_RELEASE_VERSION=6.10.1

# Optional second argument overrides the build folder; third overrides version.
FOLDER_NAME=${2:-${PLUGINS}/packages/${1}}
RELEASE_VERSION=${3:-${OPENC3_RELEASE_VERSION}}

mkdir -p "${GEMS}"
echo "<<< packageBuild $1 ${RELEASE_VERSION}"
cd "${FOLDER_NAME}"
pnpm run build
rake build VERSION="${RELEASE_VERSION}"

# Verify the exact artifact so an old gem cannot mask a failed build.
ARTIFACT="${1}-${RELEASE_VERSION}.gem"
ruby -rrubygems/package -e 'package = Gem::Package.new(ARGV[0]); package.verify; abort "Unexpected gem identity" unless package.spec.name == ARGV[1] && package.spec.version.to_s == ARGV[2]' "${ARTIFACT}" "$1" "${RELEASE_VERSION}"
mv "${ARTIFACT}" "${GEMS}/"
echo "=== packageBuild $1 ${RELEASE_VERSION} complete"

#!/bin/bash
set -euo pipefail

BUILD_VERSION="${1:-1}"

# Resolve the latest commit SHA of the upstream `tip` rolling tag.
GHOSTTY_SHA=$(curl -sSf "https://api.github.com/repos/ghostty-org/ghostty/commits/tip" \
  | grep -oP '"sha": "\K[^"]+' | head -n 1 | cut -c 1-8)

# Build date in UTC — monotonic disambiguator so each weekly build sorts strictly
# newer than the previous one (reprepro / apt use dpkg version compare semantics).
BUILD_DATE=$(date -u +%Y%m%d)

if [ -z "$GHOSTTY_SHA" ]; then
  echo "Could not resolve upstream 'tip' tag" >&2
  exit 1
fi

# Upstream app version at that commit — keeps every derived string tracking upstream.
APP_VERSION=$(curl -sSf "https://raw.githubusercontent.com/ghostty-org/ghostty/${GHOSTTY_SHA}/build.zig.zon" \
  | grep -oP '\.version\s*=\s*"\K[^"]+')

if [ -z "$APP_VERSION" ]; then
  echo "Could not resolve upstream app version from build.zig.zon" >&2
  exit 1
fi

# SemVer string for -Dversion-string (upstream validates via std.SemanticVersion).
#   APP=1.3.2-dev, BUILD_DATE=20260418  →  1.3.2-dev+20260418
ZIG_VERSION_STRING="${APP_VERSION}+${BUILD_DATE}"

# Debian-compatible upstream version: must start with a digit; `-` is reserved for
# the debian_revision separator. Translate SemVer "-dev" to Debian "~dev.<YYYYMMDD>"
# — tilde sorts BEFORE everything (tip < corresponding stable), and the date is
# monotonic so each weekly build is strictly newer than the previous one.
#   APP=1.3.2-dev, BUILD_DATE=20260418  →  1.3.2~dev.20260418
if [[ "$APP_VERSION" == *-* ]]; then
  UPSTREAM_VERSION="${APP_VERSION%%-*}~${APP_VERSION#*-}.${BUILD_DATE}"
else
  UPSTREAM_VERSION="${APP_VERSION}~tip.${BUILD_DATE}"
fi

echo "Building ghostty tip @ ${GHOSTTY_SHA} (build date ${BUILD_DATE})"
echo "  upstream app version : ${APP_VERSION}"
echo "  zig  -Dversion-string: ${ZIG_VERSION_STRING}"
echo "  debian upstream      : ${UPSTREAM_VERSION}"

# Shell-sourceable record of everything resolved at build time. CI / release
# tooling can `source ghostty-tip.version` to read these values.
cat > ghostty-tip.version <<EOF
GHOSTTY_SHA=${GHOSTTY_SHA}
BUILD_DATE=${BUILD_DATE}
APP_VERSION=${APP_VERSION}
UPSTREAM_VERSION=${UPSTREAM_VERSION}
ZIG_VERSION_STRING=${ZIG_VERSION_STRING}
EOF

declare -a arr=("trixie" "forky" "sid")
declare -a pkgs=("ghostty-tip" "libghostty-vt0-tip" "libghostty-vt-dev-tip")
for i in "${arr[@]}"
do
  DEBIAN_DIST=$i
  FULL_VERSION=${UPSTREAM_VERSION}-${BUILD_VERSION}+${DEBIAN_DIST}_amd64
  docker build . -t ghostty-$DEBIAN_DIST \
    --build-arg GHOSTTY_SHA=$GHOSTTY_SHA \
    --build-arg UPSTREAM_VERSION=$UPSTREAM_VERSION \
    --build-arg ZIG_VERSION_STRING=$ZIG_VERSION_STRING \
    --build-arg DEBIAN_DIST=$DEBIAN_DIST \
    --build-arg BUILD_VERSION=$BUILD_VERSION \
    --build-arg FULL_VERSION=$FULL_VERSION
  id="$(docker create ghostty-$DEBIAN_DIST)"
  for pkg in "${pkgs[@]}"; do
    docker cp "$id:/${pkg}_${FULL_VERSION}.deb" "./${pkg}_${FULL_VERSION}.deb"
  done
  docker rm "$id" >/dev/null
done

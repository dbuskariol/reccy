#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${RECCY_DERIVED_DATA:-$ROOT_DIR/.build/ReleaseDerivedData}"
UPDATES_DIR="$ROOT_DIR/dist/updates"
GENERATE_APPCAST="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
REPOSITORY="${RECCY_GITHUB_REPOSITORY:-dbuskariol/reccy}"
DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/latest/download/"

if [[ ! -x "$GENERATE_APPCAST" ]]; then
  /usr/bin/xcodebuild \
    -project "$ROOT_DIR/Reccy.xcodeproj" \
    -scheme Reccy \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -resolvePackageDependencies
fi
[[ -x "$GENERATE_APPCAST" ]] || {
  printf 'Sparkle generate_appcast was not resolved at %s\n' "$GENERATE_APPCAST" >&2
  exit 1
}

if [[ ! -d "$UPDATES_DIR" || -z "$(/usr/bin/find "$UPDATES_DIR" -maxdepth 1 -name 'Reccy-*.zip' -print -quit)" ]]; then
  "$ROOT_DIR/Scripts/package-update.sh"
fi

SIGNING_ARGS=(--account "${RECCY_SPARKLE_KEY_ACCOUNT:-ed25519}")
if [[ -n "${RECCY_SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  SIGNING_ARGS=(--ed-key-file "$RECCY_SPARKLE_PRIVATE_KEY_FILE")
fi

"$GENERATE_APPCAST" \
  "${SIGNING_ARGS[@]}" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --release-notes-url-prefix "$DOWNLOAD_PREFIX" \
  --maximum-versions 5 \
  --maximum-deltas 4 \
  --delta-compression lzfse \
  --phased-rollout-interval "${RECCY_PHASED_ROLLOUT_INTERVAL:-86400}" \
  --auto-prune-update-files \
  "$UPDATES_DIR"

printf 'Generated %s/appcast.xml\n' "$UPDATES_DIR"

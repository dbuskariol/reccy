#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/reccy-release.sh"

DERIVED_DATA="${RECCY_DERIVED_DATA:-$(reccy_default_derived_data Release)}"
UPDATES_DIR="$ROOT_DIR/dist/updates"
APP="$ROOT_DIR/dist/Reccy.app"
REPOSITORY="$RECCY_EXPECTED_GITHUB_REPOSITORY"
DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/latest/download/"

[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || reccy_fail "invalid GitHub repository: $REPOSITORY"
reccy_assert_release_app "$APP" "${RECCY_DEVELOPMENT_TEAM:-}"
if [[ "${RECCY_ALLOW_UNNOTARIZED_PACKAGE:-0}" != "1" ]]; then
  reccy_assert_notarized_app "$APP"
fi
GENERATE_APPCAST="$(reccy_resolve_sparkle_tool "$ROOT_DIR" "$DERIVED_DATA" generate_appcast)"
reccy_assert_sparkle_signing_key "$ROOT_DIR" "$APP" "$DERIVED_DATA"

if [[ ! -d "$UPDATES_DIR" || -z "$(/usr/bin/find "$UPDATES_DIR" -maxdepth 1 -name 'Reccy-*.zip' -print -quit)" ]]; then
  "$ROOT_DIR/scripts/package-update.sh"
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

reccy_note "Generated $UPDATES_DIR/appcast.xml"

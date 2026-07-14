#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/reccy-release.sh"

MODE="${1:-prepare}"
case "$MODE" in
  prepare|finalize) ;;
  *)
    printf 'Usage: Scripts/release.sh [prepare|finalize]\n' >&2
    exit 64
    ;;
esac

if [[ "$MODE" == "finalize" ]]; then
  [[ "${RECCY_ALLOW_DIRTY:-0}" != "1" ]] \
    || reccy_fail 'final releases can never be built from a dirty worktree'
  export RECCY_REQUIRE_RELEASE_TAG=1
fi

reccy_assert_clean_worktree "$ROOT_DIR"
IFS=$'\t' read -r VERSION BUILD < <(reccy_assert_release_metadata "$ROOT_DIR")
reccy_note "Preparing Reccy $VERSION ($BUILD) in $MODE mode"

"$ROOT_DIR/Scripts/build-release.sh"

if [[ "$MODE" == "prepare" ]]; then
  RECCY_NOTARY_PREPARE_ONLY=1 "$ROOT_DIR/Scripts/notarize-release.sh"
  reccy_note 'Release rehearsal passed; no Apple service or publishing state was changed'
  exit 0
fi

"$ROOT_DIR/Scripts/notarize-release.sh"
"$ROOT_DIR/Scripts/create-release-manifest.sh"

reccy_note "Reccy $VERSION ($BUILD) is signed, notarized, stapled, Sparkle-signed, and ready to publish"

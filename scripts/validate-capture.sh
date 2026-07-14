#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/recording.mp4 | --self-test" >&2
  exit 64
fi

exec /usr/bin/xcrun swift "$ROOT_DIR/scripts/validate-capture.swift" "$1"

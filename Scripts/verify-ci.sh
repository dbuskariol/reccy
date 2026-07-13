#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${RECCY_CI_DERIVED_DATA:-$ROOT_DIR/.build/CIDerivedData}"

for script in "$ROOT_DIR"/Scripts/*.sh; do
  /bin/bash -n "$script"
done
/usr/bin/plutil -lint "$ROOT_DIR/Configuration/Reccy-Info.plist" >/dev/null
/usr/bin/xcodebuild \
  -project "$ROOT_DIR/Reccy.xcodeproj" \
  -scheme Reccy \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  test
/usr/bin/xcodebuild \
  -project "$ROOT_DIR/Reccy.xcodeproj" \
  -scheme Reccy \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CLANG_ENABLE_CODE_COVERAGE=NO \
  GCC_GENERATE_TEST_COVERAGE_FILES=NO \
  GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO \
  build

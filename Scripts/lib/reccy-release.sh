#!/usr/bin/env bash

# Shared, fail-closed release invariants. Every script that can create a
# distributable Reccy artifact sources this file so local and CI releases are
# held to the same standard.

if [[ -n "${RECCY_RELEASE_LIB_LOADED:-}" ]]; then
  return 0
fi
readonly RECCY_RELEASE_LIB_LOADED=1

readonly RECCY_EXPECTED_BUNDLE_ID="com.reccy.mac"
readonly RECCY_EXPECTED_MINIMUM_SYSTEM="26.0"
readonly RECCY_EXPECTED_ARCHITECTURES=(arm64 x86_64)

reccy_fail() {
  printf 'Reccy release error: %s\n' "$1" >&2
  exit 1
}

reccy_note() {
  printf '==> %s\n' "$1"
}

reccy_require_tool() {
  /usr/bin/command -v "$1" >/dev/null 2>&1 || reccy_fail "required tool is unavailable: $1"
}

reccy_plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true
}

reccy_codesign_details() {
  /usr/bin/codesign -dvvv --verbose=4 "$1" 2>&1
}

reccy_signature_team() {
  /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$(reccy_codesign_details "$1")"
}

reccy_find_developer_id_identity() {
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F\" '/Developer ID Application/ { print $2; exit }'
}

reccy_assert_clean_worktree() {
  local root="$1"
  if [[ "${RECCY_ALLOW_DIRTY:-0}" == "1" ]]; then
    return 0
  fi
  [[ -z "$(/usr/bin/git -C "$root" status --porcelain --untracked-files=normal)" ]] \
    || reccy_fail 'the worktree is dirty; commit the verified release source first (or set RECCY_ALLOW_DIRTY=1 for a non-shipping rehearsal)'
}

reccy_assert_release_metadata() {
  local root="$1"
  local settings version build notes_heading tag
  settings="$(/usr/bin/xcodebuild \
    -project "$root/Reccy.xcodeproj" \
    -scheme Reccy \
    -configuration Release \
    -showBuildSettings 2>/dev/null)"
  version="$(/usr/bin/awk '/MARKETING_VERSION =/{print $3; exit}' <<<"$settings")"
  build="$(/usr/bin/awk '/CURRENT_PROJECT_VERSION =/{print $3; exit}' <<<"$settings")"

  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] \
    || reccy_fail "MARKETING_VERSION is not a release version: ${version:-missing}"
  [[ "$build" =~ ^[1-9][0-9]*$ ]] \
    || reccy_fail "CURRENT_PROJECT_VERSION must be a positive integer: ${build:-missing}"

  notes_heading="$(/usr/bin/sed -n '1p' "$root/Documentation/RELEASE_NOTES.md" 2>/dev/null || true)"
  [[ "$notes_heading" == "# Reccy $version" ]] \
    || reccy_fail "release notes must start with '# Reccy $version'"

  tag="${RECCY_RELEASE_TAG:-}"
  if [[ -z "$tag" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    tag="${GITHUB_REF_NAME:-}"
  fi
  if [[ -z "$tag" ]]; then
    tag="$(/usr/bin/git -C "$root" describe --tags --exact-match 2>/dev/null || true)"
  fi
  if [[ -n "$tag" ]]; then
    [[ "$tag" == "v$version" ]] \
      || reccy_fail "release tag $tag does not match MARKETING_VERSION $version"
  elif [[ "${RECCY_REQUIRE_RELEASE_TAG:-0}" == "1" ]]; then
    reccy_fail "a v$version release tag is required"
  fi

  printf '%s\t%s\n' "$version" "$build"
}

reccy_assert_release_app() {
  local app="$1"
  local expected_team="${2:-}"
  local info executable bundle_id minimum_system version build architectures signing_details team entitlements

  [[ -d "$app" ]] || reccy_fail "app bundle not found: $app"
  info="$app/Contents/Info.plist"
  [[ -f "$info" ]] || reccy_fail "Info.plist is missing from $app"
  /usr/bin/plutil -lint "$info" >/dev/null || reccy_fail 'Info.plist is invalid'

  bundle_id="$(reccy_plist_value CFBundleIdentifier "$info")"
  minimum_system="$(reccy_plist_value LSMinimumSystemVersion "$info")"
  version="$(reccy_plist_value CFBundleShortVersionString "$info")"
  build="$(reccy_plist_value CFBundleVersion "$info")"
  executable="$app/Contents/MacOS/$(reccy_plist_value CFBundleExecutable "$info")"

  [[ "$bundle_id" == "$RECCY_EXPECTED_BUNDLE_ID" ]] \
    || reccy_fail "unexpected bundle identifier: ${bundle_id:-missing}"
  [[ "$minimum_system" == "$RECCY_EXPECTED_MINIMUM_SYSTEM" ]] \
    || reccy_fail "minimum system must be macOS $RECCY_EXPECTED_MINIMUM_SYSTEM"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] \
    || reccy_fail "invalid app version: ${version:-missing}"
  [[ "$build" =~ ^[1-9][0-9]*$ ]] \
    || reccy_fail "invalid app build: ${build:-missing}"
  [[ -x "$executable" ]] || reccy_fail "main executable is missing: $executable"

  /usr/bin/codesign --verify --strict --deep --verbose=2 "$app" \
    || reccy_fail 'the app signature is invalid'
  signing_details="$(reccy_codesign_details "$app")"
  /usr/bin/grep -q '^Authority=Developer ID Application:' <<<"$signing_details" \
    || reccy_fail 'a Developer ID Application signature is required'
  /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' <<<"$signing_details" \
    || reccy_fail 'the hardened runtime is not enabled'
  /usr/bin/grep -Eq '^Timestamp=.+$' <<<"$signing_details" \
    || reccy_fail 'the Developer ID signature is missing a trusted timestamp'
  team="$(/usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$signing_details")"
  [[ -n "$team" && "$team" != "not set" ]] \
    || reccy_fail 'the signature is missing its team identifier'
  if [[ -n "$expected_team" && "$team" != "$expected_team" ]]; then
    reccy_fail "signature team $team does not match expected team $expected_team"
  fi

  architectures="$(/usr/bin/lipo -archs "$executable")"
  local architecture
  for architecture in "${RECCY_EXPECTED_ARCHITECTURES[@]}"; do
    [[ " $architectures " == *" $architecture "* ]] \
      || reccy_fail "the release is missing $architecture (found: $architectures)"
  done

  entitlements="$(/usr/bin/mktemp -t reccy-entitlements.XXXXXX)"
  /usr/bin/codesign -d --entitlements :- "$app" >"$entitlements" 2>/dev/null \
    || { /bin/rm -f "$entitlements"; reccy_fail 'unable to inspect release entitlements'; }
  [[ "$(reccy_plist_value com.apple.security.device.audio-input "$entitlements")" == "true" ]] \
    || { /bin/rm -f "$entitlements"; reccy_fail 'the audio-input entitlement is missing'; }
  [[ -z "$(reccy_plist_value com.apple.security.get-task-allow "$entitlements")" ]] \
    || { /bin/rm -f "$entitlements"; reccy_fail 'release contains the debug get-task-allow entitlement'; }
  [[ -z "$(reccy_plist_value com.apple.security.cs.disable-library-validation "$entitlements")" ]] \
    || { /bin/rm -f "$entitlements"; reccy_fail 'release disables library validation'; }
  /bin/rm -f "$entitlements"

  [[ -f "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]] \
    || reccy_fail 'the embedded Sparkle framework is missing'
  local feed_url public_key
  feed_url="$(reccy_plist_value SUFeedURL "$info")"
  public_key="$(reccy_plist_value SUPublicEDKey "$info")"
  [[ "$feed_url" =~ ^https://github\.com/[^/]+/[^/]+/releases/latest/download/appcast\.xml$ ]] \
    || reccy_fail "unexpected Sparkle feed URL: ${feed_url:-missing}"
  [[ "$public_key" =~ ^[A-Za-z0-9+/=]{40,}$ ]] \
    || reccy_fail 'the Sparkle EdDSA public key is invalid'
  [[ "$(reccy_plist_value SURequireSignedFeed "$info")" == "true" ]] \
    || reccy_fail 'signed Sparkle feeds are not required by the app'
  [[ "$(reccy_plist_value SUVerifyUpdateBeforeExtraction "$info")" == "true" ]] \
    || reccy_fail 'Sparkle update verification before extraction is disabled'
}

reccy_assert_notarized_app() {
  local app="$1"
  /usr/bin/xcrun stapler validate "$app" >/dev/null \
    || reccy_fail 'the app does not contain a valid stapled notarization ticket'
  /usr/sbin/spctl --assess --type execute --verbose=4 "$app" \
    || reccy_fail 'Gatekeeper rejected the app'
}

reccy_resolve_sparkle_tool() {
  local root="$1"
  local derived_data="$2"
  local tool="$3"
  local path="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/$tool"
  if [[ ! -x "$path" ]]; then
    /usr/bin/xcodebuild \
      -project "$root/Reccy.xcodeproj" \
      -scheme Reccy \
      -configuration Release \
      -destination 'generic/platform=macOS' \
      -derivedDataPath "$derived_data" \
      -resolvePackageDependencies >/dev/null
  fi
  [[ -x "$path" ]] || reccy_fail "Sparkle tool was not resolved: $tool"
  printf '%s\n' "$path"
}

reccy_assert_sparkle_signing_key() {
  local root="$1"
  local app="$2"
  local derived_data="$3"
  local embedded_key actual_key generate_keys
  embedded_key="$(reccy_plist_value SUPublicEDKey "$app/Contents/Info.plist")"

  if [[ -n "${RECCY_SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    [[ -f "$RECCY_SPARKLE_PRIVATE_KEY_FILE" ]] \
      || reccy_fail "Sparkle private key file is missing: $RECCY_SPARKLE_PRIVATE_KEY_FILE"
    actual_key="$(/usr/bin/xcrun swift "$root/Scripts/sparkle-public-key.swift" "$RECCY_SPARKLE_PRIVATE_KEY_FILE")" \
      || reccy_fail 'unable to derive the Sparkle public key'
  else
    generate_keys="$(reccy_resolve_sparkle_tool "$root" "$derived_data" generate_keys)"
    actual_key="$("$generate_keys" --account "${RECCY_SPARKLE_KEY_ACCOUNT:-ed25519}" -p 2>/dev/null)" \
      || reccy_fail 'unable to read the Sparkle signing key from Keychain'
  fi
  [[ "$actual_key" == "$embedded_key" ]] \
    || reccy_fail 'the Sparkle signing key does not match SUPublicEDKey embedded in Reccy'
}

# Releasing Reccy

Reccy ships outside the Mac App Store as a universal, hardened, Developer ID-signed and notarized app. Sparkle verifies both the signed appcast and the EdDSA-signed update archive before extraction.

`Scripts/release.sh` is the single release entry point. Local and GitHub releases use the same fail-closed validators; no separate “CI-only” signing path exists.

## Release invariants

Before an artifact can be packaged, the tooling proves all of the following:

- The worktree is clean, release notes match `MARKETING_VERSION`, the build is a positive integer, and a final release is running from the exact `v<MARKETING_VERSION>` tag.
- The bundle identifier is `com.reccy.mac`, the minimum system is macOS 26.0, and the executable contains both `arm64` and `x86_64` slices.
- The app has a timestamped Developer ID Application signature, Hardened Runtime, the expected team identifier, and no debug or disabled-library-validation entitlements.
- Sparkle is embedded, signed feeds and pre-extraction verification are required, and the private signing key matches `SUPublicEDKey` in the app.
- Apple accepted the notarization, the ticket is stapled, Gatekeeper accepts the app, the ZIP expands to the same verified executable, and Sparkle cryptographically accepts both archive and appcast signatures.
- `SHA256SUMS` and `release.json` describe the exact published artifacts and commit. The `.xcarchive`, dSYM archive, and Apple notarization evidence remain available to the release workflow for diagnostics and symbolication.

## Local rehearsal

Update `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, and `Documentation/RELEASE_NOTES.md`, commit them, then run a rehearsal:

```sh
RECCY_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
RECCY_DEVELOPMENT_TEAM="TEAMID" \
Scripts/release.sh prepare
```

This creates and validates the universal `.xcarchive`, signed app, dSYM archive, and notarization ZIP. It does not contact Apple, create a GitHub release, or mutate any publishing state.

## Local final release

Store notarization credentials in Keychain once:

```sh
xcrun notarytool store-credentials "Reccy Notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Create and check out the exact release tag only after CI and the signed hardware acceptance matrix are green, then finalize:

```sh
git tag v0.1.0

RECCY_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
RECCY_DEVELOPMENT_TEAM="TEAMID" \
RECCY_NOTARY_KEYCHAIN_PROFILE="Reccy Notary" \
RECCY_SPARKLE_KEY_ACCOUNT="ed25519" \
Scripts/release.sh finalize
```

The final command submits to Apple, staples the accepted ticket, creates and signs the phased Sparkle feed, expands and re-verifies the update, and writes:

- `dist/updates/appcast.xml`
- `dist/updates/Reccy-<version>-<build>.zip`
- `dist/updates/Reccy-<version>-<build>.md`
- `dist/updates/SHA256SUMS`
- `dist/updates/release.json`
- `dist/symbols/Reccy-<version>-<build>.dSYM.zip`
- `dist/notarization/notary-submit-*.json` and `notary-log-*.json`

Never upload a Sparkle private key, Developer ID certificate, notarization credential, or unnotarized archive.

## GitHub Actions

Pushing a `v*` tag starts `.github/workflows/release.yml` on GitHub’s macOS 26 runner. It imports the certificate into an ephemeral keychain, runs the same `Scripts/release.sh finalize` gate, preserves notarization evidence and dSYMs as a private workflow artifact, publishes only verified update assets, and removes every materialized credential even after failure.

The repository requires these Actions secrets:

- `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD`
- `APPLE_DEVELOPMENT_TEAM`
- `APP_STORE_CONNECT_KEY_P8_BASE64`, `APP_STORE_CONNECT_KEY_ID`, and `APP_STORE_CONNECT_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY_BASE64`

Protect the release environment with required reviewers, restrict tag creation, require CI on `main`, and rotate any credential immediately if a workflow log or artifact ever exposes it.

## Stable development installs

Use `Scripts/install-development.sh` for `/Applications/Reccy.app`. It refuses ad-hoc signing, verifies the bundle identity and team, compares the designated code requirement with the installed app, stages the replacement on the same volume, and restores the prior app if the swap fails. This stable identity is what lets macOS retain Screen Recording and Microphone privacy grants across rebuilds.

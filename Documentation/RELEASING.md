# Releasing Reccy

Reccy ships outside the Mac App Store as a hardened, Developer ID-signed and notarized app. Sparkle verifies every update with the EdDSA public key embedded in the app before extraction.

## Local release

1. Update `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, and `Documentation/RELEASE_NOTES.md`.
2. Build with a Developer ID Application identity:

   ```sh
   RECCY_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   RECCY_DEVELOPMENT_TEAM="TEAMID" \
   RECCY_REQUIRE_DEVELOPER_ID=1 \
   Scripts/build-release.sh
   ```

3. Store notarization credentials in Keychain once, then notarize and package:

   ```sh
   xcrun notarytool store-credentials "Reccy Notary" \
     --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"

   RECCY_NOTARY_KEYCHAIN_PROFILE="Reccy Notary" \
   RECCY_SPARKLE_KEY_ACCOUNT="ed25519" \
   Scripts/notarize-release.sh
   ```

4. Verify the stapled app, archive, and signed appcast:

   ```sh
   RECCY_REQUIRE_DEVELOPER_ID=1 Scripts/verify-sparkle-update.sh
   ```

Upload `dist/updates/appcast.xml`, the matching `.zip`, and its `.md` release notes to the same latest GitHub release. Never upload the Sparkle private key, Developer ID certificate, or notarization credentials.

## GitHub Actions secrets

The tag-driven release workflow expects:

- `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD`
- `APPLE_DEVELOPMENT_TEAM`
- `APP_STORE_CONNECT_KEY_P8_BASE64`, `APP_STORE_CONNECT_KEY_ID`, and `APP_STORE_CONNECT_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY_BASE64`

Create a `v<MARKETING_VERSION>` tag only after CI is green. The workflow validates the tag, imports an ephemeral signing keychain, signs and notarizes the app, generates the phased Sparkle feed, verifies every artifact, then publishes the GitHub release.

# Reccy 0.2.1

This patch fixes camera access in signed builds and makes the recording setup easier to scan:

- Restores camera access in Developer ID–signed releases by including the required camera entitlement alongside Reccy's existing privacy declaration.
- Adds fail-closed release checks for camera and microphone usage descriptions and signed capture entitlements.
- Gives the optional camera overlay its own capture card and source picker instead of combining it with audio.
- Separates transcription from the core Audio, Pointer, and Start controls for a cleaner recording setup.

Requires macOS 26 or later. Download the notarized DMG for a standard drag-to-Applications install, or the signed ZIP for Sparkle-compatible deployment. `SHA256SUMS` and `release.json` provide independent artifact integrity and provenance metadata.

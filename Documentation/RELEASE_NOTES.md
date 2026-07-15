# Reccy 0.2.0

This release adds native, private transcription and a fully editable webcam workflow to Reccy's capture and editing foundation:

- On-device Apple Speech and WhisperKit transcription engines with live and post-recording workflows, source-aware transcript tracks, model management, and editor integration.
- Optional built-in, external, Continuity, or Desk View camera recording as a separate, synchronized video track.
- A low-latency webcam preview on the Monitor page using the same native sample buffers written to the recording.
- A dedicated camera timeline lane with direct positioning and resizing in the editor; the same composition is used for preview and export.
- App-wide camera selection, privacy controls, recording metadata, storage preflight, interruption recovery, and two-track capture validation.
- More robust native source-picker cancellation, reset, and stale-callback handling across the main recording and menu-bar controls.

Requires macOS 26 or later. Download the notarized DMG for a standard drag-to-Applications install, or the signed ZIP for Sparkle-compatible deployment. `SHA256SUMS` and `release.json` provide independent artifact integrity and provenance metadata.

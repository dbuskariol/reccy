# Reccy 0.3.0

This release adds a native, non-destructive caption workflow to Reccy's editor and fixes application-window presentation throughout playback and export:

- Generates an editable caption track from source-aligned Apple Speech or WhisperKit transcripts while preserving independent system-audio and microphone timing.
- Lets editors correct recognized transcript segments, regenerate readable caption cues, or add, edit, and remove captions manually at the playhead.
- Provides native caption placement, sizing, visibility, live Editor and Library previews, and AVFoundation-rendered captions in exported video.
- Keeps caption edits in the timeline project so the source recording and transcript sidecars remain intact until a finished export is rendered.
- Fixes selected application-window recordings appearing small inside a black canvas by retaining canonical AVFoundation composition tracks, fitting content without distortion, and using the recording's actual display aspect throughout Library, Editor, and export.
- Reorganizes the editor around native macOS sidebar, toolbar, menu, material, sizing, keyboard, and accessibility conventions while preserving Reccy's timeline, camera, transcript, and export actions.

Requires macOS 26 or later. Download the notarized DMG for a standard drag-to-Applications install, or the signed ZIP for Sparkle-compatible deployment. `SHA256SUMS` and `release.json` provide independent artifact integrity and provenance metadata.

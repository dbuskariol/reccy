# Reccy 0.3.4

This release expands live capture preparation and non-destructive editing while keeping every source local and independently editable:

- Shows the approved screen, camera, and audio meters during the countdown by preparing one capture session before the writer is armed; countdown samples never enter the recording.
- Opens macOS Video Effects for supported cameras, including native Portrait background blur and Background Replacement images, and reflects the active system effect in Record and Monitor.
- Expands mouse-follow zoom to eleven levels from 1.25× through 6× and lets Monitor change magnification during a recording; each change becomes an editable timeline segment at the exact media clock.
- Fixes routed live captions so Apple Speech and WhisperKit publish finalized and in-progress Monitor text before recording ends, with explicit transport errors and protection against a stale session canceling the next recording.
- Adds a saved poster-frame command used consistently by Editor, Library playback, and project-rendered Library thumbnails.
- Imports movies, audio, and images through a native open panel into independent project-owned tracks. Movie audio remains linked but separate, originals are never rewritten, and still images use bounded two-frame proxies regardless of timeline duration.
- Generalizes direct manipulation, keyboard access, VoiceOver actions, undo, preview, and export from camera-only placement to every overlay-video track.
- Adds regression coverage for live Apple Speech and WhisperKit callbacks, stale-session isolation, granular live zoom changes, poster-frame migration and clamping, linked video/audio import, and real AVFoundation still-image rendering.

Requires macOS 26 or later. Download the notarized DMG for a standard drag-to-Applications install, or the signed ZIP for Sparkle-compatible deployment. `SHA256SUMS` and `release.json` provide independent artifact integrity and provenance metadata.

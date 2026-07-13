# Reccy

Reccy is a macOS 26-native screen recorder and non-destructive multitrack editor built with Swift 6 and Apple media frameworks.

The repository currently contains a working engineering foundation, not a distribution-ready 1.0. It builds, launches, and has unit-tested timeline and encoding policy. Real capture still needs a signed, permission-enabled end-to-end test pass on representative Intel and Apple silicon Macs before release.

## Current capabilities

- Record a full display, a specific display, an application, or a window using the system content picker.
- Record system audio and microphone audio independently, with named AAC tracks in the output movie.
- Toggle cursor visibility, SDR mouse-click highlights, and exclusion of Reccy's own audio.
- Capture at native, 4K, 1440p, 1080p, or 720p and 24, 30, or 60 fps without upscaling smaller sources.
- Write efficient HEVC MP4, compatible H.264 MP4, or HEVC MOV masters with explicit bitrate policy.
- Record HDR10 using the macOS 26 ScreenCaptureKit preset and a 10-bit HEVC/PQ/Rec. 2020 pipeline.
- Take native macOS 26 screenshots as HEIC, JPEG, or PNG in SDR or HDR.
- Browse recordings, reveal them in Finder, share, play, trash, or send them to the editor.
- Edit video, system audio, microphone audio, and voiceover on separate lanes.
- Split a selected clip independently, split all tracks in sync, delete a clip, or ripple-delete a time range.
- Mute and adjust individual audio lanes and record new voiceover clips at the playhead.
- Save a non-destructive `.reccyproject` package and export HEVC, H.264, ProRes, or audio-only M4A.
- Start and stop from the menu bar or the `Command-Shift-R` shortcut.

## Platform and toolchain

- macOS 26.0 or later
- Xcode 26.5 or later
- Swift 6 with complete strict-concurrency checking

Open `Reccy.xcodeproj`, select the Reccy scheme, and run on My Mac. To verify from Terminal:

```sh
xcodebuild -project Reccy.xcodeproj \
  -scheme Reccy \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Screen recording and microphone permissions are requested by macOS when those features are first used. Unsigned command-line builds are suitable for compilation and unit tests, not realistic privacy-permission validation.

## Why macOS 26 only

Reccy treats the current platform as the product rather than maintaining a compatibility architecture. macOS 26 supplies the HDR10 recording preset and the new `SCScreenshotConfiguration` API for native SDR/HDR screenshots and direct HEIC/JPEG/PNG output. Standard SwiftUI navigation, controls, materials, and toolbars also adopt the current macOS appearance automatically.

The capture engine intentionally uses `SCStream` plus `AVAssetWriter` instead of ScreenCaptureKit's simpler single-file recording output. The custom muxing layer is what preserves system audio and microphone audio as separate, independently editable tracks while retaining explicit control over codec, bitrate, color, and container.

See [Architecture](Documentation/ARCHITECTURE.md) for the media pipeline and engineering decisions.

## Production milestones

The next release-oriented work is:

1. Add draggable trimming, clip movement, snapping, waveforms, and undo/redo.
2. Add autosave, interrupted-recording recovery, and low-disk safeguards.
3. Build deterministic capture/export fixtures plus signed end-to-end permission tests.
4. Add accessibility labels, keyboard-only timeline operation, localization, and VoiceOver QA.
5. Add an app icon, onboarding, permission education, code signing, notarization, and update delivery.
6. Decide direct distribution versus App Store sandboxing; sandboxed distribution also requires security-scoped bookmarks for persistent custom folders and imported media.

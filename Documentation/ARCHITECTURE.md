# Reccy architecture

## Product boundary

Reccy deploys exclusively to macOS 26. This removes availability branching from the core product and lets macOS 26 capture, screenshot, Swift concurrency, and SwiftUI behaviors shape the architecture from day one.

## Media pipeline

```text
SCContentSharingPicker ─┐
Region selection overlay ├── approved SCContentFilter
                        │
        ▼
     SCStream
        ├── screen CMSampleBuffer ───────► HEVC/H.264 AVAssetWriterInput
        ├── system-audio CMSampleBuffer ─► AAC “System Audio” input
        └── microphone CMSampleBuffer ───► AAC “Microphone” input
                                                │
                                                ▼
                                    MP4 or MOV multitrack recording
                                                │
                                                ▼
                           TimelineProject + AVMutableComposition
                              ├── video lane
                              ├── system-audio lane
                              ├── microphone lane
                              └── voiceover lane(s)
                                                │
                                                ▼
                                      AVAssetExportSession
```

## Capture

`CaptureCoordinator` owns user-visible state, persisted settings, privacy authorization, output naming, and the transition into the library. Display, application, and window approval use `SCContentSharingPicker` and remain available without a direct-capture grant. Portion capture needs the one-time Direct Screen & System Audio Access approval that macOS describes as bypassing the private window picker; Reccy then presents one coordinated, non-capturable selection panel per connected display, and the accepted rectangle becomes the `sourceRect` of a display `SCContentFilter`.

`MultitrackRecorder` consumes ScreenCaptureKit sample buffers on one serial, user-interactive queue. The first complete video frame establishes the asset-writer session time. Early audio is buffered briefly and flushed from that same timestamp, preventing microphone or system-audio lead-in from shifting sync.

The writer creates separate, titled tracks for screen, system audio, and microphone. A five-second movie-fragment interval limits how much unwritten media is exposed during an interruption. HEVC is the default because it gives markedly better screen-content size efficiency; H.264 remains available for compatibility, and MOV is available for editing-oriented masters.

Before capture starts, `RecordingStoragePolicy` derives a five-minute safety window from the exact configured video and audio bitrates and adds a 512 MB filesystem reserve. While recording, Reccy checks that reserve every two seconds and stops through the normal writer-finalization path before the volume is exhausted. An atomic journal beside the media records the intended manifest before `SCStream` starts. A kernel-backed `fcntl` lease makes writing and recovery mutually exclusive across installed, Xcode, and QA processes; recovery waits while a live writer owns the directory and the OS releases the lease automatically after a crash. On the next safe recovery pass, Library validates the fragmented file: playable video is re-indexed automatically, while invalid media is preserved under an explicit Interrupted filename and surfaced in a first-class recovery banner.

The live monitor does not start a second stream. Complete ScreenCaptureKit frames feed the writer and a shared preview pipeline. Following Apple’s current ScreenCaptureKit sample architecture, that pipeline validates frame metadata, retains the existing IOSurface and content geometry, coalesces UI backpressure to the newest frame, and presents the surface through a layer-hosting AppKit view whose backing layer is installed before layer hosting is enabled. The recording pixels remain GPU-shared, no timed-playback renderer or pixel copy sits in the path, and writer timestamps are never mutated. AVAssetWriter uses a safe-save staging file while recording; Reccy reports an honest safe-write state until the destination exposes a committed size rather than showing a misleading zero-byte value.

HDR recording begins with ScreenCaptureKit's `.captureHDRRecordingPreservedSDRHDR10` configuration. Reccy then writes HEVC Main 10 with PQ transfer, Rec. 2020 primaries/matrix, and VideoToolbox's SDR-range-preservation metadata request. Mouse-click highlighting is disabled in HDR because ScreenCaptureKit currently supports that overlay for BGRA SDR capture.

## Screenshots

On macOS 26, `SCScreenshotConfiguration` captures the already-approved content filter. The UI exposes HEIC, JPEG, PNG, SDR, HDR, and cursor inclusion. Files are written under the selected Reccy output directory in `Screenshots`.

## Timeline

`TimelineProject` is the serializable, non-destructive edit decision list. A clip points to a source URL, source track ID, source range, and timeline range; source media is never rewritten by an edit.

`TimelineEditorController` materializes that model as an `AVMutableComposition` for AVPlayer preview and export. Video, system audio, microphone, and voiceover remain independent lanes. A user can split only the selected clip or split every lane at the playhead, delete one clip, or ripple-delete a range across the project. Lane mute and volume are represented by `AVAudioMix` parameters.

Voiceover uses an explicitly configured `AVCaptureSession` and `AVCaptureAudioFileOutput` so the user can choose a real input device instead of being limited to the current system default. The session commits its configuration before capture starts and writes mono 48 kHz AAC into the project's `Media` directory. Each take becomes an independent audio clip at the current playhead, so it can be moved, trimmed, split, muted, deleted, or replaced without altering the screen recording.

Project packages use this shape:

```text
Example.reccyproject/
├── project.json
└── Media/
    └── Voiceover <UUID>.m4a
```

## Export

`ExportService` centralizes delivery presets and delegates transcoding to macOS 26's async `AVAssetExportSession` APIs. Current outputs include source-resolution and scaled HEVC/H.264 MP4, ProRes 422/4444 MOV, and audio-only M4A. Compatibility is determined against the immutable asset snapshot before a preset is enabled. Export progress comes from `states(updateInterval:)`, and cancellation is structured task cancellation.

The service writes into a private, same-volume staging directory and reserves capacity from the framework estimate plus a conservative codec fallback. It validates playability, duration, file size, and required video or audio tracks before atomically replacing the destination, so a failed or canceled export never destroys an existing file. Library and Editor share one `ExportWorkflow` and one native sheet. Timeline exports pass both the video composition and `AVAudioMix`, ensuring gap fills and lane mute/volume decisions match preview. The capture presets and export presets are intentionally distinct: capture prioritizes a reliable real-time encode, while export can prioritize delivery size, compatibility, or finishing quality.

## UI

The application uses SwiftUI scenes, an app-owned fixed-width workspace sidebar, native toolbars, AppKit file panels, AVKit rendering surfaces, a menu-bar extra, standard materials, semantic colors, SF Symbols, and system content sharing. Owning the root split geometry keeps every section aligned even when detail toolbars change, while the controls and window chrome still inherit the native macOS treatment.

Icon controls use one shared semantic-label and tooltip primitive so the visible interface, hover help, and assistive descriptions cannot drift. The timeline exposes each clip and gap as one adjustable accessibility object instead of leaking decorative handles. Frame-accurate move, trim, and gap-fill operations are available through VoiceOver custom actions and matching Editor-menu keyboard commands.

## Privacy and distribution

Capture and editing are local. The only network surface is Sparkle's signed update feed. Hardened Runtime is enabled. App Sandbox is intentionally disabled for direct distribution so ScreenCaptureKit, the default Movies folder, persisted custom output directories, and imported media remain first-class without broad security-scoped-bookmark plumbing.

Release builds originate from an `.xcarchive`, include a dSYM archive, and are universal, timestamped Developer ID-signed, notarized, stapled, and checked by Gatekeeper. Sparkle archives and the feed are independently EdDSA-signed and published with a phased appcast through GitHub Releases. One shared validator gates local and CI releases on the exact bundle identity, version/tag, minimum OS, both architectures, Hardened Runtime, production entitlements, updater configuration, matching Sparkle key, notarization ticket, expanded-archive identity, and cryptographic archive/feed verification. Final artifacts include SHA-256 checksums and a commit-addressed machine-readable manifest.

Local capture builds use the same identity principle. `scripts/install-development.sh` refuses ad-hoc signing and requires a stable Apple Development or Developer ID certificate, ensuring macOS TCC sees rebuilt `/Applications/Reccy.app` bundles as the same application. It rejects a different team or designated code requirement and performs a staged same-volume replacement with rollback, preventing both privacy-identity churn and a half-installed app.

## Testing strategy

The automated suite covers Retina-aware resolution capping, no-upscale behavior, portrait output bounds, synchronized and independent splitting, ripple deletion, independent and linked movement, magnetic reorder, snapping, trimming, pause-timeline removal, waveform source ranges, per-gap fill identity, held-frame composition, codec bitrate policy, storage preflight, cross-process recording/recovery exclusion, atomic recovery journals, playable interruption recovery, invalid-file preservation, the complete export preset matrix, safe destination replacement, cancellation, and rendered audio mixes. GitHub runs that gate natively on both its macOS 26 Apple-silicon and Intel runners. Installed-app Computer Use QA exercises the main navigation, recovery banner, library transport, timeline seeking, movement, reorder, trimming, gap fills, VoiceOver custom actions, keyboard nudging, voiceover sources, zoom, menu-bar pause/resume/stop, and real export progress/completion. Remaining release acceptance includes:

- signed capture runs for every source and audio combination;
- long-duration A/V drift measurements;
- HDR metadata and playback validation on SDR and HDR displays;
- encoder fallback under sustained capture load;
- multichannel and external microphone fixtures;
- signed export acceptance across Intel and Apple-silicon hardware;
- signed picker automation and a complete spoken VoiceOver acceptance pass.

## Primary Apple technologies

- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [SCScreenshotConfiguration](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration)
- [AVMutableComposition](https://developer.apple.com/documentation/avfoundation/avmutablecomposition)
- [AVAssetExportSession](https://developer.apple.com/documentation/avfoundation/avassetexportsession)
- [AVCaptureSession](https://developer.apple.com/documentation/avfoundation/avcapturesession)
- [AVCaptureAudioFileOutput](https://developer.apple.com/documentation/avfoundation/avcaptureaudiofileoutput)
- [VideoToolbox](https://developer.apple.com/documentation/videotoolbox)
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)

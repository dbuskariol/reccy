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
AVCaptureSession ── camera CMSampleBuffer ► HEVC/H.264 “Camera” input
                                                │
                                                ▼
                                    MP4 or MOV multitrack recording
                                                │
                                                ▼
                           TimelineProject + AVMutableComposition
                              ├── video lane
                              ├── camera lane + normalized overlay layout
                              ├── system-audio lane
                              ├── microphone lane
                              ├── voiceover lane(s)
                              └── editable timed caption track
                                                │
                                                ▼
                                      AVAssetExportSession
```

## Capture

`CaptureCoordinator` owns user-visible state, persisted settings, privacy authorization, output naming, and the transition into the library. Display, application, and window approval use `SCContentSharingPicker` and remain available without a direct-capture grant. Portion capture needs the one-time Direct Screen & System Audio Access approval that macOS describes as bypassing the private window picker; Reccy then presents one coordinated, non-capturable selection panel per connected display, and the accepted rectangle becomes the `sourceRect` of a display `SCContentFilter`.

`MultitrackRecorder` consumes ScreenCaptureKit sample buffers on one serial, user-interactive queue. When camera capture is enabled, `WebcamCaptureSession` uses native `AVCaptureSession` device discovery and `AVCaptureVideoDataOutput` for built-in, external, Continuity, and Desk View cameras. Camera timestamps are converted from the session synchronization clock to the host clock at the capture boundary, then enter the same writer queue and pause timeline as ScreenCaptureKit. The first complete screen frame establishes the asset-writer session time. Early camera and audio samples are buffered briefly and flushed from that same timestamp, preventing a secondary source from shifting sync.

The writer creates separate, titled tracks for screen, camera, system audio, and microphone. Camera video uses its native configured dimensions, a real-time hardware-preferred encoder, and the recording's resolved codec while remaining an independent source track. Pause keeps both capture sessions alive for monitoring while withholding samples from the writer. Resume anchors every lane to the next complete screen frame and maps it onto the latest successfully written sample end across all tracks, so the removed wall-clock interval cannot create overlapping audio or a frozen-video gap. If an optional camera stops producing frames more than 250 milliseconds before the other lanes, finalization duplicates its last accepted frame at the recording boundary. This preserves a structurally aligned editable source while Library warns that the camera picture was held; if the tail cannot be written, the session follows the recoverable-failure path instead of silently cataloguing a badly drifted master. A five-second movie-fragment interval limits how much unwritten media is exposed during an interruption. HEVC is the default because it gives markedly better screen-content size efficiency; H.264 remains available for compatibility, and MOV is available for editing-oriented masters.

Before capture starts, `RecordingStoragePolicy` derives a five-minute safety window from the exact configured screen, optional camera, and audio bitrates and adds a 512 MB filesystem reserve. While recording, Reccy checks that reserve every two seconds and stops through the normal writer-finalization path before the volume is exhausted. An atomic journal beside the media records the intended manifest before capture starts and is atomically updated with the camera's resolved identity and dimensions. A failure before the first complete video frame removes its startup-only media and matching journal after the recorder has shut down; a failure after recording begins keeps the journal so real partial media remains recoverable. A kernel-backed `fcntl` lease makes writing and recovery mutually exclusive across installed, Xcode, and QA processes; recovery waits while a live writer owns the directory and the OS releases the lease automatically after a crash. On the next safe recovery pass, Library validates the fragmented file: playable video is re-indexed automatically, while invalid media is preserved under an explicit Interrupted filename and surfaced in a first-class recovery banner.

The live monitor does not start duplicate capture streams. Complete screen and camera frames feed the writer and independent shared preview pipelines. Following Apple’s current sample architecture, each pipeline validates its buffer, retains the existing IOSurface and content geometry, coalesces UI backpressure to the newest frame, and presents the surface through a layer-hosting AppKit view whose backing layer is installed before layer hosting is enabled. The recording pixels remain GPU-shared, no timed-playback renderer or pixel copy sits in the path, and writer timestamps are never mutated. AVAssetWriter uses a safe-save staging file while recording; Reccy reports an honest safe-write state until the destination exposes a committed size rather than showing a misleading zero-byte value.

The system content-sharing picker has one observer registration for the `CaptureCoordinator` lifetime. Individual selection, cancellation, stop, and failure paths only deactivate the picker; they never remove and re-add the observer from inside its own callback. This preserves native update and cancellation delivery across repeated source choices in one long-running app process.

HDR recording begins with ScreenCaptureKit's `.captureHDRRecordingPreservedSDRHDR10` configuration. Reccy then writes HEVC Main 10 with PQ transfer, Rec. 2020 primaries/matrix, and VideoToolbox's SDR-range-preservation metadata request. Mouse-click highlighting is disabled in HDR because ScreenCaptureKit currently supports that overlay for BGRA SDR capture.

Every capture resolves through one encoding plan before a file or recovery journal is created. AVAssetWriter preflights the exact video and audio settings against the chosen container. Video settings mark the encoder as real-time and use `AVVideoEncoderSpecificationKey` to prefer hardware acceleration while allowing VideoToolbox's software implementation when hardware is absent, incompatible, or busy. Reccy never switches codecs mid-file: HDR resolves to HEVC, SDR follows the selected preset, and the resolved codec is persisted independently in the manifest so Library metadata always describes the media requested from the writer.

## Screenshots

On macOS 26, `SCScreenshotConfiguration` captures the already-approved content filter. The UI exposes HEIC, JPEG, PNG, SDR, HDR, and cursor inclusion. HDR requests ask ScreenCaptureKit for both HDR and SDR representations to maximize the chance that HDR pixels remain available when the framework omits its requested file. Files are written under the selected Reccy output directory in `Screenshots`. Reccy verifies the framework output is a nonempty, decodable image before exposing Share. If ScreenCaptureKit returns pixels without persisting its requested file, an ImageIO fallback encodes the requested SDR or HDR image into a same-directory staging file, validates it, and atomically installs it at the requested destination. If macOS provides no HDR representation, Reccy reports that limitation and suggests SDR or another display instead of silently mislabeling SDR output as HDR. Screenshot-only failures preserve the approved source so dismissing the error returns to a ready workspace.

## Timeline

`TimelineProject` is the serializable, non-destructive edit decision list. A clip points to a source URL, source track ID, source range, and timeline range; source media is never rewritten by an edit.

`TimelineEditorController` materializes that model as an `AVMutableComposition` for AVPlayer preview and export. Screen video, camera video, system audio, microphone, and voiceover remain independent lanes. Camera placement is stored as a normalized, canvas-relative rectangle on the camera clip, so it survives source-resolution and export changes. The player exposes direct move and resize interaction; `AVVideoComposition` applies the same aspect-preserving transform and front-to-back layer order for preview and export. A user can split only the selected clip or split every lane at the playhead, delete one clip, or ripple-delete a range across the project. Lane mute and volume are represented by `AVAudioMix` parameters.

Every committed editor mutation atomically autosaves the project package and registers the complete project, selection, playhead, package, and source-duration state with the window’s native `UndoManager`. Standard Undo and Redo therefore cover discrete and drag-based clip edits, track mute/volume, camera layout, captions, and voiceover additions while continuing to use the same rebuild-and-save path as direct edits. Opening another project clears only this controller’s prior undo registrations, leaving ordinary text-field undo behavior to the macOS responder chain.

The project also owns a non-destructive timed caption track. Transcript projection creates sentence-bounded cues, removes strongly matching cross-track acoustic echoes, and serializes genuinely concurrent speakers so two caption layers never draw over one another. Caption text, manual cues, visibility, placement, and size are editable without rebuilding the media composition. Playback uses one shared native SwiftUI overlay in Editor and Library; exports use `AVVideoCompositionCoreAnimationTool` with `CATextLayer` because Apple defines that tool as an offline render path. The export pass reuses the base composition instructions and color metadata, so captions do not flatten or alter the source tracks.

`TimelineCompositionBuild` creates AVPlayer items from its canonical composition. The layer instructions and player asset therefore always reference the same composition tracks; independently copying the asset after instructions are built can make layered screen and camera previews resolve against different track instances. Library sizes its player surface from the actual render aspect rather than assuming 16:9, preserving window, application, portrait, and portion geometry.

Voiceover uses an explicitly configured `AVCaptureSession` and `AVCaptureAudioFileOutput` so the user can choose a real input device instead of being limited to the current system default. The session commits its configuration before capture starts and writes mono 48 kHz AAC into the project's `Media` directory. Each take becomes an independent audio clip at the current playhead, so it can be moved, trimmed, split, muted, deleted, or replaced without altering the screen recording.

Project packages use this shape:

```text
Example.reccyproject/
├── project.json
└── Media/
    └── Voiceover <UUID>.m4a
```

## Transcription

Transcription is source-track data, not a flattened presentation artifact. `MultitrackRecorder` mirrors accepted, pause-retimed system and microphone PCM buffers onto a dedicated nonblocking route after the authoritative writer append. Capture never waits for inference, and transcription failure cannot interrupt recording.

`TranscriptionEngine` defines one contract for availability, asset preparation, exact-track post-processing, and live sessions. `AppleSpeechTranscriptionEngine` follows Apple's macOS 26 SpeechAnalyzer pipeline: time-indexed `SpeechTranscriber` presets, `AssetInventory` reservation and installation, `bestAvailableAudioFormat`, an asynchronous `AnalyzerInput` sequence, volatile/final result handling, and explicit finalization. Post-recording analysis extracts the requested `CMPersistentTrackID` into a closed mono PCM file before handing it to `analyzeSequence(from:)`. Live analysis uses the reusable, unprimed `AVAudioConverter` pattern from Apple's WWDC25 code-along before supplying timestamped inputs. `AnalyzerInputConverter` and the framework input providers are macOS 27 APIs and therefore are not referenced by this macOS 26 target.

`WhisperKitTranscriptionEngine` uses Argmax Open-Source SDK 1.0's WhisperKit product and local Core ML model folders on Apple silicon. `WhisperModelManager` owns an indexed model library in Application Support, explicit background downloads, byte counts, and removal. Inference is configured with downloads disabled, so selecting WhisperKit without an installed model produces an actionable state instead of making an implicit request. Post-processing calls WhisperKit's array transcription API over bounded, overlapping five-minute source-track windows. Live microphone inference delegates decode cadence, voice activity detection, and confirmed/unconfirmed segment state to WhisperKit's `AudioStreamTranscriber`; a narrow `AudioProcessing` adapter supplies Reccy's already-authorized and pause-retimed PCM so WhisperKit does not open a competing microphone capture. WhisperKit's public stream API always requests microphone authorization, so system-audio-only live transcription uses the same decoder through Reccy's bounded external-source session instead of creating an unrelated microphone permission dependency.

Both engines emit the same word/segment model. `TranscriptStore` atomically persists one `.reccytranscript` sidecar beside the media, retaining engine, locale, model, role, source track ID, source times, confidence, alternatives, and explicit user corrections. `TranscriptProjection` maps source times through `TimelineProject` clips, so independent trims, moves, splits, duplicates, gaps, and deletions produce deterministic timeline cues without rewriting source timing. TXT, SRT, WebVTT, and the editable project caption generator use that same projection. A correction updates the canonical transcript sidecar; regenerating captions applies it while preserving caption style. Library search and seeking, Monitor captions, and Editor captions therefore consume one canonical document rather than view-specific copies.

## Export

`ExportService` centralizes delivery presets and delegates transcoding to macOS 26's async `AVAssetExportSession` APIs. Current outputs include source-resolution and scaled HEVC/H.264 MP4, ProRes 422/4444 MOV, and audio-only M4A. Compatibility is determined against the immutable asset snapshot before a preset is enabled. Export progress comes from `states(updateInterval:)`, and cancellation is structured task cancellation.

The service writes into a private, same-volume staging directory and reserves capacity from the framework estimate plus a conservative codec fallback. It validates playability, duration, file size, and required video or audio tracks before atomically replacing the destination, so a failed or canceled export never destroys an existing file. Library and Editor share one `ExportWorkflow` and one native sheet. A direct Library export first loads the exact saved project used by Library preview and Editor, then passes its video composition, caption renderer, and `AVAudioMix` into the workflow. This prevents a raw multitrack capture from silently losing its camera overlay, saved edits, captions, or timeline audio choices in delivery. The distinct Share action intentionally hands off that editable source master and is labeled accordingly. Because `AVAssetExportSession` otherwise preserves independent system and microphone tracks in video containers, Reccy first renders multi-source audio and its mix parameters into one staged AAC program, recombines that program with the untouched video tracks while preserving video-composition track IDs, and then runs the selected delivery encode. The finished validator requires exactly one audio track whenever the source contains audio. The capture presets and export presets are intentionally distinct: capture prioritizes a reliable real-time encode, while export can prioritize delivery size, compatibility, or finishing quality.

## UI

The application uses SwiftUI scenes, a native `NavigationSplitView`, native toolbars, AppKit file panels, AVKit rendering surfaces, a menu-bar extra, standard materials, semantic colors, SF Symbols, and system content sharing. The system owns sidebar presentation, resizing, and the toolbar toggle. Editor actions use native toolbar items and menus instead of a second in-content control strip, keeping macOS sizing, materials, customization, and accessibility behavior consistent across every workspace.

Icon controls use one shared semantic-label and tooltip primitive so the visible interface, hover help, and assistive descriptions cannot drift. The timeline exposes each clip and gap as one adjustable accessibility object instead of leaking decorative handles. Frame-accurate move, trim, and gap-fill operations are available through VoiceOver custom actions and matching Editor-menu keyboard commands. The camera overlay is likewise one authoritative accessibility object: its position and size are spoken, and custom actions select, move, resize, or reset it without requiring a pointer drag.

## Privacy and distribution

Capture, editing, speech inference, and transcript storage are local. Network access is limited to Sparkle's signed update feed and explicit Whisper model catalog/download operations; media, live audio, and transcript text are never sent to either surface. Hardened Runtime is enabled. App Sandbox is intentionally disabled for direct distribution so ScreenCaptureKit, the default Movies folder, persisted custom output directories, imported media, and locally managed transcription models remain first-class without broad security-scoped-bookmark plumbing.

Release builds originate from an `.xcarchive`, include a dSYM archive, and are universal, timestamped Developer ID-signed, notarized, stapled, and checked by Gatekeeper. Sparkle archives and the feed are independently EdDSA-signed and published with a phased appcast through GitHub Releases. One shared validator gates local and CI releases on the exact bundle identity, version/tag, minimum OS, both architectures, Hardened Runtime, production entitlements, updater configuration, matching Sparkle key, notarization ticket, expanded-archive identity, and cryptographic archive/feed verification. Final artifacts include SHA-256 checksums and a commit-addressed machine-readable manifest. Non-publishing rehearsals use the same artifact graph but explicitly record rehearsal status, lack of notarization, and source-worktree cleanliness in that manifest.

Local capture builds use the same identity principle. `scripts/install-development.sh` refuses ad-hoc signing and requires a stable Apple Development or Developer ID certificate, ensuring macOS TCC sees rebuilt `/Applications/Reccy.app` bundles as the same application. It rejects a different team or designated code requirement and performs a staged same-volume replacement with rollback, preventing both privacy-identity churn and a half-installed app.

Repository automation also keeps all runnable DerivedData in Xcode's standard Library hierarchy rather than beneath the checkout. Signing identity governs capture permissions; executable location governs protected-folder access. Treating both independently prevents a test host built under Documents from causing a folder prompt that Full Disk Access was never intended to paper over.

## Testing strategy

The automated suite covers Retina-aware resolution capping, no-upscale behavior, portrait output bounds, backward-compatible camera settings, camera writer policy, camera-tail alignment after a material interruption, normalized overlay layout and rendered layer order, synchronized and independent splitting, ripple deletion, independent and linked movement, magnetic reorder, snapping, trimming, pause-time removal, track-specific waveforms, persistent per-gap fill choices, held-frame composition, manifests, bitrate-aware storage policy, cross-process recording leases, startup-failure cleanup, interrupted-file recovery, all ten export presets, single-program delivery audio, audio-mix rendering, safe replacement, cancellation, transcript persistence/projection/correction/export, exact-track PCM extraction, and real post-recording plus live inference with every installed transcription engine. GitHub runs that gate natively on both its macOS 26 Apple-silicon and Intel runners; optional model tests skip when their assets are intentionally absent. Installed-app Computer Use QA exercises the main navigation, recovery banner, library transport, transcript search and seeking, timeline seeking, movement, reorder, trimming, camera placement, gap fills, accessible editor actions, keyboard nudging, voiceover sources, zoom, menu-bar pause/resume/stop, and real export progress/completion.

Signed hardware captures are checked with `scripts/validate-capture.sh`. The validator reads the current sidecar as the capture contract and independently inspects the media through AVFoundation: playability, nonzero duration and size, exact screen/camera/audio track counts, displayed screen and camera dimensions, configured frame-rate ceiling, resolved codec, required HDR color metadata, and bounded end-time drift across independent tracks. It emits a machine-readable JSON report for the release evidence bundle.

The local 0.3.2 signed acceptance bundle covers every source/audio combination, native picker selection, a ten-minute sustained-load Apple-silicon run with hardware-encoder evidence and bounded A/V drift, an independently validated HDR10 capture, a ten-minute delivery export with one mixed audio program, and an independently validated Desk View recording. A standard Continuity Camera fixture exposed severe camera-track end drift when the phone stopped producing frames; that run is preserved as regression evidence, the writer now aligns a material optional-camera tail or enters recovery, focused and full-suite checks pass, and the exact rebuilt signed app passes built-in-camera capture. The post-fix standard Continuity repeat remains pending because the phone subsequently disappeared from AVCapture device discovery. Other cross-environment acceptance requires multichannel/external microphone signal fixtures, visual HDR playback on separate confirmed SDR and HDR displays, a signed Intel export, and a complete spoken VoiceOver pass on a machine where those system settings may be changed.

## Primary Apple technologies

- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [SCScreenshotConfiguration](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration)
- [AVMutableComposition](https://developer.apple.com/documentation/avfoundation/avmutablecomposition)
- [AVAssetExportSession](https://developer.apple.com/documentation/avfoundation/avassetexportsession)
- [AVCaptureSession](https://developer.apple.com/documentation/avfoundation/avcapturesession)
- [AVCaptureAudioFileOutput](https://developer.apple.com/documentation/avfoundation/avcaptureaudiofileoutput)
- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- [Argmax Open-Source SDK](https://github.com/argmaxinc/argmax-oss-swift)
- [VideoToolbox](https://developer.apple.com/documentation/videotoolbox)
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)

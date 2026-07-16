# AGENTS.md

This file is the repository-wide operating guide for coding agents working on Reccy. It applies to every path in the checkout unless a more specific `AGENTS.md` exists below it. Direct user instructions always take precedence.

## Product and engineering intent

Reccy is a native macOS 26 screen recorder and non-destructive multitrack editor. It is built with Swift 6, SwiftUI, ScreenCaptureKit, AVFoundation, VideoToolbox, and AppKit. The app deliberately supports macOS 26 only; do not add availability branches or compatibility UI for older systems.

Treat these as product invariants:

- Reccy is local-first and privacy-preserving. Recording media, audio buffers, projects, transcripts, thumbnails, and exports stay on the Mac. Network access is limited to explicit Whisper model downloads and signed update checks.
- The source approved by the user is the source Reccy records. Preserve the private system-picker boundary and the explicit permission model for portion capture.
- Screen video, optional camera video, system audio, microphone audio, and voiceover remain independent source tracks until a delivery export intentionally mixes or composites them.
- Source-master Share and rendered Export are different actions. Do not silently flatten, remix, or rewrite source media.
- Projects and transcript sidecars are non-destructive and atomically persisted. Never modify or delete a user's source recording as part of editing, exporting, migration, cleanup, or error recovery.
- A capture failure must be explicit and recoverable. Never catalog a structurally invalid recording as a successful result, and never discard playable screen or audio media merely because an optional source failed.
- Camera sample timestamps must be translated to the recording's host-clock timeline. Capture and asset-writer state mutations must stay serialized; user-interface state belongs on the main actor.
- The shipping app is a universal `arm64` and `x86_64` Developer ID application with Hardened Runtime, notarization, and Sparkle archive verification.
- Icon-only controls need stable accessibility labels, help text where useful, keyboard access where appropriate, and equivalent VoiceOver actions for direct-manipulation editor commands.

## Native Mac quality bar

“Native” is a product requirement, not just an implementation language. Reccy should feel designed for the current macOS rather than like a web, mobile, or cross-platform interface placed in a window.

- Prefer current Apple frameworks and system behavior: SwiftUI and Observation for interface state, AppKit where Mac-specific control is needed, ScreenCaptureKit for source consent and capture, AVFoundation/AVKit/VideoToolbox for media, SpeechAnalyzer for Apple transcription, and standard system panels and services.
- Use standard Mac structure: real windows and scenes, toolbars, sidebars, inspectors, tables or outlines, search fields, menus, Settings, sheets, popovers, alerts, context menus, drag and drop, Quick Look/Share/Reveal conventions, and undo/redo through the responder chain.
- Respect window resizing, compact and expansive layouts, source aspect ratio, multiple displays, full screen, focus, first-responder behavior, state restoration, appearance, accent color, increased contrast, reduced motion, and Dynamic Type where macOS exposes it.
- Keyboard use is first-class. Commands need conventional menu placement, discoverable shortcuts, correct enabled state, focus traversal, Escape/Return behavior, and the same result whether invoked from a button, menu item, shortcut, context menu, or accessibility action.
- Accessibility is part of the control contract. Preserve semantic roles and values, useful grouping and reading order, sufficiently large hit targets, non-color status cues, spoken progress and errors, and usable alternatives to pointer-only drag gestures.
- Let the system own privacy-sensitive approval and permission guidance whenever it provides the authoritative surface. Explain why access is needed, accurately reflect current authorization, and provide one clear recovery action without pretending Reccy can grant permission itself.
- Prefer platform-standard terminology, typography, spacing, materials, symbols, animations, and interaction feedback. Custom chrome, gestures, and controls require a concrete product benefit and must still behave like Mac controls.
- Do not duplicate the same action or message in one context. Establish one visual primary action and one authoritative presentation of status, progress, validation, errors, and confirmation. Secondary entry points are welcome when they route through the same command, state, naming, and behavior.
- Keep workspaces coherent across Record, Monitor, Library, Editor, Export, menu bar, and Settings. A saved camera layout, caption choice, audio state, or edit must mean the same thing in preview and final output.
- Add a third-party dependency only when Apple frameworks and a small maintained local implementation cannot meet the requirement. Consider binary size, privacy, sandbox/signing behavior, concurrency, launch cost, update cadence, and Intel support before doing so.

## Performance and resource discipline

Reccy handles several real-time media streams while presenting a responsive editor. Performance regressions are correctness bugs when they can cause dropped samples, timestamp drift, blocked controls, memory pressure, thermal runaway, or incomplete files.

- Keep capture callbacks and asset-writer paths bounded, serialized, and free of synchronous main-thread work. Never block a media callback on UI rendering, transcription, waveform generation, thumbnail work, or a modal interaction.
- Preserve the IOSurface-backed, latest-frame-coalesced monitor design. Do not create a second capture session, unbounded frame queue, or unnecessary pixel-buffer/bitmap copy merely to update preview UI.
- Apply backpressure deliberately. Honor writer readiness, bound every queue and buffer, and make an explicit policy choice about what may be coalesced or dropped. Preview frames may be expendable; source recording samples and timeline integrity are not.
- Separate hot-path recording work from optional derived work. Transcription, waveform calculation, thumbnails, metadata inspection, and UI presentation must not determine whether primary media can be written safely.
- Avoid invalidating a large SwiftUI tree for every frame, sample, meter tick, or progress callback. Publish compact observable state at an appropriate cadence and isolate frequently changing views.
- Never load an entire long recording or audio track into memory when streaming, incremental reading, tiling, downsampling, or caching will work. Bound waveform, transcript, thumbnail, undo, and editor caches; invalidate them precisely.
- Cancel stale asynchronous work when selection, source, project, window, or export state changes. Tie tasks, observers, capture sessions, players, security-scoped access, temporary files, and timers to explicit lifecycles so closing a workspace releases them.
- Prefer event-driven observation to polling. Any repeating timer needs a clear cadence, owner, suspension behavior, and teardown path.
- Keep expensive filesystem and AVFoundation inspection off the main actor, but publish UI state on it. Avoid actor hops per sample, priority inversions, nested serialization domains, and detached tasks whose lifetime is not owned.
- Use hardware encoders and native composition/export paths where they preserve required semantics. A fallback must be explicit, tested, and must not silently change codec, HDR metadata, dimensions, track independence, or audio mix.
- Preserve native source dimensions unless a documented output cap requires scaling; never upscale smaller sources. Keep color spaces, transfer functions, clean aperture, orientation, frame cadence, and HDR intent intact end to end.
- Measure before and after a meaningful performance change. Use Instruments, Xcode metrics, signposts, structured timing, memory graphs, Energy Log, and validated media metadata as appropriate; do not replace evidence with intuition.
- Exercise sustained capture, not only short smoke tests. Watch frame and track-end drift, writer failures, file growth, memory high-water mark, CPU/GPU load, thermal state, free-space reserve, pause/resume boundaries, and stop/finalization latency.
- Performance work must remain maintainable and deterministic. Do not trade away file safety, concurrency safety, accessibility, testability, or understandable ownership for a micro-optimization.

When changing a hot path, state the expected resource behavior in the code or architecture documentation, add regression coverage where practical, and validate the real signed app under a representative sustained workload.

## Repository map

- `Reccy/Models`: persisted and in-memory domain models, settings, timelines, captions, and transcription types.
- `Reccy/Services`: capture, recording, persistence, playback composition, editing, transcription, export, update, and recovery logic.
- `Reccy/Views`: SwiftUI workspaces and reusable interface components.
- `ReccyTests`: Swift Testing coverage, media fixtures, and integration-style AVFoundation checks.
- `Configuration`: bundle metadata, build settings, export options, and privacy configuration.
- `Documentation`: architecture, release process, release notes, and product screenshots.
- `scripts`: build, CI, capture validation, development installation, and fail-closed release automation.
- `.github/workflows`: native Apple-silicon and Intel CI plus guarded release automation.
- `dist`: generated release output. Do not hand-edit it or treat it as source.

Read `README.md` for current product behavior, `Documentation/ARCHITECTURE.md` before changing media or persistence boundaries, and `Documentation/RELEASING.md` before touching distribution code.

## Working in the checkout

Before editing:

1. Inspect `git status --short`, the current branch, and the relevant diff. A dirty worktree is normal; preserve changes you did not create.
2. Search with `rg` or `rg --files` before introducing a new abstraction, model, helper, or script.
3. Trace behavior across model, service, view, persistence, test, and documentation layers. Capture changes frequently cross more than one of them.

While editing:

- Prefer small, typed changes that preserve the existing architecture and source-track boundaries.
- Keep Swift 6 strict-concurrency checks clean. Avoid `@unchecked Sendable`, detached work, global mutable state, or actor escapes unless the safety argument is documented and tested.
- Keep time math in explicit media timescales. Test nonzero starts, pauses, portrait and Retina sources, mismatched track lengths, missing optional tracks, and cancellation.
- Stage file writes privately, validate the result, and atomically replace the destination. A failed or cancelled operation must leave an existing destination intact.
- Treat free-space checks and the runtime filesystem reserve as correctness requirements, not optional polish.
- Keep user-facing errors actionable and preserve enough state for retry. Do not fall back silently when that would alter codec, dynamic range, source, track structure, or output semantics.
- Reuse native SwiftUI, AppKit, AVKit, and system pickers. Do not introduce a custom control when a native control carries the correct behavior and accessibility semantics.
- Reproduce defects before fixing them when the environment permits. Fix the root cause, inspect adjacent paths that share the mechanism, and add a regression test. Do not swallow an error, weaken an assertion, remove a capability, or fabricate passing evidence to make a symptom disappear.
- Do not add telemetry, analytics, uploaded diagnostics, or any media/transcript network path.
- Use `apply_patch` for intentional text edits. Do not run destructive Git commands or overwrite unrelated work.

Generated build products and DerivedData belong outside the repository. The scripts default to `~/Library/Developer/Xcode/DerivedData/Reccy`; preserve that convention so executable bundles do not inherit protected-folder behavior from the checkout.

## Verification

Run checks in proportion to the change, and report exactly what ran and what did not.

The repository gate is:

```sh
scripts/verify-ci.sh
```

It checks shell syntax and release metadata, type-checks validation tools, lints property lists and privacy declarations, runs `git diff --check`, executes the Debug test suite on the host architecture, and builds a universal unsigned Release app.

For a focused Swift test, use external DerivedData and the current host architecture:

```sh
xcodebuild \
  -project Reccy.xcodeproj \
  -scheme Reccy \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "${RECCY_DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData/Reccy}/Focused" \
  -only-testing:'ReccyTests/ReccyTests/testName()' \
  test
```

The parentheses in a Swift Testing identifier matter. Inspect the resulting `.xcresult` with `xcrun xcresulttool get test-results summary --path /absolute/path/to/result.xcresult` and confirm that the expected nonzero test count actually ran; `** TEST SUCCEEDED **` alone can also describe an empty filter.

Add or update tests in `ReccyTests/ReccyTests.swift` for behavior changes. Prefer deterministic tests of pure policies plus real AVFoundation composition/export checks where the framework behavior is part of the contract. Optional SpeechAnalyzer assets or Whisper models may skip only when the fixture is genuinely unavailable; product logic must not be hidden behind a skip.

Validate every manually captured media file with:

```sh
scripts/validate-capture.sh /absolute/path/to/recording.mp4
```

Review its track starts, durations, media types, dimensions, codec, and end drift. A file merely opening in a player is not sufficient evidence for a multitrack recorder.

Capture permissions are tied to the installed signing identity. Ad-hoc builds are suitable for compilation, tests, and most interface work, but reliable Screen & System Audio, Camera, and Microphone acceptance requires a stable Apple Development or Developer ID install. Use `scripts/install-development.sh`; never replace `/Applications/Reccy.app` with an ad-hoc bundle.

Code inspection and automated tests are not substitutes for navigating the app. For user-visible or workflow changes, exercise the installed app's actual controls and alternate states: keyboard and pointer entry points, loading and empty states, permission denial, cancellation, retry, failures, window resizing, menus, and cross-workspace behavior. Use the stable-signed installed candidate for identity-sensitive capture acceptance.

For behavior that depends on real hardware, record what was exercised: Mac architecture, display and dynamic range, source type, camera, microphone channel layout, codec, frame rate, duration, app signature, and validator result. Preserve useful evidence; do not claim an unavailable fixture passed.

## Documentation responsibilities

Update documentation in the same change when behavior or operator expectations move:

- `README.md` for user-visible capability, setup, or support status.
- `Documentation/ARCHITECTURE.md` for pipeline, concurrency, persistence, privacy, or format decisions.
- `Documentation/RELEASE_NOTES.md` for release-visible fixes and features. Its version heading must match `MARKETING_VERSION`.
- `Documentation/RELEASING.md` and release scripts together when a distribution invariant changes.

Keep documentation factual and durable. Distinguish implemented behavior, automated coverage, locally observed hardware acceptance, and work that still needs an external fixture.

## Release safety

Release operations have materially different authority levels:

- `scripts/release.sh prepare` is a local, non-publishing rehearsal. It builds and validates the artifact graph but does not contact Apple's notary service or create a GitHub release.
- `scripts/release.sh finalize` contacts Apple, requires the exact clean `v<MARKETING_VERSION>` tag, and produces notarized publishable artifacts.
- Pushing a tag or publishing a GitHub release changes external state.

Do not finalize, notarize, tag, push, publish, enable release automation, rotate credentials, or replace active release outputs unless the user explicitly requests that action. Never expose Developer ID material, Sparkle private keys, App Store Connect credentials, Keychain secrets, or notarization credentials in logs or commits.

A release candidate is not production-ready until all applicable gates are true:

- Version and build metadata are intentional and release notes match.
- The full repository verification passes on Apple silicon and Intel CI.
- The exact candidate is universal, correctly entitled, timestamp-signed, and identified by checksums.
- The signed installed app passes the relevant capture, permission, recovery, editor, export, accessibility, and update acceptance matrix.
- Media outputs pass structural validation, not just visual playback.
- Final artifacts are notarized and stapled, Gatekeeper accepts them, Sparkle verifies the archive/feed signatures, and release evidence identifies the exact source commit.
- Any hardware or environment acceptance gap is written down rather than inferred away.

## Handoff expectations

At completion, summarize the outcome first, then list changed files, verification results, and remaining external gaps. Do not say a task is complete when tests are failing, a required artifact is stale, the exact signed candidate was not exercised, or an external dependency still blocks the requested outcome.

# Editor essentials audit for Reccy 0.3.6

This audit compares Reccy's editor with the essential interactions users expect from a focused professional macOS screen-recording editor. It intentionally favors durable, release-sized changes over a broad nonlinear-editor feature list.

## Existing before 0.3.6

- Frame-accurate ruler seeking, playback stepping, pointer scrubbing, and timeline timecode.
- Magnetic single-clip reorder plus boundary/playhead snapping.
- Leading and trailing trim, selected-clip split, all-track split, ordinary delete, and explicit close-gap ripple delete.
- Optional linked A/V movement and trim without flattening independent tracks.
- Native undo/redo, keyboard nudging, VoiceOver custom actions, source-aligned transcript projection, captions, voiceover, imported media, editable gaps, overlays, and mouse-follow zoom.
- Atomic project persistence and shared AVFoundation preview/Library/export composition.

## Implemented for 0.3.6

- Standard Mac multi-selection: Command toggle, anchored Shift range, additive Command-Shift range, responder-chain Command-A, plain-click replacement, and empty-space clearing.
- Rigid grouped move and grouped delete confirmation with one undo transaction, no relative drift, no crossing before time zero, and lane-local collision bounds.
- Direction-aware playhead follow that yields to direct navigation, selection, scrubbing, zoom, and paused playback.
- Dynamic zoom-to-fit derived from project duration and the current clip viewport rather than a fixed minimum.
- Persisted speed, reverse, fades, and normalized video crop/size with one mapping across preview, transcript/caption timing, undo, project reload, and export.
- Visible timeline badges plus spoken selection/effect state, a native effects menu, and a discoverable Video inspector.

## Deliberately deferred

- **Arbitrary time-range selection:** Reccy's operations currently act on whole clips or the playhead. A real range model must coordinate media, captions, effects, and ripple semantics; a decorative drag rectangle would be misleading.
- **Global ripple/non-ripple editing modes:** Close Gap remains the explicit ripple command, while move, trim, delete, and speed have documented local behavior. A persistent mode would need unmistakable toolbar/menu state and broader collision tests to avoid destructive surprises.
- **Roll, slip, slide, and multi-edge trim:** Useful for a general-purpose NLE, but lower value than reliable clip grouping, effects, and screen-recording-specific zoom/caption workflows in this release.
- **Transitions, keyframes, effect stacks, and presets:** The format-7 effect model is extensible, but shipping placeholder controls or flattening generated intermediates would violate source fidelity. Future effects should add typed parameters and matching preview/export tests.
- **Nested groups and compound clips:** Current multi-selection is transient and native. Persisted compound clips introduce ownership, transcript, audio-mix, and source-master questions that need a separate design.
- **Multicam synchronization and proxy relinking:** Reccy preserves native screen/camera tracks and bounded still/reverse-audio derivatives; a general proxy or multicam system is beyond a release-sized screen-recorder editor increment.

These deferrals preserve a clear contract: every visible command in 0.3.6 is fully reversible, keyboard and accessibility reachable, and implemented consistently across the saved project and rendered delivery.

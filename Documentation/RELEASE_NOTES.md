# Reccy 0.3.2

This production-readiness release continues Reccy's native macOS polish and reliability work:

- Gives every global-shortcut recorder a unique assistive label so VoiceOver users can identify the action they are assigning.
- Makes the Editor camera overlay fully operable with VoiceOver actions for selection, movement, aspect-preserving sizing, and reset instead of requiring pointer-only dragging.
- Gives remaining icon-only folder, search, and transcript-export controls explicit spoken names, and removes the duplicated app name from update status.
- Consolidates Monitor recording state, elapsed time, and Pause/Stop controls into one authoritative status card instead of duplicating them in the page header and toolbar.
- Removes the ambiguous duplicate Choose Source footer action and aligns repeated Library command names across the recording row menu and detail pane.
- Removes duplicate Open Reccy and Library actions from the menu-bar panel while retaining their always-visible routes.
- Uses one permission and transcription readiness decision across the main recorder, menu-bar recorder, global shortcut, and Recording menu so blocked captures cannot start through a secondary command path.
- Makes unavailable, empty, recovered, and no-search-result Library states durable and actionable without stale previews or duplicate Finder actions.
- Streamlines the autosaving Editor around one Export action, exposes selected tools and distinct transcript actions to assistive technology, and clarifies transcript-to-caption creation.
- Stops Library and Editor playback clocks when media is paused instead of waking the main actor continuously in idle workspaces.
- Removes the avoidable duplicate-architecture destination warning from local Debug and Release verification.
- Keeps local verification usable while preparing the next version directly from a tagged release commit, without weakening clean release/tag enforcement.
- Verifies screenshots were written before exposing Share, with an atomic native-image fallback when ScreenCaptureKit does not persist its requested file.
- Adds native Undo/Redo coverage across timeline clips, audio controls, camera layout, captions, and voiceover edits.
- Constrains Whisper transcription to the real audio duration, removes padded silence/no-audio placeholders, and sanitizes older sidecars when they are loaded.
- Treats a valid silent transcription as “No speech detected” instead of a failed job, and keeps that neutral result durable across relaunches.
- Renders independent system, microphone, and timeline audio into one validated delivery program so ordinary players cannot silently select only one source.
- Makes direct Library export render the same saved camera layout, edits, captions, and audio mix visible in Library and Editor instead of exporting the raw screen track alone.
- Labels native sharing as a source-recording handoff so it cannot be confused with a rendered delivery export.
- Cleans up startup-only media and recovery metadata after a camera or capture source fails before the first complete video frame, preventing a false interrupted-recording warning while preserving real in-progress writer failures for recovery.
- Preserves a complete, aligned source master when an optional camera stops mid-recording by holding its final frame to the recording boundary and warning the user; an unwriteable camera tail now follows recovery instead of being silently saved with severe track drift.
- Keeps one macOS content-picker observer for the recorder lifetime so repeated source selections and native cancellations continue delivering callbacks instead of eventually leaving the picker workflow waiting forever.
- Requests both ScreenCaptureKit representations for HDR screenshots, reports an actionable limitation instead of silently substituting SDR when macOS provides no HDR image, and keeps the approved source selected if a screenshot-only operation fails.
- Labels non-publishing release manifests as unnotarized rehearsals and records whether their source worktree was clean, preventing rehearsal provenance from being mistaken for a commit-exact final release.

Requires macOS 26 or later. Download the notarized DMG for a standard drag-to-Applications install, or the signed ZIP for Sparkle-compatible deployment. `SHA256SUMS` and `release.json` provide independent artifact integrity and provenance metadata.

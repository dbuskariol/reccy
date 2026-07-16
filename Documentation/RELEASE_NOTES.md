# Reccy 0.3.4

This release expands live capture preparation and non-destructive editing while keeping every source local and independently editable:

- Shows the approved screen, camera, and audio meters during the countdown by preparing one capture session before the writer is armed; countdown samples never enter the recording.
- Adds a dismissible Camera Effects popover to Monitor that reports native Portrait blur and Background Replacement state before opening Apple's authoritative Video Effects panel; Reccy never duplicates segmentation or stores the chosen background.
- Expands mouse-follow zoom to eleven levels from 1.25× through 6× and lets Monitor change magnification during a recording; each change becomes an editable timeline segment at the exact media clock.
- Fixes routed live captions so Apple Speech and WhisperKit publish finalized and in-progress Monitor text before recording ends, with explicit transport errors and protection against a stale session canceling the next recording.
- Adds a saved poster-frame command used consistently by Editor, Library playback, and project-rendered Library thumbnails.
- Imports movies, audio, and images through a native open panel into independent project-owned tracks. Movie audio remains linked but separate, originals are never rewritten, and still images use bounded two-frame proxies regardless of timeline duration.
- Generalizes direct manipulation, keyboard access, VoiceOver actions, undo, preview, and export from camera-only placement to every overlay-video track.
- Restores the Monitor action stack to full-width native controls, keeps its primary actions anchored at the bottom, makes Library recording details use the full content width, prevents the Editor toolbar from clipping into transport, and adds synchronized vertical scrolling for larger track stacks.
- Adds native Library multi-selection with Command-click toggles, Shift-click ranges, Command-Shift additive ranges, Command-A, outside-click deselection, and count-aware batch Trash confirmation. A batch moves every selected recording and owned sidecar as one rollback-capable transaction.
- Removes first-hover overlay churn by keeping resize handles selection-owned and using native macOS pointer styles instead of repeatedly mutating the global cursor.
- Adds regression coverage for live Apple Speech and WhisperKit callbacks, stale-session isolation, granular live zoom changes, poster-frame migration and clamping, linked video/audio import, and real AVFoundation still-image rendering.

Requires macOS 26 or later. Download the notarized DMG for a standard drag-to-Applications install, or the signed ZIP for Sparkle-compatible deployment. `SHA256SUMS` and `release.json` provide independent artifact integrity and provenance metadata.

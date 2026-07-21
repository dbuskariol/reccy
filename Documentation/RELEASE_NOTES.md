# Reccy 0.3.6

This editor release expands Reccy's non-destructive timeline without changing the local-first source-master contract:

- Keeps the playhead visible during forward or reverse playback with editor-style edge margins, while pausing automatic follow after manual navigation, selection, scrubbing, or zooming.
- Derives the timeline's minimum zoom from the current project duration and clip viewport, so the complete project fits after imports, edits, and window resizing without imposing a fixed lower limit.
- Adds native multi-clip selection: Command-click toggles, Shift-click extends from a stable anchor, Command-Shift adds a range, Command-A selects the timeline scope, and empty-space clicks clear the selection. Selected clips move as one rigid group, remain clear of time zero and neighbouring media, delete through one count-aware confirmation, and participate coherently in undo, keyboard, and VoiceOver paths.
- Adds persisted per-clip 0.25×, 0.5×, 1×, 2×, and 4× speed, forward/reverse playback, and fade-in/fade-out. Preview, transcript projection, saved captions, mouse-follow effects, poster time, timeline duration, linked audio/video, and export share one source-to-timeline mapping.
- Adds a native Video inspector for normalized source cropping and centered 0.25×–4× sizing. Adjustments are reversible project parameters applied identically by AVFoundation preview and export; source files are never rewritten.
- Uses sample-accurate, bounded-memory PCM reversal for audio and frame-ordered native composition for video. Reverse audio derivatives live in a capped local cache and remain disposable rather than becoming project source media.
- Fixes application capture so macOS's purple Share action reliably delivers the approved initial filter to Reccy. Source approval remains entirely inside `SCContentSharingPicker`, and the picker is deactivated before recording starts so it cannot mutate an active capture stream.
- Lets users drag the live camera overlay away from important screen content before or during recording, with arrow-key movement, VoiceOver actions, edge clamping, and a native reset command. The saved normalized center becomes the recording's aspect-aware Editor, Library, and export default while the camera master remains an independent source track.
- Renames the prominent live action to Finish and adds a quieter Cancel path to Monitor, Record, and the menu bar, with explicit recording names retained in the Recording menu and accessibility labels. The native confirmation keeps Keep Recording as the default safe choice, and confirmed discard shuts down capture before removing only that session's staged artifacts without adding a Library item.
- Adds deterministic selection, fit, time-mapping, live-camera placement, persistence, and migration tests plus real AVFoundation reverse, crop, fade, audio-sample, camera-composition, and synchronized export coverage.

Requires macOS 26 or later. Download the notarized DMG for a standard drag-to-Applications install, or the signed ZIP for Sparkle-compatible deployment. `SHA256SUMS` and `release.json` provide independent artifact integrity and provenance metadata.

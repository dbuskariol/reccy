# Reccy 0.3.7

This patch release fixes static-screen exports and timeline recovery, and remembers the last Portion area, without changing Reccy's local-first source-master contract:

- Fixes the persistent loading preview after the last timeline clips are deleted. Empty projects now show an explicit state in Editor and Library, remain undoable, and reject empty exports with recovery guidance.
- Adds Editor > Reset Edits to restore original recording tracks after reopening. Reset backs up the previous edit JSON, retains imported and voiceover media, and is itself undoable within the current session; unsupported-project recovery uses the same non-destructive path.
- Renames Close Gap to Delete and Close Gap and confirms its all-track deletion scope. Split All selects the actual newly split right-hand clip, including splits very close to time zero.
- Fixes exports that turned black after the first moments when a clip ended during a long stretch where the recorded screen didn't change. Recordings now write the last screen frame at each of ScreenCaptureKit's idle-frame times while nothing on screen changes, so the screen track keeps its frame rate, and recording start and resume no longer wait for the screen to change; and export validation rejects any delivery whose picture stops before the timeline does instead of saving a mostly black file. Recordings made before this fix keep their source media; extend or move such a clip's end to where the screen changes before exporting.
- Remembers the last Portion area like QuickTime Player. Choosing Portion again reopens the overlay with the previous rectangle on the same display, ready to confirm with Return or adjust; a display that has become smaller keeps the area inside its bounds.

Requires macOS 26 or later. Download the notarized DMG for a standard drag-to-Applications install, or the signed ZIP for Sparkle-compatible deployment. `SHA256SUMS` and `release.json` provide independent artifact integrity and provenance metadata.

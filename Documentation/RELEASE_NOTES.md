# Reccy 0.3.1

This maintenance release polishes Reccy's native macOS workspace and caption workflow:

- Makes the sidebar a true layout participant so every page expands and contracts without hiding controls or content.
- Uses native adjustable split views for Library, Monitor, Editor preview, timeline, and inspector regions, with responsive full-width content, persistent sizing, precise one-point separators, and forgiving 14-point drag targets.
- Fixes Monitor's active layout and sidebar interaction, including constrained window sizes.
- Places direct, consistently sized timeline commands above the timeline, keeps borderless zoom controls pinned at the far right, and restores Save and Export to the window's trailing toolbar.
- Keeps each caption visible from its detected start until the next cue begins in Editor preview, Library playback, and exported video.
- Adds a dedicated caption timeline lane whose held ranges can be selected, dragged, nudged by frame, edited, added, and removed non-destructively.
- Mounts enabled caption overlays on first load so captions no longer require an off/on toggle before appearing.

Requires macOS 26 or later. Download the notarized DMG for a standard drag-to-Applications install, or the signed ZIP for Sparkle-compatible deployment. `SHA256SUMS` and `release.json` provide independent artifact integrity and provenance metadata.

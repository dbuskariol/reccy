# Reccy 0.3.3

This focused production-readiness update makes selected-source geometry consistent from live capture through final delivery:

- Fits application capture to the selected process's visible windows on the approved display instead of recording a display-sized black canvas with the application offset inside it.
- Uses one canonical source rectangle for output dimensions, Monitor, screenshots, saved media, Library and Editor playback, export, and mouse-follow zoom.
- Restores a true identity transform whenever live mouse-follow zoom is off, preventing the ordinary 1× preview from remaining translated or clipped by its last pointer position.
- Maps recorded mouse-follow motion into the exact application crop encoded by the source recording, so the editable effect targets the same content shown live.
- Preserves the camera device's negotiated native aspect ratio by configuring its writer track from the first delivered pixel buffer, avoiding stretched external-camera video.
- Adds regression coverage for display, application, window, and portion extents, application mouse mapping, live zoom reset, and active zoom positioning.
- Passes signed large-monitor application-capture acceptance across Monitor, saved HEVC media, Library, Editor, and the editable Mouse Zoom effect, plus native 1920×1080 external-camera aspect acceptance.

Requires macOS 26 or later. Download the notarized DMG for a standard drag-to-Applications install, or the signed ZIP for Sparkle-compatible deployment. `SHA256SUMS` and `release.json` provide independent artifact integrity and provenance metadata.

# Reccy 0.2.2

This patch makes transcription, recording finalization, and separate-camera playback substantially more reliable and understandable:

- Fixes Apple Speech and WhisperKit transcription across independent system-audio and microphone tracks, including recordings where only one source contains recognizable speech.
- Prepares the selected on-device transcription engine before capture and defaults new WhisperKit users to its fastest Tiny model while preserving existing model choices.
- Saves the screen, camera, and audio tracks before post-recording transcription continues in the Library, with visible progress instead of a blocking finishing state.
- Drains native screen and camera sample queues before writer completion to prevent recordings from hanging during finalization.
- Composites the separate camera track in Library playback using the same movable, resizable layout as the editor, including saved camera placement.
- Identifies camera recordings from the first frame while preserving the camera track's true first-sample timestamp for accurate synchronization.
- Makes the Monitor's Stop and Pause controls larger, full-width, and bottom-aligned, and clarifies that the first live transcript words can take a moment to appear.

Requires macOS 26 or later. Download the notarized DMG for a standard drag-to-Applications install, or the signed ZIP for Sparkle-compatible deployment. `SHA256SUMS` and `release.json` provide independent artifact integrity and provenance metadata.

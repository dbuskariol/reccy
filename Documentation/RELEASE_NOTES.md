# Reccy 0.3.5

This patch release tightens the native Library and capture-source experience introduced in 0.3.4 without changing Reccy's local-first media model:

- Restores Command-A through the macOS responder chain when the recording browser is active, while preserving normal Select All behavior inside the Library search field.
- Keeps Command-click, Shift-click, and Command-Shift selection native, clears recording selections on a plain click outside the browser, and retains the current preview so non-selection controls remain usable.
- Keeps single-recording deletion unchanged and presents a count-aware native confirmation before moving multiple recordings and their owned sidecars to the Trash.
- Uses source-specific system-picker prompts for displays, applications, and windows, avoiding awkward or ambiguous capture guidance while leaving source approval entirely with macOS.
- Revalidates the complete 140-test host suite, synthesized Apple Speech and WhisperKit live/post-recording paths, and the universal Apple-silicon/Intel Release build.

Requires macOS 26 or later. Download the notarized DMG for a standard drag-to-Applications install, or the signed ZIP for Sparkle-compatible deployment. `SHA256SUMS` and `release.json` provide independent artifact integrity and provenance metadata.

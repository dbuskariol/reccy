import AppKit
import AVFoundation
import Foundation

@MainActor
final class RecordingLibrary: ObservableObject {
    @Published private(set) var recordings: [RecordingItem] = []
    @Published private(set) var directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        ensureDirectoryExists()
        refresh()
    }

    func setDirectory(_ url: URL) {
        guard directoryURL != url else { return }
        directoryURL = url
        ensureDirectoryExists()
        refresh()
    }

    func refresh() {
        ensureDirectoryExists()

        let keys: Set<URLResourceKey> = [
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        recordings = urls.compactMap { url in
            guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile != false else { return nil }
            return RecordingItem(
                url: url,
                createdAt: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                fileSize: Int64(values?.fileSize ?? 0),
                duration: 0
            )
        }
        .sorted { $0.createdAt > $1.createdAt }

        Task { await loadDurations() }
    }

    func delete(_ item: RecordingItem) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        recordings.removeAll { $0.id == item.id }
    }

    func reveal(_ item: RecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func revealDirectory() {
        NSWorkspace.shared.open(directoryURL)
    }

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func loadDurations() async {
        for index in recordings.indices {
            let asset = AVURLAsset(url: recordings[index].url)
            guard let duration = try? await asset.load(.duration) else { continue }
            recordings[index].duration = max(0, duration.seconds)
        }
    }
}

import AppKit
import AVFoundation
import Foundation
import QuickLookThumbnailing

enum RecordingLibraryAvailability: Equatable, Sendable {
    case available
    case unavailable(message: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

@MainActor
final class RecordingLibrary: ObservableObject {
    @Published private(set) var recordings: [RecordingItem] = []
    @Published private(set) var directoryURL: URL
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    @Published private(set) var recoveryNotice: RecordingRecoveryNotice?
    @Published private(set) var availability: RecordingLibraryAvailability = .available
    private var isRecoveringInterruptedRecording = false
    private var recoveryTask: Task<Void, Never>?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        refresh()
    }

    func setDirectory(_ url: URL) {
        guard directoryURL != url else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecoveringInterruptedRecording = false
        recoveryNotice = nil
        directoryURL = url
        refresh()
    }

    func refresh() {
        let keys: Set<URLResourceKey> = [
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]

        let urls: [URL]
        do {
            try ensureDirectoryExists()
            urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            recordings = []
            thumbnails = [:]
            availability = .unavailable(message: error.localizedDescription)
            return
        }
        availability = .available

        recordings = urls.compactMap { url in
            guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile != false else { return nil }
            guard let manifest = loadManifest(for: url),
                  (2...RecordingManifest.currentVersion).contains(manifest.version)
            else { return nil }
            return RecordingItem(
                url: url,
                createdAt: manifest.createdAt,
                fileSize: Int64(values?.fileSize ?? 0),
                duration: 0,
                manifest: manifest,
                pixelWidth: manifest.width,
                pixelHeight: manifest.height,
                frameRate: Double(manifest.frameRate),
                videoCodec: manifest.videoCodec.displayName(isHDR: manifest.isHDR)
            )
        }
        .sorted { $0.createdAt > $1.createdAt }

        thumbnails = thumbnails.filter { url, _ in recordings.contains(where: { $0.url == url }) }
        Task { await loadMediaDetails() }
        recoverInterruptedRecordingIfNeeded()
    }

    func delete(_ item: RecordingItem) throws {
        try delete([item])
    }

    /// Moves the complete artifact graph for every selected recording as one
    /// rollback-capable transaction. The Library is updated only after Finder
    /// accepts the full batch, so a partial failure cannot leave the browser
    /// claiming that only some selected recordings were deleted.
    func delete(_ items: [RecordingItem]) throws {
        var seenItems = Set<URL>()
        let uniqueItems = items.filter { seenItems.insert($0.id).inserted }
        guard !uniqueItems.isEmpty else { return }

        var seenArtifacts = Set<URL>()
        let artifactURLs = uniqueItems
            .flatMap { $0.artifacts.trashOrder }
            .filter { seenArtifacts.insert($0).inserted }
        try RecordingArtifactTrashTransaction.perform(artifactURLs)

        let deletedIDs = Set(uniqueItems.map(\.id))
        recordings.removeAll { deletedIDs.contains($0.id) }
        for item in uniqueItems {
            thumbnails[item.url] = nil
        }
    }

    func reveal(_ item: RecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func revealDirectory() {
        NSWorkspace.shared.open(directoryURL)
    }

    func dismissRecoveryNotice() {
        recoveryNotice = nil
    }

    func revealRecoveryItem() {
        guard let fileURL = recoveryNotice?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func presentNotice(
        kind: RecordingRecoveryNotice.Kind,
        title: String,
        message: String,
        fileURL: URL? = nil
    ) {
        recoveryNotice = RecordingRecoveryNotice(
            kind: kind,
            title: title,
            message: message,
            fileURL: fileURL
        )
    }

    func recoverInterruptedRecordingIfNeeded() {
        guard availability.isAvailable, !isRecoveringInterruptedRecording else { return }
        isRecoveringInterruptedRecording = true
        let directory = directoryURL
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if directoryURL == directory {
                    isRecoveringInterruptedRecording = false
                    recoveryTask = nil
                }
            }
            do {
                guard try RecordingRecoveryJournal.load(from: directory) != nil else { return }

                // A live writer owns this same lease. Wait for it to complete
                // instead of mistaking its necessarily incomplete destination
                // for crash debris. The lease is released by the kernel even
                // if the writer process terminates unexpectedly.
                let lease: RecordingSessionLease
                while true {
                    guard !Task.isCancelled, directoryURL == directory else { return }
                    do {
                        lease = try RecordingSessionLease.acquire(in: directory)
                        break
                    } catch RecordingLeaseError.alreadyHeld {
                        try await Task.sleep(for: .milliseconds(250))
                    }
                }

                guard let journal = try RecordingRecoveryJournal.load(from: directory) else {
                    lease.release()
                    return
                }
                defer { lease.release() }
                let mediaURL = directory.appendingPathComponent(journal.mediaFileName)
                guard !Task.isCancelled, directoryURL == directory else { return }
                guard FileManager.default.fileExists(atPath: mediaURL.path) else {
                    try RecordingRecoveryJournal.remove(from: directory)
                    presentNotice(
                        kind: .warning,
                        title: "Interrupted recording was not found",
                        message: "Reccy cleared stale recovery metadata because its media file no longer exists."
                    )
                    return
                }

                let asset = AVURLAsset(url: mediaURL)
                let isPlayable = (try? await asset.load(.isPlayable)) == true
                let duration = (try? await asset.load(.duration).seconds) ?? 0
                let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                guard !Task.isCancelled, directoryURL == directory else { return }
                if isPlayable, duration.isFinite, duration > 0, !videoTracks.isEmpty {
                    try writeManifest(journal.manifest, for: mediaURL)
                    try RecordingRecoveryJournal.remove(from: directory)
                    refresh()
                    presentNotice(
                        kind: .recovered,
                        title: "Interrupted recording recovered",
                        message: "Reccy validated and restored \(mediaURL.deletingPathExtension().lastPathComponent).",
                        fileURL: mediaURL
                    )
                } else {
                    let partialURL = try moveToUniqueInterruptedURL(mediaURL)
                    try RecordingRecoveryJournal.remove(from: directory)
                    presentNotice(
                        kind: .warning,
                        title: "Interrupted recording needs attention",
                        message: "The file could not be validated as playable. Reccy preserved it as \(partialURL.lastPathComponent) for inspection.",
                        fileURL: partialURL
                    )
                }
            } catch {
                presentNotice(
                    kind: .warning,
                    title: "Recording recovery needs attention",
                    message: error.localizedDescription,
                    fileURL: RecordingRecoveryJournal.url(in: directory)
                )
            }
        }
    }

    func thumbnail(for item: RecordingItem) -> NSImage? {
        thumbnails[item.url]
    }

    func refreshThumbnail(for item: RecordingItem) async {
        let image = await makeThumbnail(item: item)
        guard recordings.contains(where: { $0.id == item.id }) else { return }
        thumbnails[item.url] = image
    }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func loadManifest(for url: URL) -> RecordingManifest? {
        let sidecar = RecordingManifest.sidecarURL(for: url)
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingManifest.self, from: data)
    }

    private func writeManifest(_ manifest: RecordingManifest, for mediaURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: RecordingManifest.sidecarURL(for: mediaURL), options: [.atomic])
    }

    private func moveToUniqueInterruptedURL(_ mediaURL: URL) throws -> URL {
        let directory = mediaURL.deletingLastPathComponent()
        let stem = mediaURL.deletingPathExtension().lastPathComponent
        let fileExtension = mediaURL.pathExtension
        var destination = directory
            .appendingPathComponent("\(stem) — Interrupted")
            .appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory
                .appendingPathComponent("\(stem) — Interrupted \(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        try FileManager.default.moveItem(at: mediaURL, to: destination)
        return destination
    }

    private func loadMediaDetails() async {
        let urls = recordings.map(\.url)
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []

            var width = 0
            var height = 0
            var frameRate: Double = 0
            var codec: String?
            if let videoTrack = videoTracks.first {
                if let naturalSize = try? await videoTrack.load(.naturalSize),
                   let transform = try? await videoTrack.load(.preferredTransform)
                {
                    let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
                    width = Int(abs(transformed.width).rounded())
                    height = Int(abs(transformed.height).rounded())
                }
                frameRate = Double((try? await videoTrack.load(.nominalFrameRate)) ?? 0)
                if let descriptions = try? await videoTrack.load(.formatDescriptions),
                   let description = descriptions.first
                {
                    codec = Self.codecName(CMFormatDescriptionGetMediaSubType(description))
                }
            }

            guard let index = recordings.firstIndex(where: { $0.url == url }) else { continue }
            recordings[index].duration = max(0, duration)
            if recordings[index].pixelWidth == 0 { recordings[index].pixelWidth = width }
            if recordings[index].pixelHeight == 0 { recordings[index].pixelHeight = height }
            if recordings[index].frameRate == 0 { recordings[index].frameRate = frameRate }
            if recordings[index].videoCodec == nil { recordings[index].videoCodec = codec }
            recordings[index].audioTrackIDs = audioTracks.map(\.trackID)

            if !videoTracks.isEmpty {
                await refreshThumbnail(for: recordings[index])
            }
        }
    }

    /// Library artwork is rendered from the same non-destructive composition
    /// and saved poster time used by Library and Editor playback. Quick Look is
    /// retained only as a recovery fallback for a malformed project.
    private func makeThumbnail(item: RecordingItem) async -> NSImage? {
        do {
            let loaded = try await RecordingTimelineProjectLoader.load(for: item)
            let build = try await TimelineCompositionBuilder.build(loaded.project)
            guard !build.composition.tracks(withMediaType: .video).isEmpty else {
                return await makeQuickLookThumbnail(url: item.url)
            }
            let generator = AVAssetImageGenerator(asset: build.composition)
            generator.videoComposition = TimelineCaptionVideoRenderer.applying(
                loaded.project.captionTrack,
                to: build.videoComposition,
                projectDuration: loaded.project.duration
            )
            generator.maximumSize = CGSize(width: 640, height: 360)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let time = CMTime(
                seconds: loaded.project.effectivePosterFrameTime,
                preferredTimescale: 600
            )
            let image = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CGImage, Error>) in
                generator.generateCGImageAsynchronously(for: time) { image, _, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile))
                    }
                }
            }
            return NSImage(cgImage: image, size: .zero)
        } catch {
            return await makeQuickLookThumbnail(url: item.url)
        }
    }

    private func makeQuickLookThumbnail(url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 640, height: 360),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request)
            .nsImage
    }

    private static func codecName(_ subtype: FourCharCode) -> String {
        switch subtype {
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_AppleProRes422: return "ProRes 422"
        case kCMVideoCodecType_AppleProRes4444: return "ProRes 4444"
        default:
            let scalars = [24, 16, 8, 0].compactMap { shift in
                UnicodeScalar(Int((subtype >> shift) & 0xff))
            }
            return String(String.UnicodeScalarView(scalars))
        }
    }
}

/// Moves a recording's complete owned bundle to Trash with rollback. Finder's
/// Trash API operates on one URL at a time, so a failure restores every item
/// already moved instead of leaving media, metadata, and editor state split.
nonisolated enum RecordingArtifactTrashTransaction {
    struct IncompleteRollbackError: LocalizedError {
        let originalError: Error
        let rollbackErrors: [Error]

        var errorDescription: String? {
            let rollbackSummary = rollbackErrors
                .map(\.localizedDescription)
                .joined(separator: " ")
            return """
            Reccy couldn’t move the complete recording to Trash and couldn’t fully restore it. \
            \(originalError.localizedDescription) \(rollbackSummary)
            """
        }
    }

    static func perform(
        _ urls: [URL],
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        trash: (URL) throws -> URL = trashWithFileManager,
        restore: (URL, URL) throws -> Void = restoreWithFileManager
    ) throws {
        var moved: [(original: URL, trashed: URL)] = []

        do {
            for url in urls where fileExists(url) {
                moved.append((original: url, trashed: try trash(url)))
            }
        } catch {
            var rollbackErrors: [Error] = []
            for item in moved.reversed() {
                do {
                    try restore(item.trashed, item.original)
                } catch {
                    rollbackErrors.append(error)
                }
            }
            guard rollbackErrors.isEmpty else {
                throw IncompleteRollbackError(
                    originalError: error,
                    rollbackErrors: rollbackErrors
                )
            }
            throw error
        }
    }

    private static func trashWithFileManager(_ url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL = resultingURL as URL? else {
            throw CocoaError(.fileWriteUnknown)
        }
        return resultingURL
    }

    private static func restoreWithFileManager(_ trashedURL: URL, _ originalURL: URL) throws {
        try FileManager.default.moveItem(at: trashedURL, to: originalURL)
    }
}

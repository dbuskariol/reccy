import AppKit
import AVFoundation
import Foundation
import QuickLookThumbnailing

@MainActor
final class RecordingLibrary: ObservableObject {
    @Published private(set) var recordings: [RecordingItem] = []
    @Published private(set) var directoryURL: URL
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    @Published private(set) var recoveryNotice: RecordingRecoveryNotice?
    private var isRecoveringInterruptedRecording = false
    private var recoveryTask: Task<Void, Never>?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        ensureDirectoryExists()
        refresh()
        recoverInterruptedRecordingIfNeeded()
    }

    func setDirectory(_ url: URL) {
        guard directoryURL != url else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecoveringInterruptedRecording = false
        directoryURL = url
        ensureDirectoryExists()
        refresh()
        recoverInterruptedRecordingIfNeeded()
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
            guard let manifest = loadManifest(for: url),
                  manifest.version == RecordingManifest.currentVersion
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
                videoCodec: manifest.isHDR ? "HEVC 10-bit" : nil
            )
        }
        .sorted { $0.createdAt > $1.createdAt }

        thumbnails = thumbnails.filter { url, _ in recordings.contains(where: { $0.url == url }) }
        Task { await loadMediaDetails() }
    }

    func delete(_ item: RecordingItem) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        let sidecar = RecordingManifest.sidecarURL(for: item.url)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try? FileManager.default.trashItem(at: sidecar, resultingItemURL: nil)
        }
        recordings.removeAll { $0.id == item.id }
        thumbnails[item.url] = nil
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
        guard !isRecoveringInterruptedRecording else { return }
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

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
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

            if !videoTracks.isEmpty,
               let thumbnail = await makeThumbnail(url: url)
            {
                thumbnails[url] = thumbnail
            }
        }
    }

    private func makeThumbnail(url: URL) async -> NSImage? {
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

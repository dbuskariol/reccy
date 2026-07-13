import AppKit
import AVFoundation
import Foundation
import QuickLookThumbnailing

@MainActor
final class RecordingLibrary: ObservableObject {
    @Published private(set) var recordings: [RecordingItem] = []
    @Published private(set) var directoryURL: URL
    @Published private(set) var thumbnails: [URL: NSImage] = [:]

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

    private func loadMediaDetails() async {
        let urls = recordings.map(\.url)
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []

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

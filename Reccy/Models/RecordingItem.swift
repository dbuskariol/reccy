import Foundation

struct RecordingItem: Identifiable, Hashable, Sendable {
    let url: URL
    let createdAt: Date
    let fileSize: Int64
    var duration: TimeInterval
    let manifest: RecordingManifest
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var frameRate: Double = 0
    var videoCodec: String?
    var audioTrackIDs: [Int32] = []

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }
    var artifacts: RecordingArtifacts { RecordingArtifacts(mediaURL: url) }

    var formattedDuration: String {
        Duration.seconds(duration).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var sourceName: String {
        manifest.source.name
    }

    var sourceKindTitle: String {
        manifest.source.kind.title
    }

    var formattedResolution: String? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    var formattedFrameRate: String? {
        let value = frameRate > 0 ? frameRate : Double(manifest.frameRate)
        guard value > 0 else { return nil }
        return "\(Int(value.rounded())) fps"
    }

    var audioSummary: String {
        switch (manifest.includesSystemAudio, manifest.includesMicrophone) {
        case (true, true): "System + Microphone"
        case (true, false): "System Audio"
        case (false, true): manifest.microphoneName ?? "Microphone"
        case (false, false): "No Audio"
        }
    }

    var audioDetail: String {
        guard !audioTrackIDs.isEmpty else { return audioSummary }
        let trackLabel = audioTrackIDs.count == 1 ? "1 editable track" : "\(audioTrackIDs.count) editable tracks"
        return "\(audioSummary) · \(trackLabel)"
    }
}

/// Every file Reccy owns for one recording. Keeping these paths beside the
/// recording identity prevents Library cleanup and Editor storage from
/// disagreeing about which project belongs to which source file.
struct RecordingArtifacts: Equatable, Sendable {
    let mediaURL: URL

    var manifestURL: URL {
        RecordingManifest.sidecarURL(for: mediaURL)
    }

    var projectPackageURL: URL {
        mediaURL
            .deletingLastPathComponent()
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(
                "\(mediaURL.deletingPathExtension().lastPathComponent).reccyproject",
                isDirectory: true
            )
    }

    /// Metadata is moved first and the media last. A failed media operation can
    /// therefore restore the smaller owned artifacts before surfacing the error.
    var trashOrder: [URL] {
        [projectPackageURL, manifestURL, mediaURL]
    }
}

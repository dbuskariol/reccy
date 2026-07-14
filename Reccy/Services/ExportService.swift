@preconcurrency import AVFoundation
import Foundation

nonisolated enum ExportPresetCategory: String, CaseIterable, Identifiable, Sendable {
    case efficient
    case compatible
    case professional
    case audio

    var id: Self { self }

    var title: String {
        switch self {
        case .efficient: "Efficient"
        case .compatible: "Compatible"
        case .professional: "Professional"
        case .audio: "Audio"
        }
    }
}

nonisolated enum ExportPreset: String, CaseIterable, Identifiable, Sendable {
    case hevcBest
    case hevc4K
    case hevc1080
    case h264Best
    case h2644K
    case h2641080
    case h264720
    case proRes422
    case proRes4444
    case audioM4A

    var id: Self { self }

    var title: String {
        switch self {
        case .hevcBest: "HEVC · Source Resolution"
        case .hevc4K: "HEVC · Up to 4K"
        case .hevc1080: "HEVC · Up to 1080p"
        case .h264Best: "H.264 · Source Resolution"
        case .h2644K: "H.264 · Up to 4K"
        case .h2641080: "H.264 · Up to 1080p"
        case .h264720: "H.264 · Up to 720p"
        case .proRes422: "Apple ProRes 422"
        case .proRes4444: "Apple ProRes 4444"
        case .audioM4A: "Audio Only · M4A"
        }
    }

    var detail: String {
        switch self {
        case .hevcBest: "Best balance of sharp detail, dynamic range, and file size"
        case .hevc4K: "Efficient high-resolution delivery"
        case .hevc1080: "Recommended for everyday sharing"
        case .h264Best: "Broad playback compatibility at source resolution"
        case .h2644K: "Compatible high-resolution delivery"
        case .h2641080: "Compatible Full HD delivery"
        case .h264720: "Compact web and messaging delivery"
        case .proRes422: "High-quality editing and finishing master"
        case .proRes4444: "Maximum-quality interchange and compositing master"
        case .audioM4A: "Compact AAC mix without video"
        }
    }

    var category: ExportPresetCategory {
        switch self {
        case .hevcBest, .hevc4K, .hevc1080: .efficient
        case .h264Best, .h2644K, .h2641080, .h264720: .compatible
        case .proRes422, .proRes4444: .professional
        case .audioM4A: .audio
        }
    }

    var systemImage: String {
        switch category {
        case .efficient: "leaf"
        case .compatible: "play.rectangle.on.rectangle"
        case .professional: "film.stack"
        case .audio: "waveform"
        }
    }

    var isRecommended: Bool { self == .hevc1080 }
    var includesVideo: Bool { self != .audioM4A }
    var requiresAudio: Bool { self == .audioM4A }

    var avPresetName: String {
        switch self {
        case .hevcBest: AVAssetExportPresetHEVCHighestQuality
        case .hevc4K: AVAssetExportPresetHEVC3840x2160
        case .hevc1080: AVAssetExportPresetHEVC1920x1080
        case .h264Best: AVAssetExportPresetHighestQuality
        case .h2644K: AVAssetExportPreset3840x2160
        case .h2641080: AVAssetExportPreset1920x1080
        case .h264720: AVAssetExportPreset1280x720
        case .proRes422: AVAssetExportPresetAppleProRes422LPCM
        case .proRes4444: AVAssetExportPresetAppleProRes4444LPCM
        case .audioM4A: AVAssetExportPresetAppleM4A
        }
    }

    var fileType: AVFileType {
        switch self {
        case .proRes422, .proRes4444: .mov
        case .audioM4A: .m4a
        default: .mp4
        }
    }

    var fileExtension: String {
        switch fileType {
        case .mov: "mov"
        case .m4a: "m4a"
        default: "mp4"
        }
    }

    var enablesMultiPass: Bool {
        switch self {
        case .hevcBest, .h264Best, .proRes422, .proRes4444: true
        default: false
        }
    }
}

struct ExportSource: Identifiable {
    let id = UUID()
    let name: String
    let asset: AVAsset
    let sourceURL: URL?
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?

    init(
        name: String,
        asset: AVAsset,
        sourceURL: URL? = nil,
        videoComposition: AVVideoComposition? = nil,
        audioMix: AVAudioMix? = nil
    ) {
        self.name = name
        self.asset = asset
        self.sourceURL = sourceURL
        self.videoComposition = videoComposition
        self.audioMix = audioMix
    }
}

nonisolated enum ExportProgressPhase: Equatable, Sendable {
    case preparing
    case waiting
    case exporting
    case validating
    case finishing

    var title: String {
        switch self {
        case .preparing: "Preparing export…"
        case .waiting: "Waiting for the media encoder…"
        case .exporting: "Exporting…"
        case .validating: "Validating the finished file…"
        case .finishing: "Finishing…"
        }
    }
}

nonisolated struct ExportProgressUpdate: Equatable, Sendable {
    let phase: ExportProgressPhase
    let fractionCompleted: Double?
}

nonisolated struct ExportResult: Equatable, Sendable {
    let url: URL
    let duration: TimeInterval
    let fileSize: Int64
    let videoTrackCount: Int
    let audioTrackCount: Int
}

nonisolated enum ExportServiceError: LocalizedError, Equatable {
    case unsupportedPreset
    case sourceWouldBeOverwritten
    case missingVideo
    case missingAudio
    case invalidOutput
    case durationMismatch(expected: TimeInterval, actual: TimeInterval)
    case capacityUnavailable
    case insufficientCapacity(availableBytes: Int64, requiredBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .unsupportedPreset:
            return "This export preset isn’t compatible with the current recording or timeline."
        case .sourceWouldBeOverwritten:
            return "Choose a different destination. Reccy never overwrites the source recording during export."
        case .missingVideo:
            return "The finished export doesn’t contain the expected video track. The destination was left unchanged."
        case .missingAudio:
            return "This recording doesn’t contain audio that can be exported with the selected preset."
        case .invalidOutput:
            return "The finished export could not be validated as playable. The destination was left unchanged."
        case let .durationMismatch(expected, actual):
            return "The finished export has an unexpected duration (expected \(Self.time(expected)), received \(Self.time(actual))). The destination was left unchanged."
        case .capacityUnavailable:
            return "Reccy couldn’t verify free space at the export destination. Choose another folder or try again."
        case let .insufficientCapacity(available, required):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Not enough free space to export safely. \(formatter.string(fromByteCount: available)) is available; Reccy requires \(formatter.string(fromByteCount: required)) including its filesystem reserve."
        }
    }

    private static func time(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
    }
}

@MainActor
struct ExportService {
    static let filesystemReserveBytes: Int64 = 512 * 1_024 * 1_024
    static let minimumWorkingBytes: Int64 = 256 * 1_024 * 1_024

    func compatiblePresets(for source: ExportSource) async -> Set<ExportPreset> {
        let asset = source.asset
        return await withTaskGroup(of: (ExportPreset, Bool).self) { group in
            for preset in ExportPreset.allCases {
                group.addTask {
                    let compatible = await AVAssetExportSession.compatibility(
                        ofExportPreset: preset.avPresetName,
                        with: asset,
                        outputFileType: preset.fileType
                    )
                    return (preset, compatible)
                }
            }

            var result = Set<ExportPreset>()
            for await (preset, compatible) in group where compatible {
                result.insert(preset)
            }
            return result
        }
    }

    func estimatedFileSize(
        source: ExportSource,
        preset: ExportPreset
    ) async throws -> Int64? {
        let session = try await makeSession(source: source, preset: preset)
        return try await estimatedFileSize(
            source: source,
            preset: preset,
            session: session
        )
    }

    private func estimatedFileSize(
        source: ExportSource,
        preset: ExportPreset,
        session: AVAssetExportSession
    ) async throws -> Int64? {
        // Some otherwise-valid professional presets explicitly decline
        // AVFoundation's advisory estimate. That must never block the export;
        // the conservative codec fallback still protects destination capacity.
        let frameworkEstimate = (try? await session.estimatedOutputFileLengthInBytes) ?? 0
        let fallbackEstimate = try await fallbackEstimatedFileSize(source: source, preset: preset)
        let estimate = max(frameworkEstimate, fallbackEstimate)
        return estimate > 0 ? estimate : nil
    }

    func export(
        source: ExportSource,
        destinationURL: URL,
        preset: ExportPreset,
        progress: @escaping @MainActor (ExportProgressUpdate) -> Void = { _ in }
    ) async throws -> ExportResult {
        try Task.checkCancellation()
        let destination = destinationURL.standardizedFileURL
        if let sourceURL = source.sourceURL?.standardizedFileURL,
           sourceURL.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath()
        {
            throw ExportServiceError.sourceWouldBeOverwritten
        }

        let directory = destination.deletingLastPathComponent()
        let fileManager = FileManager.default
        let workDirectory = directory.appendingPathComponent(
            ".reccy-export-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: workDirectory) }

        progress(ExportProgressUpdate(phase: .preparing, fractionCompleted: nil))
        let session = try await makeSession(source: source, preset: preset)
        session.directoryForTemporaryFiles = workDirectory
        let estimate = try await estimatedFileSize(
            source: source,
            preset: preset,
            session: session
        )
        try validateCapacity(estimate: estimate, directory: directory)
        try Task.checkCancellation()

        let stagedURL = workDirectory
            .appendingPathComponent("Export")
            .appendingPathExtension(preset.fileExtension)
        let monitor = Task { @MainActor in
            for await state in session.states(updateInterval: 0.1) {
                guard !Task.isCancelled else { return }
                switch state {
                case .pending:
                    progress(ExportProgressUpdate(phase: .preparing, fractionCompleted: nil))
                case .waiting:
                    progress(ExportProgressUpdate(phase: .waiting, fractionCompleted: nil))
                case let .exporting(exportProgress):
                    progress(ExportProgressUpdate(
                        phase: .exporting,
                        fractionCompleted: exportProgress.fractionCompleted
                    ))
                @unknown default:
                    progress(ExportProgressUpdate(phase: .exporting, fractionCompleted: nil))
                }
            }
        }
        defer { monitor.cancel() }

        try await session.export(to: stagedURL, as: preset.fileType)
        try Task.checkCancellation()
        progress(ExportProgressUpdate(phase: .validating, fractionCompleted: 1))
        let result = try await validateOutput(
            at: stagedURL,
            source: source,
            preset: preset
        )
        try Task.checkCancellation()

        progress(ExportProgressUpdate(phase: .finishing, fractionCompleted: 1))
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: destination)
        }
        return ExportResult(
            url: destination,
            duration: result.duration,
            fileSize: result.fileSize,
            videoTrackCount: result.videoTrackCount,
            audioTrackCount: result.audioTrackCount
        )
    }

    private func makeSession(
        source: ExportSource,
        preset: ExportPreset
    ) async throws -> AVAssetExportSession {
        let compatible = await AVAssetExportSession.compatibility(
            ofExportPreset: preset.avPresetName,
            with: source.asset,
            outputFileType: preset.fileType
        )
        guard compatible,
              let session = AVAssetExportSession(
                  asset: source.asset,
                  presetName: preset.avPresetName
              )
        else { throw ExportServiceError.unsupportedPreset }

        let compatibleFileTypes = await session.compatibleFileTypes
        guard compatibleFileTypes.contains(preset.fileType) else {
            throw ExportServiceError.unsupportedPreset
        }

        session.shouldOptimizeForNetworkUse = preset.fileType == .mp4
        session.allowsParallelizedExport = true
        session.canPerformMultiplePassesOverSourceMediaData = preset.enablesMultiPass
        if preset.includesVideo {
            session.videoComposition = source.videoComposition
        }
        session.audioMix = source.audioMix
        return session
    }

    private func validateCapacity(estimate: Int64?, directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
        guard let available else { throw ExportServiceError.capacityUnavailable }

        let workingBytes = max(Self.minimumWorkingBytes, estimate ?? Self.minimumWorkingBytes)
        let headroom = max(workingBytes / 5, 64 * 1_024 * 1_024)
        let required = Self.filesystemReserveBytes + workingBytes + headroom
        guard available >= required else {
            throw ExportServiceError.insufficientCapacity(
                availableBytes: available,
                requiredBytes: required
            )
        }
    }

    private func fallbackEstimatedFileSize(
        source: ExportSource,
        preset: ExportPreset
    ) async throws -> Int64 {
        let duration = try await source.asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return 0 }
        if preset == .audioM4A {
            return Int64(duration * 256_000 / 8)
        }

        let videoTrack = try await source.asset.loadTracks(withMediaType: .video).first
        guard let videoTrack else { return 0 }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        var width = max(abs(transformed.width), 1)
        var height = max(abs(transformed.height), 1)
        let frameRate = max(Double(try await videoTrack.load(.nominalFrameRate)), 24)

        let maximumSize: CGSize?
        switch preset {
        case .hevc4K, .h2644K: maximumSize = CGSize(width: 3_840, height: 2_160)
        case .hevc1080, .h2641080: maximumSize = CGSize(width: 1_920, height: 1_080)
        case .h264720: maximumSize = CGSize(width: 1_280, height: 720)
        default: maximumSize = nil
        }
        if let maximumSize {
            let scale = min(1, maximumSize.width / width, maximumSize.height / height)
            width *= scale
            height *= scale
        }

        let pixelsPerSecond = width * height * frameRate
        let videoBitsPerSecond: Double
        switch preset {
        case .hevcBest, .hevc4K, .hevc1080:
            videoBitsPerSecond = max(2_000_000, pixelsPerSecond * 0.085)
        case .h264Best, .h2644K, .h2641080, .h264720:
            videoBitsPerSecond = max(3_000_000, pixelsPerSecond * 0.14)
        case .proRes422:
            videoBitsPerSecond = 147_000_000 * pixelsPerSecond / (1_920 * 1_080 * 29.97)
        case .proRes4444:
            videoBitsPerSecond = 330_000_000 * pixelsPerSecond / (1_920 * 1_080 * 29.97)
        case .audioM4A:
            videoBitsPerSecond = 0
        }
        return Int64(duration * (videoBitsPerSecond + 320_000) / 8)
    }

    private func validateOutput(
        at url: URL,
        source: ExportSource,
        preset: ExportPreset
    ) async throws -> ExportResult {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0 else {
            throw ExportServiceError.invalidOutput
        }

        let asset = AVURLAsset(url: url)
        async let isPlayable = asset.load(.isPlayable)
        async let outputDuration = asset.load(.duration)
        async let videoTracks = asset.loadTracks(withMediaType: .video)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)
        guard try await isPlayable else { throw ExportServiceError.invalidOutput }
        let duration = try await outputDuration.seconds
        let videos = try await videoTracks
        let audio = try await audioTracks
        guard duration.isFinite, duration > 0 else { throw ExportServiceError.invalidOutput }
        if preset.includesVideo, videos.isEmpty { throw ExportServiceError.missingVideo }
        if preset.requiresAudio, audio.isEmpty { throw ExportServiceError.missingAudio }

        let expectedDuration = try await source.asset.load(.duration).seconds
        if expectedDuration.isFinite, expectedDuration > 0 {
            let tolerance = max(0.25, expectedDuration * 0.02)
            guard abs(duration - expectedDuration) <= tolerance else {
                throw ExportServiceError.durationMismatch(
                    expected: expectedDuration,
                    actual: duration
                )
            }
        }

        return ExportResult(
            url: url,
            duration: duration,
            fileSize: Int64(fileSize),
            videoTrackCount: videos.count,
            audioTrackCount: audio.count
        )
    }
}

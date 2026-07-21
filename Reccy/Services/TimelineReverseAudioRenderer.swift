@preconcurrency import AVFoundation
import CryptoKit
import Foundation

enum TimelineReverseAudioError: LocalizedError {
    case missingTrack(Int32)
    case unsupportedFormat
    case couldNotRead
    case derivativeTooLarge
    case capacityUnavailable
    case insufficientCapacity(availableBytes: Int64, requiredBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .missingTrack(let trackID):
            return "Reccy couldn’t find audio track \(trackID) for the reverse effect."
        case .unsupportedFormat:
            return "This clip’s audio format can’t be reversed without changing source fidelity."
        case .couldNotRead:
            return "Reccy couldn’t read this clip’s audio for the reverse effect."
        case .derivativeTooLarge:
            return "This reverse-audio clip would exceed Reccy’s 1 GB derived-media limit. Trim it into shorter clips and try again."
        case .capacityUnavailable:
            return "Reccy couldn’t verify free space for reverse-audio processing. Free some space or try again."
        case let .insufficientCapacity(available, required):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Not enough free space to reverse this audio safely. \(formatter.string(fromByteCount: available)) is available; Reccy requires \(formatter.string(fromByteCount: required)) including its filesystem reserve."
        }
    }
}

/// Produces a bounded, local PCM derivative for reverse playback. The cache is
/// never a source of truth: its key includes source identity and range, and it
/// can be removed at any time without touching the recording or project.
actor TimelineReverseAudioRenderer {
    static let shared = TimelineReverseAudioRenderer()

    private let maximumCacheBytes: Int64 = 1_073_741_824
    private let maximumCacheFiles = 32
    private let fileManager = FileManager.default

    func reversedTrack(
        sourceURL: URL,
        sourceTrackID: Int32,
        sourceStart: TimeInterval,
        sourceDuration: TimeInterval
    ) async throws -> URL {
        let directory = try cacheDirectory()
        let key = try cacheKey(
            sourceURL: sourceURL,
            sourceTrackID: sourceTrackID,
            sourceStart: sourceStart,
            sourceDuration: sourceDuration
        )
        let destination = directory.appendingPathComponent(key).appendingPathExtension("caf")
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return destination
        }

        let forward = directory
            .appendingPathComponent("Forward \(UUID().uuidString)")
            .appendingPathExtension("caf")
        let staging = directory
            .appendingPathComponent("Reverse \(UUID().uuidString)")
            .appendingPathExtension("caf")
        defer {
            try? fileManager.removeItem(at: forward)
            try? fileManager.removeItem(at: staging)
        }

        let format = try await writeForwardPCM(
            sourceURL: sourceURL,
            sourceTrackID: sourceTrackID,
            sourceStart: sourceStart,
            sourceDuration: sourceDuration,
            destination: forward
        )
        try writeReversedPCM(source: forward, destination: staging, format: format)
        try fileManager.moveItem(at: staging, to: destination)
        trimCache(in: directory, preserving: destination)
        return destination
    }

    private func writeForwardPCM(
        sourceURL: URL,
        sourceTrackID: Int32,
        sourceStart: TimeInterval,
        sourceDuration: TimeInterval,
        destination: URL
    ) async throws -> AVAudioFormat {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first(where: { $0.trackID == sourceTrackID }) else {
            throw TimelineReverseAudioError.missingTrack(sourceTrackID)
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else {
            throw TimelineReverseAudioError.unsupportedFormat
        }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sourceFormat.sampleRate,
                  channels: sourceFormat.channelCount,
                  interleaved: false
        )
        else { throw TimelineReverseAudioError.unsupportedFormat }
        try validateCapacity(
            directory: destination.deletingLastPathComponent(),
            format: format,
            sourceDuration: sourceDuration
        )

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, sourceStart), preferredTimescale: 48_000),
            duration: CMTime(seconds: max(sourceDuration, 0), preferredTimescale: 48_000)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TimelineReverseAudioError.couldNotRead }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? TimelineReverseAudioError.couldNotRead
        }

        do {
            let file = try AVAudioFile(forWriting: destination, settings: format.settings)
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let packet = TimedAudioBuffer(
                    buffer: try TranscriptionAudioReader.pcmBuffer(from: sampleBuffer),
                    startTime: sampleBuffer.presentationTimeStamp
                )
                let converted = try TranscriptionAudioReader.convert(packet, to: format)
                try file.write(from: converted.buffer)
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? TimelineReverseAudioError.couldNotRead
        }
        return format
    }

    private func writeReversedPCM(
        source: URL,
        destination: URL,
        format: AVAudioFormat
    ) throws {
        let input = try AVAudioFile(forReading: source)
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        var remaining = input.length
        let chunkCapacity: AVAudioFrameCount = 32_768

        while remaining > 0 {
            if Task.isCancelled { throw CancellationError() }
            let requested = AVAudioFrameCount(min(AVAudioFramePosition(chunkCapacity), remaining))
            input.framePosition = remaining - AVAudioFramePosition(requested)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: requested) else {
                throw TimelineReverseAudioError.unsupportedFormat
            }
            try input.read(into: buffer, frameCount: requested)
            guard let channels = buffer.floatChannelData else {
                throw TimelineReverseAudioError.unsupportedFormat
            }
            let frameCount = Int(buffer.frameLength)
            for channelIndex in 0..<Int(format.channelCount) {
                let channel = channels[channelIndex]
                for index in 0..<(frameCount / 2) {
                    let opposite = frameCount - index - 1
                    let value = channel[index]
                    channel[index] = channel[opposite]
                    channel[opposite] = value
                }
            }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    private func cacheDirectory() throws -> URL {
        let base = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("com.reccy.mac", isDirectory: true)
            .appendingPathComponent("ReverseAudio", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func validateCapacity(
        directory: URL,
        format: AVAudioFormat,
        sourceDuration: TimeInterval
    ) throws {
        let frames = max(0, sourceDuration) * format.sampleRate
        let bytesPerFrame = Double(format.channelCount) * Double(MemoryLayout<Float>.size)
        let derivativeBytes = Int64((frames * bytesPerFrame).rounded(.up))
        guard derivativeBytes <= maximumCacheBytes else {
            throw TimelineReverseAudioError.derivativeTooLarge
        }
        let values = try directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
        guard let available else { throw TimelineReverseAudioError.capacityUnavailable }
        // The forward and reverse staging files coexist until the atomic cache
        // move. Keep the same 512 MiB runtime reserve as capture/export plus a
        // small container and conversion margin.
        let required = RecordingStoragePolicy.runtimeReserveBytes
            + derivativeBytes * 2
            + max(64 * 1_024 * 1_024, derivativeBytes / 10)
        guard available >= required else {
            throw TimelineReverseAudioError.insufficientCapacity(
                availableBytes: available,
                requiredBytes: required
            )
        }
    }

    private func cacheKey(
        sourceURL: URL,
        sourceTrackID: Int32,
        sourceStart: TimeInterval,
        sourceDuration: TimeInterval
    ) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let size = attributes[.size] as? NSNumber ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let identity = [
            sourceURL.standardizedFileURL.path,
            String(sourceTrackID),
            String(format: "%.9f", sourceStart),
            String(format: "%.9f", sourceDuration),
            size.stringValue,
            String(format: "%.3f", modified),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func trimCache(in directory: URL, preserving destination: URL) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var entries = files.compactMap { url -> (URL, Date, Int64)? in
            guard url.pathExtension == "caf",
                  url != destination,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, Int64(values.fileSize ?? 0))
        }.sorted { $0.1 > $1.1 }
        let preservedSize = ((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var retainedBytes = Int64(preservedSize)
        var retainedFiles = 1
        for entry in entries {
            if retainedFiles < maximumCacheFiles,
               retainedBytes + entry.2 <= maximumCacheBytes
            {
                retainedFiles += 1
                retainedBytes += entry.2
            } else {
                try? fileManager.removeItem(at: entry.0)
            }
        }
        entries.removeAll(keepingCapacity: false)
    }
}

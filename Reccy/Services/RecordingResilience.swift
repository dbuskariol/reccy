import AVFoundation
import Foundation

nonisolated struct RecordingStoragePolicy: Sendable {
    static let runtimeReserveBytes: Int64 = 512 * 1_024 * 1_024
    static let preflightWindow: TimeInterval = 5 * 60
    static let preflightFloorBytes: Int64 = 256 * 1_024 * 1_024

    static func estimatedBytesPerSecond(for options: MultitrackRecordingOptions) -> Int64 {
        var bitsPerSecond = Int64(options.targetVideoBitRate)
        if options.includesSystemAudio { bitsPerSecond += 192_000 }
        if options.includesMicrophone { bitsPerSecond += 128_000 }
        return max(1, (bitsPerSecond + 7) / 8)
    }

    static func requiredPreflightBytes(for options: MultitrackRecordingOptions) -> Int64 {
        let projected = Int64(Double(estimatedBytesPerSecond(for: options)) * preflightWindow)
        return runtimeReserveBytes + max(preflightFloorBytes, projected)
    }

    static func availableBytes(at directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        if let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        throw RecordingStorageError.capacityUnavailable
    }

    static func validatePreflight(
        availableBytes: Int64,
        options: MultitrackRecordingOptions
    ) throws {
        let required = requiredPreflightBytes(for: options)
        guard availableBytes >= required else {
            throw RecordingStorageError.insufficientCapacity(
                availableBytes: availableBytes,
                requiredBytes: required
            )
        }
    }
}

nonisolated enum RecordingStorageError: LocalizedError, Equatable {
    case capacityUnavailable
    case insufficientCapacity(availableBytes: Int64, requiredBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .capacityUnavailable:
            return "Reccy couldn’t verify free space in the recording folder. Choose another folder or try again."
        case let .insufficientCapacity(available, required):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Not enough free space to start recording. \(formatter.string(fromByteCount: available)) is available; Reccy requires \(formatter.string(fromByteCount: required)) for a safe recording reserve."
        }
    }
}

nonisolated struct RecordingRecoveryJournal: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let fileName = ".reccy-active-recording.json"

    var version = currentVersion
    var createdAt: Date
    var mediaFileName: String
    var manifest: RecordingManifest

    init(mediaURL: URL, manifest: RecordingManifest) {
        createdAt = Date()
        mediaFileName = mediaURL.lastPathComponent
        self.manifest = manifest
    }

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    static func write(
        mediaURL: URL,
        manifest: RecordingManifest
    ) throws -> URL {
        let journal = RecordingRecoveryJournal(mediaURL: mediaURL, manifest: manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(journal)
        let journalURL = url(in: mediaURL.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: journalURL.path) else {
            throw RecordingRecoveryError.activeJournalExists
        }
        try data.write(to: journalURL, options: [.atomic])
        return journalURL
    }

    static func load(from directory: URL) throws -> RecordingRecoveryJournal? {
        let journalURL = url(in: directory)
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        let data = try Data(contentsOf: journalURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let journal = try decoder.decode(RecordingRecoveryJournal.self, from: data)
        guard journal.version == currentVersion,
              URL(fileURLWithPath: journal.mediaFileName).lastPathComponent == journal.mediaFileName
        else { throw RecordingRecoveryError.invalidJournal }
        return journal
    }

    static func remove(from directory: URL) throws {
        let journalURL = url(in: directory)
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        try FileManager.default.removeItem(at: journalURL)
    }
}

nonisolated enum RecordingRecoveryError: LocalizedError {
    case invalidJournal
    case activeJournalExists

    var errorDescription: String? {
        switch self {
        case .invalidJournal:
            "Reccy found invalid interrupted-recording metadata and left the media untouched."
        case .activeJournalExists:
            "An interrupted recording is still being recovered. Open Library and resolve its recovery notice before starting another capture."
        }
    }
}

nonisolated struct RecordingRecoveryNotice: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case recovered
        case warning
        case information
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
    let fileURL: URL?
}

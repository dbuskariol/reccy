import AVFoundation
import Darwin
import Foundation
import os

/// An advisory, cross-process lease for the recording directory.
///
/// Reccy may be running from Xcode while an installed copy is open. Both
/// processes share the same library and recovery journal, so the journal alone
/// cannot distinguish an interrupted recording from one that is still being
/// written. Holding this file lock for the complete writer lifecycle makes
/// capture and recovery mutually exclusive without relying on process names,
/// bundle locations, timers, or stale PID files. The kernel releases the lease
/// automatically if the owning process exits unexpectedly.
nonisolated final class RecordingSessionLease: @unchecked Sendable {
    static let fileName = ".reccy-recording.lock"
    private static let activePaths = OSAllocatedUnfairLock(initialState: Set<String>())

    private let descriptor: Int32
    private let path: String
    private let stateLock = NSLock()
    private var isReleased = false

    private init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    deinit {
        release()
    }

    static func acquire(in directory: URL) throws -> RecordingSessionLease {
        let lockURL = directory.appendingPathComponent(fileName, isDirectory: false)
        let path = lockURL.standardizedFileURL.path
        let reservedInProcess = activePaths.withLock { paths in
            paths.insert(path).inserted
        }
        guard reservedInProcess else {
            throw RecordingLeaseError.alreadyHeld
        }

        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            _ = activePaths.withLock { $0.remove(path) }
            throw RecordingLeaseError.cannotOpen(errno)
        }

        var fileLock = flock()
        fileLock.l_start = 0
        fileLock.l_len = 0
        fileLock.l_pid = 0
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &fileLock) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            _ = activePaths.withLock { $0.remove(path) }
            if code == EWOULDBLOCK || code == EAGAIN {
                throw RecordingLeaseError.alreadyHeld
            }
            throw RecordingLeaseError.cannotLock(code)
        }
        return RecordingSessionLease(descriptor: descriptor, path: path)
    }

    func release() {
        stateLock.lock()
        guard !isReleased else {
            stateLock.unlock()
            return
        }
        isReleased = true
        stateLock.unlock()

        var fileLock = flock()
        fileLock.l_start = 0
        fileLock.l_len = 0
        fileLock.l_pid = 0
        fileLock.l_type = Int16(F_UNLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
        Darwin.close(descriptor)
        _ = Self.activePaths.withLock { $0.remove(path) }
    }
}

nonisolated enum RecordingLeaseError: LocalizedError, Equatable {
    case alreadyHeld
    case cannotOpen(Int32)
    case cannotLock(Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyHeld:
            "Another Reccy process is recording or recovering this library. Stop it before starting a new recording."
        case let .cannotOpen(code):
            "Reccy couldn’t open its recording safety lease (POSIX error \(code))."
        case let .cannotLock(code):
            "Reccy couldn’t secure its recording safety lease (POSIX error \(code))."
        }
    }
}

nonisolated struct RecordingStoragePolicy: Sendable {
    static let runtimeReserveBytes: Int64 = 512 * 1_024 * 1_024
    static let preflightWindow: TimeInterval = 5 * 60
    static let preflightFloorBytes: Int64 = 256 * 1_024 * 1_024

    static func estimatedBytesPerSecond(for options: MultitrackRecordingOptions) -> Int64 {
        var bitsPerSecond = Int64(options.targetVideoBitRate)
        if options.includesSystemAudio { bitsPerSecond += 192_000 }
        if options.includesMicrophone { bitsPerSecond += 128_000 }
        if options.includesCamera { bitsPerSecond += Int64(options.targetCameraBitRate) }
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

    static func update(manifest: RecordingManifest, mediaURL: URL) throws {
        let directory = mediaURL.deletingLastPathComponent()
        guard var journal = try load(from: directory),
              journal.mediaFileName == mediaURL.lastPathComponent
        else { throw RecordingRecoveryError.invalidJournal }
        journal.manifest = manifest
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: url(in: directory), options: [.atomic])
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

    /// Removes a recording that never reached its first complete video frame.
    /// The journal stays in place until the partial media has been removed, so
    /// a filesystem failure can still be surfaced by the normal recovery path.
    static func discardIncompleteRecording(mediaURL: URL) throws {
        let directory = mediaURL.deletingLastPathComponent()
        if let journal = try load(from: directory),
           journal.mediaFileName != mediaURL.lastPathComponent
        {
            throw RecordingRecoveryError.invalidJournal
        }
        if FileManager.default.fileExists(atPath: mediaURL.path) {
            try FileManager.default.removeItem(at: mediaURL)
        }
        try remove(from: directory)
    }

    /// Permanently removes the exact artifact graph for an explicitly
    /// cancelled live session. Existing files first move into a unique hidden
    /// directory on the recording volume. That makes the visible Library and
    /// recovery journal agree before recursive deletion begins, while a move
    /// failure can still roll the small transaction back.
    static func discardCancelledRecording(mediaURL: URL) throws {
        let directory = mediaURL.deletingLastPathComponent()
        if let journal = try load(from: directory),
           journal.mediaFileName != mediaURL.lastPathComponent
        {
            throw RecordingRecoveryError.invalidJournal
        }

        let artifacts = RecordingArtifacts(mediaURL: mediaURL)
        let candidates = [url(in: directory)] + artifacts.trashOrder
        let existing = candidates.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !existing.isEmpty else { return }

        let quarantine = directory.appendingPathComponent(
            ".reccy-discard-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: quarantine,
            withIntermediateDirectories: false
        )

        var moved: [(source: URL, destination: URL)] = []
        do {
            for source in existing {
                let destination = quarantine.appendingPathComponent(
                    source.lastPathComponent,
                    isDirectory: source.hasDirectoryPath
                )
                try FileManager.default.moveItem(at: source, to: destination)
                moved.append((source, destination))
            }
        } catch {
            for item in moved.reversed()
                where FileManager.default.fileExists(atPath: item.destination.path)
                    && !FileManager.default.fileExists(atPath: item.source.path)
            {
                try? FileManager.default.moveItem(
                    at: item.destination,
                    to: item.source
                )
            }
            try? FileManager.default.removeItem(at: quarantine)
            throw error
        }

        // The user explicitly confirmed permanent discard. At this point every
        // session-owned path is hidden from both Library scanning and recovery.
        try FileManager.default.removeItem(at: quarantine)
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

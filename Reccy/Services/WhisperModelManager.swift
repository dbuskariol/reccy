import Foundation
import WhisperKit

nonisolated struct WhisperModelRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let folderPath: String
    let installedAt: Date
    let byteCount: Int64
}

actor WhisperModelManager {
    /// Product default: Argmax documents `tiny` as WhisperKit's fastest model.
    /// Keep the accuracy recommendation separate so UI and migrations do not
    /// conflate first-result latency with maximum multilingual accuracy.
    static let defaultModel = "openai_whisper-tiny"
    static let recommendedModel = "openai_whisper-large-v3-v20240930_626MB"
    static let compactModel = "openai_whisper-small"

    private let fileManager: FileManager
    private let baseURL: URL
    private let indexURL: URL
    private var records: [String: WhisperModelRecord] = [:]

    init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.fileManager = fileManager
        let resolvedBase = baseURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Reccy", isDirectory: true)
            .appendingPathComponent("Transcription Models", isDirectory: true)
        self.baseURL = resolvedBase
        self.indexURL = resolvedBase.appendingPathComponent("models.json")
    }

    func load() throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: indexURL.path) else {
            records = [:]
            return
        }
        let decoded = try JSONDecoder().decode([WhisperModelRecord].self, from: Data(contentsOf: indexURL))
        records = Dictionary(uniqueKeysWithValues: decoded.compactMap { record in
            fileManager.fileExists(atPath: record.folderPath) ? (record.id, record) : nil
        })
        try persistIndex()
    }

    func installedModels() -> [WhisperModelRecord] {
        records.values.sorted { $0.installedAt > $1.installedAt }
    }

    func installedModelURL(for identifier: String) -> URL? {
        guard let record = records[identifier], fileManager.fileExists(atPath: record.folderPath) else {
            return nil
        }
        return URL(fileURLWithPath: record.folderPath, isDirectory: true)
    }

    func availableModels() async throws -> [String] {
        try await WhisperKit.fetchAvailableModels(downloadBase: baseURL)
            .sorted { Self.modelRank($0) < Self.modelRank($1) }
    }

    func download(
        _ identifier: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> WhisperModelRecord {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let folder = try await WhisperKit.download(
            variant: identifier,
            downloadBase: baseURL,
            useBackgroundSession: true
        ) { downloadProgress in
            progress(downloadProgress.fractionCompleted)
        }
        let record = WhisperModelRecord(
            id: identifier,
            folderPath: folder.path,
            installedAt: Date(),
            byteCount: Self.recursiveByteCount(at: folder, fileManager: fileManager)
        )
        records[identifier] = record
        try persistIndex()
        return record
    }

    func remove(_ identifier: String) throws {
        guard let record = records.removeValue(forKey: identifier) else { return }
        let folder = URL(fileURLWithPath: record.folderPath, isDirectory: true)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
        try persistIndex()
    }

    func removeAll() throws {
        for identifier in Array(records.keys) { try remove(identifier) }
    }

    private func persistIndex() throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Array(records.values))
        try data.write(to: indexURL, options: .atomic)
    }

    private nonisolated static func recursiveByteCount(at url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.compactMap { $0 as? URL }.reduce(into: Int64(0)) { total, file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return }
            total += Int64(values.fileSize ?? 0)
        }
    }

    private nonisolated static func modelRank(_ identifier: String) -> Int {
        if identifier == defaultModel { return 0 }
        if identifier.contains("tiny") { return 1 }
        if identifier.contains("base") { return 2 }
        if identifier.contains("small") { return 3 }
        if identifier == recommendedModel { return 4 }
        if identifier.contains("large-v3-v20240930") { return 5 }
        if identifier.contains("large-v3") { return 6 }
        return 7
    }
}

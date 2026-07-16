@preconcurrency import AVFoundation
import Foundation

nonisolated enum TranscriptStoreError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "This transcript was created by an incompatible development build."
        }
    }
}

actor TranscriptStore {
    func load(for mediaURL: URL) async throws -> TranscriptDocument? {
        let url = Self.sidecarURL(for: mediaURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let document = try decoder.decode(TranscriptDocument.self, from: data)
        guard document.formatVersion == TranscriptDocument.currentFormatVersion else {
            throw TranscriptStoreError.unsupportedFormat
        }
        let duration = try? await AVURLAsset(url: mediaURL).load(.duration).seconds
        guard let duration else { return document }
        return document.sanitized(sourceDuration: duration)
    }

    func save(_ document: TranscriptDocument, for mediaURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(document)
        try data.write(to: Self.sidecarURL(for: mediaURL), options: .atomic)
    }

    func remove(for mediaURL: URL) throws {
        let url = Self.sidecarURL(for: mediaURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    nonisolated static func sidecarURL(for mediaURL: URL) -> URL {
        mediaURL.deletingPathExtension().appendingPathExtension("reccytranscript")
    }
}

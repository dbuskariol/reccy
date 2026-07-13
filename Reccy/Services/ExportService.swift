import AVFoundation
import Foundation

enum ExportPreset: String, CaseIterable, Identifiable, Sendable {
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
        case .hevcBest: "HEVC · Best Quality"
        case .hevc4K: "HEVC · 4K"
        case .hevc1080: "HEVC · 1080p"
        case .h264Best: "H.264 · Best Quality"
        case .h2644K: "H.264 · 4K"
        case .h2641080: "H.264 · 1080p"
        case .h264720: "H.264 · 720p"
        case .proRes422: "Apple ProRes 422"
        case .proRes4444: "Apple ProRes 4444"
        case .audioM4A: "Audio Only · M4A"
        }
    }

    var detail: String {
        switch self {
        case .hevcBest: "Small file, preserves source resolution"
        case .hevc4K: "Efficient 3840 × 2160 delivery"
        case .hevc1080: "Efficient everyday sharing"
        case .h264Best: "Maximum playback compatibility"
        case .h2644K: "Compatible 3840 × 2160 delivery"
        case .h2641080: "Compatible Full HD delivery"
        case .h264720: "Compact web and messaging export"
        case .proRes422: "High-quality professional editing"
        case .proRes4444: "Very high-quality finishing workflow"
        case .audioM4A: "AAC audio without video"
        }
    }

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
}

enum ExportServiceError: LocalizedError {
    case unsupportedPreset

    var errorDescription: String? {
        switch self {
        case .unsupportedPreset:
            "This export preset is not compatible with the selected recording."
        }
    }
}

struct ExportService {
    func export(sourceURL: URL, destinationURL: URL, preset: ExportPreset) async throws {
        let asset = AVURLAsset(url: sourceURL)
        try await export(asset: asset, destinationURL: destinationURL, preset: preset)
    }

    func export(
        asset: AVAsset,
        destinationURL: URL,
        preset: ExportPreset,
        videoComposition: AVVideoComposition? = nil
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset.avPresetName) else {
            throw ExportServiceError.unsupportedPreset
        }
        guard session.supportedFileTypes.contains(preset.fileType) else {
            throw ExportServiceError.unsupportedPreset
        }

        session.shouldOptimizeForNetworkUse = preset.fileType == .mp4
        if preset != .audioM4A {
            session.videoComposition = videoComposition
        }
        try await session.export(to: destinationURL, as: preset.fileType)
    }
}

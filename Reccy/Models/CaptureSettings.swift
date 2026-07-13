import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureSourceKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case display
    case region
    case application
    case window

    var id: Self { self }

    var title: String {
        switch self {
        case .display: "Display"
        case .region: "Portion"
        case .application: "Application"
        case .window: "Window"
        }
    }

    var detail: String {
        switch self {
        case .display: "Record an entire connected display"
        case .region: "Record a custom area of one display"
        case .application: "Record every window from one app"
        case .window: "Record one specific window"
        }
    }

    var systemImage: String {
        switch self {
        case .display: "display"
        case .region: "viewfinder.rectangular"
        case .application: "macwindow.on.rectangle"
        case .window: "macwindow"
        }
    }

    /// Portion capture uses Reccy's direct, display-spanning selection overlay.
    /// The remaining source kinds are delegated to macOS's privacy-preserving picker.
    var pickerMode: SCContentSharingPickerMode? {
        switch self {
        case .display: .singleDisplay
        case .region: nil
        case .application: .singleApplication
        case .window: .singleWindow
        }
    }

    var contentStyle: SCShareableContentStyle? {
        switch self {
        case .display: .display
        case .region: nil
        case .application: .application
        case .window: .window
        }
    }
}

enum CaptureResolution: String, CaseIterable, Identifiable, Codable, Sendable {
    case native
    case ultraHD
    case quadHD
    case fullHD
    case hd

    var id: Self { self }

    var title: String {
        switch self {
        case .native: "Native"
        case .ultraHD: "4K"
        case .quadHD: "1440p"
        case .fullHD: "1080p"
        case .hd: "720p"
        }
    }

    var detail: String {
        switch self {
        case .native: "Source resolution"
        case .ultraHD: "Up to 3840 × 2160"
        case .quadHD: "Up to 2560 × 1440"
        case .fullHD: "Up to 1920 × 1080"
        case .hd: "Up to 1280 × 720"
        }
    }

    private var landscapeBounds: CGSize? {
        switch self {
        case .native: nil
        case .ultraHD: CGSize(width: 3840, height: 2160)
        case .quadHD: CGSize(width: 2560, height: 1440)
        case .fullHD: CGSize(width: 1920, height: 1080)
        case .hd: CGSize(width: 1280, height: 720)
        }
    }

    func outputSize(contentRect: CGRect, pointPixelScale: CGFloat) -> CGSize {
        let safeScale = pointPixelScale > 0 ? pointPixelScale : 1
        let sourceWidth = max(2, contentRect.width * safeScale)
        let sourceHeight = max(2, contentRect.height * safeScale)

        guard var bounds = landscapeBounds else {
            return Self.evenSize(width: sourceWidth, height: sourceHeight)
        }

        if sourceHeight > sourceWidth {
            bounds = CGSize(width: bounds.height, height: bounds.width)
        }

        let scale = min(1, min(bounds.width / sourceWidth, bounds.height / sourceHeight))
        return Self.evenSize(width: sourceWidth * scale, height: sourceHeight * scale)
    }

    private static func evenSize(width: CGFloat, height: CGFloat) -> CGSize {
        let evenWidth = max(2, Int(width.rounded(.down)) / 2 * 2)
        let evenHeight = max(2, Int(height.rounded(.down)) / 2 * 2)
        return CGSize(width: evenWidth, height: evenHeight)
    }
}

enum CaptureFrameRate: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Self { self }
    var title: String { "\(rawValue) fps" }
}

nonisolated enum RecordingPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case efficient
    case compatible
    case hevcMaster

    var id: Self { self }

    var title: String {
        switch self {
        case .efficient: "Efficient"
        case .compatible: "Compatible"
        case .hevcMaster: "HEVC Master"
        }
    }

    var detail: String {
        switch self {
        case .efficient: "HEVC in MP4 · best default"
        case .compatible: "H.264 in MP4 · widest support"
        case .hevcMaster: "HEVC in MOV · editing workflow"
        }
    }

    var codec: AVVideoCodecType {
        switch self {
        case .efficient, .hevcMaster: .hevc
        case .compatible: .h264
        }
    }

    var fileType: AVFileType {
        switch self {
        case .efficient, .compatible: .mp4
        case .hevcMaster: .mov
        }
    }

    var fileExtension: String {
        switch fileType {
        case .mov: "mov"
        default: "mp4"
        }
    }
}

enum CountdownDelay: Int, CaseIterable, Identifiable, Codable, Sendable {
    case none = 0
    case three = 3
    case five = 5
    case ten = 10

    var id: Self { self }
    var title: String { rawValue == 0 ? "Off" : "\(rawValue) seconds" }
}

enum ScreenshotFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case heic
    case jpeg
    case png

    var id: Self { self }
    var title: String { rawValue.uppercased() }

    var contentType: UTType {
        switch self {
        case .heic: .heic
        case .jpeg: .jpeg
        case .png: .png
        }
    }

    var fileExtension: String {
        switch self {
        case .heic: "heic"
        case .jpeg: "jpg"
        case .png: "png"
        }
    }
}

enum ScreenshotRange: String, CaseIterable, Identifiable, Codable, Sendable {
    case sdr
    case hdr

    var id: Self { self }
    var title: String { rawValue.uppercased() }

    var screenCaptureRange: SCScreenshotConfiguration.DynamicRange {
        switch self {
        case .sdr: .sdr
        case .hdr: .hdr
        }
    }
}

struct CaptureSettings: Codable, Equatable, Sendable {
    var resolution: CaptureResolution = .quadHD
    var frameRate: CaptureFrameRate = .fps30
    var recordingPreset: RecordingPreset = .efficient
    var countdown: CountdownDelay = .three
    var includeSystemAudio = true
    var includeMicrophone = false
    var selectedMicrophoneID: String?
    var showCursor = true
    var showMouseClicks = true
    var excludeOwnAudio = true
    var useHDR = false
    var screenshotFormat: ScreenshotFormat = .heic
    var screenshotRange: ScreenshotRange = .sdr
    var outputFolderPath: String?

    static let storageKey = "capture-settings-v2"

    static func load(defaults: UserDefaults = .standard) -> CaptureSettings {
        guard
            let data = defaults.data(forKey: storageKey),
            let settings = try? JSONDecoder().decode(CaptureSettings.self, from: data)
        else {
            return CaptureSettings()
        }
        return settings
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

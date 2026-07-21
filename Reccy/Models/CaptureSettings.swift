import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Reccy enforces its single-session invariant in `CaptureCoordinator` rather
/// than asking Control Centre to count picker results that aren't associated
/// with an existing `SCStream` yet.
nonisolated enum CaptureSourcePickerPolicy {
    static let maximumConcurrentStreams: Int? = nil
}

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

    /// The private system picker stays responsible for source approval. Keep
    /// its progress copy source-specific so articles and terminology remain
    /// correct everywhere the selection state is surfaced.
    var pickerSelectionPrompt: String? {
        switch self {
        case .display: "Choose a display in the macOS picker."
        case .region: nil
        case .application:
            "Select an application, then choose the purple Share button in the macOS picker."
        case .window: "Choose a window in the macOS picker."
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

    /// Portion uses Reccy's resizable overlay and therefore needs macOS's
    /// direct-capture approval. Every other source stays inside Apple's
    /// privacy-preserving content picker and is approved per selection.
    var requiresDirectCapturePermission: Bool { self == .region }

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
        videoCodec.avFoundationType
    }

    var videoCodec: RecordingVideoCodec {
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

    static func available(isHDR: Bool) -> [RecordingPreset] {
        allCases.filter { !isHDR || $0.videoCodec == .hevc }
    }
}

nonisolated enum RecordingVideoCodec: String, Codable, Hashable, Sendable {
    case h264
    case hevc

    var avFoundationType: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        }
    }

    func displayName(isHDR: Bool) -> String {
        switch self {
        case .h264: "H.264"
        case .hevc: isHDR ? "HEVC 10-bit" : "HEVC"
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
        // Asking for both representations keeps the HDR image available to
        // Reccy's encoder when ScreenCaptureKit does not persist its requested
        // file. Some macOS 26 display/content combinations return neither a
        // file nor `hdrImage` when HDR is requested alone.
        case .hdr: .bothSDRAndHDR
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
    var includeCamera = false
    var selectedCameraID: String?
    var cameraOverlayPosition: CameraOverlayPosition?
    var showCursor = true
    var showMouseClicks = true
    var startsWithMouseFollowZoom = false
    var mouseFollowZoomLevel: MouseFollowZoomLevel = .standard
    var excludeOwnAudio = true
    var useHDR = false
    var screenshotFormat: ScreenshotFormat = .heic
    var screenshotRange: ScreenshotRange = .sdr
    var outputFolderPath: String?

    static let storageKey = "capture-settings-v2"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case resolution
        case frameRate
        case recordingPreset
        case countdown
        case includeSystemAudio
        case includeMicrophone
        case selectedMicrophoneID
        case includeCamera
        case selectedCameraID
        case cameraOverlayPosition
        case showCursor
        case showMouseClicks
        case startsWithMouseFollowZoom
        case mouseFollowZoomLevel
        case excludeOwnAudio
        case useHDR
        case screenshotFormat
        case screenshotRange
        case outputFolderPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try container.decodeIfPresent(CaptureResolution.self, forKey: .resolution) ?? .quadHD
        frameRate = try container.decodeIfPresent(CaptureFrameRate.self, forKey: .frameRate) ?? .fps30
        recordingPreset = try container.decodeIfPresent(RecordingPreset.self, forKey: .recordingPreset) ?? .efficient
        countdown = try container.decodeIfPresent(CountdownDelay.self, forKey: .countdown) ?? .three
        includeSystemAudio = try container.decodeIfPresent(Bool.self, forKey: .includeSystemAudio) ?? true
        includeMicrophone = try container.decodeIfPresent(Bool.self, forKey: .includeMicrophone) ?? false
        selectedMicrophoneID = try container.decodeIfPresent(String.self, forKey: .selectedMicrophoneID)
        includeCamera = try container.decodeIfPresent(Bool.self, forKey: .includeCamera) ?? false
        selectedCameraID = try container.decodeIfPresent(String.self, forKey: .selectedCameraID)
        cameraOverlayPosition = try container.decodeIfPresent(
            CameraOverlayPosition.self,
            forKey: .cameraOverlayPosition
        )
        showCursor = try container.decodeIfPresent(Bool.self, forKey: .showCursor) ?? true
        showMouseClicks = try container.decodeIfPresent(Bool.self, forKey: .showMouseClicks) ?? true
        startsWithMouseFollowZoom = try container.decodeIfPresent(
            Bool.self,
            forKey: .startsWithMouseFollowZoom
        ) ?? false
        mouseFollowZoomLevel = try container.decodeIfPresent(
            MouseFollowZoomLevel.self,
            forKey: .mouseFollowZoomLevel
        ) ?? .standard
        excludeOwnAudio = try container.decodeIfPresent(Bool.self, forKey: .excludeOwnAudio) ?? true
        useHDR = try container.decodeIfPresent(Bool.self, forKey: .useHDR) ?? false
        screenshotFormat = try container.decodeIfPresent(ScreenshotFormat.self, forKey: .screenshotFormat) ?? .heic
        screenshotRange = try container.decodeIfPresent(ScreenshotRange.self, forKey: .screenshotRange) ?? .sdr
        outputFolderPath = try container.decodeIfPresent(String.self, forKey: .outputFolderPath)
    }

    static func load(defaults: UserDefaults = .standard) -> CaptureSettings {
        guard
            let data = defaults.data(forKey: storageKey),
            let settings = try? JSONDecoder().decode(CaptureSettings.self, from: data)
        else {
            return CaptureSettings()
        }
        var normalized = settings
        normalized.normalize()
        return normalized
    }

    /// HDR10 requires HEVC. Keeping this invariant in the model prevents the
    /// picker, file extension, manifest, and encoder from describing different
    /// formats when settings are changed from any app surface.
    mutating func normalize() {
        if useHDR, recordingPreset == .compatible {
            recordingPreset = .efficient
        }
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    static func discoverAvailable() -> [AudioInputDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        .devices
        .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct VideoInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    static func discoverAvailable() -> [VideoInputDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .deskViewCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        .devices
        .map { VideoInputDevice(id: $0.uniqueID, name: $0.localizedName) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

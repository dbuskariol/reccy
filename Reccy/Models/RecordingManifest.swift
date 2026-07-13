import CoreGraphics
import Foundation

nonisolated struct CaptureRegion: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

nonisolated struct CaptureSourceDescriptor: Codable, Hashable, Sendable {
    var kind: CaptureSourceKind
    var name: String
    var applicationName: String?
    var applicationBundleIdentifier: String?
    var windowName: String?
    var windowIDs: [UInt32]
    var displayID: UInt32?
    var displayName: String?
    var region: CaptureRegion?

    var detail: String {
        switch kind {
        case .display:
            displayName ?? name
        case .region:
            if let region {
                "\(Int(region.width)) × \(Int(region.height)) points on \(displayName ?? name)"
            } else {
                displayName ?? name
            }
        case .application:
            applicationName ?? name
        case .window:
            [applicationName, windowName].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

nonisolated struct RecordingManifest: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var createdAt: Date
    var source: CaptureSourceDescriptor
    var width: Int
    var height: Int
    var frameRate: Int
    var recordingPreset: RecordingPreset
    var isHDR: Bool
    var includesSystemAudio: Bool
    var includesMicrophone: Bool
    var microphoneName: String?
    var showsCursor: Bool
    var highlightsClicks: Bool

    static func sidecarURL(for mediaURL: URL) -> URL {
        mediaURL.deletingPathExtension().appendingPathExtension("reccy.json")
    }
}

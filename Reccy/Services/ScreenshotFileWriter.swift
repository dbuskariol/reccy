import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotFileWriterError: LocalizedError {
    case missingCapturedImage
    case hdrUnavailable
    case cannotCreateDestination
    case encodingFailed
    case validationFailed

    var errorDescription: String? {
        switch self {
        case .missingCapturedImage:
            "ScreenCaptureKit did not return an image to save."
        case .hdrUnavailable:
            "macOS did not provide an HDR image for this source. Try SDR or choose another display."
        case .cannotCreateDestination:
            "Reccy could not create the screenshot file."
        case .encodingFailed:
            "Reccy could not encode the captured screenshot."
        case .validationFailed:
            "The screenshot file could not be verified after it was saved."
        }
    }
}

enum ScreenshotFileWriter {
    static func isValidImageFile(at url: URL) -> Bool {
        guard
            let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            fileSize > 0,
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else {
            return false
        }

        return true
    }

    static func write(_ image: CGImage, to destinationURL: URL, contentType: UTType) throws {
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let stagingURL = directoryURL
            .appendingPathComponent(".reccy-screenshot-\(UUID().uuidString)")
            .appendingPathExtension(destinationURL.pathExtension)
        defer { try? fileManager.removeItem(at: stagingURL) }

        guard let destination = CGImageDestinationCreateWithURL(
            stagingURL as CFURL,
            contentType.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotFileWriterError.cannotCreateDestination
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotFileWriterError.encodingFailed
        }
        guard isValidImageFile(at: stagingURL) else {
            throw ScreenshotFileWriterError.validationFailed
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }

        guard isValidImageFile(at: destinationURL) else {
            throw ScreenshotFileWriterError.validationFailed
        }
    }
}

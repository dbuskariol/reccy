@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum TimelineMediaImportError: LocalizedError {
    case unsupported(String)
    case unreadableImage(String)
    case cannotCreateImageProxy
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            "\(name) doesn’t contain a supported video, audio, or image track."
        case .unreadableImage(let name):
            "Reccy couldn’t read the image in \(name)."
        case .cannotCreateImageProxy:
            "Reccy couldn’t prepare the image for the video timeline."
        case .writerFailed(let detail):
            "Reccy couldn’t prepare the image track. \(detail)"
        }
    }
}

nonisolated struct TimelineMediaImportResult: Sendable {
    let lanes: [TimelineLane]
    let sourceDurations: [URL: TimeInterval]
    let createdFiles: [URL]
}

/// Serializes project-media ingestion away from the main actor. Source files
/// are copied through a private staging name and atomically moved into Media/.
/// Image proxies are bounded to 4096 px and contain two frames regardless of
/// timeline duration, so long stills do not grow memory or disk use over time.
actor TimelineMediaImporter {
    func prepare(
        urls: [URL],
        packageURL: URL,
        timelineStart: TimeInterval,
        canvasSize: CGSize,
        frameRate: Double
    ) async throws -> TimelineMediaImportResult {
        let mediaDirectory = packageURL.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        var lanes: [TimelineLane] = []
        var durations: [URL: TimeInterval] = [:]
        var createdFiles: [URL] = []
        do {
            for sourceURL in urls {
                try Task.checkCancellation()
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed { sourceURL.stopAccessingSecurityScopedResource() }
                }

                let ownedSourceURL = try copyAtomically(sourceURL, into: mediaDirectory)
                createdFiles.append(ownedSourceURL)

                if isImage(ownedSourceURL) {
                    let prepared = try await prepareImage(
                        ownedSourceURL,
                        in: mediaDirectory,
                        timelineStart: timelineStart,
                        canvasSize: canvasSize,
                        frameRate: frameRate
                    )
                    createdFiles.append(prepared.proxyURL)
                    lanes.append(prepared.lane)
                    durations[prepared.proxyURL] = 24 * 60 * 60
                    continue
                }

                let asset = AVURLAsset(url: ownedSourceURL)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
                    throw TimelineMediaImportError.unsupported(sourceURL.lastPathComponent)
                }

                let assetDuration = max(try await asset.load(.duration).seconds, 1 / max(frameRate, 1))
                durations[ownedSourceURL] = assetDuration
                let linkedGroupID = videoTracks.isEmpty || audioTracks.isEmpty ? nil : UUID()
                let displayName = sourceURL.deletingPathExtension().lastPathComponent

                if let videoTrack = videoTracks.first {
                    let timeRange = try await videoTrack.load(.timeRange)
                    let sourceStart = max(0, timeRange.start.seconds)
                    let trackDuration = max(timeRange.duration.seconds, 1 / max(frameRate, 1))
                    let naturalSize = try await videoTrack.load(.naturalSize)
                    let preferredTransform = try await videoTrack.load(.preferredTransform)
                    let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
                    let displaySize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
                    let layout = TimelineVideoLayout.defaultImportedVideo(
                        canvasSize: canvasSize,
                        sourceSize: displaySize
                    )
                    let clip = TimelineClip(
                        sourceURL: ownedSourceURL,
                        sourceTrackID: videoTrack.trackID,
                        sourceStart: sourceStart,
                        timelineStart: timelineStart,
                        duration: trackDuration,
                        name: displayName,
                        linkedGroupID: linkedGroupID,
                        videoLayout: layout
                    )
                    lanes.append(TimelineLane(
                        kind: .importedVideo,
                        name: displayName,
                        clips: [clip]
                    ))
                }

                for (index, audioTrack) in audioTracks.enumerated() {
                    let timeRange = try await audioTrack.load(.timeRange)
                    let sourceStart = max(0, timeRange.start.seconds)
                    let trackDuration = max(timeRange.duration.seconds, 1 / max(frameRate, 1))
                    let suffix = audioTracks.count > 1 ? " · Audio \(index + 1)" : " · Audio"
                    let clip = TimelineClip(
                        sourceURL: ownedSourceURL,
                        sourceTrackID: audioTrack.trackID,
                        sourceStart: sourceStart,
                        timelineStart: timelineStart,
                        duration: trackDuration,
                        name: displayName + suffix,
                        linkedGroupID: linkedGroupID
                    )
                    lanes.append(TimelineLane(
                        kind: .importedAudio,
                        name: displayName + suffix,
                        clips: [clip]
                    ))
                }
            }
            return TimelineMediaImportResult(
                lanes: lanes,
                sourceDurations: durations,
                createdFiles: createdFiles
            )
        } catch {
            for url in createdFiles.reversed() {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    private func prepareImage(
        _ originalURL: URL,
        in mediaDirectory: URL,
        timelineStart: TimeInterval,
        canvasSize: CGSize,
        frameRate: Double
    ) async throws -> (lane: TimelineLane, proxyURL: URL) {
        guard let imageSource = CGImageSourceCreateWithURL(originalURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  imageSource,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 4096,
                  ] as CFDictionary
              )
        else {
            throw TimelineMediaImportError.unreadableImage(originalURL.lastPathComponent)
        }

        let proxyURL = uniqueURL(
            named: originalURL.deletingPathExtension().lastPathComponent + " Still",
            extension: "mov",
            in: mediaDirectory
        )
        let stagingURL = mediaDirectory
            .appendingPathComponent(".reccy-import-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try await writeImageProxy(image, to: stagingURL, frameRate: frameRate)
        try FileManager.default.moveItem(at: stagingURL, to: proxyURL)

        let asset = AVURLAsset(url: proxyURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw TimelineMediaImportError.cannotCreateImageProxy
        }
        let sourceSize = CGSize(width: image.width, height: image.height)
        let displayName = originalURL.deletingPathExtension().lastPathComponent
        let clip = TimelineClip(
            sourceURL: proxyURL,
            sourceTrackID: track.trackID,
            sourceStart: 0,
            timelineStart: timelineStart,
            duration: 5,
            name: displayName,
            linkedGroupID: nil,
            videoLayout: .defaultImportedVideo(canvasSize: canvasSize, sourceSize: sourceSize),
            stillImageOriginalURL: originalURL
        )
        return (
            TimelineLane(kind: .importedVideo, name: displayName, clips: [clip]),
            proxyURL
        )
    }

    private func writeImageProxy(
        _ image: CGImage,
        to url: URL,
        frameRate: Double
    ) async throws {
        let dimensions = boundedEvenDimensions(width: image.width, height: image.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: dimensions.width,
                AVVideoHeightKey: dimensions.height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimensions.width,
                kCVPixelBufferHeightKey as String: dimensions.height,
            ]
        )
        guard writer.canAdd(input) else {
            throw TimelineMediaImportError.cannotCreateImageProxy
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw TimelineMediaImportError.writerFailed(writer.error?.localizedDescription ?? "Writer did not start.")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pixelBuffer = makePixelBuffer(image, width: dimensions.width, height: dimensions.height) else {
            writer.cancelWriting()
            throw TimelineMediaImportError.cannotCreateImageProxy
        }

        for frame in 0..<2 {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
            let time = CMTime(value: Int64(frame), timescale: CMTimeScale(max(frameRate, 1).rounded()))
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                writer.cancelWriting()
                throw TimelineMediaImportError.writerFailed(writer.error?.localizedDescription ?? "Frame append failed.")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw TimelineMediaImportError.writerFailed(writer.error?.localizedDescription ?? "Writer did not finish.")
        }
    }

    private func makePixelBuffer(_ image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                  data: base,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor.black)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = CGRect(
            x: (CGFloat(width) - size.width) / 2,
            y: (CGFloat(height) - size.height) / 2,
            width: size.width,
            height: size.height
        )
        context.draw(image, in: rect)
        return buffer
    }

    private func copyAtomically(_ sourceURL: URL, into directory: URL) throws -> URL {
        let destination = uniqueURL(
            named: sourceURL.deletingPathExtension().lastPathComponent,
            extension: sourceURL.pathExtension,
            in: directory
        )
        let staging = directory
            .appendingPathComponent(".reccy-import-\(UUID().uuidString)")
            .appendingPathExtension(sourceURL.pathExtension)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: sourceURL, to: staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    private func uniqueURL(named name: String, extension pathExtension: String, in directory: URL) -> URL {
        let safeName = name.isEmpty ? "Imported Media" : name
        var candidate = directory.appendingPathComponent(safeName).appendingPathExtension(pathExtension)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(safeName) \(index)")
                .appendingPathExtension(pathExtension)
            index += 1
        }
        return candidate
    }

    private func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private func boundedEvenDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1, 4096 / Double(max(width, height)))
        let scaledWidth = max(2, Int((Double(width) * scale).rounded()))
        let scaledHeight = max(2, Int((Double(height) * scale).rounded()))
        return (scaledWidth + scaledWidth % 2, scaledHeight + scaledHeight % 2)
    }
}

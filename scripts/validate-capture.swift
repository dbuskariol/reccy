import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation

private struct CaptureValidationReport: Encodable {
    let media: String
    let manifestVersion: Int
    let durationSeconds: Double
    let fileSizeBytes: Int64
    let width: Int
    let height: Int
    let nominalFrameRate: Double
    let codec: String
    let dynamicRange: String
    let videoTrackCount: Int
    let audioTrackCount: Int
    let maximumTrackEndDriftSeconds: Double
}

private struct ValidationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum SelfTestFailure: Error {
    case cannotAddVideoInput
    case cannotCreatePixelBuffer
    case writerFailed
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ValidationFailure(message: message) }
}

private func manifestValue<T>(
    _ key: String,
    in manifest: [String: Any],
    as type: T.Type = T.self
) throws -> T {
    guard let value = manifest[key] as? T else {
        throw ValidationFailure(message: "Recording manifest is missing a valid '\(key)' value.")
    }
    return value
}

private func fourCC(_ value: FourCharCode) -> String {
    String(bytes: [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ], encoding: .ascii) ?? String(format: "0x%08x", value)
}

private func normalizedCodec(_ mediaSubtype: FourCharCode) -> String {
    switch fourCC(mediaSubtype) {
    case "avc1", "avc3": "h264"
    case "hvc1", "hev1": "hevc"
    default: fourCC(mediaSubtype)
    }
}

private func displaySize(
    naturalSize: CGSize,
    preferredTransform: CGAffineTransform
) -> CGSize {
    CGRect(origin: .zero, size: naturalSize)
        .applying(preferredTransform)
        .standardized
        .size
}

private func finiteSeconds(_ time: CMTime, label: String) throws -> Double {
    let seconds = time.seconds
    try require(seconds.isFinite, "\(label) has a non-finite time value.")
    return seconds
}

private func validateCapture(at mediaURL: URL) async throws -> CaptureValidationReport {
    let fileManager = FileManager.default
    let sidecarURL = mediaURL
        .deletingPathExtension()
        .appendingPathExtension("reccy.json")

    var isDirectory: ObjCBool = false
    try require(
        fileManager.fileExists(atPath: mediaURL.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue,
        "Capture media does not exist at \(mediaURL.path)."
    )
    try require(
        fileManager.fileExists(atPath: sidecarURL.path),
        "Capture manifest does not exist at \(sidecarURL.path)."
    )

    let manifestData = try Data(contentsOf: sidecarURL)
    guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
        throw ValidationFailure(message: "Capture manifest is not a JSON object.")
    }
    let manifestVersion: Int = try manifestValue("version", in: manifest)
    let expectedWidth: Int = try manifestValue("width", in: manifest)
    let expectedHeight: Int = try manifestValue("height", in: manifest)
    let expectedFrameRate: Int = try manifestValue("frameRate", in: manifest)
    let expectedCodec: String = try manifestValue("videoCodec", in: manifest)
    let expectsHDR: Bool = try manifestValue("isHDR", in: manifest)
    let includesSystemAudio: Bool = try manifestValue("includesSystemAudio", in: manifest)
    let includesMicrophone: Bool = try manifestValue("includesMicrophone", in: manifest)
    let expectedAudioTracks = (includesSystemAudio ? 1 : 0) + (includesMicrophone ? 1 : 0)

    try require(manifestVersion == 2, "Unsupported capture manifest version \(manifestVersion).")
    try require(expectedWidth > 0 && expectedHeight > 0, "Manifest dimensions are invalid.")
    try require(expectedFrameRate > 0, "Manifest frame rate is invalid.")

    let attributes = try fileManager.attributesOfItem(atPath: mediaURL.path)
    let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    try require(fileSize > 0, "Capture media is empty.")

    let asset = AVURLAsset(url: mediaURL)
    async let loadedPlayable = asset.load(.isPlayable)
    async let loadedDuration = asset.load(.duration)
    async let loadedVideoTracks = asset.loadTracks(withMediaType: .video)
    async let loadedAudioTracks = asset.loadTracks(withMediaType: .audio)

    let isPlayable = try await loadedPlayable
    let duration = try await finiteSeconds(loadedDuration, label: "Capture")
    let videoTracks = try await loadedVideoTracks
    let audioTracks = try await loadedAudioTracks
    try require(isPlayable, "Capture is not playable according to AVFoundation.")
    try require(duration > 0.05, "Capture duration is too short to contain usable media.")
    try require(videoTracks.count == 1, "Expected one video track; found \(videoTracks.count).")
    try require(
        audioTracks.count == expectedAudioTracks,
        "Expected \(expectedAudioTracks) independent audio track(s); found \(audioTracks.count)."
    )

    let videoTrack = videoTracks[0]
    async let loadedNaturalSize = videoTrack.load(.naturalSize)
    async let loadedTransform = videoTrack.load(.preferredTransform)
    async let loadedFrameRate = videoTrack.load(.nominalFrameRate)
    async let loadedDescriptions = videoTrack.load(.formatDescriptions)
    async let loadedVideoRange = videoTrack.load(.timeRange)

    let size = try await displaySize(
        naturalSize: loadedNaturalSize,
        preferredTransform: loadedTransform
    )
    let nominalFrameRate = Double(try await loadedFrameRate)
    let descriptions = try await loadedDescriptions
    let videoRange = try await loadedVideoRange
    let format = try descriptions.first.unwrap(
        or: ValidationFailure(message: "Video track has no format description.")
    )
    let codec = normalizedCodec(CMFormatDescriptionGetMediaSubType(format))

    try require(abs(size.width - Double(expectedWidth)) <= 1, "Video width does not match the manifest.")
    try require(abs(size.height - Double(expectedHeight)) <= 1, "Video height does not match the manifest.")
    try require(codec == expectedCodec, "Expected codec \(expectedCodec); found \(codec).")
    if nominalFrameRate > 0 {
        try require(
            nominalFrameRate <= Double(expectedFrameRate) + 1,
            "Encoded frame rate exceeds the configured capture frame rate."
        )
    }

    let extensions = CMFormatDescriptionGetExtensions(format) as NSDictionary?
    let primaries = extensions?[kCMFormatDescriptionExtension_ColorPrimaries] as? String
    let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction] as? String
    let matrix = extensions?[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
    if expectsHDR {
        try require(codec == "hevc", "HDR capture is not HEVC.")
        try require(primaries != nil, "HDR capture is missing color primaries metadata.")
        try require(transfer != nil, "HDR capture is missing transfer-function metadata.")
        try require(matrix != nil, "HDR capture is missing YCbCr matrix metadata.")
    }

    var trackEndTimes = [try finiteSeconds(CMTimeRangeGetEnd(videoRange), label: "Video track")]
    for (index, track) in audioTracks.enumerated() {
        let range = try await track.load(.timeRange)
        trackEndTimes.append(
            try finiteSeconds(CMTimeRangeGetEnd(range), label: "Audio track \(index + 1)")
        )
    }
    let minimumEnd = trackEndTimes.min() ?? duration
    let maximumEnd = trackEndTimes.max() ?? duration
    let drift = maximumEnd - minimumEnd
    let driftTolerance = max(0.25, duration * 0.01)
    try require(
        drift <= driftTolerance,
        String(
            format: "Track-end drift is %.3f seconds; tolerance is %.3f seconds.",
            drift,
            driftTolerance
        )
    )

    return CaptureValidationReport(
        media: mediaURL.path,
        manifestVersion: manifestVersion,
        durationSeconds: duration,
        fileSizeBytes: fileSize,
        width: Int(size.width.rounded()),
        height: Int(size.height.rounded()),
        nominalFrameRate: nominalFrameRate,
        codec: codec,
        dynamicRange: expectsHDR ? "HDR10" : "SDR",
        videoTrackCount: videoTracks.count,
        audioTrackCount: audioTracks.count,
        maximumTrackEndDriftSeconds: drift
    )
}

private func makeSelfTestPixelBuffer() throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        64,
        64,
        kCVPixelFormatType_32BGRA,
        [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw SelfTestFailure.cannotCreatePixelBuffer
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw SelfTestFailure.cannotCreatePixelBuffer
    }
    memset(baseAddress, 0x44, CVPixelBufferGetDataSize(pixelBuffer))
    return pixelBuffer
}

private func makeSelfTestCapture() async throws -> (media: URL, manifest: URL) {
    let mediaURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Reccy Capture Validator \(UUID().uuidString)")
        .appendingPathExtension("mp4")
    let manifestURL = mediaURL
        .deletingPathExtension()
        .appendingPathExtension("reccy.json")
    let writer = try AVAssetWriter(outputURL: mediaURL, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ]
    )
    guard writer.canAdd(input) else { throw SelfTestFailure.cannotAddVideoInput }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? SelfTestFailure.writerFailed }
    writer.startSession(atSourceTime: .zero)

    for frame in 0..<15 {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard adaptor.append(
            try makeSelfTestPixelBuffer(),
            withPresentationTime: CMTime(value: Int64(frame), timescale: 30)
        ) else {
            throw writer.error ?? SelfTestFailure.writerFailed
        }
    }
    input.markAsFinished()
    await withCheckedContinuation { continuation in
        writer.finishWriting { continuation.resume() }
    }
    guard writer.status == .completed else {
        throw writer.error ?? SelfTestFailure.writerFailed
    }

    let manifest: [String: Any] = [
        "version": 2,
        "width": 64,
        "height": 64,
        "frameRate": 30,
        "videoCodec": "h264",
        "isHDR": false,
        "includesSystemAudio": false,
        "includesMicrophone": false,
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        .write(to: manifestURL, options: .atomic)
    return (mediaURL, manifestURL)
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("Usage: validate-capture.swift /path/to/recording.mp4 | --self-test\n".utf8)
    )
    exit(64)
}

Task {
    do {
        let mediaURL: URL
        var selfTestManifestURL: URL?
        if CommandLine.arguments[1] == "--self-test" {
            let fixture = try await makeSelfTestCapture()
            mediaURL = fixture.media
            selfTestManifestURL = fixture.manifest
        } else {
            mediaURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        }
        defer {
            if let selfTestManifestURL {
                try? FileManager.default.removeItem(at: mediaURL)
                try? FileManager.default.removeItem(at: selfTestManifestURL)
            }
        }
        let report = try await validateCapture(at: mediaURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Capture validation failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
dispatchMain()

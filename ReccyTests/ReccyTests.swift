import AVKit
import CoreMedia
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import Reccy

@Suite("Reccy")
struct ReccyTests {
    @Test func portionCaptureBypassesTheWholeDisplayPicker() {
        #expect(CaptureSourceKind.region.pickerMode == nil)
        #expect(CaptureSourceKind.region.contentStyle == nil)
        #expect(CaptureSourceKind.display.pickerMode == .singleDisplay)
    }

    @Test func regionSelectionConvertsFromAppKitToCaptureCoordinates() {
        let converted = RegionSelectionController.sourceRect(
            from: CGRect(x: 100, y: 200, width: 640, height: 360),
            screenSize: CGSize(width: 1920, height: 1080)
        )

        #expect(converted == CGRect(x: 100, y: 520, width: 640, height: 360))
    }

    @Test func livePreviewRoutesTheWritersPixelBufferWithoutCopyingIt() throws {
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess)
        let imageBuffer = try #require(pixelBuffer)

        var formatDescription: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr)
        let description = try #require(formatDescription)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: 42, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sourceBuffer: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sourceBuffer
        ) == noErr)

        let source = try #require(sourceBuffer)
        let previewPixelBuffer = try #require(CapturePreviewPipeline.pixelBuffer(from: source))
        #expect(previewPixelBuffer === imageBuffer)
    }

    @Test func nativeEditorPlayerViewCanBeCreated() {
        let player = AVPlayer()
        let playerView = AVPlayerView()
        playerView.player = player

        #expect(playerView.player === player)
    }

    @Test func resolutionCapsRetinaSourceWithoutChangingAspectRatio() {
        let size = CaptureResolution.quadHD.outputSize(
            contentRect: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            pointPixelScale: 2
        )

        #expect(size.width == 2560)
        #expect(size.height == 1440)
    }

    @Test func resolutionDoesNotUpscaleSmallWindow() {
        let size = CaptureResolution.ultraHD.outputSize(
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
            pointPixelScale: 1
        )

        #expect(size.width == 1280)
        #expect(size.height == 720)
    }

    @Test func portraitResolutionUsesPortraitBounds() {
        let size = CaptureResolution.quadHD.outputSize(
            contentRect: CGRect(x: 0, y: 0, width: 1080, height: 1920),
            pointPixelScale: 2
        )

        #expect(size.width == 1440)
        #expect(size.height == 2560)
    }

    @Test func timelineSplitKeepsEveryLaneAligned() {
        var project = makeProject()
        project.splitAll(at: 4)

        #expect(project.lanes[0].clips.map(\.duration) == [4, 6])
        #expect(project.lanes[1].clips.map(\.duration) == [4, 6])
        #expect(abs(project.duration - 10) < 0.001)
    }

    @Test func selectedClipCanSplitIndependently() {
        var project = makeProject()
        let videoID = project.lanes[0].clips[0].id
        project.splitClip(id: videoID, at: 4)

        #expect(project.lanes[0].clips.map(\.duration) == [4, 6])
        #expect(project.lanes[1].clips.map(\.duration) == [10])
        #expect(abs(project.duration - 10) < 0.001)
    }

    @Test func rippleDeleteClosesGapAcrossEveryLane() {
        var project = makeProject()
        project.rippleDelete(timeRange: 3..<6)

        #expect(abs(project.duration - 7) < 0.001)
        for lane in project.lanes {
            #expect(lane.clips.map(\.timelineStart) == [0, 3])
            #expect(lane.clips.map(\.duration) == [3, 4])
        }
    }

    @Test func clipsMoveIndependentlyByDefault() {
        var project = makeProject()
        let videoID = project.lanes[0].clips[0].id

        let finalStart = project.moveClip(id: videoID, to: 2)

        #expect(finalStart == 2)
        #expect(project.lanes[0].clips[0].timelineStart == 2)
        #expect(project.lanes[1].clips[0].timelineStart == 0)
    }

    @Test func explicitLinkedMoveKeepsMatchingAudioInSync() {
        var project = makeProject()
        let videoID = project.lanes[0].clips[0].id

        let finalStart = project.moveClip(id: videoID, to: 2, includeLinked: true)

        #expect(finalStart == 2)
        #expect(project.lanes[0].clips[0].timelineStart == 2)
        #expect(project.lanes[1].clips[0].timelineStart == 2)
    }

    @Test func crossingAClipMagneticallyReordersItAfterItsNeighbour() {
        var project = makeProject()
        project.splitAll(at: 4)
        let firstVideoID = project.lanes[0].clips[0].id

        let finalStart = project.moveClip(id: firstVideoID, to: 8)

        #expect(finalStart == 6)
        #expect(project.lanes[0].clips.map(\.sourceStart) == [4, 0])
        #expect(project.lanes[0].clips.map(\.timelineStart) == [0, 6])
        #expect(project.lanes[1].clips.map(\.sourceStart) == [0, 4])
    }

    @Test func explicitLinkedReorderKeepsAudioAndVideoOrderIdentical() {
        var project = makeProject()
        project.splitAll(at: 4)
        let firstVideoID = project.lanes[0].clips[0].id

        _ = project.moveClip(id: firstVideoID, to: 8, includeLinked: true)

        #expect(project.lanes[0].clips.map(\.sourceStart) == [4, 0])
        #expect(project.lanes[1].clips.map(\.sourceStart) == [4, 0])
        #expect(project.lanes[0].clips.map(\.timelineStart) == [0, 6])
        #expect(project.lanes[1].clips.map(\.timelineStart) == [0, 6])
    }

    @Test func clipMoveSnapsToPlayheadWithinTolerance() {
        var project = makeProject()
        let videoID = project.lanes[0].clips[0].id

        let finalStart = project.moveClip(
            id: videoID,
            to: 1.92,
            snapTargets: [2],
            snapTolerance: 0.1
        )

        #expect(finalStart == 2)
        #expect(project.lanes[0].clips[0].timelineStart == 2)
        #expect(project.lanes[1].clips[0].timelineStart == 0)
    }

    @Test func leadingTrimChangesTimelineAndSourceInPointsIndependently() {
        var project = makeProject()
        let videoID = project.lanes[0].clips[0].id

        let finalInPoint = project.trimClip(
            id: videoID,
            edge: .leading,
            to: 2,
            sourceDuration: 10
        )

        #expect(finalInPoint == 2)
        #expect(project.lanes[0].clips[0].timelineStart == 2)
        #expect(project.lanes[0].clips[0].sourceStart == 2)
        #expect(project.lanes[0].clips[0].duration == 8)
        #expect(project.lanes[1].clips[0].duration == 10)
    }

    @Test func trailingTrimChangesOnlyTheSelectedOutPoint() {
        var project = makeProject()
        let audioID = project.lanes[1].clips[0].id

        let finalOutPoint = project.trimClip(
            id: audioID,
            edge: .trailing,
            to: 6,
            sourceDuration: 10
        )

        #expect(finalOutPoint == 6)
        #expect(project.lanes[1].clips[0].sourceStart == 0)
        #expect(project.lanes[1].clips[0].duration == 6)
        #expect(project.lanes[0].clips[0].duration == 10)
    }

    @Test func compatibleCaptureUsesMoreBitsThanEfficientCapture() {
        let efficient = MultitrackRecordingOptions(
            width: 2560,
            height: 1440,
            frameRate: 30,
            preset: .efficient,
            includesSystemAudio: true,
            includesMicrophone: true,
            isHDR: false
        )
        let compatible = MultitrackRecordingOptions(
            width: 2560,
            height: 1440,
            frameRate: 30,
            preset: .compatible,
            includesSystemAudio: true,
            includesMicrophone: true,
            isHDR: false
        )

        #expect(compatible.targetVideoBitRate > efficient.targetVideoBitRate)
    }

    @Test func recordingManifestRoundTripsExactCaptureIntent() throws {
        let source = CaptureSourceDescriptor(
            kind: .region,
            name: "Portion of Studio Display",
            applicationName: nil,
            applicationBundleIdentifier: nil,
            windowName: nil,
            windowIDs: [],
            displayID: 42,
            displayName: "Studio Display",
            region: CaptureRegion(CGRect(x: 100, y: 80, width: 1280, height: 720))
        )
        let manifest = RecordingManifest(
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            source: source,
            width: 2560,
            height: 1440,
            frameRate: 60,
            recordingPreset: .efficient,
            isHDR: true,
            includesSystemAudio: true,
            includesMicrophone: true,
            microphoneName: "Studio Mic",
            showsCursor: true,
            highlightsClicks: false
        )

        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(RecordingManifest.self, from: encoded)

        #expect(decoded == manifest)
        #expect(decoded.source.region?.cgRect == CGRect(x: 100, y: 80, width: 1280, height: 720))
        #expect(decoded.source.detail.contains("1280 × 720"))
    }

    @Test func recordingPauseTimelineRemovesPausedWallClockTimeAcrossEveryTrack() throws {
        var timeline = RecordingPauseTimeline()

        let initialOffsetValue = timeline.offset(
            for: CMTime(seconds: 1, preferredTimescale: 600),
            isVideo: true
        )
        let initialOffset = try #require(initialOffsetValue)
        #expect(initialOffset.seconds == 0)
        timeline.pause(at: CMTime(seconds: 4, preferredTimescale: 600))
        let pausedAudioOffset = timeline.offset(
            for: CMTime(seconds: 7, preferredTimescale: 600),
            isVideo: false
        )
        #expect(pausedAudioOffset == nil)

        timeline.requestResume()
        let earlyAudioOffset = timeline.offset(
            for: CMTime(seconds: 9.9, preferredTimescale: 600),
            isVideo: false
        )
        #expect(earlyAudioOffset == nil)
        let videoOffsetValue = timeline.offset(
            for: CMTime(seconds: 10, preferredTimescale: 600),
            isVideo: true
        )
        let videoOffset = try #require(videoOffsetValue)
        #expect(abs(videoOffset.seconds - 6) < 0.001)
        let bufferedAudioOffset = timeline.offset(
            for: CMTime(seconds: 9.99, preferredTimescale: 600),
            isVideo: false
        )
        #expect(bufferedAudioOffset == nil)

        let audioOffsetValue = timeline.offset(
            for: CMTime(seconds: 10.02, preferredTimescale: 600),
            isVideo: false
        )
        let audioOffset = try #require(audioOffsetValue)
        #expect(audioOffset == videoOffset)
        #expect(abs(CMTimeSubtract(CMTime(seconds: 10.02, preferredTimescale: 600), audioOffset).seconds - 4.02) < 0.001)
    }

    @Test func waveformRepositoryUsesTheExactTrimmedSourceRange() async throws {
        let sourceURL = try makeWaveformTestAudio { frame, sampleRate in
            let time = Double(frame) / sampleRate
            guard time >= 1 else { return 0 }
            return Float(sin(2 * Double.pi * 440 * time) * 0.8)
        }
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let asset = AVURLAsset(url: sourceURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let quiet = try await WaveformRepository.shared.samples(for: WaveformSliceRequest(
            sourceURL: sourceURL,
            sourceTrackID: track.trackID,
            sourceStart: 0.1,
            duration: 0.7,
            sampleCount: 180
        ))
        let tone = try await WaveformRepository.shared.samples(for: WaveformSliceRequest(
            sourceURL: sourceURL,
            sourceTrackID: track.trackID,
            sourceStart: 1.15,
            duration: 0.7,
            sampleCount: 180
        ))

        #expect(quiet.count == 180)
        #expect(tone.count == 180)
        #expect(mean(quiet) > 0.9)
        #expect(mean(tone) < 0.35)
    }

    @Test func waveformRepositoryKeepsContainerAudioTracksIndependent() async throws {
        let loudURL = try makeWaveformTestAudio { frame, sampleRate in
            Float(sin(2 * Double.pi * 220 * Double(frame) / sampleRate) * 0.85)
        }
        let quietURL = try makeWaveformTestAudio { frame, sampleRate in
            Float(sin(2 * Double.pi * 660 * Double(frame) / sampleRate) * 0.015)
        }
        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Multitrack Waveform \(UUID().uuidString)")
            .appendingPathExtension("mov")
        defer {
            try? FileManager.default.removeItem(at: loudURL)
            try? FileManager.default.removeItem(at: quietURL)
            try? FileManager.default.removeItem(at: containerURL)
        }

        let composition = AVMutableComposition()
        for sourceURL in [loudURL, quietURL] {
            let sourceAsset = AVURLAsset(url: sourceURL)
            let sourceTrack = try #require(try await sourceAsset.loadTracks(withMediaType: .audio).first)
            let sourceRange = try await sourceTrack.load(.timeRange)
            let targetTrack = try #require(composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ))
            try targetTrack.insertTimeRange(sourceRange, of: sourceTrack, at: .zero)
        }
        let exporter = try #require(AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ))
        try await exporter.export(to: containerURL, as: .mov)

        let exportedAsset = AVURLAsset(url: containerURL)
        let tracks = try await exportedAsset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 2)
        let first = try await WaveformRepository.shared.samples(for: WaveformSliceRequest(
            sourceURL: containerURL,
            sourceTrackID: tracks[0].trackID,
            sourceStart: 0,
            duration: 1,
            sampleCount: 180
        ))
        let second = try await WaveformRepository.shared.samples(for: WaveformSliceRequest(
            sourceURL: containerURL,
            sourceTrackID: tracks[1].trackID,
            sourceStart: 0,
            duration: 1,
            sampleCount: 180
        ))

        #expect(abs(mean(first) - mean(second)) > 0.35)
    }

    @Test func eachNewVideoGapIsAnIndependentBlackSegment() {
        var project = makeProject()
        project.splitClip(id: project.lanes[0].clips[0].id, at: 4)
        let secondID = project.lanes[0].clips[1].id
        _ = project.moveClip(id: secondID, to: 6)

        #expect(project.videoGaps.count == 1)
        #expect(project.videoGaps[0].timelineStart == 4)
        #expect(project.videoGaps[0].duration == 2)
        #expect(project.videoGaps[0].fillMode == .black)
    }

    @Test func videoGapsPreserveIndependentFillChoicesAsTheirBoundariesMove() {
        var project = makeProject()
        project.splitClip(id: project.lanes[0].clips[0].id, at: 4)
        let secondID = project.lanes[0].clips[1].id
        _ = project.moveClip(id: secondID, to: 6)
        let gapID = project.videoGaps[0].id
        project.setGapFillMode(.holdPrevious, gapID: gapID)

        _ = project.moveClip(id: secondID, to: 7)

        #expect(project.videoGaps.count == 1)
        #expect(project.videoGaps[0].id == gapID)
        #expect(project.videoGaps[0].timelineStart == 4)
        #expect(project.videoGaps[0].duration == 3)
        #expect(project.videoGaps[0].fillMode == .holdPrevious)
    }

    @Test func differentVideoGapsCanUseDifferentFillModes() {
        let url = URL(fileURLWithPath: "/tmp/source.mov")
        let clips = [
            TimelineClip(
                sourceURL: url,
                sourceTrackID: 1,
                sourceStart: 0,
                timelineStart: 0,
                duration: 2,
                name: "First"
            ),
            TimelineClip(
                sourceURL: url,
                sourceTrackID: 1,
                sourceStart: 2,
                timelineStart: 3,
                duration: 2,
                name: "Second"
            ),
            TimelineClip(
                sourceURL: url,
                sourceTrackID: 1,
                sourceStart: 4,
                timelineStart: 7,
                duration: 3,
                name: "Third"
            ),
        ]
        var project = TimelineProject(
            name: "Independent Gaps",
            lanes: [TimelineLane(kind: .video, name: "Screen", clips: clips)]
        )
        project.setGapFillMode(.holdPrevious, gapID: project.videoGaps[0].id)
        project.setGapFillMode(.holdNext, gapID: project.videoGaps[1].id)

        #expect(project.videoGaps.map(\.fillMode) == [.holdPrevious, .holdNext])
    }

    @Test func compositionBuilderRendersEveryGapModeFromOneCanonicalSourceAsset() async throws {
        let sourceURL = try await makeColorTestVideo()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let asset = AVURLAsset(url: sourceURL)
        let sourceTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let clips = [
            TimelineClip(
                sourceURL: sourceURL,
                sourceTrackID: sourceTrack.trackID,
                sourceStart: 0,
                timelineStart: 0,
                duration: 1,
                name: "Red"
            ),
            TimelineClip(
                sourceURL: sourceURL,
                sourceTrackID: sourceTrack.trackID,
                sourceStart: 2,
                timelineStart: 2,
                duration: 1,
                name: "Blue"
            ),
        ]
        var project = TimelineProject(
            name: "Rendered Gaps",
            lanes: [TimelineLane(kind: .video, name: "Screen", clips: clips)]
        )
        let gapID = try #require(project.videoGaps.first?.id)

        let expectedColors: [(TimelineGapFillMode, RGBAColor)] = [
            (.black, RGBAColor(red: 0, green: 0, blue: 0)),
            (.holdPrevious, RGBAColor(red: 255, green: 0, blue: 0)),
            (.holdNext, RGBAColor(red: 0, green: 0, blue: 255)),
        ]
        for (mode, expected) in expectedColors {
            project.setGapFillMode(mode, gapID: gapID)
            let build = try await TimelineCompositionBuilder.build(project)
            let actual = try await renderedColor(
                at: 1.5,
                composition: build.composition,
                videoComposition: build.videoComposition
            )
            #expect(actual.isClose(to: expected), "\(mode) rendered \(actual), expected \(expected)")
        }
    }

    private func makeProject() -> TimelineProject {
        let url = URL(fileURLWithPath: "/tmp/source.mov")
        let groupID = UUID()
        let video = TimelineClip(
            sourceURL: url,
            sourceTrackID: 1,
            sourceStart: 0,
            timelineStart: 0,
            duration: 10,
            name: "Screen",
            linkedGroupID: groupID
        )
        let audio = TimelineClip(
            sourceURL: url,
            sourceTrackID: 2,
            sourceStart: 0,
            timelineStart: 0,
            duration: 10,
            name: "System Audio",
            linkedGroupID: groupID
        )
        return TimelineProject(
            name: "Test",
            lanes: [
                TimelineLane(kind: .video, name: "Screen", clips: [video]),
                TimelineLane(kind: .systemAudio, name: "System Audio", clips: [audio]),
            ]
        )
    }

    private func makeColorTestVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Gap Test \(UUID().uuidString)")
            .appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        guard writer.canAdd(input) else { throw TestMediaError.cannotAddVideoInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TestMediaError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            let color: RGBAColor
            if frame < 30 {
                color = RGBAColor(red: 255, green: 0, blue: 0)
            } else if frame < 60 {
                color = RGBAColor(red: 0, green: 255, blue: 0)
            } else {
                color = RGBAColor(red: 0, green: 0, blue: 255)
            }
            let pixelBuffer = try makePixelBuffer(color: color)
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? TestMediaError.writerFailed
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? TestMediaError.writerFailed
        }
        return url
    }

    private func makeWaveformTestAudio(
        sample: (_ frame: Int, _ sampleRate: Double) -> Float
    ) throws -> URL {
        let sampleRate = 48_000.0
        let frameCount = Int(sampleRate * 2)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Waveform Test \(UUID().uuidString)")
            .appendingPathExtension("caf")
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channel = try #require(buffer.floatChannelData?[0])
        for frame in 0..<frameCount {
            channel[frame] = sample(frame, sampleRate)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func mean(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    private func makePixelBuffer(color: RGBAColor) throws -> CVPixelBuffer {
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
            throw TestMediaError.cannotCreatePixelBuffer
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw TestMediaError.cannotCreatePixelBuffer
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<64 {
            let row = baseAddress.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<64 {
                row[x * 4] = color.blue
                row[x * 4 + 1] = color.green
                row[x * 4 + 2] = color.red
                row[x * 4 + 3] = 255
            }
        }
        return pixelBuffer
    }

    private func renderedColor(
        at seconds: TimeInterval,
        composition: AVComposition,
        videoComposition: AVVideoComposition?
    ) async throws -> RGBAColor {
        let generator = AVAssetImageGenerator(asset: composition)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let requestedTime = CMTime(seconds: seconds, preferredTimescale: 600)
        let image = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CGImage, Error>) in
            generator.generateCGImageAsynchronously(for: requestedTime) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? TestMediaError.writerFailed)
                }
            }
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            CIImage(cgImage: image),
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 32, y: 32, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return RGBAColor(red: pixel[0], green: pixel[1], blue: pixel[2])
    }
}

private struct RGBAColor: CustomStringConvertible {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var description: String { "rgb(\(red), \(green), \(blue))" }

    func isClose(to other: RGBAColor, tolerance: Int = 45) -> Bool {
        abs(Int(red) - Int(other.red)) <= tolerance
            && abs(Int(green) - Int(other.green)) <= tolerance
            && abs(Int(blue) - Int(other.blue)) <= tolerance
    }
}

private enum TestMediaError: Error {
    case cannotAddVideoInput
    case cannotCreatePixelBuffer
    case writerFailed
}

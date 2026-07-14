import AVKit
import CoreMedia
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import IOSurface
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

    @Test func everyCapturePhaseHasOneDeterministicStopOperation() {
        #expect(CaptureState.idle.stopOperation == .none)
        #expect(CaptureState.sourceSelected.stopOperation == .none)
        #expect(CaptureState.countingDown(3).stopOperation == .cancelCountdown)
        #expect(CaptureState.starting.stopOperation == .cancelStartup)
        #expect(CaptureState.recording.stopOperation == .finishRecording)
        #expect(CaptureState.paused.stopOperation == .finishRecording)
        #expect(CaptureState.stopping.stopOperation == .none)
        #expect(CaptureState.failed("test").stopOperation == .none)

        #expect(CaptureState.countingDown(3).stopButtonTitle == "Cancel")
        #expect(CaptureState.starting.stopButtonTitle == "Cancel Start")
        #expect(CaptureState.recording.stopButtonTitle == "Stop Recording")
        #expect(CaptureState.stopping.stopButtonTitle == "Finishing…")
    }

    @Test func captureCompletionRoutesOnlySavedMediaToPostRecordingDestinations() {
        let url = URL(fileURLWithPath: "/tmp/Reccy Completion.mov")

        for preference in RecordingCompletionDestination.allCases {
            #expect(
                CaptureSessionCompletion.Outcome.cancelled.navigation(for: preference)
                    == CaptureCompletionNavigation(section: .record, recordingURL: nil)
            )
        }
        #expect(
            CaptureSessionCompletion.Outcome.saved(url).navigation(for: .library)
                == CaptureCompletionNavigation(section: .library, recordingURL: url)
        )
        #expect(
            CaptureSessionCompletion.Outcome.saved(url).navigation(for: .editor)
                == CaptureCompletionNavigation(section: .editor, recordingURL: url)
        )
        #expect(
            CaptureSessionCompletion.Outcome.saved(url).navigation(for: .record)
                == CaptureCompletionNavigation(section: .record, recordingURL: url)
        )
    }

    @Test func livePreviewRoutesTheWritersIOSurfaceWithoutCopyingIt() throws {
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
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
        let previewFrame = try #require(CapturePreviewPipeline.frame(from: source))
        let sourceSurface = try #require(
            CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue()
        )
        #expect(
            IOSurfaceGetID(unsafeBitCast(previewFrame.surface, to: IOSurfaceRef.self))
                == IOSurfaceGetID(sourceSurface)
        )
    }

#if DEBUG
    @Test func monitorVisualHarnessProducesACompleteVideoFrame() throws {
        let sampleBuffer = try #require(CaptureCoordinator.makePreviewQASampleBuffer())
        #expect(CMSampleBufferIsValid(sampleBuffer))
        #expect(CMSampleBufferDataIsReady(sampleBuffer))
        #expect(CapturePreviewPipeline.frame(from: sampleBuffer) != nil)
    }

    @Test @MainActor func detachingAnAdaptivePreviewCandidateKeepsTheVisibleConsumerAttached() async throws {
        let pipeline = CapturePreviewPipeline()
        var visibleFrameCount = 0
        var discardedFrameCount = 0
        let visibleID = pipeline.attach { frame in
            if frame != nil { visibleFrameCount += 1 }
        }
        let discardedID = pipeline.attach { frame in
            if frame != nil { discardedFrameCount += 1 }
        }

        // ViewThatFits can construct both layout candidates, then dismantle
        // the unused one. Detaching it must not remove the visible preview.
        pipeline.detach(discardedID)
        pipeline.enqueue(try #require(CaptureCoordinator.makePreviewQASampleBuffer()))
        try await Task.sleep(for: .milliseconds(20))

        #expect(visibleFrameCount == 1)
        #expect(discardedFrameCount == 0)
        pipeline.detach(visibleID)
    }
#endif

    @Test @MainActor func livePreviewPipelineSharesTheIOSurfaceWithTheHostedLayer() async throws {
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
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
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
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

        let pipeline = CapturePreviewPipeline()
        var delivered: CapturePreviewFrame?
        let attachmentID = pipeline.attach { delivered = $0 }
        pipeline.enqueue(source)
        try await Task.sleep(for: .milliseconds(20))

        let deliveredFrame = try #require(delivered)
        let sourceSurface = try #require(
            CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue()
        )
        #expect(
            IOSurfaceGetID(unsafeBitCast(deliveredFrame.surface, to: IOSurfaceRef.self))
                == IOSurfaceGetID(sourceSurface)
        )
        #expect(deliveredFrame.contentRect == CGRect(x: 0, y: 0, width: 16, height: 16))

        let previewView = CaptureSurfacePreviewNSView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        let window = NSWindow(
            contentRect: previewView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = previewView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        previewView.display(deliveredFrame)
        for _ in 0..<20 where !previewView.isReadyForDisplay {
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(previewView.rendererError == nil)
        #expect(previewView.isReadyForDisplay)
        pipeline.detach(attachmentID)
        await Task.yield()
        #expect(delivered == nil)
    }

    @Test func activeRecordingFileSizeUsesFreshFilesystemMetadata() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Growing File \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data(repeating: 0xAA, count: 64).write(to: url)
        #expect(MultitrackRecorder.currentFileSize(at: url) == 64)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xBB, count: 128))
        try handle.synchronize()
        try handle.close()

        #expect(MultitrackRecorder.currentFileSize(at: url) == 192)
    }

    @Test func nativeEditorPlayerViewCanBeCreated() {
        let player = AVPlayer()
        let playerView = AVPlayerView()
        playerView.player = player

        #expect(playerView.player === player)
    }

    @Test @MainActor func unsupportedEditorProjectCanResetWithoutTouchingSourceMedia() async throws {
        let mediaURL = try await makeColorTestVideo()
        let packageURL = mediaURL
            .deletingLastPathComponent()
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(
                "\(mediaURL.deletingPathExtension().lastPathComponent).reccyproject",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: mediaURL)
            try? FileManager.default.removeItem(at: packageURL)
        }

        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data("{\"formatVersion\":2}".utf8).write(
            to: packageURL.appendingPathComponent("project.json")
        )
        let sourceData = try Data(contentsOf: mediaURL)
        let fileSize = try mediaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let item = RecordingItem(
            url: mediaURL,
            createdAt: Date(),
            fileSize: Int64(fileSize),
            duration: 3,
            manifest: makeRecoveryManifest()
        )
        let controller = TimelineEditorController()

        await controller.open(item)

        #expect(controller.project == nil)
        #expect(controller.canResetUnsupportedProject)
        #expect(controller.errorMessage != nil)
        #expect(FileManager.default.fileExists(atPath: packageURL.path))

        await controller.resetUnsupportedProject()

        #expect(controller.project?.formatVersion == TimelineProject.currentFormatVersion)
        #expect(controller.errorMessage == nil)
        #expect(!controller.canResetUnsupportedProject)
        #expect(try Data(contentsOf: mediaURL) == sourceData)
        let savedData = try Data(contentsOf: packageURL.appendingPathComponent("project.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(TimelineProject.self, from: savedData).formatVersion
            == TimelineProject.currentFormatVersion)
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

    @Test func exportCompatibilityIsDeterminedFromTheActualAsset() async throws {
        let videoURL = try await makeColorTestVideo()
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let source = ExportSource(
            name: "Video Only",
            asset: AVURLAsset(url: videoURL),
            sourceURL: videoURL
        )

        let presets = await ExportService().compatiblePresets(for: source)

        #expect(presets.contains(.hevc1080))
        #expect(presets.contains(.h264720))
        #expect(!presets.contains(.audioM4A))
    }

    @Test func everyDeliveryPresetExportsAndValidatesRealMedia() async throws {
        let fixtureURL = try await makeExportFixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Export Matrix \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: fixtureURL)
            try? FileManager.default.removeItem(at: directory)
        }

        let source = ExportSource(
            name: "Export Matrix",
            asset: AVURLAsset(url: fixtureURL),
            sourceURL: fixtureURL
        )
        let service = ExportService()
        let compatible = await service.compatiblePresets(for: source)
        #expect(compatible == Set(ExportPreset.allCases))

        for preset in ExportPreset.allCases {
            let destination = directory
                .appendingPathComponent(preset.rawValue)
                .appendingPathExtension(preset.fileExtension)
            var phases: [ExportProgressPhase] = []
            let result = try await service.export(
                source: source,
                destinationURL: destination,
                preset: preset
            ) { update in
                phases.append(update.phase)
            }

            #expect(result.url == destination)
            #expect(result.fileSize > 0)
            #expect(result.duration > 2.8)
            #expect(preset.includesVideo ? result.videoTrackCount > 0 : result.videoTrackCount == 0)
            #expect(preset.requiresAudio ? result.audioTrackCount > 0 : true)
            #expect(phases.contains(.preparing))
            #expect(phases.contains(.validating))
            #expect(phases.contains(.finishing))
        }

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".reccy-export-") }
        #expect(leftovers.isEmpty)
    }

    @Test func exportAtomicallyReplacesAnExistingDestination() async throws {
        let sourceURL = try await makeColorTestVideo()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Export Replace \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: directory)
        }
        let destination = directory.appendingPathComponent("Existing.mp4")
        try Data("keep this until success".utf8).write(to: destination)
        let source = ExportSource(
            name: "Replace Test",
            asset: AVURLAsset(url: sourceURL),
            sourceURL: sourceURL
        )

        let result = try await ExportService().export(
            source: source,
            destinationURL: destination,
            preset: .h264720
        )

        #expect(result.url == destination)
        #expect(result.videoTrackCount == 1)
        #expect(try Data(contentsOf: destination) != Data("keep this until success".utf8))
    }

    @Test func timelineAudioMixIsAppliedToTheExport() async throws {
        let fixtureURL = try await makeExportFixture()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Muted Export \(UUID().uuidString)")
            .appendingPathExtension("m4a")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL)
            try? FileManager.default.removeItem(at: destination)
        }

        let asset = AVURLAsset(url: fixtureURL)
        let sourceAudioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let parameters = AVMutableAudioMixInputParameters(track: sourceAudioTrack)
        parameters.setVolume(0, at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        let source = ExportSource(
            name: "Muted Timeline",
            asset: asset,
            sourceURL: fixtureURL,
            audioMix: mix
        )

        _ = try await ExportService().export(
            source: source,
            destinationURL: destination,
            preset: .audioM4A
        )

        let outputAsset = AVURLAsset(url: destination)
        let outputTrack = try #require(try await outputAsset.loadTracks(withMediaType: .audio).first)
        let samples = try await WaveformRepository.shared.samples(for: WaveformSliceRequest(
            sourceURL: destination,
            sourceTrackID: outputTrack.trackID,
            sourceStart: 0,
            duration: 2.5,
            sampleCount: 180
        ))
        #expect(mean(samples) > 0.98)
    }

    @Test func exportNeverOverwritesItsSourceRecording() async throws {
        let sourceURL = try await makeColorTestVideo()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let source = ExportSource(
            name: "Protected Source",
            asset: AVURLAsset(url: sourceURL),
            sourceURL: sourceURL
        )

        await #expect(throws: ExportServiceError.sourceWouldBeOverwritten) {
            _ = try await ExportService().export(
                source: source,
                destinationURL: sourceURL,
                preset: .h264720
            )
        }
    }

    @Test func cancelledExportLeavesAnExistingDestinationUntouched() async throws {
        let sourceURL = try await makeColorTestVideo(frameCount: 1_800)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Export Cancel \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: directory)
        }
        let destination = directory.appendingPathComponent("Existing.mp4")
        let sentinel = Data("original destination".utf8)
        try sentinel.write(to: destination)
        let source = ExportSource(
            name: "Cancel Test",
            asset: AVURLAsset(url: sourceURL),
            sourceURL: sourceURL
        )

        let (startedStream, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        var signaledStart = false
        let task = Task {
            defer { startedContinuation.finish() }
            return try await ExportService().export(
                source: source,
                destinationURL: destination,
                preset: .proRes4444
            ) { update in
                if update.phase == .exporting, !signaledStart {
                    signaledStart = true
                    startedContinuation.yield()
                }
            }
        }
        let enteredExport = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in startedStream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(enteredExport)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A canceled export unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("A canceled export returned \(error)")
        }

        #expect(try Data(contentsOf: destination) == sentinel)
    }

    @Test func storagePreflightScalesWithTheActualCaptureBitrate() {
        let efficient = MultitrackRecordingOptions(
            width: 1920,
            height: 1080,
            frameRate: 30,
            preset: .efficient,
            includesSystemAudio: false,
            includesMicrophone: false,
            isHDR: false
        )
        let highBandwidth = MultitrackRecordingOptions(
            width: 3840,
            height: 2160,
            frameRate: 60,
            preset: .hevcMaster,
            includesSystemAudio: true,
            includesMicrophone: true,
            isHDR: true
        )

        #expect(RecordingStoragePolicy.requiredPreflightBytes(for: highBandwidth)
            > RecordingStoragePolicy.requiredPreflightBytes(for: efficient))
        #expect(RecordingStoragePolicy.requiredPreflightBytes(for: efficient)
            > RecordingStoragePolicy.runtimeReserveBytes)
    }

    @Test func storagePreflightFailsBeforeTheRuntimeReserveIsAtRisk() {
        let options = MultitrackRecordingOptions(
            width: 2560,
            height: 1440,
            frameRate: 30,
            preset: .efficient,
            includesSystemAudio: true,
            includesMicrophone: true,
            isHDR: false
        )
        let required = RecordingStoragePolicy.requiredPreflightBytes(for: options)

        #expect(throws: RecordingStorageError.self) {
            try RecordingStoragePolicy.validatePreflight(
                availableBytes: required - 1,
                options: options
            )
        }
        #expect(throws: Never.self) {
            try RecordingStoragePolicy.validatePreflight(
                availableBytes: required,
                options: options
            )
        }
    }

    @Test func recoveryJournalRoundTripsAtomicallyBesideItsMedia() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Recovery \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("Interrupted Recording.mp4")
        let manifest = makeRecoveryManifest()

        let journalURL = try RecordingRecoveryJournal.write(
            mediaURL: mediaURL,
            manifest: manifest
        )
        let loaded = try RecordingRecoveryJournal.load(from: directory)
        let restored = try #require(loaded)

        #expect(journalURL == RecordingRecoveryJournal.url(in: directory))
        #expect(restored.mediaFileName == mediaURL.lastPathComponent)
        #expect(restored.manifest == manifest)
        #expect(throws: RecordingRecoveryError.self) {
            _ = try RecordingRecoveryJournal.write(
                mediaURL: directory.appendingPathComponent("New Recording.mp4"),
                manifest: manifest
            )
        }
        try RecordingRecoveryJournal.remove(from: directory)
        let removed = try RecordingRecoveryJournal.load(from: directory)
        #expect(removed == nil)
    }

    @Test func recordingLeaseSerializesCaptureAndRecoveryWithinOneProcess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Lease \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writerLease = try RecordingSessionLease.acquire(in: directory)
        #expect(throws: RecordingLeaseError.alreadyHeld) {
            _ = try RecordingSessionLease.acquire(in: directory)
        }

        writerLease.release()
        let recoveryLease = try RecordingSessionLease.acquire(in: directory)
        recoveryLease.release()
    }

    @Test func recordingLeaseRejectsAnIndependentWriterProcess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Cross Process Lease \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let child = Process()
        let childInput = Pipe()
        let childOutput = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            """
            import fcntl, os, sys
            descriptor = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
            fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            sys.stdout.write("locked\\n")
            sys.stdout.flush()
            sys.stdin.read(1)
            os.close(descriptor)
            """,
            directory.appendingPathComponent(RecordingSessionLease.fileName).path,
        ]
        child.standardInput = childInput
        child.standardOutput = childOutput
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }

        let acknowledgementData = try childOutput.fileHandleForReading.read(upToCount: 7)
        let acknowledgement = try #require(acknowledgementData)
        #expect(String(decoding: acknowledgement, as: UTF8.self) == "locked\n")
        #expect(throws: RecordingLeaseError.alreadyHeld) {
            _ = try RecordingSessionLease.acquire(in: directory)
        }

        try childInput.fileHandleForWriting.write(contentsOf: Data([0]))
        childInput.fileHandleForWriting.closeFile()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)

        let lease = try RecordingSessionLease.acquire(in: directory)
        lease.release()
    }

    @Test func recoveryWaitsForTheActiveWriterLease() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Leased Recovery \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let generated = try await makeColorTestVideo()
        let mediaURL = directory.appendingPathComponent("Still Recording.mov")
        try FileManager.default.moveItem(at: generated, to: mediaURL)
        _ = try RecordingRecoveryJournal.write(
            mediaURL: mediaURL,
            manifest: makeRecoveryManifest()
        )
        let writerLease = try RecordingSessionLease.acquire(in: directory)
        let library = RecordingLibrary(directoryURL: directory)

        try await Task.sleep(for: .milliseconds(500))
        #expect(library.recoveryNotice == nil)
        #expect(try RecordingRecoveryJournal.load(from: directory) != nil)

        writerLease.release()
        for _ in 0..<200 where library.recoveryNotice == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(library.recoveryNotice?.kind == .recovered)
        #expect(try RecordingRecoveryJournal.load(from: directory) == nil)
    }

    @Test func interruptedPlayableRecordingIsRestoredToTheLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Playable Recovery \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let generated = try await makeColorTestVideo()
        let mediaURL = directory.appendingPathComponent("Recovered Recording.mov")
        try FileManager.default.moveItem(at: generated, to: mediaURL)
        let manifest = makeRecoveryManifest()
        _ = try RecordingRecoveryJournal.write(mediaURL: mediaURL, manifest: manifest)

        let library = RecordingLibrary(directoryURL: directory)
        for _ in 0..<100 where library.recoveryNotice == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(library.recoveryNotice?.kind == .recovered)
        #expect(library.recordings
            .map { $0.url.resolvingSymlinksInPath() }
            .contains(mediaURL.resolvingSymlinksInPath()))
        #expect(FileManager.default.fileExists(
            atPath: RecordingManifest.sidecarURL(for: mediaURL).path
        ))
        let remainingJournal = try RecordingRecoveryJournal.load(from: directory)
        #expect(remainingJournal == nil)
    }

    @Test func interruptedInvalidMediaIsPreservedForInspection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Invalid Recovery \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let mediaURL = directory.appendingPathComponent("Broken Recording.mp4")
        try Data("not media".utf8).write(to: mediaURL)
        _ = try RecordingRecoveryJournal.write(
            mediaURL: mediaURL,
            manifest: makeRecoveryManifest()
        )

        let library = RecordingLibrary(directoryURL: directory)
        for _ in 0..<100 where library.recoveryNotice == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let preservedURL = try #require(library.recoveryNotice?.fileURL)
        #expect(library.recoveryNotice?.kind == .warning)
        #expect(preservedURL.lastPathComponent.contains("Interrupted"))
        #expect(FileManager.default.fileExists(atPath: preservedURL.path))
        #expect(!FileManager.default.fileExists(atPath: mediaURL.path))
        let remainingJournal = try RecordingRecoveryJournal.load(from: directory)
        #expect(remainingJournal == nil)
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
            frameRate: 60,
            lanes: [TimelineLane(kind: .video, name: "Screen", clips: clips)]
        )
        let gapID = try #require(project.videoGaps.first?.id)
        let cadenceBuild = try await TimelineCompositionBuilder.build(project)
        let videoComposition = try #require(cadenceBuild.videoComposition)
        #expect(abs(videoComposition.frameDuration.seconds - (1 / 60)) < 0.000_1)

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

    private func makeRecoveryManifest() -> RecordingManifest {
        RecordingManifest(
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            source: CaptureSourceDescriptor(
                kind: .display,
                name: "Studio Display",
                applicationName: nil,
                applicationBundleIdentifier: nil,
                windowName: nil,
                windowIDs: [],
                displayID: 42,
                displayName: "Studio Display",
                region: nil
            ),
            width: 2560,
            height: 1440,
            frameRate: 30,
            recordingPreset: .efficient,
            isHDR: false,
            includesSystemAudio: true,
            includesMicrophone: false,
            microphoneName: nil,
            showsCursor: true,
            highlightsClicks: true
        )
    }

    private func makeColorTestVideo(frameCount: Int = 90) async throws -> URL {
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

        for frame in 0..<frameCount {
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

    private func makeExportFixture() async throws -> URL {
        let videoURL = try await makeColorTestVideo()
        let audioURL = try makeWaveformTestAudio(duration: 3) { frame, sampleRate in
            Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate) * 0.35)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Export Fixture \(UUID().uuidString)")
            .appendingPathExtension("mov")
        do {
            let composition = AVMutableComposition()
            let videoAsset = AVURLAsset(url: videoURL)
            let videoTrack = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
            let videoRange = try await videoTrack.load(.timeRange)
            let targetVideo = try #require(composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ))
            try targetVideo.insertTimeRange(videoRange, of: videoTrack, at: .zero)

            let audioAsset = AVURLAsset(url: audioURL)
            let audioTrack = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
            let audioRange = try await audioTrack.load(.timeRange)
            let targetAudio = try #require(composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ))
            try targetAudio.insertTimeRange(audioRange, of: audioTrack, at: .zero)

            let exporter = try #require(AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetPassthrough
            ))
            try await exporter.export(to: destination, as: .mov)
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func makeWaveformTestAudio(
        duration: TimeInterval = 2,
        sample: (_ frame: Int, _ sampleRate: Double) -> Float
    ) throws -> URL {
        let sampleRate = 48_000.0
        let frameCount = Int(sampleRate * duration)
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

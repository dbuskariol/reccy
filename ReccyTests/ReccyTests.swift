import CoreGraphics
import Foundation
import Testing
@testable import Reccy

@Suite("Reccy")
struct ReccyTests {
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
}

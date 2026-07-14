import AVFoundation
import CoreGraphics
import Foundation

enum TimelineCompositionBuildError: LocalizedError {
    case couldNotCreateTrack(TimelineLaneKind)
    case missingSourceTrack(URL, CMPersistentTrackID)
    case couldNotInsertClip(String, Error)
    case couldNotFillGap(TimelineGapFillMode, Error)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateTrack(let kind):
            "Reccy couldn’t create the \(laneTitle(kind).lowercased()) timeline track."
        case .missingSourceTrack(let url, let trackID):
            "Track \(trackID) is no longer available in \(url.lastPathComponent)."
        case .couldNotInsertClip(let name, _):
            "Reccy couldn’t add \(name) to the timeline."
        case .couldNotFillGap(let mode, _):
            "Reccy couldn’t render the \(gapTitle(mode).lowercased()) gap."
        }
    }

    private func laneTitle(_ kind: TimelineLaneKind) -> String {
        switch kind {
        case .video: "Screen"
        case .systemAudio: "System Audio"
        case .microphone: "Microphone"
        case .voiceover: "Voiceover"
        }
    }

    private func gapTitle(_ mode: TimelineGapFillMode) -> String {
        switch mode {
        case .black: "Black"
        case .holdPrevious: "Hold Previous"
        case .holdNext: "Hold Next"
        }
    }

    var underlyingError: Error? {
        switch self {
        case .couldNotInsertClip(_, let error), .couldNotFillGap(_, let error): error
        case .couldNotCreateTrack, .missingSourceTrack: nil
        }
    }
}

struct TimelineCompositionBuild {
    let composition: AVMutableComposition
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
}

/// Assembles the editable timeline into AVFoundation playback primitives.
///
/// Each media URL is represented by exactly one `AVURLAsset` per build. This
/// invariant matters for held-frame edits: mixing `AVAssetTrack` instances from
/// separate assets that point at the same file can make AVFoundation reject an
/// otherwise valid insertion with OSStatus -12780.
@MainActor
enum TimelineCompositionBuilder {
    static func build(_ project: TimelineProject) async throws -> TimelineCompositionBuild {
        let sources = try await loadSources(for: project)
        let composition = AVMutableComposition()
        var audioParameters: [AVMutableAudioMixInputParameters] = []
        var videoCompositionTrack: AVMutableCompositionTrack?
        var videoRenderSize: CGSize?
        var videoTransform = CGAffineTransform.identity

        for lane in project.lanes where !lane.clips.isEmpty {
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: lane.kind.mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw TimelineCompositionBuildError.couldNotCreateTrack(lane.kind)
            }

            let sortedClips = lane.clips.sorted(by: { $0.timelineStart < $1.timelineStart })
            var previousVideoSource: (clip: TimelineClip, track: AVAssetTrack)?
            var videoCursor: TimeInterval = 0

            for clip in sortedClips {
                let key = SourceTrackKey(
                    url: clip.sourceURL,
                    mediaType: lane.kind.mediaType,
                    trackID: clip.sourceTrackID
                )
                guard let sourceTrack = sources.tracks[key] else {
                    throw TimelineCompositionBuildError.missingSourceTrack(
                        clip.sourceURL,
                        clip.sourceTrackID
                    )
                }

                if lane.kind == .video, clip.timelineStart > videoCursor + 0.000_1 {
                    let gap = videoCursor..<clip.timelineStart
                    let fillMode = gapFillMode(for: gap, in: project)
                    do {
                        try fillVideoGap(
                            gap,
                            mode: fillMode,
                            frameDuration: project.frameDuration,
                            compositionTrack: compositionTrack,
                            previous: previousVideoSource,
                            next: (clip, sourceTrack)
                        )
                    } catch {
                        throw TimelineCompositionBuildError.couldNotFillGap(
                            fillMode,
                            error
                        )
                    }
                }

                do {
                    try compositionTrack.insertTimeRange(
                        CMTimeRange(
                            start: timelineTime(clip.sourceStart),
                            duration: timelineTime(clip.duration)
                        ),
                        of: sourceTrack,
                        at: timelineTime(clip.timelineStart)
                    )
                } catch {
                    throw TimelineCompositionBuildError.couldNotInsertClip(clip.name, error)
                }

                if lane.kind == .video {
                    let transform = try await sourceTrack.load(.preferredTransform)
                    compositionTrack.preferredTransform = transform
                    if videoRenderSize == nil {
                        let naturalSize = try await sourceTrack.load(.naturalSize)
                        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
                        videoRenderSize = CGSize(
                            width: abs(transformed.width),
                            height: abs(transformed.height)
                        )
                        videoTransform = transform
                    }
                    previousVideoSource = (clip, sourceTrack)
                    videoCursor = clip.timelineEnd
                }
            }

            if lane.kind == .video {
                if project.duration > videoCursor + 0.000_1 {
                    let gap = videoCursor..<project.duration
                    let fillMode = gapFillMode(for: gap, in: project)
                    do {
                        try fillVideoGap(
                            gap,
                            mode: fillMode,
                            frameDuration: project.frameDuration,
                            compositionTrack: compositionTrack,
                            previous: previousVideoSource,
                            next: nil
                        )
                    } catch {
                        throw TimelineCompositionBuildError.couldNotFillGap(
                            fillMode,
                            error
                        )
                    }
                }
                videoCompositionTrack = compositionTrack
            } else {
                let parameters = AVMutableAudioMixInputParameters(track: compositionTrack)
                parameters.setVolume(lane.isMuted ? 0 : Float(lane.volume), at: .zero)
                audioParameters.append(parameters)
            }
        }

        let videoComposition = makeVideoComposition(
            track: videoCompositionTrack,
            renderSize: videoRenderSize,
            transform: videoTransform,
            duration: project.duration,
            frameDuration: project.frameDuration
        )
        let audioMix: AVAudioMix?
        if audioParameters.isEmpty {
            audioMix = nil
        } else {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioParameters
            audioMix = mix
        }

        // Retaining `sources` until assembly completes is intentional. Its
        // canonical AVURLAssets own every source track used above.
        withExtendedLifetime(sources.assets) {}
        return TimelineCompositionBuild(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix
        )
    }

    private static func loadSources(for project: TimelineProject) async throws -> LoadedSources {
        var assets: [URL: AVURLAsset] = [:]
        var requestedTypes: [URL: Set<String>] = [:]
        for lane in project.lanes {
            for clip in lane.clips {
                assets[clip.sourceURL] = assets[clip.sourceURL] ?? AVURLAsset(url: clip.sourceURL)
                requestedTypes[clip.sourceURL, default: []].insert(lane.kind.mediaType.rawValue)
            }
        }

        var tracks: [SourceTrackKey: AVAssetTrack] = [:]
        for (url, asset) in assets {
            for rawMediaType in requestedTypes[url, default: []] {
                let mediaType = AVMediaType(rawValue: rawMediaType)
                for track in try await asset.loadTracks(withMediaType: mediaType) {
                    tracks[
                        SourceTrackKey(url: url, mediaType: mediaType, trackID: track.trackID)
                    ] = track
                }
            }
        }
        return LoadedSources(assets: assets, tracks: tracks)
    }

    private static func fillVideoGap(
        _ gap: Range<TimeInterval>,
        mode: TimelineGapFillMode,
        frameDuration: TimeInterval,
        compositionTrack: AVMutableCompositionTrack,
        previous: (clip: TimelineClip, track: AVAssetTrack)?,
        next: (clip: TimelineClip, track: AVAssetTrack)?
    ) throws {
        let duration = gap.upperBound - gap.lowerBound
        guard duration > 0.000_1 else { return }

        switch mode {
        case .black:
            compositionTrack.insertEmptyTimeRange(
                CMTimeRange(start: timelineTime(gap.lowerBound), duration: timelineTime(duration))
            )

        case .holdPrevious:
            guard let previous else {
                compositionTrack.insertEmptyTimeRange(
                    CMTimeRange(start: timelineTime(gap.lowerBound), duration: timelineTime(duration))
                )
                return
            }
            try insertHeldFrame(
                from: previous.clip,
                sourceTrack: previous.track,
                sourceTime: previous.clip.sourceStart + max(0, previous.clip.duration - frameDuration),
                into: gap,
                frameDuration: frameDuration,
                compositionTrack: compositionTrack
            )

        case .holdNext:
            guard let next else {
                compositionTrack.insertEmptyTimeRange(
                    CMTimeRange(start: timelineTime(gap.lowerBound), duration: timelineTime(duration))
                )
                return
            }
            try insertHeldFrame(
                from: next.clip,
                sourceTrack: next.track,
                sourceTime: next.clip.sourceStart,
                into: gap,
                frameDuration: frameDuration,
                compositionTrack: compositionTrack
            )
        }
    }

    private static func gapFillMode(
        for range: Range<TimeInterval>,
        in project: TimelineProject
    ) -> TimelineGapFillMode {
        project.videoGaps.first(where: {
            abs($0.timelineStart - range.lowerBound) < 0.000_1
                && abs($0.timelineEnd - range.upperBound) < 0.000_1
        })?.fillMode ?? .black
    }

    private static func insertHeldFrame(
        from clip: TimelineClip,
        sourceTrack: AVAssetTrack,
        sourceTime: TimeInterval,
        into gap: Range<TimeInterval>,
        frameDuration: TimeInterval,
        compositionTrack: AVMutableCompositionTrack
    ) throws {
        let frameDuration = min(frameDuration, clip.duration)
        let insertionTime = timelineTime(gap.lowerBound)
        let insertedRange = CMTimeRange(
            start: insertionTime,
            duration: timelineTime(frameDuration)
        )
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: timelineTime(sourceTime), duration: insertedRange.duration),
            of: sourceTrack,
            at: insertionTime
        )
        compositionTrack.scaleTimeRange(
            insertedRange,
            toDuration: timelineTime(gap.upperBound - gap.lowerBound)
        )
    }

    private static func makeVideoComposition(
        track: AVMutableCompositionTrack?,
        renderSize: CGSize?,
        transform: CGAffineTransform,
        duration: TimeInterval,
        frameDuration: TimeInterval
    ) -> AVVideoComposition? {
        guard
            let track,
            let renderSize,
            renderSize.width > 0,
            renderSize.height > 0,
            duration > 0
        else { return nil }

        var layerConfiguration = AVVideoCompositionLayerInstruction.Configuration(trackID: track.trackID)
        layerConfiguration.setTransform(transform, at: .zero)
        let layerInstruction = AVVideoCompositionLayerInstruction(configuration: layerConfiguration)

        var instructionConfiguration = AVVideoCompositionInstruction.Configuration()
        instructionConfiguration.timeRange = CMTimeRange(
            start: .zero,
            duration: timelineTime(duration)
        )
        instructionConfiguration.backgroundColor = CGColor.black
        instructionConfiguration.layerInstructions = [layerInstruction]
        let instruction = AVVideoCompositionInstruction(configuration: instructionConfiguration)

        var configuration = AVVideoComposition.Configuration()
        configuration.renderSize = renderSize
        configuration.frameDuration = timelineTime(frameDuration)
        configuration.instructions = [instruction]
        return AVVideoComposition(configuration: configuration)
    }

    private static func timelineTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}

private struct LoadedSources {
    let assets: [URL: AVURLAsset]
    let tracks: [SourceTrackKey: AVAssetTrack]
}

private struct SourceTrackKey: Hashable {
    let url: URL
    let mediaType: String
    let trackID: CMPersistentTrackID

    init(url: URL, mediaType: AVMediaType, trackID: CMPersistentTrackID) {
        self.url = url
        self.mediaType = mediaType.rawValue
        self.trackID = trackID
    }
}

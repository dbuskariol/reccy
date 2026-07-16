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
        case .camera: "Camera"
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
    let renderSize: CGSize?

    /// Video-composition instructions are bound to the tracks in this exact
    /// composition. Keep playback on the canonical asset instead of copying it
    /// independently, which can make AVFoundation resolve layered screen and
    /// camera instructions against different track instances.
    @MainActor
    func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.seekingWaitsForVideoCompositionRendering = true
        return item
    }
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
        var primaryVideoTrack: AVMutableCompositionTrack?
        var videoLayers: [(kind: TimelineLaneKind, instruction: AVVideoCompositionLayerInstruction)] = []
        let videoRenderSize = try await primaryVideoRenderSize(for: project, sources: sources)

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
            var primaryVideoTransforms: [(range: Range<TimeInterval>, transform: CGAffineTransform)] = []
            var videoLayerConfiguration = lane.kind.isVideo
                ? AVVideoCompositionLayerInstruction.Configuration(trackID: compositionTrack.trackID)
                : nil
            if lane.kind == .camera,
               let firstClip = sortedClips.first,
               firstClip.timelineStart > 0
            {
                videoLayerConfiguration?.setOpacity(0, at: .zero)
            }

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

                if lane.kind.isVideo, let videoRenderSize {
                    let geometry = try await sourceVideoGeometry(sourceTrack)
                    let transform = videoTransform(
                        geometry: geometry,
                        renderSize: videoRenderSize,
                        layout: lane.kind == .camera
                            ? (clip.videoLayout ?? .defaultCamera)
                            : nil
                    )
                    videoLayerConfiguration?.setTransform(
                        transform,
                        at: timelineTime(clip.timelineStart)
                    )
                    if lane.kind == .video {
                        primaryVideoTransforms.append((
                            range: clip.timelineStart..<clip.timelineEnd,
                            transform: transform
                        ))
                    }
                    if lane.kind == .camera {
                        videoLayerConfiguration?.setOpacity(1, at: timelineTime(clip.timelineStart))
                        videoLayerConfiguration?.setOpacity(0, at: timelineTime(clip.timelineEnd))
                    }
                }

                if lane.kind == .video {
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
                primaryVideoTrack = compositionTrack
            }

            if let videoLayerConfiguration {
                let baseInstruction = AVVideoCompositionLayerInstruction(
                    configuration: videoLayerConfiguration
                )
                let instruction: AVVideoCompositionLayerInstruction
                if lane.kind == .video,
                   let renderSize = videoRenderSize,
                   let track = project.mouseFollowZoomTrack
                {
                    instruction = applyMouseFollowZoom(
                        track,
                        baseTransforms: primaryVideoTransformsCoveringGaps(
                            primaryVideoTransforms,
                            project: project
                        ),
                        renderSize: renderSize,
                        instruction: baseInstruction
                    )
                } else {
                    instruction = baseInstruction
                }
                videoLayers.append((
                    kind: lane.kind,
                    instruction: instruction
                ))
            } else {
                let parameters = AVMutableAudioMixInputParameters(track: compositionTrack)
                parameters.setVolume(lane.isMuted ? 0 : Float(lane.volume), at: .zero)
                audioParameters.append(parameters)
            }
        }

        let videoComposition = makeVideoComposition(
            primaryTrack: primaryVideoTrack,
            layers: videoLayers,
            renderSize: videoRenderSize,
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
            audioMix: audioMix,
            renderSize: videoRenderSize
        )
    }

    private static func primaryVideoRenderSize(
        for project: TimelineProject,
        sources: LoadedSources
    ) async throws -> CGSize? {
        guard let clip = project.lanes
            .first(where: { $0.kind == .video })?
            .clips
            .sorted(by: { $0.timelineStart < $1.timelineStart })
            .first
        else { return nil }
        let key = SourceTrackKey(url: clip.sourceURL, mediaType: .video, trackID: clip.sourceTrackID)
        guard let track = sources.tracks[key] else {
            throw TimelineCompositionBuildError.missingSourceTrack(clip.sourceURL, clip.sourceTrackID)
        }
        return try await sourceVideoGeometry(track).displaySize
    }

    private static func sourceVideoGeometry(_ track: AVAssetTrack) async throws -> SourceVideoGeometry {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return SourceVideoGeometry(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            transformedRect: transformedRect
        )
    }

    static func videoTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize,
        layout: TimelineVideoLayout?
    ) -> CGAffineTransform {
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return videoTransform(
            geometry: SourceVideoGeometry(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                transformedRect: transformedRect
            ),
            renderSize: renderSize,
            layout: layout
        )
    }

    static func mouseFollowZoomTransform(
        baseTransform: CGAffineTransform,
        renderSize: CGSize,
        focus: CGPoint,
        zoomScale: Double
    ) -> CGAffineTransform {
        let scale = CGFloat(min(max(zoomScale, 1), MouseFollowZoomScale.maximum))
        guard scale > 1,
              renderSize.width > 0,
              renderSize.height > 0
        else { return baseTransform }
        let focus = CGPoint(
            x: min(max(focus.x, 0), 1) * renderSize.width,
            y: min(max(focus.y, 0), 1) * renderSize.height
        )
        let viewportTransform = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: renderSize.width / 2 - focus.x * scale,
            ty: renderSize.height / 2 - focus.y * scale
        )
        return baseTransform.concatenating(viewportTransform)
    }

    private static func primaryVideoTransformsCoveringGaps(
        _ clipTransforms: [(range: Range<TimeInterval>, transform: CGAffineTransform)],
        project: TimelineProject
    ) -> [(range: Range<TimeInterval>, transform: CGAffineTransform)] {
        var result = clipTransforms
        for gap in project.videoGaps where gap.duration > 0.000_1 {
            let previous = clipTransforms
                .filter { $0.range.upperBound <= gap.timelineStart + 0.000_1 }
                .max { $0.range.upperBound < $1.range.upperBound }
            let next = clipTransforms
                .filter { $0.range.lowerBound >= gap.timelineEnd - 0.000_1 }
                .min { $0.range.lowerBound < $1.range.lowerBound }
            let transform = switch gap.fillMode {
            case .holdPrevious: previous?.transform ?? next?.transform ?? .identity
            case .holdNext: next?.transform ?? previous?.transform ?? .identity
            case .black: previous?.transform ?? next?.transform ?? .identity
            }
            result.append((
                range: gap.timelineStart..<gap.timelineEnd,
                transform: transform
            ))
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func applyMouseFollowZoom(
        _ track: MouseFollowZoomTrack,
        baseTransforms: [(range: Range<TimeInterval>, transform: CGAffineTransform)],
        renderSize: CGSize,
        instruction: AVVideoCompositionLayerInstruction
    ) -> AVVideoCompositionLayerInstruction {
        // Use AVFoundation's native ramps between bounded capture samples.
        // Emitting a transform command for every output frame makes long
        // projects expensive to build and gives AVFoundation far more state
        // than it needs to interpolate the same pointer path.
        var animated = AVVideoCompositionLayerInstruction.Configuration(
            trackID: instruction.trackID
        )

        for base in baseTransforms {
            var cursor = base.range.lowerBound
            let segments = track.segments.filter {
                $0.timelineEnd > base.range.lowerBound
                    && $0.timelineStart < base.range.upperBound
            }
            for (segmentIndex, segment) in segments.enumerated() {
                let start = max(base.range.lowerBound, segment.timelineStart)
                let end = min(base.range.upperBound, segment.timelineEnd)
                let duration = end - start
                guard duration > 0.000_1 else { continue }

                setTransformRamp(
                    from: base.transform,
                    to: base.transform,
                    range: cursor..<start,
                    configuration: &animated
                )

                let previous = segmentIndex > 0 ? segments[segmentIndex - 1] : nil
                let next = segments.indices.contains(segmentIndex + 1)
                    ? segments[segmentIndex + 1]
                    : nil
                let continuousPrevious = previous.map {
                    abs($0.timelineEnd - segment.timelineStart) < 0.000_1
                } ?? false
                let continuousNextScale = next.flatMap {
                    abs(segment.timelineEnd - $0.timelineStart) < 0.000_1
                        ? $0.zoomScale
                        : nil
                }
                let transition = min(0.2, segment.duration / 3)
                let zoomStart = segment.timelineStart + transition
                let zoomEnd = segment.timelineEnd - transition
                var sampleTimes = [start, end]
                if zoomStart > start, zoomStart < end { sampleTimes.append(zoomStart) }
                if zoomEnd > start, zoomEnd < end { sampleTimes.append(zoomEnd) }
                sampleTimes.append(contentsOf: segment.points.lazy
                    .map(\.timelineTime)
                    .filter { $0 > start && $0 < end })
                sampleTimes = Array(Set(sampleTimes)).sorted()

                for index in 0..<(sampleTimes.count - 1) {
                    let lower = sampleTimes[index]
                    let upper = sampleTimes[index + 1]
                    let timeRange = CMTimeRange(
                        start: timelineTime(lower),
                        duration: timelineTime(upper - lower)
                    )
                    animated.addTransformRamp(.init(
                        timeRange: timeRange,
                        start: mouseFollowZoomTransform(
                            baseTransform: base.transform,
                            renderSize: renderSize,
                            focus: segment.focus(at: lower),
                            zoomScale: zoomScale(
                                for: segment,
                                at: lower,
                                hasContinuousPrevious: continuousPrevious,
                                continuousNextScale: continuousNextScale
                            )
                        ),
                        end: mouseFollowZoomTransform(
                            baseTransform: base.transform,
                            renderSize: renderSize,
                            focus: segment.focus(at: upper),
                            zoomScale: zoomScale(
                                for: segment,
                                at: upper,
                                hasContinuousPrevious: continuousPrevious,
                                continuousNextScale: continuousNextScale
                            )
                        )
                    ))
                }
                cursor = end
            }
            setTransformRamp(
                from: base.transform,
                to: base.transform,
                range: cursor..<base.range.upperBound,
                configuration: &animated
            )
        }
        return AVVideoCompositionLayerInstruction(configuration: animated)
    }

    private static func setTransformRamp(
        from start: CGAffineTransform,
        to end: CGAffineTransform,
        range: Range<TimeInterval>,
        configuration: inout AVVideoCompositionLayerInstruction.Configuration
    ) {
        guard range.upperBound - range.lowerBound > 0.000_1 else { return }
        configuration.addTransformRamp(.init(
            timeRange: CMTimeRange(
                start: timelineTime(range.lowerBound),
                duration: timelineTime(range.upperBound - range.lowerBound)
            ),
            start: start,
            end: end
        ))
    }

    private static func zoomScale(
        for segment: MouseFollowZoomSegment,
        at time: TimeInterval,
        hasContinuousPrevious: Bool,
        continuousNextScale: Double?
    ) -> Double {
        let transition = min(0.2, segment.duration / 3)
        if !hasContinuousPrevious, time < segment.timelineStart + transition {
            let amount = (time - segment.timelineStart) / max(transition, 0.000_1)
            return 1 + (segment.zoomScale - 1) * min(max(amount, 0), 1)
        }
        if time > segment.timelineEnd - transition {
            let target = continuousNextScale ?? 1
            let amount = (segment.timelineEnd - time) / max(transition, 0.000_1)
            return target + (segment.zoomScale - target) * min(max(amount, 0), 1)
        }
        return segment.zoomScale
    }

    private static func videoTransform(
        geometry: SourceVideoGeometry,
        renderSize: CGSize,
        layout: TimelineVideoLayout?
    ) -> CGAffineTransform {
        guard geometry.displaySize.width > 0,
              geometry.displaySize.height > 0,
              renderSize.width > 0,
              renderSize.height > 0
        else { return .identity }

        let normalizedSource = geometry.preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -geometry.transformedRect.minX,
                y: -geometry.transformedRect.minY
            )
        )
        let box: CGRect
        if let layout {
            let layout = layout.clamped()
            box = CGRect(
                x: CGFloat(layout.x) * renderSize.width,
                y: CGFloat(layout.y) * renderSize.height,
                width: CGFloat(layout.width) * renderSize.width,
                height: CGFloat(layout.height) * renderSize.height
            )
        } else {
            box = CGRect(origin: .zero, size: renderSize)
        }
        let scale = min(
            box.width / geometry.displaySize.width,
            box.height / geometry.displaySize.height
        )
        let outputSize = CGSize(
            width: geometry.displaySize.width * scale,
            height: geometry.displaySize.height * scale
        )
        let origin = CGPoint(
            x: box.midX - outputSize.width / 2,
            y: box.midY - outputSize.height / 2
        )
        return normalizedSource
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
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
        primaryTrack: AVMutableCompositionTrack?,
        layers: [(kind: TimelineLaneKind, instruction: AVVideoCompositionLayerInstruction)],
        renderSize: CGSize?,
        duration: TimeInterval,
        frameDuration: TimeInterval
    ) -> AVVideoComposition? {
        guard
            primaryTrack != nil,
            let renderSize,
            renderSize.width > 0,
            renderSize.height > 0,
            duration > 0
        else { return nil }

        var instructionConfiguration = AVVideoCompositionInstruction.Configuration()
        instructionConfiguration.timeRange = CMTimeRange(
            start: .zero,
            duration: timelineTime(duration)
        )
        instructionConfiguration.backgroundColor = CGColor.black
        // AVFoundation defines layerInstructions in top-to-bottom order. Keep
        // each secondary camera track above the primary screen track.
        instructionConfiguration.layerInstructions = layers
            .sorted { lhs, rhs in
                let lhsPriority = lhs.kind == .camera ? 0 : 1
                let rhsPriority = rhs.kind == .camera ? 0 : 1
                return lhsPriority < rhsPriority
            }
            .map(\.instruction)
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

private struct SourceVideoGeometry {
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let transformedRect: CGRect

    var displaySize: CGSize {
        CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
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

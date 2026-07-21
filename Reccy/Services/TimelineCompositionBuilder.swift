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
        case .importedVideo: "Imported Video"
        case .systemAudio: "System Audio"
        case .microphone: "Microphone"
        case .voiceover: "Voiceover"
        case .importedAudio: "Imported Audio"
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
        var videoLayers: [(
            kind: TimelineLaneKind,
            laneOrder: Int,
            layerOrder: Int,
            instruction: AVVideoCompositionLayerInstruction
        )] = []
        let videoRenderSize = try await primaryVideoRenderSize(for: project, sources: sources)

        for (laneOrder, lane) in project.lanes.enumerated() where !lane.clips.isEmpty {
            let sortedClips = lane.clips.sorted(by: { $0.timelineStart < $1.timelineStart })
            // AVFoundation can stall when one composition track changes crop or
            // transform discontinuously at an adjacent edit. Alternating between
            // two tracks gives each cut a clean layer boundary while keeping the
            // track count bounded for arbitrarily long projects.
            let compositionTrackCount = lane.kind.isVideo ? min(sortedClips.count, 2) : 1
            let compositionTracks = try (0..<compositionTrackCount).map { _ in
                guard let track = composition.addMutableTrack(
                    withMediaType: lane.kind.mediaType,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw TimelineCompositionBuildError.couldNotCreateTrack(lane.kind)
                }
                return track
            }
            var videoLayerConfigurations = lane.kind.isVideo
                ? compositionTracks.map {
                    AVVideoCompositionLayerInstruction.Configuration(trackID: $0.trackID)
                }
                : []
            if lane.kind.isOverlayVideo {
                for index in videoLayerConfigurations.indices {
                    videoLayerConfigurations[index].setOpacity(0, at: .zero)
                }
            }

            var primaryVideoTransforms = Array(
                repeating: [(range: Range<TimeInterval>, transform: CGAffineTransform)](),
                count: compositionTrackCount
            )
            var previousVideoSource: (
                clip: TimelineClip,
                track: AVAssetTrack,
                compositionTrack: AVMutableCompositionTrack,
                trackIndex: Int,
                state: VideoRenderState?
            )?
            var videoCursor: TimeInterval = 0

            for (clipIndex, clip) in sortedClips.enumerated() {
                let trackIndex = lane.kind.isVideo ? clipIndex % compositionTrackCount : 0
                let compositionTrack = compositionTracks[trackIndex]
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

                let renderState: VideoRenderState?
                if lane.kind.isVideo, let videoRenderSize {
                    let geometry = try await sourceVideoGeometry(sourceTrack)
                    renderState = VideoRenderState(
                        transform: videoTransform(
                            geometry: geometry,
                            renderSize: videoRenderSize,
                            layout: lane.kind.isOverlayVideo
                                ? (clip.videoLayout ?? .defaultCamera)
                                : nil,
                            adjustment: clip.effectiveVideoAdjustment
                        ),
                        cropRectangle: sourceCropRectangle(
                            geometry: geometry,
                            adjustment: clip.effectiveVideoAdjustment
                        )
                    )
                } else {
                    renderState = nil
                }

                if lane.kind == .video, clip.timelineStart > videoCursor + 0.000_1 {
                    let gap = videoCursor..<clip.timelineStart
                    let fillMode = gapFillMode(for: gap, in: project)
                    let targetTrackIndex: Int
                    let targetTrack: AVMutableCompositionTrack
                    let gapState: VideoRenderState?
                    switch fillMode {
                    case .holdPrevious:
                        targetTrackIndex = previousVideoSource?.trackIndex ?? trackIndex
                        targetTrack = previousVideoSource?.compositionTrack ?? compositionTrack
                        gapState = previousVideoSource?.state ?? renderState
                    case .holdNext:
                        targetTrackIndex = trackIndex
                        targetTrack = compositionTrack
                        gapState = renderState ?? previousVideoSource?.state
                    case .black:
                        targetTrackIndex = trackIndex
                        targetTrack = compositionTrack
                        gapState = nil
                    }
                    do {
                        try fillVideoGap(
                            gap,
                            mode: fillMode,
                            frameDuration: project.frameDuration,
                            compositionTrack: targetTrack,
                            previous: previousVideoSource.map { ($0.clip, $0.track) },
                            next: (clip, sourceTrack)
                        )
                        if let gapState {
                            configureVideoGeometry(
                                gapState,
                                range: gap,
                                animateTransform: project.mouseFollowZoomTrack != nil,
                                configuration: &videoLayerConfigurations[targetTrackIndex],
                                transformRanges: &primaryVideoTransforms[targetTrackIndex]
                            )
                        }
                    } catch {
                        throw TimelineCompositionBuildError.couldNotFillGap(
                            fillMode,
                            error
                        )
                    }
                }

                do {
                    if clip.stillImageOriginalURL != nil {
                        try insertStillImage(
                            clip,
                            sourceTrack: sourceTrack,
                            frameDuration: project.frameDuration,
                            compositionTrack: compositionTrack
                        )
                    } else if clip.effectiveEffects.direction == .reverse,
                              lane.kind.isVideo
                    {
                        try insertReversedVideo(
                            clip,
                            sourceTrack: sourceTrack,
                            frameDuration: project.frameDuration,
                            compositionTrack: compositionTrack
                        )
                    } else if clip.effectiveEffects.direction == .reverse {
                        let reverseURL = try await TimelineReverseAudioRenderer.shared.reversedTrack(
                            sourceURL: clip.sourceURL,
                            sourceTrackID: clip.sourceTrackID,
                            sourceStart: clip.sourceStart,
                            sourceDuration: clip.sourceSpanDuration
                        )
                        let reverseAsset = AVURLAsset(url: reverseURL)
                        guard let reverseTrack = try await reverseAsset.loadTracks(withMediaType: .audio).first else {
                            throw TimelineReverseAudioError.missingTrack(clip.sourceTrackID)
                        }
                        try insertRetimedClip(
                            clip,
                            sourceTrack: reverseTrack,
                            sourceStart: 0,
                            compositionTrack: compositionTrack
                        )
                    } else {
                        try insertRetimedClip(
                            clip,
                            sourceTrack: sourceTrack,
                            sourceStart: clip.sourceStart,
                            compositionTrack: compositionTrack
                        )
                    }
                } catch {
                    throw TimelineCompositionBuildError.couldNotInsertClip(clip.name, error)
                }

                if let renderState {
                    configureVideoGeometry(
                        renderState,
                        range: clip.timelineStart..<clip.timelineEnd,
                        animateTransform: lane.kind == .video && project.mouseFollowZoomTrack != nil,
                        configuration: &videoLayerConfigurations[trackIndex],
                        transformRanges: &primaryVideoTransforms[trackIndex]
                    )
                    configureVideoOpacity(
                        for: clip,
                        isOverlay: lane.kind.isOverlayVideo,
                        configuration: &videoLayerConfigurations[trackIndex]
                    )
                }

                if lane.kind == .video {
                    previousVideoSource = (
                        clip,
                        sourceTrack,
                        compositionTrack,
                        trackIndex,
                        renderState
                    )
                    videoCursor = clip.timelineEnd
                }
            }

            if lane.kind == .video {
                if project.duration > videoCursor + 0.000_1 {
                    let gap = videoCursor..<project.duration
                    let fillMode = gapFillMode(for: gap, in: project)
                    let targetTrackIndex = previousVideoSource?.trackIndex ?? 0
                    let targetTrack = previousVideoSource?.compositionTrack ?? compositionTracks[0]
                    do {
                        try fillVideoGap(
                            gap,
                            mode: fillMode,
                            frameDuration: project.frameDuration,
                            compositionTrack: targetTrack,
                            previous: previousVideoSource.map { ($0.clip, $0.track) },
                            next: nil
                        )
                        if fillMode == .holdPrevious,
                           let state = previousVideoSource?.state
                        {
                            configureVideoGeometry(
                                state,
                                range: gap,
                                animateTransform: project.mouseFollowZoomTrack != nil,
                                configuration: &videoLayerConfigurations[targetTrackIndex],
                                transformRanges: &primaryVideoTransforms[targetTrackIndex]
                            )
                        }
                    } catch {
                        throw TimelineCompositionBuildError.couldNotFillGap(
                            fillMode,
                            error
                        )
                    }
                }
                primaryVideoTrack = compositionTracks.first
            }

            if lane.kind.isVideo {
                for index in videoLayerConfigurations.indices {
                    var configuration = videoLayerConfigurations[index]
                    if lane.kind == .video,
                       let renderSize = videoRenderSize,
                       let track = project.mouseFollowZoomTrack
                    {
                        applyMouseFollowZoom(
                            track,
                            baseTransforms: primaryVideoTransforms[index],
                            renderSize: renderSize,
                            configuration: &configuration
                        )
                    }
                    videoLayers.append((
                        kind: lane.kind,
                        laneOrder: laneOrder,
                        layerOrder: index,
                        instruction: AVVideoCompositionLayerInstruction(configuration: configuration)
                    ))
                }
            } else {
                let parameters = AVMutableAudioMixInputParameters(track: compositionTracks[0])
                let volume = lane.isMuted ? Float(0) : Float(lane.volume)
                parameters.setVolume(volume, at: .zero)
                for clip in sortedClips {
                    configureAudioVolume(
                        for: clip,
                        volume: volume,
                        parameters: parameters
                    )
                }
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
        layout: TimelineVideoLayout?,
        adjustment: TimelineVideoAdjustment? = nil
    ) -> CGAffineTransform {
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return videoTransform(
            geometry: SourceVideoGeometry(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                transformedRect: transformedRect
            ),
            renderSize: renderSize,
            layout: layout,
            adjustment: (adjustment ?? TimelineVideoAdjustment()).clamped()
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

    private static func applyMouseFollowZoom(
        _ track: MouseFollowZoomTrack,
        baseTransforms: [(range: Range<TimeInterval>, transform: CGAffineTransform)],
        renderSize: CGSize,
        configuration: inout AVVideoCompositionLayerInstruction.Configuration
    ) {
        // Use AVFoundation's native ramps between bounded capture samples.
        // Emitting a transform command for every output frame makes long
        // projects expensive to build and gives AVFoundation far more state
        // than it needs to interpolate the same pointer path.
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
                    configuration: &configuration
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
                    configuration.addTransformRamp(.init(
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
                configuration: &configuration
            )
        }
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
        layout: TimelineVideoLayout?,
        adjustment: TimelineVideoAdjustment
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
        let visibleDisplayRect = displayCropRectangle(
            geometry: geometry,
            adjustment: adjustment
        )
        let scale = min(
            box.width / visibleDisplayRect.width,
            box.height / visibleDisplayRect.height
        ) * CGFloat(adjustment.scale)
        let outputSize = CGSize(
            width: visibleDisplayRect.width * scale,
            height: visibleDisplayRect.height * scale
        )
        let origin = CGPoint(
            x: box.midX - outputSize.width / 2,
            y: box.midY - outputSize.height / 2
        )
        return normalizedSource
            .concatenating(CGAffineTransform(
                translationX: -visibleDisplayRect.minX,
                y: -visibleDisplayRect.minY
            ))
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

    private static func insertRetimedClip(
        _ clip: TimelineClip,
        sourceTrack: AVAssetTrack,
        sourceStart: TimeInterval,
        compositionTrack: AVMutableCompositionTrack
    ) throws {
        let sourceRange = CMTimeRange(
            start: timelineTime(sourceStart),
            duration: timelineTime(clip.sourceSpanDuration)
        )
        let targetStart = timelineTime(clip.timelineStart)
        try compositionTrack.insertTimeRange(sourceRange, of: sourceTrack, at: targetStart)
        let insertedRange = CMTimeRange(start: targetStart, duration: sourceRange.duration)
        let targetDuration = timelineTime(clip.duration)
        if abs(sourceRange.duration.seconds - targetDuration.seconds) > 0.000_1 {
            compositionTrack.scaleTimeRange(insertedRange, toDuration: targetDuration)
        }
    }

    /// AVMutableComposition has no negative-rate segment. Reverse picture is
    /// therefore assembled from bounded output-frame samples in descending
    /// source order. No proxy movie is written, and color/orientation metadata
    /// continues to come from the original AVAssetTrack.
    private static func insertReversedVideo(
        _ clip: TimelineClip,
        sourceTrack: AVAssetTrack,
        frameDuration: TimeInterval,
        compositionTrack: AVMutableCompositionTrack
    ) throws {
        let outputFrameDuration = max(frameDuration, 1 / 600)
        let sourceFrameDuration = min(outputFrameDuration, clip.sourceSpanDuration)
        var outputOffset: TimeInterval = 0
        while outputOffset < clip.duration - 0.000_001 {
            if Task.isCancelled { throw CancellationError() }
            let targetFrameDuration = min(outputFrameDuration, clip.duration - outputOffset)
            let sourceProgress = min(
                outputOffset * clip.effectiveEffects.playbackRate,
                max(0, clip.sourceSpanDuration - sourceFrameDuration)
            )
            let sourceTime = max(
                clip.sourceStart,
                clip.sourceEnd - sourceProgress - sourceFrameDuration
            )
            let targetStart = clip.timelineStart + outputOffset
            let sourceRange = CMTimeRange(
                start: timelineTime(sourceTime),
                duration: timelineTime(sourceFrameDuration)
            )
            try compositionTrack.insertTimeRange(
                sourceRange,
                of: sourceTrack,
                at: timelineTime(targetStart)
            )
            compositionTrack.scaleTimeRange(
                CMTimeRange(start: timelineTime(targetStart), duration: sourceRange.duration),
                toDuration: timelineTime(targetFrameDuration)
            )
            outputOffset += targetFrameDuration
        }
    }

    private static func configureVideoOpacity(
        for clip: TimelineClip,
        isOverlay: Bool,
        configuration: inout AVVideoCompositionLayerInstruction.Configuration
    ) {
        let effects = clip.effectiveEffects
        let start = clip.timelineStart
        let end = clip.timelineEnd
        if isOverlay || effects.fadeInDuration > 0 {
            configuration.setOpacity(0, at: timelineTime(start))
        } else {
            configuration.setOpacity(1, at: timelineTime(start))
        }
        if effects.fadeInDuration > 0 {
            configuration.addOpacityRamp(.init(
                timeRange: timelineRange(start..<(start + effects.fadeInDuration)),
                start: 0,
                end: 1
            ))
        } else if isOverlay {
            configuration.setOpacity(1, at: timelineTime(start))
        }
        if effects.fadeOutDuration > 0 {
            configuration.addOpacityRamp(.init(
                timeRange: timelineRange((end - effects.fadeOutDuration)..<end),
                start: 1,
                end: 0
            ))
        }
        if isOverlay || effects.fadeOutDuration > 0 {
            configuration.setOpacity(0, at: timelineTime(end))
        }
    }

    private static func configureVideoGeometry(
        _ state: VideoRenderState,
        range: Range<TimeInterval>,
        animateTransform: Bool,
        configuration: inout AVVideoCompositionLayerInstruction.Configuration,
        transformRanges: inout [(range: Range<TimeInterval>, transform: CGAffineTransform)]
    ) {
        guard range.upperBound - range.lowerBound > 0.000_1 else { return }
        configuration.setCropRectangle(
            state.cropRectangle,
            at: timelineTime(range.lowerBound)
        )
        if animateTransform {
            transformRanges.append((range: range, transform: state.transform))
        } else {
            configuration.setTransform(
                state.transform,
                at: timelineTime(range.lowerBound)
            )
        }
    }

    private static func configureAudioVolume(
        for clip: TimelineClip,
        volume: Float,
        parameters: AVMutableAudioMixInputParameters
    ) {
        let effects = clip.effectiveEffects
        let start = clip.timelineStart
        let end = clip.timelineEnd
        parameters.setVolume(effects.fadeInDuration > 0 ? 0 : volume, at: timelineTime(start))
        if effects.fadeInDuration > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: volume,
                timeRange: timelineRange(start..<(start + effects.fadeInDuration))
            )
        }
        if effects.fadeOutDuration > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: volume,
                toEndVolume: 0,
                timeRange: timelineRange((end - effects.fadeOutDuration)..<end)
            )
        }
    }

    private static func displayCropRectangle(
        geometry: SourceVideoGeometry,
        adjustment: TimelineVideoAdjustment
    ) -> CGRect {
        let adjustment = adjustment.clamped()
        return CGRect(
            x: CGFloat(adjustment.cropLeading) * geometry.displaySize.width,
            y: CGFloat(adjustment.cropTop) * geometry.displaySize.height,
            width: CGFloat(1 - adjustment.cropLeading - adjustment.cropTrailing)
                * geometry.displaySize.width,
            height: CGFloat(1 - adjustment.cropTop - adjustment.cropBottom)
                * geometry.displaySize.height
        )
    }

    private static func sourceCropRectangle(
        geometry: SourceVideoGeometry,
        adjustment: TimelineVideoAdjustment
    ) -> CGRect {
        let displayRect = displayCropRectangle(geometry: geometry, adjustment: adjustment)
            .offsetBy(dx: geometry.transformedRect.minX, dy: geometry.transformedRect.minY)
        return displayRect.applying(geometry.preferredTransform.inverted()).standardized
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
                sourceTime: heldFrameSourceTime(
                    for: previous.clip,
                    timelineOffset: max(0, previous.clip.duration - frameDuration),
                    frameDuration: frameDuration
                ),
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
                sourceTime: heldFrameSourceTime(
                    for: next.clip,
                    timelineOffset: 0,
                    frameDuration: frameDuration
                ),
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

    private static func heldFrameSourceTime(
        for clip: TimelineClip,
        timelineOffset: TimeInterval,
        frameDuration: TimeInterval
    ) -> TimeInterval {
        let sourceFrameDuration = min(frameDuration, clip.sourceSpanDuration)
        let requested = clip.sourceTime(atTimelineOffset: timelineOffset)
        return min(
            max(requested, clip.sourceStart),
            max(clip.sourceStart, clip.sourceEnd - sourceFrameDuration)
        )
    }

    /// Image imports use a one-frame project proxy and stretch that frame only
    /// inside the composition. The source image remains untouched in Media/,
    /// and timeline duration does not increase proxy size or decode work.
    private static func insertStillImage(
        _ clip: TimelineClip,
        sourceTrack: AVAssetTrack,
        frameDuration: TimeInterval,
        compositionTrack: AVMutableCompositionTrack
    ) throws {
        let insertedDuration = min(max(frameDuration, 1 / 600), clip.duration)
        let insertedRange = CMTimeRange(
            start: timelineTime(clip.timelineStart),
            duration: timelineTime(insertedDuration)
        )
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: insertedRange.duration),
            of: sourceTrack,
            at: insertedRange.start
        )
        compositionTrack.scaleTimeRange(
            insertedRange,
            toDuration: timelineTime(clip.duration)
        )
    }

    private static func makeVideoComposition(
        primaryTrack: AVMutableCompositionTrack?,
        layers: [(
            kind: TimelineLaneKind,
            laneOrder: Int,
            layerOrder: Int,
            instruction: AVVideoCompositionLayerInstruction
        )],
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
        // imported overlays above the camera and primary screen tracks.
        instructionConfiguration.layerInstructions = layers
            .sorted { lhs, rhs in
                let lhsPriority = switch lhs.kind {
                case .importedVideo: 0
                case .camera: 1
                default: 2
                }
                let rhsPriority = switch rhs.kind {
                case .importedVideo: 0
                case .camera: 1
                default: 2
                }
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                if lhs.laneOrder != rhs.laneOrder {
                    return lhs.laneOrder > rhs.laneOrder
                }
                return lhs.layerOrder > rhs.layerOrder
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

    private static func timelineRange(_ range: Range<TimeInterval>) -> CMTimeRange {
        CMTimeRange(
            start: timelineTime(range.lowerBound),
            duration: timelineTime(range.upperBound - range.lowerBound)
        )
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

private struct VideoRenderState {
    let transform: CGAffineTransform
    let cropRectangle: CGRect
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

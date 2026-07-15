import AppKit
@preconcurrency import AVFoundation
import QuartzCore

/// Produces readable project captions from source-aligned transcript segments.
/// The result is deliberately independent from the transcript sidecar: editors
/// can correct source text and then regenerate, or make project-only caption
/// edits without rewriting recognized timing metadata.
nonisolated enum TimelineCaptionCueGenerator {
    static let maximumCharacters = 84
    static let maximumDuration: TimeInterval = 6
    static let maximumJoinGap: TimeInterval = 0.65
    static let minimumReadableDuration: TimeInterval = 0.9

    static func cues(
        from segments: [ProjectedTranscriptSegment],
        projectDuration: TimeInterval
    ) -> [TimelineCaptionCue] {
        let candidates = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if abs($0.timelineStart - $1.timelineStart) > 0.001 {
                    return $0.timelineStart < $1.timelineStart
                }
                return $0.role.sortOrderForCaptions < $1.role.sortOrderForCaptions
            }
        guard !candidates.isEmpty, projectDuration > 0 else { return [] }

        var groups: [[ProjectedTranscriptSegment]] = []
        for role in TranscriptTrackRole.allCases {
            for segment in candidates.filter({ $0.role == role }) {
                guard var current = groups.last, current.first?.role == role else {
                    groups.append([segment])
                    continue
                }
                if canJoin(segment, to: current) {
                    current.append(segment)
                    groups[groups.count - 1] = current
                } else {
                    groups.append([segment])
                }
            }
        }

        var candidatesWithRoles = groups.compactMap { group -> CaptionCandidate? in
            guard let first = group.first else { return nil }
            let start = max(0, first.timelineStart)
            let naturalEnd = min(projectDuration, group.map(\.timelineEnd).max() ?? start)
            guard naturalEnd > start else { return nil }
            let text = group
                .map(\.text)
                .joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return CaptionCandidate(
                role: first.role,
                cue: TimelineCaptionCue(
                    text: text,
                    timelineStart: start,
                    duration: naturalEnd - start,
                    origin: .transcript
                )
            )
        }
        candidatesWithRoles.sort {
            if abs($0.cue.timelineStart - $1.cue.timelineStart) > 0.001 {
                return $0.cue.timelineStart < $1.cue.timelineStart
            }
            return $0.role.sortOrderForCaptions < $1.role.sortOrderForCaptions
        }
        candidatesWithRoles = removingCrossTrackEchoes(from: candidatesWithRoles)
        candidatesWithRoles = combiningConcurrentSpeech(in: candidatesWithRoles)
        var cues = candidatesWithRoles.map(\.cue)

        for index in cues.indices {
            let nextStart = cues.indices.contains(index + 1)
                ? cues[index + 1].timelineStart
                : projectDuration
            let maximumEnd = max(cues[index].timelineStart + 0.1, nextStart)
            let readableEnd = min(maximumEnd, cues[index].timelineStart + minimumReadableDuration)
            let naturalEnd = min(cues[index].timelineEnd, maximumEnd)
            cues[index].duration = max(0.1, max(naturalEnd, readableEnd) - cues[index].timelineStart)
        }
        return cues
    }

    /// Separate microphone and system tracks can contain the same audible
    /// speech (for example, speakers bleeding into the microphone). Remove
    /// only strongly matching, time-overlapping candidates; distinct speakers
    /// remain separate and are serialized so captions never draw on top of one
    /// another in preview or export.
    private static func removingCrossTrackEchoes(
        from candidates: [CaptionCandidate]
    ) -> [CaptionCandidate] {
        var result: [CaptionCandidate] = []
        for candidate in candidates {
            guard let previous = result.last,
                  previous.role != candidate.role,
                  overlap(previous.cue, candidate.cue) > 0.2,
                  tokenSimilarity(previous.cue.text, candidate.cue.text) >= 0.55
            else {
                result.append(candidate)
                continue
            }

            let previousWords = normalizedTokens(previous.cue.text).count
            let candidateWords = normalizedTokens(candidate.cue.text).count
            if candidateWords > previousWords {
                result[result.count - 1] = candidate
            }
        }
        return result
    }

    private static func combiningConcurrentSpeech(
        in candidates: [CaptionCandidate]
    ) -> [CaptionCandidate] {
        var result: [CaptionCandidate] = []
        for candidate in candidates {
            guard let previous = result.last,
                  previous.role != candidate.role,
                  candidate.cue.timelineStart - previous.cue.timelineStart < 0.3,
                  overlap(previous.cue, candidate.cue) > 0.2
            else {
                result.append(candidate)
                continue
            }

            let start = min(previous.cue.timelineStart, candidate.cue.timelineStart)
            let end = max(previous.cue.timelineEnd, candidate.cue.timelineEnd)
            result[result.count - 1] = CaptionCandidate(
                role: previous.role,
                cue: TimelineCaptionCue(
                    text: "– \(previous.cue.text)\n– \(candidate.cue.text)",
                    timelineStart: start,
                    duration: end - start,
                    origin: .transcript
                )
            )
        }
        return result
    }

    private static func overlap(_ lhs: TimelineCaptionCue, _ rhs: TimelineCaptionCue) -> TimeInterval {
        max(0, min(lhs.timelineEnd, rhs.timelineEnd) - max(lhs.timelineStart, rhs.timelineStart))
    }

    private static func tokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(normalizedTokens(lhs))
        let rhsTokens = Set(normalizedTokens(rhs))
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        return Double(lhsTokens.intersection(rhsTokens).count)
            / Double(lhsTokens.union(rhsTokens).count)
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func canJoin(
        _ candidate: ProjectedTranscriptSegment,
        to group: [ProjectedTranscriptSegment]
    ) -> Bool {
        guard let first = group.first, let last = group.last else { return true }
        let gap = candidate.timelineStart - last.timelineEnd
        let duration = max(last.timelineEnd, candidate.timelineEnd) - first.timelineStart
        let combinedCount = group.reduce(0) { $0 + $1.text.count + 1 } + candidate.text.count
        let closesSentence = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .last.map { ".?!".contains($0) } ?? false
        return candidate.role == last.role
            && gap <= maximumJoinGap
            && gap >= -0.05
            && duration <= maximumDuration
            && combinedCount <= maximumCharacters
            && !closesSentence
    }
}

nonisolated private struct CaptionCandidate {
    let role: TranscriptTrackRole
    let cue: TimelineCaptionCue
}

/// Builds the offline-only caption pass used by AVAssetExportSession. Playback
/// uses a native editor overlay because Apple explicitly limits the Core
/// Animation composition tool to offline rendering.
@MainActor
enum TimelineCaptionVideoRenderer {
    static func applying(
        _ track: TimelineCaptionTrack?,
        to base: AVVideoComposition?,
        projectDuration: TimeInterval
    ) -> AVVideoComposition? {
        guard let base,
              let track,
              track.isVisible,
              !track.cues.isEmpty,
              base.renderSize.width > 0,
              base.renderSize.height > 0
        else { return base }

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: base.renderSize)
        parentLayer.masksToBounds = true

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        for cue in track.cues where cue.timelineStart < projectDuration && cue.timelineEnd > 0 {
            guard let layer = captionLayer(
                cue: cue,
                style: track.style,
                renderSize: base.renderSize,
                projectDuration: projectDuration
            ) else { continue }
            parentLayer.addSublayer(layer)
        }

        let toolConfiguration = AVVideoCompositionCoreAnimationTool.Configuration(
            postProcessingAsVideoLayer: videoLayer,
            containingLayer: parentLayer
        )
        var configuration = AVVideoComposition.Configuration()
        configuration.renderSize = base.renderSize
        configuration.renderScale = base.renderScale
        configuration.frameDuration = base.frameDuration
        configuration.instructions = base.instructions
        configuration.colorPrimaries = base.colorPrimaries
        configuration.colorTransferFunction = base.colorTransferFunction
        configuration.colorYCbCrMatrix = base.colorYCbCrMatrix
        configuration.animationTool = AVVideoCompositionCoreAnimationTool(
            configuration: toolConfiguration
        )
        return AVVideoComposition(configuration: configuration)
    }

    static func fontSize(style: TimelineCaptionStyle, renderSize: CGSize) -> CGFloat {
        max(20, min(renderSize.width, renderSize.height) * style.size.renderScale)
    }

    private static func captionLayer(
        cue: TimelineCaptionCue,
        style: TimelineCaptionStyle,
        renderSize: CGSize,
        projectDuration: TimeInterval
    ) -> CALayer? {
        let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = max(0, cue.timelineStart)
        let end = min(projectDuration, cue.timelineEnd)
        guard !text.isEmpty, end - start > 0.001 else { return nil }

        let fontSize = fontSize(style: style, renderSize: renderSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ]
        )
        let maximumTextWidth = renderSize.width * 0.82
        let measured = attributed.boundingRect(
            with: CGSize(width: maximumTextWidth, height: fontSize * 3.2),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral
        let horizontalPadding = fontSize * 0.55
        let verticalPadding = fontSize * 0.30
        let layerSize = CGSize(
            width: min(renderSize.width * 0.9, measured.width + horizontalPadding * 2),
            height: measured.height + verticalPadding * 2
        )
        let safeMargin = renderSize.height * 0.075
        let originY: CGFloat
        switch style.placement {
        case .bottom:
            originY = safeMargin
        case .top:
            originY = renderSize.height - safeMargin - layerSize.height
        }

        let background = CALayer()
        background.frame = CGRect(
            x: (renderSize.width - layerSize.width) / 2,
            y: originY,
            width: layerSize.width,
            height: layerSize.height
        ).integral
        background.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        background.cornerRadius = fontSize * 0.34
        background.masksToBounds = true
        background.opacity = 0

        let textLayer = CATextLayer()
        textLayer.frame = background.bounds.insetBy(dx: horizontalPadding, dy: verticalPadding)
        textLayer.string = attributed
        textLayer.alignmentMode = .center
        textLayer.isWrapped = true
        textLayer.truncationMode = .none
        textLayer.contentsScale = 2
        background.addSublayer(textLayer)

        // Keep the model layer hidden and make the animation active only for
        // the cue's time range. A forwards fill would leave the final caption
        // visible in offline exports after its cue ended.
        let visibility = CABasicAnimation(keyPath: "opacity")
        visibility.fromValue = 1
        visibility.toValue = 1
        visibility.beginTime = AVCoreAnimationBeginTimeAtZero + start
        visibility.duration = end - start
        visibility.fillMode = .removed
        visibility.isRemovedOnCompletion = false
        background.add(visibility, forKey: "captionVisibility")
        return background
    }
}

nonisolated private extension TranscriptTrackRole {
    var sortOrderForCaptions: Int {
        switch self {
        case .systemAudio: 0
        case .microphone: 1
        case .voiceover: 2
        case .unknown: 3
        }
    }
}

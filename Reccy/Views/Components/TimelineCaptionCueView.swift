import AppKit
import SwiftUI

/// A caption boundary on the editor timeline. Its width reflects the shared
/// hold-until-next presentation range; dragging retimes the start boundary.
struct TimelineCaptionCueView: View {
    let cue: TimelineCaptionCue
    let pixelsPerSecond: Double
    let frameRate: Double
    let isSelected: Bool
    let isVisible: Bool
    let onSelect: () -> Void
    let onMove: (TimeInterval) -> Void
    let onNudge: (Int) -> Void
    let onDelete: () -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        interactiveSurface
            .reccyTooltip("Click to edit • Drag to retime the caption start • Arrow keys nudge one frame")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Caption, " + cue.text))
            .accessibilityValue(Text(accessibilityValue))
            .accessibilityHint("Activate to edit. Drag to retime, or use the additional frame-nudge actions.")
            .accessibilityAddTraits(accessibilityTraits)
            .accessibilityAction { onSelect() }
            .accessibilityAction(named: "Move Earlier by One Frame") { onNudge(-1) }
            .accessibilityAction(named: "Move Later by One Frame") { onNudge(1) }
            .accessibilityAction(named: "Delete Caption") { onDelete() }
    }

    private var visualSurface: some View {
        HStack(spacing: 7) {
            Image(systemName: "captions.bubble.fill")
            Text(cue.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.indigo.gradient.opacity(isVisible ? 1 : 0.48))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isSelected ? Color.white : Color.white.opacity(0.14),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: isSelected ? Color.indigo.opacity(0.5) : .clear, radius: 5)
    }

    private var interactiveSurface: some View {
        visualSurface
            .contentShape(Rectangle())
            .offset(x: dragOffset)
            .simultaneousGesture(TapGesture().onEnded(onSelect))
            .highPriorityGesture(moveGesture)
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .focusable()
            .onKeyPress(.leftArrow) {
                onNudge(-1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                onNudge(1)
                return .handled
            }
            .onKeyPress(.delete) {
                onDelete()
                return .handled
            }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let target = cue.timelineStart + value.translation.width / pixelsPerSecond
                dragOffset = 0
                onMove(target)
            }
    }

    private var accessibilityTraits: AccessibilityTraits {
        isSelected ? [.isButton, .isSelected] : .isButton
    }

    private var accessibilityValue: String {
        let selection = isSelected ? "Selected" : "Not selected"
        let visibility = isVisible ? "visible" : "hidden"
        return "\(selection), \(visibility), starts at \(accessibilityTimecode)"
    }

    private var accessibilityTimecode: String {
        let safeTime = max(0, cue.timelineStart)
        let seconds = Int(safeTime.rounded(.down))
        let safeFrameRate = max(frameRate, 1)
        let frames = min(
            Int((safeTime - floor(safeTime)) * safeFrameRate),
            Int(safeFrameRate) - 1
        )
        return String(
            format: "%02d:%02d:%02d:%02d",
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60,
            frames
        )
    }
}

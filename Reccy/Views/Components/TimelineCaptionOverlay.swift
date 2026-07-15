import SwiftUI

func timelineAspectFitRect(content: CGSize, in container: CGSize) -> CGRect {
    guard content.width > 0,
          content.height > 0,
          container.width > 0,
          container.height > 0
    else { return CGRect(origin: .zero, size: container) }

    let scale = min(container.width / content.width, container.height / content.height)
    let size = CGSize(width: content.width * scale, height: content.height * scale)
    return CGRect(
        x: (container.width - size.width) / 2,
        y: (container.height - size.height) / 2,
        width: size.width,
        height: size.height
    )
}

struct TimelineCaptionOverlay: View {
    let track: TimelineCaptionTrack
    let time: TimeInterval
    let renderSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            let videoRect = timelineAspectFitRect(content: renderSize, in: geometry.size)
            if let cue = track.activeCue(at: time) {
                VStack {
                    if track.style.placement == .bottom { Spacer(minLength: 0) }
                    Text(cue.text)
                        .font(.system(
                            size: max(12, min(videoRect.width, videoRect.height) * track.style.size.renderScale),
                            weight: .semibold
                        ))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: videoRect.width * 0.82)
                    if track.style.placement == .top { Spacer(minLength: 0) }
                }
                .padding(.vertical, videoRect.height * 0.075)
                .frame(width: videoRect.width, height: videoRect.height)
                .position(x: videoRect.midX, y: videoRect.midY)
            }
        }
        .accessibilityHidden(true)
    }
}

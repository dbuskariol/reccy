import AppKit
import SwiftUI

/// A deterministic, aspect-preserving recording thumbnail.
///
/// Quick Look can return preview images with source-dependent dimensions. This
/// component establishes the thumbnail's layout bounds before presenting that
/// image, so a portrait or unusually wide capture can never resize or escape
/// its row. The full source frame remains visible against a neutral backdrop.
struct RecordingThumbnail: View {
    let image: NSImage?
    let size: CGSize
    var cornerRadius: CGFloat = 8
    var showsPlayIndicator = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
            } else {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: min(size.width, size.height) * 0.3))
                    .foregroundStyle(.secondary)
            }

            if showsPlayIndicator {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.28)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                Image(systemName: "play.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.58), in: Circle())
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

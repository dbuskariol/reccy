import SwiftUI

/// The single empty-state treatment used by full-size Reccy workspaces.
///
/// `ContentUnavailableView` sizes itself around its label on macOS, which can
/// make it appear centred inside a small intrinsic rectangle instead of the
/// detail column. This component owns the full available region so every page
/// has the same true centring, surface colour, icon scale, and text measure.
struct WorkspaceEmptyState: View {
    let title: String
    let systemImage: String
    let description: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        _ title: String,
        systemImage: String,
        description: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 58, height: 58)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

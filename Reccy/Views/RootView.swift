import SwiftUI

struct RootView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator
    @EnvironmentObject private var editor: TimelineEditorController
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        NavigationSplitView {
            AppSidebar(
                selection: $navigation.section,
                captureState: coordinator.state
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 218, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .onChange(of: coordinator.state) { oldState, newState in
            if newState.isRecording, !oldState.isRecording {
                navigation.section = .monitor
            } else if case .failed = newState {
                navigation.section = .record
            }
        }
        .onChange(of: coordinator.sessionCompletion) { _, completion in
            guard let completion else { return }
            handleSessionCompletion(completion)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.section {
        case .record:
            RecordView()
        case .monitor:
            MonitorView()
        case .library:
            LibraryView(library: coordinator.library) { item in
                navigation.section = .editor
                Task { await editor.open(item) }
            }
        case .editor:
            EditorView()
        case .settings:
            SettingsView()
        }
    }

    private func handleSessionCompletion(_ completion: CaptureSessionCompletion) {
        let destination = completion.outcome.navigation(for: preferences.completionDestination)
        navigation.section = destination.section

        if destination.section == .editor {
            coordinator.library.refresh()
            guard
                let url = destination.recordingURL,
                let item = coordinator.library.recordings.first(where: { $0.url == url })
            else {
                navigation.section = .library
                return
            }
            Task { await editor.open(item) }
        }
    }
}

private struct AppSidebar: View {
    @Binding var selection: AppSection
    let captureState: CaptureState

    private var primarySections: [AppSection] {
        AppSection.allCases.filter { $0 != .settings }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                ForEach(primarySections) { section in
                    sidebarButton(section)
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 8)

            Spacer(minLength: 12)

            Divider()
            sidebarButton(.settings)
                .padding(.horizontal, 9)
                .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sidebarButton(_ section: AppSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.systemImage)
                    .frame(width: 17)
                Text(section.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if section == .monitor, captureState.isRecording {
                    Circle()
                        .fill(captureState == .paused ? .orange : .red)
                        .frame(width: 7, height: 7)
                        .shadow(
                            color: (captureState == .paused ? Color.orange : Color.red).opacity(0.55),
                            radius: 3
                        )
                        .accessibilityLabel(
                            captureState == .paused ? "Recording paused" : "Recording in progress"
                        )
                }
            }
            .font(.body)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                isSelected ? Color.accentColor : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

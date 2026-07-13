import SwiftUI

struct RootView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator
    @EnvironmentObject private var editor: TimelineEditorController
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var preferences: AppPreferences
    @State private var isSidebarVisible = true

    private let sidebarWidth: CGFloat = 218

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if isSidebarVisible {
                    sidebar
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider()
                }

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isSidebarVisible.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .accessibilityLabel(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                    .reccyTooltip(isSidebarVisible ? "Hide sidebar" : "Show sidebar")
                }
            }
        }
        .onChange(of: coordinator.state) { oldState, newState in
            if newState.isRecording, !oldState.isRecording {
                navigation.section = .monitor
            } else if oldState.isRecording, !newState.isRecording {
                handleRecordingCompletion(newState)
            }
        }
    }

    private var sidebar: some View {
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
        .background(.ultraThinMaterial)
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

    private var primarySections: [AppSection] {
        AppSection.allCases.filter { $0 != .settings }
    }

    private func sidebarButton(_ section: AppSection) -> some View {
        let isSelected = navigation.section == section
        return Button {
            navigation.section = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.systemImage)
                    .frame(width: 17)
                Text(section.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if section == .monitor, coordinator.state.isRecording {
                    Circle()
                        .fill(coordinator.state == .paused ? .orange : .red)
                        .frame(width: 7, height: 7)
                        .shadow(
                            color: (coordinator.state == .paused ? Color.orange : Color.red).opacity(0.55),
                            radius: 3
                        )
                        .accessibilityLabel(
                            coordinator.state == .paused ? "Recording paused" : "Recording in progress"
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

    private func handleRecordingCompletion(_ state: CaptureState) {
        if case .failed = state {
            navigation.section = .record
            return
        }

        switch preferences.completionDestination {
        case .library:
            navigation.section = .library
        case .record:
            navigation.section = .record
        case .editor:
            coordinator.library.refresh()
            guard
                let url = coordinator.lastRecordingURL,
                let item = coordinator.library.recordings.first(where: { $0.url == url })
            else {
                navigation.section = .library
                return
            }
            navigation.section = .editor
            Task { await editor.open(item) }
        }
    }
}

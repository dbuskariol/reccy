import SwiftUI

struct RootView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator
    @EnvironmentObject private var editor: TimelineEditorController
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(primarySections, selection: $navigation.section) { section in
                    HStack {
                        Label(section.title, systemImage: section.systemImage)
                        Spacer()
                        if section == .monitor, coordinator.state.isRecording {
                            Circle()
                                .fill(.red)
                                .frame(width: 7, height: 7)
                                .shadow(color: .red.opacity(0.55), radius: 3)
                                .accessibilityLabel("Recording in progress")
                        }
                    }
                    .tag(section)
                }
                .scrollContentBackground(.hidden)

                Divider()

                Button {
                    navigation.section = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(
                            navigation.section == .settings ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 9)
                .padding(.vertical, 9)
                .accessibilityAddTraits(navigation.section == .settings ? .isSelected : [])
            }
            .navigationTitle("Reccy")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
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
        .onChange(of: coordinator.state) { oldState, newState in
            if newState.isRecording, !oldState.isRecording {
                navigation.section = .monitor
            } else if oldState.isRecording, !newState.isRecording {
                handleRecordingCompletion(newState)
            }
        }
    }

    private var primarySections: [AppSection] {
        AppSection.allCases.filter { $0 != .settings }
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

import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case record
    case monitor
    case library
    case editor

    var id: Self { self }

    var title: String {
        switch self {
        case .record: "Record"
        case .monitor: "Monitor"
        case .library: "Library"
        case .editor: "Editor"
        }
    }

    var systemImage: String {
        switch self {
        case .record: "record.circle"
        case .monitor: "waveform.path.ecg.rectangle"
        case .library: "rectangle.stack"
        case .editor: "timeline.selection"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator
    @EnvironmentObject private var editor: TimelineEditorController
    @State private var selection: AppSection? = .record

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
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
            .navigationTitle("Reccy")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            switch selection ?? .record {
            case .record:
                RecordView()
            case .monitor:
                MonitorView()
            case .library:
                LibraryView(library: coordinator.library) { item in
                    selection = .editor
                    Task { await editor.open(item) }
                }
            case .editor:
                EditorView()
            }
        }
        .onChange(of: coordinator.state) { oldState, newState in
            if newState.isRecording, !oldState.isRecording {
                selection = .monitor
            } else if oldState.isRecording, !newState.isRecording {
                if case .failed = newState {
                    selection = .record
                } else {
                    selection = .library
                }
            }
        }
    }
}

import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case record
    case library
    case editor

    var id: Self { self }

    var title: String {
        switch self {
        case .record: "Record"
        case .library: "Library"
        case .editor: "Editor"
        }
    }

    var systemImage: String {
        switch self {
        case .record: "record.circle"
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
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Reccy")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                SidebarStatusView()
                    .environmentObject(coordinator)
                    .padding(12)
            }
        } detail: {
            switch selection ?? .record {
            case .record:
                RecordView()
            case .library:
                LibraryView(library: coordinator.library) { item in
                    selection = .editor
                    Task { await editor.open(item) }
                }
            case .editor:
                EditorView()
            }
        }
    }
}

private struct SidebarStatusView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.5), radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                if coordinator.state.isRecording {
                    Text(coordinator.formattedDuration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusTitle: String {
        switch coordinator.state {
        case .idle: "Choose a source"
        case .sourceSelected: "Ready"
        case .countingDown: "Starting soon"
        case .starting: "Starting"
        case .recording: "Recording"
        case .stopping: "Finishing"
        case .failed: "Needs attention"
        }
    }

    private var statusColor: Color {
        switch coordinator.state {
        case .recording, .countingDown, .starting, .stopping: .red
        case .sourceSelected: .green
        case .failed: .orange
        case .idle: .secondary
        }
    }
}

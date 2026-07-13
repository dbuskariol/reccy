import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var library: RecordingLibrary
    let onEdit: (RecordingItem) -> Void
    @State private var exportItem: RecordingItem?

    var body: some View {
        Group {
            if library.recordings.isEmpty {
                ContentUnavailableView(
                    "No Recordings Yet",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Your completed recordings will appear here.")
                )
            } else {
                List(library.recordings) { item in
                    recordingRow(item)
                        .listRowInsets(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    library.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    library.revealDirectory()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
            }
        }
        .sheet(item: $exportItem) { item in
            ExportSheet(item: item)
        }
    }

    private func recordingRow(_ item: RecordingItem) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: 84, height: 52)
                Image(systemName: "play.rectangle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(item.formattedDuration)
                    Text("·")
                    Text(item.formattedSize)
                    Text("·")
                    Text(item.fileExtension)
                    Text("·")
                    Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                NSWorkspace.shared.open(item.url)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Play")

            Button {
                onEdit(item)
            } label: {
                Image(systemName: "timeline.selection")
            }
            .buttonStyle(.borderless)
            .help("Edit")

            ShareLink(item: item.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Share")

            Menu {
                Button("Export As…") { exportItem = item }
                Button("Show in Finder") { library.reveal(item) }
                Divider()
                Button("Move to Trash", role: .destructive) {
                    try? library.delete(item)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .contextMenu {
            Button("Play") { NSWorkspace.shared.open(item.url) }
            Button("Edit") { onEdit(item) }
            Button("Export As…") { exportItem = item }
            Button("Show in Finder") { library.reveal(item) }
            Divider()
            Button("Move to Trash", role: .destructive) { try? library.delete(item) }
        }
    }
}

private struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: RecordingItem

    @State private var selectedPreset: ExportPreset = .hevc1080
    @State private var isExporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Export Recording")
                    .font(.title2.weight(.bold))
                Text(item.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            List(ExportPreset.allCases, selection: $selectedPreset) { preset in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preset.title)
                            .font(.headline)
                        Text(preset.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedPreset == preset {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
                .tag(preset)
            }
            .frame(height: 330)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export…") { chooseDestinationAndExport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isExporting)
            }
        }
        .padding(24)
        .frame(width: 560)
        .overlay {
            if isExporting {
                ZStack {
                    Color.black.opacity(0.08)
                    ProgressView("Exporting…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func chooseDestinationAndExport() {
        let panel = NSSavePanel()
        panel.title = "Export Recording"
        panel.nameFieldStringValue = "\(item.name) Export.\(selectedPreset.fileExtension)"
        if let type = UTType(filenameExtension: selectedPreset.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        errorMessage = nil
        Task {
            do {
                try await ExportService().export(
                    sourceURL: item.url,
                    destinationURL: destination,
                    preset: selectedPreset
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isExporting = false
            }
        }
    }
}

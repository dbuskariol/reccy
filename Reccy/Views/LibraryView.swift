import AppKit
import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var library: RecordingLibrary
    let onEdit: (RecordingItem) -> Void
    @State private var exportItem: RecordingItem?
    @State private var selectedID: URL?
    @State private var pendingDelete: RecordingItem?
    @State private var player = AVPlayer()
    @State private var isPreviewPlaying = false

    var body: some View {
        Group {
            if library.recordings.isEmpty {
                WorkspaceEmptyState(
                    "No Recordings Yet",
                    systemImage: "rectangle.stack.badge.plus",
                    description: "Your completed recordings will appear here."
                )
            } else {
                HSplitView {
                    List(library.recordings, selection: $selectedID) { item in
                        recordingRow(item)
                            .tag(item.id)
                            .listRowInsets(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
                    }
                    .frame(minWidth: 410, idealWidth: 510)

                    previewPane
                        .frame(minWidth: 330, idealWidth: 420)
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
        .alert(
            "Move Recording to Trash?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { item in
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Move to Trash", role: .destructive) {
                try? library.delete(item)
                pendingDelete = nil
                selectFirstRecording()
            }
        } message: { item in
            Text("\(item.name) and its Reccy metadata will be moved to the Trash.")
        }
        .onAppear { selectFirstRecording() }
        .onChange(of: selectedID) { _, _ in loadSelectedRecording() }
        .onChange(of: library.recordings.map(\.id)) { _, _ in selectFirstRecording() }
        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
            isPreviewPlaying = status == .playing
        }
        .onDisappear {
            player.pause()
            isPreviewPlaying = false
        }
    }

    private func recordingRow(_ item: RecordingItem) -> some View {
        HStack(spacing: 14) {
            recordingThumbnail(item)
                .frame(width: 126, height: 72)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(item.formattedDuration)
                    Text("·")
                    Text(item.formattedSize)
                    if let resolution = item.formattedResolution {
                        Text("·")
                        Text(resolution)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    metadataBadge(item.sourceKindTitle, systemImage: item.manifest.source.kind.systemImage)
                    metadataBadge(item.audioSummary, systemImage: "waveform")
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { load(item, autoplay: true) }
        .contextMenu {
            Button("Play") { load(item, autoplay: true) }
            Button("Edit") { onEdit(item) }
            Button("Export As…") { exportItem = item }
            Button("Show in Finder") { library.reveal(item) }
            Divider()
            Button("Move to Trash", role: .destructive) { pendingDelete = item }
        }
    }

    private func recordingThumbnail(_ item: RecordingItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.quaternary)
            if let image = library.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "play.rectangle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            LinearGradient(
                colors: [.clear, .black.opacity(0.22)],
                startPoint: .center,
                endPoint: .bottom
            )
            Image(systemName: "play.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(7)
                .background(.black.opacity(0.58), in: Circle())
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
    }

    private func metadataBadge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }

    @ViewBuilder
    private var previewPane: some View {
        if let item = selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    NativeLibraryVideoPlayer(player: player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.separator.opacity(0.5), lineWidth: 0.5)
                        }

                    HStack(spacing: 9) {
                        Button {
                            if player.timeControlStatus == .playing {
                                player.pause()
                            } else {
                                player.play()
                            }
                        } label: {
                            Label(
                                isPreviewPlaying ? "Pause" : "Play",
                                systemImage: isPreviewPlaying ? "pause.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)

                        Button { onEdit(item) } label: {
                            Label("Edit", systemImage: "timeline.selection")
                        }
                        .buttonStyle(.bordered)

                        Button { exportItem = item } label: {
                            Label("Export", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)

                        ShareLink(item: item.url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)

                        Spacer(minLength: 0)

                        Button(role: .destructive) { pendingDelete = item } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .reccyTooltip("Move to Trash")
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name)
                            .font(.title2.weight(.bold))
                            .textSelection(.enabled)
                        Label(item.sourceName, systemImage: item.manifest.source.kind.systemImage)
                            .font(.headline)
                        let detail = item.manifest.source.detail
                        if detail != item.sourceName {
                            Text(detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    recordingDetails(item)

                    Button("Show in Finder", systemImage: "folder") {
                        library.reveal(item)
                    }
                    .buttonStyle(.link)
                }
                .padding(20)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        } else {
            WorkspaceEmptyState(
                "Select a Recording",
                systemImage: "play.rectangle",
                description: "Choose a recording to preview its media and details."
            )
        }
    }

    private func recordingDetails(_ item: RecordingItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 11) {
            detailRow("Duration", value: item.formattedDuration)
            detailRow("Created", value: item.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
            detailRow("File", value: "\(item.formattedSize) · \(item.fileExtension)")
            if let resolution = item.formattedResolution {
                detailRow("Video", value: [resolution, item.formattedFrameRate, item.videoCodec].compactMap { $0 }.joined(separator: " · "))
            }
            detailRow("Audio", value: item.audioSummary)
            detailRow("Dynamic Range", value: item.manifest.isHDR ? "HDR10" : "SDR")
            detailRow("Pointer", value: item.manifest.showsCursor
                ? (item.manifest.highlightsClicks ? "Cursor + click highlights" : "Cursor visible")
                : "Hidden")
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        GridRow {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private var selectedItem: RecordingItem? {
        guard let selectedID else { return nil }
        return library.recordings.first(where: { $0.id == selectedID })
    }

    private func selectFirstRecording() {
        if let selectedID, library.recordings.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = library.recordings.first?.id
        loadSelectedRecording()
    }

    private func loadSelectedRecording() {
        guard let item = selectedItem else {
            player.replaceCurrentItem(with: nil)
            return
        }
        load(item, autoplay: false)
    }

    private func load(_ item: RecordingItem, autoplay: Bool) {
        selectedID = item.id
        isPreviewPlaying = false
        player.replaceCurrentItem(with: AVPlayerItem(url: item.url))
        if autoplay { player.play() }
    }
}

private struct NativeLibraryVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFrameSteppingButtons = true
        view.showsFullScreenToggleButton = true
        view.updatesNowPlayingInfoCenter = false
        view.allowsVideoFrameAnalysis = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) {
        view.player = nil
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

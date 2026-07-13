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
    @State private var playbackTime: TimeInterval = 0

    private let playbackTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if let notice = library.recoveryNotice {
                recoveryBanner(notice)
                Divider()
            }

            Group {
                if library.recordings.isEmpty {
                    WorkspaceEmptyState(
                        "No Recordings Yet",
                        systemImage: "rectangle.stack.badge.plus",
                        description: "Your completed recordings will appear here."
                    )
                } else {
                    HStack(spacing: 0) {
                        recordingBrowser
                            .frame(width: 360)

                        Divider()

                        previewPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    library.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .reccyTooltip("Refresh recordings")

                Button {
                    library.revealDirectory()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .reccyTooltip("Open recording folder")
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
        .onReceive(playbackTimer) { _ in
            let seconds = player.currentTime().seconds
            if seconds.isFinite {
                playbackTime = max(0, seconds)
            }
        }
        .onDisappear {
            player.pause()
            isPreviewPlaying = false
        }
    }

    private func recoveryBanner(_ notice: RecordingRecoveryNotice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: recoverySymbol(for: notice.kind))
                .font(.title3)
                .foregroundStyle(recoveryColor(for: notice.kind))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.headline)
                Text(notice.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if notice.fileURL != nil {
                Button("Show in Finder") { library.revealRecoveryItem() }
            }
            Button {
                library.dismissRecoveryNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .reccyTooltip("Dismiss")
            .accessibilityLabel("Dismiss recovery notice")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(recoveryColor(for: notice.kind).opacity(0.08))
    }

    private func recoverySymbol(for kind: RecordingRecoveryNotice.Kind) -> String {
        switch kind {
        case .recovered: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        }
    }

    private func recoveryColor(for kind: RecordingRecoveryNotice.Kind) -> Color {
        switch kind {
        case .recovered: .green
        case .warning: .orange
        case .information: .blue
        }
    }

    private var recordingBrowser: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                ForEach(library.recordings) { item in
                    recordingBrowserRow(item)
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func recordingBrowserRow(_ item: RecordingItem) -> some View {
        let isSelected = selectedID == item.id
        return Button {
            load(item, autoplay: false)
        } label: {
            recordingRow(item)
                .padding(8)
                .background(
                    isSelected ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

    private func recordingRow(_ item: RecordingItem) -> some View {
        HStack(spacing: 11) {
            recordingThumbnail(item)
                .frame(width: 96, height: 54)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)

                Text([item.formattedDuration, item.formattedSize, item.formattedResolution]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    compactBadge(item.sourceKindTitle, systemImage: item.manifest.source.kind.systemImage)
                    compactBadge(item.audioSummary, systemImage: "waveform")
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func recordingThumbnail(_ item: RecordingItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
            if let image = library.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "play.rectangle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
    }

    private func compactBadge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    @ViewBuilder
    private var previewPane: some View {
        if let item = selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader(item)
                    compactPreview(item)
                    playbackControls(item)
                    recordingDetailsCard(item)
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            WorkspaceEmptyState(
                "Select a Recording",
                systemImage: "play.rectangle",
                description: "Choose a recording to preview its media and details."
            )
        }
    }

    private func detailHeader(_ item: RecordingItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                        .textSelection(.enabled)

                    Label(item.sourceName, systemImage: item.manifest.source.kind.systemImage)
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    let detail = item.manifest.source.detail
                    if !detail.isEmpty, detail != item.sourceName {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 6)

                HStack(spacing: 7) {
                    Button {
                        onEdit(item)
                    } label: {
                        Image(systemName: "timeline.selection")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderedProminent)
                    .reccyTooltip("Edit recording")
                    .accessibilityLabel("Edit Recording")

                    Button {
                        exportItem = item
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .reccyTooltip("Export recording")
                    .accessibilityLabel("Export Recording")

                    ShareLink(item: item.url) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .reccyTooltip("Share recording")
                    .accessibilityLabel("Share Recording")

                    Button(role: .destructive) {
                        pendingDelete = item
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .reccyTooltip("Move to Trash")
                }
            }

            HStack(spacing: 7) {
                compactBadge(item.sourceKindTitle, systemImage: item.manifest.source.kind.systemImage)
                compactBadge(item.audioDetail, systemImage: "waveform")
                compactBadge(item.manifest.isHDR ? "HDR10" : "SDR", systemImage: "circle.lefthalf.filled")
            }
        }
    }

    private func compactPreview(_ item: RecordingItem) -> some View {
        NativeLibraryVideoPlayer(player: player)
            .frame(maxWidth: 560)
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.separator.opacity(0.5), lineWidth: 0.5)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel("Preview of \(item.name)")
    }

    private func playbackControls(_ item: RecordingItem) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                playbackButton("gobackward.5", help: "Back 5 seconds") { seekBy(-5) }

                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPreviewPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 17, height: 17)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .reccyTooltip(isPreviewPlaying ? "Pause" : "Play")
                .accessibilityLabel(isPreviewPlaying ? "Pause" : "Play")

                playbackButton("goforward.5", help: "Forward 5 seconds") { seekBy(5) }

                Text("\(playbackTimecode(playbackTime)) / \(playbackTimecode(item.duration))")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button {
                    library.reveal(item)
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .reccyTooltip("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }

            waveformScrubber(item)
        }
        .padding(12)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func playbackButton(
        _ systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .reccyTooltip(help)
        .accessibilityLabel(help)
    }

    private func waveformScrubber(_ item: RecordingItem) -> some View {
        GeometryReader { geometry in
            let progress = item.duration > 0 ? playbackTime / item.duration : 0
            ZStack(alignment: .leading) {
                if let audioTrackID = item.audioTrackIDs.first {
                    ReccyAssetWaveform(
                        sourceURL: item.url,
                        sourceTrackID: audioTrackID,
                        sourceStart: 0,
                        duration: item.duration,
                        color: .accentColor,
                        progress: progress
                    )
                    .padding(.vertical, 4)
                } else {
                    Capsule()
                        .fill(.secondary.opacity(0.18))
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                }

                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1)
                    .offset(x: max(0, min(geometry.size.width - 1, geometry.size.width * progress)))
                    .allowsHitTesting(false)
            }
            .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard item.duration > 0 else { return }
                        let fraction = min(max(value.location.x / max(geometry.size.width, 1), 0), 1)
                        seek(to: item.duration * fraction)
                    }
            )
            .accessibilityLabel("Recording waveform and scrubber")
            .accessibilityValue(playbackTimecode(playbackTime))
        }
        .frame(height: 44)
    }

    private func recordingDetailsCard(_ item: RecordingItem) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading("Recording details")

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    detailRow("Source", value: item.sourceKindTitle)
                    detailRow("Name", value: item.sourceName)
                    if let bundleID = item.manifest.source.applicationBundleIdentifier {
                        detailRow("Application", value: bundleID)
                    }
                    if let windowName = item.manifest.source.windowName {
                        detailRow("Window", value: windowName)
                    }
                    detailRow("Duration", value: item.formattedDuration)
                    detailRow(
                        "Created",
                        value: item.createdAt.formatted(
                            .dateTime.day().month(.abbreviated).year().hour().minute()
                        )
                    )
                    detailRow("File", value: "\(item.formattedSize) · \(item.fileExtension)")
                    if let resolution = item.formattedResolution {
                        detailRow(
                            "Video",
                            value: [resolution, item.formattedFrameRate, item.videoCodec]
                                .compactMap { $0 }
                                .joined(separator: " · ")
                        )
                    }
                    detailRow("Audio", value: item.audioDetail)
                    detailRow("Dynamic Range", value: item.manifest.isHDR ? "HDR10" : "SDR")
                    detailRow(
                        "Pointer",
                        value: item.manifest.showsCursor
                            ? (item.manifest.highlightsClicks ? "Cursor + click highlights" : "Cursor visible")
                            : "Hidden"
                    )
                }
            }
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
            playbackTime = 0
            return
        }
        load(item, autoplay: false)
    }

    private func load(_ item: RecordingItem, autoplay: Bool) {
        selectedID = item.id
        isPreviewPlaying = false
        playbackTime = 0
        player.replaceCurrentItem(with: AVPlayerItem(url: item.url))
        if autoplay { player.play() }
    }

    private func togglePlayback() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if let item = selectedItem, playbackTime >= item.duration - 0.02 {
                seek(to: 0)
            }
            player.play()
        }
    }

    private func seekBy(_ delta: TimeInterval) {
        seek(to: playbackTime + delta)
    }

    private func seek(to seconds: TimeInterval) {
        let duration = selectedItem?.duration ?? 0
        let target = min(max(seconds, 0), duration)
        playbackTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func playbackTimecode(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct NativeLibraryVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
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

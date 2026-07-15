import AppKit
import AVKit
import Combine
import OSLog
import SwiftUI

struct LibraryView: View {
    private let logger = Logger(subsystem: "com.reccy.mac", category: "LibraryPreview")
    @EnvironmentObject private var transcription: TranscriptionController
    @ObservedObject var library: RecordingLibrary
    let onEdit: (RecordingItem) -> Void

    @State private var exportItem: RecordingItem?
    @State private var selectedID: URL?
    @State private var pendingDelete: RecordingItem?
    @State private var player = AVPlayer()
    @State private var isPreviewPlaying = false
    @State private var isPreviewLoading = false
    @State private var previewLoadTask: Task<Void, Never>?
    @State private var playbackTime: TimeInterval = 0
    @State private var searchText = ""

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
            ExportSheet(source: ExportSource(
                name: item.name,
                asset: AVURLAsset(url: item.url),
                sourceURL: item.url
            ))
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
                pendingDelete = nil
                do {
                    try library.delete(item)
                    selectFirstRecording()
                } catch {
                    library.presentNotice(
                        kind: .warning,
                        title: "Recording Couldn’t Be Moved to Trash",
                        message: error.localizedDescription,
                        fileURL: item.url
                    )
                }
            }
        } message: { item in
            Text("This moves \(item.name), its metadata, and its non-destructive editing project to the Trash.")
        }
        .onAppear {
            selectFirstRecording()
            loadTranscriptDocuments()
        }
        .onChange(of: selectedID) { _, _ in loadSelectedRecording() }
        .onChange(of: library.recordings.map(\.id)) { _, _ in
            selectFirstRecording()
            loadTranscriptDocuments()
        }
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
            previewLoadTask?.cancel()
            previewLoadTask = nil
            player.pause()
            isPreviewPlaying = false
            isPreviewLoading = false
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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search recordings or spoken words", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .reccyTooltip("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.bar)

            Divider()

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(filteredRecordings) { item in
                        recordingBrowserRow(item)
                    }
                }
                .padding(10)
            }
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
            transcriptionContextActions(item)
            Button("Show in Finder") { library.reveal(item) }
            Divider()
            Button("Move to Trash", role: .destructive) { pendingDelete = item }
        }
    }

    private func recordingRow(_ item: RecordingItem) -> some View {
        HStack(spacing: 11) {
            RecordingThumbnail(
                image: library.thumbnail(for: item),
                size: CGSize(width: 96, height: 54),
                showsPlayIndicator: true
            )

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
                    if let camera = item.cameraSummary {
                        compactBadge(camera, systemImage: "video.fill")
                    }
                    compactBadge(item.audioSummary, systemImage: "waveform")
                    transcriptStatusBadge(item)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
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
                    transcriptCard(item)
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
                    .reccyAccessibleControl("Edit Recording", help: "Edit recording")

                    Button {
                        exportItem = item
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .reccyAccessibleControl("Export Recording", help: "Export recording")

                    ShareLink(item: item.url) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .reccyAccessibleControl("Share Recording", help: "Share recording")

                    Button(role: .destructive) {
                        pendingDelete = item
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .reccyAccessibleControl("Move to Trash")
                }
            }

            HStack(spacing: 7) {
                compactBadge(item.sourceKindTitle, systemImage: item.manifest.source.kind.systemImage)
                if let camera = item.cameraSummary {
                    compactBadge(camera, systemImage: "video.fill")
                }
                compactBadge(item.audioDetail, systemImage: "waveform")
                compactBadge(item.manifest.isHDR ? "HDR10" : "SDR", systemImage: "circle.lefthalf.filled")
            }
        }
    }

    private func compactPreview(_ item: RecordingItem) -> some View {
        ZStack {
            NativeLibraryVideoPlayer(player: player)

            if isPreviewLoading {
                ProgressView(item.manifest.camera == nil ? "Preparing preview…" : "Preparing camera preview…")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
        }
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

    @ViewBuilder
    private func transcriptCard(_ item: RecordingItem) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeading(
                        "Transcript",
                        subtitle: transcriptSubtitle(for: item)
                    )
                    Spacer()
                    transcriptActions(item)
                }

                switch transcription.jobState(for: item.url) {
                case .queued:
                    transcriptProgress(nil, label: "Queued")
                case .working(let update):
                    transcriptProgress(update.fractionCompleted, label: update.detail ?? "Transcribing")
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                case .idle:
                    Text(item.audioTrackIDs.isEmpty ? "This recording has no audio tracks." : "No transcript yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .ready:
                    if let document = transcription.document(for: item.url) {
                        transcriptDocument(document)
                    } else {
                        Text("Transcript metadata is loading…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptActions(_ item: RecordingItem) -> some View {
        let state = transcription.jobState(for: item.url)
        if state.isWorking {
            Button {
                transcription.cancelTranscription(for: item.url)
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .reccyAccessibleControl("Cancel Transcription")
        } else {
            Button {
                transcription.transcribe(item)
            } label: {
                Image(systemName: transcription.document(for: item.url) == nil
                    ? "captions.bubble"
                    : "arrow.clockwise")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .disabled(item.audioTrackIDs.isEmpty)
            .reccyAccessibleControl(
                transcription.document(for: item.url) == nil ? "Transcribe" : "Transcribe Again"
            )

            if transcription.document(for: item.url) != nil {
                Menu {
                    ForEach(TranscriptExportFormat.allCases) { format in
                        Button(format.title) { exportTranscript(item, format: format) }
                    }
                } label: {
                    Image(systemName: "text.badge.arrow.up")
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 32)
                .reccyTooltip("Export transcript")
                .accessibilityLabel("Export transcript")
            }
        }
    }

    private func transcriptDocument(_ document: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            ForEach(document.tracks) { track in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(track.role.title, systemImage: track.role.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(track.role == .systemAudio ? .teal : .orange)
                        Spacer()
                        Text(track.provider.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    FlowTranscriptView(segments: track.segments) { segment in
                        seek(to: segment.sourceStart)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func transcriptProgress(_ fraction: Double?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label)
                    .font(.callout)
                Spacer()
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction { ProgressView(value: fraction) } else { ProgressView() }
        }
    }

    private func transcriptSubtitle(for item: RecordingItem) -> String {
        switch transcription.jobState(for: item.url) {
        case .queued, .working:
            "Recording saved. On-device transcription continues here in the background."
        case .idle, .ready, .failed:
            "On-device, source-aligned, and searchable."
        }
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
                .reccyAccessibleControl(isPreviewPlaying ? "Pause" : "Play")

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
                .reccyAccessibleControl("Show in Finder")
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
        .reccyAccessibleControl(help)
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
                    if let camera = item.cameraDetail {
                        detailRow("Camera", value: camera)
                    }
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

    private var filteredRecordings: [RecordingItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return library.recordings }
        return library.recordings.filter { item in
            item.name.localizedCaseInsensitiveContains(query)
                || item.sourceName.localizedCaseInsensitiveContains(query)
                || (transcription.document(for: item.url)?.searchableText.localizedCaseInsensitiveContains(query) == true)
        }
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
        isPreviewLoading = true
        playbackTime = 0
        player.pause()
        player.replaceCurrentItem(with: nil)
        previewLoadTask?.cancel()
        previewLoadTask = Task { @MainActor in
            do {
                let loadedProject = try await RecordingTimelineProjectLoader.load(for: item)
                let build = try await TimelineCompositionBuilder.build(loadedProject.project)
                try Task.checkCancellation()
                guard selectedID == item.id else { return }

                let snapshot = (build.composition.copy() as? AVComposition) ?? build.composition
                let playerItem = AVPlayerItem(asset: snapshot)
                playerItem.videoComposition = build.videoComposition
                playerItem.audioMix = build.audioMix
                playerItem.seekingWaitsForVideoCompositionRendering = true
                player.replaceCurrentItem(with: playerItem)
                isPreviewLoading = false
                logger.info(
                    "Prepared composed preview videoTracks=\(build.composition.tracks(withMediaType: .video).count) file=\(item.url.lastPathComponent, privacy: .public)"
                )
                if autoplay { player.play() }
            } catch is CancellationError {
                return
            } catch {
                guard selectedID == item.id else { return }
                logger.error(
                    "Falling back to source preview file=\(item.url.lastPathComponent, privacy: .public) reason=\(error.localizedDescription, privacy: .public)"
                )
                player.replaceCurrentItem(with: AVPlayerItem(url: item.url))
                isPreviewLoading = false
                if autoplay { player.play() }
            }
        }
        transcription.loadDocument(for: item.url)
    }

    private func loadTranscriptDocuments() {
        for recording in library.recordings {
            transcription.loadDocument(for: recording.url)
        }
    }

    @ViewBuilder
    private func transcriptStatusBadge(_ item: RecordingItem) -> some View {
        switch transcription.jobState(for: item.url) {
        case .queued:
            compactBadge("Transcript queued", systemImage: "clock.badge")
                .foregroundStyle(.tint)
        case .working(let update):
            compactBadge(
                update.phase == .preparing ? "Loading model" : "Transcribing",
                systemImage: "captions.bubble.fill"
            )
            .foregroundStyle(.tint)
        case .ready:
            Image(systemName: "captions.bubble.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .accessibilityLabel("Transcript ready")
        case .failed:
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .accessibilityLabel("Transcription failed")
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private func transcriptionContextActions(_ item: RecordingItem) -> some View {
        if transcription.jobState(for: item.url).isWorking {
            Button("Cancel Transcription") { transcription.cancelTranscription(for: item.url) }
        } else {
            Button(transcription.document(for: item.url) == nil ? "Transcribe" : "Transcribe Again") {
                transcription.transcribe(item)
            }
            .disabled(item.audioTrackIDs.isEmpty)
        }
    }

    private func exportTranscript(_ item: RecordingItem, format: TranscriptExportFormat) {
        guard let document = transcription.document(for: item.url) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.nameFieldStringValue = "\(item.name).\(format.fileExtension)"
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let segments = document.tracks.flatMap { track in
            track.segments.map { segment in
                ProjectedTranscriptSegment(
                    id: "\(track.id):\(segment.id)",
                    sourceSegmentID: segment.id,
                    clipID: track.id,
                    laneID: track.id,
                    role: track.role,
                    text: segment.displayText,
                    timelineStart: segment.sourceStart,
                    duration: segment.duration
                )
            }
        }.sorted { $0.timelineStart < $1.timelineStart }
        do {
            try TranscriptExportFormatter.string(segments: segments, format: format)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            library.presentNotice(
                kind: .warning,
                title: "Transcript Couldn’t Be Exported",
                message: error.localizedDescription,
                fileURL: item.url
            )
        }
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

private struct FlowTranscriptView: View {
    let segments: [TranscriptSegment]
    let onSelect: (TranscriptSegment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(segments) { segment in
                Button {
                    onSelect(segment)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(timecode(segment.sourceStart))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 38, alignment: .trailing)
                        Text(segment.displayText)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .reccyTooltip("Play from \(timecode(segment.sourceStart))")
                .accessibilityLabel("Play transcript from \(timecode(segment.sourceStart)): \(segment.displayText)")
            }
        }
    }

    private func timecode(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

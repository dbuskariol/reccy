import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @EnvironmentObject private var editor: TimelineEditorController
    @State private var exportPreset: ExportPreset = .hevcBest
    @State private var isExporting = false
    @State private var exportError: String?

    private let playbackTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if editor.isLoading {
                ProgressView("Preparing editor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let project = editor.project {
                editorWorkspace(project)
            } else {
                ContentUnavailableView(
                    "Open a Recording",
                    systemImage: "timeline.selection",
                    description: Text("Choose Edit in the Library to create a non-destructive project.")
                )
            }
        }
        .navigationTitle("Editor")
        .toolbar { editorToolbar }
        .onReceive(playbackTimer) { _ in editor.syncPlayheadFromPlayer() }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "Unknown error")
        }
    }

    private func editorWorkspace(_ project: TimelineProject) -> some View {
        VStack(spacing: 0) {
            HSplitView {
                preview(project)
                    .frame(minWidth: 470, idealWidth: 700)
                inspector(project)
                    .frame(minWidth: 230, idealWidth: 270, maxWidth: 320)
            }
            .frame(minHeight: 340)

            Divider()

            timeline(project)
                .frame(minHeight: 270, idealHeight: 320)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func preview(_ project: TimelineProject) -> some View {
        VStack(spacing: 12) {
            VideoPlayer(player: editor.player)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.separator.opacity(0.5), lineWidth: 0.5)
                }
                .padding([.top, .horizontal], 18)

            HStack(spacing: 16) {
                Button {
                    editor.seek(to: max(0, editor.playhead - 5))
                } label: {
                    Image(systemName: "gobackward.5")
                }

                Button {
                    editor.playPause()
                } label: {
                    Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    editor.seek(to: min(editor.duration, editor.playhead + 5))
                } label: {
                    Image(systemName: "goforward.5")
                }

                Text(timecode(editor.playhead))
                    .font(.body.monospacedDigit().weight(.semibold))
                Text("/ \(timecode(project.duration))")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                if editor.isRebuilding {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }

    private func inspector(_ project: TimelineProject) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text("Non-destructive project")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if let selected = project.lanes
                .flatMap(\.clips)
                .first(where: { $0.id == editor.selectedClipID })
            {
                Text("Selected Clip")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LabeledContent("Name", value: selected.name)
                LabeledContent("Start", value: timecode(selected.timelineStart))
                LabeledContent("Duration", value: timecode(selected.duration))

                Button("Split Selected Clip", systemImage: "scissors") {
                    editor.splitSelectionAtPlayhead()
                }
                .disabled(!selected.contains(editor.playhead))

                Button("Split All Tracks", systemImage: "timeline.selection") {
                    editor.splitAllAtPlayhead()
                }
                .disabled(!selected.contains(editor.playhead))

                Button("Delete Clip", systemImage: "trash", role: .destructive) {
                    editor.deleteSelection()
                }

                Button("Delete and Close Gap", systemImage: "arrow.left.and.right") {
                    editor.rippleDeleteSelection()
                }
            } else {
                Text("Select a clip to split or delete it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button {
                editor.toggleVoiceover()
            } label: {
                Label(
                    editor.isVoiceoverRecording ? "Stop Voiceover" : "Record Voiceover",
                    systemImage: editor.isVoiceoverRecording ? "stop.circle.fill" : "mic.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(editor.isVoiceoverRecording ? .red : .accentColor)
            .controlSize(.large)

            Text("Starts at the playhead while the project plays. Voiceovers remain independent, splittable clips.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let errorMessage = editor.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(18)
        .background(.bar)
    }

    private func timeline(_ project: TimelineProject) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Menu {
                    Button("Split Selected Clip") { editor.splitSelectionAtPlayhead() }
                        .disabled(editor.selectedClipID == nil)
                    Button("Split All Tracks") { editor.splitAllAtPlayhead() }
                } label: {
                    Label("Split", systemImage: "scissors")
                }
                .disabled(project.duration <= 0)

                Menu {
                    Button("Delete Clip") { editor.deleteSelection() }
                    Button("Delete and Close Gap") { editor.rippleDeleteSelection() }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(editor.selectedClipID == nil)

                Divider().frame(height: 18)

                Text(timecode(editor.playhead))
                    .font(.caption.monospacedDigit().weight(.semibold))

                Slider(
                    value: Binding(
                        get: { editor.playhead },
                        set: { editor.seek(to: $0) }
                    ),
                    in: 0...max(project.duration, 0.01)
                )

                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $editor.pixelsPerSecond, in: 30...180)
                    .frame(width: 110)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                let trackWidth = max(project.duration * editor.pixelsPerSecond, 820)
                VStack(alignment: .leading, spacing: 7) {
                    ruler(width: trackWidth, duration: project.duration)
                    ForEach(project.lanes) { lane in
                        laneRow(lane, trackWidth: trackWidth)
                    }
                }
                .padding(12)
                .overlay(alignment: .topLeading) {
                    Rectangle()
                        .fill(.red)
                        .frame(width: 1.5)
                        .offset(x: 151 + editor.playhead * editor.pixelsPerSecond, y: 8)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func ruler(width: Double, duration: TimeInterval) -> some View {
        HStack(spacing: 0) {
            Text("TRACKS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            ZStack(alignment: .leading) {
                let interval = editor.pixelsPerSecond > 100 ? 2.0 : 5.0
                ForEach(Array(stride(from: 0.0, through: duration + interval, by: interval)), id: \.self) { value in
                    VStack(spacing: 2) {
                        Text(timecode(value, includeHours: false))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Rectangle()
                            .fill(.separator)
                            .frame(width: 1, height: 5)
                    }
                    .offset(x: value * editor.pixelsPerSecond)
                }
            }
            .frame(width: width, height: 25, alignment: .leading)
        }
    }

    private func laneRow(_ lane: TimelineLane, trackWidth: Double) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: lane.kind.systemImage)
                    Text(lane.name)
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))

                if lane.kind != .video {
                    HStack(spacing: 5) {
                        Button {
                            editor.toggleMute(laneID: lane.id)
                        } label: {
                            Image(systemName: lane.isMuted ? "speaker.slash.fill" : "speaker.wave.1")
                        }
                        .buttonStyle(.borderless)

                        Slider(
                            value: Binding(
                                get: { lane.volume },
                                set: { editor.setVolume($0, laneID: lane.id) }
                            ),
                            in: 0...2
                        )
                    }
                }
            }
            .frame(width: 130, alignment: .leading)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary.opacity(0.55))

                ForEach(lane.clips) { clip in
                    clipView(clip, lane: lane)
                        .frame(width: max(clip.duration * editor.pixelsPerSecond, 6), height: 52)
                        .offset(x: clip.timelineStart * editor.pixelsPerSecond)
                }
            }
            .frame(width: trackWidth, height: 58, alignment: .leading)
        }
    }

    private func clipView(_ clip: TimelineClip, lane: TimelineLane) -> some View {
        let selected = editor.selectedClipID == clip.id
        return Button {
            editor.select(clip)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: lane.kind.systemImage)
                Text(clip.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(laneColor(lane.kind).gradient)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Color.white : Color.clear, lineWidth: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .shadow(color: selected ? laneColor(lane.kind).opacity(0.4) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Save", systemImage: "square.and.arrow.down") {
                do { try editor.save() } catch { exportError = error.localizedDescription }
            }
            .disabled(!editor.hasProject)

            Menu {
                ForEach(ExportPreset.allCases) { preset in
                    Button(preset.title) { exportProject(preset) }
                }
            } label: {
                Label(isExporting ? "Exporting…" : "Export", systemImage: "square.and.arrow.up")
            }
            .disabled(!editor.hasProject || isExporting)
        }
    }

    private func exportProject(_ preset: ExportPreset) {
        let panel = NSSavePanel()
        panel.title = "Export Project"
        panel.nameFieldStringValue = "\(editor.project?.name ?? "Reccy Project") Export.\(preset.fileExtension)"
        if let type = UTType(filenameExtension: preset.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        Task {
            do {
                try await editor.export(to: url, preset: preset)
            } catch {
                exportError = error.localizedDescription
            }
            isExporting = false
        }
    }

    private func laneColor(_ kind: TimelineLaneKind) -> Color {
        switch kind {
        case .video: .indigo
        case .systemAudio: .teal
        case .microphone: .orange
        case .voiceover: .pink
        }
    }

    private func timecode(_ time: TimeInterval, includeHours: Bool = true) -> String {
        let totalSeconds = max(0, Int(time.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if includeHours || hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

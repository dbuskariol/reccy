import AVKit
import Combine
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var editor: TimelineEditorController
    @State private var exportSource: ExportSource?
    @State private var exportError: String?

    private let playbackTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private let trackHeaderWidth: CGFloat = 176
    private let rulerHeight: CGFloat = 32
    private let laneHeight: CGFloat = 68

    var body: some View {
        Group {
            if editor.isLoading {
                ProgressView("Preparing editor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let project = editor.project {
                editorWorkspace(project)
            } else {
                WorkspaceEmptyState(
                    "Open a Recording",
                    systemImage: "timeline.selection",
                    description: "Choose Edit in the Library to create a non-destructive project."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Editor")
        .toolbar { editorToolbar }
        .sheet(item: $exportSource) { source in
            ExportSheet(source: source)
        }
        .onAppear { editor.refreshVoiceoverInputDevices() }
        .onReceive(playbackTimer) { _ in editor.syncPlayheadFromPlayer() }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "Unknown error")
        }
        .alert("Editor Couldn’t Apply Change", isPresented: Binding(
            get: { editor.errorMessage != nil },
            set: { if !$0 { editor.errorMessage = nil } }
        )) {
            Button("OK") { editor.errorMessage = nil }
        } message: {
            Text(editor.errorMessage ?? "Unknown error")
        }
    }

    private func editorWorkspace(_ project: TimelineProject) -> some View {
        VSplitView {
            previewPane(project)
                .frame(minHeight: 250, idealHeight: 390)

            timelinePane(project)
                .frame(minHeight: 285, idealHeight: 360)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func previewPane(_ project: TimelineProject) -> some View {
        VStack(spacing: 0) {
            NativeVideoPlayer(player: editor.player)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.separator.opacity(0.45), lineWidth: 0.5)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            transportBar(project)
        }
    }

    private func transportBar(_ project: TimelineProject) -> some View {
        HStack(spacing: 10) {
            transportButton("gobackward.5", help: "Back 5 seconds") {
                editor.seekBy(-5)
            }
            transportButton("backward.frame.fill", help: "Previous frame") {
                editor.stepFrames(-1)
            }

            Button {
                editor.playPause()
            } label: {
                Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .clipShape(Circle())
            .reccyTooltip(editor.isPlaying ? "Pause (Space)" : "Play (Space)")
            .keyboardShortcut(.space, modifiers: [])

            transportButton("forward.frame.fill", help: "Next frame") {
                editor.stepFrames(1)
            }
            transportButton("goforward.5", help: "Forward 5 seconds") {
                editor.seekBy(5)
            }

            Divider()
                .frame(height: 22)

            Text(timecode(editor.playhead, includeFrames: true))
                .font(.body.monospacedDigit().weight(.semibold))
            Text("/ \(timecode(project.duration))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            if editor.isRebuilding {
                ProgressView()
                    .controlSize(.small)
                Text("Updating preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func transportButton(
        _ systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 19, height: 19)
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .reccyTooltip(help)
    }

    private func timelinePane(_ project: TimelineProject) -> some View {
        VStack(spacing: 0) {
            editCommandBar(project)
            Divider()

            HStack(alignment: .top, spacing: 0) {
                trackHeaders(project)
                    .frame(width: trackHeaderWidth)

                Divider()

                ScrollView(.horizontal) {
                    timelineCanvas(project)
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .scrollIndicators(.visible)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func editCommandBar(_ project: TimelineProject) -> some View {
        HStack(spacing: 8) {
            editorAction("Split Clip", systemImage: "scissors", help: "Split the selected clip at the playhead (⌘B)") {
                editor.splitSelectionAtPlayhead()
            }
            .disabled(!editor.canSplitSelection)
            .keyboardShortcut("b", modifiers: .command)

            editorAction("Split All", systemImage: "timeline.selection", help: "Split every track at the playhead (⇧⌘B)") {
                editor.splitAllAtPlayhead()
            }
            .disabled(!editor.canSplitAll)
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Divider()
                .frame(height: 20)

            editorAction("Delete", systemImage: "trash", help: "Delete the selected clip") {
                editor.deleteSelection()
            }
            .disabled(editor.selectedClipID == nil)
            .keyboardShortcut(.delete, modifiers: [])

            editorAction("Close Gap", systemImage: "arrow.left.and.right", help: "Delete the selected time range and close the gap") {
                editor.rippleDeleteSelection()
            }
            .disabled(editor.selectedClipID == nil)
            .keyboardShortcut(.delete, modifiers: .command)

            Divider()
                .frame(height: 20)

            Button {
                editor.moveLinkedClips.toggle()
            } label: {
                Image(systemName: editor.moveLinkedClips ? "link" : "link.badge.plus")
                    .frame(width: 20, height: 18)
            }
            .buttonStyle(.bordered)
            .frame(width: 44)
            .tint(editor.moveLinkedClips ? .accentColor : nil)
            .accessibilityLabel("Move linked audio and video")
            .reccyTooltip(editor.moveLinkedClips
                ? "Linked movement is on — video and matching audio move or trim together"
                : "Independent movement is on — each audio or video clip moves and trims separately")

            Picker(
                "Gap Fill",
                selection: Binding(
                    get: { editor.selectedGapFillMode },
                    set: { editor.setSelectedGapFillMode($0) }
                )
            ) {
                ForEach(TimelineGapFillMode.allCases) { mode in
                    Image(systemName: mode.systemImage)
                        .accessibilityLabel(mode.title)
                        .tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 126)
            .disabled(editor.selectedGapID == nil)
            .reccyTooltip(editor.selectedGapID == nil
                ? "Select a video gap to choose how it renders"
                : "Render this gap as black, the previous frame, or the next frame")

            Divider()
                .frame(height: 20)

            Menu {
                Button {
                    editor.selectedVoiceoverInputID = nil
                } label: {
                    Label(
                        "System Default",
                        systemImage: editor.selectedVoiceoverInputID == nil ? "checkmark" : "circle"
                    )
                }
                Divider()
                ForEach(editor.voiceoverInputDevices) { device in
                    Button {
                        editor.selectedVoiceoverInputID = device.id
                    } label: {
                        Label(
                            device.name,
                            systemImage: editor.selectedVoiceoverInputID == device.id ? "checkmark" : "circle"
                        )
                    }
                }
            } label: {
                Image(systemName: "mic.badge.plus")
                    .frame(width: 20, height: 18)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .frame(width: 44)
            .disabled(editor.isVoiceoverRecording)
            .accessibilityLabel("Voiceover Input")
            .reccyTooltip("Voiceover input: \(editor.selectedVoiceoverInputName)")

            Button {
                editor.toggleVoiceover()
            } label: {
                Image(systemName: editor.isVoiceoverRecording ? "stop.fill" : "mic.fill")
                    .frame(width: 20, height: 18)
            }
            .buttonStyle(.borderedProminent)
            .frame(width: 44)
            .tint(editor.isVoiceoverRecording ? .red : .accentColor)
            .accessibilityLabel(editor.isVoiceoverRecording ? "Stop Voiceover" : "Record Voiceover")
            .reccyTooltip("Record a new, independently editable audio clip at the playhead")

            Spacer(minLength: 12)

            Divider()
                .frame(height: 20)

            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $editor.pixelsPerSecond, in: 30...220)
                .frame(width: 104)
                .accessibilityLabel("Timeline zoom")
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func editorAction(
        _ title: String,
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.bordered)
        .frame(width: 44)
        .accessibilityLabel(title)
        .reccyTooltip(help)
    }

    private func trackHeaders(_ project: TimelineProject) -> some View {
        VStack(spacing: 0) {
            Text("TRACKS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: rulerHeight)

            ForEach(project.lanes) { lane in
                laneHeader(lane)
                    .frame(height: laneHeight)
                Divider()
            }

            Spacer(minLength: 0)
        }
        .background(.bar.opacity(0.72))
    }

    private func laneHeader(_ lane: TimelineLane) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: lane.kind.systemImage)
                    .foregroundStyle(laneColor(lane.kind))
                Text(lane.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if lane.kind != .video {
                HStack(spacing: 7) {
                    Button {
                        editor.toggleMute(laneID: lane.id)
                    } label: {
                        Image(systemName: lane.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .frame(width: 16)
                    }
                    .buttonStyle(.borderless)
                    .reccyTooltip(lane.isMuted ? "Unmute \(lane.name)" : "Mute \(lane.name)")

                    Slider(
                        value: Binding(
                            get: { lane.volume },
                            set: { editor.setVolume($0, laneID: lane.id) }
                        ),
                        in: 0...2
                    )
                    .controlSize(.small)
                    .accessibilityLabel("\(lane.name) volume")
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func timelineCanvas(_ project: TimelineProject) -> some View {
        let paddingDuration = max(4, 480 / max(editor.pixelsPerSecond, 1))
        let canvasDuration = max(project.duration + paddingDuration, 12)
        let trackWidth = canvasDuration * editor.pixelsPerSecond
        let canvasHeight = rulerHeight + CGFloat(project.lanes.count) * (laneHeight + 1)

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ruler(width: trackWidth, duration: canvasDuration)

                ForEach(project.lanes) { lane in
                    laneRow(
                        lane,
                        videoGaps: lane.kind == .video ? project.videoGaps : [],
                        trackWidth: trackWidth
                    )
                        .frame(height: laneHeight)
                    Divider()
                }
            }

            TimelinePlayhead()
                .frame(height: canvasHeight)
                .offset(x: editor.playhead * editor.pixelsPerSecond - 5)
                .allowsHitTesting(false)
                .zIndex(20)
        }
        .frame(width: trackWidth, height: canvasHeight, alignment: .topLeading)
        .coordinateSpace(name: "timelineCanvas")
    }

    private func ruler(width: Double, duration: TimeInterval) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))

            let interval = rulerInterval
            ForEach(Array(stride(from: 0.0, through: duration, by: interval)), id: \.self) { value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(timecode(value, includeHours: false))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1, height: 6)
                }
                .offset(x: value * editor.pixelsPerSecond + 4, y: 3)
            }
        }
        .frame(width: width, height: rulerHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineCanvas"))
                .onChanged { value in
                editor.seek(to: value.location.x / editor.pixelsPerSecond)
            }
        )
    }

    private var rulerInterval: TimeInterval {
        if editor.pixelsPerSecond >= 150 { return 1 }
        if editor.pixelsPerSecond >= 70 { return 2 }
        return 5
    }

    private func laneRow(
        _ lane: TimelineLane,
        videoGaps: [TimelineGapSegment],
        trackWidth: Double
    ) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineCanvas"))
                        .onChanged { value in
                        editor.seek(to: value.location.x / editor.pixelsPerSecond)
                    }
                )

            ForEach(videoGaps) { gap in
                TimelineGapView(
                    gap: gap,
                    pixelsPerSecond: editor.pixelsPerSecond,
                    isSelected: editor.selectedGapID == gap.id,
                    onSelect: { time in editor.select(gap, at: time) }
                )
                .frame(width: max(gap.duration * editor.pixelsPerSecond, 18), height: laneHeight - 12)
                .offset(x: gap.timelineStart * editor.pixelsPerSecond)
            }

            ForEach(lane.clips) { clip in
                TimelineClipView(
                    clip: clip,
                    lane: lane,
                    pixelsPerSecond: editor.pixelsPerSecond,
                    isSelected: editor.selectedClipID == clip.id,
                    color: laneColor(lane.kind),
                    onSelect: { time in editor.select(clip, at: time) },
                    onBeginMove: { anchorTime in
                        editor.beginClipMove(id: clip.id, anchorTime: anchorTime)
                    },
                    onMoveChanged: { translation in
                        editor.updateClipMove(id: clip.id, by: translation)
                    },
                    onEndMove: { editor.endClipMove(id: clip.id) },
                    onBeginTrim: { edge in editor.beginClipTrim(id: clip.id, edge: edge) },
                    onTrimChanged: { edge, translation in
                        editor.updateClipTrim(id: clip.id, edge: edge, by: translation)
                    },
                    onEndTrim: { edge in editor.endClipTrim(id: clip.id, edge: edge) }
                )
                .frame(width: max(clip.duration * editor.pixelsPerSecond, 18), height: laneHeight - 12)
                .offset(x: clip.timelineStart * editor.pixelsPerSecond)
            }
        }
        .frame(width: trackWidth, alignment: .leading)
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Save", systemImage: "square.and.arrow.down") {
                do { try editor.save() } catch { exportError = error.localizedDescription }
            }
            .disabled(!editor.hasProject)

            Button("Export", systemImage: "square.and.arrow.up") {
                do {
                    exportSource = try editor.makeExportSource()
                } catch {
                    exportError = error.localizedDescription
                }
            }
            .disabled(!editor.hasProject || editor.isRebuilding)
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

    private func timecode(
        _ time: TimeInterval,
        includeHours: Bool = true,
        includeFrames: Bool = false
    ) -> String {
        let safeTime = max(0, time)
        let totalSeconds = Int(safeTime.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        let base: String
        if includeHours || hours > 0 {
            base = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            base = String(format: "%02d:%02d", minutes, seconds)
        }
        guard includeFrames else { return base }
        let frames = min(Int((safeTime - floor(safeTime)) * 30), 29)
        return String(format: "%@:%02d", base, frames)
    }
}

private struct TimelineGapView: View {
    let gap: TimelineGapSegment
    let pixelsPerSecond: Double
    let isSelected: Bool
    let onSelect: (TimeInterval) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Image(systemName: gap.fillMode.systemImage)
                Text(gap.fillMode.title)
                    .lineLimit(1)
            }
            Image(systemName: gap.fillMode.systemImage)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(gapBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor : Color.white.opacity(0.14),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in
                select(at: value.location.x)
            }
        )
        .highPriorityGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in select(at: value.location.x) }
        )
        .reccyTooltip("Empty video space • Click to select • Drag to scrub")
        .accessibilityLabel(
            "\(gap.fillMode.title) video gap, \(gap.duration.formatted(.number.precision(.fractionLength(1)))) seconds"
        )
    }

    private var gapBackground: some ShapeStyle {
        switch gap.fillMode {
        case .black:
            AnyShapeStyle(Color.black)
        case .holdPrevious:
            AnyShapeStyle(Color(nsColor: .darkGray).gradient)
        case .holdNext:
            AnyShapeStyle(Color(nsColor: .gray).opacity(0.72).gradient)
        }
    }

    private func select(at localX: CGFloat) {
        let localTime = min(max(localX / pixelsPerSecond, 0), gap.duration)
        onSelect(gap.timelineStart + localTime)
    }
}

private struct TimelineClipView: View {
    let clip: TimelineClip
    let lane: TimelineLane
    let pixelsPerSecond: Double
    let isSelected: Bool
    let color: Color
    let onSelect: (TimeInterval) -> Void
    let onBeginMove: (TimeInterval) -> Void
    let onMoveChanged: (TimeInterval) -> Void
    let onEndMove: () -> Void
    let onBeginTrim: (TimelineTrimEdge) -> Void
    let onTrimChanged: (TimelineTrimEdge, TimeInterval) -> Void
    let onEndTrim: (TimelineTrimEdge) -> Void

    @State private var isMoving = false
    @State private var trimmingEdge: TimelineTrimEdge?

    var body: some View {
        ZStack(alignment: .leading) {
            if lane.kind != .video {
                ReccyAssetWaveform(
                    sourceURL: clip.sourceURL,
                    sourceTrackID: clip.sourceTrackID,
                    sourceStart: clip.sourceStart,
                    duration: clip.duration,
                    color: .white
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .opacity(0.72)
                .allowsHitTesting(false)
            }

            HStack(spacing: 7) {
                Image(systemName: lane.kind.systemImage)
                Text(clip.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .shadow(color: .black.opacity(lane.kind == .video ? 0 : 0.45), radius: 2)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.gradient)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? Color.white : Color.white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: isSelected ? color.opacity(0.45) : .clear, radius: 5)
        .contentShape(Rectangle())
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in
                let localTime = min(max(value.location.x / pixelsPerSecond, 0), clip.duration)
                onSelect(clip.timelineStart + localTime)
            }
        )
        .highPriorityGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("timelineCanvas"))
                .onChanged { value in
                    guard trimmingEdge == nil else { return }
                    if !isMoving {
                        isMoving = true
                        let localX = value.startLocation.x - clip.timelineStart * pixelsPerSecond
                        onBeginMove(min(max(localX / pixelsPerSecond, 0), clip.duration))
                    }
                    onMoveChanged(value.translation.width / pixelsPerSecond)
                }
                .onEnded { value in
                    guard isMoving else { return }
                    onMoveChanged(value.translation.width / pixelsPerSecond)
                    onEndMove()
                    isMoving = false
                }
        )
        .overlay {
            HStack(spacing: 0) {
                trimHandle(edge: .leading)
                Spacer(minLength: 0)
                trimHandle(edge: .trailing)
            }
        }
        .reccyTooltip("Click to seek • Drag the body to move • Drag either edge to trim")
        .accessibilityLabel("\(clip.name), \(clip.duration.formatted(.number.precision(.fractionLength(1)))) seconds")
    }

    private func trimHandle(edge: TimelineTrimEdge) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 11)
            .contentShape(Rectangle())
            .overlay(alignment: edge == .leading ? .leading : .trailing) {
                Capsule()
                    .fill(isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.35))
                    .frame(width: isSelected ? 3 : 2, height: 28)
                    .padding(edge == .leading ? .leading : .trailing, 3)
            }
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineCanvas"))
                    .onChanged { value in
                        guard !isMoving else { return }
                        if trimmingEdge == nil {
                            trimmingEdge = edge
                            onBeginTrim(edge)
                        }
                        guard trimmingEdge == edge else { return }
                        onTrimChanged(edge, value.translation.width / pixelsPerSecond)
                    }
                    .onEnded { value in
                        guard trimmingEdge == edge else { return }
                        onTrimChanged(edge, value.translation.width / pixelsPerSecond)
                        onEndTrim(edge)
                        trimmingEdge = nil
                    }
            )
            .reccyTooltip(edge == .leading ? "Trim clip in-point" : "Trim clip out-point")
    }
}

private struct TimelinePlayhead: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "triangle.fill")
                .font(.system(size: 9))
                .rotationEffect(.degrees(180))
            Rectangle()
                .frame(width: 1.5)
        }
        .foregroundStyle(.red)
        .frame(width: 11)
    }
}

/// The editor owns transport and seeking, so AVPlayerView provides only the
/// native Metal-backed video surface. This prevents a second hover scrubber
/// from competing with the project timeline.
private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.showsFrameSteppingButtons = false
        playerView.showsFullScreenToggleButton = false
        playerView.updatesNowPlayingInfoCenter = false
        playerView.allowsVideoFrameAnalysis = false
        playerView.preferredDisplayDynamicRange = .automatic
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        if playerView.player !== player {
            playerView.player = player
        }
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Void) {
        playerView.player = nil
    }
}

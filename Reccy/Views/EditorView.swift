import AVKit
import Combine
import AppKit
import SwiftUI

struct EditorView: View {
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var coordinator: CaptureCoordinator
    @EnvironmentObject private var editor: TimelineEditorController
    @EnvironmentObject private var transcription: TranscriptionController
    @EnvironmentObject private var navigation: AppNavigationModel
    @State private var exportSource: ExportSource?
    @State private var exportError: String?
    @State private var showsTranscript = false
    @State private var inspectorMode = EditorInspectorMode.transcript
    @State private var transcriptSearch = ""
    @State private var transcriptCorrection: ProjectedTranscriptSegment?
    @State private var confirmsCaptionReplacement = false
    @State private var showsVoiceoverInputPopover = false
    @State private var playbackSyncTask: Task<Void, Never>?

    private let trackHeaderWidth: CGFloat = 176
    private let rulerHeight: CGFloat = 32
    private let laneHeight: CGFloat = 68
    private let timelineToolbarControlSize: CGFloat = 34

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
                    description: "Choose Edit in the Library to create a non-destructive project.",
                    actionTitle: "Open Library"
                ) {
                    navigation.section = .library
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Editor")
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItemGroup(placement: .primaryAction) {
                exportToolbarButton
            }
        }
        .sheet(item: $exportSource) { source in
            ExportSheet(source: source)
        }
        .sheet(item: $transcriptCorrection) { segment in
            TranscriptCorrectionSheet(segment: segment) { text in
                transcription.correctSegment(
                    mediaURL: segment.mediaURL,
                    sourceTrackID: segment.sourceTrackID,
                    role: segment.role,
                    segmentID: segment.sourceSegmentID,
                    text: text
                )
            }
        }
        .onAppear {
            editor.connectUndoManager(undoManager)
            editor.refreshVoiceoverInputDevices()
            loadProjectTranscripts()
        }
        .onChange(of: editor.project) { _, _ in loadProjectTranscripts() }
        .onDisappear {
            playbackSyncTask?.cancel()
            playbackSyncTask = nil
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "Unknown error")
        }
        .alert(
            editor.canResetUnsupportedProject ? "Reset Editor Project?" : "Editor Couldn’t Apply Change",
            isPresented: Binding(
                get: { editor.errorMessage != nil },
                set: { if !$0 { editor.dismissError() } }
            )
        ) {
            if editor.canResetUnsupportedProject {
                Button("Reset Project", role: .destructive) {
                    Task { await editor.resetUnsupportedProject() }
                }
                Button("Cancel", role: .cancel) { editor.dismissError() }
            } else {
                Button("OK") { editor.dismissError() }
            }
        } message: {
            Text(editor.errorMessage ?? "Unknown error")
        }
    }

    private func editorWorkspace(_ project: TimelineProject) -> some View {
        Group {
            if showsTranscript {
                ReccySplitView(
                    axis: .horizontal,
                    autosaveName: "editor.workspace-inspector",
                    initialFraction: 0.72,
                    firstMinimum: 460,
                    secondMinimum: 280,
                    secondMaximum: 520,
                    firstPaneName: "editor workspace",
                    secondPaneName: "transcript inspector",
                    first: { editorCore(project) },
                    second: {
                        Group {
                            switch inspectorMode {
                            case .transcript:
                                transcriptPanel(project)
                            case .captions:
                                captionPanel(project)
                            }
                        }
                    }
                )
            } else {
                editorCore(project)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(editor.player.publisher(for: \.timeControlStatus)) { status in
            updatePlaybackSync(for: status)
        }
    }

    private func updatePlaybackSync(for status: AVPlayer.TimeControlStatus) {
        playbackSyncTask?.cancel()
        playbackSyncTask = nil
        guard status == .playing else { return }

        playbackSyncTask = Task { @MainActor in
            while !Task.isCancelled, editor.player.timeControlStatus == .playing {
                editor.syncPlayheadFromPlayer()
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    private func editorCore(_ project: TimelineProject) -> some View {
        ReccySplitView(
            axis: .vertical,
            autosaveName: "editor.preview-timeline",
            initialFraction: 0.56,
            firstMinimum: 250,
            secondMinimum: 285,
            firstPaneName: "video preview",
            secondPaneName: "timeline",
            first: { previewPane(project) },
            second: { timelinePane(project) }
        )
    }

    private func previewPane(_ project: TimelineProject) -> some View {
        VStack(spacing: 0) {
            ZStack {
                NativeVideoPlayer(player: editor.player)
                    .background(.black)

                if let cameraClip = editor.activeCameraClip,
                   editor.previewRenderSize.width > 0,
                   editor.previewRenderSize.height > 0
                {
                    CameraOverlayManipulator(
                        clip: cameraClip,
                        renderSize: editor.previewRenderSize,
                        isSelected: editor.selectedClipID == cameraClip.id,
                        onSelect: {
                            guard editor.selectedClipID != cameraClip.id else { return }
                            editor.select(cameraClip, at: editor.playhead)
                        },
                        onCommit: { layout in
                            editor.setVideoLayout(layout, clipID: cameraClip.id)
                        },
                        onReset: {
                            editor.resetVideoLayout(clipID: cameraClip.id)
                        }
                    )
                }

                if let captionTrack = project.captionTrack {
                    TimelineCaptionOverlay(
                        track: captionTrack,
                        time: editor.playhead,
                        renderSize: editor.previewRenderSize
                    )
                    .allowsHitTesting(false)
                    .zIndex(2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.separator.opacity(0.45), lineWidth: 0.5)
                    .allowsHitTesting(false)
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
            .reccyAccessibleControl(
                editor.isPlaying ? "Pause" : "Play",
                help: editor.isPlaying ? "Pause (Space)" : "Play (Space)"
            )
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
        .reccyAccessibleControl(help)
    }

    private func timelinePane(_ project: TimelineProject) -> some View {
        VStack(spacing: 0) {
            timelineToolbar
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

            mouseFollowZoomLaneHeader(project.mouseFollowZoomTrack)
                .frame(height: laneHeight)
            Divider()

            captionLaneHeader(project.captionTrack)
                .frame(height: laneHeight)
            Divider()

            Spacer(minLength: 0)
        }
        .background(.bar.opacity(0.72))
    }

    private func laneHeader(_ lane: TimelineLane) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: lane.kind.systemImage)
                    .foregroundStyle(laneColor(lane.kind))
                    .accessibilityHidden(true)
                Text(lane.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if lane.kind.isAudio {
                HStack(spacing: 7) {
                    Button {
                        editor.toggleMute(laneID: lane.id)
                    } label: {
                        Image(systemName: lane.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .frame(width: 16)
                    }
                    .buttonStyle(.borderless)
                    .reccyAccessibleControl(lane.isMuted ? "Unmute \(lane.name)" : "Mute \(lane.name)")

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

    private func captionLaneHeader(_ track: TimelineCaptionTrack?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(.indigo)
                    .accessibilityHidden(true)
                Text("Captions")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if let track {
                    Button {
                        editor.setCaptionsVisible(!track.isVisible)
                    } label: {
                        Image(systemName: track.isVisible ? "eye.fill" : "eye.slash.fill")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .reccyAccessibleControl(track.isVisible ? "Hide Captions" : "Show Captions")
                }

                Button {
                    addCaptionAtPlayhead()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .reccyAccessibleControl("Add Caption at Playhead")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
    }

    private func mouseFollowZoomLaneHeader(_ track: MouseFollowZoomTrack?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "cursorarrow.motionlines")
                    .foregroundStyle(.purple)
                    .accessibilityHidden(true)
                Text("Mouse Zoom")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button {
                    editor.addMouseFollowZoom(
                        at: editor.playhead,
                        zoomScale: coordinator.settings.mouseFollowZoomLevel.rawValue
                    )
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .reccyAccessibleControl("Add Mouse Zoom at Playhead")

                Text(track?.segments.isEmpty == false ? "Editable effects" : "No effects")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
    }

    private func timelineCanvas(_ project: TimelineProject) -> some View {
        let paddingDuration = max(4, 480 / max(editor.pixelsPerSecond, 1))
        let canvasDuration = max(project.duration + paddingDuration, 12)
        let trackWidth = canvasDuration * editor.pixelsPerSecond
        let canvasHeight = rulerHeight + CGFloat(project.lanes.count + 2) * (laneHeight + 1)

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ruler(width: trackWidth, duration: canvasDuration)

                ForEach(project.lanes) { lane in
                    laneRow(
                        lane,
                        videoGaps: lane.kind == .video ? project.videoGaps : [],
                        frameRate: project.frameRate,
                        trackWidth: trackWidth
                    )
                        .frame(height: laneHeight)
                    Divider()
                }

                mouseFollowZoomLaneRow(
                    project.mouseFollowZoomTrack,
                    trackWidth: trackWidth
                )
                .frame(height: laneHeight)
                Divider()

                captionLaneRow(
                    project.captionTrack,
                    projectDuration: project.duration,
                    frameRate: project.frameRate,
                    trackWidth: trackWidth
                )
                .frame(height: laneHeight)
                Divider()
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

    private func mouseFollowZoomLaneRow(
        _ track: MouseFollowZoomTrack?,
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

            if track?.segments.isEmpty != false {
                Text("Toggle during recording or add an effect at the playhead")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .allowsHitTesting(false)
            }

            ForEach(track?.segments ?? []) { segment in
                TimelineMouseFollowZoomSegmentView(
                    segment: segment,
                    pixelsPerSecond: editor.pixelsPerSecond,
                    frameRate: editor.project?.frameRate ?? 30,
                    isSelected: editor.selectedMouseFollowZoomSegmentID == segment.id,
                    onSelect: { time in editor.select(segment, at: time) },
                    onTrim: { edge, time in
                        editor.trimMouseFollowZoomSegment(id: segment.id, edge: edge, to: time)
                    },
                    onNudgeTrim: { edge, frames in
                        editor.nudgeMouseFollowZoomBoundary(
                            id: segment.id,
                            edge: edge,
                            byFrames: frames
                        )
                    },
                    onDelete: {
                        editor.select(segment)
                        editor.deleteSelection()
                    }
                )
                .frame(
                    width: max(segment.duration * editor.pixelsPerSecond, 18),
                    height: laneHeight - 12
                )
                .offset(x: segment.timelineStart * editor.pixelsPerSecond)
            }
        }
        .frame(width: trackWidth, alignment: .leading)
    }

    private func captionLaneRow(
        _ track: TimelineCaptionTrack?,
        projectDuration: TimeInterval,
        frameRate: Double,
        trackWidth: Double
    ) -> some View {
        let cues = track?.presentationCues(through: projectDuration) ?? []

        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineCanvas"))
                        .onChanged { value in
                            editor.seek(to: value.location.x / editor.pixelsPerSecond)
                        }
                )

            if cues.isEmpty {
                Text("Add a caption at the playhead")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .allowsHitTesting(false)
            }

            ForEach(cues) { cue in
                TimelineCaptionCueView(
                    cue: cue,
                    pixelsPerSecond: editor.pixelsPerSecond,
                    frameRate: frameRate,
                    isSelected: editor.selectedCaptionID == cue.id,
                    isVisible: track?.isVisible == true,
                    onSelect: {
                        editor.selectCaption(cue)
                        inspectorMode = .captions
                        showsTranscript = true
                    },
                    onMove: { start in editor.moveCaption(cue.id, to: start) },
                    onNudge: { frames in editor.nudgeCaption(cue.id, byFrames: frames) },
                    onDelete: { editor.deleteCaption(cue.id) }
                )
                .frame(width: max(cue.duration * editor.pixelsPerSecond, 18), height: laneHeight - 12)
                .offset(x: cue.timelineStart * editor.pixelsPerSecond)
            }
        }
        .frame(width: trackWidth, alignment: .leading)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline ruler")
        .accessibilityValue(timecode(editor.playhead, includeFrames: true))
        .accessibilityHint("Adjust to seek by one second")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: editor.seekBy(1)
            case .decrement: editor.seekBy(-1)
            @unknown default: break
            }
        }
    }

    private var rulerInterval: TimeInterval {
        if editor.pixelsPerSecond >= 150 { return 1 }
        if editor.pixelsPerSecond >= 70 { return 2 }
        return 5
    }

    private func laneRow(
        _ lane: TimelineLane,
        videoGaps: [TimelineGapSegment],
        frameRate: Double,
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
                    onSelect: { time in editor.select(gap, at: time) },
                    onSetFillMode: { mode in
                        editor.select(gap)
                        editor.setSelectedGapFillMode(mode)
                    }
                )
                .frame(width: max(gap.duration * editor.pixelsPerSecond, 18), height: laneHeight - 12)
                .offset(x: gap.timelineStart * editor.pixelsPerSecond)
            }

            ForEach(lane.clips) { clip in
                TimelineClipView(
                    clip: clip,
                    lane: lane,
                    pixelsPerSecond: editor.pixelsPerSecond,
                    frameRate: frameRate,
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
                    onEndTrim: { edge in editor.endClipTrim(id: clip.id, edge: edge) },
                    onNudge: { frames in editor.nudgeClip(id: clip.id, byFrames: frames) },
                    onNudgeTrim: { edge, frames in
                        editor.nudgeClipTrim(id: clip.id, edge: edge, byFrames: frames)
                    }
                )
                .frame(width: max(clip.duration * editor.pixelsPerSecond, 18), height: laneHeight - 12)
                .offset(x: clip.timelineStart * editor.pixelsPerSecond)
            }
        }
        .frame(width: trackWidth, alignment: .leading)
    }

    private var timelineToolbar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    timelineToolbarButton(
                        "Split Clip",
                        systemImage: "scissors",
                        help: "Split the selected clip at the playhead (⌘B)"
                    ) {
                        editor.splitSelectionAtPlayhead()
                    }
                    .disabled(!editor.canSplitSelection)
                    .keyboardShortcut("b", modifiers: .command)

                    timelineToolbarButton(
                        "Split All Tracks",
                        systemImage: "timeline.selection",
                        help: "Split every track at the playhead (⇧⌘B)"
                    ) {
                        editor.splitAllAtPlayhead()
                    }
                    .disabled(!editor.canSplitAll)
                    .keyboardShortcut("b", modifiers: [.command, .shift])

                    timelineToolbarButton(
                        "Delete Selection",
                        systemImage: "trash",
                        help: "Delete the selected clip or effect",
                        tint: .red
                    ) {
                        editor.deleteSelection()
                    }
                    .disabled(
                        editor.selectedClipID == nil
                            && editor.selectedMouseFollowZoomSegmentID == nil
                    )
                    .keyboardShortcut(.delete, modifiers: [])

                    timelineToolbarButton(
                        "Close Gap",
                        systemImage: "arrow.left.and.right",
                        help: "Delete the selected clip and close its gap"
                    ) {
                        editor.rippleDeleteSelection()
                    }
                    .disabled(editor.selectedClipID == nil)
                    .keyboardShortcut(.delete, modifiers: .command)

                    if editor.selectedClipIsCamera, let selectedClipID = editor.selectedClipID {
                        timelineToolbarButton(
                            "Reset Camera Position",
                            systemImage: "arrow.counterclockwise",
                            help: "Reset camera position and size"
                        ) {
                            editor.resetVideoLayout(clipID: selectedClipID)
                        }
                    }

                    if let segment = editor.selectedMouseFollowZoomSegment {
                        Menu {
                            ForEach(MouseFollowZoomLevel.allCases) { level in
                                Button {
                                    editor.setMouseFollowZoomScale(
                                        level.rawValue,
                                        segmentID: segment.id
                                    )
                                } label: {
                                    if abs(segment.zoomScale - level.rawValue) < 0.001 {
                                        Label(level.title, systemImage: "checkmark")
                                    } else {
                                        Text(level.title)
                                    }
                                }
                            }
                        } label: {
                            Label(
                                "Zoom \(MouseFollowZoomScale.title(segment.zoomScale))",
                                systemImage: "plus.magnifyingglass"
                            )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Mouse zoom level")
                    }

                    Divider().frame(height: 20)

                    linkedClipsButton
                    ForEach(TimelineGapFillMode.allCases) { mode in
                        gapFillButton(mode)
                    }

                    Divider().frame(height: 20)

                    voiceoverInputMenu
                    voiceoverButton

                    Divider().frame(height: 20)

                    inspectorButton(.transcript, title: "Transcript", systemImage: "captions.bubble")
                    inspectorButton(.captions, title: "Captions", systemImage: "captions.bubble.fill")
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                Divider().frame(height: 20)

                Button {
                    editor.pixelsPerSecond = max(30, editor.pixelsPerSecond - 20)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .frame(width: 24, height: 24)
                .disabled(editor.pixelsPerSecond <= 30)
                .reccyAccessibleControl("Zoom Out")
                .reccyTooltip("Zoom out of the timeline")

                Slider(value: $editor.pixelsPerSecond, in: 30...220)
                    .frame(width: 96)
                    .accessibilityLabel("Timeline zoom")

                Button {
                    editor.pixelsPerSecond = min(220, editor.pixelsPerSecond + 20)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .frame(width: 24, height: 24)
                .disabled(editor.pixelsPerSecond >= 220)
                .reccyAccessibleControl("Zoom In")
                .reccyTooltip("Zoom in to the timeline")
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func timelineToolbarButton(
        _ title: String,
        systemImage: String,
        help: String,
        tint: Color? = nil,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(width: timelineToolbarControlSize, height: timelineToolbarControlSize)
        .tint(tint)
        .reccyAccessibleControl(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .reccyTooltip(help)
    }

    private var linkedClipsButton: some View {
        timelineToolbarButton(
            "Move linked audio and video",
            systemImage: editor.moveLinkedClips ? "link" : "link.badge.plus",
            help: editor.moveLinkedClips
                ? "Linked movement is on — video and matching audio move or trim together"
                : "Independent movement is on — each audio or video clip moves and trims separately",
            tint: editor.moveLinkedClips ? .accentColor : nil,
            isSelected: editor.moveLinkedClips
        ) {
            editor.moveLinkedClips.toggle()
        }
    }

    private func gapFillButton(_ mode: TimelineGapFillMode) -> some View {
        timelineToolbarButton(
            mode.title,
            systemImage: mode.systemImage,
            help: "\(mode.title). \(gapFillHelp)",
            tint: editor.selectedGapFillMode == mode ? .accentColor : nil,
            isSelected: editor.selectedGapID != nil && editor.selectedGapFillMode == mode
        ) {
            editor.setSelectedGapFillMode(mode)
        }
        .disabled(editor.selectedGapID == nil)
    }

    private var gapFillHelp: String {
        editor.selectedGapID == nil
            ? "Select a video gap to choose how it renders"
            : "Render this gap as black, the previous frame, or the next frame"
    }

    private var voiceoverInputMenu: some View {
        timelineToolbarButton(
            "Voiceover Input",
            systemImage: "mic.badge.plus",
            help: "Voiceover input: \(editor.selectedVoiceoverInputName)"
        ) {
            showsVoiceoverInputPopover.toggle()
        }
        .disabled(editor.isVoiceoverRecording)
        .popover(isPresented: $showsVoiceoverInputPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Voiceover Input", systemImage: "mic")
                    .font(.headline)

                Picker(
                    "Input",
                    selection: Binding(
                        get: { editor.selectedVoiceoverInputID },
                        set: { editor.selectedVoiceoverInputID = $0 }
                    )
                ) {
                    Text("System Default").tag(String?.none)
                    ForEach(editor.voiceoverInputDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            .padding(16)
            .frame(width: 280, alignment: .leading)
        }
    }

    private var voiceoverButton: some View {
        timelineToolbarButton(
            editor.isVoiceoverRecording ? "Stop Voiceover" : "Record Voiceover",
            systemImage: editor.isVoiceoverRecording ? "stop.fill" : "mic.fill",
            help: "Record a new, independently editable audio clip at the playhead",
            tint: editor.isVoiceoverRecording ? .red : nil
        ) {
            editor.toggleVoiceover()
        }
    }

    private func inspectorButton(
        _ mode: EditorInspectorMode,
        title: String,
        systemImage: String
    ) -> some View {
        timelineToolbarButton(
            title,
            systemImage: systemImage,
            help: "Show or hide the \(title.lowercased()) panel",
            tint: showsTranscript && inspectorMode == mode ? .accentColor : nil,
            isSelected: showsTranscript && inspectorMode == mode
        ) {
            toggleInspector(mode)
        }
    }

    private var exportToolbarButton: some View {
        Button {
            do {
                exportSource = try editor.makeExportSource()
            } catch {
                exportError = error.localizedDescription
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
        }
        .disabled(!editor.hasProject || editor.isRebuilding)
        .reccyAccessibleControl("Export")
        .reccyTooltip("Export the current project")
    }

    private func captionPanel(_ project: TimelineProject) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Captions", systemImage: "captions.bubble.fill")
                    .font(.headline)
                Spacer()
                Button {
                    showsTranscript = false
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .reccyAccessibleControl("Close Captions")
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(.bar)

            Divider()

            if let track = project.captionTrack {
                HStack(spacing: 10) {
                    Toggle("Show", isOn: Binding(
                        get: { track.isVisible },
                        set: { editor.setCaptionsVisible($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Spacer()

                    Menu(track.style.placement.title) {
                        ForEach(TimelineCaptionPlacement.allCases) { placement in
                            Button(placement.title) { editor.setCaptionPlacement(placement) }
                        }
                    }
                    .menuStyle(.borderlessButton)

                    Menu(track.style.size.title) {
                        ForEach(TimelineCaptionSize.allCases) { size in
                            Button(size.title) { editor.setCaptionSize(size) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(track.cues) { cue in
                                CaptionCueEditorRow(
                                    cue: cue,
                                    isSelected: editor.selectedCaptionID == cue.id,
                                    timecode: timecode(cue.timelineStart, includeHours: false),
                                    onSelect: { editor.selectCaption(cue) },
                                    onSave: { editor.updateCaptionText($0, cueID: cue.id) },
                                    onDelete: { editor.deleteCaption(cue.id) }
                                )
                                .id(cue.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: editor.selectedCaptionID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Button("Add Caption", systemImage: "plus") {
                        addCaptionAtPlayhead()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Regenerate", systemImage: "arrow.triangle.2.circlepath") {
                        confirmsCaptionReplacement = true
                    }
                    .disabled(projectedTranscriptSegments.isEmpty)

                    Spacer()
                    Text("\(track.cues.count) cues")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.bar)
                .confirmationDialog(
                    "Replace edited captions?",
                    isPresented: $confirmsCaptionReplacement,
                    titleVisibility: .visible
                ) {
                    Button("Replace Captions", role: .destructive) {
                        installTranscriptCaptions(project)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This rebuilds the caption track from the latest corrected transcript.")
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("Add captions to the video")
                        .font(.headline)
                    Text("Create readable timed cues from the transcript, then correct or add any wording you need.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if projectedTranscriptSegments.isEmpty {
                        Button("Transcribe Sources", systemImage: "waveform.badge.magnifyingglass") {
                            transcription.transcribeMissingSources(in: project)
                            inspectorMode = .transcript
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Add Transcript Captions", systemImage: "text.badge.plus") {
                            installTranscriptCaptions(project)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button("Add Manually", systemImage: "plus") {
                        addCaptionAtPlayhead()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func transcriptPanel(_ project: TimelineProject) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Transcript", systemImage: "captions.bubble.fill")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(TranscriptExportFormat.allCases) { format in
                        Button(format.title) { exportProjectTranscript(project, format: format) }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .disabled(projectedTranscriptSegments.isEmpty)
                .reccyAccessibleControl("Export Transcript or Captions")

                Button {
                    showsTranscript = false
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .reccyAccessibleControl("Close Transcript")
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(.bar)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcript", text: $transcriptSearch)
                    .textFieldStyle(.plain)
                if !transcriptSearch.isEmpty {
                    Button {
                        transcriptSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .reccyAccessibleControl("Clear Transcript Search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)

            Divider()

            if projectedTranscriptSegments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No project transcript")
                        .font(.headline)
                    Text("Transcribe each source track without changing the timeline or media.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Transcribe Sources") {
                        transcription.transcribeMissingSources(in: project)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(filteredProjectedTranscript) { segment in
                                HStack(alignment: .top, spacing: 4) {
                                    Button {
                                        editor.seek(to: segment.timelineStart)
                                    } label: {
                                    HStack(alignment: .top, spacing: 9) {
                                        Text(timecode(segment.timelineStart, includeHours: false))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 40, alignment: .trailing)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(segment.role.title)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(laneColor(segment.role.timelineLaneKind))
                                            Text(segment.text)
                                                .font(.callout)
                                                .foregroundStyle(.primary)
                                                .multilineTextAlignment(.leading)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        segment.timelineStart <= editor.playhead && editor.playhead < segment.timelineEnd
                                            ? Color.accentColor.opacity(0.08)
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7)
                                    )
                                    .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(
                                        "Play transcript from \(timecode(segment.timelineStart)): \(segment.text)"
                                    )
                                    .accessibilityHint("Seek the editor to this transcript segment")

                                    Button {
                                        transcriptCorrection = segment
                                    } label: {
                                        Image(systemName: "pencil")
                                            .frame(width: 18, height: 18)
                                    }
                                    .buttonStyle(.borderless)
                                    .reccyAccessibleControl(
                                        "Correct \(segment.role.title) transcript at \(timecode(segment.timelineStart))"
                                    )
                                    .padding(.top, 8)
                                }
                                .id(segment.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: activeTranscriptSegmentID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var projectedTranscriptSegments: [ProjectedTranscriptSegment] {
        guard let project = editor.project else { return [] }
        let urls = Set(project.lanes.flatMap(\.clips).map(\.sourceURL))
        let documents = Dictionary(uniqueKeysWithValues: urls.compactMap { url in
            transcription.document(for: url).map { (url, $0) }
        })
        return TranscriptProjection.project(project: project, documentsByMediaURL: documents)
    }

    private var filteredProjectedTranscript: [ProjectedTranscriptSegment] {
        let query = transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projectedTranscriptSegments }
        return projectedTranscriptSegments.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var activeTranscriptSegmentID: String? {
        projectedTranscriptSegments.first {
            $0.timelineStart <= editor.playhead && editor.playhead < $0.timelineEnd
        }?.id
    }

    private func loadProjectTranscripts() {
        guard let project = editor.project else { return }
        for url in Set(project.lanes.flatMap(\.clips).map(\.sourceURL)) {
            transcription.loadDocument(for: url)
        }
    }

    private func exportProjectTranscript(_ project: TimelineProject, format: TranscriptExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Export Project Transcript"
        panel.nameFieldStringValue = "\(project.name).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TranscriptExportFormatter.string(segments: projectedTranscriptSegments, format: format)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func toggleInspector(_ mode: EditorInspectorMode) {
        if showsTranscript, inspectorMode == mode {
            showsTranscript = false
        } else {
            inspectorMode = mode
            showsTranscript = true
        }
    }

    private func installTranscriptCaptions(_ project: TimelineProject) {
        let cues = TimelineCaptionCueGenerator.cues(
            from: projectedTranscriptSegments,
            projectDuration: project.duration
        )
        editor.replaceCaptions(with: cues)
    }

    private func addCaptionAtPlayhead() {
        guard editor.addCaption(at: editor.playhead) != nil else { return }
        inspectorMode = .captions
        showsTranscript = true
    }

    private func laneColor(_ kind: TimelineLaneKind) -> Color {
        switch kind {
        case .video: .indigo
        case .camera: .blue
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
        let frameRate = max(editor.project?.frameRate ?? 30, 1)
        let frames = min(Int((safeTime - floor(safeTime)) * frameRate), Int(frameRate) - 1)
        return String(format: "%@:%02d", base, frames)
    }
}

private enum EditorInspectorMode {
    case transcript
    case captions
}

private struct TranscriptCorrectionSheet: View {
    let segment: ProjectedTranscriptSegment
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(segment: ProjectedTranscriptSegment, onSave: @escaping (String) -> Void) {
        self.segment = segment
        self.onSave = onSave
        _text = State(initialValue: segment.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Correct Transcript", systemImage: "pencil.and.outline")
                .font(.title2.weight(.semibold))
            Text("This updates the source transcript. Regenerate captions to apply the correction to an existing caption track.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 100)

            HStack {
                Text(segment.role.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

private struct CaptionCueEditorRow: View {
    let cue: TimelineCaptionCue
    let isSelected: Bool
    let timecode: String
    let onSelect: () -> Void
    let onSave: (String) -> Void
    let onDelete: () -> Void

    @State private var draft: String
    @FocusState private var isEditing: Bool

    init(
        cue: TimelineCaptionCue,
        isSelected: Bool,
        timecode: String,
        onSelect: @escaping () -> Void,
        onSave: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.cue = cue
        self.isSelected = isSelected
        self.timecode = timecode
        self.onSelect = onSelect
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: cue.text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSelect) {
                Text(timecode)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .buttonStyle(.plain)

            TextField("Caption text", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .focused($isEditing)
                .onSubmit { commit() }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .reccyAccessibleControl("Delete caption")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .onChange(of: isEditing) { wasEditing, isEditing in
            if wasEditing && !isEditing { commit() }
        }
        .onChange(of: cue.text) { _, text in
            guard !isEditing else { return }
            draft = text
        }
    }

    private func commit() {
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            draft = cue.text
            return
        }
        draft = normalized
        if normalized != cue.text { onSave(normalized) }
    }
}

private struct TimelineGapView: View {
    let gap: TimelineGapSegment
    let pixelsPerSecond: Double
    let isSelected: Bool
    let onSelect: (TimeInterval) -> Void
    let onSetFillMode: (TimelineGapFillMode) -> Void

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(gap.fillMode.title) video gap, \(accessibilityDuration) seconds"
        )
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Activate to select this gap, then choose its fill mode in the editor toolbar")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect(gap.timelineStart) }
        .accessibilityAction(named: "Fill with Black") { onSetFillMode(.black) }
        .accessibilityAction(named: "Hold Previous Frame") { onSetFillMode(.holdPrevious) }
        .accessibilityAction(named: "Hold Next Frame") { onSetFillMode(.holdNext) }
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

    private var accessibilityDuration: String {
        gap.duration.formatted(
            .number.precision(.fractionLength(gap.duration < 1 ? 2 : 1))
        )
    }
}

private struct TimelineMouseFollowZoomSegmentView: View {
    let segment: MouseFollowZoomSegment
    let pixelsPerSecond: Double
    let frameRate: Double
    let isSelected: Bool
    let onSelect: (TimeInterval) -> Void
    let onTrim: (TimelineTrimEdge, TimeInterval) -> Void
    let onNudgeTrim: (TimelineTrimEdge, Int) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "cursorarrow.motionlines")
            Text("\(zoomTitle) Mouse Follow")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.purple.gradient)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isSelected ? Color.white : Color.white.opacity(0.16),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: isSelected ? Color.purple.opacity(0.5) : .clear, radius: 5)
        .contentShape(Rectangle())
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in
                let localTime = min(max(value.location.x / pixelsPerSecond, 0), segment.duration)
                onSelect(segment.timelineStart + localTime)
            }
        )
        .overlay {
            HStack(spacing: 0) {
                trimHandle(.leading)
                Spacer(minLength: 0)
                trimHandle(.trailing)
            }
        }
        .reccyTooltip("Click to seek • Drag either edge to resize the zoom effect")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mouse-follow zoom effect")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Activate to select. Additional actions resize or delete this effect.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect(segment.timelineStart) }
        .accessibilityAction(named: "Move Start Earlier by One Frame") {
            onNudgeTrim(.leading, -1)
        }
        .accessibilityAction(named: "Move Start Later by One Frame") {
            onNudgeTrim(.leading, 1)
        }
        .accessibilityAction(named: "Move End Earlier by One Frame") {
            onNudgeTrim(.trailing, -1)
        }
        .accessibilityAction(named: "Move End Later by One Frame") {
            onNudgeTrim(.trailing, 1)
        }
        .accessibilityAction(named: "Delete Mouse Zoom", onDelete)
    }

    private func trimHandle(_ edge: TimelineTrimEdge) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 12)
            .contentShape(Rectangle())
            .overlay(alignment: edge == .leading ? .leading : .trailing) {
                Capsule()
                    .fill(isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.4))
                    .frame(width: isSelected ? 3 : 2, height: 28)
                    .padding(edge == .leading ? .leading : .trailing, 3)
            }
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineCanvas"))
                    .onEnded { value in
                        let original = edge == .leading
                            ? segment.timelineStart
                            : segment.timelineEnd
                        onTrim(edge, original + value.translation.width / pixelsPerSecond)
                    }
            )
    }

    private var zoomTitle: String {
        MouseFollowZoomScale.title(segment.zoomScale)
    }

    private var accessibilityValue: String {
        let selection = isSelected ? "Selected" : "Not selected"
        let duration = segment.duration.formatted(.number.precision(.fractionLength(1)))
        return "\(selection), \(zoomTitle), starts at \(timecode), \(duration) seconds"
    }

    private var timecode: String {
        let safeTime = max(0, segment.timelineStart)
        let seconds = Int(safeTime.rounded(.down))
        let safeFrameRate = max(frameRate, 1)
        let frames = min(
            Int((safeTime - floor(safeTime)) * safeFrameRate),
            Int(safeFrameRate) - 1
        )
        return String(
            format: "%02d:%02d:%02d:%02d",
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60,
            frames
        )
    }
}

private struct TimelineClipView: View {
    let clip: TimelineClip
    let lane: TimelineLane
    let pixelsPerSecond: Double
    let frameRate: Double
    let isSelected: Bool
    let color: Color
    let onSelect: (TimeInterval) -> Void
    let onBeginMove: (TimeInterval) -> Void
    let onMoveChanged: (TimeInterval) -> Void
    let onEndMove: () -> Void
    let onBeginTrim: (TimelineTrimEdge) -> Void
    let onTrimChanged: (TimelineTrimEdge, TimeInterval) -> Void
    let onEndTrim: (TimelineTrimEdge) -> Void
    let onNudge: (Int) -> Void
    let onNudgeTrim: (TimelineTrimEdge, Int) -> Void

    @State private var isMoving = false
    @State private var trimmingEdge: TimelineTrimEdge?

    var body: some View {
        ZStack(alignment: .leading) {
            if lane.kind.isAudio {
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
            .shadow(color: .black.opacity(lane.kind.isVideo ? 0 : 0.45), radius: 2)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lane.name) clip, \(clip.name)")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Activate to select. Additional actions move or trim by one frame.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect(clip.timelineStart) }
        .accessibilityAction(named: "Move Earlier by One Frame") { onNudge(-1) }
        .accessibilityAction(named: "Move Later by One Frame") { onNudge(1) }
        .accessibilityAction(named: "Trim Start Later by One Frame") {
            onNudgeTrim(.leading, 1)
        }
        .accessibilityAction(named: "Trim End Earlier by One Frame") {
            onNudgeTrim(.trailing, -1)
        }
    }

    private var accessibilityValue: String {
        let selection = isSelected ? "Selected" : "Not selected"
        let duration = clip.duration.formatted(.number.precision(.fractionLength(1)))
        return "\(selection), starts at \(accessibilityTimecode), \(duration) seconds"
    }

    private var accessibilityTimecode: String {
        let safeTime = max(0, clip.timelineStart)
        let seconds = Int(safeTime.rounded(.down))
        let safeFrameRate = max(frameRate, 1)
        let frames = min(
            Int((safeTime - floor(safeTime)) * safeFrameRate),
            Int(safeFrameRate) - 1
        )
        return String(
            format: "%02d:%02d:%02d:%02d",
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60,
            frames
        )
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
        .accessibilityHidden(true)
    }
}

/// Direct manipulation for the active camera clip. The outline updates at
/// pointer rate while AVFoundation rebuilds once on commit, keeping editing
/// responsive without asking the compositor to reconstruct on every mouse event.
private struct CameraOverlayManipulator: View {
    let clip: TimelineClip
    let renderSize: CGSize
    let isSelected: Bool
    let onSelect: () -> Void
    let onCommit: (TimelineVideoLayout) -> Void
    let onReset: () -> Void

    @State private var draftLayout: TimelineVideoLayout?
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geometry in
            let videoRect = timelineAspectFitRect(content: renderSize, in: geometry.size)
            let layout = (draftLayout ?? clip.videoLayout ?? .defaultCamera).clamped()
            let overlayRect = CGRect(
                x: videoRect.minX + CGFloat(layout.x) * videoRect.width,
                y: videoRect.minY + CGFloat(layout.y) * videoRect.height,
                width: CGFloat(layout.width) * videoRect.width,
                height: CGFloat(layout.height) * videoRect.height
            )

            ZStack(alignment: .topLeading) {
                overlayControl(layout: layout, overlayRect: overlayRect, videoRect: videoRect)

                if isSelected || isHovering {
                    resizeHandle(overlayRect: overlayRect, videoRect: videoRect)
                }
            }
        }
    }

    private func overlayControl(
        layout: TimelineVideoLayout,
        overlayRect: CGRect,
        videoRect: CGRect
    ) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.clear)
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected || isHovering ? Color.accentColor : .white.opacity(0.45),
                        style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isSelected ? [] : [5, 4])
                    )
            }
            .frame(width: overlayRect.width, height: overlayRect.height)
            .offset(x: overlayRect.minX, y: overlayRect.minY)
            .onHover { isHovering = $0 }
            .simultaneousGesture(TapGesture().onEnded(onSelect))
            .gesture(moveGesture(videoRect: videoRect))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Camera overlay")
            .accessibilityValue(accessibilityValue(for: layout))
            .accessibilityHint("Activate to select. Additional actions move, resize, or reset the camera video.")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onSelect() }
            .accessibilityActions {
                Button("Move Left") {
                    commitAccessibilityLayout { $0.movedBy(x: -0.02, y: 0) }
                }
                Button("Move Right") {
                    commitAccessibilityLayout { $0.movedBy(x: 0.02, y: 0) }
                }
                Button("Move Up") {
                    commitAccessibilityLayout { $0.movedBy(x: 0, y: -0.02) }
                }
                Button("Move Down") {
                    commitAccessibilityLayout { $0.movedBy(x: 0, y: 0.02) }
                }
                Button("Make Smaller") {
                    commitAccessibilityLayout { $0.scaledBy(1 / 1.1) }
                }
                Button("Make Larger") {
                    commitAccessibilityLayout { $0.scaledBy(1.1) }
                }
                Button("Reset Position and Size", action: onReset)
            }
    }

    private func resizeHandle(overlayRect: CGRect, videoRect: CGRect) -> some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .frame(width: 14, height: 14)
            .position(x: overlayRect.maxX, y: overlayRect.maxY)
            .shadow(color: .black.opacity(0.35), radius: 2)
            .highPriorityGesture(resizeGesture(videoRect: videoRect))
            .onHover { hovering in
                if hovering { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
            }
            .accessibilityHidden(true)
    }

    private func moveGesture(videoRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                onSelect()
                draftLayout = movedLayout(
                    clip.videoLayout ?? .defaultCamera,
                    translation: value.translation,
                    videoRect: videoRect
                )
            }
            .onEnded { value in
                let final = movedLayout(
                    clip.videoLayout ?? .defaultCamera,
                    translation: value.translation,
                    videoRect: videoRect
                )
                onCommit(final)
                draftLayout = nil
            }
    }

    private func resizeGesture(videoRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                draftLayout = resizedLayout(
                    clip.videoLayout ?? .defaultCamera,
                    translation: value.translation,
                    videoRect: videoRect
                )
            }
            .onEnded { value in
                let final = resizedLayout(
                    clip.videoLayout ?? .defaultCamera,
                    translation: value.translation,
                    videoRect: videoRect
                )
                onCommit(final)
                draftLayout = nil
            }
    }

    private func accessibilityValue(for layout: TimelineVideoLayout) -> String {
        "\(isSelected ? "Selected" : "Not selected"), "
            + "position \(Int(layout.x * 100)) by \(Int(layout.y * 100)) percent, "
            + "size \(Int(layout.width * 100)) by \(Int(layout.height * 100)) percent"
    }

    private func commitAccessibilityLayout(
        _ transform: (TimelineVideoLayout) -> TimelineVideoLayout
    ) {
        onSelect()
        onCommit(transform(clip.videoLayout ?? .defaultCamera))
    }

    private func movedLayout(
        _ original: TimelineVideoLayout,
        translation: CGSize,
        videoRect: CGRect
    ) -> TimelineVideoLayout {
        guard videoRect.width > 0, videoRect.height > 0 else { return original.clamped() }
        return original.movedBy(
            x: Double(translation.width / videoRect.width),
            y: Double(translation.height / videoRect.height)
        )
    }

    private func resizedLayout(
        _ original: TimelineVideoLayout,
        translation: CGSize,
        videoRect: CGRect
    ) -> TimelineVideoLayout {
        let original = original.clamped()
        guard videoRect.width > 0,
              videoRect.height > 0,
              original.width > 0,
              original.height > 0
        else { return original }
        let horizontalScale = (original.width + Double(translation.width / videoRect.width)) / original.width
        let verticalScale = (original.height + Double(translation.height / videoRect.height)) / original.height
        let requestedScale = max(horizontalScale, verticalScale)
        let minimumScale = max(0.08 / original.width, 0.08 / original.height)
        let maximumScale = min(
            (1 - original.x) / original.width,
            (1 - original.y) / original.height
        )
        let scale = min(max(requestedScale, minimumScale), maximumScale)
        return TimelineVideoLayout(
            x: original.x,
            y: original.y,
            width: original.width * scale,
            height: original.height * scale
        ).clamped()
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

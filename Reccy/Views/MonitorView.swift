import SwiftUI

struct MonitorView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator
    @EnvironmentObject private var transcription: TranscriptionController
    @EnvironmentObject private var navigation: AppNavigationModel
    @State private var isShowingMouseZoomControls = false
    @State private var isShowingCameraEffects = false

    var body: some View {
        Group {
            if coordinator.state.isRecording {
                activeMonitor
            } else {
                WorkspaceEmptyState(
                    "No Active Recording",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: "Choose a source in Record, then start recording. Reccy opens this monitor automatically.",
                    actionTitle: "Choose a Source"
                ) {
                    navigation.section = .record
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Monitor")
    }

    private var activeMonitor: some View {
        ReccySplitView(
            axis: .vertical,
            autosaveName: "monitor.overview-details.v2",
            initialFraction: 0.60,
            firstMinimum: 440,
            secondMinimum: 220,
            firstPaneName: "recording overview",
            secondPaneName: "recording details",
            first: {
                monitoringOverview
                    .padding(20)
            },
            second: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        audioSection
                        if transcription.isLiveCaptureEnabled {
                            liveTranscriptSection
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        )
    }

    private var monitoringOverview: some View {
        ReccySplitView(
            axis: .horizontal,
            autosaveName: "monitor.preview-status",
            initialFraction: 0.70,
            firstMinimum: 360,
            secondMinimum: 280,
            secondMaximum: 380,
            firstPaneName: "live preview",
            secondPaneName: "recording status",
            first: { livePreview },
            second: { recordingStatusCard }
        )
    }

    private var livePreview: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                MouseFollowZoomPreview(
                    pipeline: coordinator.previewPipeline,
                    scale: coordinator.liveMouseFollowZoomScale,
                    focus: coordinator.mouseFollowZoomPosition
                )
                    .background(.black)

                if coordinator.settings.includeCamera {
                    MovableLiveCameraOverlay(
                        pipeline: coordinator.cameraPreviewPipeline,
                        cameraName: coordinator.selectedCameraName,
                        canvasSize: geometry.size,
                        layout: coordinator.liveCameraOverlayLayout,
                        onCommit: coordinator.setLiveCameraOverlayLayout,
                        onReset: coordinator.resetLiveCameraOverlayPosition
                    )
                }

                LinearGradient(
                    colors: [.black.opacity(0.62), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .allowsHitTesting(false)

                HStack(spacing: 8) {
                    Label(
                        coordinator.selectedSource?.name ?? coordinator.selectedSourceKind.title,
                        systemImage: coordinator.selectedSourceKind.systemImage
                    )
                    .lineLimit(1)

                    Spacer(minLength: 8)

                    previewStateBadge
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(10)
                .allowsHitTesting(false)
            }
        }
        .aspectRatio(coordinator.activeCaptureAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Live preview of \(coordinator.selectedSource?.name ?? coordinator.selectedSourceKind.title)"
        )
    }

    @ViewBuilder
    private var previewStateBadge: some View {
        switch coordinator.state {
        case let .countingDown(seconds):
            Label("STARTING IN \(seconds)", systemImage: "timer")
        case .starting:
            Label("PREPARING", systemImage: "ellipsis")
        case .paused:
            Label("PAUSED", systemImage: "pause.fill")
        case .stopping:
            Label("FINISHING", systemImage: "hourglass")
        default:
            HStack(spacing: 5) {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                Text("LIVE")
            }
        }
    }

    private var recordingStatusCard: some View {
        CardContainer {
            GeometryReader { geometry in
                recordingStatusContent(isCompact: geometry.size.height < 440)
            }
        }
        .frame(minHeight: 400)
    }

    private func recordingStatusContent(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
            Label(statusTitle, systemImage: "record.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .lineLimit(1)

            Text(primaryStatusValue)
                .font(.system(
                    size: isCompact ? 29 : 34,
                    weight: .semibold,
                    design: .monospaced
                ))
                .contentTransition(.numericText())

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    metadataPill(
                        coordinator.settings.resolution.title,
                        systemImage: "rectangle.expand.vertical"
                    )
                    metadataPill(
                        coordinator.settings.frameRate.title,
                        systemImage: "speedometer"
                    )
                }
                VStack(alignment: .leading, spacing: 5) {
                    metadataPill(
                        coordinator.settings.resolution.title,
                        systemImage: "rectangle.expand.vertical"
                    )
                    metadataPill(
                        coordinator.settings.frameRate.title,
                        systemImage: "speedometer"
                    )
                }
            }

            Text(coordinator.liveStorageStatus)
                .font((isCompact ? Font.caption : Font.callout).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(isCompact ? compactAudioDescription : activeAudioDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(isCompact ? 1 : 3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: isCompact ? 6 : 14)

            Divider()
                .padding(.vertical, isCompact ? 0 : 2)

            mouseFollowZoomControl(isCompact: isCompact)

            if coordinator.settings.includeCamera {
                cameraEffectsControl(isCompact: isCompact)
            }

            Button {
                coordinator.toggleRecordingPause()
            } label: {
                recordingControlLabel(
                    coordinator.state == .paused ? "Resume Recording" : "Pause Recording",
                    systemImage: coordinator.state == .paused ? "play.fill" : "pause.fill",
                    isCompact: isCompact
                )
            }
            .buttonStyle(.bordered)
            .controlSize(isCompact ? .regular : .large)
            .disabled(coordinator.state != .recording && coordinator.state != .paused)

            Button {
                coordinator.requestCancelRecording()
            } label: {
                recordingControlLabel(
                    "Cancel",
                    systemImage: "xmark",
                    isCompact: isCompact
                )
            }
            .buttonStyle(.bordered)
            .controlSize(isCompact ? .regular : .large)
            .disabled(coordinator.state != .recording && coordinator.state != .paused)
            .reccyAccessibleControl(
                "Cancel Recording",
                help: "Discard this recording after confirmation without adding it to the Library"
            )

            Button {
                coordinator.requestFinishRecording()
            } label: {
                recordingControlLabel(
                    coordinator.state == .recording || coordinator.state == .paused
                        ? "Finish"
                        : coordinator.state.recordingEndButtonTitle,
                    systemImage: "stop.fill",
                    isCompact: isCompact
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(isCompact ? .regular : .large)
            .tint(.red)
            .disabled(coordinator.state == .stopping)
            .reccyAccessibleControl(
                coordinator.state.recordingEndButtonTitle,
                help: "Finish writing this recording and add it to the Library"
            )
        }
        .buttonBorderShape(.capsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func mouseFollowZoomControl(isCompact: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                coordinator.toggleMouseFollowZoom()
            } label: {
                recordingControlLabel(
                    "Mouse Zoom · \(coordinator.liveMouseFollowZoomScaleTitle)",
                    systemImage: coordinator.isMouseFollowZoomActive
                        ? "cursorarrow.motionlines"
                        : "plus.magnifyingglass",
                    isCompact: isCompact
                )
            }
            .buttonStyle(.bordered)
            .controlSize(isCompact ? .regular : .large)
            .tint(coordinator.isMouseFollowZoomActive ? .green : nil)
            .accessibilityValue(coordinator.isMouseFollowZoomActive ? "On" : "Off")
            .accessibilityHint("Toggles the editable mouse-follow zoom effect")

            Button {
                isShowingMouseZoomControls.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .frame(minWidth: isCompact ? 22 : 28, minHeight: isCompact ? 28 : 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(isCompact ? .regular : .large)
            .tint(coordinator.isMouseFollowZoomActive ? .green : nil)
            .accessibilityLabel("Change Mouse Zoom Level")
            .accessibilityHint("Opens the mouse zoom level controls")
            .popover(isPresented: $isShowingMouseZoomControls, arrowEdge: .trailing) {
                mouseZoomControlsPopover
            }
        }
        .buttonBorderShape(.capsule)
        .disabled(coordinator.state != .recording && coordinator.state != .paused)
        .frame(maxWidth: .infinity)
    }

    private var mouseZoomControlsPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Label("Mouse Zoom", systemImage: "cursorarrow.motionlines")
                    .font(.headline)
                Spacer()
                Button {
                    isShowingMouseZoomControls = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close Mouse Zoom Controls")
                .keyboardShortcut(.cancelAction)
            }

            Picker(
                "Zoom level",
                selection: Binding(
                    get: { coordinator.settings.mouseFollowZoomLevel },
                    set: { coordinator.setMouseFollowZoomLevel($0) }
                )
            ) {
                ForEach(MouseFollowZoomLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
        }
        .padding(14)
        .frame(width: 176)
    }

    private func cameraEffectsControl(isCompact: Bool) -> some View {
        Button {
            isShowingCameraEffects.toggle()
        } label: {
            recordingControlLabel(
                "Camera Effects",
                systemImage: "person.crop.rectangle",
                isCompact: isCompact
            )
        }
        .buttonStyle(.bordered)
        .controlSize(isCompact ? .regular : .large)
        .disabled(!coordinator.canOpenCameraVideoEffects)
        .popover(isPresented: $isShowingCameraEffects, arrowEdge: .trailing) {
            cameraEffectsPopover
        }
        .accessibilityHint("Opens the native macOS camera controls")
        .help("Camera Effects")
    }

    private var cameraEffectsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Camera Effects", systemImage: "person.crop.rectangle")
                    .font(.headline)
                Spacer()
                Button {
                    isShowingCameraEffects = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close Camera Effects")
                .keyboardShortcut(.cancelAction)
            }

            Text("Reccy uses the effects built into macOS, so the live preview and the independent camera track always match.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                coordinator.openCameraVideoEffects()
            } label: {
                Label("Open macOS Camera Effects…", systemImage: "switch.2")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!coordinator.canOpenCameraVideoEffects)

            Text("Press Escape or click outside the macOS panel when finished.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") {
                    isShowingCameraEffects = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func recordingControlLabel(
        _ title: String,
        systemImage: String,
        isCompact: Bool
    ) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity, minHeight: isCompact ? 28 : 34)
            .contentShape(Rectangle())
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                "Incoming audio",
                subtitle: "Live levels verify that each enabled source is reaching the recording."
            )

            ReccySplitView(
                axis: .horizontal,
                autosaveName: "monitor.audio-sources",
                initialFraction: 0.5,
                firstMinimum: 240,
                secondMinimum: 240,
                firstPaneName: "system audio meter",
                secondPaneName: "microphone meter",
                first: {
                    audioMeterCard(
                        title: "System Audio",
                        systemImage: "speaker.wave.2.fill",
                        isEnabled: coordinator.settings.includeSystemAudio,
                        level: coordinator.systemAudioLevel,
                        history: coordinator.systemAudioHistory,
                        color: .teal
                    )
                },
                second: {
                    audioMeterCard(
                        title: "Microphone",
                        systemImage: "mic.fill",
                        isEnabled: coordinator.settings.includeMicrophone,
                        level: coordinator.microphoneAudioLevel,
                        history: coordinator.microphoneAudioHistory,
                        color: .orange
                    )
                }
            )
            .frame(height: 220)
        }
    }

    private func audioMeterCard(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        level: Double,
        history: [Double],
        color: Color
    ) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                    Spacer()
                    Text(isEnabled ? levelLabel(level) : "Off")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(isEnabled ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                }

                ReccyLiveWaveform(samples: history, color: color, isEnabled: isEnabled)
                    .frame(height: 92)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(color.gradient)
                            .frame(width: geometry.size.width * (isEnabled ? level : 0))
                    }
                }
                .frame(height: 6)

                Text(isEnabled ? "Receiving live samples" : "Not included in this recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var liveTranscriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                "Live transcript",
                subtitle: "On-device words are aligned to their independent recording tracks."
            )

            if let notice = transcription.liveNotice {
                CardContainer {
                    Label(notice, systemImage: "captions.bubble")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                if showsSystemTranscript && showsMicrophoneTranscript {
                    ReccySplitView(
                        axis: .horizontal,
                        autosaveName: "monitor.live-transcripts",
                        initialFraction: 0.5,
                        firstMinimum: 240,
                        secondMinimum: 240,
                        firstPaneName: "system audio transcript",
                        secondPaneName: "microphone transcript",
                        first: { liveTranscriptCard(role: .systemAudio, color: .teal) },
                        second: { liveTranscriptCard(role: .microphone, color: .orange) }
                    )
                    .frame(height: 180)
                } else if showsSystemTranscript {
                    liveTranscriptCard(role: .systemAudio, color: .teal)
                        .frame(maxWidth: .infinity)
                } else if showsMicrophoneTranscript {
                    liveTranscriptCard(role: .microphone, color: .orange)
                        .frame(maxWidth: .infinity)
                }
            }

            if let warning = transcription.liveTransportWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Live transcript warning. \(warning)")
            }
        }
    }

    private var showsSystemTranscript: Bool {
        coordinator.settings.includeSystemAudio && transcription.transcribeSystemAudio
    }

    private var showsMicrophoneTranscript: Bool {
        coordinator.settings.includeMicrophone && transcription.transcribeMicrophone
    }

    private func liveTranscriptCard(role: TranscriptTrackRole, color: Color) -> some View {
        LiveTranscriptCard(
            role: role,
            color: color,
            update: transcription.liveUpdates[role]
        )
    }

    private func metadataPill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
    }

    private var statusTitle: String {
        switch coordinator.state {
        case .countingDown: "Recording starts shortly"
        case .starting: "Starting capture"
        case .recording: "Recording in progress"
        case .paused: "Recording paused"
        case .stopping: "Finishing recording"
        default: "Monitor"
        }
    }

    private var primaryStatusValue: String {
        if case let .countingDown(seconds) = coordinator.state {
            return "00:00:\(String(format: "%02d", seconds))"
        }
        return coordinator.formattedDuration
    }

    private func levelLabel(_ level: Double) -> String {
        guard level > 0.001 else { return "−∞ dB" }
        let decibels = level * 60 - 60
        return String(format: "%+.0f dB", decibels)
    }

    private var activeAudioDescription: String {
        switch (coordinator.settings.includeSystemAudio, coordinator.settings.includeMicrophone) {
        case (true, true): "System audio and microphone are recording as separate tracks."
        case (true, false): "System audio is recording on its own track."
        case (false, true): "Microphone is recording on its own track."
        case (false, false): "This recording has no audio tracks."
        }
    }

    private var compactAudioDescription: String {
        switch (coordinator.settings.includeSystemAudio, coordinator.settings.includeMicrophone) {
        case (true, true): "System + microphone · separate tracks"
        case (true, false): "System audio · separate track"
        case (false, true): "Microphone · separate track"
        case (false, false): "No audio tracks"
        }
    }
}

/// Direct manipulation for the live camera preview. The independent camera
/// source is never composited into the recording here; this control commits a
/// normalized position that the recording manifest and editor compositor use
/// later. Keeping pointer-rate state local avoids filesystem writes and broad
/// observable-object invalidation while the user drags.
private struct MovableLiveCameraOverlay: View {
    let pipeline: CapturePreviewPipeline
    let cameraName: String
    let canvasSize: CGSize
    let layout: TimelineVideoLayout
    let onCommit: (TimelineVideoLayout) -> Void
    let onReset: () -> Void

    @State private var draftLayout: TimelineVideoLayout?
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var displayedLayout: TimelineVideoLayout {
        (draftLayout ?? layout).clamped()
    }

    private var overlayRect: CGRect {
        let layout = displayedLayout
        return CGRect(
            x: CGFloat(layout.x) * canvasSize.width,
            y: CGFloat(layout.y) * canvasSize.height,
            width: CGFloat(layout.width) * canvasSize.width,
            height: CGFloat(layout.height) * canvasSize.height
        )
    }

    var body: some View {
        let overlayRect = overlayRect
        CapturePreviewView(pipeline: pipeline)
            .background(.black)
            .frame(width: overlayRect.width, height: overlayRect.height)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isFocused || isHovering || draftLayout != nil
                            ? Color.accentColor
                            : .white.opacity(0.8),
                        lineWidth: isFocused || draftLayout != nil ? 2 : 1
                    )
            }
            .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            .position(x: overlayRect.midX, y: overlayRect.midY)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onHover { isHovering = $0 }
            .simultaneousGesture(TapGesture().onEnded { isFocused = true })
            .gesture(moveGesture)
            .pointerStyle(draftLayout == nil ? .grabIdle : .grabActive)
            .focusable()
            .focused($isFocused)
            .onKeyPress(.leftArrow) { commitMove(x: -0.02, y: 0) }
            .onKeyPress(.rightArrow) { commitMove(x: 0.02, y: 0) }
            .onKeyPress(.upArrow) { commitMove(x: 0, y: -0.02) }
            .onKeyPress(.downArrow) { commitMove(x: 0, y: 0.02) }
            .contextMenu {
                Button("Reset Camera Position", systemImage: "arrow.counterclockwise") {
                    onReset()
                }
            }
            .help("Drag to reposition the camera. Use the arrow keys for precise movement.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live camera overlay from \(cameraName)")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Drag to reposition. Arrow keys and additional actions provide precise movement.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isFocused = true }
            .accessibilityActions {
                Button("Move Left") { commitLayout(layout.movedBy(x: -0.02, y: 0)) }
                Button("Move Right") { commitLayout(layout.movedBy(x: 0.02, y: 0)) }
                Button("Move Up") { commitLayout(layout.movedBy(x: 0, y: -0.02)) }
                Button("Move Down") { commitLayout(layout.movedBy(x: 0, y: 0.02)) }
                Button("Reset Position", action: onReset)
            }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                isFocused = true
                draftLayout = movedLayout(translation: value.translation)
            }
            .onEnded { value in
                commitLayout(movedLayout(translation: value.translation))
                draftLayout = nil
            }
    }

    private func movedLayout(translation: CGSize) -> TimelineVideoLayout {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return layout.clamped() }
        return layout.movedBy(
            x: Double(translation.width / canvasSize.width),
            y: Double(translation.height / canvasSize.height)
        )
    }

    private func commitMove(x: Double, y: Double) -> KeyPress.Result {
        commitLayout(layout.movedBy(x: x, y: y))
        return .handled
    }

    private func commitLayout(_ layout: TimelineVideoLayout) {
        isFocused = true
        onCommit(layout.clamped())
    }

    private var accessibilityValue: String {
        let layout = displayedLayout
        let position = CameraOverlayPosition(layout: layout)
        return "center \(Int(position.centerX * 100)) by \(Int(position.centerY * 100)) percent"
    }
}

private struct MouseFollowZoomPreview: View {
    let pipeline: CapturePreviewPipeline
    let scale: Double
    let focus: CGPoint

    var body: some View {
        GeometryReader { geometry in
            let transform = MouseFollowZoomPreviewTransform.resolve(
                scale: scale,
                focus: focus,
                viewportSize: geometry.size
            )
            CapturePreviewView(pipeline: pipeline)
                .scaleEffect(transform.scale)
                .offset(transform.offset)
                .animation(.smooth(duration: 0.14), value: transform.offset)
                .animation(.smooth(duration: 0.2), value: transform.scale)
        }
        .clipped()
    }
}

/// Resolves the live effect independently from the capture surface. An
/// inactive 1x effect must be the identity transform regardless of the last
/// sampled pointer position; otherwise an ended zoom leaves the source shifted
/// and clipped even though the recording is no longer magnified.
nonisolated struct MouseFollowZoomPreviewTransform: Equatable, Sendable {
    let scale: CGFloat
    let offset: CGSize

    static func resolve(
        scale: Double,
        focus: CGPoint,
        viewportSize: CGSize
    ) -> MouseFollowZoomPreviewTransform {
        let clampedScale = CGFloat(min(max(scale, 1), MouseFollowZoomScale.maximum))
        guard clampedScale > 1 else {
            return MouseFollowZoomPreviewTransform(scale: 1, offset: .zero)
        }
        let clampedFocus = CGPoint(
            x: min(max(focus.x, 0), 1),
            y: min(max(focus.y, 0), 1)
        )
        return MouseFollowZoomPreviewTransform(
            scale: clampedScale,
            offset: CGSize(
                width: (0.5 - clampedFocus.x) * viewportSize.width * clampedScale,
                height: (0.5 - clampedFocus.y) * viewportSize.height * clampedScale
            )
        )
    }
}

private struct LiveTranscriptCard: View {
    private static let bottomAnchor = "live-transcript-bottom"

    let role: TranscriptTrackRole
    let color: Color
    let update: LiveTranscriptUpdate?

    private var finalized: [TranscriptSegment] {
        Array(update?.finalizedSegments.suffix(20) ?? [])
    }

    private var volatile: [TranscriptSegment] {
        Array(update?.volatileSegments.suffix(4) ?? [])
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(role.title, systemImage: role.systemImage)
                        .font(.headline)
                    Spacer()
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                    Text(update == nil ? "LISTENING" : "LIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if finalized.isEmpty && volatile.isEmpty {
                                Text("Listening… First words can take a moment to appear.")
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            } else {
                                ForEach(finalized) { segment in
                                    Text(segment.displayText)
                                        .textSelection(.enabled)
                                }
                                ForEach(volatile) { segment in
                                    Text(segment.displayText)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(Self.bottomAnchor)
                        }
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: update) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                    }
                }
                .frame(height: 104)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live \(role.title) transcript")
    }
}

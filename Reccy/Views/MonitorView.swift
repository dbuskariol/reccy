import SwiftUI

struct MonitorView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator
    @EnvironmentObject private var transcription: TranscriptionController

    private let meterColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        Group {
            if coordinator.state.isRecording {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        monitoringOverview
                        audioSection
                        if transcription.isLiveCaptureEnabled {
                            liveTranscriptSection
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 980)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                WorkspaceEmptyState(
                    "No Active Recording",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: "Choose a source in Record, then start recording. Reccy opens this monitor automatically."
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Monitor")
        .toolbar {
            if coordinator.state.isRecording {
                ToolbarItem {
                    HStack {
                        Button(
                            coordinator.state == .paused ? "Resume" : "Pause",
                            systemImage: coordinator.state == .paused ? "play.fill" : "pause.fill"
                        ) {
                            coordinator.toggleRecordingPause()
                        }
                        .disabled(coordinator.state != .recording && coordinator.state != .paused)

                        Button("Stop", systemImage: "stop.fill") {
                            coordinator.stopRecording()
                        }
                        .tint(.red)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(coordinator.state == .paused ? .orange : .red)
                        .frame(width: 10, height: 10)
                        .shadow(color: .red.opacity(0.55), radius: 4)
                    Text(statusTitle)
                        .font(.largeTitle.weight(.bold))
                }
                Text("Keep this window open on another display while Reccy captures your selected source.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(coordinator.formattedDuration)
                .font(.title2.monospacedDigit().weight(.semibold))
        }
    }

    private var monitoringOverview: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                livePreview
                    .frame(maxWidth: .infinity)
                recordingStatusCard
                    .frame(width: 260)
            }

            VStack(spacing: 16) {
                livePreview
                recordingStatusCard
            }
        }
    }

    private var livePreview: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                CapturePreviewView(pipeline: coordinator.previewPipeline)
                    .background(.black)

                if coordinator.settings.includeCamera {
                    CapturePreviewView(pipeline: coordinator.cameraPreviewPipeline)
                        .background(.black)
                        .frame(
                            width: geometry.size.width * 0.28,
                            height: geometry.size.height * 0.28
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(.white.opacity(0.8), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                        .position(
                            x: geometry.size.width * 0.83,
                            y: geometry.size.height * 0.81
                        )
                        .accessibilityLabel("Live camera preview from \(coordinator.selectedCameraName)")
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

                    HStack(spacing: 5) {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                        Text(coordinator.state == .paused ? "PAUSED" : "LIVE")
                    }
                    .foregroundStyle(.white)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(10)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
        .accessibilityLabel(
            "Live preview of \(coordinator.selectedSource?.name ?? coordinator.selectedSourceKind.title)"
        )
    }

    private var recordingStatusCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(statusTitle, systemImage: "record.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    Spacer()
                }

                Text(primaryStatusValue)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .contentTransition(.numericText())

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        metadataPill(coordinator.settings.resolution.title, systemImage: "rectangle.expand.vertical")
                        metadataPill(coordinator.settings.frameRate.title, systemImage: "speedometer")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        metadataPill(coordinator.settings.resolution.title, systemImage: "rectangle.expand.vertical")
                        metadataPill(coordinator.settings.frameRate.title, systemImage: "speedometer")
                    }
                }

                Text(coordinator.liveStorageStatus)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(activeAudioDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                Button {
                    coordinator.stopRecording()
                } label: {
                    recordingControlLabel(coordinator.state.stopButtonTitle, systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
                .disabled(coordinator.state == .stopping)

                Button {
                    coordinator.toggleRecordingPause()
                } label: {
                    recordingControlLabel(
                        coordinator.state == .paused ? "Resume Recording" : "Pause Recording",
                        systemImage: coordinator.state == .paused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(coordinator.state != .recording && coordinator.state != .paused)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func recordingControlLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(Rectangle())
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                "Incoming audio",
                subtitle: "Live levels verify that each enabled source is reaching the recording."
            )

            LazyVGrid(columns: meterColumns, alignment: .leading, spacing: 16) {
                audioMeterCard(
                    title: "System Audio",
                    systemImage: "speaker.wave.2.fill",
                    isEnabled: coordinator.settings.includeSystemAudio,
                    level: coordinator.systemAudioLevel,
                    history: coordinator.systemAudioHistory,
                    color: .teal
                )
                audioMeterCard(
                    title: "Microphone",
                    systemImage: "mic.fill",
                    isEnabled: coordinator.settings.includeMicrophone,
                    level: coordinator.microphoneAudioLevel,
                    history: coordinator.microphoneAudioHistory,
                    color: .orange
                )
            }
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
                LazyVGrid(columns: meterColumns, alignment: .leading, spacing: 16) {
                    if coordinator.settings.includeSystemAudio && transcription.transcribeSystemAudio {
                        liveTranscriptCard(role: .systemAudio, color: .teal)
                    }
                    if coordinator.settings.includeMicrophone && transcription.transcribeMicrophone {
                        liveTranscriptCard(role: .microphone, color: .orange)
                    }
                }
            }
        }
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
                                Text("Waiting for speech…")
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

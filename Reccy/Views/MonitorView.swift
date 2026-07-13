import SwiftUI

struct MonitorView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator

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
                        recordingStatusCard
                        audioSection
                    }
                    .padding(28)
                    .frame(maxWidth: 980)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                ContentUnavailableView {
                    Label("No Active Recording", systemImage: "waveform.path.ecg.rectangle")
                } description: {
                    Text("Choose a source in Record, then start recording. Reccy opens this monitor automatically.")
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Monitor")
        .toolbar {
            if coordinator.state.isRecording {
                ToolbarItem {
                    Button("Stop", systemImage: "stop.fill") {
                        coordinator.stopRecording()
                    }
                    .tint(.red)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(.red)
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

    private var recordingStatusCard: some View {
        CardContainer {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(primaryStatusValue)
                        .font(.system(size: 52, weight: .semibold, design: .monospaced))
                        .contentTransition(.numericText())

                    HStack(spacing: 8) {
                        metadataPill(
                            coordinator.selectedSource?.name ?? coordinator.selectedSourceKind.title,
                            systemImage: coordinator.selectedSourceKind.systemImage
                        )
                        metadataPill(coordinator.settings.resolution.title, systemImage: "rectangle.expand.vertical")
                        metadataPill(coordinator.settings.frameRate.title, systemImage: "speedometer")
                        metadataPill(coordinator.settings.recordingPreset.title, systemImage: "doc.badge.gearshape")
                    }

                    Text("\(coordinator.formattedFileSize) written · \(activeAudioDescription)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 24)

                Button {
                    coordinator.stopRecording()
                } label: {
                    Label(stopButtonTitle, systemImage: "stop.fill")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
                .disabled(coordinator.state == .stopping)
            }
            .frame(minHeight: 150)
        }
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

                AudioWaveformView(samples: history, color: color, isEnabled: isEnabled)
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

    private var stopButtonTitle: String {
        switch coordinator.state {
        case .countingDown: "Cancel"
        case .stopping: "Finishing…"
        default: "Stop Recording"
        }
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

private struct AudioWaveformView: View {
    let samples: [Double]
    let color: Color
    let isEnabled: Bool

    var body: some View {
        Canvas { context, size in
            let visibleSamples = samples.isEmpty ? Array(repeating: 0.0, count: 48) : samples
            let spacing = size.width / CGFloat(max(visibleSamples.count, 1))
            let barWidth = max(1.5, spacing * 0.48)

            for (index, sample) in visibleSamples.enumerated() {
                let amplitude = isEnabled ? min(max(sample, 0.015), 1) : 0.015
                let height = max(2, amplitude * size.height * 0.9)
                let rect = CGRect(
                    x: CGFloat(index) * spacing,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(isEnabled ? color.opacity(0.9) : Color.secondary.opacity(0.2))
                )
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(isEnabled ? "Live audio waveform" : "Audio source off")
    }
}

import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if case let .failed(message) = coordinator.state {
                    errorBanner(message)
                }

                if coordinator.state.isRecording {
                    activeRecordingCard
                } else {
                    sourceCard
                    optionsCard
                    outputCard
                    macOS26Card
                    recordControls
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Record")
        .toolbar {
            ToolbarItem {
                Button {
                    coordinator.library.revealDirectory()
                } label: {
                    Label("Open Recordings", systemImage: "folder")
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Capture your Mac")
                    .font(.largeTitle.weight(.bold))
                Text("Native, private, and tuned for excellent quality at sensible file sizes.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("⌘⇧R")
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var sourceCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(
                    "What do you want to record?",
                    subtitle: "macOS shows the system picker, so Reccy only sees what you approve."
                )

                HStack(spacing: 12) {
                    ForEach(CaptureSourceKind.allCases) { source in
                        sourceButton(source)
                    }
                }
            }
        }
    }

    private func sourceButton(_ source: CaptureSourceKind) -> some View {
        let isSelected = coordinator.hasSelectedSource && coordinator.selectedSourceKind == source
        return Button {
            coordinator.chooseSource(source)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: source.systemImage)
                        .font(.title2)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
                Text(source.title)
                    .font(.headline)
                Text(source.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
            .padding(15)
            .background(isSelected ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 1.5 : 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var optionsCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 17) {
                SectionHeading("Capture options")
                Grid(alignment: .topLeading, horizontalSpacing: 36, verticalSpacing: 14) {
                    GridRow {
                        optionColumn(title: "Audio", systemImage: "waveform") {
                            Toggle("System audio", isOn: $coordinator.settings.includeSystemAudio)
                            Toggle("Microphone", isOn: $coordinator.settings.includeMicrophone)
                            if coordinator.settings.includeSystemAudio && coordinator.settings.includeMicrophone {
                                Label("Saved as separate editable tracks", systemImage: "timeline.selection")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if coordinator.settings.includeMicrophone {
                                Picker("Input", selection: $coordinator.settings.selectedMicrophoneID) {
                                    Text("System Default").tag(String?.none)
                                    ForEach(coordinator.audioInputDevices) { device in
                                        Text(device.name).tag(Optional(device.id))
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 220)
                            }
                        }

                        optionColumn(title: "Pointer", systemImage: "cursorarrow.motionlines") {
                            Toggle("Show cursor", isOn: $coordinator.settings.showCursor)
                            Toggle("Highlight clicks", isOn: $coordinator.settings.showMouseClicks)
                                .disabled(coordinator.settings.useHDR)
                            if coordinator.settings.useHDR {
                                Text("Click highlights require SDR capture.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        optionColumn(title: "Start", systemImage: "timer") {
                            Picker("Countdown", selection: $coordinator.settings.countdown) {
                                ForEach(CountdownDelay.allCases) { delay in
                                    Text(delay.title).tag(delay)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 180)
                            Toggle("Exclude Reccy audio", isOn: $coordinator.settings.excludeOwnAudio)
                        }
                    }
                }
            }
        }
    }

    private func optionColumn<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var outputCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(
                    "Recording quality",
                    subtitle: "The defaults balance sharp text, smooth motion, and compact files."
                )
                HStack(spacing: 18) {
                    settingPicker("Resolution", selection: $coordinator.settings.resolution) {
                        ForEach(CaptureResolution.allCases) { resolution in
                            Text("\(resolution.title) — \(resolution.detail)").tag(resolution)
                        }
                    }
                    settingPicker("Frame rate", selection: $coordinator.settings.frameRate) {
                        ForEach(CaptureFrameRate.allCases) { frameRate in
                            Text(frameRate.title).tag(frameRate)
                        }
                    }
                    settingPicker("Format", selection: $coordinator.settings.recordingPreset) {
                        ForEach(RecordingPreset.allCases) { preset in
                            Text("\(preset.title) — \(preset.detail)").tag(preset)
                        }
                    }
                }
            }
        }
    }

    private func settingPicker<Selection: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(title, selection: selection, content: content)
                .labelsHidden()
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var macOS26Card: some View {
        CardContainer {
            VStack(spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.title)
                        .foregroundStyle(.tint)
                        .frame(width: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("HDR10 recording")
                                .font(.headline)
                            CapabilityBadge(text: "macOS 26")
                        }
                        Text("Preserves highlights and color while maintaining a useful SDR playback range.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("HDR10", isOn: $coordinator.settings.useHDR)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                Divider()

                HStack(spacing: 14) {
                    Image(systemName: "camera.aperture")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Native screenshots")
                            .font(.headline)
                        Text("Save the selected display, app, or window in SDR or HDR.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Format", selection: $coordinator.settings.screenshotFormat) {
                        ForEach(ScreenshotFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 92)
                    Picker("Range", selection: $coordinator.settings.screenshotRange) {
                        ForEach(ScreenshotRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 82)
                    Button {
                        coordinator.captureScreenshot()
                    } label: {
                        if coordinator.isCapturingScreenshot {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Screenshot", systemImage: "camera")
                        }
                    }
                    .disabled(!coordinator.hasSelectedSource || coordinator.isCapturingScreenshot)
                }
            }
        }
    }

    private var recordControls: some View {
        HStack(spacing: 14) {
            Button {
                coordinator.startRecording()
            } label: {
                Label(
                    coordinator.hasSelectedSource ? "Start Recording" : "Choose Source",
                    systemImage: coordinator.hasSelectedSource ? "record.circle.fill" : "rectangle.dashed.badge.record"
                )
                .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)

            if let url = coordinator.lastRecordingURL {
                ShareLink(item: url) {
                    Label("Share Last Recording", systemImage: "square.and.arrow.up")
                }
                .controlSize(.large)
            }

            if let url = coordinator.lastScreenshotURL {
                ShareLink(item: url) {
                    Label("Share Screenshot", systemImage: "photo")
                }
                .controlSize(.large)
            }
        }
    }

    private var activeRecordingCard: some View {
        CardContainer {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(.red.opacity(0.12))
                        .frame(width: 88, height: 88)
                    Circle()
                        .fill(.red)
                        .frame(width: 34, height: 34)
                        .shadow(color: .red.opacity(0.4), radius: 10)
                }

                switch coordinator.state {
                case let .countingDown(seconds):
                    Text("\(seconds)")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("Get ready")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { coordinator.cancelCountdown() }
                case .starting:
                    ProgressView("Starting recording…")
                case .stopping:
                    ProgressView("Finishing the file…")
                default:
                    Text(coordinator.formattedDuration)
                        .font(.system(size: 48, weight: .semibold, design: .monospaced))
                        .contentTransition(.numericText())
                    Text("\(coordinator.formattedFileSize) · \(coordinator.settings.resolution.title) · \(coordinator.settings.frameRate.title)")
                        .foregroundStyle(.secondary)
                    Button {
                        coordinator.stopRecording()
                    } label: {
                        Label("Stop Recording", systemImage: "stop.fill")
                            .frame(minWidth: 150)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 390)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Reccy couldn’t continue")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss") { coordinator.clearError() }
        }
        .padding(15)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator

    private let threeColumnLayout = Array(
        repeating: GridItem(.flexible(minimum: 180), spacing: 18, alignment: .topLeading),
        count: 3
    )
    private let sourceColumnLayout = Array(
        repeating: GridItem(.flexible(minimum: 160), spacing: 14, alignment: .topLeading),
        count: 4
    )

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if case let .failed(message) = coordinator.state {
                        errorBanner(message)
                    }

                    if coordinator.state.isRecording {
                        activeRecordingCard
                    } else {
                        permissionsCard
                        sourceCard
                        optionsCard
                        outputCard
                        macOS26Card
                    }
                }
                .padding(28)
                .frame(maxWidth: 1040, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }

            if !coordinator.state.isRecording {
                Divider()
                recordControls
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 1040)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
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

                if coordinator.isPresentingSourcePicker {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(coordinator.sourceSelectionMessage ?? "Waiting for macOS…")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else if let message = coordinator.sourceSelectionMessage {
                    Label(
                        message,
                        systemImage: coordinator.hasSelectedSource
                            ? "checkmark.circle.fill"
                            : "info.circle"
                    )
                    .font(.callout.weight(coordinator.hasSelectedSource ? .medium : .regular))
                    .foregroundStyle(coordinator.hasSelectedSource ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }

                LazyVGrid(columns: sourceColumnLayout, alignment: .leading, spacing: 14) {
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
        .disabled(!coordinator.screenCapturePermission.isGranted)
    }

    private var permissionsCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(
                    "Permissions",
                    subtitle: "Reccy checks access before opening the source picker, so capture never fails silently."
                )

                permissionDividerRow(
                    systemImage: "rectangle.inset.filled.and.person.filled",
                    title: "Screen & System Audio Recording",
                    detail: "Authorizes the source you approve in Apple’s picker and its ScreenCaptureKit audio."
                ) {
                    screenPermissionControls
                }

                Divider()

                permissionDividerRow(
                    systemImage: "speaker.wave.2.fill",
                    title: "System Audio",
                    detail: coordinator.settings.includeSystemAudio
                        ? "Enabled for this recording and covered by the source access above."
                        : "Optional and currently disabled for this recording."
                ) {
                    if coordinator.settings.includeSystemAudio {
                        if coordinator.screenCapturePermission.isGranted {
                            Label("Covered", systemImage: "checkmark.circle.fill")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.green)
                        } else {
                            Label("Needs access above", systemImage: "arrow.up.circle.fill")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Label("Off", systemImage: "minus.circle")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                permissionDividerRow(
                    systemImage: "mic.fill",
                    title: "Microphone",
                    detail: coordinator.settings.includeMicrophone
                        ? "Required because microphone recording is enabled."
                        : "Optional until you enable microphone recording."
                ) {
                    microphonePermissionControls
                }

                Label(
                    "‘System Audio Recording Only’ is for audio-only Core Audio taps. Reccy records system audio with the approved ScreenCaptureKit video source, so it does not require that separate entry.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func permissionDividerRow<Controls: View>(
        systemImage: String,
        title: String,
        detail: String,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                controls()
            }
            .frame(minWidth: 210, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var screenPermissionControls: some View {
        switch coordinator.screenCapturePermission {
        case .granted:
            permissionReadyLabel
        case .restartRequired:
            Label("Restart required", systemImage: "arrow.clockwise.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Button("Quit Reccy") { coordinator.quitForPermissionRestart() }
        case .notGranted:
            Button("System Settings") { coordinator.openScreenCapturePrivacySettings() }
            Button("Allow…") { coordinator.requestScreenCapturePermission() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var microphonePermissionControls: some View {
        switch coordinator.microphonePermission {
        case .authorized:
            permissionReadyLabel
        case .notDetermined:
            if coordinator.settings.includeMicrophone {
                Button("Allow…") { coordinator.requestMicrophonePermission() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Allow…") { coordinator.requestMicrophonePermission() }
                    .buttonStyle(.bordered)
            }
        case .denied, .restricted:
            Label("Not allowed", systemImage: "exclamationmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Button("System Settings") { coordinator.openMicrophonePrivacySettings() }
        @unknown default:
            Button("Check Again") { coordinator.refreshPermissionStatus() }
        }
    }

    private var permissionReadyLabel: some View {
        Label("Ready", systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.green)
    }

    private var optionsCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 17) {
                SectionHeading("Capture options")
                LazyVGrid(columns: threeColumnLayout, alignment: .leading, spacing: 18) {
                    optionColumn(title: "Audio", systemImage: "waveform") {
                        optionToggleRow("System audio", isOn: $coordinator.settings.includeSystemAudio)
                        optionToggleRow("Microphone", isOn: $coordinator.settings.includeMicrophone)
                        if coordinator.settings.includeSystemAudio && coordinator.settings.includeMicrophone {
                            Label("Separate editable tracks", systemImage: "timeline.selection")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if coordinator.settings.includeMicrophone {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Microphone input")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("Input", selection: $coordinator.settings.selectedMicrophoneID) {
                                    Text("System Default").tag(String?.none)
                                    ForEach(coordinator.audioInputDevices) { device in
                                        Text(device.name).tag(Optional(device.id))
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    optionColumn(title: "Pointer", systemImage: "cursorarrow.motionlines") {
                        optionToggleRow("Show cursor", isOn: $coordinator.settings.showCursor)
                        optionToggleRow(
                            "Highlight clicks",
                            isOn: $coordinator.settings.showMouseClicks,
                            isDisabled: coordinator.settings.useHDR
                        )
                        if coordinator.settings.useHDR {
                            Text("Click highlights require SDR capture.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    optionColumn(title: "Start", systemImage: "timer") {
                        optionControlRow("Countdown") {
                            Picker("Countdown", selection: $coordinator.settings.countdown) {
                                ForEach(CountdownDelay.allCases) { delay in
                                    Text(delay.title).tag(delay)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 132)
                        }
                        optionToggleRow("Exclude Reccy audio", isOn: $coordinator.settings.excludeOwnAudio)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionToggleRow(
        _ title: String,
        isOn: Binding<Bool>,
        isDisabled: Bool = false
    ) -> some View {
        optionControlRow(title) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isDisabled)
        }
    }

    private func optionControlRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            control()
        }
        .frame(maxWidth: .infinity, minHeight: 26)
    }

    private var outputCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(
                    "Recording quality",
                    subtitle: "The defaults balance sharp text, smooth motion, and compact files."
                )
                LazyVGrid(columns: threeColumnLayout, alignment: .leading, spacing: 18) {
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
                .pickerStyle(.menu)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("HDR10", isOn: $coordinator.settings.useHDR)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .frame(width: 310, alignment: .trailing)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
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
                                    .frame(minWidth: 88)
                            } else {
                                Label("Screenshot", systemImage: "camera")
                                    .frame(minWidth: 88)
                            }
                        }
                        .disabled(!coordinator.hasSelectedSource || coordinator.isCapturingScreenshot)
                    }
                    .frame(width: 310, alignment: .trailing)
                }
            }
        }
    }

    private var recordControls: some View {
        HStack(spacing: 14) {
            Label(
                coordinator.hasSelectedSource
                    ? "\(coordinator.selectedSource?.name ?? coordinator.selectedSourceKind.title) selected"
                    : "1. Choose a source above",
                systemImage: coordinator.hasSelectedSource ? "checkmark.circle.fill" : "1.circle"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(coordinator.hasSelectedSource ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))

            if let url = coordinator.lastRecordingURL {
                ShareLink(item: url) {
                    Label("Share Last Recording", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.large)
                .reccyTooltip("Share last recording")
            }

            if let url = coordinator.lastScreenshotURL {
                ShareLink(item: url) {
                    Label("Share Screenshot", systemImage: "photo")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.large)
                .reccyTooltip("Share last screenshot")
            }

            Spacer()

            Button {
                coordinator.startRecording()
            } label: {
                Label(
                    coordinator.hasSelectedSource ? "2. Start Recording" : "Choose Source",
                    systemImage: coordinator.hasSelectedSource ? "record.circle.fill" : "rectangle.dashed.badge.record"
                )
                .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
        }
        .frame(maxWidth: .infinity)
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
                    if let source = coordinator.selectedSource {
                        Label(source.name, systemImage: source.kind.systemImage)
                            .font(.headline)
                        Text(source.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
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

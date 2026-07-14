import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator
    @EnvironmentObject private var navigation: AppNavigationModel

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
                        if needsPermissionAttention {
                            permissionWarning
                        }
                        sourceCard
                        optionsCard
                        outputCard
                        nativeMediaCard
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
        VStack(alignment: .leading, spacing: 5) {
            Text("Capture your Mac")
                .font(.largeTitle.weight(.bold))
            Text("Native, private, and tuned for excellent quality at sensible file sizes.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var sourceCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(
                    "What do you want to record?",
                    subtitle: "Reccy only sees the source or area you explicitly approve."
                )

                if coordinator.isSelectingSource {
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
        .disabled(coordinator.isSelectingSource)
    }

    private var needsPermissionAttention: Bool {
        needsDirectCaptureAccess
            || (coordinator.settings.includeMicrophone && coordinator.microphonePermission != .authorized)
    }

    private var needsDirectCaptureAccess: Bool {
        coordinator.selectedSourceKind.requiresDirectCapturePermission
            && !coordinator.directCapturePermission.isGranted
    }

    private var permissionWarning: some View {
        HStack(spacing: 13) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("Capture access needs attention")
                    .font(.headline)
                Text(permissionAttentionDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Review Permissions") {
                navigation.openSettings(.permissions)
            }
        }
        .padding(16)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.orange.opacity(0.25), lineWidth: 0.5)
        }
    }

    private var permissionAttentionDetail: String {
        if needsDirectCaptureAccess {
            return coordinator.directCapturePermission == .restartRequired
                ? "Quit and reopen Reccy once to finish enabling direct Portion capture."
                : "Portion uses Reccy’s resizable overlay and needs the one-time Direct Screen & System Audio Access approval."
        }
        return "Microphone access is required because microphone recording is enabled."
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
    private var nativeMediaCard: some View {
        CardContainer {
            VStack(spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.title)
                        .foregroundStyle(.tint)
                        .frame(width: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HDR10 recording")
                            .font(.headline)
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
                recordControlStatus,
                systemImage: recordControlStatusImage
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(recordControlStatusStyle)

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
                performPrimaryRecordAction()
            } label: {
                Label(
                    primaryRecordActionTitle,
                    systemImage: primaryRecordActionImage
                )
                .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
        }
        .frame(maxWidth: .infinity)
    }

    private var recordControlStatus: String {
        if needsDirectCaptureAccess {
            return "Direct Portion access required"
        }
        if coordinator.hasSelectedSource {
            return "\(coordinator.selectedSource?.name ?? coordinator.selectedSourceKind.title) selected"
        }
        return "1. Choose a source above"
    }

    private var recordControlStatusImage: String {
        if needsDirectCaptureAccess { return "exclamationmark.circle.fill" }
        return coordinator.hasSelectedSource ? "checkmark.circle.fill" : "1.circle"
    }

    private var recordControlStatusStyle: AnyShapeStyle {
        if needsDirectCaptureAccess { return AnyShapeStyle(.orange) }
        return coordinator.hasSelectedSource ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary)
    }

    private var primaryRecordActionTitle: String {
        if needsDirectCaptureAccess { return "Review Permissions" }
        return coordinator.hasSelectedSource ? "2. Start Recording" : "Choose Source"
    }

    private var primaryRecordActionImage: String {
        if needsDirectCaptureAccess { return "hand.raised.fill" }
        return coordinator.hasSelectedSource ? "record.circle.fill" : "rectangle.dashed.badge.record"
    }

    private func performPrimaryRecordAction() {
        if needsDirectCaptureAccess {
            navigation.openSettings(.permissions)
        } else if coordinator.hasSelectedSource {
            coordinator.startRecording()
        } else {
            coordinator.chooseSource(coordinator.selectedSourceKind)
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
                    Button(coordinator.state.stopButtonTitle) {
                        coordinator.stopRecording()
                    }
                case .starting:
                    ProgressView("Starting recording…")
                    Button(coordinator.state.stopButtonTitle) {
                        coordinator.stopRecording()
                    }
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
                        Label(coordinator.state.stopButtonTitle, systemImage: "stop.fill")
                            .frame(minWidth: 150)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)

                    Button {
                        coordinator.toggleRecordingPause()
                    } label: {
                        Label(
                            coordinator.state == .paused ? "Resume Recording" : "Pause Recording",
                            systemImage: coordinator.state == .paused ? "play.fill" : "pause.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
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

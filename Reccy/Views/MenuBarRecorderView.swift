import AppKit
import SwiftUI

struct MenuBarRecorderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var coordinator: CaptureCoordinator
    @EnvironmentObject private var editor: TimelineEditorController
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var softwareUpdates: SoftwareUpdateController
    @EnvironmentObject private var transcription: TranscriptionController
    @State private var menuContentHeight: CGFloat = 300

    private let sourceColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                menuContent
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: MenuContentHeightPreferenceKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
            }
            .scrollIndicators(menuContentHeight > 520 ? .visible : .hidden)
            .frame(height: min(menuContentHeight, 520))
            .onPreferenceChange(MenuContentHeightPreferenceKey.self) { height in
                guard height > 0, abs(menuContentHeight - height) > 0.5 else { return }
                menuContentHeight = height
            }

            Divider()
            footer
        }
        .frame(width: 370)
        .background(.regularMaterial)
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if coordinator.state.isRecording {
                activeRecording
            } else {
                idleRecorder
            }

            if !coordinator.library.recordings.isEmpty {
                recentRecordings
            }
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.gradient)
                Image(systemName: "record.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Reccy")
                    .font(.headline)
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if coordinator.state.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                    .shadow(color: .red.opacity(0.6), radius: 4)
                    .accessibilityHidden(true)
            }

            Button {
                showMain(.record)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .reccyAccessibleControl("Open Reccy")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var idleRecorder: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case let .failed(message) = coordinator.state {
                compactNotice(
                    title: "Recording failed",
                    detail: message,
                    systemImage: "exclamationmark.triangle.fill",
                    color: .orange
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("New Recording")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                LazyVGrid(columns: sourceColumns, spacing: 8) {
                    ForEach(CaptureSourceKind.allCases) { kind in
                        sourceButton(kind)
                    }
                }

                cameraOption
            }

            if let source = coordinator.selectedSource {
                selectedSourceCard(source)
            }
        }
    }

    private var cameraOption: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $coordinator.settings.includeCamera) {
                Label("Record camera", systemImage: "video")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.switch)

            if coordinator.settings.includeCamera {
                Picker("Camera source", selection: $coordinator.settings.selectedCameraID) {
                    Text("System Default").tag(String?.none)
                    ForEach(coordinator.cameraInputDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)

                Label("Saved as a separate editable video track", systemImage: "rectangle.on.rectangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    private func compactNotice(
        title: String,
        detail: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sourceButton(_ kind: CaptureSourceKind) -> some View {
        let needsDirectAccess = kind.requiresDirectCapturePermission
            && !coordinator.directCapturePermission.isGranted
        return Button {
            chooseSource(kind)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(coordinator.selectedSourceKind == kind ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(kind.title)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                if needsDirectAccess {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if coordinator.hasSelectedSource, coordinator.selectedSourceKind == kind {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                if coordinator.hasSelectedSource, coordinator.selectedSourceKind == kind {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            needsDirectAccess
                ? "Review permissions for \(kind.title) capture"
                : "Choose \(kind.title)"
        )
        .accessibilityHint(
            needsDirectAccess
                ? "Portion capture requires Direct Screen & System Audio Access"
                : ""
        )
    }

    private func selectedSourceCard(_ source: CaptureSourceDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: source.kind.systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(source.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    coordinator.clearSelectedSource()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .reccyAccessibleControl(
                    "Clear Selected Source",
                    help: "Discard the selected capture source"
                )
            }

            if capturePermissionNeedsAttention {
                menuPermissionReadiness
            } else if captureTranscriptionNeedsAttention {
                menuTranscriptionReadiness
            }

            HStack(spacing: 8) {
                if canStartFromMenu {
                    Button {
                        coordinator.startRecording()
                        dismiss()
                    } label: {
                        Label("Start Recording", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

                Button {
                    coordinator.captureScreenshot()
                    dismiss()
                } label: {
                    if canStartFromMenu {
                        Image(systemName: "camera")
                            .frame(width: 18, height: 18)
                    } else {
                        Label("Capture Screenshot", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.isCapturingScreenshot)
                .reccyAccessibleControl("Capture Screenshot", help: "Capture screenshot")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
    }

    private var captureTranscriptionConfiguration: CaptureTranscriptionConfiguration {
        transcription.makeCaptureConfiguration(
            systemAudio: coordinator.settings.includeSystemAudio,
            microphone: coordinator.settings.includeMicrophone
        )
    }

    private var captureTranscriptionNeedsAttention: Bool {
        captureTranscriptionConfiguration.isEnabled && !transcription.captureReadiness.isReady
    }

    private var capturePermissionNeedsAttention: Bool {
        coordinator.capturePermissionReadiness.needsAttention
    }

    private var canStartFromMenu: Bool {
        coordinator.canStartRecording
    }

    private var menuPermissionReadiness: some View {
        HStack(alignment: .top, spacing: 8) {
            Label(
                coordinator.capturePermissionReadiness.detail,
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Review Permissions") {
                navigation.openSettings(.permissions)
                showMain(.settings)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var menuTranscriptionReadiness: some View {
        switch transcription.captureReadiness {
        case .preparing(let update):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(update.detail ?? "Preparing transcription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        case .unavailable(let message):
            HStack(alignment: .top, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Transcription Settings") {
                    navigation.openSettings(.transcription)
                    showMain(.settings)
                }
                .controlSize(.small)
            }
        case .disabled:
            HStack(spacing: 8) {
                Label(
                    "Prepare the selected transcription engine before recording.",
                    systemImage: "waveform.badge.magnifyingglass"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Prepare") {
                    transcription.prepareSelectedCaptureEngine()
                }
                .controlSize(.small)
            }
        case .ready:
            EmptyView()
        }
    }

    private var activeRecording: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(activeTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .textCase(.uppercase)
                    Text(activeDuration)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(coordinator.liveStorageStatus)
                        .font(.subheadline.monospacedDigit().weight(.medium))
                }
            }

            Label(
                coordinator.selectedSource?.name ?? coordinator.selectedSourceKind.title,
                systemImage: coordinator.selectedSourceKind.systemImage
            )
            .font(.subheadline.weight(.medium))
            .lineLimit(1)

            if coordinator.settings.includeCamera {
                Label(coordinator.selectedCameraName, systemImage: "video.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if coordinator.settings.includeSystemAudio || coordinator.settings.includeMicrophone {
                compactAudioMeters
            }

            HStack(spacing: 8) {
                Button {
                    coordinator.toggleRecordingPause()
                } label: {
                    Image(systemName: coordinator.state == .paused ? "play.fill" : "pause.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.state != .recording && coordinator.state != .paused)
                .reccyAccessibleControl(
                    coordinator.state == .paused ? "Resume Recording" : "Pause Recording"
                )

                Button {
                    coordinator.stopRecording()
                } label: {
                    Label(coordinator.state.stopButtonTitle, systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(coordinator.state == .stopping)

                Button {
                    showMain(.monitor)
                } label: {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .reccyAccessibleControl("Open Recording Monitor", help: "Open recording monitor")
            }
        }
        .padding(13)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.red.opacity(0.22), lineWidth: 1)
        }
    }

    private var compactAudioMeters: some View {
        VStack(spacing: 8) {
            if coordinator.settings.includeSystemAudio {
                compactMeter(
                    title: "System",
                    level: coordinator.systemAudioLevel,
                    samples: coordinator.systemAudioHistory,
                    color: .teal
                )
            }
            if coordinator.settings.includeMicrophone {
                compactMeter(
                    title: "Mic",
                    level: coordinator.microphoneAudioLevel,
                    samples: coordinator.microphoneAudioHistory,
                    color: .orange
                )
            }
        }
    }

    private func compactMeter(
        title: String,
        level: Double,
        samples: [Double],
        color: Color
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            ReccyLiveWaveform(samples: Array(samples.suffix(120)), color: color, isEnabled: true)
                .frame(height: 24)
                .accessibilityHidden(true)
            Text(levelText(level))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 43, alignment: .trailing)
                .accessibilityLabel("\(title) audio level \(levelText(level))")
        }
    }

    private var recentRecordings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            VStack(spacing: 2) {
                ForEach(coordinator.library.recordings.prefix(3)) { item in
                    Button {
                        openEditor(item)
                    } label: {
                        HStack(spacing: 9) {
                            RecordingThumbnail(
                                image: coordinator.library.thumbnail(for: item),
                                size: CGSize(width: 54, height: 32),
                                cornerRadius: 5
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text("\(item.formattedDuration) · \(item.formattedSize) · \(item.sourceKindTitle)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            footerButton("Open Library", systemImage: "rectangle.stack") { showMain(.library) }
            footerButton("Open Folder", systemImage: "folder") {
                coordinator.library.revealDirectory()
                dismiss()
            }
            .disabled(!coordinator.library.availability.isAvailable)
            footerButton("Settings", systemImage: "gearshape") {
                navigation.openSettings(.general)
                showMain(.settings)
            }
            footerButton("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                softwareUpdates.checkForUpdates()
                dismiss()
            }

            Spacer(minLength: 2)

            footerButton("Quit Reccy", systemImage: "power", role: .destructive) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func footerButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .reccyAccessibleControl(title)
    }

    private var statusSubtitle: String {
        switch coordinator.state {
        case .idle: "Ready to capture"
        case .sourceSelected: coordinator.selectedSource?.name ?? "Source selected"
        case let .countingDown(seconds): "Starting in \(seconds) seconds"
        case .starting: "Preparing capture"
        case .recording: coordinator.selectedSource?.name ?? "Recording"
        case .paused: "Recording paused"
        case .stopping: "Finishing recording"
        case .failed: "Needs attention"
        }
    }

    private var activeTitle: String {
        switch coordinator.state {
        case .countingDown: "Starting"
        case .starting: "Preparing"
        case .stopping: "Finishing"
        case .paused: "Paused"
        default: "Recording"
        }
    }

    private var activeDuration: String {
        if case let .countingDown(seconds) = coordinator.state {
            return "00:00:\(String(format: "%02d", seconds))"
        }
        return coordinator.formattedDuration
    }

    private func chooseSource(_ kind: CaptureSourceKind) {
        guard !kind.requiresDirectCapturePermission || coordinator.directCapturePermission.isGranted else {
            navigation.openSettings(.permissions)
            showMain(.settings)
            return
        }
        coordinator.chooseSource(kind)
        dismiss()
    }

    private func openEditor(_ item: RecordingItem) {
        showMain(.editor)
        Task { await editor.open(item) }
    }

    private func showMain(_ section: AppSection) {
        navigation.section = section
        dismiss()
        openWindow(id: "main")
        NSApp.activate()
    }

    private func levelText(_ level: Double) -> String {
        guard level > 0.001 else { return "−∞ dB" }
        return String(format: "%+.0f dB", level * 60 - 60)
    }
}

private struct MenuContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 300

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

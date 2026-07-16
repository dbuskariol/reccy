import AVFoundation
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var coordinator: CaptureCoordinator
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var softwareUpdates: SoftwareUpdateController
    @EnvironmentObject private var transcription: TranscriptionController

    var body: some View {
        VStack(spacing: 0) {
            settingsNavigation
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pageHeader
                    categoryContent
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Settings")
        .onAppear {
            coordinator.refreshPermissionStatus()
            preferences.refreshLaunchAtLoginStatus()
            transcription.refreshCapabilities()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            coordinator.refreshPermissionStatus()
            preferences.refreshLaunchAtLoginStatus()
            transcription.refreshCapabilities()
        }
    }

    private var settingsNavigation: some View {
        HStack(spacing: 6) {
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    navigation.settingsCategory = category
                } label: {
                    Label(category.title, systemImage: category.systemImage)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .background(
                            navigation.settingsCategory == category
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(navigation.settingsCategory == category ? .primary : .secondary)
                .accessibilityAddTraits(
                    navigation.settingsCategory == category ? .isSelected : []
                )
                .reccyTooltip(category.title)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
        .background(.bar)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(navigation.settingsCategory.title)
                .font(.largeTitle.weight(.bold))
            Text(categorySubtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var categorySubtitle: String {
        switch navigation.settingsCategory {
        case .general: "Choose how Reccy behaves and where it keeps your recordings."
        case .recording: "Set sensible defaults for every new capture."
        case .transcription: "Create private, searchable transcripts entirely on this Mac."
        case .permissions: "Review the macOS access required by the capture options you use."
        case .shortcuts: "Record global shortcuts without granting Accessibility access."
        case .updates: "Keep Reccy current through signed, verified updates."
        }
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch navigation.settingsCategory {
        case .general:
            generalSettings
        case .recording:
            recordingSettings
        case .transcription:
            transcriptionSettings
        case .permissions:
            permissionSettings
        case .shortcuts:
            shortcutSettings
        case .updates:
            updateSettings
        }
    }

    private var generalSettings: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "App") {
                SettingsToggleRow(
                    title: "Show Reccy in the menu bar",
                    detail: "Start captures and monitor an active recording without opening the main window.",
                    systemImage: "menubar.rectangle",
                    isOn: $preferences.showMenuBarExtra
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Show button tooltips",
                    detail: "Display Reccy’s fast, compact explanations when hovering over icon buttons.",
                    systemImage: "character.bubble",
                    isOn: $preferences.showTooltips
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Launch at login",
                    detail: "Make capture controls available as soon as you sign in.",
                    systemImage: "power",
                    isOn: Binding(
                        get: { preferences.launchAtLoginEnabled },
                        set: { preferences.setLaunchAtLogin($0) }
                    )
                )
                if let error = preferences.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.leading, 42)
                }
                SettingsDivider()
                SettingsValueRow(
                    title: "After recording",
                    detail: "Choose where Reccy takes you when a capture finishes.",
                    systemImage: "arrow.turn.down.right"
                ) {
                    Picker("After recording", selection: $preferences.completionDestination) {
                        ForEach(RecordingCompletionDestination.allCases) { destination in
                            Text(destination.title).tag(destination)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
            }

            SettingsCard(title: "Storage") {
                SettingsValueRow(
                    title: "Recording location",
                    detail: coordinator.library.directoryURL.path(percentEncoded: false),
                    systemImage: "internaldrive"
                ) {
                    HStack(spacing: 8) {
                        Button("Choose…") { coordinator.chooseOutputFolder() }
                        Button {
                            coordinator.library.revealDirectory()
                        } label: {
                            Image(systemName: "folder")
                                .frame(width: 16, height: 16)
                        }
                        .reccyAccessibleControl("Open Recording Folder")
                        .disabled(!coordinator.library.availability.isAvailable)
                    }
                }
                if coordinator.settings.outputFolderPath != nil {
                    SettingsDivider()
                    SettingsActionRow(
                        title: "Restore default location",
                        detail: "Save future recordings in Movies/Reccy.",
                        systemImage: "arrow.counterclockwise"
                    ) {
                        Button("Restore") { coordinator.resetOutputFolder() }
                    }
                }
            }
        }
    }

    private var recordingSettings: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Video") {
                recordingPickerRow(
                    title: "Resolution",
                    detail: "Limit output dimensions while preserving the source aspect ratio.",
                    systemImage: "rectangle.inset.filled",
                    selection: $coordinator.settings.resolution,
                    values: CaptureResolution.allCases
                ) { "\($0.title) — \($0.detail)" }
                SettingsDivider()
                recordingPickerRow(
                    title: "Frame rate",
                    detail: "30 fps is the best balance for most screen recordings.",
                    systemImage: "gauge.with.dots.needle.33percent",
                    selection: $coordinator.settings.frameRate,
                    values: CaptureFrameRate.allCases
                ) { $0.title }
                SettingsDivider()
                recordingPickerRow(
                    title: "Format",
                    detail: "Efficient HEVC keeps text sharp at smaller file sizes.",
                    systemImage: "film.stack",
                    selection: $coordinator.settings.recordingPreset,
                    values: RecordingPreset.available(isHDR: coordinator.settings.useHDR)
                ) { "\($0.title) — \($0.detail)" }
                SettingsDivider()
                recordingPickerRow(
                    title: "Countdown",
                    detail: "Wait before recording begins after you press Start.",
                    systemImage: "timer",
                    selection: $coordinator.settings.countdown,
                    values: CountdownDelay.allCases
                ) { $0.title }
                SettingsDivider()
                SettingsToggleRow(
                    title: "HDR10 recording",
                    detail: "Use ScreenCaptureKit’s HDR preset with SDR-compatible playback.",
                    systemImage: "sun.max.trianglebadge.exclamationmark",
                    isOn: Binding(
                        get: { coordinator.settings.useHDR },
                        set: { coordinator.setHDREnabled($0) }
                    )
                )
            }

            SettingsCard(title: "Camera") {
                SettingsToggleRow(
                    title: "Record camera",
                    detail: "Keep camera video as a separate track for positioning and resizing in the editor.",
                    systemImage: "video",
                    isOn: $coordinator.settings.includeCamera
                )
                if coordinator.settings.includeCamera {
                    SettingsDivider()
                    SettingsValueRow(
                        title: "Camera source",
                        detail: "Choose a built-in, external, Desk View, or Continuity Camera.",
                        systemImage: "web.camera"
                    ) {
                        Picker("Camera", selection: $coordinator.settings.selectedCameraID) {
                            Text("System Default").tag(String?.none)
                            ForEach(coordinator.cameraInputDevices) { device in
                                Text(device.name).tag(Optional(device.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 190)
                    }
                }
            }

            SettingsCard(title: "Audio") {
                SettingsToggleRow(
                    title: "Record system audio",
                    detail: "Keep system audio as an independent, editable timeline track.",
                    systemImage: "speaker.wave.2",
                    isOn: $coordinator.settings.includeSystemAudio
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Record microphone",
                    detail: "Keep microphone audio independent from video and system audio.",
                    systemImage: "mic",
                    isOn: $coordinator.settings.includeMicrophone
                )
                if coordinator.settings.includeMicrophone {
                    SettingsDivider()
                    SettingsValueRow(
                        title: "Microphone input",
                        detail: "Choose a device or follow the current system default.",
                        systemImage: "waveform"
                    ) {
                        Picker("Microphone", selection: $coordinator.settings.selectedMicrophoneID) {
                            Text("System Default").tag(String?.none)
                            ForEach(coordinator.audioInputDevices) { device in
                                Text(device.name).tag(Optional(device.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 190)
                    }
                }
                SettingsDivider()
                SettingsToggleRow(
                    title: "Exclude Reccy audio",
                    detail: "Prevent preview and monitoring sounds from feeding back into the capture.",
                    systemImage: "speaker.slash",
                    isOn: $coordinator.settings.excludeOwnAudio
                )
            }

            SettingsCard(title: "Pointer & Screenshots") {
                SettingsToggleRow(
                    title: "Show pointer",
                    detail: "Include the pointer in recordings and screenshots.",
                    systemImage: "cursorarrow",
                    isOn: $coordinator.settings.showCursor
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Highlight clicks",
                    detail: coordinator.settings.useHDR
                        ? "Click highlighting is unavailable during HDR capture."
                        : "Show native click feedback in SDR recordings.",
                    systemImage: "cursorarrow.click.2",
                    isOn: $coordinator.settings.showMouseClicks,
                    isDisabled: coordinator.settings.useHDR
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Start with mouse-follow zoom",
                    detail: "Begin each recording magnified around the pointer; toggles become editable effect segments.",
                    systemImage: "cursorarrow.motionlines",
                    isOn: $coordinator.settings.startsWithMouseFollowZoom
                )
                SettingsDivider()
                SettingsValueRow(
                    title: "Mouse-follow zoom level",
                    detail: "The default magnification for new live and editor-created zoom segments.",
                    systemImage: "plus.magnifyingglass"
                ) {
                    Picker("Zoom level", selection: $coordinator.settings.mouseFollowZoomLevel) {
                        ForEach(MouseFollowZoomLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 96)
                }
                SettingsDivider()
                SettingsValueRow(
                    title: "Screenshot defaults",
                    detail: "HEIC provides excellent quality at compact sizes.",
                    systemImage: "camera"
                ) {
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
                    }
                }
            }
        }
    }

    private var transcriptionSettings: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Transcription Engine") {
                SettingsValueRow(
                    title: "Default engine",
                    detail: transcription.provider.detail,
                    systemImage: transcription.provider.systemImage
                ) {
                    Picker("Engine", selection: $transcription.provider) {
                        ForEach(TranscriptionProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }
                SettingsDivider()
                SettingsValueRow(
                    title: "Spoken language",
                    detail: "Used for both live and post-recording transcription.",
                    systemImage: "globe"
                ) {
                    Picker("Language", selection: $transcription.localeIdentifier) {
                        if !transcription.supportedLocales.contains(where: { $0.identifier == transcription.localeIdentifier }) {
                            Text(transcription.localizedLocaleName(Locale(identifier: transcription.localeIdentifier)))
                                .tag(transcription.localeIdentifier)
                        }
                        ForEach(transcription.supportedLocales, id: \.identifier) { locale in
                            Text(transcription.localizedLocaleName(locale)).tag(locale.identifier)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 210)
                }
            }

            SettingsCard(title: "Recording Workflow") {
                SettingsToggleRow(
                    title: "Enable transcription",
                    detail: "Allow live and post-recording transcription during capture.",
                    systemImage: "captions.bubble",
                    isOn: $transcription.isEnabledForCapture
                )
                if transcription.isEnabledForCapture {
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Create post-recording transcript",
                        detail: "Create a source-aligned transcript automatically after every capture.",
                        systemImage: "text.badge.checkmark",
                        isOn: $transcription.automaticallyTranscribe
                    )
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Show live transcript",
                        detail: "Display finalized and in-progress words in Monitor without affecting capture performance.",
                        systemImage: "captions.bubble",
                        isOn: $transcription.showLiveTranscript
                    )
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "System audio",
                        detail: "Transcribe remote speakers and app audio on its independent source track.",
                        systemImage: "speaker.wave.2",
                        isOn: $transcription.transcribeSystemAudio
                    )
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Microphone & voiceover",
                        detail: "Transcribe your microphone as a separate editable source track.",
                        systemImage: "mic",
                        isOn: $transcription.transcribeMicrophone
                    )
                }
            }

            SettingsCard(title: "Apple Speech") {
                SettingsActionRow(
                    title: appleSpeechStatusTitle,
                    detail: "Apple manages the language model. Audio and transcripts remain on this Mac.",
                    systemImage: "apple.intelligence"
                ) {
                    switch transcription.appleAvailability {
                    case .ready:
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .requiresDownload:
                        Button("Download") { transcription.prepareAppleSpeech() }
                            .buttonStyle(.borderedProminent)
                    case .unavailable:
                        Button("Check Again") { transcription.refreshCapabilities() }
                    }
                }
                if let progress = transcription.applePreparationProgress {
                    SettingsDivider()
                    modelProgressRow(progress.fractionCompleted, detail: progress.detail ?? "Preparing Apple Speech")
                }
                if let error = transcription.applePreparationError {
                    SettingsDivider()
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            SettingsCard(title: "WhisperKit Models") {
                SettingsValueRow(
                    title: "Model",
                    detail: whisperModelDetail,
                    systemImage: "shippingbox"
                ) {
                    Picker("WhisperKit model", selection: $transcription.whisperModelIdentifier) {
                        ForEach(transcription.availableWhisperModels, id: \.self) { identifier in
                            Text(transcription.whisperModelDisplayName(identifier)).tag(identifier)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 240)
                }
                SettingsDivider()
                SettingsActionRow(
                    title: transcription.isWhisperModelInstalled(transcription.whisperModelIdentifier)
                        ? "Model installed"
                        : "Download selected model",
                    detail: "WhisperKit 1.0 runs OpenAI Whisper locally through Core ML on Apple silicon.",
                    systemImage: transcription.isWhisperModelInstalled(transcription.whisperModelIdentifier)
                        ? "checkmark.circle.fill"
                        : "arrow.down.circle"
                ) {
                    if transcription.isWhisperModelInstalled(transcription.whisperModelIdentifier) {
                        Button("Remove", role: .destructive) {
                            transcription.removeWhisperModel(transcription.whisperModelIdentifier)
                        }
                    } else {
                        Button("Download") { transcription.downloadSelectedWhisperModel() }
                            .buttonStyle(.borderedProminent)
                            .disabled(transcription.whisperDownloadProgress != nil)
                    }
                }
                if let progress = transcription.whisperDownloadProgress {
                    SettingsDivider()
                    modelProgressRow(progress, detail: "Downloading model")
                }
                if let error = transcription.whisperModelError {
                    SettingsDivider()
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Label(
                "Reccy never sends recordings, live audio, models, or transcript text to a cloud transcription service.",
                systemImage: "lock.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var appleSpeechStatusTitle: String {
        switch transcription.appleAvailability {
        case .ready: "Language model ready"
        case .requiresDownload: "Language model required"
        case .unavailable(let reason): reason
        }
    }

    private var whisperModelDetail: String {
        guard let record = transcription.installedWhisperModels.first(where: {
            $0.id == transcription.whisperModelIdentifier
        }) else {
            if transcription.whisperModelIdentifier == WhisperModelManager.defaultModel {
                return "Fastest model and the default for new recordings. Downloaded only when requested."
            }
            if transcription.whisperModelIdentifier == WhisperModelManager.recommendedModel {
                return "Recommended for maximum multilingual accuracy. Downloaded only when requested."
            }
            return "Downloaded only when requested."
        }
        return "Installed · \(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file))"
    }

    private func modelProgressRow(_ fraction: Double?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(detail)
                    .font(.callout.weight(.medium))
                Spacer()
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
        }
        .padding(.leading, 42)
    }

    private var permissionSettings: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Capture Access") {
                SettingsPermissionRow(
                    title: "Direct Screen & System Audio Access",
                    detail: "Required for Portion because Reccy draws the resizable selection overlay. macOS describes this as bypassing the private window picker. Display, Application, and Window use Apple’s picker instead.",
                    systemImage: "rectangle.inset.filled.and.person.filled",
                    status: directCapturePermissionPresentation
                ) {
                    directCapturePermissionActions
                }
                SettingsDivider()
                SettingsPermissionRow(
                    title: "Microphone",
                    detail: "Only required when microphone recording or editor voiceover is enabled.",
                    systemImage: "mic.fill",
                    status: microphonePermissionPresentation
                ) {
                    microphonePermissionActions
                }
                SettingsDivider()
                SettingsPermissionRow(
                    title: "Camera",
                    detail: "Only required when a separate camera video track is enabled.",
                    systemImage: "video.fill",
                    status: cameraPermissionPresentation
                ) {
                    cameraPermissionActions
                }
            }

            if let outputFolderPath = coordinator.settings.outputFolderPath {
                SettingsCard(title: "Storage Access") {
                    SettingsPermissionRow(
                        title: "Custom recording folder",
                        detail: recordingFolderPermissionDetail(for: outputFolderPath),
                        systemImage: "folder.badge.gearshape",
                        status: .managedByMacOS
                    ) {
                        Button("System Settings") {
                            coordinator.openFilesAndFoldersPrivacySettings()
                        }
                    }
                }
            }

            CardContainer {
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "speaker.wave.2.badge.checkmark")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("System audio follows capture access")
                            .font(.headline)
                        Text("Reccy records system audio with the selected source. Picker captures are approved in Apple’s picker; Portion uses the access above. The separate “System Audio Recording Only” list does not apply.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)

        }
        .accessibilityElement(children: .contain)
    }

    private var shortcutSettings: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Global Recording Shortcuts") {
                ForEach(Array(ReccyGlobalShortcut.allCases.enumerated()), id: \.element.id) { index, shortcut in
                    SettingsValueRow(
                        title: shortcut.title,
                        detail: shortcutDetail(shortcut),
                        systemImage: shortcutSystemImage(shortcut)
                    ) {
                        KeyboardShortcuts.Recorder(for: shortcut.name)
                            .accessibilityLabel("\(shortcut.title) shortcut")
                    }
                    if index < ReccyGlobalShortcut.allCases.count - 1 {
                        SettingsDivider()
                    }
                }
            }

            SettingsCard(title: "Editor Shortcuts") {
                Text("Available whenever the timeline editor is active.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Divider()
                editorShortcutRow("Play or pause", keys: "Space", systemImage: "playpause")
                SettingsDivider()
                editorShortcutRow("Previous frame", keys: "⌃←", systemImage: "backward.frame.fill")
                SettingsDivider()
                editorShortcutRow("Next frame", keys: "⌃→", systemImage: "forward.frame.fill")
                SettingsDivider()
                editorShortcutRow("Nudge selected clip earlier", keys: "⌥←", systemImage: "arrow.left.to.line")
                SettingsDivider()
                editorShortcutRow("Nudge selected clip later", keys: "⌥→", systemImage: "arrow.right.to.line")
                SettingsDivider()
                editorShortcutRow("Split selected clip", keys: "⌘B", systemImage: "scissors")
                SettingsDivider()
                editorShortcutRow("Split all tracks", keys: "⇧⌘B", systemImage: "timeline.selection")
                SettingsDivider()
                editorShortcutRow("Delete selected clip", keys: "⌫", systemImage: "trash")
                SettingsDivider()
                editorShortcutRow("Delete and close gap", keys: "⌘⌫", systemImage: "arrow.left.and.right")
            }

            Label(
                "Global shortcuts are optional and stored by the KeyboardShortcuts framework. Reccy warns about conflicts and does not require Accessibility permission.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var updateSettings: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Automatic Updates") {
                SettingsToggleRow(
                    title: "Automatically check for updates",
                    detail: "Securely check the Reccy release feed in the background.",
                    systemImage: "arrow.triangle.2.circlepath",
                    isOn: Binding(
                        get: { softwareUpdates.automaticallyChecksForUpdates },
                        set: { softwareUpdates.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                if softwareUpdates.automaticallyChecksForUpdates {
                    SettingsDivider()
                    SettingsValueRow(
                        title: "Check frequency",
                        detail: "How often Reccy checks the signed update feed.",
                        systemImage: "calendar.badge.clock"
                    ) {
                        Picker(
                            "Frequency",
                            selection: Binding(
                                get: { softwareUpdates.updateCheckInterval },
                                set: { softwareUpdates.setUpdateCheckInterval($0) }
                            )
                        ) {
                            ForEach(AppUpdateCheckInterval.allCases) { interval in
                                Text(interval.title).tag(interval)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }
                    if softwareUpdates.allowsAutomaticUpdates {
                        SettingsDivider()
                        SettingsToggleRow(
                            title: "Download updates automatically",
                            detail: "Prepare verified updates so they are ready when you quit Reccy.",
                            systemImage: "arrow.down.circle",
                            isOn: Binding(
                                get: { softwareUpdates.automaticallyDownloadsUpdates },
                                set: { softwareUpdates.setAutomaticallyDownloadsUpdates($0) }
                            )
                        )
                    }
                }
            }

            SettingsCard(title: "Current Version") {
                SettingsActionRow(
                    title: appVersion,
                    detail: "Updates are signed and verified by Sparkle before installation.",
                    systemImage: "app.badge.checkmark"
                ) {
                    Button("Check Now") { softwareUpdates.checkForUpdates() }
                        .disabled(!softwareUpdates.canCheckForUpdates)
                }
            }
        }
    }

    private func recordingPickerRow<Value: Hashable & Identifiable, Values: RandomAccessCollection>(
        title: String,
        detail: String,
        systemImage: String,
        selection: Binding<Value>,
        values: Values,
        label: @escaping (Value) -> String
    ) -> some View where Values.Element == Value {
        SettingsValueRow(title: title, detail: detail, systemImage: systemImage) {
            Picker(title, selection: selection) {
                ForEach(values) { value in
                    Text(label(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 220)
        }
    }

    private var directCapturePermissionPresentation: PermissionPresentation {
        switch coordinator.directCapturePermission {
        case .granted: .ready
        case .restartRequired: .restartRequired
        case .notGranted: .notAllowed
        }
    }

    private var microphonePermissionPresentation: PermissionPresentation {
        switch coordinator.microphonePermission {
        case .authorized: .ready
        case .notDetermined: .notRequested
        case .denied, .restricted: .notAllowed
        @unknown default: .notAllowed
        }
    }

    private var cameraPermissionPresentation: PermissionPresentation {
        switch coordinator.cameraPermission {
        case .authorized: .ready
        case .notDetermined: .notRequested
        case .denied, .restricted: .notAllowed
        @unknown default: .notAllowed
        }
    }

    private func recordingFolderPermissionDetail(for path: String) -> String {
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return "macOS manages access to your chosen “\(name)” folder and may ask once if it’s protected."
    }

    @ViewBuilder
    private var directCapturePermissionActions: some View {
        switch coordinator.directCapturePermission {
        case .granted:
            EmptyView()
        case .restartRequired:
            Button("Quit Reccy") { coordinator.quitForPermissionRestart() }
        case .notGranted:
            Button("System Settings") { coordinator.openScreenCapturePrivacySettings() }
            Button("Allow…") { coordinator.requestDirectCapturePermission() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var microphonePermissionActions: some View {
        switch coordinator.microphonePermission {
        case .authorized:
            EmptyView()
        case .notDetermined:
            Button("Allow…") { coordinator.requestMicrophonePermission() }
                .buttonStyle(.borderedProminent)
        case .denied, .restricted:
            Button("System Settings") { coordinator.openMicrophonePrivacySettings() }
        @unknown default:
            Button("Check Again") { coordinator.refreshPermissionStatus() }
        }
    }

    @ViewBuilder
    private var cameraPermissionActions: some View {
        switch coordinator.cameraPermission {
        case .authorized:
            EmptyView()
        case .notDetermined:
            Button("Allow…") { coordinator.requestCameraPermission() }
                .buttonStyle(.borderedProminent)
        case .denied, .restricted:
            Button("System Settings") { coordinator.openCameraPrivacySettings() }
        @unknown default:
            Button("Check Again") { coordinator.refreshPermissionStatus() }
        }
    }

    private func shortcutDetail(_ shortcut: ReccyGlobalShortcut) -> String {
        switch shortcut {
        case .toggleRecording: "Starts with the current source, or stops the active recording."
        case .toggleRecordingPause: "Pauses or resumes writing while keeping the live monitor available."
        case .toggleMouseFollowZoom: "Starts or ends an editable mouse-follow zoom segment during recording."
        case .chooseDisplay: "Open the native picker for an entire display."
        case .choosePortion: "Choose a display, then drag out the exact capture area."
        case .chooseApplication: "Open the native picker for all windows from one app."
        case .chooseWindow: "Open the native picker for one window."
        case .captureScreenshot: "Save a screenshot of the currently selected source."
        }
    }

    private func shortcutSystemImage(_ shortcut: ReccyGlobalShortcut) -> String {
        switch shortcut {
        case .toggleRecording: "record.circle"
        case .toggleRecordingPause: "pause.circle"
        case .toggleMouseFollowZoom: "cursorarrow.motionlines"
        case .chooseDisplay: "display"
        case .choosePortion: "viewfinder.rectangular"
        case .chooseApplication: "macwindow.on.rectangle"
        case .chooseWindow: "macwindow"
        case .captureScreenshot: "camera"
        }
    }

    private func editorShortcutRow(_ title: String, keys: String, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Spacer()
            Text(keys)
                .font(.callout.monospaced().weight(.semibold))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.headline)
                content
            }
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 42)
    }
}

private struct SettingsRowDescription: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsValueRow<Control: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let control: Control

    init(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 14) {
            SettingsRowDescription(title: title, detail: detail, systemImage: systemImage)
            control
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let systemImage: String
    @Binding var isOn: Bool
    var isDisabled = false

    var body: some View {
        SettingsValueRow(title: title, detail: detail, systemImage: systemImage) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .disabled(isDisabled)
        }
    }
}

private struct SettingsActionRow<Control: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let control: Control

    init(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.control = control()
    }

    var body: some View {
        SettingsValueRow(title: title, detail: detail, systemImage: systemImage) {
            control
        }
    }
}

private enum PermissionPresentation {
    case ready
    case notRequested
    case notAllowed
    case restartRequired
    case managedByMacOS

    var title: String {
        switch self {
        case .ready: "Ready"
        case .notRequested: "Not requested"
        case .notAllowed: "Not allowed"
        case .restartRequired: "Restart required"
        case .managedByMacOS: "Managed by macOS"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .notRequested: "circle.dashed"
        case .notAllowed: "exclamationmark.circle.fill"
        case .restartRequired: "arrow.clockwise.circle.fill"
        case .managedByMacOS: "gearshape.circle"
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .notRequested, .managedByMacOS: .secondary
        case .notAllowed, .restartRequired: .orange
        }
    }
}

private struct SettingsPermissionRow<Actions: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let status: PermissionPresentation
    let actions: Actions

    init(
        title: String,
        detail: String,
        systemImage: String,
        status: PermissionPresentation,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.status = status
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 12) {
                SettingsRowDescription(title: title, detail: detail, systemImage: systemImage)
                Label(status.title, systemImage: status.systemImage)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(status.color)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(status.title)")
            .accessibilityHint(detail)
            actions
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

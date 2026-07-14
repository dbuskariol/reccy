import AVFoundation
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var coordinator: CaptureCoordinator
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var softwareUpdates: SoftwareUpdateController

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
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Settings")
        .onAppear {
            coordinator.refreshPermissionStatus()
            preferences.refreshLaunchAtLoginStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            coordinator.refreshPermissionStatus()
            preferences.refreshLaunchAtLoginStatus()
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
                        .reccyTooltip("Open recording folder")
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
                    values: RecordingPreset.allCases
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
                    isOn: $coordinator.settings.useHDR
                )
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

    private var permissionSettings: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Capture Access") {
                SettingsPermissionRow(
                    title: "Screen & System Audio Recording",
                    detail: "Required for every capture source. Portion uses this permission too; it has no separate grant.",
                    systemImage: "rectangle.inset.filled.and.person.filled",
                    status: screenPermissionPresentation
                ) {
                    screenPermissionActions
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
            }

            SettingsCard(title: "Storage Access") {
                SettingsPermissionRow(
                    title: "Files & Folders",
                    detail: recordingFolderPermissionDetail,
                    systemImage: "folder.badge.gearshape",
                    status: coordinator.settings.outputFolderPath == nil
                        ? .notRequired
                        : .managedByMacOS
                ) {
                    Button("System Settings") {
                        coordinator.openFilesAndFoldersPrivacySettings()
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
                        Text("System audio uses the selected screen source")
                            .font(.headline)
                        Text("Reccy captures system audio through ScreenCaptureKit, covered by Screen & System Audio Recording above. macOS’s separate “System Audio Recording Only” list is for Core Audio process taps and is not required for Reccy’s synchronized video captures.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Button {
                    coordinator.refreshPermissionStatus()
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                Spacer()
                Text("Permission changes are refreshed whenever Reccy becomes active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
                    }
                    if index < ReccyGlobalShortcut.allCases.count - 1 {
                        SettingsDivider()
                    }
                }
            }

            SettingsCard(title: "Editor Shortcuts") {
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

            SettingsCard(title: "Reccy") {
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

    private var screenPermissionPresentation: PermissionPresentation {
        switch coordinator.screenCapturePermission {
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

    private var recordingFolderPermissionDetail: String {
        if let path = coordinator.settings.outputFolderPath {
            let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
            return "macOS manages access to your chosen “\(name)” folder and may ask once if it’s protected."
        }
        return "Default Movies/Reccy needs no extra access. macOS asks only if you choose a protected folder."
    }

    @ViewBuilder
    private var screenPermissionActions: some View {
        switch coordinator.screenCapturePermission {
        case .granted:
            EmptyView()
        case .restartRequired:
            Button("Quit Reccy") { coordinator.quitForPermissionRestart() }
        case .notGranted:
            Button("System Settings") { coordinator.openScreenCapturePrivacySettings() }
            Button("Allow…") { coordinator.requestScreenCapturePermission() }
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

    private func shortcutDetail(_ shortcut: ReccyGlobalShortcut) -> String {
        switch shortcut {
        case .toggleRecording: "Starts with the current source, or stops the active recording."
        case .toggleRecordingPause: "Pauses or resumes writing while keeping the live monitor available."
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
        case .chooseDisplay: "display"
        case .choosePortion: "viewfinder.rectangular"
        case .chooseApplication: "macwindow.on.rectangle"
        case .chooseWindow: "macwindow"
        case .captureScreenshot: "camera"
        }
    }

    private func editorShortcutRow(_ title: String, keys: String, systemImage: String) -> some View {
        SettingsValueRow(
            title: title,
            detail: "Available whenever the timeline editor is active.",
            systemImage: systemImage
        ) {
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
        return "Reccy \(version) (\(build))"
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
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
    case notRequired
    case managedByMacOS

    var title: String {
        switch self {
        case .ready: "Ready"
        case .notRequested: "Not requested"
        case .notAllowed: "Not allowed"
        case .restartRequired: "Restart required"
        case .notRequired: "Not required"
        case .managedByMacOS: "Managed by macOS"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .notRequested: "circle.dashed"
        case .notAllowed: "exclamationmark.circle.fill"
        case .restartRequired: "arrow.clockwise.circle.fill"
        case .notRequired: "checkmark.circle"
        case .managedByMacOS: "gearshape.circle"
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .notRequested, .notRequired, .managedByMacOS: .secondary
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
        SettingsValueRow(title: title, detail: detail, systemImage: systemImage) {
            HStack(spacing: 8) {
                Label(status.title, systemImage: status.systemImage)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(status.color)
                actions
            }
        }
    }
}

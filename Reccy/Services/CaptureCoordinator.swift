import AppKit
import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation
import KeyboardShortcuts
import OSLog
@preconcurrency import ScreenCaptureKit

enum CaptureState: Equatable, Sendable {
    case idle
    case sourceSelected
    case countingDown(Int)
    case starting
    case recording
    case paused
    case stopping
    case failed(String)

    var isRecording: Bool {
        switch self {
        case .countingDown, .starting, .recording, .paused, .stopping: true
        default: false
        }
    }

    var canChangeSettings: Bool { !isRecording }

    var stopOperation: CaptureStopOperation {
        switch self {
        case .countingDown: .cancelCountdown
        case .starting: .cancelStartup
        case .recording, .paused: .finishRecording
        case .idle, .sourceSelected, .stopping, .failed: .none
        }
    }

    var stopButtonTitle: String {
        switch self {
        case .countingDown: "Cancel"
        case .starting: "Cancel Start"
        case .stopping: "Finishing…"
        default: "Stop Recording"
        }
    }
}

enum CaptureStopOperation: Equatable, Sendable {
    case none
    case cancelCountdown
    case cancelStartup
    case finishRecording
}

struct CaptureSessionCompletion: Equatable, Identifiable, Sendable {
    enum Outcome: Equatable, Sendable {
        case saved(URL)
        case cancelled
    }

    let id = UUID()
    let outcome: Outcome
}

enum CapturePermissionStatus: Equatable, Sendable {
    case notGranted
    case granted
    case restartRequired

    var isGranted: Bool { self == .granted }
}

@MainActor
final class CaptureCoordinator: NSObject, ObservableObject {
    @Published var settings: CaptureSettings {
        didSet {
            settings.save()
            if oldValue.outputFolderPath != settings.outputFolderPath {
                library.setDirectory(Self.outputDirectory(for: settings))
            }
        }
    }
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var selectedSourceKind: CaptureSourceKind = .display
    @Published private(set) var hasSelectedSource = false
    @Published private(set) var recordedDuration: TimeInterval = 0
    @Published private(set) var recordedFileSize: Int64 = 0
    @Published private(set) var audioInputDevices: [AudioInputDevice] = []
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastScreenshotURL: URL?
    @Published private(set) var isCapturingScreenshot = false
    @Published private(set) var directCapturePermission: CapturePermissionStatus = .notGranted
    @Published private(set) var microphonePermission: AVAuthorizationStatus = .notDetermined
    @Published private(set) var isSelectingSource = false
    @Published private(set) var sourceSelectionMessage: String?
    @Published private(set) var selectedSource: CaptureSourceDescriptor?
    @Published private(set) var systemAudioLevel: Double = 0
    @Published private(set) var microphoneAudioLevel: Double = 0
    @Published private(set) var systemAudioHistory: [Double] = []
    @Published private(set) var microphoneAudioHistory: [Double] = []
    @Published private(set) var sessionCompletion: CaptureSessionCompletion?

    let library: RecordingLibrary
    let previewPipeline = CapturePreviewPipeline()
    let transcription: TranscriptionController

    private let logger = Logger(subsystem: "com.reccy.mac", category: "Capture")
    private var selectedFilter: SCContentFilter?
    private var selectedSourceRect: CGRect?
    private var multitrackRecorder: MultitrackRecorder?
    private var recordingLease: RecordingSessionLease?
    private var activeOutputURL: URL?
    private var activeRecordingManifest: RecordingManifest?
    private var activeTranscriptionConfiguration: CaptureTranscriptionConfiguration?
    private var pendingCompletionNotice: String?
    private var countdownTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var recordingStopTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var sessionGeneration: UInt = 0
    private var activationCancellable: AnyCancellable?
    private var observesSystemPicker = false
    private let regionSelectionController = RegionSelectionController()
    private let boundaryController = CaptureBoundaryController()
#if DEBUG
    private var suppressesPermissionRefreshForQA = false
    private var isSimulatingRecordingForQA = false
#endif

    init(transcription: TranscriptionController = TranscriptionController()) {
        let savedSettings = CaptureSettings.load()
        settings = savedSettings
        library = RecordingLibrary(directoryURL: Self.outputDirectory(for: savedSettings))
        self.transcription = transcription
        super.init()

        let picker = SCContentSharingPicker.shared
        // Reccy presents the picker explicitly from its own source controls.
        // Do not publish an additional persistent Control Center entry for an
        // unassociated stream.
        picker.maximumStreamCount = 0
        picker.isActive = false
        refreshAudioInputDevices()
        refreshPermissionStatus()
        registerGlobalShortcuts()
        activationCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshPermissionStatus()
                    self?.refreshAudioInputDevices()
                }
            }
    }

    var formattedDuration: String {
        Duration.seconds(recordedDuration).formatted(
            .time(pattern: .hourMinuteSecond(padHourToLength: 2))
        )
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: recordedFileSize, countStyle: .file)
    }

    var liveStorageStatus: String {
        recordedFileSize > 0 ? "\(formattedFileSize) written" : "Writing safely"
    }

    var selectedMicrophoneName: String {
        guard let id = settings.selectedMicrophoneID else { return "System Default" }
        return audioInputDevices.first(where: { $0.id == id })?.name ?? "System Default"
    }

    /// Applies the HDR/codec invariant as one user action. Views never mutate
    /// `settings` from its own observer, avoiding re-entrant publication and
    /// preserving scroll, focus, and control state across every settings surface.
    func setHDREnabled(_ isEnabled: Bool) {
        var updated = settings
        updated.useHDR = isEnabled
        updated.normalize()
        guard updated != settings else { return }
        settings = updated
    }

    private func registerGlobalShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.state.isRecording {
                    self.stopRecording()
                } else {
                    self.startRecording()
                }
            }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecordingPause) { [weak self] in
            Task { @MainActor in self?.toggleRecordingPause() }
        }
        KeyboardShortcuts.onKeyUp(for: .chooseDisplay) { [weak self] in
            Task { @MainActor in self?.chooseSource(.display) }
        }
        KeyboardShortcuts.onKeyUp(for: .choosePortion) { [weak self] in
            Task { @MainActor in self?.chooseSource(.region) }
        }
        KeyboardShortcuts.onKeyUp(for: .chooseApplication) { [weak self] in
            Task { @MainActor in self?.chooseSource(.application) }
        }
        KeyboardShortcuts.onKeyUp(for: .chooseWindow) { [weak self] in
            Task { @MainActor in self?.chooseSource(.window) }
        }
        KeyboardShortcuts.onKeyUp(for: .captureScreenshot) { [weak self] in
            Task { @MainActor in self?.captureScreenshot() }
        }
    }

    func chooseSource(_ kind: CaptureSourceKind) {
        guard state.canChangeSettings, !isSelectingSource else { return }
        selectedSourceKind = kind
        selectedFilter = nil
        selectedSourceRect = nil
        selectedSource = nil
        hasSelectedSource = false
        boundaryController.hide()
        state = .idle

        guard !kind.requiresDirectCapturePermission || directCapturePermission.isGranted else {
            sourceSelectionMessage = "Portion capture needs Direct Screen & System Audio Access. Allow Reccy once in Permissions."
            return
        }

        isSelectingSource = true

        if kind == .region {
            sourceSelectionMessage = "Drag anywhere on a display to select the recording area. Press Escape to cancel."
            Task { await chooseRegion() }
            return
        }

        guard let pickerMode = kind.pickerMode, let contentStyle = kind.contentStyle else {
            isSelectingSource = false
            handleFailure(CaptureError.sourceUnavailable)
            return
        }
        sourceSelectionMessage = "Choose a \(kind.title.lowercased()) in the macOS picker."

        var pickerConfiguration = SCContentSharingPickerConfiguration()
        pickerConfiguration.allowedPickerModes = pickerMode
        // The picker is used to create a new filter, not to mutate the
        // recorder's private SCStream after capture has begun.
        pickerConfiguration.allowsChangingSelectedContent = false
        if let bundleID = Bundle.main.bundleIdentifier {
            pickerConfiguration.excludedBundleIDs = [bundleID]
        }

        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = pickerConfiguration
        if !observesSystemPicker {
            picker.add(self)
            observesSystemPicker = true
        }
        picker.isActive = true
        picker.present(using: contentStyle)
    }

    private func chooseRegion() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let selection = await regionSelectionController.selectRegion(across: content.displays),
                  let display = content.displays.first(where: { $0.displayID == selection.displayID })
            else {
                isSelectingSource = false
                state = .idle
                sourceSelectionMessage = "Portion selection was cancelled."
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            isSelectingSource = false
            completeSourceSelection(filter: filter, sourceRect: selection.sourceRect)
        } catch {
            isSelectingSource = false
            handleFailure(error)
        }
    }

    func requestDirectCapturePermission() {
        guard !directCapturePermission.isGranted else { return }
        let wasGranted = CGPreflightScreenCaptureAccess()
        let granted = CGRequestScreenCaptureAccess()
        if granted && !wasGranted {
            directCapturePermission = .restartRequired
            sourceSelectionMessage = "Direct capture access granted. Quit and reopen Reccy once to enable Portion capture."
        } else {
            refreshPermissionStatus()
            if !granted {
                sourceSelectionMessage = "Enable Reccy in System Settings → Privacy & Security → Screen & System Audio Recording to use Portion capture."
            }
        }
    }

    func requestMicrophonePermission() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshPermissionStatus()
        }
    }

    func openScreenCapturePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openFilesAndFoldersPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func quitForPermissionRestart() {
        NSApp.terminate(nil)
    }

    func refreshPermissionStatus() {
#if DEBUG
        if suppressesPermissionRefreshForQA {
            return
        }
#endif
        if directCapturePermission != .restartRequired {
            directCapturePermission = CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        }
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func startRecording() {
        guard let filter = selectedFilter, state.canChangeSettings else {
            chooseSource(selectedSourceKind)
            return
        }

        countdownTask?.cancel()
        sessionCompletion = nil
        let seconds = settings.countdown.rawValue
        guard seconds > 0 else {
            launchRecordingStart(with: filter)
            return
        }

        countdownTask = Task { [weak self] in
            guard let self else { return }
            for remaining in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                state = .countingDown(remaining)
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            countdownTask = nil
            launchRecordingStart(with: filter)
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        state = hasSelectedSource ? .sourceSelected : .idle
        sessionCompletion = CaptureSessionCompletion(outcome: .cancelled)
    }

    private func cancelRecordingStartup() {
        guard state == .starting else { return }

        sessionGeneration &+= 1
        let startTask = recordingStartTask
        let recorder = multitrackRecorder
        let outputURL = activeOutputURL
        recordingStartTask = nil
        startTask?.cancel()
        state = .stopping
        meterTask?.cancel()

        recordingStopTask = Task { [weak self] in
            await recorder?.cancel()
            await startTask?.value
            guard let self, self.state == .stopping else { return }
            self.discardIncompleteRecording(at: outputURL)
        }
    }

    private func finishActiveRecording() {
        guard recordingStopTask == nil,
              let recorder = multitrackRecorder,
              state == .recording || state == .paused
        else { return }

        sessionGeneration &+= 1
        recordingStartTask?.cancel()
        recordingStartTask = nil
        state = .stopping
        meterTask?.cancel()

        recordingStopTask = Task { [weak self] in
            do {
                try await recorder.stop()
                guard let self else { return }
                self.finishRecording()
            } catch {
                guard let self else { return }
                self.handleFailure(error)
            }
        }
    }

    func stopRecording() {
#if DEBUG
        if isSimulatingRecordingForQA {
            isSimulatingRecordingForQA = false
            previewPipeline.clear()
            clearSourceSelection()
            resetSessionTelemetry()
            state = .idle
            sessionCompletion = CaptureSessionCompletion(outcome: .cancelled)
            return
        }
#endif
        switch state.stopOperation {
        case .cancelCountdown:
            cancelCountdown()
        case .cancelStartup:
            cancelRecordingStartup()
        case .finishRecording:
            finishActiveRecording()
        case .none:
            break
        }
    }

    func toggleRecordingPause() {
#if DEBUG
        if isSimulatingRecordingForQA {
            state = state == .paused ? .recording : .paused
            return
        }
#endif
        guard let multitrackRecorder else { return }
        switch state {
        case .recording:
            guard multitrackRecorder.pause() else { return }
            state = .paused
            boundaryController.setRecording(true, isPaused: true, duration: recordedDuration)
        case .paused:
            guard multitrackRecorder.resume() else { return }
            state = .recording
            boundaryController.setRecording(true, duration: recordedDuration)
        default:
            break
        }
    }

    func captureScreenshot() {
        guard let selectedFilter, state.canChangeSettings, !isCapturingScreenshot else {
            if selectedFilter == nil {
                chooseSource(selectedSourceKind)
            }
            return
        }

        isCapturingScreenshot = true
        Task {
            do {
                let configuration = SCScreenshotConfiguration()
                configuration.showsCursor = settings.showCursor
                configuration.contentType = settings.screenshotFormat.contentType as UTTypeReference
                configuration.dynamicRange = settings.screenshotRange.screenCaptureRange
                configuration.displayIntent = .canonical
                configuration.fileURL = try makeScreenshotURL()
                if let selectedSourceRect {
                    configuration.sourceRect = selectedSourceRect
                }

                let output = try await SCScreenshotManager.captureScreenshot(
                    contentFilter: selectedFilter,
                    configuration: configuration
                )
                lastScreenshotURL = (output.fileURL as URL?) ?? configuration.fileURL
                isCapturingScreenshot = false
                NSApp.requestUserAttention(.informationalRequest)
            } catch {
                isCapturingScreenshot = false
                handleFailure(error)
            }
        }
    }

    func clearError() {
        if case .failed = state {
            state = hasSelectedSource ? .sourceSelected : .idle
        }
    }

    func refreshAudioInputDevices() {
        audioInputDevices = AudioInputDevice.discoverAvailable()
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Recording Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = library.directoryURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.outputFolderPath = url.path
    }

    func resetOutputFolder() {
        settings.outputFolderPath = nil
    }

    private func launchRecordingStart(with filter: SCContentFilter) {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        state = .starting
        recordingStartTask = Task { [weak self] in
            await self?.beginRecording(with: filter, generation: generation)
        }
    }

    private func beginRecording(
        with filter: SCContentFilter,
        generation: UInt
    ) async {
        guard await requestMicrophonePermissionIfNeeded() else {
            guard isCurrentSession(generation) else { return }
            recordingStartTask = nil
            handleFailure(CaptureError.microphonePermissionDenied)
            return
        }
        guard isCurrentSession(generation), !Task.isCancelled else { return }

        do {
            recordedDuration = 0
            recordedFileSize = 0
            systemAudioLevel = 0
            microphoneAudioLevel = 0
            systemAudioHistory.removeAll(keepingCapacity: true)
            microphoneAudioHistory.removeAll(keepingCapacity: true)
            previewPipeline.clear()

            let streamConfiguration = makeStreamConfiguration(for: filter)
            let options = MultitrackRecordingOptions(
                width: streamConfiguration.width,
                height: streamConfiguration.height,
                frameRate: settings.frameRate.rawValue,
                preset: settings.recordingPreset,
                includesSystemAudio: settings.includeSystemAudio,
                includesMicrophone: settings.includeMicrophone,
                isHDR: settings.useHDR
            )
            let encodingPlan = options.encodingPlan
            let outputURL = try makeOutputURL(fileExtension: encodingPlan.fileExtension)
            recordingLease = try RecordingSessionLease.acquire(
                in: outputURL.deletingLastPathComponent()
            )
            let availableBytes = try RecordingStoragePolicy.availableBytes(
                at: outputURL.deletingLastPathComponent()
            )
            try RecordingStoragePolicy.validatePreflight(
                availableBytes: availableBytes,
                options: options
            )
            guard let selectedSource else { throw CaptureError.sourceUnavailable }
            let manifest = RecordingManifest(
                createdAt: Date(),
                source: selectedSource,
                width: streamConfiguration.width,
                height: streamConfiguration.height,
                frameRate: settings.frameRate.rawValue,
                recordingPreset: settings.recordingPreset,
                videoCodec: encodingPlan.codec,
                isHDR: settings.useHDR,
                includesSystemAudio: settings.includeSystemAudio,
                includesMicrophone: settings.includeMicrophone,
                microphoneName: settings.includeMicrophone ? selectedMicrophoneName : nil,
                showsCursor: settings.showCursor,
                highlightsClicks: settings.showMouseClicks && !settings.useHDR
            )
            _ = try RecordingRecoveryJournal.write(
                mediaURL: outputURL,
                manifest: manifest
            )

            let recorder = MultitrackRecorder()
            let transcriptionConfiguration = transcription.makeCaptureConfiguration(
                systemAudio: settings.includeSystemAudio,
                microphone: settings.includeMicrophone
            )
            transcription.beginLive(
                configuration: transcriptionConfiguration,
                microphoneName: selectedMicrophoneName
            )
            let liveRouter = transcription.liveRouter
            recorder.onStarted = { [weak self] in
                Task { @MainActor in
                    guard let self,
                          self.isCurrentSession(generation),
                          self.state == .starting
                    else { return }
                    self.recordingStartTask = nil
                    self.state = .recording
                    self.boundaryController.setRecording(true)
                    self.beginMetering()
                }
            }
            recorder.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.isCurrentSession(generation) else { return }
                    self.handleFailure(error)
                }
            }
            recorder.onVideoFrame = { [previewPipeline] sampleBuffer in
                previewPipeline.enqueue(sampleBuffer)
            }
            recorder.onAudioPacket = { role, packet in
                Task { await liveRouter.ingest(packet, role: role) }
            }
            multitrackRecorder = recorder
            activeOutputURL = outputURL
            activeRecordingManifest = manifest
            activeTranscriptionConfiguration = transcriptionConfiguration
            try await recorder.start(
                filter: filter,
                configuration: streamConfiguration,
                outputURL: outputURL,
                options: options
            )
            guard isCurrentSession(generation), !Task.isCancelled else {
                await recorder.cancel()
                return
            }
            recordingStartTask = nil
        } catch {
            guard isCurrentSession(generation), !Task.isCancelled else { return }
            recordingStartTask = nil
            handleFailure(error)
        }
    }

    private func makeStreamConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration: SCStreamConfiguration
        if settings.useHDR {
            configuration = SCStreamConfiguration(preset: .captureHDRRecordingPreservedSDRHDR10)
        } else {
            configuration = SCStreamConfiguration()
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
        }

        let captureRect = selectedSourceRect ?? filter.contentRect
        let size = settings.resolution.outputSize(
            contentRect: captureRect,
            pointPixelScale: CGFloat(filter.pointPixelScale)
        )
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(settings.frameRate.rawValue)
        )
        configuration.queueDepth = 5
        configuration.showsCursor = settings.showCursor
        configuration.showMouseClicks = settings.showMouseClicks && !settings.useHDR
        configuration.capturesAudio = settings.includeSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = settings.excludeOwnAudio
        configuration.captureMicrophone = settings.includeMicrophone
        configuration.microphoneCaptureDeviceID = settings.selectedMicrophoneID
        configuration.streamName = "Reccy Recording"
        if let selectedSourceRect {
            configuration.sourceRect = selectedSourceRect
        }
        return configuration
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        guard settings.includeMicrophone else { return true }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func makeOutputURL(fileExtension: String) throws -> URL {
        let directory = library.directoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let baseName = "Reccy \(formatter.string(from: Date()))"
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    private func makeScreenshotURL() throws -> URL {
        let directory = library.directoryURL.appendingPathComponent("Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let baseName = "Reccy Screenshot \(formatter.string(from: Date()))"
        let fileExtension = settings.screenshotFormat.fileExtension
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    private func beginMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            var storageCheckTick = 0
            while let self, !Task.isCancelled, let recorder = self.multitrackRecorder {
                let metrics = recorder.metrics
                recordedDuration = metrics.duration
                recordedFileSize = metrics.fileSize
                systemAudioLevel = metrics.systemAudioLevel
                microphoneAudioLevel = metrics.microphoneLevel
                appendLevel(metrics.systemAudioLevel, to: &systemAudioHistory)
                appendLevel(metrics.microphoneLevel, to: &microphoneAudioHistory)
                boundaryController.setRecording(
                    true,
                    isPaused: state == .paused,
                    duration: metrics.duration
                )
                if storageCheckTick == 0,
                   shouldStopForStorageReserve()
                {
                    return
                }
                storageCheckTick = (storageCheckTick + 1) % 30
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    private func shouldStopForStorageReserve() -> Bool {
        guard let activeOutputURL,
              let availableBytes = try? RecordingStoragePolicy.availableBytes(
                at: activeOutputURL.deletingLastPathComponent()
              ),
              availableBytes < RecordingStoragePolicy.runtimeReserveBytes
        else { return false }

        let available = ByteCountFormatter.string(
            fromByteCount: availableBytes,
            countStyle: .file
        )
        pendingCompletionNotice = "Only \(available) remained in the recording folder. Reccy stopped gracefully before the filesystem reserve was exhausted."
        stopRecording()
        return true
    }

    private func appendLevel(_ level: Double, to history: inout [Double]) {
        history.append(min(max(level, 0), 1))
        if history.count > 600 {
            history.removeFirst(history.count - 600)
        }
    }

    private func finishRecording() {
        sessionGeneration &+= 1
        recordingStartTask?.cancel()
        recordingStartTask = nil
        recordingStopTask = nil
        meterTask?.cancel()
        meterTask = nil
        multitrackRecorder = nil
        previewPipeline.clear()

        let completedURL = activeOutputURL
        var indexingError: Error?
        if let completedURL {
            if let activeRecordingManifest {
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(activeRecordingManifest)
                    try data.write(
                        to: RecordingManifest.sidecarURL(for: completedURL),
                        options: .atomic
                    )
                    try RecordingRecoveryJournal.remove(
                        from: completedURL.deletingLastPathComponent()
                    )
                } catch {
                    indexingError = error
                }
            }
            lastRecordingURL = completedURL
        }
        let completedManifest = activeRecordingManifest
        let completedTranscriptionConfiguration = activeTranscriptionConfiguration
        activeOutputURL = nil
        activeRecordingManifest = nil
        activeTranscriptionConfiguration = nil
        clearSourceSelection()
        resetSessionTelemetry()
        state = .idle
        library.refresh()
        if let indexingError {
            library.presentNotice(
                kind: .warning,
                title: "Recording saved; indexing needs attention",
                message: indexingError.localizedDescription,
                fileURL: lastRecordingURL
            )
        } else if let pendingCompletionNotice {
            library.presentNotice(
                kind: .warning,
                title: "Recording stopped to protect the file",
                message: pendingCompletionNotice,
                fileURL: lastRecordingURL
            )
        }
        pendingCompletionNotice = nil
        recordingLease = nil
        NSApp.requestUserAttention(.informationalRequest)
        if let completedURL {
            if let completedManifest, let completedTranscriptionConfiguration {
                transcription.finishLive(
                    mediaURL: completedURL,
                    manifest: completedManifest,
                    configuration: completedTranscriptionConfiguration
                )
            } else {
                transcription.cancelLive()
            }
            sessionCompletion = CaptureSessionCompletion(outcome: .saved(completedURL))
        }
    }

    private func discardIncompleteRecording(at outputURL: URL?) {
        transcription.cancelLive()
        if let outputURL {
            try? RecordingRecoveryJournal.remove(
                from: outputURL.deletingLastPathComponent()
            )
            try? FileManager.default.removeItem(at: outputURL)
        }

        recordingStartTask = nil
        recordingStopTask = nil
        meterTask?.cancel()
        meterTask = nil
        multitrackRecorder = nil
        activeOutputURL = nil
        activeRecordingManifest = nil
        activeTranscriptionConfiguration = nil
        pendingCompletionNotice = nil
        recordingLease = nil
        previewPipeline.clear()
        clearSourceSelection()
        resetSessionTelemetry()
        state = .idle
        sessionCompletion = CaptureSessionCompletion(outcome: .cancelled)
    }

    private func isCurrentSession(_ generation: UInt) -> Bool {
        generation == sessionGeneration
    }

    /// Ends the privacy-sensitive capture session as one atomic lifecycle
    /// operation. Successful recordings never leave a stale filter, source
    /// badge, crop rectangle, or non-recorded boundary visible in the app.
    private func clearSourceSelection() {
        deactivateSystemPicker()
        selectedFilter = nil
        selectedSourceRect = nil
        selectedSource = nil
        selectedSourceKind = .display
        hasSelectedSource = false
        isSelectingSource = false
        sourceSelectionMessage = nil
        boundaryController.hide()
    }

    /// Clears values whose meaning is scoped to one capture session. Durable
    /// settings and `lastRecordingURL` intentionally survive so completion
    /// navigation can open the saved recording without leaving live state in
    /// Record, Monitor, or the menu-bar extra.
    private func resetSessionTelemetry() {
        recordedDuration = 0
        recordedFileSize = 0
        systemAudioLevel = 0
        microphoneAudioLevel = 0
        systemAudioHistory.removeAll(keepingCapacity: true)
        microphoneAudioHistory.removeAll(keepingCapacity: true)
    }

    /// The shared picker owns macOS's screen-sharing menu-bar and switcher UI.
    /// Reccy activates it only while choosing or recording a system-picked
    /// source, and releases it as part of every terminal capture path.
    private func deactivateSystemPicker() {
        let picker = SCContentSharingPicker.shared
        picker.isActive = false
        if observesSystemPicker {
            picker.remove(self)
            observesSystemPicker = false
        }
    }

    private func handleFailure(_ error: Error) {
        transcription.cancelLive()
        logCaptureFailure(error)
        sessionGeneration &+= 1
        deactivateSystemPicker()
        countdownTask?.cancel()
        countdownTask = nil
        recordingStartTask?.cancel()
        recordingStartTask = nil
        recordingStopTask = nil
        meterTask?.cancel()
        meterTask = nil
        let shouldInspectRecovery = activeOutputURL != nil
        if let multitrackRecorder {
            Task {
                await multitrackRecorder.cancel()
                recordingLease = nil
                if shouldInspectRecovery {
                    library.recoverInterruptedRecordingIfNeeded()
                }
            }
        } else {
            recordingLease = nil
        }
        multitrackRecorder = nil
        activeOutputURL = nil
        activeRecordingManifest = nil
        activeTranscriptionConfiguration = nil
        clearSourceSelection()
        resetSessionTelemetry()
        previewPipeline.clear()
        pendingCompletionNotice = nil
        state = .failed(error.localizedDescription)
    }

    private func logCaptureFailure(_ error: Error) {
        let nsError = error as NSError
        let underlying: NSError?
        switch error {
        case let MultitrackRecorderError.writerCouldNotStart(error),
             let MultitrackRecorderError.writerFailed(error):
            underlying = error as NSError?
        default:
            underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let underlyingDomain = underlying?.domain ?? "none"
        let underlyingCode = underlying?.code ?? 0
        let detail = "Capture failed domain=\(nsError.domain) code=\(nsError.code) "
            + "description=\(nsError.localizedDescription) "
            + "underlyingDomain=\(underlyingDomain) underlyingCode=\(underlyingCode)"
        logger.error("\(detail, privacy: .public)")
    }

    private static func outputDirectory(for settings: CaptureSettings) -> URL {
        if let path = settings.outputFolderPath, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return movies.appendingPathComponent("Reccy", isDirectory: true)
    }

    private func completeSourceSelection(
        filter: SCContentFilter,
        sourceRect: CGRect? = nil
    ) {
        guard let descriptor = makeSourceDescriptor(filter: filter, sourceRect: sourceRect) else {
            handleFailure(CaptureError.sourceUnavailable)
            return
        }
        selectedFilter = filter
        selectedSourceRect = sourceRect
        selectedSource = descriptor
        hasSelectedSource = true
        state = .sourceSelected
        if let region = descriptor.region {
            let rect = region.cgRect
            sourceSelectionMessage = "\(descriptor.name) selected · \(Int(rect.width)) × \(Int(rect.height)). Reccy is ready to record."
        } else {
            sourceSelectionMessage = "\(descriptor.name) selected. Reccy is ready to record."
        }
        if let target = makeBoundaryTarget(from: descriptor) {
            boundaryController.show(target: target, sourceName: descriptor.name)
        }
    }

    private func makeSourceDescriptor(
        filter: SCContentFilter,
        sourceRect: CGRect?
    ) -> CaptureSourceDescriptor? {
        switch selectedSourceKind {
        case .display, .region:
            guard let display = filter.includedDisplays.first else { return nil }
            let displayName = NSScreen.screen(displayID: display.displayID)?.localizedName
                ?? "Display \(display.displayID)"
            return CaptureSourceDescriptor(
                kind: selectedSourceKind,
                name: selectedSourceKind == .region ? "Portion of \(displayName)" : displayName,
                applicationName: nil,
                applicationBundleIdentifier: nil,
                windowName: nil,
                windowIDs: [],
                displayID: display.displayID,
                displayName: displayName,
                region: sourceRect.map(CaptureRegion.init)
            )

        case .application:
            guard let application = filter.includedApplications.first else { return nil }
            return CaptureSourceDescriptor(
                kind: .application,
                name: application.applicationName,
                applicationName: application.applicationName,
                applicationBundleIdentifier: application.bundleIdentifier,
                windowName: nil,
                windowIDs: filter.includedWindows.map(\.windowID),
                displayID: nil,
                displayName: nil,
                region: nil
            )

        case .window:
            guard let window = filter.includedWindows.first else { return nil }
            let applicationName = window.owningApplication?.applicationName
            let windowName = window.title?.isEmpty == false ? window.title : nil
            return CaptureSourceDescriptor(
                kind: .window,
                name: windowName ?? applicationName ?? "Window",
                applicationName: applicationName,
                applicationBundleIdentifier: window.owningApplication?.bundleIdentifier,
                windowName: windowName,
                windowIDs: [window.windowID],
                displayID: nil,
                displayName: nil,
                region: nil
            )
        }
    }

    private func makeBoundaryTarget(
        from descriptor: CaptureSourceDescriptor
    ) -> CaptureBoundaryTarget? {
        switch descriptor.kind {
        case .display:
            return descriptor.displayID.map(CaptureBoundaryTarget.display)
        case .region:
            guard let displayID = descriptor.displayID, let region = descriptor.region else { return nil }
            return .region(displayID, region)
        case .application:
            if let bundleIdentifier = descriptor.applicationBundleIdentifier {
                return .application(bundleIdentifier)
            }
            return descriptor.windowIDs.isEmpty ? nil : .windows(descriptor.windowIDs)
        case .window:
            return descriptor.windowIDs.isEmpty ? nil : .windows(descriptor.windowIDs)
        }
    }

#if DEBUG
    func installPermissionsQAScenario() {
        suppressesPermissionRefreshForQA = true
        directCapturePermission = .notGranted
        microphonePermission = .denied
    }

    func installPortionSelectionQAScenario() {
        suppressesPermissionRefreshForQA = true
        directCapturePermission = .granted
        selectedSourceKind = .region
        isSelectingSource = true
        sourceSelectionMessage = "Drag anywhere on a display to select the recording area. Press Escape to cancel."
        Task { [weak self] in
            _ = await self?.regionSelectionController.selectRegionForVisualQA()
            guard let self else { return }
            isSelectingSource = false
            sourceSelectionMessage = "Portion selection was cancelled."
        }
    }

    func installActiveMonitorQAScenario() {
        suppressesPermissionRefreshForQA = true
        directCapturePermission = .granted
        installActiveMenuBarQAScenario()
        recordedDuration = 9
        recordedFileSize = 8_400_000
        selectedSource = CaptureSourceDescriptor(
            kind: .application,
            name: "Preview Pipeline",
            applicationName: "Preview Pipeline",
            applicationBundleIdentifier: "com.reccy.preview-qa",
            windowName: nil,
            windowIDs: [101],
            displayID: nil,
            displayName: nil,
            region: nil
        )
        isSimulatingRecordingForQA = true
        let previewPipeline = previewPipeline
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(350))
            for _ in 0..<60 {
                guard let sampleBuffer = Self.makePreviewQASampleBuffer() else { return }
                previewPipeline.enqueue(sampleBuffer)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func installRecordReadyQAScenario() {
        suppressesPermissionRefreshForQA = true
        directCapturePermission = .granted
        microphonePermission = .authorized
        selectedSourceKind = .application
        hasSelectedSource = true
        selectedSource = Self.qaApplicationSource
        sourceSelectionMessage = nil
        state = .sourceSelected
    }

    /// Drives the exact production menu-bar view during installed-app visual QA.
    /// This state is compiled out of Release and never starts a capture stream.
    func installActiveMenuBarQAScenario() {
        isSimulatingRecordingForQA = true
        selectedSourceKind = .application
        hasSelectedSource = true
        selectedSource = Self.qaApplicationSource
        recordedDuration = 222.4
        recordedFileSize = 48_721_920
        systemAudioLevel = 0.74
        microphoneAudioLevel = 0.46
        systemAudioHistory = Self.qaWaveformSamples(count: 120, amplitude: 0.82, phase: 0.15)
        microphoneAudioHistory = Self.qaWaveformSamples(count: 120, amplitude: 0.58, phase: 1.1)
        state = .recording
    }

    private static let qaApplicationSource = CaptureSourceDescriptor(
        kind: .application,
        name: "Safari · Research",
        applicationName: "Safari",
        applicationBundleIdentifier: "com.apple.Safari",
        windowName: nil,
        windowIDs: [101, 102],
        displayID: nil,
        displayName: nil,
        region: nil
    )

    private static func qaWaveformSamples(
        count: Int,
        amplitude: Double,
        phase: Double
    ) -> [Double] {
        (0..<count).map { index in
            let position = Double(index) / 5.5
            let carrier = abs(sin(position + phase))
            let detail = abs(sin(position * 2.7 + phase * 0.6)) * 0.24
            return min(1, 0.08 + (carrier * 0.76 + detail) * amplitude)
        }
    }

    nonisolated static func makePreviewQASampleBuffer() -> CMSampleBuffer? {
        let width = 960
        let height = 540
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let red = UInt32(36 + (180 * x / width))
                let green = UInt32(45 + (130 * y / height))
                let blue = UInt32(150 + (90 * (width - x) / width))
                row[x] = 0xFF00_0000 | (red << 16) | (green << 8) | blue
            }
        }

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }
#endif
}

extension CaptureCoordinator: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            isSelectingSource = false
            deactivateSystemPicker()
            if !hasSelectedSource {
                state = .idle
                sourceSelectionMessage = "Source selection was cancelled."
            }
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            isSelectingSource = false
            deactivateSystemPicker()
            completeSourceSelection(filter: filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            isSelectingSource = false
            handleFailure(CaptureError.sourcePickerFailed(message))
        }
    }
}

enum CaptureError: LocalizedError {
    case microphonePermissionDenied
    case sourcePickerFailed(String)
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is off. Enable it for Reccy in System Settings → Privacy & Security → Microphone."
        case let .sourcePickerFailed(message):
            "The macOS source picker failed: \(message)"
        case .sourceUnavailable:
            "The selected source is no longer available. Choose it again in the macOS picker."
        }
    }
}

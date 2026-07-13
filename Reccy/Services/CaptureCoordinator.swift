import AppKit
import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

enum CaptureState: Equatable, Sendable {
    case idle
    case sourceSelected
    case countingDown(Int)
    case starting
    case recording
    case stopping
    case failed(String)

    var isRecording: Bool {
        switch self {
        case .countingDown, .starting, .recording, .stopping: true
        default: false
        }
    }

    var canChangeSettings: Bool { !isRecording }
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
    @Published private(set) var screenCapturePermission: CapturePermissionStatus = .notGranted
    @Published private(set) var microphonePermission: AVAuthorizationStatus = .notDetermined
    @Published private(set) var isPresentingSourcePicker = false
    @Published private(set) var sourceSelectionMessage: String?
    @Published private(set) var selectedSource: CaptureSourceDescriptor?
    @Published private(set) var systemAudioLevel: Double = 0
    @Published private(set) var microphoneAudioLevel: Double = 0
    @Published private(set) var systemAudioHistory: [Double] = []
    @Published private(set) var microphoneAudioHistory: [Double] = []

    let library: RecordingLibrary

    private var selectedFilter: SCContentFilter?
    private var selectedSourceRect: CGRect?
    private var multitrackRecorder: MultitrackRecorder?
    private var activeOutputURL: URL?
    private var activeRecordingManifest: RecordingManifest?
    private var countdownTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var activationCancellable: AnyCancellable?
    private let regionSelectionController = RegionSelectionController()
    private let boundaryController = CaptureBoundaryController()

    override init() {
        let savedSettings = CaptureSettings.load()
        settings = savedSettings
        library = RecordingLibrary(directoryURL: Self.outputDirectory(for: savedSettings))
        super.init()

        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        refreshAudioInputDevices()
        refreshPermissionStatus()
        activationCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshPermissionStatus() }
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

    var selectedMicrophoneName: String {
        guard let id = settings.selectedMicrophoneID else { return "System Default" }
        return audioInputDevices.first(where: { $0.id == id })?.name ?? "System Default"
    }

    func chooseSource(_ kind: CaptureSourceKind) {
        guard state.canChangeSettings else { return }
        guard screenCapturePermission.isGranted else {
            sourceSelectionMessage = "Allow Screen & System Audio Recording before choosing a source."
            return
        }
        selectedSourceKind = kind
        selectedFilter = nil
        selectedSourceRect = nil
        selectedSource = nil
        hasSelectedSource = false
        boundaryController.hide()
        state = .idle
        isPresentingSourcePicker = true
        sourceSelectionMessage = kind == .region
            ? "Choose a display in the macOS picker, then drag out the portion to record."
            : "Choose a \(kind.title.lowercased()) in the macOS picker."

        var pickerConfiguration = SCContentSharingPickerConfiguration()
        pickerConfiguration.allowedPickerModes = kind.pickerMode
        pickerConfiguration.allowsChangingSelectedContent = true
        if let bundleID = Bundle.main.bundleIdentifier {
            pickerConfiguration.excludedBundleIDs = [bundleID]
        }

        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = pickerConfiguration
        picker.isActive = true
        picker.present(using: kind.contentStyle)
    }

    func requestScreenCapturePermission() {
        guard !screenCapturePermission.isGranted else { return }
        let wasGranted = CGPreflightScreenCaptureAccess()
        let granted = CGRequestScreenCaptureAccess()
        if granted && !wasGranted {
            screenCapturePermission = .restartRequired
            sourceSelectionMessage = "Permission granted. Quit and reopen Reccy once to enable capture."
        } else {
            refreshPermissionStatus()
            if !granted {
                sourceSelectionMessage = "Enable Reccy in System Settings → Privacy & Security → Screen & System Audio Recording."
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

    func quitForPermissionRestart() {
        NSApp.terminate(nil)
    }

    func refreshPermissionStatus() {
        if screenCapturePermission != .restartRequired {
            screenCapturePermission = CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        }
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func startRecording() {
        guard let filter = selectedFilter, state.canChangeSettings else {
            chooseSource(selectedSourceKind)
            return
        }

        countdownTask?.cancel()
        let seconds = settings.countdown.rawValue
        guard seconds > 0 else {
            Task { await beginRecording(with: filter) }
            return
        }

        countdownTask = Task { [weak self] in
            guard let self else { return }
            for remaining in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                state = .countingDown(remaining)
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            await beginRecording(with: filter)
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        state = hasSelectedSource ? .sourceSelected : .idle
    }

    func stopRecording() {
        if case .countingDown = state {
            cancelCountdown()
            return
        }
        guard let multitrackRecorder, state.isRecording else { return }
        state = .stopping
        meterTask?.cancel()

        Task {
            do {
                try await multitrackRecorder.stop()
                finishRecording()
            } catch {
                handleFailure(error)
            }
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
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        audioInputDevices = session.devices.map {
            AudioInputDevice(id: $0.uniqueID, name: $0.localizedName)
        }
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

    private func beginRecording(with filter: SCContentFilter) async {
        guard await requestMicrophonePermissionIfNeeded() else {
            handleFailure(CaptureError.microphonePermissionDenied)
            return
        }

        do {
            state = .starting
            recordedDuration = 0
            recordedFileSize = 0
            systemAudioLevel = 0
            microphoneAudioLevel = 0
            systemAudioHistory.removeAll(keepingCapacity: true)
            microphoneAudioHistory.removeAll(keepingCapacity: true)

            let streamConfiguration = makeStreamConfiguration(for: filter)
            let outputURL = try makeOutputURL()
            let options = MultitrackRecordingOptions(
                width: streamConfiguration.width,
                height: streamConfiguration.height,
                frameRate: settings.frameRate.rawValue,
                preset: settings.recordingPreset,
                includesSystemAudio: settings.includeSystemAudio,
                includesMicrophone: settings.includeMicrophone,
                isHDR: settings.useHDR
            )
            let recorder = MultitrackRecorder()
            recorder.onStarted = { [weak self] in
                Task { @MainActor in
                    self?.state = .recording
                    self?.boundaryController.setRecording(true)
                    self?.beginMetering()
                }
            }
            recorder.onFailure = { [weak self] error in
                Task { @MainActor in self?.handleFailure(error) }
            }
            multitrackRecorder = recorder
            activeOutputURL = outputURL
            if let selectedSource {
                activeRecordingManifest = RecordingManifest(
                    createdAt: Date(),
                    source: selectedSource,
                    width: streamConfiguration.width,
                    height: streamConfiguration.height,
                    frameRate: settings.frameRate.rawValue,
                    recordingPreset: settings.recordingPreset,
                    isHDR: settings.useHDR,
                    includesSystemAudio: settings.includeSystemAudio,
                    includesMicrophone: settings.includeMicrophone,
                    microphoneName: settings.includeMicrophone ? selectedMicrophoneName : nil,
                    showsCursor: settings.showCursor,
                    highlightsClicks: settings.showMouseClicks && !settings.useHDR
                )
            }
            try await recorder.start(
                filter: filter,
                configuration: streamConfiguration,
                outputURL: outputURL,
                options: options
            )
        } catch {
            handleFailure(error)
        }
    }

    private func makeStreamConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration: SCStreamConfiguration
        if settings.useHDR, #available(macOS 26.0, *) {
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

    private func makeOutputURL() throws -> URL {
        let directory = library.directoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let baseName = "Reccy \(formatter.string(from: Date()))"
        let fileExtension = settings.recordingPreset.fileExtension
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
            while let self, !Task.isCancelled, let recorder = self.multitrackRecorder {
                let metrics = recorder.metrics
                recordedDuration = metrics.duration
                recordedFileSize = metrics.fileSize
                systemAudioLevel = metrics.systemAudioLevel
                microphoneAudioLevel = metrics.microphoneLevel
                appendLevel(metrics.systemAudioLevel, to: &systemAudioHistory)
                appendLevel(metrics.microphoneLevel, to: &microphoneAudioHistory)
                boundaryController.setRecording(true, duration: metrics.duration)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func appendLevel(_ level: Double, to history: inout [Double]) {
        history.append(min(max(level, 0), 1))
        if history.count > 96 {
            history.removeFirst(history.count - 96)
        }
    }

    private func finishRecording() {
        meterTask?.cancel()
        meterTask = nil
        multitrackRecorder = nil
        systemAudioLevel = 0
        microphoneAudioLevel = 0

        if let activeOutputURL {
            if let activeRecordingManifest {
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(activeRecordingManifest)
                    try data.write(
                        to: RecordingManifest.sidecarURL(for: activeOutputURL),
                        options: .atomic
                    )
                } catch {
                    sourceSelectionMessage = "Recording saved, but its capture details could not be indexed."
                }
            }
            lastRecordingURL = activeOutputURL
        }
        activeOutputURL = nil
        activeRecordingManifest = nil
        boundaryController.setRecording(false)
        state = hasSelectedSource ? .sourceSelected : .idle
        library.refresh()
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func handleFailure(_ error: Error) {
        countdownTask?.cancel()
        meterTask?.cancel()
        if let multitrackRecorder {
            Task { await multitrackRecorder.cancel() }
        }
        multitrackRecorder = nil
        activeOutputURL = nil
        activeRecordingManifest = nil
        boundaryController.setRecording(false)
        systemAudioLevel = 0
        microphoneAudioLevel = 0
        state = .failed(error.localizedDescription)
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
        sourceSelectionMessage = "\(descriptor.name) selected. Reccy is ready to record."
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
}

extension CaptureCoordinator: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            isPresentingSourcePicker = false
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
            isPresentingSourcePicker = false
            if selectedSourceKind == .region {
                guard let display = filter.includedDisplays.first else {
                    handleFailure(CaptureError.sourceUnavailable)
                    return
                }
                isPresentingSourcePicker = true
                sourceSelectionMessage = "Drag to select the portion to record, then choose Use Area."
                if let region = await regionSelectionController.selectRegion(on: display) {
                    isPresentingSourcePicker = false
                    completeSourceSelection(filter: filter, sourceRect: region)
                } else {
                    isPresentingSourcePicker = false
                    state = .idle
                    sourceSelectionMessage = "Portion selection was cancelled."
                }
            } else {
                completeSourceSelection(filter: filter)
            }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            isPresentingSourcePicker = false
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

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

    let library: RecordingLibrary

    private var selectedFilter: SCContentFilter?
    private var multitrackRecorder: MultitrackRecorder?
    private var activeOutputURL: URL?
    private var countdownTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?

    override init() {
        let savedSettings = CaptureSettings.load()
        settings = savedSettings
        library = RecordingLibrary(directoryURL: Self.outputDirectory(for: savedSettings))
        super.init()

        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        refreshAudioInputDevices()
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
        selectedSourceKind = kind
        selectedFilter = nil
        hasSelectedSource = false
        state = .idle

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
                    self?.beginMetering()
                }
            }
            recorder.onFailure = { [weak self] error in
                Task { @MainActor in self?.handleFailure(error) }
            }
            multitrackRecorder = recorder
            activeOutputURL = outputURL
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

        let size = settings.resolution.outputSize(
            contentRect: filter.contentRect,
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
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func finishRecording() {
        meterTask?.cancel()
        meterTask = nil
        multitrackRecorder = nil

        if let activeOutputURL {
            lastRecordingURL = activeOutputURL
        }
        activeOutputURL = nil
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
}

extension CaptureCoordinator: SCContentSharingPickerObserver {
    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        if !hasSelectedSource {
            state = .idle
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        selectedFilter = filter
        hasSelectedSource = true
        state = .sourceSelected
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        handleFailure(error)
    }
}

enum CaptureError: LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is off. Enable it for Reccy in System Settings → Privacy & Security → Microphone."
        }
    }
}

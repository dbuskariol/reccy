@preconcurrency import AVFoundation
import Foundation

struct VoiceoverRecording: Sendable {
    let url: URL
    let duration: TimeInterval
}

enum VoiceoverRecorderError: LocalizedError {
    case noInputDevice
    case selectedInputUnavailable
    case cannotAddInput
    case cannotAddOutput
    case notRecording
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone input is available."
        case .selectedInputUnavailable: "The selected voiceover microphone is no longer available. Choose another input."
        case .cannotAddInput: "The selected microphone couldn’t be connected to the voiceover session."
        case .cannotAddOutput: "The voiceover file output couldn’t be configured."
        case .notRecording: "No voiceover recording is in progress."
        case .recordingFailed: "The voiceover recording couldn’t be finalized."
        }
    }
}

/// Records from an explicitly selected AVFoundation capture device. AVAudioRecorder
/// only records the system's active input, so a capture session is required for a
/// real per-device voiceover selector.
nonisolated final class VoiceoverRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.reccy.voiceover.capture", qos: .userInitiated)

    private var stopContinuation: CheckedContinuation<VoiceoverRecording, Error>?
    private var outputURL: URL?
    private var durationAtStop: TimeInterval = 0

    func start(to url: URL, deviceID: String?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    let device: AVCaptureDevice
                    if let deviceID {
                        guard let selected = AVCaptureDevice(uniqueID: deviceID), selected.isConnected else {
                            throw VoiceoverRecorderError.selectedInputUnavailable
                        }
                        device = selected
                    } else {
                        guard let defaultDevice = AVCaptureDevice.default(for: .audio) else {
                            throw VoiceoverRecorderError.noInputDevice
                        }
                        device = defaultDevice
                    }

                    session.beginConfiguration()
                    defer { session.commitConfiguration() }

                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        throw VoiceoverRecorderError.cannotAddInput
                    }
                    session.addInput(input)

                    guard session.canAddOutput(output) else {
                        throw VoiceoverRecorderError.cannotAddOutput
                    }
                    session.addOutput(output)
                    output.audioSettings = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 128_000,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    ]

                    outputURL = url
                    session.startRunning()
                    output.startRecording(
                        to: url,
                        outputFileType: .m4a,
                        recordingDelegate: self
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws -> VoiceoverRecording {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                guard output.isRecording else {
                    continuation.resume(throwing: VoiceoverRecorderError.notRecording)
                    return
                }
                durationAtStop = output.recordedDuration.seconds
                stopContinuation = continuation
                output.stopRecording()
            }
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        sessionQueue.async { [self] in
            session.stopRunning()
            guard let continuation = stopContinuation else { return }
            stopContinuation = nil

            if let error = error as NSError? {
                let finished = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
                guard finished else {
                    continuation.resume(throwing: error)
                    return
                }
            }

            let finalURL = self.outputURL ?? outputFileURL
            continuation.resume(returning: VoiceoverRecording(
                url: finalURL,
                duration: max(durationAtStop, output.recordedDuration.seconds)
            ))
        }
    }
}

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

nonisolated enum TranscriptionAudioReader {
    static func temporaryPCMTrack(
        mediaURL: URL,
        sourceTrackID: Int32
    ) async throws -> URL {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reccy Speech Track \(UUID().uuidString)")
            .appendingPathExtension("caf")
        do {
            // AVAudioFile flushes its container metadata when it is released. Keep the
            // writer in an inner scope so analyzeSequence(from:) never observes a
            // partially finalized CAF file.
            do {
                let output = try AVAudioFile(forWriting: destination, settings: format.settings)
                let packets = try await stream(
                    mediaURL: mediaURL,
                    sourceTrackID: sourceTrackID,
                    outputFormat: format
                )
                for try await packet in packets {
                    try output.write(from: packet.buffer)
                }
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func stream(
        mediaURL: URL,
        sourceTrackID: Int32,
        outputFormat: AVAudioFormat
    ) async throws -> TranscriptionAudioStream {
        let asset = AVURLAsset(url: mediaURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first(where: { $0.trackID == sourceTrackID }) else {
            throw TranscriptionEngineError.sourceTrackMissing(sourceTrackID)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outputFormat.sampleRate,
            AVNumberOfChannelsKey: outputFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: outputFormat.isInterleaved == false,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TranscriptionEngineError.cannotReadAudio }
        reader.add(output)
        return TranscriptionAudioStream(
            context: TranscriptionReaderContext(reader: reader, output: output)
        )
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw TranscriptionEngineError.cannotConvertAudio
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard
            frameCount > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { throw TranscriptionEngineError.cannotConvertAudio }

        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { throw TranscriptionEngineError.cannotConvertAudio }
        return buffer
    }

    static func convert(
        _ packet: TimedAudioBuffer,
        to outputFormat: AVAudioFormat
    ) throws -> TimedAudioBuffer {
        let input = packet.buffer
        if input.format == outputFormat { return packet }
        guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            throw TranscriptionEngineError.cannotConvertAudio
        }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw TranscriptionEngineError.cannotConvertAudio
        }

        let inputState = OSAllocatedUnfairLock(initialState: false)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            let shouldSupply = inputState.withLock { suppliedInput in
                if suppliedInput { return false }
                suppliedInput = true
                return true
            }
            inputStatus.pointee = shouldSupply ? .haveData : .endOfStream
            return shouldSupply ? input : nil
        }
        guard status != .error, conversionError == nil else {
            throw conversionError ?? TranscriptionEngineError.cannotConvertAudio
        }
        return TimedAudioBuffer(buffer: output, startTime: packet.startTime)
    }

    static func monoFloatSamples(from packet: TimedAudioBuffer) throws -> [Float] {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let converted = try convert(packet, to: format).buffer
        guard let channel = converted.floatChannelData?.pointee else {
            throw TranscriptionEngineError.cannotConvertAudio
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }
}

/// A pull-based exact-track sequence. AVAssetReader advances only when the
/// transcription engine asks for the next packet, providing natural
/// backpressure without buffering or dropping source audio during inference.
nonisolated struct TranscriptionAudioStream: AsyncSequence, Sendable {
    typealias Element = TimedAudioBuffer

    struct AsyncIterator: AsyncIteratorProtocol {
        private let context: TranscriptionReaderContext

        init(context: TranscriptionReaderContext) {
            self.context = context
        }

        mutating func next() async throws -> TimedAudioBuffer? {
            try await context.next()
        }
    }

    private let context: TranscriptionReaderContext

    init(context: TranscriptionReaderContext) {
        self.context = context
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(context: context)
    }
}

actor TranscriptionReaderContext {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var started = false

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        self.reader = reader
        self.output = output
    }

    func next() throws -> TimedAudioBuffer? {
        if Task.isCancelled {
            reader.cancelReading()
            throw CancellationError()
        }
        if !started {
            guard reader.startReading() else {
                throw reader.error ?? TranscriptionEngineError.cannotReadAudio
            }
            started = true
        }
        if let sampleBuffer = output.copyNextSampleBuffer() {
            return TimedAudioBuffer(
                buffer: try TranscriptionAudioReader.pcmBuffer(from: sampleBuffer),
                startTime: sampleBuffer.presentationTimeStamp
            )
        }
        if reader.status == .failed {
            throw reader.error ?? TranscriptionEngineError.cannotReadAudio
        }
        return nil
    }
}

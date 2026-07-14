@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

nonisolated enum TranscriptionAudioReader {
    static func stream(
        mediaURL: URL,
        sourceTrackID: Int32,
        outputFormat: AVAudioFormat
    ) async throws -> AsyncThrowingStream<TimedAudioBuffer, Error> {
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

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                guard reader.startReading() else {
                    continuation.finish(throwing: reader.error ?? TranscriptionEngineError.cannotReadAudio)
                    return
                }

                while !Task.isCancelled, let sampleBuffer = output.copyNextSampleBuffer() {
                    do {
                        let buffer = try pcmBuffer(from: sampleBuffer)
                        let result = continuation.yield(TimedAudioBuffer(
                            buffer: buffer,
                            startTime: sampleBuffer.presentationTimeStamp
                        ))
                        if case .terminated = result {
                            reader.cancelReading()
                            return
                        }
                    } catch {
                        reader.cancelReading()
                        continuation.finish(throwing: error)
                        return
                    }
                }

                if Task.isCancelled {
                    reader.cancelReading()
                    continuation.finish(throwing: CancellationError())
                } else if reader.status == .failed {
                    continuation.finish(throwing: reader.error ?? TranscriptionEngineError.cannotReadAudio)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
            inputState.withLock { suppliedInput in
                guard !suppliedInput else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return input
            }
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

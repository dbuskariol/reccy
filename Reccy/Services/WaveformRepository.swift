@preconcurrency import AVFoundation
import DSWaveformImage
import Foundation

struct WaveformSliceRequest: Hashable, Sendable {
    var sourceURL: URL
    var sourceTrackID: Int32?
    var sourceStart: TimeInterval
    var duration: TimeInterval?
    var sampleCount: Int
}

actor WaveformRepository {
    static let shared = WaveformRepository()

    private struct TrackKey: Hashable, Sendable {
        var sourceURL: URL
        var sourceTrackID: Int32?
    }

    private struct CachedTrack: Sendable {
        var samples: [Float]
        var duration: TimeInterval
    }

    private var trackTasks: [TrackKey: Task<CachedTrack, Error>] = [:]

    func samples(for request: WaveformSliceRequest) async throws -> [Float] {
        let key = TrackKey(
            sourceURL: request.sourceURL,
            sourceTrackID: request.sourceTrackID
        )
        let cached = try await cachedTrack(for: key)
        return Self.slice(
            cached,
            sourceStart: request.sourceStart,
            duration: request.duration,
            sampleCount: request.sampleCount
        )
    }

    func invalidate(sourceURL: URL) {
        trackTasks = trackTasks.filter { $0.key.sourceURL != sourceURL }
    }

    func clear() {
        trackTasks.removeAll()
    }

    private func cachedTrack(for key: TrackKey) async throws -> CachedTrack {
        if let task = trackTasks[key] {
            return try await task.value
        }

        let task = Task.detached(priority: .userInitiated) {
            try await Self.analyzeTrack(key)
        }
        trackTasks[key] = task

        do {
            return try await task.value
        } catch {
            trackTasks[key] = nil
            throw error
        }
    }

    private static func analyzeTrack(_ key: TrackKey) async throws -> CachedTrack {
        let asset = AVURLAsset(
            url: key.sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let sourceTrack = key.sourceTrackID.flatMap({ requestedID in
            audioTracks.first(where: { $0.trackID == requestedID })
        }) ?? audioTracks.first else {
            throw WaveformAnalyzer.AnalyzeError.emptyTracks
        }

        let timeRange = try await sourceTrack.load(.timeRange)
        let duration = max(0, timeRange.duration.seconds)
        guard duration.isFinite, duration > 0 else {
            return CachedTrack(samples: [1], duration: 0)
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw WaveformAnalyzer.AnalyzeError.emptyTracks
        }
        try compositionTrack.insertTimeRange(timeRange, of: sourceTrack, at: .zero)

        // 180 envelope points per second preserves speech transients at the
        // editor's maximum practical zoom while keeping hour-long recordings
        // compact in memory. DSWaveformImage performs peak-aware downsampling.
        let sampleCount = min(max(Int(ceil(duration * 180)), 2_048), 900_000)
        var analyzer = WaveformAnalyzer()
        analyzer.noiseFloorDecibelCutoff = -60
        let samples = try await analyzer.samples(
            fromAsset: composition,
            count: sampleCount,
            channelSelection: .merged,
            qos: .userInitiated
        )
        return CachedTrack(samples: samples, duration: duration)
    }

    private static func slice(
        _ cached: CachedTrack,
        sourceStart: TimeInterval,
        duration requestedDuration: TimeInterval?,
        sampleCount requestedSampleCount: Int
    ) -> [Float] {
        let outputCount = max(2, requestedSampleCount)
        guard cached.duration > 0, !cached.samples.isEmpty else {
            return Array(repeating: 1, count: outputCount)
        }

        let start = min(max(sourceStart, 0), cached.duration)
        let availableDuration = max(0, cached.duration - start)
        let duration = min(max(requestedDuration ?? availableDuration, 0), availableDuration)
        guard duration > 0 else {
            return Array(repeating: 1, count: outputCount)
        }

        let lower = min(
            cached.samples.count - 1,
            max(0, Int(floor(start / cached.duration * Double(cached.samples.count))))
        )
        let upper = min(
            cached.samples.count,
            max(lower + 1, Int(ceil((start + duration) / cached.duration * Double(cached.samples.count))))
        )
        let segment = Array(cached.samples[lower..<upper])
        return resample(segment, to: outputCount)
    }

    private static func resample(_ input: [Float], to outputCount: Int) -> [Float] {
        guard !input.isEmpty else { return Array(repeating: 1, count: outputCount) }
        guard input.count != outputCount else { return input }

        if input.count > outputCount {
            // DSWaveformImage represents peaks near zero and silence near one.
            // Taking each bucket's minimum preserves transient detail instead
            // of averaging clicks and speech consonants out of the timeline.
            return (0..<outputCount).map { index in
                let lower = index * input.count / outputCount
                let upper = max(lower + 1, (index + 1) * input.count / outputCount)
                return input[lower..<min(upper, input.count)].min() ?? 1
            }
        }

        guard input.count > 1 else { return Array(repeating: input[0], count: outputCount) }
        return (0..<outputCount).map { index in
            let position = Double(index) / Double(max(outputCount - 1, 1)) * Double(input.count - 1)
            let lower = Int(floor(position))
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(position - Double(lower))
            return input[lower] + (input[upper] - input[lower]) * fraction
        }
    }
}

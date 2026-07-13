import AppKit
import AVFAudio
import AVFoundation
import Combine
import Foundation

enum TimelineEditorError: LocalizedError {
    case noMedia
    case noProject
    case microphonePermissionDenied
    case voiceoverCouldNotStart
    case exportUnsupported

    var errorDescription: String? {
        switch self {
        case .noMedia: "The recording doesn’t contain editable video or audio tracks."
        case .noProject: "Open a recording in the editor first."
        case .microphonePermissionDenied: "Microphone access is required to record a voiceover."
        case .voiceoverCouldNotStart: "The voiceover recorder couldn’t start."
        case .exportUnsupported: "That export format isn’t compatible with this project."
        }
    }
}

@MainActor
final class TimelineEditorController: ObservableObject {
    @Published private(set) var project: TimelineProject?
    @Published private(set) var isLoading = false
    @Published private(set) var isRebuilding = false
    @Published private(set) var isVoiceoverRecording = false
    @Published var selectedClipID: UUID?
    @Published var playhead: TimeInterval = 0
    @Published var pixelsPerSecond: Double = 72
    @Published var errorMessage: String?

    let player = AVPlayer()

    private var composition: AVMutableComposition?
    private var voiceoverRecorder: AVAudioRecorder?
    private var voiceoverStartTime: TimeInterval = 0
    private var projectPackageURL: URL?

    var duration: TimeInterval { max(project?.duration ?? 0, 0.01) }
    var hasProject: Bool { project != nil }
    var isPlaying: Bool { player.timeControlStatus == .playing }

    func open(_ item: RecordingItem) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let asset = AVURLAsset(url: item.url)
            let duration = try await asset.load(.duration).seconds
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
                throw TimelineEditorError.noMedia
            }

            let linkedGroupID = UUID()
            var lanes: [TimelineLane] = []
            if let videoTrack = videoTracks.first {
                lanes.append(
                    TimelineLane(
                        kind: .video,
                        name: "Screen",
                        clips: [
                            TimelineClip(
                                sourceURL: item.url,
                                sourceTrackID: videoTrack.trackID,
                                sourceStart: 0,
                                timelineStart: 0,
                                duration: duration,
                                name: item.name,
                                linkedGroupID: linkedGroupID
                            ),
                        ]
                    )
                )
            }

            for (index, track) in audioTracks.enumerated() {
                let kind: TimelineLaneKind = index == 0 ? .systemAudio : .microphone
                let name = audioTracks.count == 1 ? "Recorded Audio" : kind.title
                lanes.append(
                    TimelineLane(
                        kind: kind,
                        name: name,
                        clips: [
                            TimelineClip(
                                sourceURL: item.url,
                                sourceTrackID: track.trackID,
                                sourceStart: 0,
                                timelineStart: 0,
                                duration: duration,
                                name: name,
                                linkedGroupID: linkedGroupID
                            ),
                        ]
                    )
                )
            }

            let packageURL = item.url
                .deletingLastPathComponent()
                .appendingPathComponent("Projects", isDirectory: true)
                .appendingPathComponent("\(item.name).reccyproject", isDirectory: true)
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            projectPackageURL = packageURL
            project = TimelineProject(name: item.name, lanes: lanes)
            playhead = 0
            selectedClipID = lanes.first?.clips.first?.id
            try await rebuildComposition()
            try save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func splitAllAtPlayhead() {
        guard var project else { return }
        project.splitAll(at: playhead)
        self.project = project
        selectedClipID = project.lanes
            .flatMap(\.clips)
            .first(where: { abs($0.timelineStart - playhead) < 0.002 })?.id
        rebuildAndSave()
    }

    func splitSelectionAtPlayhead() {
        guard var project, let selectedClipID else { return }
        guard let rightClipID = project.splitClip(id: selectedClipID, at: playhead) else { return }
        self.project = project
        self.selectedClipID = rightClipID
        rebuildAndSave()
    }

    func deleteSelection() {
        guard var project, let selectedClipID else { return }
        project.deleteClip(id: selectedClipID)
        self.project = project
        self.selectedClipID = nil
        rebuildAndSave()
    }

    func rippleDeleteSelection() {
        guard
            var project,
            let selectedClipID,
            let selected = project.lanes.flatMap(\.clips).first(where: { $0.id == selectedClipID })
        else { return }

        project.rippleDelete(timeRange: selected.timelineStart..<selected.timelineEnd)
        self.project = project
        self.selectedClipID = nil
        playhead = min(playhead, project.duration)
        rebuildAndSave()
    }

    func select(_ clip: TimelineClip) {
        selectedClipID = clip.id
        seek(to: clip.timelineStart)
    }

    func toggleMute(laneID: UUID) {
        guard var project, let index = project.lanes.firstIndex(where: { $0.id == laneID }) else { return }
        project.lanes[index].isMuted.toggle()
        project.modifiedAt = Date()
        self.project = project
        rebuildAndSave()
    }

    func setVolume(_ volume: Double, laneID: UUID) {
        guard var project, let index = project.lanes.firstIndex(where: { $0.id == laneID }) else { return }
        project.lanes[index].volume = min(max(volume, 0), 2)
        project.modifiedAt = Date()
        self.project = project
        rebuildAndSave()
    }

    func playPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if playhead >= duration - 0.05 {
                seek(to: 0)
            }
            player.play()
        }
        objectWillChange.send()
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), duration)
        playhead = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func syncPlayheadFromPlayer() {
        guard player.timeControlStatus == .playing else { return }
        let current = player.currentTime().seconds
        if current.isFinite {
            playhead = min(max(current, 0), duration)
        }
        objectWillChange.send()
    }

    func toggleVoiceover() {
        if isVoiceoverRecording {
            stopVoiceover()
        } else {
            Task { await startVoiceover() }
        }
    }

    func save() throws {
        guard let project, let packageURL = projectPackageURL else {
            throw TimelineEditorError.noProject
        }
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.reccy.encode(project)
        try data.write(to: packageURL.appendingPathComponent("project.json"), options: .atomic)
    }

    func export(to destinationURL: URL, preset: ExportPreset) async throws {
        guard let composition else { throw TimelineEditorError.noProject }
        guard let snapshot = composition.copy() as? AVComposition else {
            throw TimelineEditorError.noProject
        }
        try await ExportService().export(asset: snapshot, destinationURL: destinationURL, preset: preset)
    }

    private func rebuildAndSave() {
        Task {
            do {
                try await rebuildComposition()
                try save()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rebuildComposition() async throws {
        guard let project else { throw TimelineEditorError.noProject }
        isRebuilding = true
        defer { isRebuilding = false }

        let newComposition = AVMutableComposition()
        var audioParameters: [AVMutableAudioMixInputParameters] = []

        for lane in project.lanes where !lane.clips.isEmpty {
            guard let compositionTrack = newComposition.addMutableTrack(
                withMediaType: lane.kind.mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            for clip in lane.clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                let asset = AVURLAsset(url: clip.sourceURL)
                let tracks = try await asset.loadTracks(withMediaType: lane.kind.mediaType)
                guard let sourceTrack = tracks.first(where: { $0.trackID == clip.sourceTrackID }) else {
                    continue
                }
                let sourceRange = CMTimeRange(
                    start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
                )
                try compositionTrack.insertTimeRange(
                    sourceRange,
                    of: sourceTrack,
                    at: CMTime(seconds: clip.timelineStart, preferredTimescale: 600)
                )

                if lane.kind == .video {
                    compositionTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)
                }
            }

            if lane.kind != .video {
                let parameters = AVMutableAudioMixInputParameters(track: compositionTrack)
                parameters.setVolume(lane.isMuted ? 0 : Float(lane.volume), at: .zero)
                audioParameters.append(parameters)
            }
        }

        let snapshot = (newComposition.copy() as? AVComposition) ?? newComposition
        let item = AVPlayerItem(asset: snapshot)
        if !audioParameters.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioParameters
            item.audioMix = audioMix
        }

        composition = newComposition
        player.replaceCurrentItem(with: item)
        seek(to: min(playhead, project.duration))
    }

    private func startVoiceover() async {
        do {
            guard project != nil else { throw TimelineEditorError.noProject }
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                granted = true
            case .notDetermined:
                granted = await AVCaptureDevice.requestAccess(for: .audio)
            default:
                granted = false
            }
            guard granted else { throw TimelineEditorError.microphonePermissionDenied }
            guard let packageURL = projectPackageURL else { throw TimelineEditorError.noProject }

            let mediaDirectory = packageURL.appendingPathComponent("Media", isDirectory: true)
            try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            let url = mediaDirectory
                .appendingPathComponent("Voiceover \(UUID().uuidString)")
                .appendingPathExtension("m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.prepareToRecord()
            guard recorder.record() else { throw TimelineEditorError.voiceoverCouldNotStart }

            voiceoverRecorder = recorder
            voiceoverStartTime = playhead
            isVoiceoverRecording = true
            player.play()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopVoiceover() {
        guard let recorder = voiceoverRecorder else { return }
        let recordedDuration = recorder.currentTime
        let url = recorder.url
        recorder.stop()
        player.pause()
        voiceoverRecorder = nil
        isVoiceoverRecording = false

        guard recordedDuration > 0.05 else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        Task {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw TimelineEditorError.noMedia
                }
                guard var project else { throw TimelineEditorError.noProject }
                let clip = TimelineClip(
                    sourceURL: url,
                    sourceTrackID: track.trackID,
                    sourceStart: 0,
                    timelineStart: voiceoverStartTime,
                    duration: recordedDuration,
                    name: "Voiceover",
                    linkedGroupID: nil
                )
                if let laneIndex = project.lanes.firstIndex(where: { $0.kind == .voiceover }) {
                    project.lanes[laneIndex].clips.append(clip)
                } else {
                    project.lanes.append(
                        TimelineLane(kind: .voiceover, name: "Voiceover", clips: [clip])
                    )
                }
                project.modifiedAt = Date()
                self.project = project
                selectedClipID = clip.id
                try await rebuildComposition()
                try save()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension JSONEncoder {
    static var reccy: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

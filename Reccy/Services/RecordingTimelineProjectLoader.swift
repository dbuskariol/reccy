import AVFoundation
import CoreGraphics
import Foundation

struct LoadedTimelineProject {
    let project: TimelineProject
    let sourceDurations: [URL: TimeInterval]
    let needsInitialSave: Bool
}

/// Loads the non-destructive project for a recording or creates the canonical
/// first project directly from its independent media tracks.
///
/// Library playback and Editor playback deliberately share this path so the
/// camera overlay has one default layout and saved edits preview identically
/// everywhere in the app.
@MainActor
enum RecordingTimelineProjectLoader {
    static func initialProject(for item: RecordingItem) async throws -> TimelineProject {
        try await makeInitialProject(for: item).project
    }

    static func load(
        for item: RecordingItem,
        packageURL: URL? = nil
    ) async throws -> LoadedTimelineProject {
        let resolvedPackageURL = packageURL ?? item.artifacts.projectPackageURL
        let savedProjectURL = resolvedPackageURL.appendingPathComponent("project.json")
        if FileManager.default.fileExists(atPath: savedProjectURL.path) {
            let data = try Data(contentsOf: savedProjectURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let header = try decoder.decode(TimelineProjectHeader.self, from: data)
            guard (3...TimelineProject.currentFormatVersion).contains(header.formatVersion) else {
                throw TimelineEditorError.projectFormatUnsupported
            }
            var savedProject = try decoder.decode(TimelineProject.self, from: data)
            let needsMigrationSave = savedProject.formatVersion != TimelineProject.currentFormatVersion
            savedProject.formatVersion = TimelineProject.currentFormatVersion
            var durations: [URL: TimeInterval] = [:]
            for url in Set(savedProject.lanes.flatMap(\.clips).map(\.sourceURL)) {
                durations[url] = try await AVURLAsset(url: url).load(.duration).seconds
            }
            return LoadedTimelineProject(
                project: savedProject,
                sourceDurations: durations,
                needsInitialSave: needsMigrationSave
            )
        }

        return try await makeInitialProject(for: item)
    }

    /// Builds the same rendered recording that Library previews and Editor
    /// opens. Direct Library delivery must not bypass this path: doing so drops
    /// the camera overlay, saved edits, captions, and timeline audio choices.
    static func exportSource(for item: RecordingItem) async throws -> ExportSource {
        let loaded = try await load(for: item)
        try Task.checkCancellation()
        let build = try await TimelineCompositionBuilder.build(loaded.project)
        try Task.checkCancellation()
        return ExportSource(
            name: item.name,
            asset: build.composition,
            sourceURL: item.url,
            videoComposition: TimelineCaptionVideoRenderer.applying(
                loaded.project.captionTrack,
                to: build.videoComposition,
                projectDuration: loaded.project.duration
            ),
            audioMix: build.audioMix
        )
    }

    private static func makeInitialProject(for item: RecordingItem) async throws -> LoadedTimelineProject {
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
            lanes.append(TimelineLane(
                kind: .video,
                name: "Screen",
                clips: [TimelineClip(
                    sourceURL: item.url,
                    sourceTrackID: videoTrack.trackID,
                    sourceStart: 0,
                    timelineStart: 0,
                    duration: duration,
                    name: item.name,
                    linkedGroupID: linkedGroupID
                )]
            ))
        }

        if let camera = item.manifest.camera, videoTracks.indices.contains(1) {
            let cameraTrack = videoTracks[1]
            let cameraTimeRange = try await cameraTrack.load(.timeRange)
            let sourceStart = max(0, cameraTimeRange.start.seconds)
            let cameraDuration = min(duration, max(0, cameraTimeRange.duration.seconds))
            if cameraDuration > 0 {
                let layout = TimelineVideoLayout.defaultCamera(
                    canvasSize: CGSize(
                        width: CGFloat(item.manifest.width),
                        height: CGFloat(item.manifest.height)
                    ),
                    sourceSize: CGSize(
                        width: CGFloat(camera.width),
                        height: CGFloat(camera.height)
                    )
                )
                lanes.append(TimelineLane(
                    kind: .camera,
                    name: camera.name,
                    clips: [TimelineClip(
                        sourceURL: item.url,
                        sourceTrackID: cameraTrack.trackID,
                        sourceStart: sourceStart,
                        timelineStart: sourceStart,
                        duration: cameraDuration,
                        name: camera.name,
                        linkedGroupID: linkedGroupID,
                        videoLayout: layout
                    )]
                ))
            }
        }

        var audioLaneDescriptions: [(kind: TimelineLaneKind, name: String)] = []
        if item.manifest.includesSystemAudio {
            audioLaneDescriptions.append((.systemAudio, "System Audio"))
        }
        if item.manifest.includesMicrophone {
            audioLaneDescriptions.append((
                .microphone,
                item.manifest.microphoneName ?? "Microphone"
            ))
        }

        for (track, description) in zip(audioTracks, audioLaneDescriptions) {
            lanes.append(TimelineLane(
                kind: description.kind,
                name: description.name,
                clips: [TimelineClip(
                    sourceURL: item.url,
                    sourceTrackID: track.trackID,
                    sourceStart: 0,
                    timelineStart: 0,
                    duration: duration,
                    name: description.name,
                    linkedGroupID: linkedGroupID
                )]
            ))
        }

        return LoadedTimelineProject(
            project: TimelineProject(
                name: item.name,
                frameRate: Double(item.manifest.frameRate),
                lanes: lanes
            ),
            sourceDurations: [item.url: duration],
            needsInitialSave: true
        )
    }
}

private struct TimelineProjectHeader: Decodable {
    let formatVersion: Int
}

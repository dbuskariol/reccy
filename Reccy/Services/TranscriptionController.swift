@preconcurrency import AVFoundation
import Foundation
import Speech

nonisolated enum TranscriptionJobState: Equatable, Sendable {
    case idle
    case queued
    case working(TranscriptionProgressUpdate)
    case ready
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .queued, .working: true
        default: false
        }
    }
}

@MainActor
final class TranscriptionController: ObservableObject {
    @Published var provider: TranscriptionProvider {
        didSet {
            defaults.set(provider.rawValue, forKey: Keys.provider)
            prewarmSelectedLiveEngine()
        }
    }
    @Published var automaticallyTranscribe: Bool {
        didSet { defaults.set(automaticallyTranscribe, forKey: Keys.automaticallyTranscribe) }
    }
    @Published var showLiveTranscript: Bool {
        didSet {
            defaults.set(showLiveTranscript, forKey: Keys.showLiveTranscript)
            prewarmSelectedLiveEngine()
        }
    }
    @Published var transcribeSystemAudio: Bool {
        didSet { defaults.set(transcribeSystemAudio, forKey: Keys.systemAudio) }
    }
    @Published var transcribeMicrophone: Bool {
        didSet { defaults.set(transcribeMicrophone, forKey: Keys.microphone) }
    }
    @Published var localeIdentifier: String {
        didSet {
            defaults.set(localeIdentifier, forKey: Keys.locale)
            prewarmSelectedLiveEngine()
        }
    }
    @Published var whisperModelIdentifier: String {
        didSet {
            defaults.set(whisperModelIdentifier, forKey: Keys.whisperModel)
            whisperEngine = nil
            prewarmSelectedLiveEngine()
        }
    }
    @Published private(set) var supportedLocales: [Locale] = []
    @Published private(set) var appleAvailability: TranscriptionEngineAvailability = .requiresDownload
    @Published private(set) var applePreparationProgress: TranscriptionProgressUpdate?
    @Published private(set) var applePreparationError: String?
    @Published private(set) var availableWhisperModels: [String] = []
    @Published private(set) var installedWhisperModels: [WhisperModelRecord] = []
    @Published private(set) var whisperDownloadProgress: Double?
    @Published private(set) var whisperModelError: String?
    @Published private(set) var jobs: [URL: TranscriptionJobState] = [:]
    @Published private(set) var documents: [URL: TranscriptDocument] = [:]
    @Published private(set) var liveUpdates: [TranscriptTrackRole: LiveTranscriptUpdate] = [:]
    @Published private(set) var liveNotice: String?

    nonisolated let liveRouter = LiveTranscriptionRouter()
    private let defaults: UserDefaults
    private let store = TranscriptStore()
    private let modelManager: WhisperModelManager
    private let appleEngine = AppleSpeechTranscriptionEngine()
    private var whisperEngine: WhisperKitTranscriptionEngine?
    private var transcriptionTasks: [URL: Task<Void, Never>] = [:]
    private var liveSetupTask: Task<Void, Never>?
    private var livePrewarmTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, modelManager: WhisperModelManager = WhisperModelManager()) {
        self.defaults = defaults
        self.modelManager = modelManager
        provider = TranscriptionProvider(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .appleSpeech
        automaticallyTranscribe = defaults.object(forKey: Keys.automaticallyTranscribe) as? Bool ?? true
        showLiveTranscript = defaults.object(forKey: Keys.showLiveTranscript) as? Bool ?? true
        transcribeSystemAudio = defaults.object(forKey: Keys.systemAudio) as? Bool ?? true
        transcribeMicrophone = defaults.object(forKey: Keys.microphone) as? Bool ?? true
        localeIdentifier = defaults.string(forKey: Keys.locale) ?? Locale.current.identifier
        whisperModelIdentifier = defaults.string(forKey: Keys.whisperModel)
            ?? WhisperModelManager.recommendedModel
    }

    func refreshCapabilities() {
        Task {
            supportedLocales = await SpeechTranscriber.supportedLocales.sorted {
                localizedLocaleName($0) < localizedLocaleName($1)
            }
            appleAvailability = await appleEngine.availability(localeIdentifier: localeIdentifier)
            do {
                try await modelManager.load()
                installedWhisperModels = await modelManager.installedModels()
                availableWhisperModels = try await modelManager.availableModels()
                whisperModelError = nil
            } catch {
                installedWhisperModels = await modelManager.installedModels()
                if availableWhisperModels.isEmpty {
                    availableWhisperModels = [
                        WhisperModelManager.recommendedModel,
                        WhisperModelManager.compactModel,
                    ]
                }
                whisperModelError = error.localizedDescription
            }
        }
    }

    func downloadSelectedWhisperModel() {
        guard whisperDownloadProgress == nil else { return }
        whisperModelError = nil
        whisperDownloadProgress = 0
        let identifier = whisperModelIdentifier
        Task {
            do {
                _ = try await modelManager.download(identifier) { [weak self] fraction in
                    Task { @MainActor in self?.whisperDownloadProgress = fraction }
                }
                installedWhisperModels = await modelManager.installedModels()
                whisperDownloadProgress = nil
                whisperEngine = nil
                prewarmSelectedLiveEngine()
            } catch {
                whisperDownloadProgress = nil
                whisperModelError = error.localizedDescription
            }
        }
    }

    func prepareAppleSpeech() {
        applePreparationError = nil
        Task {
            do {
                try await appleEngine.prepare(localeIdentifier: localeIdentifier) { [weak self] update in
                    Task { @MainActor in self?.applePreparationProgress = update }
                }
                appleAvailability = .ready
                applePreparationProgress = nil
            } catch {
                applePreparationProgress = nil
                applePreparationError = error.localizedDescription
                appleAvailability = .unavailable(error.localizedDescription)
            }
        }
    }

    func removeWhisperModel(_ identifier: String) {
        Task {
            do {
                try await modelManager.remove(identifier)
                installedWhisperModels = await modelManager.installedModels()
                whisperEngine = nil
            } catch {
                whisperModelError = error.localizedDescription
            }
        }
    }

    /// Loads the selected local WhisperKit model while the user configures a
    /// recording, so capture never owns the expensive Core ML cold start.
    /// WhisperKitTranscriptionEngine.prepare coalesces this work with any
    /// concurrent post-recording or live request.
    func prewarmSelectedLiveEngine() {
        livePrewarmTask?.cancel()
        livePrewarmTask = nil
        guard showLiveTranscript, provider == .whisperKit else { return }
        let selectedLocale = localeIdentifier
        let selectedModel = whisperModelIdentifier
        let engine = engine(for: .whisperKit)
        livePrewarmTask = Task { [weak self] in
            guard let self else { return }
            let availability = await engine.availability(localeIdentifier: selectedLocale)
            guard availability == .ready, !Task.isCancelled else {
                if whisperModelIdentifier == selectedModel { livePrewarmTask = nil }
                return
            }
            do {
                try await engine.prepare(localeIdentifier: selectedLocale) { _ in }
                if whisperModelIdentifier == selectedModel { whisperModelError = nil }
            } catch is CancellationError {
                // A new provider, locale, or model superseded this prewarm.
            } catch {
                if whisperModelIdentifier == selectedModel {
                    whisperModelError = error.localizedDescription
                }
            }
            if whisperModelIdentifier == selectedModel { livePrewarmTask = nil }
        }
    }

    func jobState(for mediaURL: URL) -> TranscriptionJobState {
        jobs[mediaURL] ?? (documents[mediaURL] == nil ? .idle : .ready)
    }

    func document(for mediaURL: URL) -> TranscriptDocument? { documents[mediaURL] }

    func loadDocument(for mediaURL: URL) {
        Task {
            do {
                if let document = try await store.load(for: mediaURL) {
                    documents[mediaURL] = document
                    jobs[mediaURL] = .ready
                }
            } catch {
                jobs[mediaURL] = .failed(error.localizedDescription)
            }
        }
    }

    func transcribe(_ recording: RecordingItem, replacingExisting: Bool = true) {
        transcribe(mediaURL: recording.url, manifest: recording.manifest, replacingExisting: replacingExisting)
    }

    func transcribe(
        mediaURL: URL,
        manifest: RecordingManifest,
        replacingExisting: Bool = true
    ) {
        transcriptionTasks[mediaURL]?.cancel()
        jobs[mediaURL] = .queued
        let selectedProvider = provider
        let selectedLocale = localeIdentifier
        let includeSystem = transcribeSystemAudio && manifest.includesSystemAudio
        let includeMicrophone = transcribeMicrophone && manifest.includesMicrophone
        transcriptionTasks[mediaURL] = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = engine(for: selectedProvider)
                let tracks = try await AVURLAsset(url: mediaURL).loadTracks(withMediaType: .audio)
                var requests: [TranscriptionTrackRequest] = []
                var index = 0
                if includeSystem, tracks.indices.contains(index) {
                    requests.append(.init(
                        mediaURL: mediaURL,
                        sourceTrackID: tracks[index].trackID,
                        role: .systemAudio,
                        name: "System Audio",
                        localeIdentifier: selectedLocale
                    ))
                    index += 1
                } else if manifest.includesSystemAudio {
                    index += 1
                }
                if includeMicrophone, tracks.indices.contains(index) {
                    requests.append(.init(
                        mediaURL: mediaURL,
                        sourceTrackID: tracks[index].trackID,
                        role: .microphone,
                        name: manifest.microphoneName ?? "Microphone",
                        localeIdentifier: selectedLocale
                    ))
                }
                guard !requests.isEmpty else {
                    throw TranscriptionEngineError.noSpeechRecognized
                }

                var document = replacingExisting
                    ? TranscriptDocument(mediaFileName: mediaURL.lastPathComponent, tracks: [])
                    : (try await store.load(for: mediaURL)
                        ?? TranscriptDocument(mediaFileName: mediaURL.lastPathComponent, tracks: []))
                for request in requests {
                    try Task.checkCancellation()
                    let track = try await engine.transcribe(request) { [weak self] update in
                        Task { @MainActor in self?.jobs[mediaURL] = .working(update) }
                    }
                    document.replace(track)
                    try await store.save(document, for: mediaURL)
                    documents[mediaURL] = document
                }
                jobs[mediaURL] = .ready
            } catch is CancellationError {
                jobs[mediaURL] = documents[mediaURL] == nil ? .idle : .ready
            } catch {
                jobs[mediaURL] = .failed(error.localizedDescription)
            }
            transcriptionTasks[mediaURL] = nil
        }
    }

    func cancelTranscription(for mediaURL: URL) {
        transcriptionTasks[mediaURL]?.cancel()
        transcriptionTasks[mediaURL] = nil
    }

    func transcribeMissingSources(in project: TimelineProject) {
        let audioLanes = project.lanes.filter { $0.kind != .video }
        let grouped = Dictionary(grouping: audioLanes.flatMap { lane in
            lane.clips.map { clip in
                ProjectTrackRequest(
                    mediaURL: clip.sourceURL,
                    sourceTrackID: clip.sourceTrackID,
                    role: TranscriptTrackRole(laneKind: lane.kind),
                    name: lane.name
                )
            }
        }, by: \.mediaURL)

        for (mediaURL, values) in grouped {
            let unique = Dictionary(grouping: values, by: { "\($0.sourceTrackID):\($0.role.rawValue)" })
                .compactMap(\.value.first)
            transcriptionTasks[mediaURL]?.cancel()
            jobs[mediaURL] = .queued
            let engine = engine(for: provider)
            let selectedLocale = localeIdentifier
            transcriptionTasks[mediaURL] = Task { [weak self] in
                guard let self else { return }
                do {
                    var document = try await store.load(for: mediaURL)
                        ?? TranscriptDocument(mediaFileName: mediaURL.lastPathComponent, tracks: [])
                    for value in unique where document.track(
                        sourceTrackID: value.sourceTrackID,
                        role: value.role
                    ) == nil {
                        let request = TranscriptionTrackRequest(
                            mediaURL: mediaURL,
                            sourceTrackID: value.sourceTrackID,
                            role: value.role,
                            name: value.name,
                            localeIdentifier: selectedLocale
                        )
                        let track = try await engine.transcribe(request) { [weak self] update in
                            Task { @MainActor in self?.jobs[mediaURL] = .working(update) }
                        }
                        document.replace(track)
                        try await store.save(document, for: mediaURL)
                    }
                    documents[mediaURL] = document
                    jobs[mediaURL] = .ready
                } catch {
                    jobs[mediaURL] = .failed(error.localizedDescription)
                }
                transcriptionTasks[mediaURL] = nil
            }
        }
    }

    func beginLive(systemAudio: Bool, microphone: Bool, microphoneName: String) {
        liveSetupTask?.cancel()
        liveUpdates = [:]
        liveNotice = nil
        let selectedProvider = provider
        let selectedLocale = localeIdentifier
        let roles: [(TranscriptTrackRole, String)] = [
            systemAudio && transcribeSystemAudio ? (.systemAudio, "System Audio") : nil,
            microphone && transcribeMicrophone ? (.microphone, microphoneName) : nil,
        ].compactMap { $0 }
        guard showLiveTranscript, !roles.isEmpty else {
            liveSetupTask = nil
            return
        }
        liveNotice = "Preparing \(selectedProvider.title) for live transcription…"
        liveSetupTask = Task { [weak self] in
            guard let self else { return }
            let engine = engine(for: selectedProvider)
            let availability = await engine.availability(localeIdentifier: selectedLocale)
            if case .unavailable(let reason) = availability {
                liveNotice = reason
                return
            }
            if selectedProvider == .whisperKit, availability == .requiresDownload {
                liveNotice = "Download the selected WhisperKit model in Settings to enable live transcription."
                return
            }
            do {
                var sessions: [TranscriptTrackRole: any LiveTranscriptionSession] = [:]
                for (role, name) in roles {
                    sessions[role] = try await engine.makeLiveSession(
                        role: role,
                        name: name,
                        localeIdentifier: selectedLocale
                    ) { [weak self] update in
                        Task { @MainActor in self?.liveUpdates[update.role] = update }
                    }
                }
                await liveRouter.install(sessions)
                guard !Task.isCancelled else { return }
                liveNotice = nil
            } catch {
                liveNotice = error.localizedDescription
            }
        }
    }

    func finishLive(mediaURL: URL, manifest: RecordingManifest) {
        let setup = liveSetupTask
        liveSetupTask = nil
        jobs[mediaURL] = .working(.init(
            phase: .finalizing,
            fractionCompleted: nil,
            detail: "Finalizing live transcript"
        ))
        Task { [weak self] in
            guard let self else { return }
            await setup?.value
            let audioTracks = (try? await AVURLAsset(url: mediaURL).loadTracks(withMediaType: .audio)) ?? []
            var trackIDs: [TranscriptTrackRole: Int32] = [:]
            var index = 0
            if manifest.includesSystemAudio, audioTracks.indices.contains(index) {
                trackIDs[.systemAudio] = audioTracks[index].trackID
                index += 1
            }
            if manifest.includesMicrophone, audioTracks.indices.contains(index) {
                trackIDs[.microphone] = audioTracks[index].trackID
            }
            let liveTracks = await liveRouter.finish(trackIDs: trackIDs)
            if !liveTracks.isEmpty {
                var document = (try? await store.load(for: mediaURL))
                    ?? TranscriptDocument(mediaFileName: mediaURL.lastPathComponent, tracks: [])
                for track in liveTracks where !track.segments.isEmpty { document.replace(track) }
                try? await store.save(document, for: mediaURL)
                documents[mediaURL] = document
                jobs[mediaURL] = .ready
            } else {
                jobs[mediaURL] = .idle
            }
            liveUpdates = [:]
            if automaticallyTranscribe {
                transcribe(mediaURL: mediaURL, manifest: manifest)
            }
        }
    }

    func cancelLive() {
        liveSetupTask?.cancel()
        liveSetupTask = nil
        Task { await liveRouter.cancel() }
        liveUpdates = [:]
        liveNotice = nil
    }

    func export(
        document: TranscriptDocument,
        project: TimelineProject,
        format: TranscriptExportFormat,
        to url: URL
    ) throws {
        let sourceURLs = Set(project.lanes.flatMap(\.clips).map(\.sourceURL))
        let documentsByURL = Dictionary(uniqueKeysWithValues: sourceURLs.map { sourceURL in
            (sourceURL, sourceURL.lastPathComponent == document.mediaFileName ? document : documents[sourceURL])
        }.compactMap { key, value in value.map { (key, $0) } })
        let segments = TranscriptProjection.project(project: project, documentsByMediaURL: documentsByURL)
        try TranscriptExportFormatter.string(segments: segments, format: format)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    func localizedLocaleName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    func whisperModelDisplayName(_ identifier: String) -> String {
        WhisperKitTranscriptionEngine.displayName(identifier)
    }

    func isWhisperModelInstalled(_ identifier: String) -> Bool {
        installedWhisperModels.contains { $0.id == identifier }
    }

    private func engine(for provider: TranscriptionProvider) -> any TranscriptionEngine {
        switch provider {
        case .appleSpeech: return appleEngine
        case .whisperKit:
            if let whisperEngine { return whisperEngine }
            let engine = WhisperKitTranscriptionEngine(
                modelManager: modelManager,
                modelIdentifier: whisperModelIdentifier
            )
            whisperEngine = engine
            return engine
        }
    }

    private enum Keys {
        static let provider = "transcription.provider"
        static let automaticallyTranscribe = "transcription.automatic"
        static let showLiveTranscript = "transcription.live"
        static let systemAudio = "transcription.system-audio"
        static let microphone = "transcription.microphone"
        static let locale = "transcription.locale"
        static let whisperModel = "transcription.whisper-model"
    }

    private nonisolated struct ProjectTrackRequest: Sendable {
        let mediaURL: URL
        let sourceTrackID: Int32
        let role: TranscriptTrackRole
        let name: String
    }

#if DEBUG
    func installMonitorQAScenario() {
        let system = TranscriptSegment(
            text: "Welcome to the product walkthrough. The export is ready.",
            sourceStart: 2.1,
            duration: 3.2,
            words: []
        )
        let microphone = TranscriptSegment(
            text: "I’ll show the new timeline workflow next.",
            sourceStart: 5.4,
            duration: 2.8,
            words: []
        )
        liveUpdates = [
            .systemAudio: LiveTranscriptUpdate(
                role: .systemAudio,
                finalizedSegments: [system],
                volatileSegments: []
            ),
            .microphone: LiveTranscriptUpdate(
                role: .microphone,
                finalizedSegments: [],
                volatileSegments: [microphone]
            ),
        ]
        liveNotice = nil
    }

    func installProjectQAScenario(_ project: TimelineProject) {
        for lane in project.lanes where lane.kind != .video {
            for clip in lane.clips {
                var document = documents[clip.sourceURL]
                    ?? TranscriptDocument(mediaFileName: clip.sourceURL.lastPathComponent, tracks: [])
                document.replace(TranscriptTrack(
                    sourceTrackID: clip.sourceTrackID,
                    role: TranscriptTrackRole(laneKind: lane.kind),
                    name: lane.name,
                    provider: lane.kind == .systemAudio ? .appleSpeech : .whisperKit,
                    localeIdentifier: "en-AU",
                    modelIdentifier: lane.kind == .systemAudio ? "apple-speech-en-AU" : WhisperModelManager.compactModel,
                    segments: [
                        TranscriptSegment(
                            text: lane.kind == .systemAudio
                                ? "The source-aligned transcript follows every timeline edit."
                                : "Each speaker remains on an independent track.",
                            sourceStart: clip.sourceStart,
                            duration: min(3.5, clip.duration),
                            words: []
                        ),
                    ]
                ))
                documents[clip.sourceURL] = document
                jobs[clip.sourceURL] = .ready
            }
        }
    }

    func installRecordingQAScenario(_ recording: RecordingItem) {
        let systemTrackID = recording.audioTrackIDs.first ?? 2
        let microphoneTrackID = recording.audioTrackIDs.dropFirst().first ?? 3
        let tracks = [
            TranscriptTrack(
                sourceTrackID: systemTrackID,
                role: .systemAudio,
                name: "System Audio",
                provider: .appleSpeech,
                localeIdentifier: "en-AU",
                modelIdentifier: "apple-speech-en-AU",
                segments: [
                    TranscriptSegment(
                        text: "Welcome to Reccy. This transcript is searchable and stays on your Mac.",
                        sourceStart: 0.4,
                        duration: min(4, recording.duration),
                        words: []
                    ),
                ]
            ),
            TranscriptTrack(
                sourceTrackID: microphoneTrackID,
                role: .microphone,
                name: recording.manifest.microphoneName ?? "Microphone",
                provider: .whisperKit,
                localeIdentifier: "en-AU",
                modelIdentifier: WhisperModelManager.compactModel,
                segments: [
                    TranscriptSegment(
                        text: "The microphone remains an independently editable track.",
                        sourceStart: 4.7,
                        duration: min(3, max(0, recording.duration - 4.7)),
                        words: []
                    ),
                ]
            ),
        ]
        documents[recording.url] = TranscriptDocument(
            mediaFileName: recording.url.lastPathComponent,
            tracks: tracks
        )
        jobs[recording.url] = .ready
    }
#endif
}

actor LiveTranscriptionRouter {
    private var sessions: [TranscriptTrackRole: any LiveTranscriptionSession] = [:]
    private var pending: [TranscriptTrackRole: [TimedAudioBuffer]] = [:]
    private let maximumPendingPackets = 1_500

    func install(_ sessions: [TranscriptTrackRole: any LiveTranscriptionSession]) async {
        let bufferedPackets = pending
        pending.removeAll(keepingCapacity: false)
        self.sessions = sessions
        for (role, packets) in bufferedPackets {
            guard let session = sessions[role] else { continue }
            for packet in packets { await session.ingest(packet) }
        }
    }

    func ingest(_ packet: TimedAudioBuffer, role: TranscriptTrackRole) async {
        if let session = sessions[role] {
            await session.ingest(packet)
            return
        }
        var packets = pending.removeValue(forKey: role) ?? []
        packets.append(packet)
        if packets.count > maximumPendingPackets {
            packets.removeFirst(packets.count - maximumPendingPackets)
        }
        pending[role] = packets
    }

    func finish(trackIDs: [TranscriptTrackRole: Int32]) async -> [TranscriptTrack] {
        let activeSessions = sessions
        sessions.removeAll(keepingCapacity: false)
        pending.removeAll(keepingCapacity: false)
        var tracks: [TranscriptTrack] = []
        for (role, session) in activeSessions {
            guard let trackID = trackIDs[role], let track = try? await session.finish(sourceTrackID: trackID) else {
                await session.cancel()
                continue
            }
            tracks.append(track)
        }
        return tracks
    }

    func cancel() async {
        let activeSessions = Array(sessions.values)
        sessions.removeAll(keepingCapacity: false)
        pending.removeAll(keepingCapacity: false)
        for session in activeSessions { await session.cancel() }
    }
}

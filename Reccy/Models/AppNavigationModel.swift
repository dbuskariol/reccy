import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case record
    case monitor
    case library
    case editor
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .record: "Record"
        case .monitor: "Monitor"
        case .library: "Library"
        case .editor: "Editor"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .record: "record.circle"
        case .monitor: "waveform.path.ecg.rectangle"
        case .library: "rectangle.stack"
        case .editor: "timeline.selection"
        case .settings: "gearshape"
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case recording
    case transcription
    case permissions
    case shortcuts
    case updates

    var id: Self { self }

    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .recording: "record.circle"
        case .transcription: "captions.bubble"
        case .permissions: "hand.raised"
        case .shortcuts: "command"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

struct CaptureCompletionNavigation: Equatable {
    let section: AppSection
    let recordingURL: URL?
}

extension CaptureSessionCompletion.Outcome {
    func navigation(for preference: RecordingCompletionDestination) -> CaptureCompletionNavigation {
        switch self {
        case .cancelled:
            CaptureCompletionNavigation(section: .record, recordingURL: nil)
        case let .saved(url):
            switch preference {
            case .library:
                CaptureCompletionNavigation(section: .library, recordingURL: url)
            case .editor:
                CaptureCompletionNavigation(section: .editor, recordingURL: url)
            case .record:
                CaptureCompletionNavigation(section: .record, recordingURL: url)
            }
        }
    }
}

@MainActor
final class AppNavigationModel: ObservableObject {
    @Published var section: AppSection = .record
    @Published var settingsCategory: SettingsCategory = .general

    func openSettings(_ category: SettingsCategory) {
        settingsCategory = category
        section = .settings
    }
}

import Foundation
import ServiceManagement

enum ReccyPreferenceKeys {
    static let showTooltips = "interface.show-tooltips"
    static let showMenuBarExtra = "interface.show-menu-bar-extra"
    static let completionDestination = "recording.completion-destination"
}

enum RecordingCompletionDestination: String, CaseIterable, Identifiable, Sendable {
    case library
    case editor
    case record

    var id: Self { self }

    var title: String {
        switch self {
        case .library: "Open Library"
        case .editor: "Open Editor"
        case .record: "Return to Record"
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var showTooltips: Bool {
        didSet { defaults.set(showTooltips, forKey: ReccyPreferenceKeys.showTooltips) }
    }
    @Published var showMenuBarExtra: Bool {
        didSet { defaults.set(showMenuBarExtra, forKey: ReccyPreferenceKeys.showMenuBarExtra) }
    }
    @Published var completionDestination: RecordingCompletionDestination {
        didSet {
            defaults.set(
                completionDestination.rawValue,
                forKey: ReccyPreferenceKeys.completionDestination
            )
        }
    }
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showTooltips = defaults.object(forKey: ReccyPreferenceKeys.showTooltips) as? Bool ?? true
        showMenuBarExtra = defaults.object(forKey: ReccyPreferenceKeys.showMenuBarExtra) as? Bool ?? true
        completionDestination = RecordingCompletionDestination(
            rawValue: defaults.string(forKey: ReccyPreferenceKeys.completionDestination) ?? ""
        ) ?? .library
        refreshLaunchAtLoginStatus()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            launchAtLoginError = error.localizedDescription
            refreshLaunchAtLoginStatus()
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }
}

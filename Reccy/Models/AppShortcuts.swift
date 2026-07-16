import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggle-recording")
    static let toggleRecordingPause = Self("toggle-recording-pause")
    static let toggleMouseFollowZoom = Self("toggle-mouse-follow-zoom")
    static let chooseDisplay = Self("choose-display")
    static let choosePortion = Self("choose-portion")
    static let chooseApplication = Self("choose-application")
    static let chooseWindow = Self("choose-window")
    static let captureScreenshot = Self("capture-screenshot")
}

enum ReccyGlobalShortcut: CaseIterable, Identifiable {
    case toggleRecording
    case toggleRecordingPause
    case toggleMouseFollowZoom
    case chooseDisplay
    case choosePortion
    case chooseApplication
    case chooseWindow
    case captureScreenshot

    var id: Self { self }

    var title: String {
        switch self {
        case .toggleRecording: "Start or stop recording"
        case .toggleRecordingPause: "Pause or resume recording"
        case .toggleMouseFollowZoom: "Toggle mouse-follow zoom"
        case .chooseDisplay: "Choose a display"
        case .choosePortion: "Choose a portion"
        case .chooseApplication: "Choose an application"
        case .chooseWindow: "Choose a window"
        case .captureScreenshot: "Capture a screenshot"
        }
    }

    var name: KeyboardShortcuts.Name {
        switch self {
        case .toggleRecording: .toggleRecording
        case .toggleRecordingPause: .toggleRecordingPause
        case .toggleMouseFollowZoom: .toggleMouseFollowZoom
        case .chooseDisplay: .chooseDisplay
        case .choosePortion: .choosePortion
        case .chooseApplication: .chooseApplication
        case .chooseWindow: .chooseWindow
        case .captureScreenshot: .captureScreenshot
        }
    }
}

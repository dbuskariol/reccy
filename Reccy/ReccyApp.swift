import SwiftUI

@main
struct ReccyApp: App {
    @StateObject private var coordinator = CaptureCoordinator()
    @StateObject private var editor = TimelineEditorController()
    @StateObject private var navigation = AppNavigationModel()
    @StateObject private var preferences = AppPreferences()
    @StateObject private var softwareUpdates = SoftwareUpdateController()

#if DEBUG
    private let presentsActiveMenuBarQAHarness = CommandLine.arguments.contains("-ReccyMenuBarActiveQA")
    private let presentsMenuBarQAHarness = CommandLine.arguments.contains("-ReccyMenuBarQA")
        || CommandLine.arguments.contains("-ReccyMenuBarActiveQA")
#endif

    var body: some Scene {
        Window("Reccy", id: "main") {
            mainWindowContent
                .environmentObject(coordinator)
                .environmentObject(editor)
                .environmentObject(navigation)
                .environmentObject(preferences)
                .environmentObject(softwareUpdates)
                .frame(minWidth: minimumWindowWidth, minHeight: minimumWindowHeight)
        }
        .defaultSize(width: defaultWindowWidth, height: defaultWindowHeight)
        .commands {
            CommandMenu("Recording") {
                Button("Choose Display…") {
                    coordinator.chooseSource(.display)
                }
                .keyboardShortcut("1", modifiers: [.command, .shift])

                Button("Choose Application…") {
                    coordinator.chooseSource(.application)
                }
                .keyboardShortcut("2", modifiers: [.command, .shift])

                Button("Choose Portion…") {
                    coordinator.chooseSource(.region)
                }
                .keyboardShortcut("3", modifiers: [.command, .shift])

                Button("Choose Window…") {
                    coordinator.chooseSource(.window)
                }
                .keyboardShortcut("4", modifiers: [.command, .shift])

                Divider()

                Button(coordinator.state.isRecording ? "Stop Recording" : "Start Recording") {
                    if coordinator.state.isRecording {
                        coordinator.stopRecording()
                    } else {
                        coordinator.startRecording()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button(coordinator.state == .paused ? "Resume Recording" : "Pause Recording") {
                    coordinator.toggleRecordingPause()
                }
                .disabled(coordinator.state != .recording && coordinator.state != .paused)
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra(isInserted: menuBarExtraInsertion) {
            MenuBarRecorderView()
                .environmentObject(coordinator)
                .environmentObject(editor)
                .environmentObject(navigation)
                .environmentObject(softwareUpdates)
        } label: {
            if coordinator.state == .paused {
                Label(coordinator.formattedDuration, systemImage: "pause.circle.fill")
            } else if coordinator.state.isRecording {
                Label(coordinator.formattedDuration, systemImage: "record.circle.fill")
            } else {
                Label("Reccy", systemImage: "record.circle")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(coordinator)
                .environmentObject(navigation)
                .environmentObject(preferences)
                .environmentObject(softwareUpdates)
                .frame(width: 720, height: 620)
        }
    }

    private var menuBarExtraInsertion: Binding<Bool> {
        Binding(
            get: { preferences.showMenuBarExtra },
            set: { isInserted in
                guard preferences.showMenuBarExtra != isInserted else { return }
                preferences.showMenuBarExtra = isInserted
            }
        )
    }

    @ViewBuilder
    private var mainWindowContent: some View {
#if DEBUG
        if presentsMenuBarQAHarness {
            MenuBarRecorderView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .task {
                    if presentsActiveMenuBarQAHarness {
                        coordinator.installActiveMenuBarQAScenario()
                    }
                }
        } else {
            RootView()
                .task {
                    await installMainWindowQAScenario()
                }
        }
#else
        RootView()
#endif
    }

    private var minimumWindowWidth: CGFloat {
#if DEBUG
        presentsMenuBarQAHarness ? 400 : 940
#else
        940
#endif
    }

    private var minimumWindowHeight: CGFloat {
#if DEBUG
        presentsMenuBarQAHarness ? 430 : 680
#else
        680
#endif
    }

    private var defaultWindowWidth: CGFloat {
#if DEBUG
        presentsMenuBarQAHarness ? 400 : 1080
#else
        1080
#endif
    }

    private var defaultWindowHeight: CGFloat {
#if DEBUG
        presentsMenuBarQAHarness ? 470 : 760
#else
        760
#endif
    }

#if DEBUG
    @MainActor
    private func installMainWindowQAScenario() async {
        if CommandLine.arguments.contains("-ReccyPortionSelectionQA") {
            coordinator.installPortionSelectionQAScenario()
            navigation.section = .record
        } else if CommandLine.arguments.contains("-ReccyMonitorActiveQA") {
            coordinator.installActiveMonitorQAScenario()
            navigation.section = .monitor
        } else if CommandLine.arguments.contains("-ReccyRecordReadyQA") {
            coordinator.installRecordReadyQAScenario()
            navigation.section = .record
        } else if CommandLine.arguments.contains("-ReccyLibraryQA") {
            coordinator.library.refresh()
            navigation.section = .library
        } else if CommandLine.arguments.contains("-ReccyEditorQA") {
            coordinator.library.refresh()
            guard let recording = coordinator.library.recordings.first else {
                navigation.section = .editor
                return
            }
            await editor.open(recording)
            navigation.section = .editor
        } else if CommandLine.arguments.contains("-ReccyPermissionsQA") {
            navigation.openSettings(.permissions)
        }
    }
#endif
}

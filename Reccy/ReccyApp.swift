import SwiftUI

@main
struct ReccyApp: App {
    @StateObject private var coordinator = CaptureCoordinator()
    @StateObject private var editor = TimelineEditorController()
    @StateObject private var navigation = AppNavigationModel()
    @StateObject private var preferences = AppPreferences()
    @StateObject private var softwareUpdates = SoftwareUpdateController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
                .environmentObject(editor)
                .environmentObject(navigation)
                .environmentObject(preferences)
                .environmentObject(softwareUpdates)
                .frame(minWidth: 940, minHeight: 680)
        }
        .defaultSize(width: 1080, height: 760)
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
            }
        }

        MenuBarExtra(isInserted: menuBarExtraInsertion) {
            MenuBarRecorderView()
                .environmentObject(coordinator)
                .environmentObject(navigation)
                .environmentObject(softwareUpdates)
        } label: {
            Label("Reccy", systemImage: coordinator.state.isRecording ? "record.circle.fill" : "record.circle")
        }

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
}

private struct MenuBarRecorderView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator

    var body: some View {
        if coordinator.state.isRecording {
            Text(coordinator.formattedDuration)
            Text(coordinator.formattedFileSize)
            Divider()
            Button("Stop Recording") {
                coordinator.stopRecording()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        } else {
            Button("Record Display…") {
                coordinator.chooseSource(.display)
            }
            Button("Record Application…") {
                coordinator.chooseSource(.application)
            }
            Button("Record Portion…") {
                coordinator.chooseSource(.region)
            }
            Button("Record Window…") {
                coordinator.chooseSource(.window)
            }
            Divider()
            Button("Open Recordings Folder") {
                coordinator.library.revealDirectory()
            }
        }
    }
}

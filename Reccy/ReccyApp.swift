import SwiftUI

@main
struct ReccyApp: App {
    @StateObject private var coordinator = CaptureCoordinator()
    @StateObject private var editor = TimelineEditorController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
                .environmentObject(editor)
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

                Button("Choose Window…") {
                    coordinator.chooseSource(.window)
                }
                .keyboardShortcut("3", modifiers: [.command, .shift])

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

        MenuBarExtra {
            MenuBarRecorderView()
                .environmentObject(coordinator)
        } label: {
            Label("Reccy", systemImage: coordinator.state.isRecording ? "record.circle.fill" : "record.circle")
        }

        Settings {
            SettingsView()
                .environmentObject(coordinator)
                .frame(width: 620, height: 570)
        }
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

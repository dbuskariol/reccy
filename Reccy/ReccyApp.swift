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
    private let presentsBlockedMenuBarQAHarness = CommandLine.arguments.contains("-ReccyMenuBarBlockedQA")
    private let presentsMenuBarQAHarness = CommandLine.arguments.contains("-ReccyMenuBarQA")
        || CommandLine.arguments.contains("-ReccyMenuBarActiveQA")
        || CommandLine.arguments.contains("-ReccyMenuBarBlockedQA")
#endif

    var body: some Scene {
        Window("Reccy", id: "main") {
            mainWindowContent
                .environmentObject(coordinator)
                .environmentObject(editor)
                .environmentObject(navigation)
                .environmentObject(preferences)
                .environmentObject(softwareUpdates)
                .environmentObject(coordinator.transcription)
                .frame(minWidth: minimumWindowWidth, minHeight: minimumWindowHeight)
        }
        .defaultSize(width: defaultWindowWidth, height: defaultWindowHeight)
        .windowStyle(.hiddenTitleBar)
        .commands {
            RecordingCommands(
                coordinator: coordinator,
                transcription: coordinator.transcription
            )

            CommandGroup(replacing: .saveItem) {
                Button("Save Project") {
                    editor.saveProject()
                }
                .disabled(!editor.hasProject || editor.isRebuilding)
                .keyboardShortcut("s", modifiers: .command)
            }

            CommandGroup(after: .importExport) {
                Button("Import Media…") {
                    editor.chooseMediaToImport()
                }
                .disabled(!editor.hasProject || editor.isRebuilding || editor.isImportingMedia)
                .keyboardShortcut("i", modifiers: .command)
            }

            CommandMenu("Editor") {
                Button("Previous Frame") {
                    editor.stepFrames(-1)
                }
                .disabled(!editor.hasProject)
                .keyboardShortcut(.leftArrow, modifiers: .control)

                Button("Next Frame") {
                    editor.stepFrames(1)
                }
                .disabled(!editor.hasProject)
                .keyboardShortcut(.rightArrow, modifiers: .control)

                Button("Use Current Frame as Poster") {
                    editor.useCurrentFrameAsPoster()
                    if let sourceURL = editor.sourceRecordingURL,
                       let item = coordinator.library.recordings.first(where: { $0.url == sourceURL })
                    {
                        Task { await coordinator.library.refreshThumbnail(for: item) }
                    }
                }
                .disabled(!editor.hasProject)

                Divider()

                Button("Nudge Selected Clip Earlier") {
                    guard let id = editor.selectedClipID else { return }
                    editor.nudgeClip(id: id, byFrames: -1)
                }
                .disabled(editor.selectedClipID == nil)
                .keyboardShortcut(.leftArrow, modifiers: .option)

                Button("Nudge Selected Clip Later") {
                    guard let id = editor.selectedClipID else { return }
                    editor.nudgeClip(id: id, byFrames: 1)
                }
                .disabled(editor.selectedClipID == nil)
                .keyboardShortcut(.rightArrow, modifiers: .option)
            }
        }

        MenuBarExtra(isInserted: menuBarExtraInsertion) {
            MenuBarRecorderView()
                .environmentObject(coordinator)
                .environmentObject(editor)
                .environmentObject(navigation)
                .environmentObject(softwareUpdates)
                .environmentObject(coordinator.transcription)
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
                .environmentObject(coordinator.transcription)
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
                    if let directory = qaLibraryDirectory {
                        coordinator.library.setDirectory(directory)
                    }
                    if presentsActiveMenuBarQAHarness {
                        coordinator.installActiveMenuBarQAScenario()
                    } else if presentsBlockedMenuBarQAHarness {
                        coordinator.installBlockedMenuBarQAScenario()
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
        if let directory = qaLibraryDirectory {
            coordinator.library.setDirectory(directory)
        }

        if CommandLine.arguments.contains("-ReccyPortionSelectionQA") {
            coordinator.installPortionSelectionQAScenario()
            navigation.section = .record
        } else if CommandLine.arguments.contains("-ReccyMonitorActiveQA") {
            coordinator.installActiveMonitorQAScenario()
            navigation.section = .monitor
        } else if CommandLine.arguments.contains("-ReccyMonitorTranscriptionQA") {
            coordinator.installActiveMonitorQAScenario()
            coordinator.transcription.installMonitorQAScenario()
            navigation.section = .monitor
        } else if CommandLine.arguments.contains("-ReccyRecordReadyQA") {
            coordinator.installRecordReadyQAScenario()
            navigation.section = .record
        } else if CommandLine.arguments.contains("-ReccyLibraryQA") {
            coordinator.library.refresh()
            navigation.section = .library
        } else if CommandLine.arguments.contains("-ReccyEmptyLibraryQA") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Reccy Empty Library QA", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            coordinator.library.setDirectory(directory)
            navigation.section = .library
        } else if CommandLine.arguments.contains("-ReccyUnavailableLibraryQA") {
            coordinator.library.setDirectory(
                URL(fileURLWithPath: "/dev/null/Reccy Unavailable Library", isDirectory: true)
            )
            navigation.section = .library
        } else if CommandLine.arguments.contains("-ReccyLibraryTranscriptionQA") {
            coordinator.library.refresh()
            if let recording = coordinator.library.recordings.first {
                coordinator.transcription.installRecordingQAScenario(recording)
            }
            navigation.section = .library
        } else if CommandLine.arguments.contains("-ReccyRecoveryQA") {
            coordinator.library.refresh()
            coordinator.library.presentNotice(
                kind: .recovered,
                title: "Interrupted recording recovered",
                message: "Reccy validated and restored Reccy Recovery Test.",
                fileURL: coordinator.library.recordings.first?.url
            )
            navigation.section = .library
        } else if CommandLine.arguments.contains("-ReccyEditorQA") {
            coordinator.library.refresh()
            guard let recording = coordinator.library.recordings.first else {
                navigation.section = .editor
                return
            }
            await editor.open(recording)
            navigation.section = .editor
        } else if CommandLine.arguments.contains("-ReccyEditorTranscriptionQA") {
            coordinator.library.refresh()
            guard let recording = coordinator.library.recordings.first else {
                navigation.section = .editor
                return
            }
            await editor.open(recording)
            if let project = editor.project {
                coordinator.transcription.installProjectQAScenario(project)
            }
            navigation.section = .editor
        } else if CommandLine.arguments.contains("-ReccyTranscriptionSettingsQA") {
            navigation.openSettings(.transcription)
        } else if CommandLine.arguments.contains("-ReccyPermissionsQA") {
            coordinator.installPermissionsQAScenario()
            navigation.openSettings(.permissions)
        }
    }

    private var qaLibraryDirectory: URL? {
        guard let argumentIndex = CommandLine.arguments.firstIndex(of: "-ReccyQALibraryPath"),
              CommandLine.arguments.indices.contains(argumentIndex + 1)
        else {
            return nil
        }

        return URL(
            fileURLWithPath: CommandLine.arguments[argumentIndex + 1],
            isDirectory: true
        )
    }
#endif
}

private struct RecordingCommands: Commands {
    @ObservedObject var coordinator: CaptureCoordinator
    @ObservedObject var transcription: TranscriptionController

    var body: some Commands {
        CommandMenu("Recording") {
            Button("Choose Display…") {
                coordinator.chooseSource(.display)
            }
            .keyboardShortcut("1", modifiers: [.command, .shift])
            .disabled(!canChooseSource)

            Button("Choose Application…") {
                coordinator.chooseSource(.application)
            }
            .keyboardShortcut("2", modifiers: [.command, .shift])
            .disabled(!canChooseSource)

            Button("Choose Portion…") {
                coordinator.chooseSource(.region)
            }
            .keyboardShortcut("3", modifiers: [.command, .shift])
            .disabled(!canChooseSource)

            Button("Choose Window…") {
                coordinator.chooseSource(.window)
            }
            .keyboardShortcut("4", modifiers: [.command, .shift])
            .disabled(!canChooseSource)

            Divider()

            Button(coordinator.state.isRecording ? coordinator.state.stopButtonTitle : "Start Recording") {
                if coordinator.state.isRecording {
                    coordinator.requestStopRecording()
                } else {
                    coordinator.startRecording()
                }
            }
            .disabled(
                coordinator.state.isRecording
                    ? coordinator.state == .stopping
                    : !coordinator.canStartRecording
            )
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button(coordinator.state == .paused ? "Resume Recording" : "Pause Recording") {
                coordinator.toggleRecordingPause()
            }
            .disabled(coordinator.state != .recording && coordinator.state != .paused)
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }

    private var canChooseSource: Bool {
        coordinator.state.canChangeSettings && !coordinator.isSelectingSource
    }
}

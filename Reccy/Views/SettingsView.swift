import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator

    var body: some View {
        Form {
            Section("Recording Defaults") {
                Picker("Resolution", selection: $coordinator.settings.resolution) {
                    ForEach(CaptureResolution.allCases) { value in
                        Text("\(value.title) — \(value.detail)").tag(value)
                    }
                }
                Picker("Frame rate", selection: $coordinator.settings.frameRate) {
                    ForEach(CaptureFrameRate.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                Picker("Format", selection: $coordinator.settings.recordingPreset) {
                    ForEach(RecordingPreset.allCases) { value in
                        Text("\(value.title) — \(value.detail)").tag(value)
                    }
                }
                Picker("Countdown", selection: $coordinator.settings.countdown) {
                    ForEach(CountdownDelay.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
            }

            Section("Audio") {
                Toggle("Record system audio", isOn: $coordinator.settings.includeSystemAudio)
                Toggle("Record microphone", isOn: $coordinator.settings.includeMicrophone)
                if coordinator.settings.includeMicrophone {
                    Picker("Microphone", selection: $coordinator.settings.selectedMicrophoneID) {
                        Text("System Default").tag(String?.none)
                        ForEach(coordinator.audioInputDevices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                }
                Toggle("Exclude Reccy’s own audio", isOn: $coordinator.settings.excludeOwnAudio)
            }

            Section("Pointer") {
                Toggle("Show pointer", isOn: $coordinator.settings.showCursor)
                Toggle("Highlight mouse clicks", isOn: $coordinator.settings.showMouseClicks)
                    .disabled(coordinator.settings.useHDR)
            }

            if #available(macOS 26.0, *) {
                Section {
                    Toggle("Record in HDR10", isOn: $coordinator.settings.useHDR)
                    Text("Uses the macOS 26 ScreenCaptureKit HDR recording preset, preserving a useful SDR playback range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    HStack {
                        Text("macOS 26")
                        CapabilityBadge(text: "Enhanced")
                    }
                }
            }

            Section("Storage") {
                LabeledContent("Save recordings to") {
                    Text(coordinator.library.directoryURL.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose Folder…") { coordinator.chooseOutputFolder() }
                    if coordinator.settings.outputFolderPath != nil {
                        Button("Use Movies/Reccy") { coordinator.resetOutputFolder() }
                    }
                    Spacer()
                    Button("Open Folder") { coordinator.library.revealDirectory() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

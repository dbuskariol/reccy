import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var workflow: ExportWorkflow

    init(source: ExportSource) {
        _workflow = StateObject(wrappedValue: ExportWorkflow(source: source))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            presetBrowser
            Divider()
            footer
        }
        .frame(width: 650, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(workflow.isExporting)
        .task { workflow.prepare() }
        .onDisappear { workflow.cancelTransientWork() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.and.arrow.up")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text("Export")
                    .font(.title2.weight(.bold))
                Text(workflow.source.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
    }

    private var presetBrowser: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(ExportPresetCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(category.title.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        VStack(spacing: 5) {
                            ForEach(presets(in: category)) { preset in
                                presetRow(preset)
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .overlay {
            if workflow.isPreparing {
                ZStack {
                    Color(nsColor: .windowBackgroundColor).opacity(0.72)
                    ProgressView("Checking available formats…")
                        .controlSize(.large)
                }
            }
        }
    }

    private func presets(in category: ExportPresetCategory) -> [ExportPreset] {
        ExportPreset.allCases.filter { $0.category == category }
    }

    private func presetRow(_ preset: ExportPreset) -> some View {
        let isSelected = workflow.selectedPreset == preset
        let isCompatible = workflow.compatiblePresets.contains(preset)
        return Button {
            workflow.select(preset)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: preset.systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isCompatible ? Color.accentColor : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(preset.title)
                            .font(.headline)
                        if preset.isRecommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.tint.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(preset.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if !workflow.isPreparing, !isCompatible {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.65) : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(workflow.isExporting || (!workflow.isPreparing && !isCompatible))
        .accessibilityLabel("\(preset.title). \(preset.detail)")
        .accessibilityValue(isSelected ? "Selected" : (isCompatible ? "Available" : "Unavailable"))
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if let result = workflow.completedResult {
                completionSummary(result)
            } else if workflow.isExporting {
                exportProgress
            } else {
                selectionSummary
            }

            if let error = workflow.errorMessage {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        workflow.clearError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss export error")
                }
                .padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }

            if let result = workflow.completedResult {
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.url])
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack {
                    Button(workflow.isExporting ? "Cancel Export" : "Cancel") {
                        if workflow.isExporting {
                            workflow.cancelExport()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(workflow.isCancelling)

                    Spacer()

                    Button("Export…") { chooseDestination() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!workflow.canExport)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
        .background(.bar)
    }

    private var selectionSummary: some View {
        HStack(spacing: 9) {
            Image(systemName: workflow.selectedPreset.systemImage)
                .foregroundStyle(.tint)
            Text(workflow.selectedPreset.fileExtension.uppercased())
                .font(.callout.weight(.semibold))
            Text("·")
                .foregroundStyle(.tertiary)
            if workflow.isEstimating {
                ProgressView()
                    .controlSize(.small)
                Text("Estimating size…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let estimate = workflow.formattedEstimate {
                Text("Allow up to \(estimate)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Final size depends on the recording")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var exportProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(workflow.isCancelling ? "Canceling export…" : workflow.progress.phase.title)
                    .font(.callout.weight(.medium))
                Spacer()
                if let fraction = workflow.progress.fractionCompleted {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction = workflow.progress.fractionCompleted {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
    }

    private func completionSummary(_ result: ExportResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export complete")
                    .font(.callout.weight(.semibold))
                Text("\(result.url.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: result.fileSize, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Export \(workflow.source.name)"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(workflow.source.name) Export.\(workflow.selectedPreset.fileExtension)"
        if let type = UTType(filenameExtension: workflow.selectedPreset.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        workflow.startExport(to: destination)
    }
}

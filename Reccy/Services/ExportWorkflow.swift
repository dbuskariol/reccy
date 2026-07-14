import Combine
import Foundation

@MainActor
final class ExportWorkflow: ObservableObject {
    let source: ExportSource

    @Published private(set) var compatiblePresets: Set<ExportPreset> = []
    @Published private(set) var isPreparing = true
    @Published private(set) var isEstimating = false
    @Published private(set) var isExporting = false
    @Published private(set) var isCancelling = false
    @Published private(set) var estimatedFileSize: Int64?
    @Published private(set) var progress = ExportProgressUpdate(
        phase: .preparing,
        fractionCompleted: nil
    )
    @Published private(set) var errorMessage: String?
    @Published private(set) var completedResult: ExportResult?
    @Published private(set) var selectedPreset: ExportPreset = .hevc1080

    private let service = ExportService()
    private var preparationTask: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

    init(source: ExportSource) {
        self.source = source
    }

    var canExport: Bool {
        !isPreparing
            && !isExporting
            && compatiblePresets.contains(selectedPreset)
    }

    var formattedEstimate: String? {
        guard let estimatedFileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: estimatedFileSize, countStyle: .file)
    }

    func prepare() {
        guard preparationTask == nil else { return }
        isPreparing = true
        errorMessage = nil
        preparationTask = Task { [weak self] in
            guard let self else { return }
            let compatible = await service.compatiblePresets(for: source)
            guard !Task.isCancelled else { return }
            compatiblePresets = compatible
            if !compatible.contains(selectedPreset) {
                selectedPreset = ExportPreset.allCases.first(where: compatible.contains)
                    ?? .hevc1080
            }
            isPreparing = false
            preparationTask = nil
            if compatible.isEmpty {
                errorMessage = ExportServiceError.unsupportedPreset.localizedDescription
            } else {
                refreshEstimate()
            }
        }
    }

    func select(_ preset: ExportPreset) {
        guard !isExporting, compatiblePresets.contains(preset) else { return }
        selectedPreset = preset
        errorMessage = nil
        refreshEstimate()
    }

    func startExport(to destinationURL: URL) {
        guard canExport else { return }
        exportTask?.cancel()
        estimateTask?.cancel()
        isEstimating = false
        isExporting = true
        isCancelling = false
        errorMessage = nil
        completedResult = nil
        progress = ExportProgressUpdate(phase: .preparing, fractionCompleted: nil)
        let preset = selectedPreset

        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.export(
                    source: source,
                    destinationURL: destinationURL,
                    preset: preset
                ) { [weak self] update in
                    self?.progress = update
                }
                guard !Task.isCancelled else { return }
                completedResult = result
                isExporting = false
                isCancelling = false
                exportTask = nil
            } catch {
                let wasCancelled = Task.isCancelled || error is CancellationError
                isExporting = false
                isCancelling = false
                exportTask = nil
                if !wasCancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelExport() {
        guard isExporting, !isCancelling else { return }
        isCancelling = true
        exportTask?.cancel()
    }

    func clearError() {
        errorMessage = nil
    }

    func cancelTransientWork() {
        preparationTask?.cancel()
        preparationTask = nil
        estimateTask?.cancel()
        estimateTask = nil
    }

    private func refreshEstimate() {
        estimateTask?.cancel()
        estimatedFileSize = nil
        guard compatiblePresets.contains(selectedPreset), !isExporting else {
            isEstimating = false
            return
        }

        isEstimating = true
        let preset = selectedPreset
        estimateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let estimate = try await service.estimatedFileSize(
                    source: source,
                    preset: preset
                )
                guard !Task.isCancelled, selectedPreset == preset else { return }
                estimatedFileSize = estimate
            } catch {
                // Estimation is advisory. Compatibility and final export still
                // perform their own strict checks.
            }
            guard !Task.isCancelled, selectedPreset == preset else { return }
            isEstimating = false
            estimateTask = nil
        }
    }
}

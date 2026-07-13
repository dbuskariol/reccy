import AppKit
import DSWaveformImage
import DSWaveformImageViews
import SwiftUI

struct ReccyLiveWaveform: View {
    let samples: [Double]
    let color: Color
    let isEnabled: Bool

    var body: some View {
        ZStack {
            ReccyWaveformGuide()

            if isEnabled {
                WaveformLiveCanvas(
                    samples: normalizedSamples,
                    configuration: configuration,
                    renderer: LinearWaveformRenderer(),
                    shouldDrawSilencePadding: true
                )
                .padding(.vertical, 4)
            } else {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(height: 1)
                    .padding(.horizontal, 8)
            }
        }
        .background(.quaternary.opacity(0.26), in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel(isEnabled ? "Live audio waveform" : "Audio source off")
    }

    private var normalizedSamples: [Float] {
        samples.map { value in
            // Reccy levels use zero for silence and one for peak. The package
            // uses the inverse normalized-decibel convention.
            1 - Float(min(max(value, 0), 1))
        }
    }

    private var configuration: Waveform.Configuration {
        let base = NSColor(color)
        return Waveform.Configuration(
            style: .gradient([
                base.withAlphaComponent(0.55),
                base.withAlphaComponent(0.98),
            ]),
            damping: .init(percentage: 0.08, sides: .left),
            verticalScalingFactor: 0.46,
            shouldAntialias: true
        )
    }
}

struct ReccyAssetWaveform: View {
    let sourceURL: URL
    let sourceTrackID: Int32?
    let sourceStart: TimeInterval
    let duration: TimeInterval?
    let color: Color
    var progress: Double? = nil

    @State private var samples: [Float] = []

    var body: some View {
        GeometryReader { geometry in
            let request = WaveformSliceRequest(
                sourceURL: sourceURL,
                sourceTrackID: sourceTrackID,
                sourceStart: sourceStart,
                duration: duration,
                sampleCount: max(2, Int(geometry.size.width.rounded(.up)))
            )

            ZStack {
                ReccyWaveformGuide()

                waveformShape
                    .fill(color.opacity(0.38))

                if let progress {
                    waveformShape
                        .fill(color)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: geometry.size.width * min(max(progress, 0), 1))
                        }
                }
            }
            .task(id: request) {
                do {
                    samples = try await WaveformRepository.shared.samples(for: request)
                } catch is CancellationError {
                    return
                } catch {
                    samples = []
                }
            }
        }
        .accessibilityLabel("Audio waveform")
    }

    private var waveformShape: WaveformShape {
        WaveformShape(
            samples: samples,
            configuration: Waveform.Configuration(
                style: .filled(.white),
                scale: 1,
                verticalScalingFactor: 0.46,
                shouldAntialias: true
            ),
            renderer: LinearWaveformRenderer()
        )
    }
}

private struct ReccyWaveformGuide: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [0.25, 0.5, 0.75] {
                    let y = geometry.size.height * fraction
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(Color.secondary.opacity(0.13), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
        }
        .allowsHitTesting(false)
    }
}

import SwiftUI
import UIKit

struct ImageSonificationSession: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ImageSonificationPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audio = ImageSonificationAudioController()

    let image: UIImage

    @State private var spectralImage: ImageSonificationSpectralImage?
    @State private var previewImage: UIImage?
    @State private var settings: ImageSonificationSettings
    @State private var previewStartedAt = Date()
    @State private var threshold = 0.0
    @State private var isExportingVideo = false
    @State private var exportErrorMessage: String?
    @State private var shareItem: SonificationVideoShareItem?

    private let previewTimer = Timer.publish(every: 1.0 / 18.0, on: .main, in: .common).autoconnect()

    init(image: UIImage) {
        self.image = image
        _settings = State(initialValue: ImageSonificationSettings.load())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                preview
                transportControls
                sweepControls
                pitchControls
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Sonify")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    audio.stop()
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    exportSweepVideo()
                } label: {
                    if isExportingVideo {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(spectralImage == nil || isExportingVideo)
                .accessibilityLabel("Export sweep video")
            }
        }
        .task {
            prepareImage()
        }
        .onReceive(previewTimer) { date in
            updateThresholdPreview(at: date)
        }
        .onChange(of: settings) { _, _ in
            settings.save()
            if let spectralImage, audio.isPlaying {
                audio.play(source: spectralImage, settings: settings)
            }
            updateThresholdPreview(at: Date())
        }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(items: [item.url])
        }
        .onDisappear {
            audio.stop()
        }
    }

    private var preview: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.06))

                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, minHeight: 260)
                }

                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                    Text("\(Int(threshold * 100))%")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.56), in: Capsule())
                .padding(10)
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            }

            ProgressView(value: threshold)
                .tint(.cyan)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 12) {
            Button {
                guard let spectralImage else { return }
                if audio.isPlaying {
                    audio.stop()
                } else {
                    previewStartedAt = Date()
                    audio.play(source: spectralImage, settings: settings)
                }
            } label: {
                Image(systemName: audio.isPlaying ? "stop.fill" : "play.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(audio.isPlaying ? .black : .white)
                    .frame(width: 58, height: 58)
                    .background(audio.isPlaying ? .white : .cyan.opacity(0.7), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(spectralImage == nil)
            .accessibilityLabel(audio.isPlaying ? "Stop sonification" : "Play sonification")

            VStack(alignment: .leading, spacing: 5) {
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(exportErrorMessage == nil ? .white : .red)
                Text(settings.loopMode.title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
            }

            Spacer()

            Picker("Loop", selection: $settings.loopMode) {
                ForEach(ImageSonificationLoopMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 176)
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusText: String {
        if isExportingVideo {
            return "Exporting video"
        }
        if let exportErrorMessage {
            return exportErrorMessage
        }
        return audio.statusMessage.isEmpty ? "Ready" : audio.statusMessage
    }

    private var sweepControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            controlHeader("Sweep", systemImage: "timeline.selection")

            controlSlider(
                title: "Speed",
                value: $settings.sweepDuration,
                range: ImageSonificationSettings.sweepDurationRange,
                step: 0.05,
                valueText: "\(settings.sweepDuration.formatted(.number.precision(.fractionLength(1))))s"
            )

            controlSlider(
                title: "Bands",
                value: Binding(
                    get: { Double(settings.bandCount) },
                    set: { settings.bandCount = Int($0.rounded()) }
                ),
                range: Double(ImageSonificationSettings.bandCountRange.lowerBound)...Double(ImageSonificationSettings.bandCountRange.upperBound),
                step: 8,
                valueText: "\(settings.bandCount)"
            )

            controlSlider(
                title: "Curve",
                value: $settings.scanCurve,
                range: ImageSonificationSettings.scanCurveRange,
                step: 0.05,
                valueText: "x\(settings.scanCurve.formatted(.number.precision(.fractionLength(2))))"
            )
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var pitchControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            controlHeader("Sound", systemImage: "slider.horizontal.3")

            controlSlider(
                title: "Base",
                value: $settings.baseFrequency,
                range: ImageSonificationSettings.baseFrequencyRange,
                step: 5,
                valueText: "\(Int(settings.baseFrequency)) Hz"
            )

            controlSlider(
                title: "Range",
                value: $settings.pitchSpanOctaves,
                range: ImageSonificationSettings.pitchSpanOctavesRange,
                step: 0.05,
                valueText: "\(settings.pitchSpanOctaves.formatted(.number.precision(.fractionLength(1)))) oct"
            )

            controlSlider(
                title: "Gain",
                value: $settings.gain,
                range: ImageSonificationSettings.gainRange,
                step: 0.05,
                valueText: "\(Int(settings.gain * 100))%"
            )

            controlSlider(
                title: "Density",
                value: $settings.densityPower,
                range: ImageSonificationSettings.densityPowerRange,
                step: 0.05,
                valueText: "x\(settings.densityPower.formatted(.number.precision(.fractionLength(2))))"
            )
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func controlHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
    }

    private func controlSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(valueText)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
            }
            Slider(value: value, in: range, step: step)
                .tint(.cyan)
        }
    }

    private func prepareImage() {
        spectralImage = ImageSonificationSpectralImage.make(from: image)
        updateThresholdPreview(at: Date())
    }

    private func updateThresholdPreview(at date: Date) {
        threshold = thresholdValue(at: date)
        previewImage = spectralImage?.binaryImage(threshold: threshold)
    }

    private func thresholdValue(at date: Date) -> Double {
        settings.threshold(at: date, startedAt: previewStartedAt)
    }

    private func exportSweepVideo() {
        guard let spectralImage, !isExportingVideo else { return }

        isExportingVideo = true
        exportErrorMessage = nil
        let exportSettings = settings

        Task {
            do {
                let url = try await ImageSonificationVideoExporter.export(
                    source: spectralImage,
                    settings: exportSettings
                )
                await MainActor.run {
                    shareItem = SonificationVideoShareItem(url: url)
                    isExportingVideo = false
                }
            } catch {
                await MainActor.run {
                    exportErrorMessage = error.localizedDescription
                    isExportingVideo = false
                }
            }
        }
    }
}

private struct SonificationVideoShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

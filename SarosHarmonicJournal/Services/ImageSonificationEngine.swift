import AVFoundation
import UIKit

enum ImageSonificationLoopMode: String, CaseIterable, Identifiable, Sendable {
    case restart
    case pingPong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restart: "Restart"
        case .pingPong: "Ping Pong"
        }
    }
}

struct ImageSonificationSettings: Equatable, Sendable {
    static let sweepDurationRange: ClosedRange<Double> = 0.25...4
    static let baseFrequencyRange: ClosedRange<Double> = 40...220
    static let pitchSpanOctavesRange: ClosedRange<Double> = 0.25...4
    static let gainRange: ClosedRange<Double> = 0.05...1.5
    static let bandCountRange: ClosedRange<Int> = 8...64
    static let scanCurveRange: ClosedRange<Double> = 0.35...2.5
    static let densityPowerRange: ClosedRange<Double> = 0.35...1.6

    var sweepDuration: Double = 1
    var baseFrequency: Double = 85
    var pitchSpanOctaves: Double = 1
    var gain: Double = 1
    var bandCount: Int = 16
    var loopMode: ImageSonificationLoopMode = .restart
    var scanCurve: Double = 1
    var densityPower: Double = 0.72

    var cycleDuration: Double {
        let duration = max(sweepDuration, 0.1)
        return loopMode == .pingPong ? duration * 2 : duration
    }

    static func load() -> ImageSonificationSettings {
        let defaults = UserDefaults.standard
        var settings = ImageSonificationSettings()

        if defaults.object(forKey: StoreKey.sweepDuration) != nil {
            settings.sweepDuration = defaults.double(forKey: StoreKey.sweepDuration)
        }
        if defaults.object(forKey: StoreKey.baseFrequency) != nil {
            settings.baseFrequency = defaults.double(forKey: StoreKey.baseFrequency)
        }
        if defaults.object(forKey: StoreKey.pitchSpanOctaves) != nil {
            settings.pitchSpanOctaves = defaults.double(forKey: StoreKey.pitchSpanOctaves)
        }
        if defaults.object(forKey: StoreKey.gain) != nil {
            settings.gain = defaults.double(forKey: StoreKey.gain)
        }
        if defaults.object(forKey: StoreKey.bandCount) != nil {
            settings.bandCount = defaults.integer(forKey: StoreKey.bandCount)
        }
        if let rawLoopMode = defaults.string(forKey: StoreKey.loopMode),
           let loopMode = ImageSonificationLoopMode(rawValue: rawLoopMode) {
            settings.loopMode = loopMode
        }
        if defaults.object(forKey: StoreKey.scanCurve) != nil {
            settings.scanCurve = defaults.double(forKey: StoreKey.scanCurve)
        }
        if defaults.object(forKey: StoreKey.densityPower) != nil {
            settings.densityPower = defaults.double(forKey: StoreKey.densityPower)
        }

        return settings.normalized()
    }

    func save() {
        let settings = normalized()
        let defaults = UserDefaults.standard
        defaults.set(settings.sweepDuration, forKey: StoreKey.sweepDuration)
        defaults.set(settings.baseFrequency, forKey: StoreKey.baseFrequency)
        defaults.set(settings.pitchSpanOctaves, forKey: StoreKey.pitchSpanOctaves)
        defaults.set(settings.gain, forKey: StoreKey.gain)
        defaults.set(settings.bandCount, forKey: StoreKey.bandCount)
        defaults.set(settings.loopMode.rawValue, forKey: StoreKey.loopMode)
        defaults.set(settings.scanCurve, forKey: StoreKey.scanCurve)
        defaults.set(settings.densityPower, forKey: StoreKey.densityPower)
    }

    func normalized() -> ImageSonificationSettings {
        var settings = self
        settings.sweepDuration = settings.sweepDuration.clamped(to: Self.sweepDurationRange)
        settings.baseFrequency = settings.baseFrequency.clamped(to: Self.baseFrequencyRange)
        settings.pitchSpanOctaves = settings.pitchSpanOctaves.clamped(to: Self.pitchSpanOctavesRange)
        settings.gain = settings.gain.clamped(to: Self.gainRange)
        settings.bandCount = settings.bandCount.clamped(to: Self.bandCountRange)
        settings.scanCurve = settings.scanCurve.clamped(to: Self.scanCurveRange)
        settings.densityPower = settings.densityPower.clamped(to: Self.densityPowerRange)
        return settings
    }

    func threshold(at date: Date, startedAt: Date) -> Double {
        let elapsed = max(date.timeIntervalSince(startedAt), 0)
        let duration = max(sweepDuration, 0.1)
        switch loopMode {
        case .restart:
            return curvedThreshold((elapsed / duration).truncatingRemainder(dividingBy: 1))
        case .pingPong:
            let cycle = (elapsed / duration).truncatingRemainder(dividingBy: 2)
            return curvedThreshold(cycle <= 1 ? cycle : 2 - cycle)
        }
    }

    func threshold(atCycleProgress progress: Double) -> Double {
        let boundedProgress = progress.clamped(to: 0...1)
        let rawThreshold = switch loopMode {
        case .restart:
            boundedProgress
        case .pingPong:
            boundedProgress <= 0.5 ? boundedProgress * 2 : (1 - boundedProgress) * 2
        }
        return curvedThreshold(rawThreshold)
    }

    private func curvedThreshold(_ rawThreshold: Double) -> Double {
        pow(rawThreshold.clamped(to: 0...1), max(scanCurve, 0.05))
    }

    private enum StoreKey {
        static let sweepDuration = "sonification.sweepDuration"
        static let baseFrequency = "sonification.baseFrequency"
        static let pitchSpanOctaves = "sonification.pitchSpanOctaves"
        static let gain = "sonification.gain"
        static let bandCount = "sonification.bandCount"
        static let loopMode = "sonification.loopMode"
        static let scanCurve = "sonification.scanCurve"
        static let densityPower = "sonification.densityPower"
    }
}

struct ImageSonificationSpectralImage: Sendable {
    static let defaultSide = 256

    let side: Int
    let brightness: [UInt8]

    static func make(from image: UIImage, side: Int = defaultSide) -> ImageSonificationSpectralImage? {
        let side = max(16, side)
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        let size = CGSize(width: side, height: side)
        let normalizedImage = UIGraphicsImageRenderer(size: size, format: rendererFormat).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let imageSize = image.size
            let scale = max(size.width / max(imageSize.width, 1), size.height / max(imageSize.height, 1))
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let drawRect = CGRect(
                x: (size.width - drawSize.width) / 2,
                y: (size.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            image.draw(in: drawRect)
        }

        guard let cgImage = normalizedImage.cgImage else { return nil }

        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        guard
            let context = CGContext(
                data: &rgba,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var brightness = [UInt8](repeating: 0, count: side * side)
        for index in 0..<(side * side) {
            let pixel = index * 4
            let red = Double(rgba[pixel])
            let green = Double(rgba[pixel + 1])
            let blue = Double(rgba[pixel + 2])
            brightness[index] = UInt8(min(max((red * 0.299 + green * 0.587 + blue * 0.114).rounded(), 0), 255))
        }

        return ImageSonificationSpectralImage(side: side, brightness: brightness)
    }

    func binaryImage(threshold: Double) -> UIImage? {
        let thresholdByte = UInt8(min(max(threshold, 0), 1) * 255)
        var rgba = [UInt8](repeating: 255, count: side * side * 4)

        for index in 0..<(side * side) {
            let value: UInt8 = brightness[index] >= thresholdByte ? 255 : 0
            let pixel = index * 4
            rgba[pixel] = value
            rgba[pixel + 1] = value
            rgba[pixel + 2] = value
            rgba[pixel + 3] = 255
        }

        guard
            let context = CGContext(
                data: &rgba,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let cgImage = context.makeImage()
        else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    func audioBuffer(
        settings: ImageSonificationSettings,
        sampleRate: Double = 22_050
    ) throws -> AVAudioPCMBuffer {
        let settings = settings.normalized()
        let bandCount = settings.bandCount
        let frameCount = max(48, min(240, Int(settings.cycleDuration * 48)))
        let cycleDuration = settings.cycleDuration
        let sampleCount = max(Int(sampleRate * cycleDuration), 1)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            throw ImageSonificationError.couldNotCreateAudioBuffer
        }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        guard let channel = buffer.floatChannelData?[0] else {
            throw ImageSonificationError.couldNotCreateAudioBuffer
        }

        let spectra = spectralFrames(frameCount: frameCount, bandCount: bandCount, settings: settings)
        let frequencies = frequencies(
            bandCount: bandCount,
            baseFrequency: settings.baseFrequency,
            pitchSpanOctaves: settings.pitchSpanOctaves
        )
        var phases = [Double](repeating: 0, count: bandCount)
        let normalization = max(sqrt(Double(bandCount)) * 1.5, 1)

        for sample in 0..<sampleCount {
            let position = Double(sample) / Double(max(sampleCount - 1, 1))
            let frameIndex = min(Int(position * Double(frameCount - 1)), frameCount - 1)
            let spectrum = spectra[frameIndex]
            var mixed = 0.0

            for band in 0..<bandCount {
                let amplitude = Double(spectrum[band])
                guard amplitude > 0.001 else { continue }
                phases[band] += 2 * .pi * frequencies[band] / sampleRate
                if phases[band] > 2 * .pi {
                    phases[band].formTruncatingRemainder(dividingBy: 2 * .pi)
                }
                mixed += sin(phases[band]) * amplitude
            }

            let sampleValue = mixed / normalization * settings.gain
            channel[sample] = Float(max(min(sampleValue, 0.96), -0.96))
        }

        return buffer
    }

    private func spectralFrames(
        frameCount: Int,
        bandCount: Int,
        settings: ImageSonificationSettings
    ) -> [[Float]] {
        (0..<frameCount).map { frame in
            let rawProgress = Double(frame) / Double(max(frameCount - 1, 1))
            let threshold = settings.threshold(atCycleProgress: rawProgress)
            return spectrum(
                threshold: threshold,
                bandCount: bandCount,
                densityPower: settings.densityPower
            )
        }
    }

    private func spectrum(threshold: Double, bandCount: Int, densityPower: Double) -> [Float] {
        let thresholdByte = UInt8(min(max(threshold, 0), 1) * 255)
        return (0..<bandCount).map { band in
            let yStart = band * side / bandCount
            let yEnd = max((band + 1) * side / bandCount, yStart + 1)
            var active = 0
            var total = 0

            for y in yStart..<min(yEnd, side) {
                let row = y * side
                for x in 0..<side {
                    total += 1
                    if brightness[row + x] >= thresholdByte {
                        active += 1
                    }
                }
            }

            let density = total > 0 ? Double(active) / Double(total) : 0
            return Float(pow(density, densityPower))
        }
    }

    private func frequencies(
        bandCount: Int,
        baseFrequency: Double,
        pitchSpanOctaves: Double
    ) -> [Double] {
        (0..<bandCount).map { band in
            let upward = Double(bandCount - 1 - band) / Double(max(bandCount - 1, 1))
            return baseFrequency * pow(2, upward * pitchSpanOctaves)
        }
    }
}

enum ImageSonificationVideoExporter {
    static func export(
        source: ImageSonificationSpectralImage,
        settings: ImageSonificationSettings
    ) async throws -> URL {
        let settings = settings.normalized()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExeligmosSonificationExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = UUID().uuidString
        let videoURL = directory.appendingPathComponent("\(id)-video.mov")
        let audioURL = directory.appendingPathComponent("\(id)-audio.caf")
        let outputURL = directory.appendingPathComponent("sonification-\(id).mov")

        [videoURL, audioURL, outputURL].forEach { url in
            try? FileManager.default.removeItem(at: url)
        }

        let audioBuffer = try source.audioBuffer(settings: settings, sampleRate: 44_100)
        let audioFile = try AVAudioFile(forWriting: audioURL, settings: audioBuffer.format.settings)
        try audioFile.write(from: audioBuffer)

        try await renderVideo(
            source: source,
            settings: settings,
            outputURL: videoURL
        )

        let finalURL = try await combine(videoURL: videoURL, audioURL: audioURL, outputURL: outputURL)
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: audioURL)
        return finalURL
    }

    private static func renderVideo(
        source: ImageSonificationSpectralImage,
        settings: ImageSonificationSettings,
        outputURL: URL,
        side: Int = 512,
        framesPerSecond: Int32 = 24
    ) async throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_400_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(input) else {
            throw ImageSonificationError.couldNotExportVideo
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? ImageSonificationError.couldNotExportVideo
        }
        writer.startSession(atSourceTime: .zero)

        let duration = max(settings.cycleDuration, 0.1)
        let frameCount = max(Int(duration * Double(framesPerSecond)), 1)
        for frame in 0..<frameCount {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000)
            }

            let progress = Double(frame) / Double(max(frameCount - 1, 1))
            let threshold = settings.threshold(atCycleProgress: progress)
            guard
                let image = source.binaryImage(threshold: threshold),
                let pixelBuffer = makePixelBuffer(from: image, side: side)
            else {
                throw ImageSonificationError.couldNotExportVideo
            }

            let presentationTime = CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? ImageSonificationError.couldNotExportVideo
            }
        }

        input.markAsFinished()
        try await finishWriting(writer)
    }

    private static func combine(videoURL: URL, audioURL: URL, outputURL: URL) async throws -> URL {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let duration = try await videoAsset.load(.duration)

        guard
            let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
            let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw ImageSonificationError.couldNotExportVideo
        }

        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceVideoTrack,
            at: .zero
        )
        videoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        if
            let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
            let audioDuration = try await audioAsset.load(.duration)
            let insertDuration = CMTimeCompare(audioDuration, duration) < 0 ? audioDuration : duration
            try audioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: insertDuration),
                of: sourceAudioTrack,
                at: .zero
            )
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ImageSonificationError.couldNotExportVideo
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true

        let exportSessionBox = NonSendableCallbackBox(exportSession)
        try await withCheckedThrowingContinuation { continuation in
            exportSessionBox.value.exportAsynchronously {
                switch exportSessionBox.value.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed, .cancelled:
                    continuation.resume(throwing: exportSessionBox.value.error ?? ImageSonificationError.couldNotExportVideo)
                default:
                    continuation.resume(throwing: ImageSonificationError.couldNotExportVideo)
                }
            }
        }

        return outputURL
    }

    private static func makePixelBuffer(from image: UIImage, side: Int) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            side,
            side,
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard
            let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
            let context = CGContext(
                data: baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else {
            return nil
        }

        UIColor.black.setFill()
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        guard let cgImage = image.cgImage else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixelBuffer
    }

    private static func finishWriting(_ writer: AVAssetWriter) async throws {
        let writerBox = NonSendableCallbackBox(writer)
        try await withCheckedThrowingContinuation { continuation in
            writerBox.value.finishWriting {
                if writerBox.value.status == .completed {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: writerBox.value.error ?? ImageSonificationError.couldNotExportVideo)
                }
            }
        }
    }
}

@MainActor
final class ImageSonificationAudioController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var statusMessage = ""

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let renderQueue = DispatchQueue(label: "exeligmos.image-sonification.audio", qos: .userInitiated)
    private var isConfigured = false
    private var playbackGeneration = 0

    func play(source: ImageSonificationSpectralImage, settings: ImageSonificationSettings) {
        playbackGeneration += 1
        let generation = playbackGeneration
        if player.isPlaying {
            player.stop()
        }
        isPlaying = false
        statusMessage = "Preparing"

        renderQueue.async { [weak self, source, settings] in
            let result = Result {
                try source.audioBuffer(settings: settings)
            }

            Task { @MainActor [weak self] in
                self?.finishPlay(result, generation: generation)
            }
        }
    }

    func stop() {
        playbackGeneration += 1
        if player.isPlaying {
            player.stop()
        }
        isPlaying = false
        if statusMessage == "Scanning" {
            statusMessage = ""
        }
    }

    private func finishPlay(_ result: Result<AVAudioPCMBuffer, Error>, generation: Int) {
        guard playbackGeneration == generation else { return }

        switch result {
        case .success(let buffer):
            do {
                try configureEngineIfNeeded(format: buffer.format)
                player.scheduleBuffer(buffer, at: nil, options: .loops)
                player.play()
                isPlaying = true
                statusMessage = "Scanning"
            } catch {
                statusMessage = error.localizedDescription
                isPlaying = false
            }
        case .failure(let error):
            statusMessage = error.localizedDescription
            isPlaying = false
        }
    }

    private func configureEngineIfNeeded(format: AVAudioFormat) throws {
        configureAudioSessionIfPossible()

        guard !isConfigured else {
            if !engine.isRunning {
                try engine.start()
            }
            return
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        isConfigured = true
    }

    private func configureAudioSessionIfPossible() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP]
            )
            try session.setActive(true)
        } catch {
            // The camera/session can temporarily own audio priority. AVAudioEngine may still start under the active session.
        }
    }
}

enum ImageSonificationError: LocalizedError {
    case couldNotPrepareImage
    case couldNotCreateAudioBuffer
    case couldNotExportVideo

    var errorDescription: String? {
        switch self {
        case .couldNotPrepareImage:
            "The image could not be prepared for sonification."
        case .couldNotCreateAudioBuffer:
            "The audio buffer could not be created."
        case .couldNotExportVideo:
            "The sweep video could not be exported."
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private final class NonSendableCallbackBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

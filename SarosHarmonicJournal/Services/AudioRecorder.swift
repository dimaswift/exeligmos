import AVFoundation
import Combine
import Foundation

enum MediaTemporalMode: String, Hashable, Sendable {
    case forward
    case backward
    case forwardBackward
}

enum AudioRecordingMode: String, Hashable, Sendable {
    case reflected
    case convolution
}

final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var lastItem: JournalMediaItem?
    @Published private(set) var recordingMode: AudioRecordingMode?

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

    func toggleRecording(mode: AudioRecordingMode = .reflected) throws {
        if isRecording {
            stop()
        } else {
            try start(mode: mode)
        }
    }

    func consumeLastItem() -> JournalMediaItem? {
        defer { lastItem = nil }
        return lastItem
    }

    private func start(mode: AudioRecordingMode) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let url = try MediaStorage.newMediaURL(fileExtension: "m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.prepareToRecord()
        recorder.record()

        self.recorder = recorder
        currentURL = url
        recordingMode = mode
        isRecording = true
    }

    private func stop() {
        recorder?.stop()
        recorder = nil
        isRecording = false

        if let currentURL {
            do {
                let processedURL: URL
                switch recordingMode ?? .reflected {
                case .reflected:
                    processedURL = try MediaPalindromeProcessor.makeTemporalAudio(from: currentURL, mode: .forwardBackward)
                case .convolution:
                    processedURL = try MediaPalindromeProcessor.makeConvolvedAudio(from: currentURL)
                }
                if processedURL != currentURL {
                    try? FileManager.default.removeItem(at: currentURL)
                }
                lastItem = JournalMediaItem(type: .audio, localPath: MediaStorage.relativePath(for: processedURL))
            } catch {
                lastItem = JournalMediaItem(type: .audio, localPath: MediaStorage.relativePath(for: currentURL))
            }
        }
        currentURL = nil
        recordingMode = nil
    }
}

enum MediaPalindromeProcessor {
    enum ProcessorError: LocalizedError {
        case emptyAudio
        case unsupportedAudioFormat
        case exportUnavailable
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .emptyAudio:
                "The audio recording is empty."
            case .unsupportedAudioFormat:
                "The audio format could not be reversed."
            case .exportUnavailable:
                "The media exporter could not be created."
            case .exportFailed:
                "The media could not be exported."
            }
        }
    }

    static func makePalindromicAudio(from inputURL: URL, outputURL: URL? = nil) throws -> URL {
        try makeTemporalAudio(from: inputURL, mode: .forwardBackward, outputURL: outputURL)
    }

    static func makeTemporalAudio(from inputURL: URL, mode: MediaTemporalMode, outputURL: URL? = nil) throws -> URL {
        let inputFile = try AVAudioFile(forReading: inputURL)
        let frameCapacity = AVAudioFrameCount(inputFile.length)
        guard frameCapacity > 0 else {
            throw ProcessorError.emptyAudio
        }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFile.processingFormat,
            frameCapacity: frameCapacity
        ) else {
            throw ProcessorError.unsupportedAudioFormat
        }
        try inputFile.read(into: sourceBuffer)

        let floatBuffer = try floatBuffer(from: sourceBuffer)
        let frameCount = Int(floatBuffer.frameLength)
        guard frameCount > 0 else {
            throw ProcessorError.emptyAudio
        }
        guard let sourceChannels = floatBuffer.floatChannelData else {
            throw ProcessorError.unsupportedAudioFormat
        }

        let outputFrameCount = mode == .forwardBackward ? frameCount * 2 : frameCount
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: floatBuffer.format,
            frameCapacity: AVAudioFrameCount(outputFrameCount)
        ), let outputChannels = outputBuffer.floatChannelData else {
            throw ProcessorError.unsupportedAudioFormat
        }
        outputBuffer.frameLength = AVAudioFrameCount(outputFrameCount)

        let channelCount = Int(floatBuffer.format.channelCount)
        for channel in 0..<channelCount {
            let source = sourceChannels[channel]
            let destination = outputChannels[channel]
            switch mode {
            case .forward:
                destination.update(from: source, count: frameCount)
            case .backward:
                for index in 0..<frameCount {
                    destination[index] = source[frameCount - index - 1]
                }
            case .forwardBackward:
                destination.update(from: source, count: frameCount)
                for index in 0..<frameCount {
                    destination[frameCount + index] = source[frameCount - index - 1]
                }
            }
        }

        let destinationURL = try outputURL ?? MediaStorage.newMediaURL(fileExtension: "caf")
        try? FileManager.default.removeItem(at: destinationURL)
        let outputFile = try AVAudioFile(forWriting: destinationURL, settings: outputBuffer.format.settings)
        try outputFile.write(from: outputBuffer)
        return destinationURL
    }

    static func makeConvolvedAudio(from inputURL: URL, outputURL: URL? = nil) throws -> URL {
        let inputFile = try AVAudioFile(forReading: inputURL)
        let frameCapacity = AVAudioFrameCount(inputFile.length)
        guard frameCapacity > 0 else {
            throw ProcessorError.emptyAudio
        }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFile.processingFormat,
            frameCapacity: frameCapacity
        ) else {
            throw ProcessorError.unsupportedAudioFormat
        }
        try inputFile.read(into: sourceBuffer)

        let floatBuffer = try floatBuffer(from: sourceBuffer)
        let frameCount = Int(floatBuffer.frameLength)
        guard frameCount > 0 else {
            throw ProcessorError.emptyAudio
        }
        guard let sourceChannels = floatBuffer.floatChannelData else {
            throw ProcessorError.unsupportedAudioFormat
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: floatBuffer.format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let outputChannels = outputBuffer.floatChannelData else {
            throw ProcessorError.unsupportedAudioFormat
        }
        outputBuffer.frameLength = AVAudioFrameCount(frameCount)

        let channelCount = Int(floatBuffer.format.channelCount)
        for channel in 0..<channelCount {
            let source = sourceChannels[channel]
            let destination = outputChannels[channel]
            for index in 0..<frameCount {
                destination[index] = (source[index] + source[frameCount - index - 1]) * 0.5
            }
        }

        let destinationURL = try outputURL ?? MediaStorage.newMediaURL(fileExtension: "caf")
        try? FileManager.default.removeItem(at: destinationURL)
        let outputFile = try AVAudioFile(forWriting: destinationURL, settings: outputBuffer.format.settings)
        try outputFile.write(from: outputBuffer)
        return destinationURL
    }

    static func makePalindromicAudio(from asset: AVAsset) async throws -> URL? {
        try await makeTemporalAudio(from: asset, mode: .forwardBackward)
    }

    static func makeTemporalAudio(from asset: AVAsset, mode: MediaTemporalMode) async throws -> URL? {
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            return nil
        }

        let forwardAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let palindromeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")

        [forwardAudioURL, palindromeURL].forEach { url in
            try? FileManager.default.removeItem(at: url)
        }

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ProcessorError.exportUnavailable
        }
        exporter.outputURL = forwardAudioURL
        exporter.outputFileType = .m4a

        nonisolated(unsafe) let unsafeExporter = exporter
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            unsafeExporter.exportAsynchronously {
                switch unsafeExporter.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: unsafeExporter.error ?? ProcessorError.exportFailed)
                default:
                    continuation.resume(throwing: ProcessorError.exportFailed)
                }
            }
        }

        defer {
            try? FileManager.default.removeItem(at: forwardAudioURL)
        }
        return try makeTemporalAudio(from: forwardAudioURL, mode: mode, outputURL: palindromeURL)
    }

    private static func floatBuffer(from sourceBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if sourceBuffer.floatChannelData != nil,
           sourceBuffer.format.commonFormat == .pcmFormatFloat32,
           !sourceBuffer.format.isInterleaved {
            return sourceBuffer
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceBuffer.format.sampleRate,
            channels: sourceBuffer.format.channelCount,
            interleaved: false
        ) else {
            throw ProcessorError.unsupportedAudioFormat
        }
        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            throw ProcessorError.unsupportedAudioFormat
        }

        let ratio = targetFormat.sampleRate / max(sourceBuffer.format.sampleRate, 1)
        let convertedCapacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * ratio).rounded(.up)) + 16
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: convertedCapacity
        ) else {
            throw ProcessorError.unsupportedAudioFormat
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: convertedBuffer, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            status.pointee = .haveData
            return sourceBuffer
        }

        if let conversionError {
            throw conversionError
        }
        return convertedBuffer
    }
}

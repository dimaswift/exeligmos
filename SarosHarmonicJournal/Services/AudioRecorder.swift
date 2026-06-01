import AVFoundation
import Combine
import Foundation

final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var lastItem: JournalMediaItem?

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

    func toggleRecording() throws {
        if isRecording {
            stop()
        } else {
            try start()
        }
    }

    func consumeLastItem() -> JournalMediaItem? {
        defer { lastItem = nil }
        return lastItem
    }

    private func start() throws {
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
        isRecording = true
    }

    private func stop() {
        recorder?.stop()
        recorder = nil
        isRecording = false

        if let currentURL {
            lastItem = JournalMediaItem(type: .audio, localPath: currentURL.path)
        }
        currentURL = nil
    }
}

import AVFoundation
import SwiftUI
import UIKit

struct JournalRecordRow: View {
    let record: JournalRecord
    let entityTitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OctalGlyph(value: record.octalAddress, depth: record.harmonicDepth)
                .frame(width: 36, height: 36)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entityTitle)
                        .font(.headline)
                    Spacer(minLength: 12)
                    Text(record.octalAddress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.cyan)
                }

                if let text = record.text, !text.isEmpty {
                    Text(text)
                        .lineLimit(3)
                } else if let emoji = record.emoji, !emoji.isEmpty {
                    Text(emoji)
                        .lineLimit(1)
                }

                MediaThumbnailStrip(items: record.mediaItems)

                HStack {
                    Text(JournalFormatters.dateTime.string(from: record.eventDate))
                    Spacer()
                    Text(record.triggerType.displayName)
                    if !record.mediaItems.isEmpty {
                        Label("\(record.mediaItems.count)", systemImage: "paperclip")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct JournalRecordDetailView: View {
    let record: JournalRecord
    let entityTitle: String

    @StateObject private var audioPlayer = RecordAudioPlayer()

    private var photos: [JournalMediaItem] {
        record.mediaItems.filter { $0.type == .photo }
    }

    private var audioItems: [JournalMediaItem] {
        record.mediaItems.filter { $0.type == .audio }
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    OctalGlyph(value: record.octalAddress, depth: record.harmonicDepth)
                        .frame(width: 88, height: 88)
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(entityTitle)
                            .font(.headline)
                        Text(record.octalAddress)
                            .font(.system(.title2, design: .monospaced))
                            .foregroundStyle(.cyan)
                        Text(JournalFormatters.dateTime.string(from: record.eventDate))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                if let text = record.text, !text.isEmpty {
                    Text(text)
                }

                if let emoji = record.emoji, !emoji.isEmpty {
                    MetadataRow(title: "Marker", value: emoji)
                }
            }

            Section("Images") {
                if photos.isEmpty {
                    Text("No images attached")
                        .foregroundStyle(.secondary)
                } else {
                    AttachedImageCarousel(items: photos)
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
            }

            Section("Audio") {
                if audioItems.isEmpty {
                    Text("No audio attached")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(audioItems.enumerated()), id: \.element.id) { index, item in
                        Button {
                            audioPlayer.toggle(path: item.localPath)
                        } label: {
                            Label(
                                audioButtonTitle(for: item, index: index),
                                systemImage: audioPlayer.isPlaying(path: item.localPath) ? "stop.circle.fill" : "play.circle.fill"
                            )
                        }
                    }
                }
            }

            Section("Metadata") {
                MetadataRow(title: "Saros", value: "\(record.saros)")
                MetadataRow(title: "Bin", value: "\(record.binIndex)")
                MetadataRow(title: "Trigger", value: record.triggerType.displayName)
            }
        }
        .navigationTitle("Record")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            audioPlayer.stop()
        }
        .alert("Audio failed", isPresented: Binding(get: {
            audioPlayer.errorMessage != nil
        }, set: { _ in
            audioPlayer.clearError()
        })) {
            Button("OK", role: .cancel) {
                audioPlayer.clearError()
            }
        } message: {
            Text(audioPlayer.errorMessage ?? "")
        }
    }

    private func audioButtonTitle(for item: JournalMediaItem, index: Int) -> String {
        if audioPlayer.isPlaying(path: item.localPath) {
            return "Stop audio"
        }
        return audioItems.count == 1 ? "Play audio record" : "Play audio \(index + 1)"
    }
}

private struct MediaThumbnailStrip: View {
    let items: [JournalMediaItem]

    var body: some View {
        let photos = items.filter { $0.type == .photo }
        if !photos.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(photos) { item in
                        if let image = UIImage(contentsOfFile: item.localPath) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct AttachedImageCarousel: View {
    let items: [JournalMediaItem]

    var body: some View {
        TabView {
            ForEach(items) { item in
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.secondary.opacity(0.12))

                    if let image = UIImage(contentsOfFile: item.localPath) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Image unavailable", systemImage: "photo")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
    }
}

private final class RecordAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var currentPath: String?
    @Published private(set) var errorMessage: String?

    private var player: AVAudioPlayer?

    func isPlaying(path: String) -> Bool {
        currentPath == path && player?.isPlaying == true
    }

    func toggle(path: String) {
        if isPlaying(path: path) {
            stop()
        } else {
            play(path: path)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        currentPath = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func clearError() {
        errorMessage = nil
    }

    private func play(path: String) {
        stop()

        guard FileManager.default.fileExists(atPath: path) else {
            errorMessage = "The audio file could not be found."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player.delegate = self
            player.prepareToPlay()
            player.play()

            self.player = player
            currentPath = path
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard self.player === player else { return }
            self.player = nil
            self.currentPath = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

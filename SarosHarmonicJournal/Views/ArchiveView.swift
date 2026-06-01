import AVFoundation
import AVKit
import MapKit
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
                    Text(JournalRecordMarkers.marker(from: record.emoji))
                        .font(.system(size: 34))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }

                if let text = record.text, !text.isEmpty {
                    Text(text)
                        .lineLimit(3)
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
    @EnvironmentObject private var services: AppServices

    let record: JournalRecord
    let entityTitle: String

    @StateObject private var audioPlayer = RecordAudioPlayer()
    @State private var exportShareItem: RecordShareItem?
    @State private var exportErrorMessage: String?
    @State private var locationMapItem: RecordLocationMapItem?

    private var photos: [JournalMediaItem] {
        record.mediaItems.filter { $0.type.isImage }
    }

    private var audioItems: [JournalMediaItem] {
        record.mediaItems.filter { $0.type == .audio }
    }

    private var videoItems: [JournalMediaItem] {
        record.mediaItems.filter { $0.type == .video }
    }

    private var capturedMediaURL: URL? {
        guard let item = record.mediaItems.first(where: { $0.type == .symbolicPhoto })
            ?? record.mediaItems.first(where: { $0.type == .video })
            ?? photos.first else {
            return nil
        }
        let url = MediaStorage.url(for: item)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var recordCoordinate: CLLocationCoordinate2D? {
        guard let latitude = record.latitude, let longitude = record.longitude else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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

                    Spacer(minLength: 12)

                    Text(JournalRecordMarkers.marker(from: record.emoji))
                        .font(.system(size: 58))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(.vertical, 4)

                if let text = record.text, !text.isEmpty {
                    Text(text)
                }
            }

            if !photos.isEmpty {
                Section("Images") {
                    AttachedImageCarousel(items: photos)
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
            }

            if !videoItems.isEmpty {
                Section("Videos") {
                    ForEach(Array(videoItems.enumerated()), id: \.element.id) { index, item in
                        let url = MediaStorage.url(for: item)
                        if FileManager.default.fileExists(atPath: url.path) {
                            RecordVideoPlayerView(
                                url: url,
                                title: videoItems.count == 1 ? "Video capture" : "Video capture \(index + 1)"
                            )
                            .frame(height: 260)
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        } else {
                            ContentUnavailableView("Video unavailable", systemImage: "video.slash")
                        }
                    }
                }
            }

            Section("Audio") {
                if audioItems.isEmpty {
                    Text("No audio attached")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(audioItems.enumerated()), id: \.element.id) { index, item in
                        Button {
                            audioPlayer.toggle(url: MediaStorage.url(for: item))
                        } label: {
                            Label(
                                audioButtonTitle(for: item, index: index),
                                systemImage: audioPlayer.isPlaying(url: MediaStorage.url(for: item)) ? "stop.circle.fill" : "play.circle.fill"
                            )
                        }
                    }
                }
            }

            Section("Metadata") {
                MetadataRow(title: "Saros", value: "\(record.saros)")
                MetadataRow(title: "Bin", value: "\(record.binIndex)")
                MetadataRow(title: "Trigger", value: record.triggerType.displayName)
                if let recordCoordinate {
                    Button {
                        locationMapItem = RecordLocationMapItem(
                            coordinate: recordCoordinate,
                            title: entityTitle,
                            subtitle: JournalFormatters.dateTime.string(from: record.eventDate)
                        )
                    } label: {
                        Label("Open record map", systemImage: "map")
                    }
                }
            }
        }
        .navigationTitle("Record")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let capturedMediaURL {
                    ShareLink(item: capturedMediaURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share captured media")
                } else {
                    Button {} label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(true)
                    .accessibilityLabel("Share captured media")
                }

                Button {
                    exportRecord()
                } label: {
                    Image(systemName: "archivebox")
                }
                .accessibilityLabel("Export record archive")
            }
        }
        .onDisappear {
            audioPlayer.stop()
        }
        .sheet(item: $exportShareItem) { item in
            ActivityShareSheet(activityItems: [item.url])
        }
        .sheet(item: $locationMapItem) { item in
            NavigationStack {
                RecordLocationMapView(item: item)
            }
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
        .alert("Export failed", isPresented: Binding(get: {
            exportErrorMessage != nil
        }, set: { _ in
            exportErrorMessage = nil
        })) {
            Button("OK", role: .cancel) {
                exportErrorMessage = nil
            }
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    private func audioButtonTitle(for item: JournalMediaItem, index: Int) -> String {
        if audioPlayer.isPlaying(url: MediaStorage.url(for: item)) {
            return "Stop audio"
        }
        return audioItems.count == 1 ? "Play audio record" : "Play audio \(index + 1)"
    }

    private func exportRecord() {
        do {
            let url = try services.exportService.exportRecordZIP(record: record, entityTitle: entityTitle)
            exportShareItem = RecordShareItem(url: url)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }
}

private struct RecordShareItem: Identifiable {
    let url: URL

    var id: String { url.path }
}

private struct RecordLocationMapItem: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let title: String
    let subtitle: String
}

private struct RecordLocationMapView: View {
    @Environment(\.dismiss) private var dismiss

    let item: RecordLocationMapItem

    @State private var position: MapCameraPosition

    init(item: RecordLocationMapItem) {
        self.item = item
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: item.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )))
    }

    var body: some View {
        Map(position: $position) {
            Marker(item.title, coordinate: item.coordinate)
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("Record Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct MediaThumbnailStrip: View {
    let items: [JournalMediaItem]

    var body: some View {
        let visibleItems = items.filter { $0.type.isImage || $0.type == .video }
        if !visibleItems.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(visibleItems) { item in
                        if item.type.isImage, let image = UIImage(contentsOfFile: MediaStorage.url(for: item).path) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else if item.type == .video {
                            Image(systemName: "video.fill")
                                .font(.title2)
                                .foregroundStyle(.cyan)
                                .frame(width: 72, height: 72)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
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

                    if let image = UIImage(contentsOfFile: MediaStorage.url(for: item).path) {
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

private struct RecordVideoPlayerView: View {
    let url: URL
    let title: String

    @State private var player: AVPlayer

    init(url: URL, title: String) {
        self.url = url
        self.title = title
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VideoPlayer(player: player)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
        }
        .onDisappear {
            player.pause()
        }
    }
}

private final class RecordAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var currentPath: String?
    @Published private(set) var errorMessage: String?

    private var player: AVAudioPlayer?

    func isPlaying(url: URL) -> Bool {
        currentPath == url.path && player?.isPlaying == true
    }

    func toggle(url: URL) {
        if isPlaying(url: url) {
            stop()
        } else {
            play(url: url)
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

    private func play(url: URL) {
        stop()

        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "The audio file could not be found."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()

            self.player = player
            currentPath = url.path
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

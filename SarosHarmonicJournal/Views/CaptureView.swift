import CoreLocation
import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct CaptureView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let entity: TrackedEntity
    let harmonicDepth: Int
    let recordStartedAt: Date
    var onSaved: () -> Void

    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var locationProvider = RecordLocationProvider()
    @State private var text = ""
    @State private var emoji = JournalRecordMarkers.random()
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pendingCameraMedia: [PendingMediaAttachment] = []
    @State private var pendingAttachedPhotos: [PendingMediaAttachment] = []
    @State private var isLoadingPhoto = false
    @State private var isCameraPresented = false
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        entity: TrackedEntity,
        harmonicDepth: Int,
        recordStartedAt: Date = Date(),
        onSaved: @escaping () -> Void = {}
    ) {
        self.entity = entity
        self.harmonicDepth = JournalSettings.clampedHarmonicDepth(harmonicDepth)
        self.recordStartedAt = recordStartedAt
        self.onSaved = onSaved
    }

    var body: some View {
        Form {
            Section("Thread") {
                if let reading = try? services.clockService.reading(
                    saros: entity.saros,
                    date: recordStartedAt,
                    harmonicDepth: harmonicDepth
                ) {
                    HStack {
                        OctalGlyph(value: reading.octalAddress, depth: reading.harmonicDepth)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(entity.displayTitle)
                                .font(.headline)
                            Text("Saros \(reading.saros) · \(reading.octalAddress)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Next flip in \(reading.timeUntilNextFlip.compactDuration)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Record") {
                TextField("Emoji marker", text: $emoji)
                    .textContentType(.none)
                TextField("Note", text: $text, axis: .vertical)
                    .lineLimit(4...10)
                    .textContentType(.none)

                Button {
                    isCameraPresented = true
                } label: {
                    Label("Capture photo", systemImage: "camera.viewfinder")
                }

                PhotosPicker(selection: $photoItems, matching: .images) {
                    Label("Add from library", systemImage: "photo")
                }
                .onChange(of: photoItems) { _, newItems in
                    Task {
                        await loadPhotos(from: newItems)
                    }
                }

                if isLoadingPhoto {
                    HStack {
                        ProgressView()
                        Text("Loading photo")
                            .foregroundStyle(.secondary)
                    }
                }

                if !pendingCameraMedia.isEmpty {
                    PendingMediaGroup(title: "Camera captures") {
                        ForEach(pendingCameraMedia) { media in
                            PendingMediaRow(media: media) {
                                pendingCameraMedia.removeAll { $0.id == media.id }
                            }
                        }
                    }
                }

                if !pendingAttachedPhotos.isEmpty {
                    PendingMediaGroup(title: "Attached images") {
                        ForEach(pendingAttachedPhotos) { media in
                            PendingMediaRow(media: media) {
                                pendingAttachedPhotos.removeAll { $0.id == media.id }
                            }
                        }
                    }
                }

                Button {
                    do {
                        try audioRecorder.toggleRecording(mode: .reflected)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label(
                        audioRecorder.isRecording && audioRecorder.recordingMode == .reflected ? "Stop audio" : "Record audio",
                        systemImage: audioRecorder.isRecording && audioRecorder.recordingMode == .reflected ? "stop.circle" : "mic.circle"
                    )
                }
                .disabled(audioRecorder.isRecording && audioRecorder.recordingMode != .reflected)

                Button {
                    do {
                        try audioRecorder.toggleRecording(mode: .convolution)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label(
                        audioRecorder.isRecording && audioRecorder.recordingMode == .convolution ? "Stop convolution" : "Record convolution",
                        systemImage: audioRecorder.isRecording && audioRecorder.recordingMode == .convolution ? "stop.circle" : "waveform.path.ecg"
                    )
                }
                .disabled(audioRecorder.isRecording && audioRecorder.recordingMode != .convolution)
            }

            Section {
                Button {
                    Task { await saveRecord() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Label("Save record", systemImage: "tray.and.arrow.down")
                    }
                }
                .disabled(isSaving || isLoadingPhoto)
            }
        }
        .navigationTitle("Record")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
        .task {
            locationProvider.prepare()
        }
        .alert("Capture failed", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            MirrorCameraView { media in
                pendingCameraMedia.append(PendingMediaAttachment(
                    media: media,
                    displayName: "\(media.type.recordDisplayName) \(pendingCameraMedia.count + 1)"
                ))
            }
        }
    }

    @MainActor
    private func loadPhotos(from items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }

        isLoadingPhoto = true
        defer {
            isLoadingPhoto = false
            photoItems = []
        }

        do {
            for item in items {
                guard let pickedPhoto = try await item.loadTransferable(type: PickedPhotoTransfer.self) else {
                    continue
                }

                pendingAttachedPhotos.append(PendingMediaAttachment(
                    data: pickedPhoto.data,
                    sourceURL: nil,
                    fileExtension: preferredFileExtension(for: item),
                    type: .photo,
                    displayName: "Attached image \(pendingAttachedPhotos.count + 1)"
                ))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func preferredFileExtension(for item: PhotosPickerItem) -> String {
        item.supportedContentTypes
            .first(where: { $0.conforms(to: .image) })?
            .preferredFilenameExtension ?? "jpg"
    }

    @MainActor
    private func saveRecord() async {
        isSaving = true
        defer { isSaving = false }

        do {
            var mediaItems: [JournalMediaItem] = []
            for pendingMedia in pendingCameraMedia {
                mediaItems.append(
                    try pendingMedia.save()
                )
            }
            for pendingMedia in pendingAttachedPhotos {
                mediaItems.append(
                    try pendingMedia.save()
                )
            }
            if let audioItem = audioRecorder.consumeLastItem() {
                mediaItems.append(audioItem)
            }

            let reading = try services.clockService.reading(
                saros: entity.saros,
                date: recordStartedAt,
                harmonicDepth: harmonicDepth
            )
            let coordinate = locationProvider.coordinate

            let record = JournalRecord(
                entityID: entity.id,
                eventDate: recordStartedAt,
                text: text.nilIfBlank,
                emoji: emoji.nilIfBlank ?? JournalRecordMarkers.random(),
                mediaItems: mediaItems,
                saros: reading.saros,
                harmonicDepth: reading.harmonicDepth,
                octalAddress: reading.octalAddress,
                binIndex: reading.binIndex,
                phase: reading.phase,
                triggerType: .manual,
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude
            )

            modelContext.insert(record)
            try modelContext.save()
            text = ""
            emoji = JournalRecordMarkers.random()
            photoItems = []
            pendingCameraMedia = []
            pendingAttachedPhotos = []
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private final class RecordLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func prepare() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

private struct PendingMediaAttachment: Identifiable {
    let id = UUID()
    let data: Data?
    let sourceURL: URL?
    let fileExtension: String
    let type: MediaType
    let displayName: String

    init(
        data: Data?,
        sourceURL: URL?,
        fileExtension: String,
        type: MediaType,
        displayName: String
    ) {
        self.data = data
        self.sourceURL = sourceURL
        self.fileExtension = fileExtension
        self.type = type
        self.displayName = displayName
    }

    init(media: MirrorCameraCapturedMedia, displayName: String) {
        self.data = media.data
        self.sourceURL = media.sourceURL
        self.fileExtension = media.fileExtension
        self.type = media.type
        self.displayName = displayName
    }

    var uiImage: UIImage? {
        guard let data else { return nil }
        return UIImage(data: data)
    }

    var sizeDescription: String {
        if let data {
            return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        }
        if let sourceURL,
           let size = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return "Pending"
    }

    func save() throws -> JournalMediaItem {
        if let data {
            return try MediaStorage.saveData(data, fileExtension: fileExtension, type: type)
        }
        if let sourceURL {
            return try MediaStorage.saveFile(at: sourceURL, fileExtension: fileExtension, type: type)
        }
        throw PendingMediaError.missingSource
    }
}

private struct PendingMediaGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(.vertical, 4)
    }
}

private struct PendingMediaRow: View {
    let media: PendingMediaAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let image = media.uiImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: media.type.systemImage)
                    .font(.title2)
                    .frame(width: 58, height: 58)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(media.displayName)
                    .font(.subheadline)
                Text("\(media.fileExtension.uppercased()) · \(media.sizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive, action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove media")
        }
    }
}

private enum PendingMediaError: LocalizedError {
    case missingSource

    var errorDescription: String? {
        "The captured media could not be found."
    }
}

private extension MediaType {
    var systemImage: String {
        switch self {
        case .photo, .symbolicPhoto:
            "photo"
        case .video:
            "video"
        case .audio:
            "waveform"
        }
    }

    var recordDisplayName: String {
        switch self {
        case .video:
            "Video capture"
        case .photo, .symbolicPhoto:
            "Camera capture"
        case .audio:
            "Audio"
        }
    }
}

private struct PickedPhotoTransfer: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            PickedPhotoTransfer(data: data)
        }
    }
}

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
    var onSaved: () -> Void

    @StateObject private var audioRecorder = AudioRecorder()
    @State private var text = ""
    @State private var emoji = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingPhoto: PendingPhotoAttachment?
    @State private var isLoadingPhoto = false
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        entity: TrackedEntity,
        harmonicDepth: Int,
        onSaved: @escaping () -> Void = {}
    ) {
        self.entity = entity
        self.harmonicDepth = JournalSettings.clampedHarmonicDepth(harmonicDepth)
        self.onSaved = onSaved
    }

    var body: some View {
        Form {
            Section("Thread") {
                if let reading = try? services.clockService.reading(
                    saros: entity.saros,
                    date: Date(),
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

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(pendingPhoto == nil ? "Add photo" : "Change photo", systemImage: "photo")
                }
                .onChange(of: photoItem) { _, newItem in
                    Task {
                        await loadPhoto(from: newItem)
                    }
                }

                if isLoadingPhoto {
                    HStack {
                        ProgressView()
                        Text("Loading photo")
                            .foregroundStyle(.secondary)
                    }
                } else if let pendingPhoto {
                    PendingPhotoRow(photo: pendingPhoto) {
                        photoItem = nil
                        self.pendingPhoto = nil
                    }
                }

                Button {
                    do {
                        try audioRecorder.toggleRecording()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label(audioRecorder.isRecording ? "Stop audio" : "Record audio", systemImage: audioRecorder.isRecording ? "stop.circle" : "mic.circle")
                }
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
        .alert("Capture failed", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func loadPhoto(from item: PhotosPickerItem?) async {
        pendingPhoto = nil
        guard let item else { return }

        isLoadingPhoto = true
        defer { isLoadingPhoto = false }

        do {
            guard let pickedPhoto = try await item.loadTransferable(type: PickedPhotoTransfer.self) else {
                errorMessage = "The selected photo could not be loaded."
                photoItem = nil
                return
            }

            pendingPhoto = PendingPhotoAttachment(
                data: pickedPhoto.data,
                fileExtension: preferredFileExtension(for: item),
                displayName: "Photo attached"
            )
        } catch {
            errorMessage = error.localizedDescription
            photoItem = nil
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
            if let pendingPhoto {
                mediaItems.append(
                    try MediaStorage.saveData(
                        pendingPhoto.data,
                        fileExtension: pendingPhoto.fileExtension,
                        type: .photo
                    )
                )
            }
            if let audioItem = audioRecorder.consumeLastItem() {
                mediaItems.append(audioItem)
            }

            let reading = try services.clockService.reading(
                saros: entity.saros,
                date: Date(),
                harmonicDepth: harmonicDepth
            )

            let record = JournalRecord(
                entityID: entity.id,
                text: text.nilIfBlank,
                emoji: emoji.nilIfBlank,
                mediaItems: mediaItems,
                saros: reading.saros,
                harmonicDepth: reading.harmonicDepth,
                octalAddress: reading.octalAddress,
                binIndex: reading.binIndex,
                phase: reading.phase,
                triggerType: .manual
            )

            modelContext.insert(record)
            try modelContext.save()
            text = ""
            emoji = ""
            photoItem = nil
            pendingPhoto = nil
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PendingPhotoAttachment {
    let data: Data
    let fileExtension: String
    let displayName: String

    var uiImage: UIImage? {
        UIImage(data: data)
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

private struct PendingPhotoRow: View {
    let photo: PendingPhotoAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let image = photo.uiImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .frame(width: 58, height: 58)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(photo.displayName)
                    .font(.subheadline)
                Text("\(photo.fileExtension.uppercased()) · \(photo.sizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive, action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove photo")
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

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
    @Environment(\.scenePhase) private var scenePhase

    let entity: TrackedEntity
    let harmonicDepth: Int
    let recordStartedAt: Date
    var onSaved: () -> Void

    @Query private var drafts: [RecordDraft]
    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var locationProvider = RecordLocationProvider()
    @State private var noteBuffer = DraftNoteBuffer()
    @State private var noteText = ""
    @State private var noteEditorID = UUID()
    @State private var emoji = JournalRecordMarkers.random()
    @State private var eventDate: Date
    @State private var octalAddressInput = ""
    @State private var draftMediaItems: [JournalMediaItem] = []
    @State private var activeDraft: RecordDraft?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isLoadingPhoto = false
    @State private var isCameraPresented = false
    @State private var isDraftPrepared = false
    @State private var errorMessage: String?
    @State private var phaseEditError: String?
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
        _eventDate = State(initialValue: recordStartedAt)
        let entityID = entity.id
        _drafts = Query(
            filter: #Predicate<RecordDraft> { draft in
                draft.entityID == entityID
            },
            sort: \.updatedAt,
            order: .reverse
        )
    }

    var body: some View {
        Form {
            Section("Thread") {
                if let reading = try? services.clockService.reading(
                    saros: entity.saros,
                    date: eventDate,
                    harmonicDepth: harmonicDepth
                ) {
                    HStack {
                        OctalGlyph(value: reading.octalAddress, depth: reading.harmonicDepth, rarity: reading.currentRarity)
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

            Section("Timing") {
                DatePicker("Record date", selection: $eventDate)
                    .datePickerStyle(.compact)

                HStack {
                    TextField(String(repeating: "0", count: harmonicDepth), text: $octalAddressInput)
                        .font(.system(.body, design: .monospaced))
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            applyOctalAddressInput()
                        }

                    Button {
                        applyOctalAddressInput()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .disabled(octalAddressInput.count != harmonicDepth)
                    .accessibilityLabel("Apply Saros phase")
                }

                if let phaseEditError {
                    Text(phaseEditError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let moonReading = try? services.moonPhaseService.octalReading(for: eventDate, depth: 8) {
                    HStack(spacing: 12) {
                        MoonPhaseGlyph(reading: moonReading)
                            .frame(width: 38, height: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(moonReading.phaseReading.phase.displayName)
                                .font(.subheadline)
                            Text(moonReading.rarity.title)
                                .font(.caption)
                                .foregroundStyle(moonReading.rarity.color)
                        }
                    }
                }
            }

            Section("Record") {
                TextField("Emoji marker", text: $emoji)
                    .textContentType(.none)

                DraftNoteEditor(buffer: noteBuffer, initialText: noteText) {
                    commitNoteText()
                }
                .id(noteEditorID)

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

                if !draftMediaItems.isEmpty {
                    PendingMediaGroup(title: "Draft media") {
                        ForEach(draftMediaItems) { item in
                            DraftMediaRow(item: item) {
                                removeDraftMedia(item)
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
                Button("Close") {
                    commitNoteText()
                    dismiss()
                }
            }
        }
        .task {
            locationProvider.prepare()
            prepareDraft()
        }
        .onChange(of: emoji) { _, _ in persistDraft() }
        .onChange(of: eventDate) { _, _ in
            syncOctalAddressFromEventDate()
            persistDraft()
        }
        .onChange(of: octalAddressInput) { _, newValue in
            sanitizeOctalAddressInput(newValue)
        }
        .onChange(of: draftMediaItems) { _, _ in persistDraft() }
        .onChange(of: audioRecorder.lastItem) { _, item in
            guard let item else { return }
            draftMediaItems.append(item)
            _ = audioRecorder.consumeLastItem()
        }
        .onChange(of: locationProvider.coordinateDescription) { _, _ in persistDraft() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            commitNoteText()
        }
        .alert("Capture failed", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            MirrorCameraView { media in
                addCameraMedia(media)
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

                let mediaItem = try MediaStorage.saveData(
                    pickedPhoto.data,
                    fileExtension: preferredFileExtension(for: item),
                    type: .photo
                )
                draftMediaItems.append(mediaItem)
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
        commitNoteText(persist: false)
        isSaving = true
        defer { isSaving = false }

        do {
            var mediaItems = draftMediaItems
            if let audioItem = audioRecorder.consumeLastItem() {
                mediaItems.append(audioItem)
                draftMediaItems = mediaItems
            }

            let reading = try services.clockService.reading(
                saros: entity.saros,
                date: eventDate,
                harmonicDepth: harmonicDepth
            )
            let coordinate = locationProvider.coordinate
            let latitude = coordinate?.latitude ?? activeDraft?.latitude
            let longitude = coordinate?.longitude ?? activeDraft?.longitude

            let record = JournalRecord(
                entityID: entity.id,
                createdAt: activeDraft?.createdAt ?? recordStartedAt,
                eventDate: eventDate,
                text: noteBuffer.text.nilIfBlank,
                emoji: emoji.nilIfBlank ?? JournalRecordMarkers.random(),
                mediaItems: mediaItems,
                saros: reading.saros,
                harmonicDepth: reading.harmonicDepth,
                octalAddress: reading.octalAddress,
                binIndex: reading.binIndex,
                phase: reading.phase,
                triggerType: .manual,
                latitude: latitude,
                longitude: longitude
            )

            modelContext.insert(record)
            if let activeDraft {
                modelContext.delete(activeDraft)
            }
            try modelContext.save()
            self.activeDraft = nil
            noteBuffer.text = ""
            noteText = ""
            noteEditorID = UUID()
            emoji = JournalRecordMarkers.random()
            photoItems = []
            draftMediaItems = []
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func prepareDraft() {
        guard !isDraftPrepared else { return }

        do {
            if let draft = drafts.first {
                activeDraft = draft
                load(draft)
            } else {
                let reading = try services.clockService.reading(
                    saros: entity.saros,
                    date: recordStartedAt,
                    harmonicDepth: harmonicDepth
                )
                let draft = RecordDraft(
                    entityID: entity.id,
                    createdAt: recordStartedAt,
                    updatedAt: Date(),
                    eventDate: recordStartedAt,
                    emoji: emoji.nilIfBlank ?? JournalRecordMarkers.random(),
                    saros: reading.saros,
                    harmonicDepth: reading.harmonicDepth,
                    octalAddress: reading.octalAddress,
                    binIndex: reading.binIndex,
                    phase: reading.phase
                )
                modelContext.insert(draft)
                activeDraft = draft
                load(draft)
                try modelContext.save()
            }
            isDraftPrepared = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func load(_ draft: RecordDraft) {
        noteText = draft.text ?? ""
        noteBuffer.text = noteText
        noteEditorID = UUID()
        emoji = draft.emoji ?? JournalRecordMarkers.random()
        eventDate = draft.eventDate
        octalAddressInput = draft.octalAddress
        draftMediaItems = draft.mediaItems
        phaseEditError = nil
    }

    @MainActor
    private func persistDraft() {
        guard isDraftPrepared, let activeDraft else { return }

        do {
            activeDraft.text = noteBuffer.text.nilIfBlank
            activeDraft.emoji = emoji.nilIfBlank
            activeDraft.eventDate = eventDate
            activeDraft.mediaItems = draftMediaItems
            activeDraft.updatedAt = Date()

            let coordinate = locationProvider.coordinate
            activeDraft.latitude = coordinate?.latitude ?? activeDraft.latitude
            activeDraft.longitude = coordinate?.longitude ?? activeDraft.longitude

            let reading = try services.clockService.reading(
                saros: entity.saros,
                date: eventDate,
                harmonicDepth: harmonicDepth
            )
            activeDraft.apply(reading: reading)
            try modelContext.save()
        } catch {
            phaseEditError = error.localizedDescription
        }
    }

    @MainActor
    private func syncOctalAddressFromEventDate() {
        guard let reading = try? services.clockService.reading(
            saros: entity.saros,
            date: eventDate,
            harmonicDepth: harmonicDepth
        ) else {
            return
        }
        octalAddressInput = reading.octalAddress
        phaseEditError = nil
    }

    @MainActor
    private func applyOctalAddressInput() {
        let address = sanitizedOctalAddress(octalAddressInput)
        octalAddressInput = address

        guard address.count == harmonicDepth else {
            phaseEditError = "Enter \(harmonicDepth) octal digits."
            return
        }

        do {
            let reading = try services.clockService.reading(
                saros: entity.saros,
                date: eventDate,
                harmonicDepth: harmonicDepth
            )
            let index = reading.binIndex(forOctalAddress: address)
            eventDate = reading.date(forBinIndex: index)
            phaseEditError = nil
            persistDraft()
        } catch {
            phaseEditError = error.localizedDescription
        }
    }

    @MainActor
    private func sanitizeOctalAddressInput(_ value: String) {
        let sanitized = sanitizedOctalAddress(value)
        if sanitized != value {
            octalAddressInput = sanitized
        }
    }

    private func sanitizedOctalAddress(_ value: String) -> String {
        String(value.filter { "01234567".contains($0) }.prefix(harmonicDepth))
    }

    @MainActor
    private func commitNoteText(persist: Bool = true) {
        noteText = noteBuffer.text
        if persist {
            persistDraft()
        }
    }

    @MainActor
    private func addCameraMedia(_ media: MirrorCameraCapturedMedia) {
        do {
            let item = try PendingMediaAttachment(
                media: media,
                displayName: media.type.recordDisplayName
            ).save()
            draftMediaItems.append(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func removeDraftMedia(_ item: JournalMediaItem) {
        draftMediaItems.removeAll { $0.id == item.id }
        MediaStorage.delete(item)
    }
}

private final class DraftNoteBuffer {
    var text = ""
}

private struct DraftNoteEditor: View {
    let buffer: DraftNoteBuffer
    let initialText: String
    let onSubmit: () -> Void

    @State private var draftText: String
    @FocusState private var isFocused: Bool

    init(buffer: DraftNoteBuffer, initialText: String, onSubmit: @escaping () -> Void) {
        self.buffer = buffer
        self.initialText = initialText
        self.onSubmit = onSubmit
        _draftText = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if draftText.isEmpty {
                    Text("Note")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $draftText)
                    .focused($isFocused)
                    .font(.body)
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .frame(minHeight: 150, maxHeight: 260)
                    .padding(.horizontal, 2)
                    .onChange(of: draftText) { _, newValue in
                        buffer.text = newValue
                    }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button {
                    submit()
                } label: {
                    Label("Done", systemImage: "keyboard.chevron.compact.down")
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear {
            buffer.text = draftText
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    submit()
                } label: {
                    Label("Done", systemImage: "keyboard.chevron.compact.down")
                }
            }
        }
    }

    private func submit() {
        buffer.text = draftText
        isFocused = false
        onSubmit()
    }
}

private final class RecordLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()

    var coordinateDescription: String {
        guard let coordinate else { return "" }
        return "\(coordinate.latitude),\(coordinate.longitude)"
    }

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

private struct DraftMediaRow: View {
    let item: JournalMediaItem
    let remove: () -> Void

    private var image: UIImage? {
        guard item.type.isImage else { return nil }
        return UIImage(contentsOfFile: MediaStorage.url(for: item).path)
    }

    private var sizeDescription: String {
        let url = MediaStorage.url(for: item)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return "Saved"
    }

    var body: some View {
        HStack(spacing: 12) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: item.type.systemImage)
                    .font(.title2)
                    .frame(width: 58, height: 58)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.type.recordDisplayName)
                    .font(.subheadline)
                Text(sizeDescription)
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

import AVFoundation
import AVKit
import CoreLocation
import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct JournalEntryRow: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    let entry: JournalEntry
    let tags: [JournalTag]

    private var context: JournalEventContext {
        entry.context
    }

    private var matchingTags: [JournalTag] {
        let saroses = Set(context.sarosNumbers)
        return tags.filter { saroses.contains($0.saros) }
    }

    private var primeTag: JournalTag? {
        matchingTags.first(where: \.isPrime)
    }

    private var moonReading: MoonPhaseOctalReading? {
        try? services.moonPhaseService.octalReading(for: entry.eventDate, depth: 3)
    }

    var body: some View {
        let primeTint = primeTag.map { Color(hex: $0.tintHex, fallback: .white) }

        HStack(alignment: .top, spacing: 14) {
            Text(JournalRecordMarkers.marker(from: entry.emoji))
                .font(.system(size: 36))
                .frame(width: 48, height: 52, alignment: .top)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Text(primaryTitle)
                        .font(.headline)
                        .foregroundStyle(context.titleColor)
                        .lineLimit(1)
                        .padding(.top, 2)
                    Spacer(minLength: 0)
                    JournalClosestSarosPhaseGlyph(
                        context: context,
                        displayDepth: displayDepth,
                        size: 40
                    )
                }

                JournalSpikeGlyphStrip(
                    spikes: context.spikes,
                    displayDepth: displayDepth,
                    size: 28,
                    highlightedSpikeID: context.closestSpike?.id
                )

                if let text = entry.text, !text.isEmpty {
                    Text(text)
                        .lineLimit(3)
                        .font(.subheadline)
                }

                if !entry.mediaItems.isEmpty {
                    JournalEntryMediaStrip(items: entry.mediaItems)
                }

                if !matchingTags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(matchingTags) { tag in
                            Text(tag.displayEmoji)
                                .font(.caption)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    tag.isPrime
                                        ? Color(hex: tag.tintHex, fallback: .white).opacity(0.18)
                                        : Color.secondary.opacity(0.12),
                                    in: Capsule()
                                )
                        }
                    }
                }

                HStack(spacing: 10) {
                    Text(JournalFormatters.dateTime.string(from: entry.eventDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let moonReading {
                        MoonPhaseGlyph(reading: moonReading)
                            .frame(width: 24, height: 24)
                    }
                    Spacer(minLength: 8)
                    JournalWaveDirectionIcon(direction: context.direction, size: 12)
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, primeTint == nil ? 0 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let primeTint {
                RoundedRectangle(cornerRadius: 8)
                    .fill(primeTint.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(primeTint.opacity(0.28), lineWidth: 1)
                    }
            }
        }
        .contentShape(Rectangle())
    }

    private var primaryTitle: String {
        context.displayTitleWithoutSaros
    }

    private var displayDepth: Int {
        JournalSettings.clampedHarmonicDepth(harmonicDepth)
    }
}

struct JournalEntryDetailView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    let entry: JournalEntry
    let tags: [JournalTag]

    @StateObject private var audioPlayer = JournalEntryAudioPlayer()
    @State private var isDeleteConfirmationPresented = false
    @State private var errorMessage: String?
    @State private var localWaveDynamics: JournalWaveDynamicsSnapshot?

    private var context: JournalEventContext {
        entry.context
    }

    private var photos: [JournalMediaItem] {
        entry.mediaItems.filter(\.type.isImage)
    }

    private var videos: [JournalMediaItem] {
        entry.mediaItems.filter { $0.type == .video }
    }

    private var audio: [JournalMediaItem] {
        entry.mediaItems.filter { $0.type == .audio }
    }

    private var matchingTags: [JournalTag] {
        let saroses = Set(context.sarosNumbers)
        return tags.filter { saroses.contains($0.saros) }
    }

    private var moonReading: MoonPhaseOctalReading? {
        try? services.moonPhaseService.octalReading(for: entry.eventDate, depth: 3)
    }

    private var primeTag: JournalTag? {
        matchingTags.first(where: \.isPrime)
    }

    var body: some View {
        let displayedDirection = localWaveDynamics?.direction ?? context.direction
        let displayedMomentum = localWaveDynamics?.momentum ?? context.effectiveMomentum

        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 16) {
                        Text(JournalRecordMarkers.marker(from: entry.emoji))
                            .font(.system(size: 54))
                            .frame(width: 64, height: 64)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(context.displayTitleWithoutSaros)
                                .font(.headline)
                                .foregroundStyle(context.titleColor)
                            if context.rarity != .common {
                                FlipRarityBadge(rarity: context.rarity)
                            }
                        }

                        Spacer(minLength: 0)

                        VStack(spacing: 8) {
                            JournalClosestSarosPhaseGlyph(
                                context: context,
                                displayDepth: displayDepth,
                                size: 58
                            )
                            if let moonReading {
                                MoonPhaseGlyph(reading: moonReading)
                                    .frame(width: 40, height: 40)
                            }
                        }
                    }

                    JournalSpikeGlyphStrip(
                        spikes: context.spikes,
                        displayDepth: displayDepth,
                        size: 44,
                        highlightedSpikeID: context.closestSpike?.id
                    )

                    HStack(alignment: .bottom) {
                        Text(JournalFormatters.dateTime.string(from: entry.eventDate))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        JournalWaveDirectionIcon(direction: displayedDirection, size: 14)
                    }
                }
                .padding(.vertical, 4)
                .background {
                    if let primeTag {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: primeTag.tintHex, fallback: .white).opacity(0.08))
                    }
                }
            }

            if let text = entry.text, !text.isEmpty {
                Section("Text") {
                    Text(text)
                }
            }

            Section("Waveform") {
                JournalEntryWaveformView(context: context)
                    .frame(height: 190)
            }

            if !photos.isEmpty {
                Section("Images") {
                    JournalEntryImageCarousel(items: photos)
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
            }

            if !videos.isEmpty {
                Section("Videos") {
                    ForEach(videos) { item in
                        VideoPlayer(player: AVPlayer(url: MediaStorage.url(for: item)))
                            .frame(height: 260)
                    }
                }
            }

            if !audio.isEmpty {
                Section("Audio") {
                    ForEach(audio) { item in
                        Button {
                            audioPlayer.toggle(url: MediaStorage.url(for: item))
                        } label: {
                            Label(
                                audioPlayer.isPlaying(url: MediaStorage.url(for: item)) ? "Stop audio" : "Play audio",
                                systemImage: audioPlayer.isPlaying(url: MediaStorage.url(for: item)) ? "stop.circle.fill" : "play.circle.fill"
                            )
                        }
                    }
                }
            }

            if !matchingTags.isEmpty {
                Section("Tags") {
                    ForEach(matchingTags) { tag in
                        HStack {
                            Text(tag.displayEmoji)
                            Text(tag.displayName)
                            if tag.isPrime {
                                Circle()
                                    .fill(Color(hex: tag.tintHex, fallback: .white))
                                    .frame(width: 10, height: 10)
                            }
                            Spacer()
                            Text("Saros \(tag.saros)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            JournalEntrySpikesSection(
                spikes: context.spikes,
                highlightedSpikeID: context.closestSpike?.id,
                displayDepth: displayDepth
            )

            Section("Metadata") {
                MetadataRow(title: "Unix timestamp", value: "\(entry.unixTimestamp)")
                JournalDirectionMetadataRow(direction: displayedDirection)
                MetadataRow(title: "Momentum", value: Self.momentumPercentText(displayedMomentum))
                MetadataRow(title: "Energy", value: "\(Int((context.energyPercent * 100).rounded()))%")
                MetadataRow(title: "Extremum", value: context.extremum.title)
                MetadataRow(title: "Major period", value: context.majorPeriodSeconds.compactDuration)
                if let moonMetadataReading {
                    MetadataRow(title: "Moon glyph", value: moonMetadataReading.octalAddress)
                    ForEach(moonMetadataReading.components) { component in
                        MetadataRow(
                            title: "Moon \(component.kind.displayName.lowercased())",
                            value: component.detailOctalAddress
                        )
                        MetadataRow(
                            title: "\(component.kind.displayName) bin",
                            value: "\(component.digit)"
                        )
                        MetadataRow(
                            title: "\(component.kind.displayName) previous",
                            value: JournalFormatters.dateTime.string(from: component.cycleReading.previousEvent.date)
                        )
                        MetadataRow(
                            title: "\(component.kind.displayName) next",
                            value: JournalFormatters.dateTime.string(from: component.cycleReading.nextEvent.date)
                        )
                    }
                }
            }
        }
        .navigationTitle(context.displayTitleWithoutSaros)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete entry")
            }
        }
        .onDisappear {
            audioPlayer.stop()
        }
        .task(id: context.waveformCacheKey) {
            let context = context
            let contextService = services.sarosEventContextService
            let dynamics = await Task.detached(priority: .userInitiated) { () -> JournalWaveDynamicsSnapshot in
                let spikes = (
                    try? contextService.waveformSpikes(
                        around: context.eventDate,
                        harmonicDepth: context.waveformHarmonicDepth
                    )
                ) ?? context.spikes
                return JournalWaveMetricsCalculator.dynamics(
                    at: context.eventDate,
                    spikes: spikes
                )
            }.value
            localWaveDynamics = dynamics
        }
        .confirmationDialog("Delete this entry?", isPresented: $isDeleteConfirmationPresented, titleVisibility: .visible) {
            Button("Delete Record", role: .destructive) {
                deleteEntry()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Record error", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var displayDepth: Int {
        JournalSettings.clampedHarmonicDepth(harmonicDepth)
    }

    private var moonMetadataReading: MoonPhaseOctalReading? {
        try? services.moonPhaseService.octalReading(for: entry.eventDate, depth: 8)
    }

    private static func momentumPercentText(_ momentum: Double) -> String {
        let percent = Int((momentum * 100).rounded())
        if percent > 0 {
            return "+\(percent)%"
        }
        return "\(percent)%"
    }

    private func displayAddress(for spike: JournalSpikeReference) -> String {
        JournalSettings.displayOctalAddress(
            spike.octalAddress,
            storedDepth: spike.harmonicDepth,
            displayDepth: displayDepth
        )
    }

    private func deleteEntry() {
        audioPlayer.stop()
        let mediaItems = entry.mediaItems
        modelContext.delete(entry)
        do {
            try modelContext.save()
            mediaItems.forEach(MediaStorage.delete)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct JournalEntryCaptureView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let recordStartedAt: Date

    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var locationProvider = JournalEntryLocationProvider()
    @State private var noteText = ""
    @State private var emoji = JournalRecordMarkers.random()
    @State private var eventDate: Date
    @State private var mediaItems: [JournalMediaItem] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var context: JournalEventContext?
    @State private var isLoadingPhoto = false
    @State private var isCameraPresented = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(recordStartedAt: Date = Date(), template: JournalTemplateSeed = .random) {
        self.recordStartedAt = recordStartedAt
        _eventDate = State(initialValue: recordStartedAt)
        _noteText = State(initialValue: template.text)
        _emoji = State(initialValue: template.resolvedEmoji)
    }

    var body: some View {
        Form {
            Section("Record") {
                TextField("Emoji marker", text: $emoji)
                    .textContentType(.none)

                TextEditor(text: $noteText)
                    .font(.body)
                    .lineSpacing(4)
                    .frame(minHeight: 160, maxHeight: 280)
                    .scrollContentBackground(.hidden)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                if isLoadingPhoto {
                    HStack {
                        ProgressView()
                        Text("Loading photo")
                            .foregroundStyle(.secondary)
                    }
                }

                if !mediaItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Draft media")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(mediaItems) { item in
                            JournalDraftMediaRow(item: item) {
                                removeMedia(item)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack(spacing: 12) {
                    Button {
                        isCameraPresented = true
                    } label: {
                        JournalEntryActionIcon(systemName: "camera.viewfinder")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Capture photo")

                    PhotosPicker(selection: $photoItems, matching: .images) {
                        JournalEntryActionIcon(systemName: "photo.on.rectangle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add from library")
                    .onChange(of: photoItems) { _, newItems in
                        Task { await loadPhotos(from: newItems) }
                    }

                    Button {
                        do {
                            try audioRecorder.toggleRecording(mode: .reflected)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    } label: {
                        JournalEntryActionIcon(
                            systemName: audioRecorder.isRecording ? "stop.circle.fill" : "mic.circle.fill",
                            tint: audioRecorder.isRecording ? .red : .accentColor
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(audioRecorder.isRecording ? "Stop audio" : "Record audio")
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Section("Timing") {
                DatePicker("Record date", selection: $eventDate)
                    .datePickerStyle(.compact)

                Button {
                    eventDate = Date()
                    refreshContext()
                } label: {
                    Label("Now", systemImage: "clock.arrow.circlepath")
                }

                if let context {
                    JournalSpikeGlyphStrip(
                        spikes: context.spikes,
                        displayDepth: JournalSettings.canonicalHarmonicDepth,
                        size: 38
                    )
                    JournalEntryWaveformView(context: context)
                        .frame(height: 150)
                } else {
                    ContentUnavailableView("Saros context unavailable", systemImage: "waveform.path.ecg")
                }
            }

            Section {
                Button {
                    Task { await saveEntry() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Label("Save entry", systemImage: "tray.and.arrow.down")
                    }
                }
                .disabled(isSaving || isLoadingPhoto || context == nil)
            }
        }
        .navigationTitle("Record")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    dismiss()
                }
            }
        }
        .task {
            locationProvider.prepare()
            refreshContext()
        }
        .onChange(of: eventDate) { _, _ in
            refreshContext()
        }
        .onChange(of: audioRecorder.lastItem) { _, item in
            guard let item else { return }
            mediaItems.append(item)
            _ = audioRecorder.consumeLastItem()
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            MirrorCameraView { media in
                addCameraMedia(media)
            }
        }
        .alert("Record failed", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
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
                guard let pickedPhoto = try await item.loadTransferable(type: JournalPickedPhotoTransfer.self) else {
                    continue
                }
                let mediaItem = try MediaStorage.saveData(
                    pickedPhoto.data,
                    fileExtension: preferredFileExtension(for: item),
                    type: .photo
                )
                mediaItems.append(mediaItem)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func saveEntry() async {
        isSaving = true
        defer { isSaving = false }

        do {
            var savedMedia = mediaItems
            if let audioItem = audioRecorder.consumeLastItem() {
                savedMedia.append(audioItem)
                mediaItems = savedMedia
            }

            let resolvedContext = try services.sarosEventContextService.context(
                for: eventDate,
                harmonicDepth: JournalSettings.canonicalHarmonicDepth
            )
            let coordinate = locationProvider.coordinate
            let entry = JournalEntry(
                createdAt: recordStartedAt,
                updatedAt: Date(),
                eventDate: eventDate,
                text: noteText.nilIfBlank,
                emoji: emoji.nilIfBlank ?? JournalRecordMarkers.random(),
                mediaItems: savedMedia,
                context: resolvedContext,
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude
            )
            modelContext.insert(entry)
            try modelContext.save()
            dismiss()
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
    private func refreshContext() {
        do {
            context = try services.sarosEventContextService.context(
                for: eventDate,
                harmonicDepth: JournalSettings.canonicalHarmonicDepth
            )
        } catch {
            context = nil
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func addCameraMedia(_ media: MirrorCameraCapturedMedia) {
        do {
            let item = try JournalPendingMediaAttachment(media: media).save()
            mediaItems.append(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func removeMedia(_ item: JournalMediaItem) {
        mediaItems.removeAll { $0.id == item.id }
        MediaStorage.delete(item)
    }
}

struct JournalTemplatesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \JournalTemplate.createdAt, order: .forward) private var templates: [JournalTemplate]

    @State private var selectedTemplate: JournalTemplateSeed?
    @State private var draft: JournalTemplateDraft?

    var body: some View {
        List {
            Section {
                Button {
                    selectedTemplate = .random
                } label: {
                    JournalTemplateRow(
                        title: "Random",
                        emoji: JournalRecordMarkers.fallback,
                        text: "Random emoji, empty text"
                    )
                }
                .buttonStyle(.plain)

                ForEach(templates) { template in
                    Button {
                        selectedTemplate = JournalTemplateSeed(template: template)
                    } label: {
                        JournalTemplateRow(
                            title: template.displayName,
                            emoji: template.displayEmoji,
                            text: template.text.nilIfBlank ?? "Empty text"
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteTemplate(template)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            draft = JournalTemplateDraft(template: template)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .navigationTitle("Record")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    draft = JournalTemplateDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add template")
            }
        }
        .sheet(item: $selectedTemplate) { template in
            NavigationStack {
                JournalEntryCaptureView(recordStartedAt: Date(), template: template)
            }
        }
        .sheet(item: $draft) { draft in
            NavigationStack {
                JournalTemplateEditorView(draft: draft) { savedDraft in
                    saveTemplate(savedDraft)
                }
            }
        }
    }

    private func saveTemplate(_ draft: JournalTemplateDraft) {
        if let existing = templates.first(where: { $0.id == draft.id }) {
            existing.name = draft.name.nilIfBlank ?? "Template"
            existing.emoji = draft.emoji.nilIfBlank ?? JournalRecordMarkers.random()
            existing.text = draft.text
            existing.touch()
        } else {
            modelContext.insert(JournalTemplate(
                id: draft.id,
                name: draft.name.nilIfBlank ?? "Template",
                emoji: draft.emoji.nilIfBlank ?? JournalRecordMarkers.random(),
                text: draft.text
            ))
        }
        try? modelContext.save()
    }

    private func deleteTemplate(_ template: JournalTemplate) {
        modelContext.delete(template)
        try? modelContext.save()
    }
}

struct JournalTemplateSeed: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String?
    let text: String
    let usesRandomEmoji: Bool

    static var random: JournalTemplateSeed {
        JournalTemplateSeed(
            id: "random",
            name: "Random",
            emoji: nil,
            text: "",
            usesRandomEmoji: true
        )
    }

    init(template: JournalTemplate) {
        self.id = template.id.uuidString
        self.name = template.displayName
        self.emoji = template.emoji
        self.text = template.text
        self.usesRandomEmoji = false
    }

    private init(id: String, name: String, emoji: String?, text: String, usesRandomEmoji: Bool) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.text = text
        self.usesRandomEmoji = usesRandomEmoji
    }

    var resolvedEmoji: String {
        usesRandomEmoji ? JournalRecordMarkers.random() : (emoji?.nilIfBlank ?? JournalRecordMarkers.random())
    }
}

private struct JournalTemplateRow: View {
    let title: String
    let emoji: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text(emoji)
                .font(.system(size: 32))
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct JournalTemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State var draft: JournalTemplateDraft
    let onSave: (JournalTemplateDraft) -> Void

    var body: some View {
        Form {
            Section("Template") {
                TextField("Name", text: $draft.name)
                TextField("Emoji marker", text: $draft.emoji)
                TextEditor(text: $draft.text)
                    .frame(minHeight: 180)
            }
        }
        .navigationTitle("Template")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
            }
        }
    }
}

private struct JournalTemplateDraft: Identifiable {
    let id: UUID
    var name: String
    var emoji: String
    var text: String

    init(id: UUID = UUID(), name: String = "", emoji: String = JournalRecordMarkers.random(), text: String = "") {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.text = text
    }

    init(template: JournalTemplate) {
        self.id = template.id
        self.name = template.name
        self.emoji = template.emoji
        self.text = template.text
    }
}

struct TagsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \JournalTag.createdAt, order: .forward) private var tags: [JournalTag]
    @Query(sort: \JournalEntry.eventDate, order: .reverse) private var entries: [JournalEntry]

    @State private var draft: JournalTagDraft?

    var body: some View {
        List {
            if tags.isEmpty {
                ContentUnavailableView("No tags yet", systemImage: "tag")
            } else {
                ForEach(tags) { tag in
                    NavigationLink {
                        JournalTagEntriesView(tag: tag, entries: entries, tags: tags)
                    } label: {
                        HStack(spacing: 12) {
                            Text(tag.displayEmoji)
                                .font(.system(size: 32))
                                .frame(width: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 7) {
                                    Text(tag.displayName)
                                        .font(.headline)
                                    if tag.isPrime {
                                        Circle()
                                            .fill(Color(hex: tag.tintHex, fallback: .white))
                                            .frame(width: 10, height: 10)
                                    }
                                }
                                Text("Saros \(tag.saros)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(entryCount(for: tag))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.thinMaterial, in: Capsule())
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteTag(tag)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            draft = JournalTagDraft(tag: tag)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                .onDelete(perform: deleteTags)
            }
        }
        .navigationTitle("Tags")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    draft = JournalTagDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add tag")
            }
        }
        .sheet(item: $draft) { draft in
            NavigationStack {
                JournalTagEditorView(draft: draft) { savedDraft in
                    saveTag(savedDraft)
                }
            }
        }
    }

    private func entryCount(for tag: JournalTag) -> Int {
        entries.filter { $0.context.sarosNumbers.contains(tag.saros) }.count
    }

    private func saveTag(_ draft: JournalTagDraft) {
        if let existing = tags.first(where: { $0.id == draft.id }) {
            existing.name = draft.name.nilIfBlank ?? "Saros \(draft.saros)"
            existing.emoji = draft.emoji.nilIfBlank ?? "◇"
            existing.anchorDate = draft.anchorDate
            existing.saros = draft.saros
            existing.notes = draft.notes.nilIfBlank
            existing.isPrime = draft.isPrime
            existing.colorHex = draft.colorHex
            existing.touch()
        } else {
            modelContext.insert(JournalTag(
                id: draft.id,
                name: draft.name.nilIfBlank ?? "Saros \(draft.saros)",
                emoji: draft.emoji.nilIfBlank ?? "◇",
                anchorDate: draft.anchorDate,
                saros: draft.saros,
                notes: draft.notes.nilIfBlank,
                isPrime: draft.isPrime,
                colorHex: draft.colorHex
            ))
        }
        try? modelContext.save()
    }

    private func deleteTags(at offsets: IndexSet) {
        for offset in offsets {
            deleteTag(tags[offset], save: false)
        }
        try? modelContext.save()
    }

    private func deleteTag(_ tag: JournalTag, save: Bool = true) {
        modelContext.delete(tag)
        if save {
            try? modelContext.save()
        }
    }
}

private struct JournalTagEntriesView: View {
    @EnvironmentObject private var services: AppServices

    let tag: JournalTag
    let entries: [JournalEntry]
    let tags: [JournalTag]

    @State private var selectedEntry: JournalEntry?
    @State private var isFilterPresented = false
    @State private var selectedRarity: FlipRarity?
    @State private var selectedDirection: JournalWaveDirection?
    @State private var selectedExtremum: JournalWaveExtremum?
    @State private var dateFilterMode: JournalRecordDateFilterMode = .all
    @State private var selectedDate = Date()
    @State private var selectedSynodicBin: Int?
    @State private var selectedAnomalisticBin: Int?
    @State private var selectedDraconicBin: Int?
    @State private var spikesOnly = false

    private var matchingEntries: [JournalEntry] {
        entries.filter { entry in
            let context = entry.context
            let closestRarity = context.closestSpike?.rarity.baseRarity ?? .common
            let matchesTag = context.sarosNumbers.contains(tag.saros)
            let matchesRarity = selectedRarity.map { closestRarity == $0.baseRarity } ?? true
            let matchesDirection = selectedDirection.map { context.direction == $0 } ?? true
            let matchesExtremum = selectedExtremum.map { context.extremum == $0 } ?? true
            let matchesMoon = matchesMoonFilters(entry.eventDate)
            let matchesSpikesOnly = !spikesOnly || context.closestSpike?.saros == tag.saros
            let matchesDate = switch dateFilterMode {
            case .all:
                true
            case .day:
                Calendar.current.isDate(entry.eventDate, inSameDayAs: selectedDate)
            }
            return matchesTag && matchesRarity && matchesDirection && matchesExtremum && matchesMoon && matchesSpikesOnly && matchesDate
        }
    }

    private var hasActiveFilters: Bool {
        selectedRarity != nil
            || selectedDirection != nil
            || selectedExtremum != nil
            || selectedSynodicBin != nil
            || selectedAnomalisticBin != nil
            || selectedDraconicBin != nil
            || spikesOnly
            || dateFilterMode != .all
    }

    var body: some View {
        List {
            if matchingEntries.isEmpty {
                ContentUnavailableView("No records", systemImage: "rectangle.stack")
            } else {
                ForEach(matchingEntries) { entry in
                    Button {
                        selectedEntry = entry
                    } label: {
                        JournalEntryRow(entry: entry, tags: tags)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("\(tag.displayEmoji) \(tag.displayName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isFilterPresented = true
                } label: {
                    Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter records")
            }
        }
        .sheet(isPresented: $isFilterPresented) {
            NavigationStack {
                JournalScopedRecordFilterView(
                    selectedRarity: $selectedRarity,
                    selectedDirection: $selectedDirection,
                    selectedExtremum: $selectedExtremum,
                    dateFilterMode: $dateFilterMode,
                    selectedDate: $selectedDate,
                    selectedSynodicBin: $selectedSynodicBin,
                    selectedAnomalisticBin: $selectedAnomalisticBin,
                    selectedDraconicBin: $selectedDraconicBin,
                    spikesOnly: $spikesOnly
                )
            }
        }
        .navigationDestination(item: $selectedEntry) { entry in
            JournalEntryDetailView(entry: entry, tags: tags)
        }
    }

    private func matchesMoonFilters(_ date: Date) -> Bool {
        guard selectedSynodicBin != nil || selectedAnomalisticBin != nil || selectedDraconicBin != nil else {
            return true
        }
        guard let reading = try? services.moonPhaseService.octalReading(for: date, depth: 3) else {
            return false
        }
        return matchesMoonBin(selectedSynodicBin, kind: .synodic, reading: reading)
            && matchesMoonBin(selectedAnomalisticBin, kind: .anomalistic, reading: reading)
            && matchesMoonBin(selectedDraconicBin, kind: .draconic, reading: reading)
    }

    private func matchesMoonBin(_ bin: Int?, kind: MoonCycleKind, reading: MoonPhaseOctalReading) -> Bool {
        guard let bin else { return true }
        return reading.component(kind)?.digit == bin
    }
}

private struct JournalTagEditorView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State var draft: JournalTagDraft
    let onSave: (JournalTagDraft) -> Void

    @State private var derivationError: String?

    var body: some View {
        Form {
            Section("Tag") {
                TextField("Name", text: $draft.name)
                TextField("Emoji", text: $draft.emoji)
                DatePicker("Anchor date", selection: $draft.anchorDate)
                Toggle("Prime", isOn: $draft.isPrime)
                ColorPicker("Tint", selection: Binding(
                    get: { Color(hex: draft.colorHex, fallback: .white) },
                    set: { draft.colorHex = $0.hexRGBString }
                ))
                HStack {
                    Text("Saros")
                    Spacer()
                    Text("\(draft.saros)")
                        .foregroundStyle(.secondary)
                }
                Button {
                    deriveSaros()
                } label: {
                    Label("Derive from date", systemImage: "sparkle.magnifyingglass")
                }
                if let derivationError {
                    Text(derivationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Notes") {
                TextEditor(text: $draft.notes)
                    .frame(minHeight: 110)
            }
        }
        .navigationTitle("Tag")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
            }
        }
        .task {
            if draft.saros == 0 {
                deriveSaros()
            }
        }
        .onChange(of: draft.anchorDate) { _, _ in
            deriveSaros()
        }
    }

    private func deriveSaros() {
        do {
            let eclipse = try services.sarosEventContextService.closestEclipse(to: draft.anchorDate)
            draft.saros = eclipse.saros
            derivationError = nil
        } catch {
            derivationError = error.localizedDescription
        }
    }
}

private struct JournalTagDraft: Identifiable {
    let id: UUID
    var name: String
    var emoji: String
    var anchorDate: Date
    var saros: Int
    var notes: String
    var isPrime: Bool
    var colorHex: String

    init(
        id: UUID = UUID(),
        name: String = "",
        emoji: String = "◇",
        anchorDate: Date = Date(),
        saros: Int = 0,
        notes: String = "",
        isPrime: Bool = false,
        colorHex: String = "#FFFFFF"
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.anchorDate = anchorDate
        self.saros = saros
        self.notes = notes
        self.isPrime = isPrime
        self.colorHex = colorHex
    }

    init(tag: JournalTag) {
        self.id = tag.id
        self.name = tag.name
        self.emoji = tag.emoji
        self.anchorDate = tag.anchorDate
        self.saros = tag.saros
        self.notes = tag.notes ?? ""
        self.isPrime = tag.isPrime
        self.colorHex = tag.tintHex
    }
}

private struct JournalClosestSarosPhaseGlyph: View {
    @EnvironmentObject private var services: AppServices

    let context: JournalEventContext
    let displayDepth: Int
    let size: CGFloat

    @State private var phase: JournalSarosPhaseReference?

    var body: some View {
        ZStack {
            if let phase {
                OctalGlyph(
                    value: displayAddress(for: phase),
                    depth: displayDepth,
                    style: phase.rarity.glyphStyle
                )
                .frame(width: size, height: size)
                .accessibilityLabel("Saros \(phase.saros) current phase")
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: phaseTaskID) {
            let context = context
            let displayDepth = displayDepth
            let contextService = services.sarosEventContextService
            phase = await Task.detached(priority: .utility) { () -> JournalSarosPhaseReference? in
                try? contextService.closestSarosPhase(
                    for: context,
                    harmonicDepth: displayDepth
                )
            }.value
        }
    }

    private var phaseTaskID: String {
        "\(context.unixTimestamp)-\(displayDepth)-\(context.closestSpike?.id ?? "none")"
    }

    private func displayAddress(for phase: JournalSarosPhaseReference) -> String {
        JournalSettings.displayOctalAddress(
            phase.octalAddress,
            storedDepth: phase.harmonicDepth,
            displayDepth: displayDepth
        )
    }

}

private struct JournalSpikeGlyphStrip: View {
    let spikes: [JournalSpikeReference]
    let displayDepth: Int
    let size: CGFloat
    var highlightedSpikeID: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            ForEach(spikes) { spike in
                VStack(spacing: 3) {
                    OctalGlyph(
                        value: displayAddress(for: spike),
                        depth: displayDepth,
                        style: spike.rarity.glyphStyle
                    )
                    .frame(width: size, height: size)
                    .padding(size * 0.10)
                    .background(
                        spike.id == highlightedSpikeID ? spike.rarity.color.opacity(0.18) : .clear,
                        in: Circle()
                    )
                    .overlay {
                        if spike.id == highlightedSpikeID {
                            Circle()
                                .stroke(spike.rarity.color.opacity(0.52), lineWidth: 1)
                        }
                    }
                    Text("\(spike.saros)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(spike.id == highlightedSpikeID ? spike.rarity.color : .secondary)
                }
                .frame(minWidth: size + 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func displayAddress(for spike: JournalSpikeReference) -> String {
        JournalSettings.displayOctalAddress(
            spike.octalAddress,
            storedDepth: spike.harmonicDepth,
            displayDepth: displayDepth
        )
    }
}

private struct JournalEntrySpikesSection: View {
    let spikes: [JournalSpikeReference]
    let highlightedSpikeID: String?
    let displayDepth: Int

    var body: some View {
        Section("Spikes") {
            ForEach(spikes, id: \.id) { spike in
                JournalEntrySpikeRow(
                    spike: spike,
                    displayDepth: displayDepth,
                    isHighlighted: spike.id == highlightedSpikeID
                )
            }
        }
    }
}

private struct JournalEntrySpikeRow: View {
    let spike: JournalSpikeReference
    let displayDepth: Int
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            OctalGlyph(
                value: displayAddress,
                depth: displayDepth,
                style: spike.rarity.glyphStyle
            )
            .frame(width: 32, height: 32)
            .padding(5)
            .background(
                isHighlighted ? spike.rarity.color.opacity(0.16) : .clear,
                in: Circle()
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Saros \(spike.saros)")
                    .font(.subheadline.weight(.semibold))
                Text(JournalFormatters.dateTime.string(from: spike.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if spike.rarity != .common {
                FlipRarityBadge(rarity: spike.rarity, compact: true)
            }
        }
    }

    private var displayAddress: String {
        JournalSettings.displayOctalAddress(
            spike.octalAddress,
            storedDepth: spike.harmonicDepth,
            displayDepth: displayDepth
        )
    }
}

private struct JournalEntryWaveformView: View {
    @EnvironmentObject private var services: AppServices

    let context: JournalEventContext

    @State private var plot = JournalEntryWaveformPlot.empty

    var body: some View {
        Canvas { graphics, size in
            let rect = CGRect(origin: .zero, size: size)
            let background = RoundedRectangle(cornerRadius: 8).path(in: rect)
            graphics.fill(background, with: .color(Color(.secondarySystemBackground)))
            graphics.stroke(background, with: .color(.secondary.opacity(0.2)), lineWidth: 1)

            let interval = plot.interval
            let samples = plot.samples
            guard !samples.isEmpty else { return }

            let maxEnergy = plot.maxEnergy
            let insets = EdgeInsets(top: 14, leading: 14, bottom: 24, trailing: 14)
            let width = max(size.width - insets.leading - insets.trailing, 1)
            let height = max(size.height - insets.top - insets.bottom, 1)

            var path = Path()
            for sample in samples {
                let x = insets.leading + CGFloat(sample.date.timeIntervalSince(interval.start) / interval.duration) * width
                let y = insets.top + (1 - CGFloat(sample.energy / maxEnergy)) * height
                if sample == samples.first {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            graphics.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.6)

            var placedDots: [CGPoint] = []
            for spike in plot.visibleSpikes {
                let baseX = insets.leading + CGFloat(spike.date.timeIntervalSince(interval.start) / interval.duration) * width
                var x = baseX
                let spikeEnergy = plot.energyBySpikeID[spike.id] ?? 0
                let dotSize = JournalEntryWaveform.dotSize(for: spike.rarity)
                let baseY = insets.top + (1 - CGFloat(spikeEnergy / maxEnergy)) * height
                var dotY = baseY
                var collisionLevel = 0
                let dotStep = dotSize + 5
                let maxUpLevels = max(Int((baseY - insets.top - dotSize / 2) / dotStep), 0)

                while placedDots.contains(where: { abs($0.x - x) < dotSize + 4 && abs($0.y - dotY) < dotSize + 4 }),
                      collisionLevel < 24
                {
                    collisionLevel += 1
                    let upLevel = min(collisionLevel, maxUpLevels)
                    let overflowLevel = max(collisionLevel - maxUpLevels, 0)
                    dotY = max(insets.top + dotSize / 2, baseY - CGFloat(upLevel) * dotStep)
                    x = min(
                        size.width - insets.trailing - dotSize / 2,
                        baseX + CGFloat(overflowLevel) * (dotSize + 5)
                    )
                }
                placedDots.append(CGPoint(x: x, y: dotY))

                var line = Path()
                line.move(to: CGPoint(x: x, y: insets.top))
                line.addLine(to: CGPoint(x: x, y: size.height - insets.bottom))
                graphics.stroke(line, with: .color(spike.rarity.color.opacity(0.42)), lineWidth: 1)
                let dotRect = CGRect(
                    x: x - dotSize / 2,
                    y: dotY - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )
                let dot = Path(ellipseIn: dotRect)
                graphics.fill(dot, with: .color(spike.rarity.color))
                graphics.stroke(dot, with: .color(.black.opacity(0.38)), lineWidth: 0.8)
            }

            let eventX = insets.leading + CGFloat(context.eventDate.timeIntervalSince(interval.start) / interval.duration) * width
            let eventY = insets.top + (1 - CGFloat(plot.eventEnergy / maxEnergy)) * height
            var marker = Path()
            marker.move(to: CGPoint(x: eventX, y: insets.top))
            marker.addLine(to: CGPoint(x: eventX, y: size.height - insets.bottom))
            graphics.stroke(marker, with: .color(.green.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            graphics.fill(Path(ellipseIn: CGRect(x: eventX - 4, y: eventY - 4, width: 8, height: 8)), with: .color(.green))
        }
        .accessibilityLabel("Journal waveform")
        .task(id: context.waveformCacheKey) {
            let context = context
            let contextService = services.sarosEventContextService
            let generated = await Task.detached(priority: .userInitiated) { () -> JournalEntryWaveformPlot in
                let spikes = (
                    try? contextService.waveformSpikes(
                        around: context.eventDate,
                        harmonicDepth: context.waveformHarmonicDepth
                    )
                ) ?? context.spikes
                return JournalEntryWaveformPlot.make(for: context, spikes: spikes)
            }.value
            plot = generated
        }
    }
}

private struct JournalEntryWaveformPlot {
    let interval: DateInterval
    let samples: [JournalEventWaveSample]
    let visibleSpikes: [JournalSpikeReference]
    let energyBySpikeID: [String: Double]
    let eventEnergy: Double
    let maxEnergy: Double

    static let empty = JournalEntryWaveformPlot(
        interval: DateInterval(start: Date(), duration: 86_400),
        samples: [],
        visibleSpikes: [],
        energyBySpikeID: [:],
        eventEnergy: 0,
        maxEnergy: 1
    )

    static func make(
        for context: JournalEventContext,
        spikes: [JournalSpikeReference]
    ) -> JournalEntryWaveformPlot {
        let interval = JournalEventWaveform.displayInterval(centeredOn: context.eventDate)
        let sortedSpikes = spikes.sorted { $0.date < $1.date }
        let field = JournalEventWaveform.field(spikes: sortedSpikes)
        let waveSamples = field.samples(
            in: interval,
            sampleCount: 1_024,
            spikes: sortedSpikes
        )
        let visibleSpikes = JournalEventWaveform.visibleSpikes(
            in: interval,
            spikes: sortedSpikes
        )
        let eventEnergy = field.energy(at: context.eventDate)
        let localMaxEnergy = waveSamples.points.map(\.energy).max() ?? eventEnergy
        let visibleSpikeMaxEnergy = visibleSpikes
            .compactMap { waveSamples.eventEnergyByID[$0.id] }
            .max() ?? 0
        let maxEnergy = max(localMaxEnergy, visibleSpikeMaxEnergy, eventEnergy, 0.000_001)
        return JournalEntryWaveformPlot(
            interval: interval,
            samples: waveSamples.points,
            visibleSpikes: visibleSpikes,
            energyBySpikeID: waveSamples.eventEnergyByID,
            eventEnergy: eventEnergy,
            maxEnergy: maxEnergy
        )
    }
}

private extension JournalEventContext {
    var waveformHarmonicDepth: Int {
        spikes.map(\.harmonicDepth).max() ?? JournalSettings.supportedHarmonicDepth.upperBound
    }
}

private struct JournalWaveDirectionIcon: View {
    let direction: JournalWaveDirection
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .frame(width: size + 4, height: size + 4)
            .accessibilityLabel(direction.title)
    }

    private var symbolName: String {
        switch direction {
        case .ascending:
            "arrow.up"
        case .descending:
            "arrow.down"
        case .flat:
            "minus"
        }
    }

    private var color: Color {
        switch direction {
        case .ascending:
            .green
        case .descending:
            .red
        case .flat:
            .white
        }
    }
}

private struct JournalDirectionMetadataRow: View {
    let direction: JournalWaveDirection

    var body: some View {
        HStack(alignment: .center) {
            Text("Direction")
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            JournalWaveDirectionIcon(direction: direction, size: 18)
        }
        .font(.subheadline)
    }
}

private enum JournalEntryWaveform {
    static func dotSize(for rarity: FlipRarity) -> CGFloat {
        switch rarity.baseRarity {
        case .mythic: 9
        case .legendary: 7.5
        case .epic: 6.5
        default: 6
        }
    }
}

struct SarosGlyphGridPicker: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    @Binding var selectedSaros: Int?
    var primeColorsBySaros: [Int: Color] = [:]

    @State private var items: [SarosGlyphGridPickerItem] = []
    @State private var errorMessage: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
    private static let columnCount = 5
    private static let cellHeight: CGFloat = 58
    private static let gridSpacing: CGFloat = 6

    private var preferredHeight: CGFloat {
        if errorMessage != nil { return 120 }
        if items.isEmpty { return 42 }
        let itemCount = min(items.count, 40)
        let rows = Int(ceil(Double(itemCount) / Double(Self.columnCount)))
        return CGFloat(rows) * Self.cellHeight + CGFloat(max(rows - 1, 0)) * Self.gridSpacing + 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage {
                ContentUnavailableView(errorMessage, systemImage: "circle.grid.3x3")
            } else if items.isEmpty {
                HStack {
                    ProgressView()
                    Text("Loading Saros")
                        .foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(items.prefix(40))) { item in
                        Button {
                            selectedSaros = selectedSaros == item.saros ? nil : item.saros
                        } label: {
                            SarosGlyphGridPickerCell(
                                item: item,
                                isSelected: selectedSaros == item.saros,
                                tint: primeColorsBySaros[item.saros]
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: preferredHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: harmonicDepth) {
            await loadItems()
        }
    }

    @MainActor
    private func loadItems() async {
        let date = Date()
        let depth = JournalSettings.clampedHarmonicDepth(harmonicDepth)
        let eclipseService = services.eclipseService

        let result = await Task.detached(priority: .userInitiated) {
            Result<[SarosGlyphGridPickerItem], Error> {
                try eclipseService.allSarosSeries()
                    .filter { $0.firstEclipseDate < date && $0.lastEclipseDate > date }
                    .compactMap { summary -> SarosGlyphGridPickerItem? in
                        guard let interval = try? eclipseService.previousAndNextEclipse(
                            saros: summary.saros,
                            around: date
                        ),
                              let reading = try? SarosClockCalculator.reading(
                                saros: summary.saros,
                                previous: interval.previous,
                                next: interval.next,
                                now: date,
                                harmonicDepth: depth
                              )
                        else {
                            return nil
                        }
                        return SarosGlyphGridPickerItem(
                            saros: summary.saros,
                            octalAddress: reading.octalAddress,
                            harmonicDepth: reading.harmonicDepth,
                            rarity: reading.currentRarity
                        )
                    }
                    .sorted { $0.saros < $1.saros }
            }
        }.value

        switch result {
        case .success(let loaded):
            items = loaded
            errorMessage = nil
        case .failure(let error):
            items = []
            errorMessage = error.localizedDescription
        }
    }
}

private struct SarosGlyphGridPickerItem: Identifiable, Hashable {
    let saros: Int
    let octalAddress: String
    let harmonicDepth: Int
    let rarity: FlipRarity

    var id: Int { saros }
}

private struct SarosGlyphGridPickerCell: View {
    let item: SarosGlyphGridPickerItem
    let isSelected: Bool
    let tint: Color?

    private var color: Color {
        if isSelected {
            return tint ?? .accentColor
        }
        return tint ?? (item.rarity == .common ? .white : item.rarity.color)
    }

    var body: some View {
        VStack(spacing: 4) {
            OctalGlyph(value: item.octalAddress, depth: item.harmonicDepth, color: color)
                .frame(width: 28, height: 28)
                .padding(6)
                .background(.black.opacity(isSelected ? 0.42 : 0.18), in: Circle())
                .overlay {
                    Circle()
                        .stroke(color.opacity(isSelected ? 0.82 : 0.28), lineWidth: isSelected ? 2 : 1)
                }
            Text("\(item.saros)")
                .font(.caption2.monospacedDigit().weight(isSelected ? .bold : .semibold))
                .foregroundStyle(color.opacity(isSelected ? 1 : 0.72))
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Saros \(item.saros)")
    }
}

private extension JournalEventContext {
    var waveformCacheKey: String {
        "\(unixTimestamp)-\(spikes.map(\.id).joined(separator: "|"))"
    }

    var displayTitleWithoutSaros: String {
        if rarity == .common {
            return "Common"
        }
        return rarity.title
    }

    var titleColor: Color {
        rarity == .common ? .primary : rarity.color
    }

    var momentumPercentText: String {
        let percent = Int((effectiveMomentum * 100).rounded())
        if percent > 0 {
            return "+\(percent)%"
        }
        return "\(percent)%"
    }
}

private struct JournalEntryMediaStrip: View {
    let items: [JournalMediaItem]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.prefix(4)) { item in
                if item.type.isImage {
                    JournalAsyncMediaImage(item: item, contentMode: .fill)
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: systemImage(for: item.type))
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 42, height: 42)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

private struct JournalEntryImageCarousel: View {
    let items: [JournalMediaItem]

    var body: some View {
        TabView {
            ForEach(items) { item in
                JournalAsyncMediaImage(item: item, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .tabViewStyle(.page)
    }
}

private struct JournalAsyncMediaImage: View {
    let item: JournalMediaItem
    let contentMode: ContentMode

    @State private var image: UIImage?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if didLoad {
                ContentUnavailableView("Image unavailable", systemImage: "photo")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.id) {
            guard item.type.isImage else {
                didLoad = true
                return
            }

            let url = MediaStorage.url(for: item)
            let loaded = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)
            }.value
            image = loaded
            didLoad = true
        }
    }
}

private struct JournalDraftMediaRow: View {
    let item: JournalMediaItem
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if item.type.isImage {
                JournalAsyncMediaImage(item: item, contentMode: .fill)
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: systemImage(for: item.type))
                    .font(.title2)
                    .frame(width: 58, height: 58)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(for: item.type))
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

    private var sizeDescription: String {
        let url = MediaStorage.url(for: item)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return "Saved"
    }
}

private struct JournalEntryActionIcon: View {
    let systemName: String
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: systemName)
            .font(.title2.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 64, height: 64)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(tint.opacity(0.28), lineWidth: 1)
            }
    }
}

private final class JournalEntryLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
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

private struct JournalPendingMediaAttachment {
    let data: Data?
    let sourceURL: URL?
    let fileExtension: String
    let type: MediaType

    init(media: MirrorCameraCapturedMedia) {
        self.data = media.data
        self.sourceURL = media.sourceURL
        self.fileExtension = media.fileExtension
        self.type = media.type
    }

    func save() throws -> JournalMediaItem {
        if let data {
            return try MediaStorage.saveData(data, fileExtension: fileExtension, type: type)
        }
        if let sourceURL {
            return try MediaStorage.saveFile(at: sourceURL, fileExtension: fileExtension, type: type)
        }
        throw JournalEntryCaptureError.missingMedia
    }
}

private final class JournalEntryAudioPlayer: ObservableObject {
    private var player: AVAudioPlayer?
    private var currentURL: URL?

    func toggle(url: URL) {
        if isPlaying(url: url) {
            stop()
            return
        }

        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            self.player = player
            currentURL = url
            player.play()
            objectWillChange.send()
        } catch {
            stop()
        }
    }

    func isPlaying(url: URL) -> Bool {
        currentURL == url && (player?.isPlaying ?? false)
    }

    func stop() {
        player?.stop()
        player = nil
        currentURL = nil
        objectWillChange.send()
    }
}

private struct JournalPickedPhotoTransfer: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            JournalPickedPhotoTransfer(data: data)
        }
    }
}

private enum JournalEntryCaptureError: LocalizedError {
    case missingMedia

    var errorDescription: String? {
        "The captured media could not be found."
    }
}

private func systemImage(for type: MediaType) -> String {
    switch type {
    case .photo, .symbolicPhoto:
        "photo"
    case .video:
        "video"
    case .audio:
        "waveform"
    }
}

private func displayName(for type: MediaType) -> String {
    switch type {
    case .photo, .symbolicPhoto:
        "Camera capture"
    case .video:
        "Video capture"
    case .audio:
        "Audio"
    }
}

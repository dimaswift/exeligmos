import AVFoundation
import AVKit
import CoreLocation
import CoreTransferable
import ImageIO
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
        let tagIDs = Set(entry.tagIDs)
        return tags.filter { tagIDs.contains($0.compactID) }
    }

    private var primeTag: JournalTag? {
        matchingTags.first(where: \.isPrime)
    }

    private var moonReading: MoonPhaseOctalReading? {
        try? services.moonPhaseService.octalReading(for: entry.eventDate, depth: 3)
    }

    private var remoteDeviceEmoji: String? {
        guard entry.sourceDeviceID != JournalDevice.current().id else { return nil }
        return entry.sourceDeviceEmoji?.nilIfBlank
    }

    private var secondaryDisplayLabel: String {
        entry.isOngoing() ? "\(context.secondaryEventLabel) (in progress)" : context.secondaryEventLabel
    }

    var body: some View {
        let primeTint = primeTag.map { Color(hex: $0.tintHex, fallback: .white) }

        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                Text(JournalRecordMarkers.marker(from: entry.emoji))
                    .font(.system(size: 38))
                    .frame(width: 44, height: 44, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    Text(primaryTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(context.titleColor)
                        .lineLimit(1)
                    Text(secondaryDisplayLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if entry.isPeriodEntry {
                        Text(SarosDurationUnitFormatter.verboseDuration(entry.eventDuration, maxUnits: 2))
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                HStack(alignment: .center, spacing: 6) {
                    JournalClosestSarosPhaseGlyph(
                        context: context,
                        displayDepth: displayDepth,
                        size: 46
                    )
                    JournalPulseGlyphForDate(date: entry.eventDate, size: 38)
                    if let moonReading {
                        MoonPhaseGlyph(reading: moonReading)
                            .frame(width: 36, height: 36)
                    }
                }
            }

            JournalSpikeGlyphStrip(
                spikes: context.spikes,
                displayDepth: displayDepth,
                size: 32,
                highlightedSpikeID: context.closestSpike?.id
            )

            if let text = entry.text, !text.isEmpty {
                Text(text)
                    .lineLimit(3)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                if let remoteDeviceEmoji {
                    Text(remoteDeviceEmoji)
                        .font(.caption)
                }
                Spacer(minLength: 8)
                JournalWaveEventIcon(signature: context.waveSignature, size: 15)
            }
        }
        .padding(.vertical, 4)
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
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""
    @AppStorage(JournalSettings.pulseSarosKey) private var pulseSaros = 0
    @Query(sort: \SyncLocalCommand.createdAt, order: .forward) private var syncCommands: [SyncLocalCommand]

    let entry: JournalEntry
    let tags: [JournalTag]

    @StateObject private var audioPlayer = JournalEntryAudioPlayer()
    @State private var isDeleteConfirmationPresented = false
    @State private var isEditingEntry = false
    @State private var errorMessage: String?

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
        let tagIDs = Set(entry.tagIDs)
        return tags.filter { tagIDs.contains($0.compactID) }
    }

    private var moonReading: MoonPhaseOctalReading? {
        try? services.moonPhaseService.octalReading(for: entry.eventDate, depth: 3)
    }

    private var primeTag: JournalTag? {
        matchingTags.first(where: \.isPrime)
    }

    private var remoteDeviceEmoji: String? {
        guard entry.sourceDeviceID != JournalDevice.current().id else { return nil }
        return entry.sourceDeviceEmoji?.nilIfBlank
    }

    private var secondaryDisplayLabel: String {
        entry.isOngoing() ? "\(context.secondaryEventLabel) (in progress)" : context.secondaryEventLabel
    }

    var body: some View {
        let waveSignature = context.waveSignature

        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(JournalRecordMarkers.marker(from: entry.emoji))
                            .font(.system(size: 30))
                            .frame(width: 36, height: 36)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(context.displayTitleWithoutSaros)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(context.titleColor)
                                .lineLimit(2)
                                .minimumScaleFactor(0.82)
                            Text(secondaryDisplayLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            if entry.isPeriodEntry {
                                Text(SarosDurationUnitFormatter.verboseDuration(entry.eventDuration, maxUnits: 2))
                                    .font(.caption2.monospacedDigit().weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Spacer(minLength: 0)

                        HStack(alignment: .center, spacing: 6) {
                            JournalClosestSarosPhaseGlyph(
                                context: context,
                                displayDepth: displayDepth,
                                size: 34
                            )
                            if let pulseReading {
                                SarosPulseGlyph(reading: pulseReading, size: 30)
                            }
                            if let moonReading {
                                MoonPhaseGlyph(reading: moonReading)
                                    .frame(width: 30, height: 30)
                            }
                            if let remoteDeviceEmoji {
                                Text(remoteDeviceEmoji)
                                    .font(.caption)
                            }
                        }
                    }

                    JournalSpikeGlyphStrip(
                        spikes: context.spikes,
                        displayDepth: displayDepth,
                        size: 24,
                        highlightedSpikeID: context.closestSpike?.id
                    )

                    HStack(alignment: .center, spacing: 8) {
                        Text(JournalFormatters.dateTime.string(from: entry.eventDate))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                        Spacer(minLength: 0)
                        JournalWaveEventIcon(signature: waveSignature, size: 13)
                    }
                }
                .padding(.vertical, 0)
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
                        let url = MediaStorage.url(for: item)
                        VideoPlayer(player: AVPlayer(url: url))
                            .frame(height: 260)
                            .contextMenu {
                                ShareLink(item: url) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
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

            if entry.weatherCode != nil || entry.temperatureC != nil {
                Section("Weather") {
                    HStack {
                        Text(entry.weatherEmoji ?? JournalWeatherCatalog.emoji(for: entry.weatherCode) ?? "🌡️")
                            .font(.largeTitle)
                        VStack(alignment: .leading) {
                            if let option = JournalWeatherCatalog.option(for: entry.weatherCode) {
                                Text(option.title)
                            }
                            if let temperatureC = entry.temperatureC {
                                Text("\(temperatureC)°C")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                JournalEntryWaveformView(context: context, endDate: entry.effectiveEndDate)
                    .frame(height: 190)
            } header: {
                Text("Waveform")
                    .textCase(nil)
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
                MetadataRow(title: "Sync", value: syncStatusTitle)
                MetadataRow(title: "Version", value: "\(entry.version)")
                MetadataRow(title: "Unix timestamp", value: "\(entry.unixTimestamp)")
                JournalWaveEventMetadataRow(signature: waveSignature)
                MetadataRow(title: "Momentum", value: waveSignature.momentumText)
                MetadataRow(title: "Energy", value: waveSignature.energyText)
                MetadataRow(
                    title: "\(context.eventDescriptor.segmentKind == .descent ? "Descent" : "Ascent") period",
                    value: SarosDurationUnitFormatter.verboseDuration(context.eventDescriptor.segmentDuration)
                )
                if entry.isPeriodEntry {
                    MetadataRow(title: "End", value: JournalFormatters.dateTime.string(from: entry.effectiveEndDate))
                    MetadataRow(
                        title: "Duration",
                        value: SarosDurationUnitFormatter.verboseDuration(entry.eventDuration)
                    )
                }
                if let pulseReading {
                    HStack {
                        Text("Pulse")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        SarosPulseGlyph(reading: pulseReading, size: 36)
                    }
                }
                if let sourceDeviceEmoji = entry.sourceDeviceEmoji?.nilIfBlank {
                    MetadataRow(title: "Device", value: sourceDeviceEmoji)
                }
            }
        }
        .navigationTitle(context.displayTitleWithoutSaros)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isEditingEntry = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Edit entry")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete entry")
            }
        }
        .sheet(isPresented: $isEditingEntry) {
            NavigationStack {
                JournalEntryCaptureView(editing: entry)
            }
        }
        .onDisappear {
            audioPlayer.stop()
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

    private var pulseReading: SarosPulseReading? {
        let selectedSaros = pulseSaros > 0
            ? pulseSaros
            : (context.closestSpike?.saros ?? (try? SarosPulseCalculator.defaultActiveSaros(
                at: entry.eventDate,
                eclipseService: services.eclipseService
            )) ?? 0)
        guard selectedSaros > 0 else { return nil }
        return try? SarosPulseCalculator.reading(
            saros: selectedSaros,
            date: entry.eventDate,
            harmonicDepth: harmonicDepth,
            eclipseService: services.eclipseService
        )
    }

    private var syncStatusTitle: String {
        syncCommands.contains { command in
            command.isPending
                && command.subjectID == entry.id.uuidString
                && (command.type == .entryUpsert || command.type == .entryDelete)
        } ? "Pending" : "Synced"
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
        SyncLocalCommand.enqueue(
            .entryDelete,
            subjectID: entry.id.uuidString,
            existing: syncCommands,
            modelContext: modelContext
        )
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
    @Query(sort: \JournalTag.createdAt, order: .forward) private var tags: [JournalTag]
    @Query(sort: \JournalEntry.eventDate, order: .reverse) private var entries: [JournalEntry]
    @Query(sort: \SyncLocalCommand.createdAt, order: .forward) private var syncCommands: [SyncLocalCommand]
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""

    let recordStartedAt: Date
    let existingDraft: JournalEntryDraft?
    private let initialLatitude: Double?
    private let initialLongitude: Double?

    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var locationProvider = JournalEntryLocationProvider()
    @State private var noteText = ""
    @State private var emoji = JournalRecordMarkers.random()
    @State private var eventDate: Date
    @State private var eventEndDate: Date
    @State private var mediaItems: [JournalMediaItem] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var context: JournalEventContext?
    @State private var isLoadingPhoto = false
    @State private var isCameraPresented = false
    @State private var isSaving = false
    @State private var isFetchingWeather = false
    @State private var didSaveEntry = false
    @State private var didPersistDraft = false
    @State private var errorMessage: String?
    @State private var weatherCode: Int?
    @State private var weatherEmoji: String?
    @State private var temperatureC: Int?
    @State private var weatherStatusMessage = ""
    @State private var selectedTagIDs: Set<String> = []
    @State private var isTagPickerPresented = false
    @State private var removedMediaItems: [JournalMediaItem] = []

    private let editingEntry: JournalEntry?

    init(
        recordStartedAt: Date = Date(),
        eventEndDate: Date? = nil,
        template: JournalTemplateSeed = .random,
        draft: JournalEntryDraft? = nil,
        initialMediaItems: [JournalMediaItem] = [],
        initialLatitude: Double? = nil,
        initialLongitude: Double? = nil
    ) {
        let startedAt = draft?.recordStartedAt ?? recordStartedAt
        let lastWeather = JournalWeatherDefaults.current()
        self.recordStartedAt = startedAt
        self.existingDraft = draft
        self.editingEntry = nil
        self.initialLatitude = draft?.latitude ?? initialLatitude
        self.initialLongitude = draft?.longitude ?? initialLongitude
        _eventDate = State(initialValue: draft?.eventDate ?? startedAt)
        _eventEndDate = State(initialValue: draft?.endDate ?? eventEndDate ?? draft?.eventDate ?? startedAt)
        _noteText = State(initialValue: draft?.text ?? template.text)
        _emoji = State(initialValue: draft?.emoji ?? template.resolvedEmoji)
        _mediaItems = State(initialValue: draft?.mediaItems ?? initialMediaItems)
        _weatherCode = State(initialValue: draft?.weatherCode ?? lastWeather.code)
        _weatherEmoji = State(initialValue: draft?.weatherEmoji ?? lastWeather.emoji)
        _temperatureC = State(initialValue: draft?.temperatureC ?? lastWeather.temperatureC)
        _selectedTagIDs = State(initialValue: Set(draft?.tagIDs ?? []))
    }

    init(editing entry: JournalEntry) {
        self.recordStartedAt = entry.createdAt
        self.existingDraft = nil
        self.editingEntry = entry
        self.initialLatitude = entry.latitude
        self.initialLongitude = entry.longitude
        _eventDate = State(initialValue: entry.eventDate)
        _eventEndDate = State(initialValue: entry.effectiveEndDate)
        _noteText = State(initialValue: entry.text ?? "")
        _emoji = State(initialValue: entry.emoji ?? JournalRecordMarkers.random())
        _mediaItems = State(initialValue: entry.mediaItems)
        _weatherCode = State(initialValue: entry.weatherCode)
        _weatherEmoji = State(initialValue: entry.weatherEmoji)
        _temperatureC = State(initialValue: entry.temperatureC)
        _selectedTagIDs = State(initialValue: Set(entry.tagIDs))
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

                DatePicker("End", selection: $eventEndDate, in: eventDate...)
                    .datePickerStyle(.compact)

                HStack(spacing: 10) {
                    JournalTimingIconButton(systemName: "arrow.left.to.line", title: "Start") {
                        setStartToNow()
                    }
                    JournalTimingIconButton(systemName: "arrow.right.to.line", title: "Finish") {
                        setFinishToNow()
                    }
                    JournalTimingIconButton(systemName: "arrow.down.right.and.arrow.up.left", title: "Collapse") {
                        collapseTimingToNow()
                    }
                    JournalTimingIconButton(systemName: "minus", title: "Cut") {
                        cutEndByKilosaros()
                    }
                    JournalTimingIconButton(systemName: "plus", title: "Extend") {
                        extendEndByKilosaros()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

                if let context {
                    JournalSpikeGlyphStrip(
                        spikes: context.spikes,
                        displayDepth: JournalSettings.canonicalHarmonicDepth,
                        size: 38
                    )
                    JournalEntryWaveformView(context: context, endDate: normalizedEndDate)
                        .frame(height: 150)
                } else {
                    ContentUnavailableView("Saros context unavailable", systemImage: "waveform.path.ecg")
                }
            }

            Section("Weather") {
                JournalWeatherCaptureSection(
                    weatherCode: $weatherCode,
                    weatherEmoji: $weatherEmoji,
                    temperatureC: $temperatureC,
                    isFetchingWeather: isFetchingWeather,
                    statusMessage: weatherStatusMessage.nilIfBlank
                ) {
                    Task { await fetchCurrentWeather() }
                }
            }

            Section("Tags") {
                JournalSelectedTagsRow(
                    tags: selectedTags,
                    hasAvailableTags: !availableTags.isEmpty,
                    onAdd: { isTagPickerPresented = true },
                    onRemove: { tag in selectedTagIDs.remove(tag.compactID) }
                )
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
        .navigationTitle(editingEntry == nil ? "Record" : "Edit record")
        .refreshable {
            await refreshFromRelay()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    persistDraft()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await saveEntry() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Label("Save", systemImage: "tray.and.arrow.down")
                    }
                }
                .disabled(isSaving || isLoadingPhoto || context == nil)
            }
        }
        .task {
            locationProvider.prepare()
            refreshContext()
        }
        .onChange(of: eventDate) { _, _ in
            if eventEndDate < eventDate {
                eventEndDate = eventDate
            }
            refreshContext()
        }
        .onChange(of: audioRecorder.lastItem) { _, item in
            guard let item else { return }
            mediaItems.append(item)
            _ = audioRecorder.consumeLastItem()
        }
        .onDisappear {
            guard editingEntry == nil else { return }
            guard !didSaveEntry, !didPersistDraft else { return }
            persistDraft()
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            MirrorCameraView { media in
                addCameraMedia(media)
            }
        }
        .sheet(isPresented: $isTagPickerPresented) {
            NavigationStack {
                JournalTagPickerView(
                    tags: availableTags,
                    onSelect: { tag in
                        selectedTagIDs.insert(tag.compactID)
                        isTagPickerPresented = false
                    }
                )
            }
        }
        .alert("Record failed", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func refreshFromRelay() async {
        guard syncServerURL.nilIfBlank != nil else { return }
        do {
            _ = try await services.syncService.synchronizeEntries(
                with: syncServerURL,
                modelContext: modelContext,
                tags: tags,
                entries: entries,
                commands: syncCommands
            )
        } catch {
            // Manual refresh should never trap the edit flow behind an alert.
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
            let fallbackLatitude = coordinate?.latitude ?? initialLatitude
            let fallbackLongitude = coordinate?.longitude ?? initialLongitude
            let device = JournalDevice.current()
            if let editingEntry {
                editingEntry.createdAt = recordStartedAt
                editingEntry.updatedAt = Date()
                editingEntry.eventDate = eventDate
                editingEntry.endDate = normalizedEndDate
                editingEntry.unixTimestamp = Int64(eventDate.timeIntervalSince1970.rounded(.towardZero))
                editingEntry.version += 1
                editingEntry.text = noteText.nilIfBlank
                editingEntry.emoji = emoji.nilIfBlank ?? JournalRecordMarkers.random()
                editingEntry.mediaItems = savedMedia
                editingEntry.context = resolvedContext
                editingEntry.tagIDs = sortedSelectedTagIDs
                editingEntry.latitude = fallbackLatitude ?? editingEntry.latitude
                editingEntry.longitude = fallbackLongitude ?? editingEntry.longitude
                editingEntry.sourceDeviceID = device.id
                editingEntry.sourceDeviceEmoji = device.emoji
                editingEntry.sourceDeviceName = device.name
                editingEntry.weatherCode = weatherCode
                editingEntry.weatherEmoji = weatherEmoji
                editingEntry.temperatureC = temperatureC
                SyncLocalCommand.enqueue(
                    .entryUpsert,
                    subjectID: editingEntry.id.uuidString,
                    existing: syncCommands,
                    modelContext: modelContext
                )
                try modelContext.save()
                for item in removedMediaItems {
                    MediaStorage.delete(item)
                }
                didSaveEntry = true
                JournalWeatherDefaults.save(code: weatherCode, emoji: weatherEmoji, temperatureC: temperatureC)
                dismiss()
                return
            }

            let entry = JournalEntry(
                createdAt: recordStartedAt,
                updatedAt: Date(),
                eventDate: eventDate,
                endDate: normalizedEndDate,
                text: noteText.nilIfBlank,
                emoji: emoji.nilIfBlank ?? JournalRecordMarkers.random(),
                mediaItems: savedMedia,
                context: resolvedContext,
                tagIDs: sortedSelectedTagIDs,
                latitude: fallbackLatitude,
                longitude: fallbackLongitude,
                sourceDeviceID: device.id,
                sourceDeviceEmoji: device.emoji,
                sourceDeviceName: device.name,
                weatherCode: weatherCode,
                weatherEmoji: weatherEmoji,
                temperatureC: temperatureC
            )
            modelContext.insert(entry)
            SyncLocalCommand.enqueue(
                .entryUpsert,
                subjectID: entry.id.uuidString,
                existing: syncCommands,
                modelContext: modelContext
            )
            if let existingDraft {
                modelContext.delete(existingDraft)
            }
            try modelContext.save()
            didSaveEntry = true
            JournalWeatherDefaults.save(code: weatherCode, emoji: weatherEmoji, temperatureC: temperatureC)
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
    private func fetchCurrentWeather() async {
        weatherStatusMessage = ""
        guard let coordinate = locationProvider.coordinate else {
            weatherStatusMessage = "Location unavailable."
            return
        }
        isFetchingWeather = true
        defer { isFetchingWeather = false }
        do {
            let reading = try await services.weatherService.currentWeather(at: coordinate)
            weatherCode = reading.code
            weatherEmoji = reading.emoji
            temperatureC = reading.temperatureC
            JournalWeatherDefaults.save(code: reading.code, emoji: reading.emoji, temperatureC: reading.temperatureC)
            weatherStatusMessage = "Weather updated."
        } catch {
            weatherStatusMessage = "Weather unavailable."
        }
    }

    @MainActor
    private func persistDraft() {
        guard editingEntry == nil else { return }
        guard !didSaveEntry else { return }
        let coordinate = locationProvider.coordinate
        let fallbackLatitude = coordinate?.latitude ?? initialLatitude
        let fallbackLongitude = coordinate?.longitude ?? initialLongitude
        if let existingDraft {
            existingDraft.update(
                recordStartedAt: recordStartedAt,
                eventDate: eventDate,
                endDate: normalizedEndDate,
                text: noteText.nilIfBlank,
                emoji: emoji.nilIfBlank,
                mediaItems: mediaItems,
                tagIDs: sortedSelectedTagIDs,
                latitude: fallbackLatitude ?? existingDraft.latitude,
                longitude: fallbackLongitude ?? existingDraft.longitude,
                weatherCode: weatherCode,
                weatherEmoji: weatherEmoji,
                temperatureC: temperatureC
            )
        } else {
            modelContext.insert(JournalEntryDraft(
                recordStartedAt: recordStartedAt,
                eventDate: eventDate,
                endDate: normalizedEndDate,
                text: noteText.nilIfBlank,
                emoji: emoji.nilIfBlank,
                mediaItems: mediaItems,
                tagIDs: sortedSelectedTagIDs,
                latitude: fallbackLatitude,
                longitude: fallbackLongitude,
                weatherCode: weatherCode,
                weatherEmoji: weatherEmoji,
                temperatureC: temperatureC
            ))
        }
        do {
            try modelContext.save()
            didPersistDraft = true
        } catch {
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
        if editingEntry == nil {
            MediaStorage.delete(item)
        } else if !removedMediaItems.contains(where: { $0.id == item.id }) {
            removedMediaItems.append(item)
        }
    }

    private var sortedSelectedTagIDs: [String] {
        let tagOrder = JournalTag.compactIDOrderMap(for: tags)
        return selectedTagIDs
            .compactMap(JournalTag.normalizedOctalID)
            .sorted { lhs, rhs in
                let lhsOrder = tagOrder[lhs] ?? Int.max
                let rhsOrder = tagOrder[rhs] ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs < rhs
            }
    }

    private var selectedTags: [JournalTag] {
        tags.filter { selectedTagIDs.contains($0.compactID) }
    }

    private var availableTags: [JournalTag] {
        tags.filter { !selectedTagIDs.contains($0.compactID) }
    }

    private var kilosarosDuration: TimeInterval {
        SarosPulseCalculator.averageDuration(for: .kilo)
    }

    @MainActor
    private func setStartToNow() {
        let now = Date()
        eventDate = now
        if eventEndDate < eventDate {
            eventEndDate = eventDate
        }
        refreshContext()
    }

    @MainActor
    private func setFinishToNow() {
        let now = Date()
        if now < eventDate {
            eventDate = now
        }
        eventEndDate = max(now, eventDate)
        refreshContext()
    }

    @MainActor
    private func collapseTimingToNow() {
        let now = Date()
        eventDate = now
        eventEndDate = now
        refreshContext()
    }

    @MainActor
    private func cutEndByKilosaros() {
        eventEndDate = max(eventDate, eventEndDate.addingTimeInterval(-kilosarosDuration))
    }

    @MainActor
    private func extendEndByKilosaros() {
        eventEndDate = eventEndDate.addingTimeInterval(kilosarosDuration)
    }

    private var normalizedEndDate: Date {
        eventEndDate < eventDate ? eventDate : eventEndDate
    }
}

private struct JournalSelectedTagsRow: View {
    let tags: [JournalTag]
    let hasAvailableTags: Bool
    let onAdd: () -> Void
    let onRemove: (JournalTag) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if tags.isEmpty {
                    Text("No tags")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(tags) { tag in
                                Button {
                                    onRemove(tag)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(tag.displayEmoji)
                                        Text(tag.displayName)
                                            .lineLimit(1)
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        Color(hex: tag.tintHex, fallback: .accentColor).opacity(0.18),
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule()
                                            .stroke(Color(hex: tag.tintHex, fallback: .accentColor).opacity(0.65), lineWidth: 1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove tag \(tag.displayName)")
                            }
                        }
                    }
                }

                Spacer(minLength: 8)

                Button {
                    onAdd()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!hasAvailableTags)
                .accessibilityLabel("Add tag")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct JournalTagPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let tags: [JournalTag]
    let onSelect: (JournalTag) -> Void

    var body: some View {
        Group {
            if tags.isEmpty {
                ContentUnavailableView("No tags available", systemImage: "tag")
            } else {
                List(tags) { tag in
                    Button {
                        onSelect(tag)
                    } label: {
                        HStack(spacing: 12) {
                            Text(tag.displayEmoji)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tag.displayName)
                                    .foregroundStyle(.primary)
                                Text(tag.displayCompactID)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(Color(hex: tag.tintHex, fallback: .white))
                                .frame(width: 12, height: 12)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Add tag")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
    }
}

private struct JournalEntryEditDraft: Identifiable, Hashable {
    let id: UUID
    var eventDate: Date
    var text: String
    var emoji: String
    var selectedTagIDs: Set<String>
    var weatherCode: Int?
    var weatherEmoji: String?
    var temperatureC: Int?

    init(entry: JournalEntry) {
        self.id = entry.id
        self.eventDate = entry.eventDate
        self.text = entry.text ?? ""
        self.emoji = entry.emoji ?? ""
        self.selectedTagIDs = Set(entry.tagIDs)
        self.weatherCode = entry.weatherCode
        self.weatherEmoji = entry.weatherEmoji
        self.temperatureC = entry.temperatureC
    }

    func sortedTagIDs(tags: [JournalTag]) -> [String] {
        let order = JournalTag.compactIDOrderMap(for: tags)
        return selectedTagIDs
            .compactMap(JournalTag.normalizedOctalID)
            .sorted { lhs, rhs in
                let lhsOrder = order[lhs] ?? Int.max
                let rhsOrder = order[rhs] ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs < rhs
            }
    }
}

private struct JournalEntryEditView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \JournalEntry.eventDate, order: .reverse) private var entries: [JournalEntry]
    @Query(sort: \SyncLocalCommand.createdAt, order: .forward) private var syncCommands: [SyncLocalCommand]
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""

    let entry: JournalEntry
    let tags: [JournalTag]
    let onSave: (JournalEntryEditDraft) -> Void

    @State private var draft: JournalEntryEditDraft
    @State private var isTagPickerPresented = false

    init(
        entry: JournalEntry,
        draft: JournalEntryEditDraft,
        tags: [JournalTag],
        onSave: @escaping (JournalEntryEditDraft) -> Void
    ) {
        self.entry = entry
        self.tags = tags
        self.onSave = onSave
        _draft = State(initialValue: draft)
    }

    var body: some View {
        Form {
            Section("Record") {
                TextField("Emoji marker", text: $draft.emoji)
                    .textContentType(.none)

                TextEditor(text: $draft.text)
                    .font(.body)
                    .lineSpacing(4)
                    .frame(minHeight: 180, maxHeight: 320)
                    .scrollContentBackground(.hidden)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            Section("Timing") {
                DatePicker("Record date", selection: $draft.eventDate)
                    .datePickerStyle(.compact)
            }

            Section("Weather") {
                JournalWeatherCaptureSection(
                    weatherCode: $draft.weatherCode,
                    weatherEmoji: $draft.weatherEmoji,
                    temperatureC: $draft.temperatureC,
                    isFetchingWeather: false,
                    fetchCurrentWeather: {}
                )
            }

            Section("Tags") {
                JournalSelectedTagsRow(
                    tags: selectedTags,
                    hasAvailableTags: !availableTags.isEmpty,
                    onAdd: { isTagPickerPresented = true },
                    onRemove: { tag in draft.selectedTagIDs.remove(tag.compactID) }
                )
            }
        }
        .navigationTitle("Edit record")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refreshFromRelay()
        }
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
        .sheet(isPresented: $isTagPickerPresented) {
            NavigationStack {
                JournalTagPickerView(
                    tags: availableTags,
                    onSelect: { tag in
                        draft.selectedTagIDs.insert(tag.compactID)
                        isTagPickerPresented = false
                    }
                )
            }
        }
    }

    @MainActor
    private func refreshFromRelay() async {
        guard syncServerURL.nilIfBlank != nil else { return }
        do {
            _ = try await services.syncService.synchronizeEntries(
                with: syncServerURL,
                modelContext: modelContext,
                tags: tags,
                entries: entries,
                commands: syncCommands
            )
        } catch {
            // Relay refresh is best-effort; editing must keep working offline.
        }
    }

    private var selectedTags: [JournalTag] {
        tags.filter { draft.selectedTagIDs.contains($0.compactID) }
    }

    private var availableTags: [JournalTag] {
        tags.filter { !draft.selectedTagIDs.contains($0.compactID) }
    }
}

private struct JournalTemplateCaptureRequest: Identifiable, Hashable {
    let id = UUID()
    let startDate: Date
    let endDate: Date
    let template: JournalTemplateSeed
    var mediaItems: [JournalMediaItem] = []
    var latitude: Double?
    var longitude: Double?
}

private struct ContinuousActivityLoggingPanel: View {
    let session: ContinuousActivitySession?
    let onBegin: () -> Void
    let onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 14) {
                if let session {
                    let glyph = ActivityLoggingGlyph.glyph(startDate: session.startDate, at: timeline.date)
                    let color = Color(hex: ActivityLoggingGlyph.colorHex(for: glyph), fallback: .white)
                    OctalGlyph(
                        value: glyph,
                        depth: ActivityLoggingGlyph.depth,
                        color: color
                    )
                    .frame(width: 54, height: 54)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.isCountdown ? "Countdown" : ActivityLoggingGlyph.title(for: glyph))
                            .font(.headline)
                            .foregroundStyle(color)
                        if let endDate = session.displayEndDate {
                            if endDate > timeline.date {
                                Text(timerInterval: timeline.date...endDate, countsDown: true)
                                    .font(.title3.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.primary)
                            } else {
                                Text("Done")
                                    .font(.title3.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                        } else {
                            Text(session.startDate, style: .timer)
                                .font(.title3.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                } else {
                    Image(systemName: "record.circle")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Continuous log")
                            .font(.headline)
                        Text("Capture an activity as a time window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Button(action: session == nil ? onBegin : onStop) {
                    Label(
                        session == nil ? "Begin" : "Stop",
                        systemImage: session == nil ? "play.circle.fill" : "stop.circle.fill"
                    )
                    .font(.callout.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(session == nil ? Color.accentColor : Color.red, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
    }
}

struct JournalTemplatesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \JournalTemplate.createdAt, order: .forward) private var templates: [JournalTemplate]
    @Query(sort: \JournalEntryDraft.updatedAt, order: .reverse) private var entryDrafts: [JournalEntryDraft]

    @AppStorage(ContinuousActivityLogger.sessionKey) private var activitySessionData = Data()

    @State private var selectedTemplateAction: JournalTemplateSeed?
    @State private var captureRequest: JournalTemplateCaptureRequest?
    @State private var selectedEntryDraft: JournalEntryDraft?
    @State private var pendingTemplate: JournalTemplateSeed?
    @State private var isReplacingDraft = false
    @State private var draft: JournalTemplateDraft?

    private var activeDraft: JournalEntryDraft? {
        entryDrafts.first
    }

    private var activitySession: ContinuousActivitySession? {
        ContinuousActivityLogger.session(from: activitySessionData)
    }

    var body: some View {
        List {
            Section {
                ContinuousActivityLoggingPanel(
                    session: activitySession,
                    onBegin: { beginActivityLogging(template: .random) },
                    onStop: stopActivityLogging
                )
            }

            if let activeDraft {
                Section {
                    Button {
                        selectedEntryDraft = activeDraft
                    } label: {
                        Label("Resume draft", systemImage: "arrow.uturn.forward.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }

            Section {
                Button {
                    openTemplate(.random)
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
                        openTemplate(JournalTemplateSeed(template: template))
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
        .sheet(item: $selectedTemplateAction) { template in
            NavigationStack {
                JournalTemplateActionView(
                    template: template,
                    onNow: { request in
                        captureRequest = request
                        selectedTemplateAction = nil
                    },
                    onCountdown: { template, duration in
                        beginCountdown(template: template, duration: duration)
                        selectedTemplateAction = nil
                    },
                    onTimer: { template in
                        beginActivityLogging(template: template)
                        selectedTemplateAction = nil
                    },
                    onRetroactive: { request in
                        captureRequest = request
                        selectedTemplateAction = nil
                    }
                )
            }
        }
        .sheet(item: $captureRequest) { request in
            NavigationStack {
                JournalEntryCaptureView(
                    recordStartedAt: request.startDate,
                    eventEndDate: request.endDate,
                    template: request.template,
                    initialMediaItems: request.mediaItems,
                    initialLatitude: request.latitude,
                    initialLongitude: request.longitude
                )
            }
        }
        .sheet(item: $selectedEntryDraft) { draft in
            NavigationStack {
                JournalEntryCaptureView(draft: draft)
            }
        }
        .sheet(item: $draft) { draft in
            NavigationStack {
                JournalTemplateEditorView(draft: draft) { savedDraft in
                    saveTemplate(savedDraft)
                }
            }
        }
        .confirmationDialog("Replace current draft?", isPresented: $isReplacingDraft, titleVisibility: .visible) {
            Button("Delete Draft", role: .destructive) {
                if let activeDraft {
                    discardDraft(activeDraft)
                }
                selectedTemplateAction = pendingTemplate
                pendingTemplate = nil
            }
            Button("Cancel", role: .cancel) {
                pendingTemplate = nil
            }
        } message: {
            Text("Opening a template starts a new entry and deletes the unsaved draft.")
        }
    }

    private func openTemplate(_ template: JournalTemplateSeed) {
        if activeDraft != nil {
            pendingTemplate = template
            isReplacingDraft = true
        } else {
            selectedTemplateAction = template
        }
    }

    @MainActor
    private func beginActivityLogging(template: JournalTemplateSeed) {
        let session = ContinuousActivityLogger.beginTimer(template: template)
        Task {
            try? await ThreadLiveActivityService.start(
                snapshot: ThreadLiveActivityService.activityLoggingSnapshot(
                    startDate: session.startDate,
                    endDate: session.endDate
                )
            )
        }
    }

    @MainActor
    private func stopActivityLogging() {
        guard let window = ContinuousActivityLogger.finish() else {
            return
        }
        captureRequest = JournalTemplateCaptureRequest(
            startDate: window.startDate,
            endDate: window.endDate,
            template: window.template
        )
        Task {
            await ThreadLiveActivityService.stopActivityLogging()
            await NotificationScheduler.shared.cancelActivityCountdown()
        }
    }

    @MainActor
    private func beginCountdown(template: JournalTemplateSeed, duration: TimeInterval) {
        let session = ContinuousActivityLogger.beginCountdown(template: template, duration: duration)
        Task {
            await NotificationScheduler.shared.scheduleActivityCountdownCompletion(for: session)
            try? await ThreadLiveActivityService.start(
                snapshot: ThreadLiveActivityService.activityLoggingSnapshot(
                    startDate: session.startDate,
                    endDate: session.endDate
                )
            )
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

    private func discardDraft(_ draft: JournalEntryDraft) {
        draft.mediaItems.forEach(MediaStorage.delete)
        modelContext.delete(draft)
        try? modelContext.save()
    }
}

private struct JournalTemplateActionView: View {
    @Environment(\.dismiss) private var dismiss

    let template: JournalTemplateSeed
    let onNow: (JournalTemplateCaptureRequest) -> Void
    let onCountdown: (JournalTemplateSeed, TimeInterval) -> Void
    let onTimer: (JournalTemplateSeed) -> Void
    let onRetroactive: (JournalTemplateCaptureRequest) -> Void

    @State private var megaCount = 0
    @State private var kiloCount = 0
    @State private var sarosCount = 1
    @State private var miliCount = 0
    @State private var isCountdownExpanded = false
    @State private var retroactivePhotoItem: PhotosPickerItem?
    @State private var isLoadingRetroactivePhoto = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Text(template.resolvedStaticEmoji)
                            .font(.system(size: 44))
                            .frame(width: 54, height: 54)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(template.name)
                                .font(.headline)
                            Text(template.text.nilIfBlank ?? "Empty text")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                        JournalTemplateActionButton(title: "Now", systemName: "record.circle") {
                            let now = Date()
                            onNow(JournalTemplateCaptureRequest(
                                startDate: now,
                                endDate: now,
                                template: template
                            ))
                            dismiss()
                        }

                        JournalTemplateActionButton(title: "Countdown", systemName: "timer") {
                            withAnimation(.snappy) {
                                isCountdownExpanded.toggle()
                            }
                        }

                        JournalTemplateActionButton(title: "Timer", systemName: "stopwatch") {
                            onTimer(template)
                            dismiss()
                        }

                        PhotosPicker(selection: $retroactivePhotoItem, matching: .images) {
                            JournalTemplateActionButtonLabel(title: "Retroactive", systemName: "photo.badge.clock")
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingRetroactivePhoto)
                    }
                }
                .padding(.vertical, 4)

                if isCountdownExpanded {
                    JournalCountdownConfigurationView(
                        megaCount: $megaCount,
                        kiloCount: $kiloCount,
                        sarosCount: $sarosCount,
                        miliCount: $miliCount,
                        duration: countdownDuration
                    ) {
                        onCountdown(template, countdownDuration)
                        dismiss()
                    }
                }

                if isLoadingRetroactivePhoto {
                    HStack {
                        ProgressView()
                        Text("Loading photo")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Record")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
        .onChange(of: retroactivePhotoItem) { _, item in
            guard let item else { return }
            Task {
                await importRetroactivePhoto(item)
            }
        }
    }

    private var countdownDuration: TimeInterval {
        Double(megaCount) * SarosPulseCalculator.averageDuration(for: .mega)
            + Double(kiloCount) * SarosPulseCalculator.averageDuration(for: .kilo)
            + Double(sarosCount) * SarosPulseCalculator.averageDuration(for: .saros)
            + Double(miliCount) * SarosPulseCalculator.averageDuration(for: .mili)
    }

    @MainActor
    private func importRetroactivePhoto(_ item: PhotosPickerItem) async {
        isLoadingRetroactivePhoto = true
        errorMessage = nil
        defer {
            isLoadingRetroactivePhoto = false
            retroactivePhotoItem = nil
        }

        do {
            guard let pickedPhoto = try await item.loadTransferable(type: JournalPickedPhotoTransfer.self) else {
                errorMessage = "Photo unavailable."
                return
            }
            let metadata = JournalImportedPhotoMetadataReader.read(from: pickedPhoto.data)
            let mediaItem = try MediaStorage.saveData(
                pickedPhoto.data,
                fileExtension: item.supportedContentTypes.first(where: { $0.conforms(to: .image) })?.preferredFilenameExtension ?? "jpg",
                type: .photo
            )
            let date = metadata.date ?? Date()
            onRetroactive(JournalTemplateCaptureRequest(
                startDate: date,
                endDate: date,
                template: template,
                mediaItems: [mediaItem],
                latitude: metadata.latitude,
                longitude: metadata.longitude
            ))
            dismiss()
        } catch {
            errorMessage = "Photo import failed."
        }
    }
}

private struct JournalTemplateActionButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            JournalTemplateActionButtonLabel(title: title, systemName: systemName)
        }
        .buttonStyle(.plain)
    }
}

private struct JournalTemplateActionButtonLabel: View {
    let title: String
    let systemName: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.title2.weight(.semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 86)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

private struct JournalCountdownConfigurationView: View {
    @Binding var megaCount: Int
    @Binding var kiloCount: Int
    @Binding var sarosCount: Int
    @Binding var miliCount: Int

    let duration: TimeInterval
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            JournalCountdownStepper(label: "Mega", value: $megaCount)
            JournalCountdownStepper(label: "Kilo", value: $kiloCount)
            JournalCountdownStepper(label: "Saros", value: $sarosCount)
            JournalCountdownStepper(label: "Mili", value: $miliCount)

            HStack {
                Text(SarosDurationUnitFormatter.verboseDuration(duration, maxUnits: 3))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onStart()
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(duration <= 0)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct JournalCountdownStepper: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        Stepper(value: $value, in: 0...7) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value)")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct JournalImportedPhotoMetadata {
    var date: Date?
    var latitude: Double?
    var longitude: Double?
}

private enum JournalImportedPhotoMetadataReader {
    static func read(from data: Data) -> JournalImportedPhotoMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return JournalImportedPhotoMetadata()
        }

        var metadata = JournalImportedPhotoMetadata()
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let dateString = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String
            ?? exif?[kCGImagePropertyExifDateTimeDigitized as String] as? String
            ?? tiff?[kCGImagePropertyTIFFDateTime as String] as? String
        metadata.date = dateString.flatMap(parseExifDate)

        if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            metadata.latitude = coordinateValue(
                gps[kCGImagePropertyGPSLatitude as String],
                ref: gps[kCGImagePropertyGPSLatitudeRef as String] as? String,
                negativeRef: "S"
            )
            metadata.longitude = coordinateValue(
                gps[kCGImagePropertyGPSLongitude as String],
                ref: gps[kCGImagePropertyGPSLongitudeRef as String] as? String,
                negativeRef: "W"
            )
        }

        return metadata
    }

    private static func parseExifDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private static func coordinateValue(_ rawValue: Any?, ref: String?, negativeRef: String) -> Double? {
        let value: Double?
        if let double = rawValue as? Double {
            value = double
        } else if let number = rawValue as? NSNumber {
            value = number.doubleValue
        } else {
            value = nil
        }
        guard let value else { return nil }
        return ref?.uppercased() == negativeRef ? -abs(value) : abs(value)
    }
}

struct JournalTemplateSeed: Identifiable, Hashable, Codable {
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

    var resolvedStaticEmoji: String {
        usesRandomEmoji ? JournalRecordMarkers.fallback : (emoji?.nilIfBlank ?? JournalRecordMarkers.fallback)
    }

    var previewTitle: String {
        text.nilIfBlank?.components(separatedBy: .newlines).first?.nilIfBlank
            ?? name.nilIfBlank
            ?? "Activity"
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

private enum JournalWeatherDefaults {
    static func current() -> (code: Int?, emoji: String?, temperatureC: Int?) {
        let defaults = UserDefaults.standard
        let code = defaults.object(forKey: JournalSettings.lastWeatherCodeKey) as? Int
        let emoji = defaults.string(forKey: JournalSettings.lastWeatherEmojiKey)?.nilIfBlank
        let temperatureC = defaults.object(forKey: JournalSettings.lastWeatherTemperatureKey) as? Int
        return (code, emoji, temperatureC)
    }

    static func save(code: Int?, emoji: String?, temperatureC: Int?) {
        let defaults = UserDefaults.standard
        if let code {
            defaults.set(code, forKey: JournalSettings.lastWeatherCodeKey)
        } else {
            defaults.removeObject(forKey: JournalSettings.lastWeatherCodeKey)
        }

        if let emoji = emoji?.nilIfBlank {
            defaults.set(emoji, forKey: JournalSettings.lastWeatherEmojiKey)
        } else {
            defaults.removeObject(forKey: JournalSettings.lastWeatherEmojiKey)
        }

        if let temperatureC {
            defaults.set(temperatureC, forKey: JournalSettings.lastWeatherTemperatureKey)
        } else {
            defaults.removeObject(forKey: JournalSettings.lastWeatherTemperatureKey)
        }
    }
}

private struct JournalWeatherCaptureSection: View {
    @Binding var weatherCode: Int?
    @Binding var weatherEmoji: String?
    @Binding var temperatureC: Int?
    let isFetchingWeather: Bool
    var statusMessage: String? = nil
    let fetchCurrentWeather: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(JournalWeatherCatalog.options) { option in
                        Button {
                            weatherCode = option.id
                            weatherEmoji = option.emoji
                        } label: {
                            Text(option.emoji)
                                .font(.title2)
                                .frame(width: 44, height: 44)
                                .background(
                                    selectedWeatherOption?.id == option.id
                                        ? Color.accentColor.opacity(0.24)
                                        : Color.secondary.opacity(0.12),
                                    in: Circle()
                                )
                                .overlay {
                                    Circle()
                                        .stroke(
                                            selectedWeatherOption?.id == option.id ? Color.accentColor : Color.secondary.opacity(0.18),
                                            lineWidth: selectedWeatherOption?.id == option.id ? 2 : 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    adjustTemperature(by: -1)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Decrease temperature")

                TextField("°C", text: temperatureText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.center)
                    .font(.title3.monospacedDigit())
                    .frame(width: 86)
                    .textFieldStyle(.roundedBorder)

                Button {
                    adjustTemperature(by: 1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Increase temperature")
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Button {
                fetchCurrentWeather()
            } label: {
                if isFetchingWeather {
                    ProgressView()
                } else {
                    Label("Fetch current weather", systemImage: "location.magnifyingglass")
                }
            }
            .disabled(isFetchingWeather)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedWeatherOption: JournalWeatherOption? {
        JournalWeatherCatalog.option(for: weatherCode)
    }

    private var temperatureText: Binding<String> {
        Binding {
            temperatureC.map(String.init) ?? ""
        } set: { value in
            let filtered = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if filtered.isEmpty {
                temperatureC = nil
            } else if let number = Int(filtered) {
                temperatureC = min(max(number, -40), 40)
            }
        }
    }

    private func adjustTemperature(by delta: Int) {
        temperatureC = min(max((temperatureC ?? 0) + delta, -40), 40)
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
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \JournalTag.createdAt, order: .forward) private var tags: [JournalTag]
    @Query(sort: \JournalEntry.eventDate, order: .reverse) private var entries: [JournalEntry]
    @Query(sort: \SyncLocalCommand.createdAt, order: .forward) private var syncCommands: [SyncLocalCommand]
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""

    @State private var draft: JournalTagDraft?
    @State private var errorMessage: String?

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
                            Text(tag.displayCompactID)
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.thinMaterial, in: Capsule())
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
        .refreshable {
            await refreshFromRelay()
        }
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
        .alert("Tag update failed", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func refreshFromRelay() async {
        guard syncServerURL.nilIfBlank != nil else { return }
        do {
            _ = try await services.syncService.synchronizeEntries(
                with: syncServerURL,
                modelContext: modelContext,
                tags: tags,
                entries: entries,
                commands: syncCommands
            )
        } catch {
            // Relay refresh is best-effort; tag management must keep working offline.
        }
    }

    private func entryCount(for tag: JournalTag) -> Int {
        entries.filter { $0.tagIDs.contains(tag.compactID) }.count
    }

    private func saveTag(_ draft: JournalTagDraft) {
        var tagsToRepair = tags
        if let existing = tags.first(where: { $0.id == draft.id }) {
            existing.name = draft.name.nilIfBlank ?? "Saros \(draft.saros)"
            existing.emoji = draft.emoji.nilIfBlank ?? "◇"
            existing.anchorDate = draft.anchorDate
            existing.saros = draft.saros
            existing.notes = draft.notes.nilIfBlank
            existing.isPrime = draft.isPrime
            existing.colorHex = draft.colorHex
            existing.octalID = JournalTag.normalizedOctalID(draft.octalID)
            existing.ensureCompactID(existing: tags)
            existing.touch()
        } else {
            let tag = JournalTag(
                id: draft.id,
                name: draft.name.nilIfBlank ?? "Saros \(draft.saros)",
                emoji: draft.emoji.nilIfBlank ?? "◇",
                anchorDate: draft.anchorDate,
                saros: draft.saros,
                notes: draft.notes.nilIfBlank,
                isPrime: draft.isPrime,
                colorHex: draft.colorHex,
                octalID: draft.octalID
            )
            tag.ensureCompactID(existing: tags)
            modelContext.insert(tag)
            tagsToRepair.append(tag)
        }
        _ = JournalTag.ensureUniqueCompactIDs(in: tagsToRepair)
        SyncLocalCommand.enqueue(
            .tagUpsert,
            subjectID: draft.id.uuidString,
            existing: syncCommands,
            modelContext: modelContext
        )
        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTags(at offsets: IndexSet) {
        for offset in offsets {
            deleteTag(tags[offset], save: false)
        }
        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTag(_ tag: JournalTag, save: Bool = true) {
        let compactID = tag.compactID
        for entry in entries where entry.tagIDs.contains(compactID) {
            entry.tagIDs = entry.tagIDs.filter { $0 != compactID }
            SyncLocalCommand.enqueue(
                .entryUpsert,
                subjectID: entry.id.uuidString,
                existing: syncCommands,
                modelContext: modelContext
            )
        }
        SyncLocalCommand.enqueue(
            .tagDelete,
            subjectID: tag.id.uuidString,
            existing: syncCommands,
            modelContext: modelContext
        )
        modelContext.delete(tag)
        if save {
            do {
                try modelContext.save()
            } catch {
                errorMessage = error.localizedDescription
            }
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
            let matchesTag = entry.tagIDs.contains(tag.compactID)
            let matchesRarity = selectedRarity.map { closestRarity == $0.baseRarity } ?? true
            let matchesDirection = selectedDirection.map { context.waveSignature.direction == $0 } ?? true
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
                HStack {
                    Text("ID")
                    Spacer()
                    Text(draft.displayOctalID)
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
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
    var octalID: String
    var notes: String
    var isPrime: Bool
    var colorHex: String

    init(
        id: UUID = UUID(),
        name: String = "",
        emoji: String = "◇",
        anchorDate: Date = Date(),
        saros: Int = 0,
        octalID: String = "",
        notes: String = "",
        isPrime: Bool = false,
        colorHex: String = "#FFFFFF"
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.anchorDate = anchorDate
        self.saros = saros
        self.octalID = octalID
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
        self.octalID = tag.compactID
        self.notes = tag.notes ?? ""
        self.isPrime = tag.isPrime
        self.colorHex = tag.tintHex
    }

    var displayOctalID: String {
        JournalTag.normalizedOctalID(octalID) ?? "auto"
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

private struct JournalPulseGlyphForDate: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @AppStorage(JournalSettings.pulseSarosKey) private var pulseSaros = 0

    let date: Date
    let size: CGFloat

    @State private var reading: SarosPulseReading?

    var body: some View {
        ZStack {
            if let reading {
                SarosPulseGlyph(reading: reading, size: size)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: taskID) {
            await loadReading()
        }
    }

    private var taskID: String {
        "\(pulseSaros)-\(JournalSettings.clampedHarmonicDepth(harmonicDepth))-\(Int(date.timeIntervalSince1970))"
    }

    @MainActor
    private func loadReading() async {
        let configuredSaros = pulseSaros
        let date = date
        let harmonicDepth = harmonicDepth
        let eclipseService = services.eclipseService
        let result = await Task.detached(priority: .utility) {
            Result<SarosPulseReading?, Error> {
                let resolvedSaros: Int?
                if configuredSaros > 0 {
                    resolvedSaros = configuredSaros
                } else {
                    resolvedSaros = try SarosPulseCalculator.defaultActiveSaros(
                        at: date,
                        eclipseService: eclipseService
                    )
                }

                guard let resolvedSaros else { return nil }
                return try SarosPulseCalculator.reading(
                    saros: resolvedSaros,
                    date: date,
                    harmonicDepth: harmonicDepth,
                    eclipseService: eclipseService
                )
            }
        }.value

        switch result {
        case .success(let loaded):
            reading = loaded
        case .failure:
            reading = nil
        }
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
    @AppStorage(JournalSettings.waveformMergeCloseSpikesKey) private var waveformMergeCloseSpikes = false
    @AppStorage(JournalSettings.waveformNormalizedAmplitudeKey) private var waveformNormalizedAmplitude = false
    @AppStorage(JournalSettings.waveformSubdivisionDepthKey) private var waveformSubdivisionDepth = JournalWaveformSettings.defaultSubdivisionDepth
    @AppStorage(JournalSettings.waveformAmplitudeMultiplierKey) private var waveformAmplitudeMultiplier = JournalWaveformSettings.defaultAmplitudeMultiplier

    let context: JournalEventContext
    var endDate: Date? = nil

    @State private var plot = JournalEntryWaveformPlot.empty
    @State private var lunarTicks: [LunarRulerTick] = []
    @State private var pulseTicks: [SarosPulseTick] = []
    @State private var displayMegaUnits = JournalEntryWaveform.defaultMegaUnits
    @AppStorage(JournalSettings.pulseSarosKey) private var pulseSaros = 0

    var body: some View {
        ZStack {
            Canvas { graphics, size in
                let rect = CGRect(origin: .zero, size: size)
                let background = RoundedRectangle(cornerRadius: 8).path(in: rect)
                graphics.fill(background, with: .color(Color(.secondarySystemBackground)))
                graphics.stroke(background, with: .color(.secondary.opacity(0.2)), lineWidth: 1)

                let interval = plot.interval
                let samples = plot.samples
                guard !samples.isEmpty else { return }

                let maxEnergy = plot.maxEnergy
                let lunarBottomY = JournalEntryWaveform.lunarRulerTopInset
                    + JournalEntryWaveform.lunarRulerRowSpacing * 2
                    + LunarRulerTickLevel.major.height
                let insets = EdgeInsets(top: lunarBottomY, leading: 14, bottom: 24, trailing: 14)
                let width = max(size.width - insets.leading - insets.trailing, 1)
                let height = max(size.height - insets.top - insets.bottom, 1)
                let baseline = insets.top + height
                let waveHeight = height * JournalEntryWaveform.amplitudeScale

                var path = Path()
                for sample in samples {
                    let x = insets.leading + CGFloat(sample.date.timeIntervalSince(interval.start) / interval.duration) * width
                    let y = baseline - CGFloat(sample.energy / maxEnergy) * waveHeight
                    if sample == samples.first {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                graphics.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.6)

                for midpoint in plot.midpointDates {
                    let x = insets.leading + CGFloat(midpoint.timeIntervalSince(interval.start) / interval.duration) * width
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: lunarBottomY))
                    line.addLine(to: CGPoint(x: x, y: size.height - insets.bottom))
                    graphics.stroke(
                        line,
                        with: .color(.gray.opacity(0.5)),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 4])
                    )
                }

                var placedDots: [CGPoint] = []
                for group in plot.visibleSpikeGroups {
                    let spike = group.primary
                    let baseX = insets.leading + CGFloat(spike.date.timeIntervalSince(interval.start) / interval.duration) * width
                    var x = baseX
                    let spikeEnergy = plot.energyBySpikeID[spike.id] ?? 0
                    let dotSize = JournalEntryWaveform.dotSize(for: spike.rarity)
                    let baseY = baseline - CGFloat(spikeEnergy / maxEnergy) * waveHeight
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
                    line.move(to: CGPoint(x: x, y: lunarBottomY))
                    line.addLine(to: CGPoint(x: x, y: size.height - insets.bottom))
                    graphics.stroke(line, with: .color(spike.rarity.color.opacity(0.42)), lineWidth: 1)

                    let contributors = group.contributors.isEmpty ? [spike] : group.contributors
                    let dotGap = dotSize + 3
                    let startOffset = -CGFloat(contributors.count - 1) * dotGap / 2
                    for (index, contributor) in contributors.enumerated() {
                        let y = dotY + startOffset + CGFloat(index) * dotGap
                        let dotRect = CGRect(
                            x: x - dotSize / 2,
                            y: y - dotSize / 2,
                            width: dotSize,
                            height: dotSize
                        )
                        let dot = Path(ellipseIn: dotRect)
                        graphics.fill(dot, with: .color(contributor.rarity.color))
                        graphics.stroke(dot, with: .color(.black.opacity(0.38)), lineWidth: 0.8)
                    }
                }

                let eventX = insets.leading + CGFloat(context.eventDate.timeIntervalSince(interval.start) / interval.duration) * width
                let eventY = baseline - CGFloat(plot.eventEnergy / maxEnergy) * waveHeight
                if plot.isPeriod {
                    let rawEndX = insets.leading + CGFloat(plot.eventEndDate.timeIntervalSince(interval.start) / interval.duration) * width
                    let clampedStartX = min(max(eventX, insets.leading), insets.leading + width)
                    let clampedEndX = min(max(rawEndX, insets.leading), insets.leading + width)
                    let leftX = min(clampedStartX, clampedEndX)
                    let rightX = max(clampedStartX, clampedEndX)
                    let periodRect = CGRect(
                        x: leftX,
                        y: insets.top,
                        width: max(rightX - leftX, 2),
                        height: size.height - insets.top - insets.bottom
                    )
                    let periodPath = Path(roundedRect: periodRect, cornerRadius: 4)
                    graphics.fill(periodPath, with: .color(.green.opacity(0.12)))
                    graphics.stroke(periodPath, with: .color(.green.opacity(0.55)), lineWidth: 1)

                    for x in [clampedStartX, clampedEndX] {
                        var marker = Path()
                        marker.move(to: CGPoint(x: x, y: insets.top))
                        marker.addLine(to: CGPoint(x: x, y: size.height - insets.bottom))
                        graphics.stroke(
                            marker,
                            with: .color(.green.opacity(0.85)),
                            style: StrokeStyle(lineWidth: 1.2, dash: [4, 4])
                        )
                    }

                    let endY = baseline - CGFloat(plot.eventEndEnergy / maxEnergy) * waveHeight
                    graphics.fill(Path(ellipseIn: CGRect(x: clampedStartX - 4, y: eventY - 4, width: 8, height: 8)), with: .color(.green))
                    graphics.fill(Path(ellipseIn: CGRect(x: clampedEndX - 4, y: endY - 4, width: 8, height: 8)), with: .color(.green))
                } else {
                    var marker = Path()
                    marker.move(to: CGPoint(x: eventX, y: insets.top))
                    marker.addLine(to: CGPoint(x: eventX, y: size.height - insets.bottom))
                    graphics.stroke(marker, with: .color(.green.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    graphics.fill(Path(ellipseIn: CGRect(x: eventX - 4, y: eventY - 4, width: 8, height: 8)), with: .color(.green))
                }
            }
            LunarRulerCanvas(
                ticks: lunarTicks,
                displayInterval: plot.interval,
                topInset: JournalEntryWaveform.lunarRulerTopInset,
                rowSpacing: JournalEntryWaveform.lunarRulerRowSpacing,
                labelOffset: 15
            )
            JournalEntryPulseRulerCanvas(
                ticks: pulseTicks,
                displayInterval: plot.interval
            )
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            displayMegaUnits = min(displayMegaUnits + 1, JournalEntryWaveform.maximumMegaUnits)
                        }
                    }
                    .accessibilityLabel("Zoom waveform out")

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            displayMegaUnits = max(displayMegaUnits - 1, JournalEntryWaveform.minimumMegaUnits)
                        }
                    }
                    .accessibilityLabel("Zoom waveform in")
            }
        }
        .accessibilityLabel("Journal waveform")
        .task(id: waveformTaskID) {
            let context = context
            let contextService = services.sarosEventContextService
            let moonService = services.moonPhaseService
            let eclipseService = services.eclipseService
            let pulseSaros = pulseSaros
            let endDate = resolvedEndDate
            let displayDuration = JournalEntryWaveform.displayDuration(megaUnits: displayMegaUnits)
            let parabolaA = JournalWaveformSettings.currentParabolaA
            let options = JournalWaveformOptions(
                ignorePartialEclipses: false,
                mergeCloseSpikes: waveformMergeCloseSpikes,
                normalizedAmplitude: waveformNormalizedAmplitude,
                subdivisionDepth: clampedSubdivisionDepth,
                mergeThreshold: JournalWaveformSettings.mergeCloseSpikeThreshold,
                amplitudeMultiplier: clampedAmplitudeMultiplier
            )
            let generated = await Task.detached(priority: .userInitiated) { () -> (JournalEntryWaveformPlot, [LunarRulerTick], [SarosPulseTick]) in
                let spikes = (
                    try? contextService.waveformSpikes(
                        around: context.eventDate,
                        harmonicDepth: context.waveformHarmonicDepth,
                        displayDuration: displayDuration,
                        paddingDuration: 172_800
                    )
                ) ?? context.spikes
                let plot = JournalEntryWaveformPlot.make(
                    for: context,
                    endDate: endDate,
                    spikes: spikes,
                    displayDuration: displayDuration,
                    model: .parabola,
                    parabolaA: parabolaA,
                    options: options
                )
                let lunarTicks = LunarRulerTickBuilder.ticks(in: plot.interval, moonService: moonService)
                let resolvedPulseSaros: Int?
                if pulseSaros > 0 {
                    resolvedPulseSaros = pulseSaros
                } else {
                    resolvedPulseSaros = context.closestSpike?.saros ?? (try? SarosPulseCalculator.defaultActiveSaros(
                        at: context.eventDate,
                        eclipseService: eclipseService
                    ))
                }
                let pulseTicks: [SarosPulseTick]
                if let resolvedPulseSaros {
                    pulseTicks = (try? SarosPulseCalculator.ticks(
                        in: plot.interval,
                        saros: resolvedPulseSaros,
                        harmonicDepth: context.waveformHarmonicDepth,
                        eclipseService: eclipseService
                    )) ?? []
                } else {
                    pulseTicks = []
                }
                return (plot, lunarTicks, pulseTicks)
            }.value
            plot = generated.0
            lunarTicks = generated.1
            pulseTicks = generated.2
        }
    }

    private var waveformTaskID: String {
        [
            context.waveformCacheKey,
            "\(Int(resolvedEndDate.timeIntervalSince1970))",
            "\(Int((JournalWaveformSettings.currentParabolaA * 100).rounded()))",
            waveformMergeCloseSpikes ? "merged" : "raw",
            waveformNormalizedAmplitude ? "norm" : "weighted",
            "\(clampedSubdivisionDepth)",
            "\(Int((clampedAmplitudeMultiplier * 100).rounded()))",
            "\(displayMegaUnits)",
            "\(pulseSaros)"
        ].joined(separator: "-")
    }

    private var clampedSubdivisionDepth: Int {
        min(
            max(waveformSubdivisionDepth, JournalWaveformSettings.subdivisionDepthRange.lowerBound),
            JournalWaveformSettings.subdivisionDepthRange.upperBound
        )
    }

    private var clampedAmplitudeMultiplier: Double {
        min(
            max(waveformAmplitudeMultiplier, JournalWaveformSettings.amplitudeMultiplierRange.lowerBound),
            JournalWaveformSettings.amplitudeMultiplierRange.upperBound
        )
    }

    private var resolvedEndDate: Date {
        guard let endDate, endDate > context.eventDate else { return context.eventDate }
        return endDate
    }
}

private struct JournalEntryWaveformPlot {
    let interval: DateInterval
    let samples: [JournalEventWaveSample]
    let visibleSpikeGroups: [JournalEntryWaveformSpikeGroup]
    let midpointDates: [Date]
    let energyBySpikeID: [String: Double]
    let eventEnergy: Double
    let eventEndDate: Date
    let eventEndEnergy: Double
    let isPeriod: Bool
    let maxEnergy: Double

    static let empty = JournalEntryWaveformPlot(
        interval: DateInterval(start: Date(), duration: 86_400),
        samples: [],
        visibleSpikeGroups: [],
        midpointDates: [],
        energyBySpikeID: [:],
        eventEnergy: 0,
        eventEndDate: Date(),
        eventEndEnergy: 0,
        isPeriod: false,
        maxEnergy: 1
    )

    static func make(
        for context: JournalEventContext,
        endDate: Date? = nil,
        spikes: [JournalSpikeReference],
        displayDuration: TimeInterval = JournalEntryWaveform.displayDuration(megaUnits: JournalEntryWaveform.defaultMegaUnits),
        model: JournalWaveformModel = JournalWaveformModel.current,
        parabolaA: Double = JournalWaveformSettings.currentParabolaA,
        options: JournalWaveformOptions = .current
    ) -> JournalEntryWaveformPlot {
        let eventEndDate = {
            guard let endDate, endDate > context.eventDate else { return context.eventDate }
            return endDate
        }()
        let intervalCenter = context.eventDate.addingTimeInterval(
            max(eventEndDate.timeIntervalSince(context.eventDate), 0) / 2
        )
        let interval = JournalEventWaveform.displayInterval(
            centeredOn: intervalCenter,
            duration: displayDuration
        )
        let sortedSpikes = spikes.sorted { $0.date < $1.date }
        let field = JournalEventWaveform.field(
            spikes: sortedSpikes,
            model: model,
            parabolaA: parabolaA,
            options: options
        )
        let waveSamples = field.samples(
            in: interval,
            sampleCount: 1_024,
            spikes: sortedSpikes
        )
        let visibleSpikeGroups = field.components
            .filter { interval.contains($0.spike.date) }
            .sorted {
                if $0.spike.date != $1.spike.date {
                    return $0.spike.date < $1.spike.date
                }
                return $0.spike.rarity > $1.spike.rarity
            }
            .map {
                JournalEntryWaveformSpikeGroup(
                    primary: $0.spike,
                    contributors: $0.contributorSpikes
                )
            }
        let eventEnergy = field.energy(at: context.eventDate)
        let eventEndEnergy = field.energy(at: eventEndDate)
        let localMaxEnergy = waveSamples.points.map(\.energy).max() ?? eventEnergy
        let visibleSpikeMaxEnergy = visibleSpikeGroups
            .compactMap { waveSamples.eventEnergyByID[$0.primary.id] }
            .max() ?? 0
        let midpointDates = field.components
            .flatMap { [$0.period.leftBoundary, $0.period.rightBoundary] }
            .filter { interval.contains($0) }
            .sorted()
        let maxEnergy = max(localMaxEnergy, visibleSpikeMaxEnergy, eventEnergy, eventEndEnergy, 0.000_001)
        return JournalEntryWaveformPlot(
            interval: interval,
            samples: waveSamples.points,
            visibleSpikeGroups: visibleSpikeGroups,
            midpointDates: midpointDates,
            energyBySpikeID: waveSamples.eventEnergyByID,
            eventEnergy: eventEnergy,
            eventEndDate: eventEndDate,
            eventEndEnergy: eventEndEnergy,
            isPeriod: eventEndDate.timeIntervalSince(context.eventDate) > 0.5,
            maxEnergy: maxEnergy
        )
    }
}

private struct JournalEntryWaveformSpikeGroup {
    let primary: JournalSpikeReference
    let contributors: [JournalSpikeReference]
}

private extension JournalEventContext {
    var waveformHarmonicDepth: Int {
        spikes.map(\.harmonicDepth).max() ?? JournalSettings.supportedHarmonicDepth.upperBound
    }
}

private struct JournalWaveEventIcon: View {
    let signature: JournalWaveSignature
    var size: CGFloat = 18

    var body: some View {
        Text(signature.type.emoji)
            .font(.system(size: size))
            .frame(width: size + 4, height: size + 4)
            .accessibilityLabel(signature.type.title)
    }
}

private struct JournalWaveEventMetadataRow: View {
    let signature: JournalWaveSignature

    var body: some View {
        HStack(alignment: .center) {
            Text("Event")
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Text(signature.label)
                    .foregroundStyle(.primary)
                JournalWaveEventIcon(signature: signature, size: 18)
            }
        }
        .font(.subheadline)
    }
}

private enum JournalEntryWaveform {
    static let minimumMegaUnits = 1
    static let defaultMegaUnits = 4
    static let maximumMegaUnits = 12
    static let lunarRulerTopInset: CGFloat = 10
    static let lunarRulerRowSpacing: CGFloat = 15
    static let amplitudeScale: CGFloat = 0.34

    static func displayDuration(megaUnits: Int) -> TimeInterval {
        SarosPulseCalculator.averageDuration(for: .mega)
            * Double(min(max(megaUnits, minimumMegaUnits), maximumMegaUnits))
    }

    static func dotSize(for rarity: FlipRarity) -> CGFloat {
        switch rarity.baseRarity {
        case .mythic: 9
        case .legendary: 7.5
        case .epic: 6.5
        default: 6
        }
    }
}

private struct JournalEntryPulseRulerCanvas: View {
    let ticks: [SarosPulseTick]
    let displayInterval: DateInterval

    var body: some View {
        Canvas { context, size in
            guard displayInterval.duration > 0, !ticks.isEmpty else { return }

            let baseline = size.height - 8
            var lastXByUnit: [SarosPulseUnit: CGFloat] = [:]

            for tick in ticks where tick.unit.isRulerTick {
                let x = xPosition(for: tick.date, width: size.width)
                if tick.unit != .rollover,
                   let lastX = lastXByUnit[tick.unit],
                   abs(lastX - x) < 1.6 {
                    continue
                }
                lastXByUnit[tick.unit] = x

                var line = Path()
                line.move(to: CGPoint(x: x, y: baseline))
                line.addLine(to: CGPoint(x: x, y: baseline - tickHeight(for: tick.unit)))
                context.stroke(
                    line,
                    with: .color(tick.unit.color.opacity(opacity(for: tick.unit))),
                    lineWidth: lineWidth(for: tick.unit)
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func tickHeight(for unit: SarosPulseUnit) -> CGFloat {
        switch unit {
        case .rollover: 28
        case .giga: 22
        case .mega: 16
        case .kilo: 11
        case .saros, .mili, .nano: 0
        }
    }

    private func opacity(for unit: SarosPulseUnit) -> Double {
        switch unit {
        case .rollover: 0.9
        case .giga: 0.72
        case .mega: 0.58
        case .kilo: 0.44
        case .saros, .mili, .nano: 0
        }
    }

    private func lineWidth(for unit: SarosPulseUnit) -> CGFloat {
        switch unit {
        case .rollover: 1.3
        case .giga: 1.0
        case .mega: 0.85
        case .kilo: 0.65
        case .saros, .mili, .nano: 0
        }
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let ratio = min(max(date.timeIntervalSince(displayInterval.start) / displayInterval.duration, 0), 1)
        return CGFloat(ratio) * width
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
        waveSignature.momentumText
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
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        let url = MediaStorage.url(for: item)
                        JournalAsyncMediaImage(item: item, contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .background(Color(.secondarySystemBackground))
                            .contentShape(Rectangle())
                            .overlay {
                                MediaShareContextMenuOverlay(url: url)
                            }
                            .contextMenu {
                                ShareLink(item: url) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
        }
    }
}

private struct MediaShareContextMenuOverlay: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.url = url
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self, weak interaction] _ in
                let action = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    self?.presentShareSheet(from: interaction?.view)
                }
                return UIMenu(children: [action])
            }
        }

        private func presentShareSheet(from sourceView: UIView?) {
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = sourceView
                popover.sourceRect = sourceView?.bounds ?? .zero
            }
            topViewController()?.present(controller, animated: true)
        }

        private func topViewController() -> UIViewController? {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
            while let presented = controller?.presentedViewController {
                controller = presented
            }
            return controller
        }
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

private struct JournalTimingIconButton: View {
    let systemName: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.title3.weight(.semibold))
                    .frame(width: 26, height: 24)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(Color.accentColor)
            .frame(width: 58, height: 58)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor.opacity(0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
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

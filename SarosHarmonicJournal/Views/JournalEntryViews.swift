import AVFoundation
import AVKit
import CoreLocation
import CoreTransferable
import ImageIO
import PhotosUI
import QuickLook
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum JournalFeedTiming {
    static let nowThreshold: TimeInterval = 60
}

struct JournalEntryRow: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    let entry: JournalEntry
    let tags: [JournalTag]
    var now = Date()

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
                Text(entryDateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let remoteDeviceEmoji {
                    Text(remoteDeviceEmoji)
                        .font(.caption)
                }
                Spacer(minLength: 8)
                Text(relativeEventLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
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

    private var entryDateLabel: String {
        guard entry.eventDuration > SarosPulseCalculator.averageDuration(for: .mega) else {
            return JournalFormatters.dateTime.string(from: entry.eventDate)
        }
        let endDate = entry.effectiveEndDate
        if Calendar.current.isDate(entry.eventDate, inSameDayAs: endDate) {
            return "\(JournalFormatters.monthDay.string(from: entry.eventDate)) \(JournalFormatters.timeOfDay.string(from: entry.eventDate))-\(JournalFormatters.timeOfDay.string(from: endDate))"
        }
        return "\(JournalFormatters.dateTime.string(from: entry.eventDate)) - \(JournalFormatters.dateTime.string(from: endDate))"
    }

    private var relativeEventLabel: String {
        if abs(entry.eventDate.timeIntervalSince(now)) <= JournalFeedTiming.nowThreshold {
            return "now"
        }
        if entry.eventDate > now {
            return "\(feedRelativeDuration(entry.eventDate.timeIntervalSince(now))) left"
        }
        if entry.isOngoing(at: now) {
            return "\(feedRelativeDuration(now.timeIntervalSince(entry.eventDate))) running"
        }
        return "\(feedRelativeDuration(now.timeIntervalSince(entry.eventDate))) ago"
    }

    private func feedRelativeDuration(_ interval: TimeInterval) -> String {
        let duration = max(interval, 0)
        let yearDuration = SolarYearRuler.averageTropicalYearDuration()
        if duration > yearDuration {
            return "\(max(Int(duration / yearDuration), 1))y"
        }
        return duration.compactDuration
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
    @State private var previewDocumentURL: URL?

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

    private var documents: [JournalMediaItem] {
        entry.mediaItems.filter { $0.type == .document }
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

            if !documents.isEmpty {
                Section("Documents") {
                    ForEach(documents) { item in
                        let url = MediaStorage.url(for: item)
                        Button {
                            previewDocumentURL = url
                        } label: {
                            Label(url.lastPathComponent, systemImage: "doc")
                        }
                        .contextMenu {
                            ShareLink(item: url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
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
                    .frame(height: 230)
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
        .quickLookPreview($previewDocumentURL)
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
    @State private var isImportingDocument = false
    @State private var isCameraPresented = false
    @State private var isDocumentImporterPresented = false
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
        initialText: String? = nil,
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
        _noteText = State(initialValue: draft?.text ?? initialText ?? template.text)
        _emoji = State(initialValue: draft?.emoji ?? template.resolvedEmoji)
        _mediaItems = State(initialValue: draft?.mediaItems ?? initialMediaItems)
        _weatherCode = State(initialValue: draft?.weatherCode ?? lastWeather.code)
        _weatherEmoji = State(initialValue: draft?.weatherEmoji ?? lastWeather.emoji)
        _temperatureC = State(initialValue: draft?.temperatureC ?? lastWeather.temperatureC)
        _selectedTagIDs = State(initialValue: Set(draft?.tagIDs ?? template.resolvedTagIDs))
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

                    Button {
                        isDocumentImporterPresented = true
                    } label: {
                        JournalEntryActionIcon(systemName: "doc.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .disabled(isImportingDocument)
                    .accessibilityLabel("Attach document")
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
                        .frame(height: 190)
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
                .disabled(isSaving || isLoadingPhoto || isImportingDocument || context == nil)
            }
        }
        .navigationTitle(editingEntry == nil ? "Record" : "Edit record")
        .refreshable {
            await refreshFromRelay()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    closeWithoutBlockingDraftPersistence()
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
                .disabled(isSaving || isLoadingPhoto || isImportingDocument || context == nil)
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
        .fileImporter(
            isPresented: $isDocumentImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            Task { await importDocuments(from: result) }
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
                let fileExtension = preferredFileExtension(for: item)
                let mediaItem = try await Task.detached(priority: .utility) {
                    try MediaStorage.saveData(
                        pickedPhoto.data,
                        fileExtension: fileExtension,
                        type: .photo
                    )
                }.value
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
                didSaveEntry = true
                JournalWeatherDefaults.save(code: weatherCode, emoji: weatherEmoji, temperatureC: temperatureC)
                dismiss()
                Task {
                    await services.notificationScheduler.scheduleFutureEntryNotification(for: editingEntry)
                    await deleteMediaItemsInBackground(removedMediaItems)
                }
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
            Task {
                await services.notificationScheduler.scheduleFutureEntryNotification(for: entry)
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
    private func importDocuments(from result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }

            isImportingDocument = true
            defer { isImportingDocument = false }

            for url in urls {
                let didStartAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let fileExtension = url.pathExtension.isEmpty ? "bin" : url.pathExtension
                let item = try await Task.detached(priority: .utility) {
                    try MediaStorage.saveFile(
                        at: url,
                        fileExtension: fileExtension,
                        type: .document
                    )
                }.value
                mediaItems.append(item)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
    private func closeWithoutBlockingDraftPersistence() {
        guard editingEntry == nil, !didSaveEntry, !didPersistDraft else {
            dismiss()
            return
        }
        didPersistDraft = true
        dismiss()
        Task { @MainActor in
            persistDraft()
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

    private func deleteMediaItemsInBackground(_ items: [JournalMediaItem]) async {
        await Task.detached(priority: .utility) {
            items.forEach(MediaStorage.delete)
        }.value
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
    var text: String? = nil
    var mediaItems: [JournalMediaItem] = []
    var latitude: Double?
    var longitude: Double?
}

private struct JournalTemplateRetroactiveMirrorRequest: Identifiable {
    let id = UUID()
    let startDate: Date
    let template: JournalTemplateSeed
    let image: UIImage
    var latitude: Double?
    var longitude: Double?
}

private struct ContinuousActivityLoggingPanel: View {
    let session: ContinuousActivitySession?
    let onBegin: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if let session {
                ContinuousActivitySessionGlyphBlock(session: session)
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

private struct ContinuousActivitySessionGlyphBlock: View {
    let session: ContinuousActivitySession

    private var fallbackSelection: SarosCountdownSelection {
        session.displayEndDate.map {
            SarosCountdownScale.normalized(forDuration: $0.timeIntervalSince(session.startDate))
        } ?? SarosCountdownSelection.defaultSaros
    }

    private var selection: SarosCountdownSelection {
        session.sarosCountdownSelection ?? fallbackSelection
    }

    private var direction: SarosCountdownDirection {
        session.isCountdown ? .down : .up
    }

    private var refreshInterval: TimeInterval {
        guard !session.isCompleted else { return 60 }
        return max(selection.scale.leastSignificantDigitDuration, 1.0 / 60.0)
    }

    var body: some View {
        TimelineView(.periodic(from: session.startDate, by: refreshInterval)) { timeline in
            let displayDate = session.completedAt ?? timeline.date
            let reading = SarosCountdownCalculator.reading(
                startDate: session.startDate,
                endDate: session.displayEndDate,
                now: displayDate,
                direction: direction,
                selection: selection
            )

            HStack(spacing: 14) {
                SarosCountdownGlyphTimer(reading: reading, size: 78)

                VStack(alignment: .leading, spacing: 4) {
                    Text(sessionTitle)
                        .font(.headline)
                        .foregroundStyle(reading.scale.color)
                    Text(reading.octalAddress)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private var sessionTitle: String {
        "\(session.template.resolvedStaticEmoji) \(session.template.name.nilIfBlank ?? "Activity")"
    }
}

private struct ActiveActivityDraftPager: View {
    let sessions: [ContinuousActivitySession]
    @Binding var selectedID: UUID?
    let height: CGFloat
    let recordingActivityID: UUID?
    let isRecordingAudio: Bool
    let onLibrary: ([PhotosPickerItem]) -> Void
    let onCamera: () -> Void
    let onDocument: () -> Void
    let onToggleAudio: () -> Void
    let onStop: (ContinuousActivitySession) -> Void
    let onEditNotes: (ContinuousActivitySession) -> Void
    let onRemoveMedia: (ContinuousActivitySession, JournalMediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(sessions) { session in
                            ActiveActivityDraftPage(
                                session: session,
                                noteText: session.draftText ?? "",
                                height: cardHeight,
                                isRecordingAudio: isRecordingAudio && recordingActivityID == session.id,
                                onLibrary: onLibrary,
                                onCamera: onCamera,
                                onDocument: onDocument,
                                onToggleAudio: onToggleAudio,
                                onStop: { onStop(session) },
                                onEditNotes: { onEditNotes(session) },
                                onRemoveMedia: { item in onRemoveMedia(session, item) }
                            )
                            .frame(width: proxy.size.width)
                            .id(session.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $selectedID)
                .frame(height: cardHeight)
            }
            .frame(height: cardHeight)
            .onAppear {
                selectedID = selectedID ?? sessions.first?.id
            }

            ActivitySessionSelectorStrip(
                sessions: sessions,
                selectedID: $selectedID
            )
        }
        .frame(height: height)
    }

    private var cardHeight: CGFloat {
        max(360, height - 44)
    }
}

private struct ActiveActivityDraftPage: View {
    let session: ContinuousActivitySession
    let noteText: String
    let height: CGFloat
    let isRecordingAudio: Bool
    let onLibrary: ([PhotosPickerItem]) -> Void
    let onCamera: () -> Void
    let onDocument: () -> Void
    let onToggleAudio: () -> Void
    let onStop: () -> Void
    let onEditNotes: () -> Void
    let onRemoveMedia: (JournalMediaItem) -> Void

    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ContinuousActivitySessionGlyphBlock(session: session)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(role: session.isCompleted ? nil : .destructive, action: onStop) {
                    Image(systemName: session.isCompleted ? "checkmark.circle.fill" : "stop.circle.fill")
                        .font(.title2.weight(.semibold))
                        .frame(width: 42, height: 42)
                        .foregroundStyle(session.isCompleted ? Color.green : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.isCompleted ? "Open completed activity" : "Stop activity")
            }

            HStack(spacing: 12) {
                PhotosPicker(selection: $photoItems, matching: .images) {
                    JournalEntryActionIcon(systemName: "photo.on.rectangle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add image")
                .onChange(of: photoItems) { _, newItems in
                    guard !newItems.isEmpty else { return }
                    onLibrary(newItems)
                    photoItems = []
                }

                Button(action: onCamera) {
                    JournalEntryActionIcon(systemName: "camera.viewfinder")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Capture photo")

                Button(action: onToggleAudio) {
                    JournalEntryActionIcon(
                        systemName: isRecordingAudio ? "stop.circle.fill" : "mic.circle.fill",
                        tint: isRecordingAudio ? .red : .accentColor
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRecordingAudio ? "Stop audio" : "Record audio")

                Button(action: onDocument) {
                    JournalEntryActionIcon(systemName: "doc.badge.plus")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach document")
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Button {
                onEditNotes()
            } label: {
                Text(noteText.nilIfBlank ?? "Notes")
                    .font(.callout)
                    .foregroundStyle(noteText.nilIfBlank == nil ? Color.primary : Color.secondary)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Edit notes")
            .frame(maxHeight: .infinity)

            ActivityDraftMediaStrip(items: session.mediaItems, onRemove: onRemoveMedia)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct ActiveActivityNoteEditor: View {
    let session: ContinuousActivitySession
    let initialText: String
    let onTextChange: (String) -> Void
    let onDone: () -> Void

    @State private var draftText: String
    @FocusState private var isFocused: Bool

    init(
        session: ContinuousActivitySession,
        initialText: String,
        onTextChange: @escaping (String) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.session = session
        self.initialText = initialText
        self.onTextChange = onTextChange
        self.onDone = onDone
        _draftText = State(initialValue: initialText)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(session.template.name.nilIfBlank ?? "Activity notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Done", action: close)
                    .font(.caption.weight(.semibold))
            }

            TextEditor(text: $draftText)
                .font(.body)
                .lineSpacing(4)
                .textInputAutocapitalization(.sentences)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.visible)
                .padding(8)
                .frame(height: 260)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
        .padding(.horizontal, 12)
        .onAppear {
            DispatchQueue.main.async {
                isFocused = true
            }
        }
        .onChange(of: draftText) { _, text in
            onTextChange(text)
        }
        .onChange(of: session.id) { _, _ in
            draftText = initialText
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done", action: close)
            }
        }
    }

    private func close() {
        isFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        onDone()
    }
}

private struct ActivityDraftMediaStrip: View {
    let items: [JournalMediaItem]
    let onRemove: (JournalMediaItem) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            if items.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "photo.stack")
                    Image(systemName: "waveform")
                    Image(systemName: "mic.circle")
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary.opacity(0.65))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items) { item in
                            ActivityDraftMediaThumbnail(item: item) {
                                onRemove(item)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .frame(height: 70)
    }
}

private struct ActivitySessionSelectorStrip: View {
    let sessions: [ContinuousActivitySession]
    @Binding var selectedID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessions) { session in
                    Button {
                        withAnimation(.snappy) {
                            selectedID = session.id
                        }
                    } label: {
                        ActivitySessionSelectorChip(
                            session: session,
                            isSelected: selectedID == session.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct ActivitySessionSelectorChip: View {
    let session: ContinuousActivitySession
    let isSelected: Bool

    private var fallbackSelection: SarosCountdownSelection {
        session.displayEndDate.map {
            SarosCountdownScale.normalized(forDuration: $0.timeIntervalSince(session.startDate))
        } ?? SarosCountdownSelection.defaultSaros
    }

    private var selection: SarosCountdownSelection {
        session.sarosCountdownSelection ?? fallbackSelection
    }

    private var direction: SarosCountdownDirection {
        session.isCountdown ? .down : .up
    }

    private var refreshInterval: TimeInterval {
        guard !session.isCompleted else { return 60 }
        return max(selection.scale.leastSignificantDigitDuration, 1.0 / 60.0)
    }

    var body: some View {
        TimelineView(.periodic(from: session.startDate, by: refreshInterval)) { timeline in
            let displayDate = session.completedAt ?? timeline.date
            let reading = SarosCountdownCalculator.reading(
                startDate: session.startDate,
                endDate: session.displayEndDate,
                now: displayDate,
                direction: direction,
                selection: selection
            )

            HStack(spacing: 8) {
                Text(session.template.resolvedStaticEmoji)
                    .font(.title3)
                SarosCountdownGlyphTimer(reading: reading, size: 28, showsDots: false)
                    .frame(width: 34, height: 34)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor.opacity(0.20) : Color(.secondarySystemGroupedBackground),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(session.template.previewTitle)
            .accessibilityValue(reading.octalAddress)
        }
    }
}

private struct ActivityDraftMediaThumbnail: View {
    let item: JournalMediaItem
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if item.type.isImage {
                    JournalAsyncMediaImage(item: item, contentMode: .fill)
                } else {
                    Image(systemName: systemImage(for: item.type))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.thinMaterial)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .accessibilityLabel("Remove media")
        }
        .frame(width: 62, height: 60)
    }
}

private struct JournalRecordTopActionBar: View {
    let hasDraft: Bool
    let onStart: () -> Void
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            JournalRecordTopActionButton(
                title: "Start",
                systemName: "play.circle.fill",
                tint: .accentColor,
                action: onStart
            )

            if hasDraft {
                JournalRecordTopActionButton(
                    title: "Resume",
                    systemName: "arrow.uturn.forward.circle.fill",
                    tint: .secondary,
                    action: onResume
                )
            }
        }
    }
}

private struct JournalRecordTopActionButton: View {
    let title: String
    let systemName: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(tint.opacity(0.32), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private enum JournalRecordAction: String, CaseIterable, Identifiable {
    case instant
    case timer
    case countdown
    case retroactive
    case draft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instant: "Instant"
        case .timer: "Timer"
        case .countdown: "Countdown"
        case .retroactive: "Retroactive"
        case .draft: "Draft"
        }
    }

    var systemName: String {
        switch self {
        case .instant: "bolt.circle"
        case .timer: "stopwatch"
        case .countdown: "timer"
        case .retroactive: "clock.arrow.circlepath"
        case .draft: "arrow.uturn.forward.circle"
        }
    }
}

private struct JournalRecordActionGrid: View {
    let selectedAction: JournalRecordAction?
    let hasDraft: Bool
    let onSelect: (JournalRecordAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(JournalRecordAction.allCases) { action in
                JournalRecordSquareActionButton(
                    action: action,
                    isSelected: selectedAction == action,
                    isEnabled: action != .draft || hasDraft
                ) {
                    onSelect(action)
                }

                if action.id != JournalRecordAction.allCases.last?.id {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1)
                        .padding(.vertical, 8)
                }
            }
        }
        .frame(height: 58)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct JournalRecordIdleActionGrid: View {
    let selectedAction: JournalRecordAction?
    let hasDraft: Bool
    let onSelect: (JournalRecordAction) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var primaryActions: [JournalRecordAction] {
        [.instant, .timer, .countdown, .retroactive]
    }

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(primaryActions) { action in
                    JournalRecordLargeActionButton(
                        action: action,
                        isSelected: selectedAction == action,
                        isEnabled: true
                    ) {
                        onSelect(action)
                    }
                }
            }

            JournalRecordLargeActionButton(
                action: .draft,
                isSelected: selectedAction == .draft,
                isEnabled: hasDraft
            ) {
                onSelect(.draft)
            }
        }
    }
}

private struct JournalRecordSquareActionButton: View {
    let action: JournalRecordAction
    let isSelected: Bool
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: action.systemName)
                .font(.title.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(isSelected ? Color.accentColor : Color.clear)
            .opacity(isEnabled ? 1 : 0.38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(action.title)
    }
}

private struct JournalRecordLargeActionButton: View {
    let action: JournalRecordAction
    let isSelected: Bool
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Image(systemName: action.systemName)
                    .font(.title.weight(.semibold))
                Text(action.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.38)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(action.title)
    }
}

private struct JournalActivityTemplatePickerView: View {
    @Environment(\.dismiss) private var dismiss

    let templates: [JournalTemplate]
    let onNow: (JournalTemplateCaptureRequest) -> Void
    let onCountdown: (JournalTemplateSeed, TimeInterval, SarosCountdownSelection) -> Void
    let onTimer: (JournalTemplateSeed, SarosCountdownSelection) -> Void
    let onRetroactive: (JournalTemplateRetroactiveMirrorRequest) -> Void

    @State private var selectedTemplate: JournalTemplateSeed?
    @State private var currentRandomEmoji = JournalRecordMarkers.random()
    @State private var retroactivePhotoItem: PhotosPickerItem?
    @State private var isLoadingRetroactivePhoto = false
    @State private var errorMessage: String?

    private var templateGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 74), spacing: 12)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: templateGridColumns, spacing: 12) {
                    randomActivityTemplateCell()

                    ForEach(templates) { template in
                        activityTemplateCell(JournalTemplateSeed(template: template))
                    }
                }
                .padding(.horizontal, 26)

                if isLoadingRetroactivePhoto {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading photo")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Start")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
        .onChange(of: retroactivePhotoItem) { _, item in
            guard let item, let selectedTemplate else { return }
            Task {
                await importRetroactivePhoto(item, template: selectedTemplate)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 539_000_000)
                currentRandomEmoji = JournalRecordMarkers.random()
            }
        }
    }

    @ViewBuilder
    private func randomActivityTemplateCell() -> some View {
        let isSelected = selectedTemplate?.id == JournalTemplateSeed.randomID
        let frozenTemplate = isSelected ? selectedTemplate : nil
        let displayEmoji = frozenTemplate?.resolvedStaticEmoji ?? currentRandomEmoji

        VStack(spacing: 8) {
            Button {
                withAnimation(.snappy) {
                    selectedTemplate = isSelected ? nil : JournalTemplateSeed.random(emoji: currentRandomEmoji)
                }
            } label: {
                JournalTemplateGridTile(
                    title: "Random",
                    emoji: displayEmoji
                )
            }
            .buttonStyle(.plain)

            if let frozenTemplate, isSelected {
                JournalActivityTemplateActionPopover(
                    isLoadingRetroactivePhoto: isLoadingRetroactivePhoto,
                    retroactivePhotoItem: $retroactivePhotoItem,
                    onNow: {
                        let now = Date()
                        onNow(JournalTemplateCaptureRequest(
                            startDate: now,
                            endDate: now,
                            template: frozenTemplate
                        ))
                        dismiss()
                    },
                    onCountdown: { duration, selection in
                        onCountdown(frozenTemplate, duration, selection)
                        dismiss()
                    },
                    onTimer: {
                        onTimer(frozenTemplate, .timerDefault)
                        dismiss()
                    }
                )
                .zIndex(1)
                .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
            }
        }
        .zIndex(isSelected ? 20 : 0)
    }

    @ViewBuilder
    private func activityTemplateCell(_ template: JournalTemplateSeed) -> some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.snappy) {
                    selectedTemplate = selectedTemplate?.id == template.id ? nil : template
                }
            } label: {
                JournalTemplateGridTile(
                    title: template.previewTitle,
                    emoji: template.resolvedStaticEmoji
                )
            }
            .buttonStyle(.plain)

            if selectedTemplate?.id == template.id {
                JournalActivityTemplateActionPopover(
                    isLoadingRetroactivePhoto: isLoadingRetroactivePhoto,
                    retroactivePhotoItem: $retroactivePhotoItem,
                    onNow: {
                        let now = Date()
                        onNow(JournalTemplateCaptureRequest(
                            startDate: now,
                            endDate: now,
                            template: template
                        ))
                        dismiss()
                    },
                    onCountdown: { duration, selection in
                        onCountdown(template, duration, selection)
                        dismiss()
                    },
                    onTimer: {
                        onTimer(template, .timerDefault)
                        dismiss()
                    }
                )
                .zIndex(1)
                .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
            }
        }
        .zIndex(selectedTemplate?.id == template.id ? 20 : 0)
    }

    @MainActor
    private func importRetroactivePhoto(_ item: PhotosPickerItem, template: JournalTemplateSeed) async {
        isLoadingRetroactivePhoto = true
        errorMessage = nil
        defer {
            isLoadingRetroactivePhoto = false
            retroactivePhotoItem = nil
        }

        do {
            guard let pickedPhoto = try await item.loadTransferable(type: JournalPickedPhotoTransfer.self),
                  let image = UIImage(data: pickedPhoto.data) else {
                errorMessage = "Photo unavailable."
                return
            }
            let metadata = JournalImportedPhotoMetadataReader.read(from: pickedPhoto.data)
            let date = metadata.date ?? Date()
            onRetroactive(JournalTemplateRetroactiveMirrorRequest(
                startDate: date,
                template: template,
                image: MirrorCameraView.preparedImportedImage(image),
                latitude: metadata.latitude,
                longitude: metadata.longitude
            ))
            dismiss()
        } catch {
            errorMessage = "Photo import failed."
        }
    }
}

private struct JournalActivityTemplateActionPopover: View {
    let isLoadingRetroactivePhoto: Bool
    @Binding var retroactivePhotoItem: PhotosPickerItem?
    let onNow: () -> Void
    let onCountdown: (TimeInterval, SarosCountdownSelection) -> Void
    let onTimer: () -> Void

    @State private var isCountdownExpanded = false
    @State private var selectedCountdownDuration: TimeInterval = 0

    var body: some View {
        VStack(spacing: 10) {
            if isCountdownExpanded {
                JournalCompactCountdownPeriodSelector(
                    duration: selectedCountdownDuration,
                    onSet: { duration in
                        selectedCountdownDuration = duration
                    },
                    onStart: {
                        guard selectedCountdownDuration > 0 else { return }
                        onCountdown(selectedCountdownDuration, countdownSelection)
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 8), count: 2), spacing: 8) {
                    JournalActivityCompactActionButton(
                        title: "Instant",
                        systemName: "bolt.circle",
                        action: onNow
                    )

                    JournalActivityCompactActionButton(
                        title: "Countdown",
                        systemName: "timer"
                    ) {
                        withAnimation(.snappy) {
                            isCountdownExpanded = true
                        }
                    }

                    JournalActivityCompactActionButton(
                        title: "Timer",
                        systemName: "stopwatch",
                        action: onTimer
                    )

                    PhotosPicker(selection: $retroactivePhotoItem, matching: .images) {
                        JournalActivityCompactActionIcon(systemName: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingRetroactivePhoto)
                    .accessibilityLabel("Retroactive")
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .top) {
            JournalTooltipTriangle()
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 14, height: 8)
                .offset(y: -7)
        }
        .frame(width: 124)
    }

    private var countdownSelection: SarosCountdownSelection {
        SarosCountdownScale.normalized(forDuration: selectedCountdownDuration)
    }
}

private struct JournalActivityCompactActionButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            JournalActivityCompactActionIcon(systemName: systemName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct JournalCompactCountdownPeriodSelector: View {
    let duration: TimeInterval
    let onSet: (TimeInterval) -> Void
    let onStart: () -> Void

    @State private var selectedUnit = JournalCountdownQuickDuration(title: "S", accessibilityTitle: "1 Saros", unit: .saros)
    @State private var selectedCount = 0

    private let options: [JournalCountdownQuickDuration] = [
        JournalCountdownQuickDuration(title: "Ms", accessibilityTitle: "1 Megasaros", unit: .mega),
        JournalCountdownQuickDuration(title: "S", accessibilityTitle: "1 Saros", unit: .saros),
        JournalCountdownQuickDuration(title: "Ks", accessibilityTitle: "1 Kilosaros", unit: .kilo),
        JournalCountdownQuickDuration(title: "ms", accessibilityTitle: "1 Milisaros", unit: .mili)
    ]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    unitButton(option)
                }
            }

            selectorRow
        }
        .padding(8)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            syncInitialCount()
        }
    }

    private func unitButton(_ option: JournalCountdownQuickDuration) -> some View {
        let isSelected = selectedUnit.id == option.id
        return Button {
            select(option)
        } label: {
            Text(option.title)
                .font(.callout.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.accessibilityTitle)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var selectorRow: some View {
        HStack(spacing: 8) {
            Stepper(value: unitCountBinding, in: 0...999) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(unitCount)")
                        .font(.callout.monospacedDigit().weight(.semibold))
                    Text(durationText)
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(duration > 0 ? Color.secondary : Color.secondary.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }

            Button(action: onStart) {
                Text("Start")
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(width: 58, height: 38)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(duration <= 0)
            .opacity(duration <= 0 ? 0.45 : 1)
            .accessibilityLabel("Start countdown")
        }
    }

    private func select(_ option: JournalCountdownQuickDuration) {
        selectedUnit = option
        let count = max(selectedCount, duration > 0 ? 1 : 0)
        selectedCount = count
        onSet(Double(count) * option.duration)
    }

    private var unitCount: Int {
        selectedCount
    }

    private var unitCountBinding: Binding<Int> {
        Binding {
            unitCount
        } set: { newValue in
            let count = max(newValue, 0)
            selectedCount = count
            onSet(Double(count) * selectedUnit.duration)
        }
    }

    private var durationText: String {
        guard duration > 0 else {
            return "Choose duration"
        }
        return SarosDurationUnitFormatter.verboseDuration(duration, maxUnits: 3)
    }

    private func syncInitialCount() {
        guard selectedCount == 0, duration > 0 else { return }
        selectedCount = max(Int(round(duration / selectedUnit.duration)), 1)
    }
}

private struct JournalCountdownQuickDuration: Identifiable {
    let title: String
    let accessibilityTitle: String
    let unit: SarosPulseUnit

    var id: String { title }
    var duration: TimeInterval { SarosPulseCalculator.averageDuration(for: unit) }
}

private struct JournalActivityCompactActionIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.title2.weight(.semibold))
            .frame(width: 48, height: 48)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct JournalTooltipTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct JournalTemplatesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \JournalTag.createdAt, order: .forward) private var tags: [JournalTag]
    @Query(sort: \JournalTemplate.createdAt, order: .forward) private var templates: [JournalTemplate]
    @Query(sort: \JournalEntryDraft.updatedAt, order: .reverse) private var entryDrafts: [JournalEntryDraft]

    @AppStorage(ContinuousActivityLogger.sessionKey) private var activitySessionData = Data()

    @StateObject private var audioRecorder = AudioRecorder()
    @State private var captureRequest: JournalTemplateCaptureRequest?
    @State private var retroactiveMirrorRequest: JournalTemplateRetroactiveMirrorRequest?
    @State private var selectedEntryDraft: JournalEntryDraft?
    @State private var draft: JournalTemplateDraft?
    @State private var selectedActivityID: UUID?
    @State private var editingActivityNotesID: UUID?
    @State private var recordingActivityID: UUID?
    @State private var selectedInlineTemplate: JournalTemplateSeed?
    @State private var selectedRecordAction: JournalRecordAction?
    @State private var selectedCountdownDuration: TimeInterval = 0
    @State private var isCountdownDurationConfirmed = false
    @State private var inlineRandomEmoji = JournalRecordMarkers.random()
    @State private var inlineRetroactivePhotoItem: PhotosPickerItem?
    @State private var isLoadingInlineRetroactivePhoto = false
    @State private var inlineGridErrorMessage: String?
    @State private var isTemplatePickerPresented = false
    @State private var isTemplateManagerPresented = false
    @State private var isActivityCameraPresented = false
    @State private var isActivityDocumentImporterPresented = false
    @State private var errorMessage: String?

    private var activeDraft: JournalEntryDraft? {
        entryDrafts.first
    }

    private var activitySessions: [ContinuousActivitySession] {
        ContinuousActivityLogger.sessions(from: activitySessionData)
    }

    private var selectedActivitySession: ContinuousActivitySession? {
        guard !activitySessions.isEmpty else { return nil }
        if let selectedActivityID,
           let selected = activitySessions.first(where: { $0.id == selectedActivityID }) {
            return selected
        }
        return activitySessions.first
    }

    private var editingActivityNotesSession: ContinuousActivitySession? {
        guard let editingActivityNotesID else { return nil }
        return activitySessions.first { $0.id == editingActivityNotesID }
    }

    private var templateGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 74), spacing: 12)]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color(.systemGroupedBackground)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }

                VStack(alignment: .leading, spacing: 18) {
                    recordActionControls

                    if !activitySessions.isEmpty {
                        ActiveActivityDraftPager(
                            sessions: activitySessions,
                            selectedID: selectedActivityBinding,
                            height: activityPagerHeight(in: proxy.size.height),
                            recordingActivityID: recordingActivityID,
                            isRecordingAudio: audioRecorder.isRecording,
                            onLibrary: { items in
                                Task {
                                    await loadActivityPhotos(from: items)
                                }
                            },
                            onCamera: { isActivityCameraPresented = true },
	                            onDocument: { isActivityDocumentImporterPresented = true },
	                            onToggleAudio: toggleActivityAudio,
	                            onStop: { session in stopActivityLogging(sessionID: session.id) },
	                            onEditNotes: { session in
	                                withAnimation(.snappy(duration: 0.18)) {
	                                    editingActivityNotesID = session.id
	                                }
	                            },
                            onRemoveMedia: { session, item in
                                ContinuousActivityLogger.removeMedia(item, from: session.id)
                                MediaStorage.delete(item)
                            }
                        )
                    } else {
                        idleRecordStatus
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if shouldShowTemplateGrid {
                    templateSelectionOverlay
                        .zIndex(4)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            if let session = editingActivityNotesSession {
                ActiveActivityNoteEditor(
                    session: session,
                    initialText: session.draftText ?? "",
                    onTextChange: { text in
                        ContinuousActivityLogger.updateDraft(sessionID: session.id, text: text)
                    },
                    onDone: closeActivityNoteEditor
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Record")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isTemplateManagerPresented = true
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .accessibilityLabel("Templates")
            }
        }
        .sheet(isPresented: $isTemplatePickerPresented) {
            NavigationStack {
                JournalActivityTemplatePickerView(
                    templates: templates,
                    onNow: { request in
                        captureRequest = request
                        isTemplatePickerPresented = false
                    },
                    onCountdown: { template, duration, selection in
                        beginCountdown(
                            template: template,
                            duration: duration,
                            selection: selection
                        )
                        isTemplatePickerPresented = false
                    },
                    onTimer: { template, selection in
                        beginActivityLogging(template: template, selection: selection)
                        isTemplatePickerPresented = false
                    },
                    onRetroactive: { request in
                        retroactiveMirrorRequest = request
                        isTemplatePickerPresented = false
                    }
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isTemplateManagerPresented) {
            NavigationStack {
                JournalTemplateManagerView(
                    templates: templates,
                    onAdd: {
                        isTemplateManagerPresented = false
                        DispatchQueue.main.async {
                            draft = JournalTemplateDraft()
                        }
                    },
                    onEdit: { template in
                        isTemplateManagerPresented = false
                        DispatchQueue.main.async {
                            draft = JournalTemplateDraft(template: template)
                        }
                    },
                    onDelete: deleteTemplate
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $captureRequest) { request in
            NavigationStack {
                JournalEntryCaptureView(
                    recordStartedAt: request.startDate,
                    eventEndDate: request.endDate,
                    template: request.template,
                    initialText: request.text,
                    initialMediaItems: request.mediaItems,
                    initialLatitude: request.latitude,
                    initialLongitude: request.longitude
                )
            }
        }
        .fullScreenCover(item: $retroactiveMirrorRequest) { request in
            MirrorCameraView(initialReviewImage: request.image) { media in
                completeRetroactiveMirror(request: request, media: media)
            }
        }
        .fullScreenCover(isPresented: $isActivityCameraPresented) {
            MirrorCameraView { media in
                addActivityCameraMedia(media)
            }
        }
        .fileImporter(
            isPresented: $isActivityDocumentImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            Task { await importActivityDocuments(from: result) }
        }
        .sheet(item: $selectedEntryDraft) { draft in
            NavigationStack {
                JournalEntryCaptureView(draft: draft)
            }
        }
        .sheet(item: $draft) { draft in
            NavigationStack {
                JournalTemplateEditorView(draft: draft, tags: tags) { savedDraft in
                    saveTemplate(savedDraft)
                }
            }
        }
        .onChange(of: activitySessionData) { _, _ in
            normalizeSelectedActivity()
            syncActivityWidget()
        }
        .onChange(of: selectedActivityID) { _, _ in
            syncActivityWidget()
        }
        .onChange(of: inlineRetroactivePhotoItem) { _, item in
            guard let item, let selectedInlineTemplate else { return }
            Task {
                await importInlineRetroactivePhoto(item, template: selectedInlineTemplate)
            }
        }
        .onChange(of: audioRecorder.lastItem) { _, item in
            guard let item else { return }
            let targetID = recordingActivityID ?? selectedActivitySession?.id
            guard let targetID else { return }
            ContinuousActivityLogger.appendMedia(item, to: targetID)
            recordingActivityID = nil
            _ = audioRecorder.consumeLastItem()
        }
        .alert("Record failed", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: shouldShuffleInlineRandomEmoji) {
            guard shouldShuffleInlineRandomEmoji else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 539_000_000)
                inlineRandomEmoji = JournalRecordMarkers.random()
            }
        }
    }

    private var recordActionControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if activitySessions.isEmpty {
                JournalRecordIdleActionGrid(
                    selectedAction: selectedRecordAction,
                    hasDraft: activeDraft != nil,
                    onSelect: selectRecordAction
                )
                .padding(.horizontal, 6)
                .transition(.opacity)
            } else {
                JournalRecordActionGrid(
                    selectedAction: selectedRecordAction,
                    hasDraft: activeDraft != nil,
                    onSelect: selectRecordAction
                )
                .padding(.horizontal, 6)
                .transition(.opacity)
            }

            if selectedRecordAction == .countdown && !isCountdownDurationConfirmed {
                JournalCompactCountdownPeriodSelector(
                    duration: selectedCountdownDuration,
                    onSet: { duration in
                        selectedCountdownDuration = duration
                    },
                    onStart: {
                        guard selectedCountdownDuration > 0 else { return }
                        withAnimation(.snappy) {
                            isCountdownDurationConfirmed = true
                        }
                    }
                )
                .padding(.horizontal, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
    }

    private var templateSelectionGrid: some View {
        LazyVGrid(columns: templateGridColumns, spacing: 10) {
            inlineRandomActivityTemplateCell()

            ForEach(templates) { template in
                inlineActivityTemplateCell(template)
            }
        }
        .padding(.horizontal, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var templateSelectionOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                templateSelectionGrid
                    .padding(10)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 286)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, templateOverlayTopPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var templateOverlayTopPadding: CGFloat {
        if activitySessions.isEmpty {
            return selectedRecordAction == .countdown && !isCountdownDurationConfirmed ? 406 : 306
        }
        return selectedRecordAction == .countdown && !isCountdownDurationConfirmed ? 188 : 92
    }

    private var idleRecordStatus: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isLoadingInlineRetroactivePhoto {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading photo")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            if let inlineGridErrorMessage {
                Text(inlineGridErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var shouldShowTemplateGrid: Bool {
        switch selectedRecordAction {
        case .instant, .timer, .retroactive:
            true
        case .countdown:
            isCountdownDurationConfirmed && selectedCountdownDuration > 0
        case .draft, nil:
            false
        }
    }

    private var shouldShuffleInlineRandomEmoji: Bool {
        shouldShowTemplateGrid
    }

    private func selectRecordAction(_ action: JournalRecordAction) {
        if action == .draft {
            activeDraft.map { selectedEntryDraft = $0 }
            return
        }

        withAnimation(.snappy) {
            selectedInlineTemplate = nil
            selectedRecordAction = selectedRecordAction == action ? nil : action
            if action != .countdown {
                selectedCountdownDuration = 0
                isCountdownDurationConfirmed = false
            } else if selectedRecordAction != .countdown {
                selectedCountdownDuration = 0
                isCountdownDurationConfirmed = false
            }
        }
    }

    @ViewBuilder
    private func inlineRandomActivityTemplateCell() -> some View {
        let displayEmoji = inlineRandomEmoji
        let template = JournalTemplateSeed.random(emoji: displayEmoji)

        if selectedRecordAction == .retroactive {
            PhotosPicker(selection: $inlineRetroactivePhotoItem, matching: .images) {
                JournalTemplateGridTile(
                    title: "Random",
                    emoji: displayEmoji
                )
            }
            .simultaneousGesture(TapGesture().onEnded {
                selectedInlineTemplate = template
            })
            .buttonStyle(.plain)
            .disabled(isLoadingInlineRetroactivePhoto)
        } else {
            Button {
                performSelectedRecordAction(template)
            } label: {
                JournalTemplateGridTile(
                    title: "Random",
                    emoji: displayEmoji
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func inlineActivityTemplateCell(_ template: JournalTemplate) -> some View {
        let seed = JournalTemplateSeed(template: template)

        if selectedRecordAction == .retroactive {
            PhotosPicker(selection: $inlineRetroactivePhotoItem, matching: .images) {
                JournalTemplateGridTile(
                    title: seed.previewTitle,
                    emoji: seed.resolvedStaticEmoji
                )
            }
            .simultaneousGesture(TapGesture().onEnded {
                selectedInlineTemplate = seed
            })
            .buttonStyle(.plain)
            .disabled(isLoadingInlineRetroactivePhoto)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    draft = JournalTemplateDraft(template: template)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    deleteTemplate(template)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } else {
            Button {
                performSelectedRecordAction(seed)
            } label: {
                JournalTemplateGridTile(
                    title: seed.previewTitle,
                    emoji: seed.resolvedStaticEmoji
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    draft = JournalTemplateDraft(template: template)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    deleteTemplate(template)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func performSelectedRecordAction(_ template: JournalTemplateSeed) {
        switch selectedRecordAction {
        case .instant:
            let now = Date()
            captureRequest = JournalTemplateCaptureRequest(
                startDate: now,
                endDate: now,
                template: template
            )
        case .timer:
            beginActivityLogging(template: template, selection: .timerDefault)
            selectedRecordAction = nil
        case .countdown:
            guard selectedCountdownDuration > 0 else { return }
            beginCountdown(
                template: template,
                duration: selectedCountdownDuration,
                selection: SarosCountdownScale.normalized(forDuration: selectedCountdownDuration)
            )
            selectedRecordAction = nil
            selectedCountdownDuration = 0
            isCountdownDurationConfirmed = false
        case .retroactive, .draft, nil:
            break
        }
    }

    private var selectedActivityBinding: Binding<UUID?> {
        Binding(
            get: { selectedActivitySession?.id },
            set: { selectedActivityID = $0 }
        )
    }

    private func closeActivityNoteEditor() {
        withAnimation(.snappy(duration: 0.18)) {
            editingActivityNotesID = nil
        }
        dismissKeyboard()
    }

    private func activityPagerHeight(in availableHeight: CGFloat) -> CGFloat {
        max(474, availableHeight - 118)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    @MainActor
    private func beginActivityLogging(
        template: JournalTemplateSeed,
        selection: SarosCountdownSelection = .timerDefault
    ) {
        let session = ContinuousActivityLogger.beginTimer(
            template: template,
            sarosCountdownSelection: selection
        )
        selectedActivityID = session.id
        Task {
            try? await ThreadLiveActivityService.start(
                snapshot: ThreadLiveActivityService.activityLoggingSnapshot(session: session)
            )
        }
    }

    @MainActor
    private func stopActivityLogging(sessionID: UUID?) {
        guard let window = ContinuousActivityLogger.finish(sessionID: sessionID) else {
            return
        }
        captureRequest = JournalTemplateCaptureRequest(
            startDate: window.startDate,
            endDate: window.endDate,
            template: window.template,
            text: window.text,
            mediaItems: window.mediaItems
        )
        Task {
            await ThreadLiveActivityService.stopActivityLogging(sessionID: window.sessionID)
            await ThreadLiveActivityService.syncActivityLogging(
                sessions: ContinuousActivityLogger.sessions,
                preferredSessionID: selectedActivityID
            )
            await NotificationScheduler.shared.cancelActivityCountdown(sessionID: window.sessionID)
        }
    }

    @MainActor
    private func beginCountdown(
        template: JournalTemplateSeed,
        duration: TimeInterval,
        selection: SarosCountdownSelection
    ) {
        let session = ContinuousActivityLogger.beginCountdown(
            template: template,
            duration: duration,
            sarosCountdownSelection: selection
        )
        selectedActivityID = session.id
        Task {
            await NotificationScheduler.shared.scheduleActivityCountdownCompletion(for: session)
            try? await ThreadLiveActivityService.start(
                snapshot: ThreadLiveActivityService.activityLoggingSnapshot(session: session)
            )
        }
    }

    private func saveTemplate(_ draft: JournalTemplateDraft) {
        let tagIDs = draft.sortedTagIDs(tags: tags)
        if let existing = templates.first(where: { $0.id == draft.id }) {
            existing.name = draft.name.nilIfBlank ?? "Template"
            existing.emoji = draft.emoji.nilIfBlank ?? JournalRecordMarkers.random()
            existing.text = draft.text
            existing.tagIDs = tagIDs
            existing.touch()
        } else {
            modelContext.insert(JournalTemplate(
                id: draft.id,
                name: draft.name.nilIfBlank ?? "Template",
                emoji: draft.emoji.nilIfBlank ?? JournalRecordMarkers.random(),
                text: draft.text,
                tagIDs: tagIDs
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

    private func normalizeSelectedActivity() {
        let ids = Set(activitySessions.map(\.id))
        if let selectedActivityID, ids.contains(selectedActivityID) {
            return
        }
        selectedActivityID = activitySessions.first?.id
    }

    private func syncActivityWidget() {
        let sessions = activitySessions
        let preferredID = selectedActivityID
        Task {
            await ThreadLiveActivityService.syncActivityLogging(
                sessions: sessions,
                preferredSessionID: preferredID
            )
        }
    }

    private func toggleActivityAudio() {
        do {
            if !audioRecorder.isRecording {
                recordingActivityID = selectedActivitySession?.id
            }
            try audioRecorder.toggleRecording(mode: .reflected)
            if !audioRecorder.isRecording, audioRecorder.lastItem == nil {
                recordingActivityID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addActivityCameraMedia(_ media: MirrorCameraCapturedMedia) {
        guard let session = selectedActivitySession else { return }
        do {
            let item = try JournalPendingMediaAttachment(media: media).save()
            ContinuousActivityLogger.appendMedia(item, to: session.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadActivityPhotos(from items: [PhotosPickerItem]) async {
        guard !items.isEmpty, let session = selectedActivitySession else { return }
        do {
            for item in items {
                guard let pickedPhoto = try await item.loadTransferable(type: JournalPickedPhotoTransfer.self) else {
                    continue
                }
                let fileExtension = preferredActivityPhotoFileExtension(for: item)
                let mediaItem = try await Task.detached(priority: .utility) {
                    try MediaStorage.saveData(
                        pickedPhoto.data,
                        fileExtension: fileExtension,
                        type: .photo
                    )
                }.value
                ContinuousActivityLogger.appendMedia(mediaItem, to: session.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func importActivityDocuments(from result: Result<[URL], Error>) async {
        guard let session = selectedActivitySession else { return }
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }

            for url in urls {
                let didStartAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let fileExtension = url.pathExtension.isEmpty ? "bin" : url.pathExtension
                let mediaItem = try await Task.detached(priority: .utility) {
                    try MediaStorage.saveFile(
                        at: url,
                        fileExtension: fileExtension,
                        type: .document
                    )
                }.value
                ContinuousActivityLogger.appendMedia(mediaItem, to: session.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func preferredActivityPhotoFileExtension(for item: PhotosPickerItem) -> String {
        item.supportedContentTypes
            .first(where: { $0.conforms(to: .image) })?
            .preferredFilenameExtension ?? "jpg"
    }

    @MainActor
    private func importInlineRetroactivePhoto(_ item: PhotosPickerItem, template: JournalTemplateSeed) async {
        isLoadingInlineRetroactivePhoto = true
        inlineGridErrorMessage = nil
        defer {
            isLoadingInlineRetroactivePhoto = false
            inlineRetroactivePhotoItem = nil
        }

        do {
            guard let pickedPhoto = try await item.loadTransferable(type: JournalPickedPhotoTransfer.self),
                  let image = UIImage(data: pickedPhoto.data) else {
                inlineGridErrorMessage = "Photo unavailable."
                return
            }
            let metadata = JournalImportedPhotoMetadataReader.read(from: pickedPhoto.data)
            retroactiveMirrorRequest = JournalTemplateRetroactiveMirrorRequest(
                startDate: metadata.date ?? Date(),
                template: template,
                image: MirrorCameraView.preparedImportedImage(image),
                latitude: metadata.latitude,
                longitude: metadata.longitude
            )
            selectedInlineTemplate = nil
        } catch {
            inlineGridErrorMessage = "Photo import failed."
        }
    }

    private func completeRetroactiveMirror(
        request: JournalTemplateRetroactiveMirrorRequest,
        media: MirrorCameraCapturedMedia
    ) {
        do {
            let mediaItem = try JournalPendingMediaAttachment(media: media).save()
            let nextCaptureRequest = JournalTemplateCaptureRequest(
                startDate: request.startDate,
                endDate: request.startDate,
                template: request.template,
                mediaItems: [mediaItem],
                latitude: request.latitude,
                longitude: request.longitude
            )
            retroactiveMirrorRequest = nil
            DispatchQueue.main.async {
                captureRequest = nextCaptureRequest
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct JournalTemplateActionView: View {
    @Environment(\.dismiss) private var dismiss

    let template: JournalTemplateSeed
    let onNow: (JournalTemplateCaptureRequest) -> Void
    let onCountdown: (JournalTemplateSeed, TimeInterval, SarosCountdownSelection) -> Void
    let onTimer: (JournalTemplateSeed, SarosCountdownSelection) -> Void
    let onRetroactive: (JournalTemplateRetroactiveMirrorRequest) -> Void

    @State private var gigaCount = 0
    @State private var megaCount = 0
    @State private var kiloCount = 0
    @State private var sarosCount = 1
    @State private var isCountdownExpanded = false
    @State private var retroactivePhotoItem: PhotosPickerItem?
    @State private var isLoadingRetroactivePhoto = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Text(template.resolvedStaticEmoji)
                        .font(.system(size: 46))
                        .frame(width: 58, height: 58)
                        .background(Color(.secondarySystemGroupedBackground), in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.name)
                            .font(.headline)
                        Text(template.text.nilIfBlank ?? "Empty text")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                    JournalTemplateActionButton(title: "Instant", systemName: "bolt.circle") {
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
                        onTimer(template, .timerDefault)
                        dismiss()
                    }

                    PhotosPicker(selection: $retroactivePhotoItem, matching: .images) {
                        JournalTemplateActionButtonLabel(title: "Retroactive", systemName: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingRetroactivePhoto)
                }

                if isCountdownExpanded {
                    JournalCountdownConfigurationView(
                        gigaCount: $gigaCount,
                        megaCount: $megaCount,
                        kiloCount: $kiloCount,
                        sarosCount: $sarosCount,
                        duration: countdownDuration
                    ) {
                        onCountdown(template, countdownDuration, countdownSelection)
                        dismiss()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if isLoadingRetroactivePhoto {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading photo")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(18)
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity, minHeight: 360, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemGroupedBackground))
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
        .onChange(of: gigaCount) { oldValue, newValue in
            clearDefaultSarosCountIfNeeded(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: megaCount) { oldValue, newValue in
            clearDefaultSarosCountIfNeeded(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: kiloCount) { oldValue, newValue in
            clearDefaultSarosCountIfNeeded(oldValue: oldValue, newValue: newValue)
        }
    }

    private var countdownDuration: TimeInterval {
        Double(countdownBaseSarosCount) * SarosPulseCalculator.averageDuration(for: .saros)
    }

    private var countdownSelection: SarosCountdownSelection {
        SarosCountdownScale.normalized(forBaseSarosCount: countdownBaseSarosCount)
    }

    private var countdownBaseSarosCount: Int {
        gigaCount * SarosCountdownScale.gigasaros.baseSarosCount
            + megaCount * SarosCountdownScale.megasaros.baseSarosCount
            + kiloCount * SarosCountdownScale.kilosaros.baseSarosCount
            + sarosCount
    }

    private func clearDefaultSarosCountIfNeeded(oldValue: Int, newValue: Int) {
        guard oldValue == 0, newValue > 0, sarosCount == 1 else { return }
        sarosCount = 0
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
            guard let image = UIImage(data: pickedPhoto.data) else {
                errorMessage = "Photo unavailable."
                return
            }
            let metadata = JournalImportedPhotoMetadataReader.read(from: pickedPhoto.data)
            let date = metadata.date ?? Date()
            onRetroactive(JournalTemplateRetroactiveMirrorRequest(
                startDate: date,
                template: template,
                image: MirrorCameraView.preparedImportedImage(image),
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
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 88)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
}

private struct JournalCountdownConfigurationView: View {
    @Binding var gigaCount: Int
    @Binding var megaCount: Int
    @Binding var kiloCount: Int
    @Binding var sarosCount: Int

    let duration: TimeInterval
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            JournalCountdownStepper(label: "Gigasaros", value: $gigaCount)
            JournalCountdownStepper(label: "Megasaros", value: $megaCount)
            JournalCountdownStepper(label: "Kilosaros", value: $kiloCount)
            JournalCountdownStepper(label: "Saros", value: $sarosCount)

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
    let tagIDs: [String]?

    static let randomID = "random"

    static var random: JournalTemplateSeed {
        JournalTemplateSeed(
            id: randomID,
            name: "Random",
            emoji: nil,
            text: "",
            usesRandomEmoji: true,
            tagIDs: nil
        )
    }

    static func random(emoji: String) -> JournalTemplateSeed {
        JournalTemplateSeed(
            id: randomID,
            name: "Random",
            emoji: emoji,
            text: "",
            usesRandomEmoji: false,
            tagIDs: nil
        )
    }

    init(template: JournalTemplate) {
        self.id = template.id.uuidString
        self.name = template.displayName
        self.emoji = template.emoji
        self.text = template.text
        self.usesRandomEmoji = false
        self.tagIDs = template.tagIDs
    }

    private init(id: String, name: String, emoji: String?, text: String, usesRandomEmoji: Bool, tagIDs: [String]?) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.text = text
        self.usesRandomEmoji = usesRandomEmoji
        self.tagIDs = tagIDs
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

    var resolvedTagIDs: [String] {
        tagIDs ?? []
    }
}

private struct JournalRecordSectionCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct JournalTemplateGridButton: View {
    let template: JournalTemplate
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            JournalTemplateGridTile(
                title: template.displayName,
                emoji: template.displayEmoji
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }

            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct JournalTemplateGridTile: View {
    let title: String
    let emoji: String

    var body: some View {
        VStack(spacing: 6) {
            Text(emoji)
                .font(.system(size: 34))
                .frame(width: 52, height: 52)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 84, alignment: .top)
        .contentShape(Rectangle())
    }
}

private struct JournalTemplateManagerView: View {
    @Environment(\.dismiss) private var dismiss

    let templates: [JournalTemplate]
    let onAdd: () -> Void
    let onEdit: (JournalTemplate) -> Void
    let onDelete: (JournalTemplate) -> Void

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 82), spacing: 12)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                Button(action: onAdd) {
                    VStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .frame(width: 52, height: 52)
                            .background(Color.accentColor.opacity(0.16), in: Circle())
                        Text("Add")
                            .font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 86, alignment: .top)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                ForEach(templates) { template in
                    Button {
                        onEdit(template)
                    } label: {
                        JournalTemplateGridTile(
                            title: template.displayName,
                            emoji: template.displayEmoji
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            onEdit(template)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            onDelete(template)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

private struct JournalTemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State var draft: JournalTemplateDraft
    let tags: [JournalTag]
    let onSave: (JournalTemplateDraft) -> Void
    @State private var isTagPickerPresented = false

    var body: some View {
        Form {
            Section("Template") {
                TextField("Name", text: $draft.name)
                TextField("Emoji marker", text: $draft.emoji)
                TextEditor(text: $draft.text)
                    .frame(minHeight: 180)
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

    private var selectedTags: [JournalTag] {
        tags.filter { draft.selectedTagIDs.contains($0.compactID) }
    }

    private var availableTags: [JournalTag] {
        tags.filter { !draft.selectedTagIDs.contains($0.compactID) }
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
    var selectedTagIDs: Set<String>

    init(
        id: UUID = UUID(),
        name: String = "",
        emoji: String = JournalRecordMarkers.random(),
        text: String = "",
        selectedTagIDs: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.text = text
        self.selectedTagIDs = selectedTagIDs
    }

    init(template: JournalTemplate) {
        self.id = template.id
        self.name = template.name
        self.emoji = template.emoji
        self.text = template.text
        self.selectedTagIDs = Set(template.tagIDs)
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
    @AppStorage("timelineUseSineWaveforms") private var timelineUseSineWaveforms = false
    @AppStorage("timelineSineWaveSumMode") private var timelineSineWaveSumMode = false
    @AppStorage("timelineWavelengthOption") private var timelineWavelengthOption = 2.0
    @AppStorage(JournalSettings.timelineWaveColorModeKey) private var timelineWaveColorModeRaw = TimelineWaveColorMode.current.rawValue
    @AppStorage(JournalSettings.pulseSarosKey) private var pulseSaros = 0

    let context: JournalEventContext
    var endDate: Date? = nil

    @State private var plot = JournalEntryWaveformPlot.empty
    @State private var lunarTicks: [LunarRulerTick] = []
    @State private var solarTicks: [SolarYearRulerTick] = []
    @State private var pulseTicks: [SarosPulseTick] = []
    @State private var displayMegaUnits = JournalEntryWaveform.defaultMegaUnits
    @AppStorage(JournalSettings.solarSiderealReferenceDateKey) private var solarSiderealReferenceTimestamp = SolarYearRuler.defaultSiderealReferenceDate.timeIntervalSince1970

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
                let solarTopY = JournalEntryWaveform.solarRulerTopY(in: size.height)
                let insets = EdgeInsets(
                    top: lunarBottomY,
                    leading: 14,
                    bottom: max(size.height - solarTopY + 18, 32),
                    trailing: 14
                )
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
                    line.addLine(to: CGPoint(x: x, y: solarTopY))
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
                    let dotStep = dotSize + 7
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
                    line.addLine(to: CGPoint(x: x, y: solarTopY))
                    graphics.stroke(line, with: .color(spike.rarity.color.opacity(0.42)), lineWidth: 1)

                    let contributors = group.contributors.isEmpty ? [spike] : group.contributors
                    let dotGap = dotSize + 7
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
                        marker.addLine(to: CGPoint(x: x, y: solarTopY))
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
                    marker.addLine(to: CGPoint(x: eventX, y: solarTopY))
                    graphics.stroke(marker, with: .color(.green.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    graphics.fill(Path(ellipseIn: CGRect(x: eventX - 4, y: eventY - 4, width: 8, height: 8)), with: .color(.green))
                }
            }
            LunarRulerCanvas(
                ticks: lunarTicks,
                displayInterval: plot.interval,
                topInset: JournalEntryWaveform.lunarRulerTopInset,
                rowSpacing: JournalEntryWaveform.lunarRulerRowSpacing,
                labelOffset: 15,
                showSineWave: timelineUseSineWaveforms,
                waveSumMode: timelineSineWaveSumMode,
                wavelengthOption: timelineWavelengthOption,
                waveColorMode: timelineWaveColorMode
            )
            SolarYearRulerCanvas(
                ticks: solarTicks,
                displayInterval: plot.interval,
                baselineRatio: JournalEntryWaveform.solarRulerBaselineRatio,
                rowSpacing: JournalEntryWaveform.solarRulerRowSpacing,
                showSineWave: timelineUseSineWaveforms,
                waveSumMode: timelineSineWaveSumMode,
                wavelengthOption: timelineWavelengthOption,
                waveColorMode: timelineWaveColorMode
            )
            GeometryReader { proxy in
                SarosPulseRulerCanvas(
                    ticks: pulseTicks,
                    displayInterval: plot.interval,
                    tickStartY: JournalEntryWaveform.pulseTickTopY(in: proxy.size.height),
                    tickEndY: JournalEntryWaveform.solarRulerTopY(in: proxy.size.height)
                )
            }
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
            let endDate = resolvedEndDate
            let siderealReferenceDate = Date(timeIntervalSince1970: solarSiderealReferenceTimestamp)
            let displayDuration = JournalEntryWaveform.displayDuration(megaUnits: displayMegaUnits)
            let configuredPulseSaros = pulseSaros
            let parabolaA = JournalWaveformSettings.currentParabolaA
            let eclipseService = services.eclipseService
            let options = JournalWaveformOptions(
                ignorePartialEclipses: false,
                mergeCloseSpikes: waveformMergeCloseSpikes,
                normalizedAmplitude: waveformNormalizedAmplitude,
                subdivisionDepth: clampedSubdivisionDepth,
                mergeThreshold: JournalWaveformSettings.mergeCloseSpikeThreshold,
                amplitudeMultiplier: clampedAmplitudeMultiplier
            )
            let generated = await Task.detached(priority: .userInitiated) { () -> (JournalEntryWaveformPlot, [LunarRulerTick], [SolarYearRulerTick], [SarosPulseTick]) in
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
                let solarTicks = SolarYearRuler.ticks(in: plot.interval, siderealReferenceDate: siderealReferenceDate)
                let resolvedPulseSaros = configuredPulseSaros > 0
                    ? configuredPulseSaros
                    : (context.closestSpike?.saros ?? 0)
                let pulseTicks = resolvedPulseSaros > 0
                    ? ((try? SarosPulseCalculator.ticks(
                        in: plot.interval,
                        saros: resolvedPulseSaros,
                        harmonicDepth: context.waveformHarmonicDepth,
                        eclipseService: eclipseService,
                        units: [.rollover, .giga, .mega, .kilo]
                    )) ?? [])
                    : []
                return (plot, lunarTicks, solarTicks, pulseTicks)
            }.value
            plot = generated.0
            lunarTicks = generated.1
            solarTicks = generated.2
            pulseTicks = generated.3
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
            "\(pulseSaros)",
            "\(Int(solarSiderealReferenceTimestamp))"
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

    private var timelineWaveColorMode: TimelineWaveColorMode {
        TimelineWaveColorMode(rawValue: timelineWaveColorModeRaw) ?? .current
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
    static let defaultMegaUnits = 2
    static let maximumMegaUnits = 12
    static let lunarRulerTopInset: CGFloat = 10
    static let lunarRulerRowSpacing: CGFloat = 15
    static let solarRulerBaselineRatio: CGFloat = 0.86
    static let solarRulerRowSpacing: CGFloat = 15
    static let amplitudeScale: CGFloat = 0.56

    static func solarRulerTopY(in height: CGFloat) -> CGFloat {
        max(
            lunarRulerTopInset + lunarRulerRowSpacing * 2 + LunarRulerTickLevel.major.height + 8,
            height * solarRulerBaselineRatio - solarRulerRowSpacing * 2 - LunarRulerTickLevel.major.height
        )
    }

    static func pulseTickTopY(in height: CGFloat) -> CGFloat {
        min(
            max(lunarRulerTopInset + lunarRulerRowSpacing * 2 + LunarRulerTickLevel.major.height, 0),
            solarRulerTopY(in: height)
        )
    }

    static func displayDuration(megaUnits: Int) -> TimeInterval {
        SarosPulseCalculator.averageDuration(for: .mega)
            * Double(min(max(megaUnits, minimumMegaUnits), maximumMegaUnits))
    }

    static func dotSize(for rarity: FlipRarity) -> CGFloat {
        switch rarity.baseRarity {
        case .mythic: 7
        case .legendary: 6.5
        case .epic: 5.5
        default: 5
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
    case .document:
        "doc"
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
    case .document:
        "Document"
    }
}

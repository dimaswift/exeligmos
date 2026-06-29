import SwiftData
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \JournalTag.createdAt, order: .forward) private var tags: [JournalTag]
    @Query(sort: \JournalEntry.eventDate, order: .reverse) private var entries: [JournalEntry]
    @Query(sort: \SyncLocalCommand.createdAt, order: .forward) private var syncCommands: [SyncLocalCommand]

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""
    @AppStorage(JournalSettings.deviceIDKey) private var deviceID = ""
    @AppStorage(JournalSettings.deviceNameKey) private var deviceName = ""
    @AppStorage(JournalSettings.deviceEmojiKey) private var deviceEmoji = ""
    @AppStorage(JournalSettings.lastSyncAtKey) private var lastSyncAt = 0.0
    @State private var diagnosticMessage = ""
    @State private var syncMessage = ""
    @State private var errorMessage: String?
    @State private var isSyncing = false
    @State private var deviceUpdateTask: Task<Void, Never>?
    @State private var isStartingLiveTracking = false
    @State private var liveTrackingMessage = ""

    var body: some View {
        Form {
            Section("Saros clock") {
                Stepper(
                    "Glyph depth \(harmonicDepth)",
                    value: $harmonicDepth,
                    in: JournalSettings.supportedHarmonicDepth
                )

                Text("Depth controls glyph shape, flip timing, and which rarity orders exist.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    RarityPeriodsSettingsView()
                } label: {
                    Label("Periods", systemImage: "clock.arrow.circlepath")
                }

                NavigationLink {
                    WaveformSettingsView()
                } label: {
                    Label("Waveform", systemImage: "waveform.path.ecg")
                }

                NavigationLink {
                    CatalogView()
                } label: {
                    Label("Catalog", systemImage: "globe.europe.africa")
                }
            }

            Section("Pulse") {
                NavigationLink {
                    PulseSettingsView()
                } label: {
                    Label("Pulse reference", systemImage: "ruler")
                }
            }

            Section("Camera") {
                NavigationLink {
                    MirrorCameraView()
                } label: {
                    Label("Open camera", systemImage: "camera.viewfinder")
                }
            }

            Section("Notifications") {
                Button {
                    Task { await startLiveTracking() }
                } label: {
                    if isStartingLiveTracking {
                        ProgressView()
                    } else {
                        Label("Live tracking", systemImage: "waveform.path.ecg")
                    }
                }
                .disabled(isStartingLiveTracking)

                Button {
                    Task {
                        await services.notificationScheduler.refreshGlobalSarosEventSchedules(
                            eclipseService: services.eclipseService,
                            moonPhaseService: services.moonPhaseService,
                            harmonicDepth: harmonicDepth
                        )
                        diagnosticMessage = "Notification schedule refreshed."
                    }
                } label: {
                    Label("Refresh peak schedule", systemImage: "bell.badge")
                }

                if !diagnosticMessage.isEmpty {
                    Text(diagnosticMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !liveTrackingMessage.isEmpty {
                    Text(liveTrackingMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("LAN Sync") {
                HStack {
                    Text("Channel")
                    Spacer()
                    Text(deviceID)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                TextField("Channel name", text: $deviceName)
                    .textInputAutocapitalization(.words)

                TextField("Emoji", text: $deviceEmoji)
                    .frame(maxWidth: 90)

                TextField("http://192.168.1.10:8787", text: $syncServerURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Button {
                    Task { await testSyncServer() }
                } label: {
                    Label("Test relay connection", systemImage: "network.badge.shield.half.filled")
                }
                .disabled(isSyncing)

                Button {
                    Task { await syncWithServer() }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Label("Sync with relay", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isSyncing)

                if !syncMessage.isEmpty {
                    Text(syncMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text(lastSyncText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                NavigationLink {
                    AnimacyDatasetSettingsView()
                } label: {
                    Label("Animacy dataset", systemImage: "target")
                }
            }

        }
        .navigationTitle("Settings")
        .task {
            let device = JournalDevice.ensureIdentity()
            deviceID = device.id
            deviceName = device.name
            deviceEmoji = device.emoji
        }
        .onChange(of: harmonicDepth) { _, newDepth in
            Task {
                await services.notificationScheduler.refreshGlobalSarosEventSchedules(
                    eclipseService: services.eclipseService,
                    moonPhaseService: services.moonPhaseService,
                    harmonicDepth: newDepth
                )
                diagnosticMessage = "Glyph depth updated and notification schedule refreshed."
            }
        }
        .onChange(of: deviceName) { _, _ in
            scheduleDeviceProfileUpdate()
        }
        .onChange(of: deviceEmoji) { _, _ in
            scheduleDeviceProfileUpdate()
        }
        .alert("Settings error", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func testSyncServer() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let status = try await services.syncService.checkStatus(from: syncServerURL)
            if let exportTimestamp = status.exportTimestamp, status.hasBackup {
                syncMessage = "Server OK. Folder state \(exportTimestamp.formatted(date: .abbreviated, time: .shortened)): \(status.entityCount) tags, \(status.recordCount) records, \(status.mediaCount) media files."
            } else {
                syncMessage = "Server OK. No records have been uploaded yet."
            }
        } catch {
            syncMessage = "Offline. Sync will retry when the relay is reachable."
        }
    }

    @MainActor
    private func syncWithServer() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let summary = try await services.syncService.synchronizeEntries(
                with: syncServerURL,
                modelContext: modelContext,
                tags: tags,
                entries: entries,
                commands: syncCommands
            )
            syncMessage = "Relayed \(summary.uploadedRecordCount + summary.restoredRecordCount) record commands, \(summary.restoredEntityCount) tag commands, \(summary.uploadedMediaCount + summary.restoredMediaCount) media files."
        } catch {
            syncMessage = "Offline. Local changes are safe on this device."
        }
    }

    private var lastSyncText: String {
        guard lastSyncAt > 0 else {
            return "Last sync: never"
        }
        let elapsed = max(Date().timeIntervalSince1970 - lastSyncAt, 0)
        return "Last sync: \(elapsed.compactDuration) ago"
    }

    private func scheduleDeviceProfileUpdate() {
        deviceUpdateTask?.cancel()
        deviceUpdateTask = Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled, syncServerURL.nilIfBlank != nil else { return }
            try? await services.syncService.registerChannel(to: syncServerURL)
        }
    }

    @MainActor
    private func startLiveTracking() async {
        isStartingLiveTracking = true
        defer { isStartingLiveTracking = false }

        let contextService = services.sarosEventContextService
        let eclipseService = services.eclipseService
        let moonPhaseService = services.moonPhaseService
        let depth = harmonicDepth

        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try ThreadLiveActivityService.journalSnapshot(
                    contextService: contextService,
                    eclipseService: eclipseService,
                    moonService: moonPhaseService,
                    date: Date(),
                    harmonicDepth: depth
                )
            }.value
            try await ThreadLiveActivityService.start(snapshot: snapshot)
            liveTrackingMessage = "Live tracking active: \(snapshot.eventName ?? snapshot.rarityTitle)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

private struct WaveformSettingsView: View {
    @AppStorage(JournalSettings.waveformModelKey) private var waveformModelRawValue = JournalWaveformModel.gaussian.rawValue
    @AppStorage(JournalSettings.waveformParabolaAKey) private var parabolaA = JournalWaveformSettings.defaultParabolaA
    @AppStorage(JournalSettings.waveformMergeCloseSpikesKey) private var mergeCloseSpikes = false
    @AppStorage(JournalSettings.waveformNormalizedAmplitudeKey) private var normalizedAmplitude = false
    @AppStorage(JournalSettings.waveformSubdivisionDepthKey) private var subdivisionDepth = JournalWaveformSettings.defaultSubdivisionDepth

    private var selectedModel: JournalWaveformModel {
        JournalWaveformModel(rawValue: waveformModelRawValue) ?? .gaussian
    }

    var body: some View {
        List {
            Section {
                Picker("Model", selection: $waveformModelRawValue) {
                    ForEach(JournalWaveformModel.allCases) { model in
                        Text(model.title).tag(model.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(selectedModel.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Parabola") {
                HStack {
                    Text("A")
                    Slider(
                        value: $parabolaA,
                        in: JournalWaveformSettings.parabolaARange,
                        step: 0.1
                    )
                    Text(parabolaA.formatted(.number.precision(.fractionLength(1))))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text("Higher A values make the peak narrower and move more acceleration toward the selected side of each half-wave.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Spikes") {
                Toggle("Merge close spikes", isOn: $mergeCloseSpikes)
                Toggle("Normalized amplitude", isOn: $normalizedAmplitude)

                Stepper(
                    "Subdivision depth \(clampedSubdivisionDepth)",
                    value: $subdivisionDepth,
                    in: JournalWaveformSettings.subdivisionDepthRange
                )

                Text("Merged spikes use a 1 kilosaros window (36m 10s). Sampling always includes spike and midpoint anchors, then subdivides each segment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                MetadataRow(title: "Current model", value: selectedModel.title)
                MetadataRow(title: "Energy", value: energyDescription)
                MetadataRow(title: "Momentum", value: selectedModel == .saw ? "Segment slope" : "Sampled slope")
            }
        }
        .navigationTitle("Waveform")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var energyDescription: String {
        switch selectedModel {
        case .gaussian: "Gaussian mixture"
        case .saw: "Linear interpolation"
        case .parabola: "Parabolic halves"
        }
    }

    private var clampedSubdivisionDepth: Int {
        min(
            max(subdivisionDepth, JournalWaveformSettings.subdivisionDepthRange.lowerBound),
            JournalWaveformSettings.subdivisionDepthRange.upperBound
        )
    }
}

private struct PulseSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @AppStorage(JournalSettings.pulseSarosKey) private var pulseSaros = 0

    @State private var preview: SarosPulseReading?
    @State private var errorMessage: String?

    private var selectedSaros: Binding<Int?> {
        Binding(
            get: { pulseSaros > 0 ? pulseSaros : nil },
            set: { pulseSaros = $0 ?? 0 }
        )
    }

    var body: some View {
        List {
            Section("Reference Saros") {
                SarosGlyphGridPicker(selectedSaros: selectedSaros)

                if let preview, !preview.octalAddress.isEmpty {
                    HStack(spacing: 12) {
                        SarosPulseGlyph(reading: preview, size: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Current pulse")
                                .font(.subheadline.weight(.semibold))
                            Text("Saros \(preview.saros)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("Pulse uses one selected Saros as a six-digit fine ruler.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Ruler") {
                ForEach(SarosPulseUnit.referenceUnits) { unit in
                    HStack {
                        Rectangle()
                            .fill(unit.color)
                            .frame(width: 28, height: 3)
                            .clipShape(Capsule())
                        Text(unit.title)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(pattern(for: unit))
                                .font(.caption.monospaced())
                            Text(Self.durationFormatter.string(from: SarosPulseCalculator.averageDuration(for: unit)) ?? SarosPulseCalculator.averageDuration(for: unit).compactDuration)
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Pulse")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await ensureDefaultSaros()
            updatePreview()
        }
        .onChange(of: pulseSaros) { _, _ in
            updatePreview()
        }
        .onChange(of: harmonicDepth) { _, _ in
            updatePreview()
        }
    }

    @MainActor
    private func ensureDefaultSaros() async {
        guard pulseSaros <= 0 else { return }
        let eclipseService = services.eclipseService
        let result = await Task.detached(priority: .utility) {
            Result {
                try SarosPulseCalculator.defaultActiveSaros(
                    at: Date(),
                    eclipseService: eclipseService
                )
            }
        }.value

        if case .success(let saros?) = result {
            pulseSaros = saros
        }
    }

    private func updatePreview() {
        guard pulseSaros > 0 else {
            preview = nil
            return
        }

        do {
            preview = try SarosPulseCalculator.reading(
                saros: pulseSaros,
                date: Date(),
                harmonicDepth: harmonicDepth,
                eclipseService: services.eclipseService
            )
            errorMessage = nil
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func pattern(for unit: SarosPulseUnit) -> String {
        unit.pattern
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 3
        return formatter
    }()
}

private struct AnimacyDatasetSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""

    @State private var datasetSummary = AnimacyDatasetQueueSummary.empty
    @State private var datasetMessage = ""
    @State private var isUploadingDataset = false

    var body: some View {
        List {
            Section {
                MetadataRow(title: "Pending captures", value: "\(datasetSummary.pendingCaptureCount)")
                MetadataRow(title: "Failed captures", value: "\(datasetSummary.failedCaptureCount)")
                MetadataRow(title: "Completed captures", value: "\(datasetSummary.completedCaptureCount)")
                MetadataRow(title: "Queued samples", value: "\(datasetSummary.pendingTransformationCount)")
                MetadataRow(title: "Uploaded samples", value: "\(datasetSummary.completedTransformationCount)")
            }

            Section {
                Button {
                    Task { await uploadPendingDatasetCaptures() }
                } label: {
                    if isUploadingDataset {
                        ProgressView()
                    } else {
                        Label("Upload pending captures", systemImage: "arrow.up.circle")
                    }
                }
                .disabled(isUploadingDataset || !datasetSummary.hasPendingUploads)

                Button(role: .destructive) {
                    clearCompletedDatasetCaptures()
                } label: {
                    Label("Clear completed uploads", systemImage: "trash")
                }
                .disabled(datasetSummary.completedCaptureCount == 0)

                if !datasetMessage.isEmpty {
                    Text(datasetMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Animacy Dataset")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            refreshDatasetSummary()
        }
    }

    private func refreshDatasetSummary() {
        do {
            datasetSummary = try services.animacyDatasetQueue.summary()
        } catch {
            datasetMessage = error.localizedDescription
        }
    }

    @MainActor
    private func uploadPendingDatasetCaptures() async {
        isUploadingDataset = true
        defer {
            isUploadingDataset = false
            refreshDatasetSummary()
        }

        do {
            let summary = try await services.animacyDatasetQueue.uploadPending(to: syncServerURL)
            if summary.attemptedCount == 0 {
                datasetMessage = "No pending animacy captures."
            } else if summary.failedCount > 0 {
                datasetMessage = "Uploaded \(summary.uploadedCount), failed \(summary.failedCount). \(summary.lastError ?? "")"
            } else {
                datasetMessage = "Uploaded \(summary.uploadedCount) animacy captures."
            }
        } catch {
            datasetMessage = error.localizedDescription
        }
    }

    private func clearCompletedDatasetCaptures() {
        do {
            datasetSummary = try services.animacyDatasetQueue.clearCompleted()
            datasetMessage = "Cleared completed animacy uploads."
        } catch {
            datasetMessage = error.localizedDescription
        }
    }
}

private struct RarityPeriodsSettingsView: View {
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    var body: some View {
        List {
            Section {
                MetadataRow(title: "Glyph depth", value: "\(JournalSettings.clampedHarmonicDepth(harmonicDepth))")
                MetadataRow(title: "Average Saros", value: Self.durationFormatter.string(from: JournalSettings.averageSarosPeriod) ?? JournalSettings.averageSarosPeriod.compactDuration)
                Text("Periods use repeated suffix patterns over the average Saros interval, so rarity spacing stays stable as glyph depth changes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Average periods") {
                ForEach(FlipRarity.rarityGroups(for: harmonicDepth)) { group in
                    DisclosureGroup {
                        ForEach(group.subrarities) { rarity in
                            RarityPeriodRow(rarity: rarity, harmonicDepth: harmonicDepth)
                        }
                    } label: {
                        RarityPeriodRow(rarity: group.header, harmonicDepth: harmonicDepth)
                    }
                }
            }
        }
        .navigationTitle("Periods")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.year, .month, .day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 3
        return formatter
    }()
}

private struct RarityPeriodRow: View {
    let rarity: FlipRarity
    let harmonicDepth: Int

    private var divisions: Int {
        rarity.basePeriodDivisions
    }

    private var periodDuration: TimeInterval {
        let basePeriod = JournalSettings.averageSarosPeriod / Double(divisions)
        let fraction = basePeriod / 7
        guard !rarity.isHeaderRarity else { return fraction }
        return fraction * Double(max(rarity.repeatedDigit, 1))
    }

    private var detailText: String {
        if rarity.isHeaderRarity {
            return "Smallest 1/7 fraction"
        }
        return "\(rarity.repeatedDigit)/7 filled"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    FlipRarityGlyphIcon(rarity: rarity, harmonicDepth: harmonicDepth, size: 24)
                    Text(rarity.title)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(rarity.color)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.durationFormatter.string(from: periodDuration) ?? periodDuration.compactDuration)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.year, .month, .day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 3
        return formatter
    }()
}

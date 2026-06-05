import SwiftData
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \JournalRecord.createdAt, order: .reverse) private var records: [JournalRecord]
    @Query(sort: \CustomFlipEvent.date, order: .forward) private var customFlips: [CustomFlipEvent]

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""
    @AppStorage(JournalSettings.autoSyncEnabledKey) private var autoSyncEnabled = false
    @StateObject private var server = LocalExportServer()
    @State private var exportURL: URL?
    @State private var diagnosticMessage = ""
    @State private var syncMessage = ""
    @State private var errorMessage: String?
    @State private var isSyncing = false
    @State private var datasetSummary = AnimacyDatasetQueueSummary.empty
    @State private var datasetMessage = ""
    @State private var isUploadingDataset = false

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
            }

            Section("Notifications") {
                NavigationLink {
                    FlipNotificationSettingsView()
                } label: {
                    Label("Flip rarities", systemImage: "slider.horizontal.3")
                }

                Button {
                    Task {
                        await services.notificationScheduler.refreshSchedules(
                            for: entities,
                            clockService: services.clockService,
                            harmonicDepth: harmonicDepth,
                            customFlips: customFlips
                        )
                        diagnosticMessage = "Notification schedule refreshed."
                    }
                } label: {
                    Label("Refresh schedules", systemImage: "bell.badge")
                }
            }

            Section("Export") {
                Button {
                    exportArchive()
                } label: {
                    Label("Write JSON export", systemImage: "square.and.arrow.down")
                }

                if let exportURL {
                    Text(exportURL.path)
                        .font(.footnote)
                        .textSelection(.enabled)
                }

                Button {
                    toggleServer()
                } label: {
                    Label(server.isRunning ? "Stop local server" : "Start local server", systemImage: server.isRunning ? "stop.circle" : "network")
                }

                if let urlString = server.urlString {
                    Text(urlString)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }

            Section("LAN Sync") {
                TextField("http://192.168.1.10:8787", text: $syncServerURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Button {
                    Task { await testSyncServer() }
                } label: {
                    Label("Test server connection", systemImage: "network.badge.shield.half.filled")
                }
                .disabled(isSyncing)

                Button {
                    Task { await pushSyncBackup() }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Label("Push backup to server", systemImage: "arrow.up.doc")
                    }
                }
                .disabled(isSyncing)

                Button {
                    Task { await pushSyncDelta() }
                } label: {
                    Label("Sync new records now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing)

                Toggle(isOn: $autoSyncEnabled) {
                    Label("Auto sync new records", systemImage: autoSyncEnabled ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                }

                Button {
                    Task { await restoreSyncBackup() }
                } label: {
                    Label("Restore latest from server", systemImage: "arrow.down.doc")
                }
                .disabled(isSyncing)

                if !syncMessage.isEmpty {
                    Text(syncMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Animacy Dataset") {
                MetadataRow(title: "Pending captures", value: "\(datasetSummary.pendingCaptureCount)")
                MetadataRow(title: "Failed captures", value: "\(datasetSummary.failedCaptureCount)")
                MetadataRow(title: "Completed captures", value: "\(datasetSummary.completedCaptureCount)")
                MetadataRow(title: "Queued samples", value: "\(datasetSummary.pendingTransformationCount)")
                MetadataRow(title: "Uploaded samples", value: "\(datasetSummary.completedTransformationCount)")

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

            Section("Diagnostics") {
                Button {
                    runDiagnostics()
                } label: {
                    Label("Check eclipse data", systemImage: "stethoscope")
                }

                if !diagnosticMessage.isEmpty {
                    Text(diagnosticMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .task {
            refreshDatasetSummary()
        }
        .onChange(of: harmonicDepth) { _, newDepth in
            Task {
                await services.notificationScheduler.refreshSchedules(
                    for: entities,
                    clockService: services.clockService,
                    harmonicDepth: newDepth,
                    customFlips: customFlips
                )
                diagnosticMessage = "Glyph depth updated and notification schedule refreshed."
            }
        }
        .alert("Settings error", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func exportArchive() {
        do {
            exportURL = try services.exportService.exportJSON(entities: entities, records: records)
            diagnosticMessage = "Export written."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleServer() {
        do {
            if server.isRunning {
                server.stop()
            } else {
                let url = try services.exportService.exportJSON(entities: entities, records: records)
                exportURL = url
                try server.start(exportDirectory: url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func testSyncServer() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let status = try await services.syncService.checkStatus(from: syncServerURL)
            if let exportTimestamp = status.exportTimestamp, status.hasBackup {
                syncMessage = "Server OK. Latest backup \(exportTimestamp.formatted(date: .abbreviated, time: .shortened)): \(status.entityCount) threads, \(status.recordCount) records, \(status.mediaCount) media files."
            } else {
                syncMessage = "Server OK. No backup has been pushed yet."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func pushSyncBackup() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let summary = try await services.syncService.push(
                to: syncServerURL,
                entities: entities,
                records: records
            )
            syncMessage = "Pushed \(summary.entityCount) threads, \(summary.recordCount) records, \(summary.mediaCount) media files."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func pushSyncDelta() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let summary = try await services.syncService.pushMissingRecords(
                to: syncServerURL,
                entities: entities,
                records: records
            )
            if summary.recordCount == 0 {
                syncMessage = "No new records to upload."
            } else {
                syncMessage = "Uploaded \(summary.recordCount) new records with \(summary.mediaCount) media files."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func restoreSyncBackup() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let summary = try await services.syncService.restoreLatest(
                from: syncServerURL,
                modelContext: modelContext,
                entities: entities,
                records: records
            )
            syncMessage = "Restored \(summary.entityCount) threads, \(summary.recordCount) records, \(summary.mediaCount) media files."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runDiagnostics() {
        do {
            let allSeries = try services.eclipseService.allSarosSeries()
            let nearest = try services.eclipseService.nearestEclipse(to: Date())
            diagnosticMessage = "\(allSeries.count) Saros series loaded. Nearest eclipse: Saros \(nearest?.saros ?? 0)."
        } catch {
            errorMessage = error.localizedDescription
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
                Text("Periods use the average Saros interval and the configured glyph depth.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Average periods") {
                ForEach(FlipRarity.visibleRarities(for: harmonicDepth)) { rarity in
                    RarityPeriodRow(rarity: rarity, harmonicDepth: harmonicDepth)
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

    private var depth: Int {
        JournalSettings.clampedHarmonicDepth(harmonicDepth)
    }

    private var binCount: Int {
        (0..<depth).reduce(1) { value, _ in value * 8 }
    }

    private var stride: Int {
        rarity == .saros ? binCount : (0..<rarity.order).reduce(1) { value, _ in value * 8 }
    }

    private var periodDuration: TimeInterval {
        rarity == .saros ? JournalSettings.averageSarosPeriod : JournalSettings.averageSarosPeriod / Double(binCount) * Double(stride)
    }

    private var stepOctalLabel: String {
        rarity == .saros
            ? String(repeating: "0", count: depth)
            : String(stride, radix: 8).leftPadded(toLength: rarity.order + 1, withPad: "0")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(rarity.title, systemImage: rarity.symbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(rarity.color)
                Text("\(rarity.orderLabel) · step \(stepOctalLabel)")
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

private struct FlipNotificationSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \CustomFlipEvent.date, order: .forward) private var customFlips: [CustomFlipEvent]

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @State private var preferences: [FlipNotificationRarityPreference] = []
    @State private var didLoad = false
    @State private var statusMessage = ""

    var body: some View {
        Form {
            Section {
                ForEach($preferences) { $preference in
                    RarityPreferenceRow(preference: $preference)
                }
            } footer: {
                Text("Notifications are scheduled for Rare and above. Order N is the number of trailing zeroes in the flip address; Saros covers seven zeroes or the eclipse rollover.")
            }

            Section {
                Button {
                    resetDefaults()
                } label: {
                    Label("Reset rarity defaults", systemImage: "arrow.counterclockwise")
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Flip Rarities")
        .onAppear {
            load()
        }
        .onChange(of: harmonicDepth) { _, _ in
            load(force: true)
        }
        .onChange(of: preferences) { _, newPreferences in
            guard didLoad else { return }
            FlipNotificationPreferences.save(newPreferences)
            Task {
                await services.notificationScheduler.refreshSchedules(
                    for: entities,
                    clockService: services.clockService,
                    harmonicDepth: harmonicDepth,
                    customFlips: customFlips
                )
                statusMessage = "Notification schedule refreshed."
            }
        }
    }

    private func load(force: Bool = false) {
        guard force || !didLoad else { return }
        preferences = FlipNotificationPreferences.load(for: harmonicDepth)
        didLoad = true
    }

    private func resetDefaults() {
        preferences = FlipNotificationPreferences.defaults(for: harmonicDepth)
    }
}

private struct RarityPreferenceRow: View {
    @Binding var preference: FlipNotificationRarityPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(preference.rarity.title, systemImage: preference.rarity.symbolName)
                    .font(.headline)
                    .foregroundStyle(preference.rarity.color)
                Spacer()
                Picker("Mode", selection: $preference.mode) {
                    ForEach(FlipNotificationMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbolName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            if preference.mode.usesAdvanceTime {
                Stepper(
                    "Show \(preference.advanceMinutes)m before",
                    value: $preference.advanceMinutes,
                    in: 1...1_440,
                    step: 5
                )
            } else {
                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(preference.rarity.orderLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var modeDescription: String {
        switch preference.mode {
        case .silent:
            "No notification for this rarity."
        case .event:
            "Regular notification at the flip moment."
        case .live:
            "Countdown-style notification before the flip."
        case .alarm:
            "Alarm-like time-sensitive notification before the flip."
        }
    }
}

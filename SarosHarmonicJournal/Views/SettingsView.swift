import SwiftData
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \JournalRecord.createdAt, order: .reverse) private var records: [JournalRecord]

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @AppStorage(JournalSettings.countdownMinimumTierKey) private var countdownMinimumTierSetting = JournalSettings.defaultCountdownMinimumTier
    @AppStorage(JournalSettings.catalogStartCenturyKey) private var catalogStartCentury = JournalSettings.defaultCatalogStartCentury
    @AppStorage(JournalSettings.catalogEndCenturyKey) private var catalogEndCentury = JournalSettings.defaultCatalogEndCentury
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""
    @AppStorage(JournalSettings.autoSyncEnabledKey) private var autoSyncEnabled = false
    @StateObject private var server = LocalExportServer()
    @State private var exportURL: URL?
    @State private var diagnosticMessage = ""
    @State private var syncMessage = ""
    @State private var errorMessage: String?
    @State private var isSyncing = false

    private var catalogBounds: CatalogCenturyBounds {
        CatalogCenturyBounds(startCentury: catalogStartCentury, endCentury: catalogEndCentury)
    }

    var body: some View {
        Form {
            Section("Saros clock") {
                Stepper(
                    "Glyph depth \(harmonicDepth)",
                    value: $harmonicDepth,
                    in: JournalSettings.supportedHarmonicDepth
                )

                Stepper(
                    "Countdown min tier \(countdownMinimumTier)",
                    value: countdownMinimumTierBinding,
                    in: JournalSettings.supportedCountdownTiers(for: harmonicDepth)
                )

                Text("Depth controls glyph shape and flip timing. Minimum tier controls the main screen countdown.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    TierPeriodsSettingsView()
                } label: {
                    Label("Periods", systemImage: "clock.arrow.circlepath")
                }
            }

            Section("Catalog") {
                Stepper(
                    "From \(JournalSettings.centuryLabel(catalogStartCentury)) century",
                    value: $catalogStartCentury,
                    in: JournalSettings.supportedCatalogCenturies
                )

                Stepper(
                    "Through \(JournalSettings.centuryLabel(catalogEndCentury)) century",
                    value: $catalogEndCentury,
                    in: JournalSettings.supportedCatalogCenturies
                )

                Text("Current catalog bounds: \(catalogBounds.displayTitle).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                NavigationLink {
                    FlipNotificationSettingsView()
                } label: {
                    Label("Flip tiers", systemImage: "slider.horizontal.3")
                }

                Button {
                    Task {
                        await services.notificationScheduler.refreshSchedules(
                            for: entities,
                            clockService: services.clockService,
                            harmonicDepth: harmonicDepth
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
        .onChange(of: harmonicDepth) { _, newDepth in
            countdownMinimumTierSetting = JournalSettings.clampedCountdownMinimumTier(
                countdownMinimumTierSetting,
                harmonicDepth: newDepth
            )
            Task {
                await services.notificationScheduler.refreshSchedules(
                    for: entities,
                    clockService: services.clockService,
                    harmonicDepth: newDepth
                )
                diagnosticMessage = "Glyph depth updated and notification schedule refreshed."
            }
        }
        .onChange(of: countdownMinimumTierSetting) { _, newTier in
            countdownMinimumTierSetting = JournalSettings.clampedCountdownMinimumTier(
                newTier,
                harmonicDepth: harmonicDepth
            )
        }
        .onChange(of: catalogStartCentury) { _, newCentury in
            catalogStartCentury = JournalSettings.clampedCatalogCentury(newCentury)
            if catalogStartCentury > catalogEndCentury {
                catalogEndCentury = catalogStartCentury
            }
        }
        .onChange(of: catalogEndCentury) { _, newCentury in
            catalogEndCentury = JournalSettings.clampedCatalogCentury(newCentury)
            if catalogEndCentury < catalogStartCentury {
                catalogStartCentury = catalogEndCentury
            }
        }
        .alert("Settings error", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var countdownMinimumTier: Int {
        JournalSettings.clampedCountdownMinimumTier(
            countdownMinimumTierSetting,
            harmonicDepth: harmonicDepth
        )
    }

    private var countdownMinimumTierBinding: Binding<Int> {
        Binding {
            countdownMinimumTier
        } set: { newValue in
            countdownMinimumTierSetting = JournalSettings.clampedCountdownMinimumTier(
                newValue,
                harmonicDepth: harmonicDepth
            )
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
}

private struct TierPeriodsSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    private var references: [PeriodSarosReference] {
        var seenSaroses: Set<Int> = []
        return entities.compactMap { entity in
            guard seenSaroses.insert(entity.saros).inserted else { return nil }
            return PeriodSarosReference(
                saros: entity.saros,
                title: entity.displayTitle
            )
        }
    }

    var body: some View {
        List {
            Section {
                MetadataRow(title: "Glyph depth", value: "\(JournalSettings.clampedHarmonicDepth(harmonicDepth))")
                Text("Half-periods are used to mark harmonic flip overlaps.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if references.isEmpty {
                Section {
                    ContentUnavailableView("No threads yet", systemImage: "clock.badge.questionmark")
                }
            } else {
                ForEach(references) { reference in
                    Section {
                        if let reading = reading(for: reference.saros) {
                            ForEach(FlipNotificationPreferences.tiers(for: harmonicDepth), id: \.self) { tier in
                                TierPeriodRow(tier: tier, reading: reading)
                            }
                        } else {
                            ContentUnavailableView("Periods unavailable", systemImage: "exclamationmark.triangle")
                        }
                    } header: {
                        Text("\(reference.title) · Saros \(reference.saros)")
                    }
                }
            }
        }
        .navigationTitle("Periods")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func reading(for saros: Int) -> SarosClockReading? {
        try? services.clockService.reading(
            saros: saros,
            date: Date(),
            harmonicDepth: harmonicDepth
        )
    }
}

private struct PeriodSarosReference: Identifiable, Hashable {
    let saros: Int
    let title: String

    var id: Int { saros }
}

private struct TierPeriodRow: View {
    let tier: Int
    let reading: SarosClockReading

    private var stride: Int {
        reading.qualifiedFlipStride(forTier: tier)
    }

    private var periodDuration: TimeInterval {
        Double(stride) * reading.binDuration
    }

    private var trailingZeroCount: Int {
        max(reading.harmonicDepth - tier - 1, 0)
    }

    private var stepOctalLabel: String {
        String(stride, radix: 8).leftPadded(toLength: trailingZeroCount + 1, withPad: "0")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tier \(tier)")
                    .font(.subheadline.weight(.semibold))
                Text("\(trailingZeroCount) trailing zeros · step \(stepOctalLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.durationFormatter.string(from: periodDuration) ?? periodDuration.compactDuration)
                    .font(.subheadline.weight(.semibold))
                Text("half \(Self.durationFormatter.string(from: periodDuration / 2) ?? (periodDuration / 2).compactDuration)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @State private var preferences: [FlipNotificationTierPreference] = []
    @State private var didLoad = false
    @State private var statusMessage = ""

    var body: some View {
        Form {
            Section {
                ForEach($preferences) { $preference in
                    TierPreferenceRow(preference: $preference)
                }
            } footer: {
                Text("Tier 1 is the largest carry. At depth 7, 7000000 is tier 1, 7210230 is tier 5, and a one-step flip is tier 6.")
            }

            Section {
                Button {
                    resetDefaults()
                } label: {
                    Label("Reset tier defaults", systemImage: "arrow.counterclockwise")
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Flip Tiers")
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
                    harmonicDepth: harmonicDepth
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

private struct TierPreferenceRow: View {
    @Binding var preference: FlipNotificationTierPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Tier \(preference.tier)", systemImage: tierSymbol)
                    .font(.headline)
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
        }
        .padding(.vertical, 4)
    }

    private var tierSymbol: String {
        switch preference.tier {
        case 1: "sparkles"
        case 2: "burst"
        default: "circle.grid.cross"
        }
    }

    private var modeDescription: String {
        switch preference.mode {
        case .silent:
            "No notification for this flip tier."
        case .event:
            "Regular notification at the flip moment."
        case .live:
            "Countdown-style notification before the flip."
        case .alarm:
            "Alarm-like time-sensitive notification before the flip."
        }
    }
}

import SwiftData
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \JournalRecord.createdAt, order: .reverse) private var records: [JournalRecord]

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @AppStorage(JournalSettings.catalogStartCenturyKey) private var catalogStartCentury = JournalSettings.defaultCatalogStartCentury
    @AppStorage(JournalSettings.catalogEndCenturyKey) private var catalogEndCentury = JournalSettings.defaultCatalogEndCentury
    @StateObject private var server = LocalExportServer()
    @State private var exportURL: URL?
    @State private var diagnosticMessage = ""
    @State private var errorMessage: String?

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
                Text("Controls octal glyph shape and flip timing for all threads.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            Task {
                await services.notificationScheduler.refreshSchedules(
                    for: entities,
                    clockService: services.clockService,
                    harmonicDepth: newDepth
                )
                diagnosticMessage = "Glyph depth updated and notification schedule refreshed."
            }
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

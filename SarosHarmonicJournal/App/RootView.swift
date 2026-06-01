import SwiftData
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case clock
    case catalog
    case camera
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: "Threads"
        case .catalog: "Catalog"
        case .camera: "Camera"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .clock: "moonphase.new.moon"
        case .catalog: "globe.americas"
        case .camera: "camera.viewfinder"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    screen(for: tab)
                }
                .tabItem {
                    Label(tab.title, systemImage: tab.symbol)
                }
            }
        }
        .background(AutoSyncObserver())
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .clock:
            ClockDashboardView()
        case .catalog:
            CatalogView()
        case .camera:
            MirrorCameraView()
        case .settings:
            SettingsView()
        }
    }
}

private struct AutoSyncObserver: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \JournalRecord.createdAt, order: .reverse) private var records: [JournalRecord]
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""
    @AppStorage(JournalSettings.autoSyncEnabledKey) private var autoSyncEnabled = false

    @State private var isSyncing = false
    @State private var lastCheckedFingerprint = ""

    private var syncFingerprint: String {
        [
            autoSyncEnabled ? "1" : "0",
            syncServerURL,
            records.map { $0.id.uuidString }.joined(separator: ",")
        ].joined(separator: "|")
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: syncFingerprint) {
                await scheduleAutoSync()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await scheduleAutoSync(force: true)
                }
            }
    }

    @MainActor
    private func scheduleAutoSync(force: Bool = false) async {
        guard autoSyncEnabled, syncServerURL.nilIfBlank != nil, !records.isEmpty else { return }

        if !force {
            try? await Task.sleep(nanoseconds: 850_000_000)
        }
        guard !Task.isCancelled else { return }

        await syncIfNeeded(force: force)
    }

    @MainActor
    private func syncIfNeeded(force: Bool) async {
        let fingerprint = syncFingerprint
        guard force || lastCheckedFingerprint != fingerprint else { return }
        guard !isSyncing else { return }

        isSyncing = true
        defer { isSyncing = false }

        do {
            _ = try await services.syncService.pushMissingRecords(
                to: syncServerURL,
                entities: entities,
                records: records
            )
            lastCheckedFingerprint = fingerprint
        } catch {
            // Keep auto sync quiet; manual sync controls surface detailed server errors.
        }
    }
}

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
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    @State private var selectedTab: AppTab = .clock
    @State private var captureEntity: TrackedEntity?

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    screen(for: tab)
                }
                .tabItem {
                    Label(tab.title, systemImage: tab.symbol)
                }
                .tag(tab)
            }
        }
        .background(AutoSyncObserver())
        .background(LiveTrackingRolloverObserver())
        .sheet(item: $captureEntity) { entity in
            NavigationStack {
                CaptureView(entity: entity, harmonicDepth: harmonicDepth) {}
            }
        }
        .onOpenURL(perform: handleDeepLink)
        .onReceive(NotificationCenter.default.publisher(for: .recordCaptureRequested)) { notification in
            if let entityID = notification.object as? UUID {
                openRecordCapture(for: entityID)
            } else if let entityIDString = notification.userInfo?["entityID"] as? String,
                      let entityID = UUID(uuidString: entityIDString) {
                openRecordCapture(for: entityID)
            }
        }
        .task {
            consumePendingRecordCapture()
        }
        .onChange(of: entities.map(\.id)) { _, _ in
            consumePendingRecordCapture()
        }
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

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "exeligmos" else { return }

        switch url.host {
        case "record":
            guard let entityID = entityID(from: url) else { return }
            openRecordCapture(for: entityID)
        case "thread":
            selectedTab = .clock
        default:
            break
        }
    }

    private func entityID(from url: URL) -> UUID? {
        let idString = url.pathComponents.dropFirst().first
        return idString.flatMap(UUID.init(uuidString:))
    }

    private func openRecordCapture(for entityID: UUID) {
        guard let entity = entities.first(where: { $0.id == entityID }) else {
            AppDeepLinkStore.storePendingRecordCapture(entityID: entityID)
            return
        }

        selectedTab = .clock
        captureEntity = entity
    }

    private func consumePendingRecordCapture() {
        guard let entityID = AppDeepLinkStore.consumePendingRecordCapture() else { return }
        openRecordCapture(for: entityID)
    }
}

extension Notification.Name {
    static let recordCaptureRequested = Notification.Name("recordCaptureRequested")
}

enum AppDeepLinkStore {
    private static let pendingRecordCaptureKey = "pendingRecordCaptureEntityID"

    static func storePendingRecordCapture(entityID: UUID) {
        UserDefaults.standard.set(entityID.uuidString, forKey: pendingRecordCaptureKey)
    }

    static func consumePendingRecordCapture() -> UUID? {
        guard let idString = UserDefaults.standard.string(forKey: pendingRecordCaptureKey) else {
            return nil
        }

        UserDefaults.standard.removeObject(forKey: pendingRecordCaptureKey)
        return UUID(uuidString: idString)
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
        guard syncServerURL.nilIfBlank != nil else { return }

        if !force {
            try? await Task.sleep(nanoseconds: 850_000_000)
        }
        guard !Task.isCancelled else { return }

        let hasPendingDataset = ((try? services.animacyDatasetQueue.summary().hasPendingUploads) ?? false)
        guard autoSyncEnabled || hasPendingDataset else { return }

        await syncIfNeeded(force: force || hasPendingDataset)
    }

    @MainActor
    private func syncIfNeeded(force: Bool) async {
        let fingerprint = syncFingerprint
        guard force || lastCheckedFingerprint != fingerprint else { return }
        guard !isSyncing else { return }

        isSyncing = true
        defer { isSyncing = false }

        do {
            if autoSyncEnabled, !records.isEmpty {
                _ = try await services.syncService.pushMissingRecords(
                    to: syncServerURL,
                    entities: entities,
                    records: records
                )
            }
            _ = try await services.animacyDatasetQueue.uploadPending(to: syncServerURL)
            lastCheckedFingerprint = fingerprint
        } catch {
            // Keep auto sync quiet; manual sync controls surface detailed server errors.
        }
    }
}

private struct LiveTrackingRolloverObserver: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]

    @State private var isUpdating = false
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                await rollOverIfNeeded(at: Date())
            }
            .onReceive(timer) { date in
                now = date
                guard scenePhase == .active else { return }
                Task {
                    await rollOverIfNeeded(at: date)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await rollOverIfNeeded(at: now)
                }
            }
    }

    @MainActor
    private func rollOverIfNeeded(at date: Date) async {
        guard !isUpdating,
              let snapshot = ThreadTrackingSharedStore.load(),
              date >= snapshot.flipDate.addingTimeInterval(ThreadTrackingSharedStore.flipRolloverDelay),
              let entityID = UUID(uuidString: snapshot.threadID),
              let entity = entities.first(where: { $0.id == entityID })
        else {
            return
        }

        isUpdating = true
        defer { isUpdating = false }

        do {
            let reading = try services.clockService.reading(
                saros: entity.saros,
                date: date,
                harmonicDepth: snapshot.harmonicDepth
            )
            let trackingRarity = FlipRarity(rawValue: snapshot.rarityRawValue) ?? .common
            let nextSnapshot = ThreadLiveActivityService.snapshot(
                entity: entity,
                reading: reading,
                trackingRarity: trackingRarity
            )
            guard nextSnapshot.flipDate > snapshot.flipDate.addingTimeInterval(0.5) else { return }
            try await ThreadLiveActivityService.start(snapshot: nextSnapshot)
        } catch {
            // Live tracking should not disturb normal app navigation if a rollover cannot be refreshed.
        }
    }
}

import SwiftData
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case feed
    case clock
    case catalog
    case camera
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feed: "Feed"
        case .clock: "Threads"
        case .catalog: "Catalog"
        case .camera: "Camera"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .feed: "rectangle.stack"
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

    @State private var selectedTab: AppTab = .feed
    @State private var captureRequest: RecordCaptureRequest?

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
        .sheet(item: $captureRequest) { request in
            NavigationStack {
                CaptureView(
                    entity: request.entity,
                    harmonicDepth: harmonicDepth,
                    recordStartedAt: request.startedAt
                ) {}
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
        case .feed:
            FeedView()
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
        captureRequest = RecordCaptureRequest(entity: entity, startedAt: Date())
    }

    private func consumePendingRecordCapture() {
        guard let entityID = AppDeepLinkStore.consumePendingRecordCapture() else { return }
        openRecordCapture(for: entityID)
    }
}

private struct RecordCaptureRequest: Identifiable {
    let id = UUID()
    let entity: TrackedEntity
    let startedAt: Date
}

private struct FeedView: View {
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \JournalRecord.eventDate, order: .reverse) private var records: [JournalRecord]
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    @State private var selectedRarity: FlipRarity?
    @State private var dateFilterMode: FeedDateFilterMode = .all
    @State private var selectedDate = Date()
    @State private var selectedRecord: JournalRecord?

    private var entityTitlesByID: [UUID: String] {
        Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0.displayTitle) })
    }

    private var filteredRecords: [JournalRecord] {
        records.filter { record in
            let matchesRarity = selectedRarity.map { recordRarity(for: record) == $0 } ?? true
            let matchesDate = switch dateFilterMode {
            case .all:
                true
            case .day:
                Calendar.current.isDate(record.eventDate, inSameDayAs: selectedDate)
            }
            return matchesRarity && matchesDate
        }
    }

    private var recordGroups: [FeedRecordDayGroup] {
        let calendar = Calendar.current
        return Dictionary(grouping: filteredRecords) { record in
            calendar.startOfDay(for: record.eventDate)
        }
        .map { day, records in
            FeedRecordDayGroup(
                day: day,
                records: records.sorted { $0.eventDate > $1.eventDate }
            )
        }
        .sorted { $0.day > $1.day }
    }

    var body: some View {
        List {
            filterSection

            if records.isEmpty {
                Section {
                    ContentUnavailableView("No records yet", systemImage: "rectangle.stack")
                }
            } else if filteredRecords.isEmpty {
                Section {
                    ContentUnavailableView("No matching records", systemImage: "line.3.horizontal.decrease.circle")
                }
            } else {
                ForEach(recordGroups) { group in
                    Section {
                        ForEach(group.records) { record in
                            Button {
                                selectedRecord = record
                            } label: {
                                JournalRecordRow(
                                    record: record,
                                    entityTitle: entityTitle(for: record),
                                    rarity: recordRarity(for: record)
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.visible)
                            .listRowSeparatorTint(.white.opacity(0.28))
                        }
                    } header: {
                        Text(dayTitle(for: group.day))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    }
                }
            }
        }
        .navigationTitle("Feed")
        .navigationDestination(item: $selectedRecord) { record in
            JournalRecordDetailView(
                record: record,
                entityTitle: entityTitle(for: record)
            )
        }
    }

    private var filterSection: some View {
        Section("Filters") {
            Picker("Rarity", selection: $selectedRarity) {
                Text("All rarities").tag(nil as FlipRarity?)
                ForEach(FlipRarity.visibleRarities(for: harmonicDepth)) { rarity in
                    Label(rarity.title, systemImage: rarity.symbolName)
                        .tag(Optional(rarity))
                }
            }
            .pickerStyle(.menu)

            Picker("Date", selection: $dateFilterMode) {
                ForEach(FeedDateFilterMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if dateFilterMode == .day {
                DatePicker("Day", selection: $selectedDate, displayedComponents: .date)
            }
        }
    }

    private func entityTitle(for record: JournalRecord) -> String {
        entityTitlesByID[record.entityID] ?? "Saros \(record.saros)"
    }

    private func recordRarity(for record: JournalRecord) -> FlipRarity {
        FlipRarity.rarity(
            forOrder: FlipRarity.order(forOctalAddress: record.octalAddress, harmonicDepth: record.harmonicDepth),
            isEclipse: record.triggerType == .eclipse
        )
    }

    private func dayTitle(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(day) {
            return "Yesterday"
        }
        return JournalFormatters.date.string(from: day)
    }
}

private enum FeedDateFilterMode: String, CaseIterable, Identifiable {
    case all
    case day

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Dates"
        case .day: "Day"
        }
    }
}

private struct FeedRecordDayGroup: Identifiable {
    let day: Date
    let records: [JournalRecord]

    var id: Date { day }
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
    @Query(sort: \ThreadGroup.createdAt, order: .forward) private var threadGroups: [ThreadGroup]
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
                    records: records,
                    groups: threadGroups
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

import SwiftData
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case feed
    case clock
    case saros
    case record
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feed: "Feed"
        case .clock: "Tags"
        case .saros: "Saros"
        case .record: "Record"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .feed: "rectangle.stack"
        case .clock: "tag"
        case .saros: "circle.grid.3x3"
        case .record: "square.and.pencil"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var services: AppServices
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
            prewarmSarosFlipDistribution()
            refreshSarosEventNotifications()
        }
        .onChange(of: harmonicDepth) { _, _ in
            prewarmSarosFlipDistribution()
            refreshSarosEventNotifications()
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
            TagsView()
        case .saros:
            SarosGridView()
        case .record:
            JournalTemplatesView()
        case .settings:
            SettingsView()
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "exeligmos" else { return }

        switch url.host {
        case "record":
            if let entityID = entityID(from: url) {
                openRecordCapture(for: entityID)
            } else {
                selectedTab = .record
            }
        case "thread":
            selectedTab = .clock
        case "saros":
            selectedTab = .saros
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

    private func prewarmSarosFlipDistribution() {
        Task {
            await services.sarosFlipDistributionStore.prewarm(
                around: Date(),
                harmonicDepth: harmonicDepth,
                eclipseService: services.eclipseService
            )
        }
    }

    private func refreshSarosEventNotifications() {
        Task {
            await services.notificationScheduler.refreshGlobalSarosEventSchedules(
                eclipseService: services.eclipseService,
                harmonicDepth: harmonicDepth
            )
        }
    }
}

private struct RecordCaptureRequest: Identifiable {
    let id = UUID()
    let entity: TrackedEntity
    let startedAt: Date
}

private struct FeedView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \JournalEntry.eventDate, order: .reverse) private var entries: [JournalEntry]
    @Query(sort: \JournalTag.createdAt, order: .forward) private var tags: [JournalTag]
    @Query(sort: \JournalEntryDraft.updatedAt, order: .reverse) private var entryDrafts: [JournalEntryDraft]
    @Query(sort: \SyncLocalCommand.createdAt, order: .forward) private var syncCommands: [SyncLocalCommand]
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""

    @State private var selectedRarity: FlipRarity?
    @State private var selectedDirection: JournalWaveDirection?
    @State private var selectedExtremum: JournalWaveExtremum?
    @State private var dateFilterMode: FeedDateFilterMode = .all
    @State private var selectedDate = Date()
    @State private var selectedSaros: Int?
    @State private var selectedSynodicBin: Int?
    @State private var selectedAnomalisticBin: Int?
    @State private var selectedDraconicBin: Int?
    @State private var selectedEntry: JournalEntry?
    @State private var captureRequest: FeedCaptureRequest?
    @State private var isFilterPresented = false
    @State private var syncErrorMessage: String?

    private var filteredEntries: [JournalEntry] {
        entries.filter { entry in
            let context = entry.context
            let closestRarity = context.closestSpike?.rarity.baseRarity ?? .common
            let matchesRarity = selectedRarity.map { closestRarity == $0.baseRarity } ?? true
            let matchesDirection = selectedDirection.map { context.direction == $0 } ?? true
            let matchesExtremum = selectedExtremum.map { context.extremum == $0 } ?? true
            let matchesSaros = selectedSaros.map { context.sarosNumbers.contains($0) } ?? true
            let matchesMoon = matchesMoonFilters(entry.eventDate)
            let matchesDate = switch dateFilterMode {
            case .all:
                true
            case .day:
                Calendar.current.isDate(entry.eventDate, inSameDayAs: selectedDate)
            }
            return matchesRarity && matchesDirection && matchesExtremum && matchesSaros && matchesMoon && matchesDate
        }
    }

    private var entryGroups: [FeedEntryDayGroup] {
        let calendar = Calendar.current
        return Dictionary(grouping: filteredEntries) { entry in
            calendar.startOfDay(for: entry.eventDate)
        }
        .map { day, entries in
            FeedEntryDayGroup(
                day: day,
                entries: entries.sorted { $0.eventDate > $1.eventDate }
            )
        }
        .sorted { $0.day > $1.day }
    }

    private var primeColorsBySaros: [Int: Color] {
        tags.filter(\.isPrime).reduce(into: [Int: Color]()) { colors, tag in
            colors[tag.saros] = colors[tag.saros] ?? Color(hex: tag.tintHex, fallback: .white)
        }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    ContentUnavailableView("No entries yet", systemImage: "rectangle.stack")
                }
            } else if filteredEntries.isEmpty {
                Section {
                    ContentUnavailableView("No matching entries", systemImage: "line.3.horizontal.decrease.circle")
                }
            } else {
                ForEach(entryGroups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            Button {
                                selectedEntry = entry
                            } label: {
                                JournalEntryRow(entry: entry, tags: tags)
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
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refreshFromRelay()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isFilterPresented = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter feed")

                Button {
                    if let draft = entryDrafts.first {
                        captureRequest = .draft(draft)
                    } else {
                        captureRequest = .template(.random)
                    }
                } label: {
                    Image(systemName: "record.circle")
                }
                .accessibilityLabel("Record entry")
            }
        }
        .navigationDestination(item: $selectedEntry) { entry in
            JournalEntryDetailView(entry: entry, tags: tags)
        }
        .sheet(item: $captureRequest) { request in
            NavigationStack {
                switch request {
                case .template(let template):
                    JournalEntryCaptureView(recordStartedAt: Date(), template: template)
                case .draft(let draft):
                    JournalEntryCaptureView(draft: draft)
                }
            }
        }
        .sheet(isPresented: $isFilterPresented) {
            NavigationStack {
                JournalEntryFeedFilterView(
                    selectedRarity: $selectedRarity,
                    selectedDirection: $selectedDirection,
                    selectedExtremum: $selectedExtremum,
                    dateFilterMode: $dateFilterMode,
                    selectedDate: $selectedDate,
                    selectedSaros: $selectedSaros,
                    selectedSynodicBin: $selectedSynodicBin,
                    selectedAnomalisticBin: $selectedAnomalisticBin,
                    selectedDraconicBin: $selectedDraconicBin,
                    primeColorsBySaros: primeColorsBySaros
                )
            }
        }
        .alert("Sync failed", isPresented: Binding(get: { syncErrorMessage != nil }, set: { _ in syncErrorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(syncErrorMessage ?? "")
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
            syncErrorMessage = error.localizedDescription
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

private enum FeedCaptureRequest: Identifiable {
    case template(JournalTemplateSeed)
    case draft(JournalEntryDraft)

    var id: String {
        switch self {
        case .template(let template):
            "template-\(template.id)"
        case .draft(let draft):
            "draft-\(draft.id.uuidString)"
        }
    }
}

private struct JournalEntryFeedFilterView: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedRarity: FlipRarity?
    @Binding var selectedDirection: JournalWaveDirection?
    @Binding var selectedExtremum: JournalWaveExtremum?
    @Binding var dateFilterMode: FeedDateFilterMode
    @Binding var selectedDate: Date
    @Binding var selectedSaros: Int?
    @Binding var selectedSynodicBin: Int?
    @Binding var selectedAnomalisticBin: Int?
    @Binding var selectedDraconicBin: Int?

    let primeColorsBySaros: [Int: Color]

    var body: some View {
        Form {
            Section {
                if let selectedSaros {
                    Button {
                        self.selectedSaros = nil
                    } label: {
                        Label("Clear Saros \(selectedSaros)", systemImage: "xmark.circle")
                    }
                }

                SarosGlyphGridPicker(
                    selectedSaros: $selectedSaros,
                    primeColorsBySaros: primeColorsBySaros
                )
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                .listRowBackground(Color.clear)
            } header: {
                Text("Saros")
            }

            Section("Wave") {
                Picker("Closest rarity", selection: $selectedRarity) {
                    Text("All rarities").tag(nil as FlipRarity?)
                    ForEach(FlipRarity.eventBaseRarities) { rarity in
                        Text(rarity.title).tag(Optional(rarity))
                    }
                }

                Picker("Direction", selection: $selectedDirection) {
                    Text("All directions").tag(nil as JournalWaveDirection?)
                    ForEach(JournalWaveDirection.allCases) { direction in
                        Text(direction.title).tag(Optional(direction))
                    }
                }

                Picker("Extremum", selection: $selectedExtremum) {
                    Text("All extrema").tag(nil as JournalWaveExtremum?)
                    ForEach(JournalWaveExtremum.allCases) { extremum in
                        Text(extremum.title).tag(Optional(extremum))
                    }
                }
            }

            Section("Moon") {
                MoonBinPicker(title: "Synodic", selection: $selectedSynodicBin)
                MoonBinPicker(title: "Anomalistic", selection: $selectedAnomalisticBin)
                MoonBinPicker(title: "Draconic", selection: $selectedDraconicBin)
            }

            Section("Date") {
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

            Section {
                Button {
                    clearFilters()
                } label: {
                    Label("Clear filters", systemImage: "xmark.circle")
                }
            }
        }
        .navigationTitle("Filters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    private func clearFilters() {
        selectedRarity = nil
        selectedDirection = nil
        selectedExtremum = nil
        selectedSaros = nil
        selectedSynodicBin = nil
        selectedAnomalisticBin = nil
        selectedDraconicBin = nil
        dateFilterMode = .all
    }
}

struct MoonBinPicker: View {
    let title: String
    @Binding var selection: Int?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Any").tag(nil as Int?)
            ForEach(0..<8, id: \.self) { bin in
                Text("\(bin)").tag(Optional(bin))
            }
        }
        .pickerStyle(.menu)
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

private struct FeedEntryDayGroup: Identifiable {
    let day: Date
    let entries: [JournalEntry]

    var id: Date { day }
}

private struct MoonPhaseClockCard: View {
    let reading: MoonPhaseOctalReading

    var body: some View {
        HStack(spacing: 16) {
            MoonPhaseGlyph(reading: reading)
                .frame(width: 74, height: 74)
                .padding(8)
                .background(reading.rarity.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text("Moon")
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(reading.octalAddress)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .contentTransition(.numericText())
                    FlipRarityBadge(rarity: reading.rarity, compact: true)
                }
                Text(reading.phaseReading.phase.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
        }
        .padding(.vertical, 4)
    }
}

private struct MoonTimelineScreen: View {
    @EnvironmentObject private var services: AppServices
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    @State private var pixelsPerDay: Double = 120
    @State private var anchorDate = Date()

    private var startDate: Date {
        Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: anchorDate)) ?? anchorDate
    }

    private var endDate: Date {
        Calendar.current.date(byAdding: .day, value: 120, to: Calendar.current.startOfDay(for: anchorDate)) ?? anchorDate.addingTimeInterval(120 * 86_400)
    }

    private var model: MoonTimelineModel {
        MoonTimelineModelBuilder.make(
            startDate: startDate,
            endDate: endDate,
            now: anchorDate,
            pixelsPerDay: pixelsPerDay,
            entities: entities,
            moonService: services.moonPhaseService,
            clockService: services.clockService,
            harmonicDepth: harmonicDepth
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $pixelsPerDay, in: 56...420)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            ScrollView(.vertical) {
                MoonTimelineCanvas(model: model)
                    .frame(height: model.height)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .scrollIndicators(.visible)
        }
        .navigationTitle("Timeline")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MoonTimelineCanvas: View {
    let model: MoonTimelineModel

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let background = RoundedRectangle(cornerRadius: 8).path(in: rect)
            context.fill(background, with: .color(Color(.secondarySystemBackground)))
            context.stroke(background, with: .color(.secondary.opacity(0.2)), lineWidth: 1)

            drawDayBoundaries(in: &context, size: size)
            drawNowLine(in: &context, size: size)
            drawLunarEvents(in: &context, size: size)
            drawSarosEvents(in: &context, size: size)
            drawLaneLabels(in: &context, size: size)
        }
    }

    private func drawDayBoundaries(in context: inout GraphicsContext, size: CGSize) {
        for boundary in model.dayBoundaries {
            let y = model.y(for: boundary.date)
            var path = Path()
            path.move(to: CGPoint(x: 10, y: y))
            path.addLine(to: CGPoint(x: size.width - 10, y: y))
            context.stroke(path, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

            context.draw(
                Text(boundary.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary),
                at: CGPoint(x: 12, y: y + 11),
                anchor: .leading
            )
        }
    }

    private func drawNowLine(in context: inout GraphicsContext, size: CGSize) {
        let y = model.y(for: model.now)
        var path = Path()
        path.move(to: CGPoint(x: 10, y: y))
        path.addLine(to: CGPoint(x: size.width - 10, y: y))
        context.stroke(path, with: .color(.white.opacity(0.65)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
        context.draw(
            Text("Now")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85)),
            at: CGPoint(x: size.width - 14, y: y - 8),
            anchor: .trailing
        )
    }

    private func drawLunarEvents(in context: inout GraphicsContext, size: CGSize) {
        let x = lunarLaneX(in: size)

        for event in model.lunarEvents {
            let y = model.y(for: event.date)
            let color = event.color
            var path = Path()
            path.move(to: CGPoint(x: x - event.markLength / 2, y: y))
            path.addLine(to: CGPoint(x: x + event.markLength / 2, y: y))
            context.stroke(path, with: .color(color.opacity(event.opacity)), lineWidth: event.lineWidth)

            if let label = event.label {
                context.draw(
                    Text(label)
                        .font(.caption2.weight(event.isMajor ? .semibold : .regular))
                        .foregroundStyle(color),
                    at: CGPoint(x: x - event.markLength / 2 - 8, y: y),
                    anchor: .trailing
                )
            }
        }
    }

    private func drawSarosEvents(in context: inout GraphicsContext, size: CGSize) {
        let x = sarosLaneX(in: size)

        for event in model.sarosEvents {
            let y = model.y(for: event.date)
            var path = Path()
            path.move(to: CGPoint(x: x - event.markLength / 2, y: y))
            path.addLine(to: CGPoint(x: x + event.markLength / 2, y: y))
            context.stroke(path, with: .color(event.rarity.color.opacity(0.88)), lineWidth: event.lineWidth)

            if event.shouldLabel {
                context.draw(
                    Text(event.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(event.rarity.color.opacity(0.95)),
                    at: CGPoint(x: x + event.markLength / 2 + 6, y: y),
                    anchor: .leading
                )
            }
        }
    }

    private func drawLaneLabels(in context: inout GraphicsContext, size: CGSize) {
        context.draw(
            Text("Lunar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary),
            at: CGPoint(x: lunarLaneX(in: size), y: 34),
            anchor: .center
        )
        context.draw(
            Text("Saros")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary),
            at: CGPoint(x: sarosLaneX(in: size), y: 34),
            anchor: .center
        )
        context.draw(
            Text("Days")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary),
            at: CGPoint(x: 20, y: 34),
            anchor: .leading
        )
    }

    private func lunarLaneX(in size: CGSize) -> CGFloat {
        max(220, size.width - 86)
    }

    private func sarosLaneX(in size: CGSize) -> CGFloat {
        max(150, size.width * 0.52)
    }
}

private struct MoonTimelineModel {
    let startDate: Date
    let endDate: Date
    let now: Date
    let pixelsPerDay: Double
    let dayBoundaries: [MoonTimelineDayBoundary]
    let lunarEvents: [MoonTimelineLunarEvent]
    let sarosEvents: [MoonTimelineSarosEvent]

    var height: CGFloat {
        CGFloat(max(endDate.timeIntervalSince(startDate) / 86_400 * pixelsPerDay, 1_200)) + topInset + bottomInset
    }

    func y(for date: Date) -> CGFloat {
        topInset + CGFloat(date.timeIntervalSince(startDate) / 86_400 * pixelsPerDay)
    }

    private var topInset: CGFloat { 72 }
    private var bottomInset: CGFloat { 80 }
}

private struct MoonTimelineDayBoundary: Identifiable {
    let id = UUID()
    let date: Date
    let label: String
}

private struct MoonTimelineLunarEvent: Identifiable {
    let id = UUID()
    let date: Date
    let rarity: FlipRarity
    let label: String?
    let kind: MoonTimelineLunarEventKind

    var color: Color {
        switch kind {
        case .phaseSubdivision, .newMoon:
            rarity.color
        case .fullMoon:
            .cyan
        case .apogee:
            .orange
        case .perigee:
            .pink
        case .ascendingNode:
            .green
        case .descendingNode:
            .mint
        }
    }

    var markLength: CGFloat {
        switch kind {
        case .fullMoon: return 116
        case .apogee, .perigee: return 84
        case .ascendingNode, .descendingNode: return 70
        default: break
        }

        switch rarity.baseRarity {
        case .legendary: return 126
        case .epic: return 92
        case .rare: return 52
        default: return 30
        }
    }

    var lineWidth: CGFloat {
        switch kind {
        case .fullMoon:
            return 1.8
        case .apogee, .perigee, .ascendingNode, .descendingNode:
            return 1.4
        default:
            break
        }
        return rarity >= .epic ? 2 : 1
    }

    var opacity: Double {
        kind == .phaseSubdivision && rarity.baseRarity == .rare ? 0.55 : 0.9
    }

    var isMajor: Bool {
        kind != .phaseSubdivision || rarity >= .epic
    }
}

private enum MoonTimelineLunarEventKind {
    case phaseSubdivision
    case newMoon
    case fullMoon
    case apogee
    case perigee
    case ascendingNode
    case descendingNode
}

private struct MoonTimelineSarosEvent: Identifiable {
    let id = UUID()
    let date: Date
    let title: String
    let rarity: FlipRarity
    let octalAddress: String

    var markLength: CGFloat {
        switch rarity.baseRarity {
        case .mythic: return 118
        case .legendary: return 96
        case .epic: return 74
        default: return 52
        }
    }

    var lineWidth: CGFloat {
        rarity >= .legendary ? 2 : 1.2
    }

    var shouldLabel: Bool {
        rarity >= .epic
    }

    var label: String {
        title
    }
}

private enum MoonTimelineModelBuilder {
    static func make(
        startDate: Date,
        endDate: Date,
        now: Date,
        pixelsPerDay: Double,
        entities: [TrackedEntity],
        moonService: any MoonPhaseService,
        clockService: any SarosClockService,
        harmonicDepth: Int
    ) -> MoonTimelineModel {
        MoonTimelineModel(
            startDate: startDate,
            endDate: endDate,
            now: now,
            pixelsPerDay: pixelsPerDay,
            dayBoundaries: makeDayBoundaries(startDate: startDate, endDate: endDate),
            lunarEvents: makeLunarEvents(startDate: startDate, endDate: endDate, moonService: moonService),
            sarosEvents: makeSarosEvents(
                startDate: startDate,
                endDate: endDate,
                entities: entities,
                clockService: clockService,
                harmonicDepth: harmonicDepth
            )
        )
    }

    private static func makeDayBoundaries(startDate: Date, endDate: Date) -> [MoonTimelineDayBoundary] {
        var calendar = Calendar.current
        calendar.timeZone = .current
        var cursor = calendar.startOfDay(for: startDate)
        var boundaries: [MoonTimelineDayBoundary] = []

        while cursor <= endDate {
            boundaries.append(MoonTimelineDayBoundary(
                date: cursor,
                label: dayLabel.string(from: cursor)
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return boundaries
    }

    private static func makeLunarEvents(
        startDate: Date,
        endDate: Date,
        moonService: any MoonPhaseService
    ) -> [MoonTimelineLunarEvent] {
        var events: [MoonTimelineLunarEvent] = []

        if let startReading = try? moonService.reading(for: startDate) {
            var cycleStart = startReading.previousNewMoon.date
            var cycleEnd = startReading.nextNewMoon.date

            while cycleStart <= endDate {
                appendMoonRarityTicks(
                    into: &events,
                    cycleStart: cycleStart,
                    cycleEnd: cycleEnd,
                    visibleStart: startDate,
                    visibleEnd: endDate
                )

                let nextSeed = cycleEnd.addingTimeInterval(1)
                guard let nextReading = try? moonService.reading(for: nextSeed),
                      nextReading.nextNewMoon.date > cycleEnd
                else { break }
                cycleStart = nextReading.previousNewMoon.date
                cycleEnd = nextReading.nextNewMoon.date
            }
        }

        var cursor = startDate
        while cursor <= endDate {
            guard let reading = try? moonService.reading(for: cursor) else { break }
            let event = reading.nextEvent
            guard event.date <= endDate else { break }
            if event.date >= startDate {
                let isNew = event.kind == .new
                events.append(MoonTimelineLunarEvent(
                    date: event.date,
                    rarity: isNew ? .mythicDigit(7) : .legendaryDigit(7),
                    label: isNew ? "New" : "Full",
                    kind: isNew ? .newMoon : .fullMoon
                ))
            }
            cursor = event.date.addingTimeInterval(1)
        }

        if let orbitalEvents = try? moonService.orbitalEvents(from: startDate, through: endDate) {
            events.append(contentsOf: orbitalEvents.map { event in
                MoonTimelineLunarEvent(
                    date: event.date,
                    rarity: .epicDigit(7),
                    label: moonOrbitalTimelineLabel(for: event.kind),
                    kind: moonTimelineKind(for: event.kind)
                )
            })
        }

        return events.sorted { $0.date < $1.date }
    }

    private static func appendMoonRarityTicks(
        into events: inout [MoonTimelineLunarEvent],
        cycleStart: Date,
        cycleEnd: Date,
        visibleStart: Date,
        visibleEnd: Date
    ) {
        let duration = max(cycleEnd.timeIntervalSince(cycleStart), 1)
        let binCount = 512

        for boundaryIndex in stride(from: 8, through: binCount - 8, by: 8) {
            guard let rarity = lunarTimelineRarity(forBoundaryIndex: boundaryIndex, depth: 3),
                  rarity >= .epic
            else {
                continue
            }

            let date = cycleStart.addingTimeInterval(Double(boundaryIndex) / Double(binCount) * duration)
            guard date >= visibleStart && date <= visibleEnd else { continue }

            events.append(MoonTimelineLunarEvent(
                date: date,
                rarity: rarity,
                label: nil,
                kind: .phaseSubdivision
            ))
        }
    }

    private static func moonOrbitalTimelineLabel(for kind: MoonOrbitalEventKind) -> String {
        switch kind {
        case .apogee: "Apo"
        case .perigee: "Peri"
        case .ascendingNode: "Asc"
        case .descendingNode: "Desc"
        }
    }

    private static func moonTimelineKind(for kind: MoonOrbitalEventKind) -> MoonTimelineLunarEventKind {
        switch kind {
        case .apogee: .apogee
        case .perigee: .perigee
        case .ascendingNode: .ascendingNode
        case .descendingNode: .descendingNode
        }
    }

    private static func lunarTimelineRarity(forBoundaryIndex index: Int, depth: Int) -> FlipRarity? {
        let address = String(index, radix: 8).leftPadded(toLength: depth, withPad: "0")
        let rarity = FlipRarity.rarity(forOctalAddress: address, harmonicDepth: depth)
        return rarity.isHeaderRarity ? nil : rarity
    }

    private static func makeSarosEvents(
        startDate: Date,
        endDate: Date,
        entities: [TrackedEntity],
        clockService: any SarosClockService,
        harmonicDepth: Int
    ) -> [MoonTimelineSarosEvent] {
        var eventsByKey: [String: MoonTimelineSarosEvent] = [:]
        let regularRarities = FlipRarity
            .eventRarities(for: harmonicDepth)
            .filter { $0 >= .epic }

        let sarosFamilies = Array(Set(entities.map(\.saros))).sorted()

        for saros in sarosFamilies {
            guard let reading = try? clockService.reading(
                saros: saros,
                date: startDate,
                harmonicDepth: harmonicDepth
            ) else {
                continue
            }

            for rarity in regularRarities {
                var nextBin = reading.nextQualifiedFlipBin(after: reading.binIndex, rarity: rarity, exact: true)
                while let binIndex = nextBin {
                    let date = reading.date(forBinIndex: binIndex)
                    guard date <= endDate else { break }
                    if date >= startDate {
                        let actualRarity = reading.flipRarity(forBinIndex: binIndex)
                        guard actualRarity >= .epic else {
                            nextBin = reading.nextQualifiedFlipBin(after: binIndex, rarity: rarity, exact: true)
                            continue
                        }
                        let key = "\(saros)-\(binIndex)"
                        let event = MoonTimelineSarosEvent(
                            date: date,
                            title: "\(saros)",
                            rarity: actualRarity,
                            octalAddress: reading.octalAddress(forBinIndex: binIndex)
                        )
                        if let existing = eventsByKey[key] {
                            if event.rarity > existing.rarity {
                                eventsByKey[key] = event
                            }
                        } else {
                            eventsByKey[key] = event
                        }
                    }
                    nextBin = reading.nextQualifiedFlipBin(after: binIndex, rarity: rarity, exact: true)
                }
            }
        }

        return eventsByKey.values.sorted {
            if $0.date == $1.date {
                return $0.rarity > $1.rarity
            }
            return $0.date < $1.date
        }
    }

    private static let dayLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()
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
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \JournalTag.createdAt, order: .forward) private var tags: [JournalTag]
    @Query(sort: \JournalEntry.eventDate, order: .reverse) private var entries: [JournalEntry]
    @Query(sort: \SyncLocalCommand.createdAt, order: .forward) private var syncCommands: [SyncLocalCommand]
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""

    @State private var isSyncing = false
    @State private var lastCheckedFingerprint = ""

    private var syncFingerprint: String {
        "\(syncServerURL)|\(commandFingerprint)"
    }

    private var commandFingerprint: String {
        syncCommands
            .filter(\.isPending)
            .map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970):\($0.typeRawValue):\($0.subjectID)" }
            .joined(separator: ",")
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: syncFingerprint) {
                await pushPendingCommands()
            }
    }

    @MainActor
    private func pushPendingCommands() async {
        guard syncServerURL.nilIfBlank != nil else { return }
        try? await Task.sleep(nanoseconds: 850_000_000)
        guard !Task.isCancelled else { return }
        let hasPendingCommands = syncCommands.contains(where: \.isPending)
        guard hasPendingCommands else { return }
        let fingerprint = syncFingerprint
        guard lastCheckedFingerprint != fingerprint else { return }
        guard !isSyncing else { return }

        isSyncing = true
        defer { isSyncing = false }

        do {
            _ = try await services.syncService.pushPendingLocalCommands(
                with: syncServerURL,
                modelContext: modelContext,
                tags: tags,
                entries: entries,
                commands: syncCommands
            )
            lastCheckedFingerprint = fingerprint
        } catch {
            // Keep background command sending quiet; manual refresh surfaces detailed relay errors.
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
              let snapshot = ThreadTrackingSharedStore.load()
        else {
            return
        }
        let shouldRefreshForFlip = date >= snapshot.flipDate.addingTimeInterval(ThreadTrackingSharedStore.flipRolloverDelay)
        let shouldRefreshForWaveform = snapshot.threadID == ThreadTrackingSharedStore.journalTrackingID
            && snapshot.waveformEndDate.map { date >= $0 } == true
        guard shouldRefreshForFlip || shouldRefreshForWaveform else { return }

        isUpdating = true
        defer { isUpdating = false }

        do {
            if snapshot.threadID == ThreadTrackingSharedStore.journalTrackingID {
                let contextService = services.sarosEventContextService
                let harmonicDepth = snapshot.harmonicDepth
                let nextSnapshot = try await Task.detached(priority: .userInitiated) {
                    try ThreadLiveActivityService.journalSnapshot(
                        contextService: contextService,
                        date: date,
                        harmonicDepth: harmonicDepth
                    )
                }.value
                guard shouldRefreshForWaveform || nextSnapshot.flipDate > snapshot.flipDate.addingTimeInterval(0.5) else { return }
                try await ThreadLiveActivityService.start(snapshot: nextSnapshot)
                return
            }

            guard let entityID = UUID(uuidString: snapshot.threadID),
                  let entity = entities.first(where: { $0.id == entityID })
            else {
                return
            }

            let reading = try services.clockService.reading(
                saros: entity.saros,
                date: date,
                harmonicDepth: snapshot.harmonicDepth
            )
            let trackingRarity = FlipRarity(rawValue: snapshot.rarityRawValue) ?? .rare
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

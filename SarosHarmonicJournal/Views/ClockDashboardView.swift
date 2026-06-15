import AVFoundation
import CoreImage
import Photos
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct ClockDashboardView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \ThreadGroup.createdAt, order: .forward) private var threadGroups: [ThreadGroup]
    @Query(sort: \JournalRecord.createdAt, order: .reverse) private var records: [JournalRecord]
    @Query(sort: \RecordDraft.updatedAt, order: .reverse) private var recordDrafts: [RecordDraft]
    @Query(sort: \CustomFlipEvent.date, order: .forward) private var customFlips: [CustomFlipEvent]

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @State private var isAddingEntity = false
    @State private var captureRequest: ThreadCaptureRequest?
    @State private var selectedGroupFilter: ThreadGroupFilter = .all

    var body: some View {
        List {
            closestFlipSection

            threadsSection
        }
        .navigationTitle("Threads")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                groupFilterMenu

                Button {
                    isAddingEntity = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add thread")
            }
        }
        .sheet(isPresented: $isAddingEntity) {
            NavigationStack {
                EntityEditorView()
            }
        }
        .sheet(item: $captureRequest) { request in
            NavigationStack {
                CaptureView(entity: request.entity, harmonicDepth: harmonicDepth, recordStartedAt: request.startedAt) {}
            }
        }
    }

    @ViewBuilder
    private var closestFlipSection: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            if let closestFlip = closestFlip(at: context.date) {
                Section("Next flip") {
                    ClosestFlipCard(
                        flip: closestFlip,
                        countdownText: countdownText(for: closestFlip.flipDate.timeIntervalSince(context.date))
                    ) {
                        captureRequest = ThreadCaptureRequest(entity: closestFlip.entity, startedAt: Date())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var threadsSection: some View {
        Section("Threads") {
            if entities.isEmpty {
                ContentUnavailableView {
                    VStack(spacing: 12) {
                        OctalGlyph(value: String(repeating: "7", count: harmonicDepth), depth: harmonicDepth, color: .secondary)
                            .frame(width: 56, height: 56)
                        Text("No threads yet")
                    }
                } description: {
                    Text("Add an anchor date to start a private Saros clock.")
                }
            } else if filteredEntities.isEmpty {
                ContentUnavailableView("No threads in \(selectedGroupFilter.title(groups: threadGroups))", systemImage: "line.3.horizontal.decrease.circle")
            } else {
                ForEach(filteredEntities) { entity in
                    NavigationLink {
                        EntityDetailView(entity: entity)
                    } label: {
                        TimelineView(.periodic(from: Date(), by: 1)) { context in
                            let reading = reading(for: entity, at: context.date)
                            let countdown = reading.flatMap {
                                currentRarityCountdown(for: $0, at: context.date)
                                    ?? nearestRarityCountdown(for: $0, at: context.date)
                            }
                            EntityCardView(
                                entity: entity,
                                reading: reading,
                                countdown: countdown,
                                latestRecord: latestRecord(for: entity),
                                draft: draft(for: entity),
                                group: group(for: entity)
                            )
                        }
                    }
                }
                .onDelete(perform: deleteEntities)
            }
        }
    }

    private func closestFlip(at date: Date) -> DashboardFlipItem? {
        let readings = entityReadings(at: date)
        let active = readings.compactMap { item -> DashboardFlipItem? in
            let regular = currentRarityCountdown(for: item.reading, at: date).map {
                DashboardFlipItem(entity: item.entity, reading: item.reading, countdown: $0)
            }
            let custom = nextCustomFlip(for: item.entity, after: date).flatMap { customFlip -> DashboardFlipItem? in
                let timeUntil = customFlip.date.timeIntervalSince(date)
                guard timeUntil >= 0 && timeUntil <= Self.currentRarityWindow else { return nil }
                return DashboardFlipItem(entity: item.entity, reading: item.reading, customFlip: customFlip, now: date)
            }
            return [regular, custom].compactMap { $0 }.sorted(by: flipPrioritySort).first
        }

        if let best = active.sorted(by: flipPrioritySort).first {
            return best
        }

        return readings
            .compactMap { item -> DashboardFlipItem? in
                let regular = nearestRarityCountdown(for: item.reading, at: date).map {
                    DashboardFlipItem(entity: item.entity, reading: item.reading, countdown: $0)
                }
                let custom = nextCustomFlip(for: item.entity, after: date).map {
                    DashboardFlipItem(entity: item.entity, reading: item.reading, customFlip: $0, now: date)
                }
                return [regular, custom].compactMap { $0 }.min { $0.timeUntilFlip < $1.timeUntilFlip }
            }
            .min { lhs, rhs in
                lhs.timeUntilFlip < rhs.timeUntilFlip
            }
    }

    private func entityReadings(at date: Date) -> [(entity: TrackedEntity, reading: SarosClockReading)] {
        filteredEntities.compactMap { entity in
            guard let reading = reading(for: entity, at: date) else { return nil }
            return (entity, reading)
        }
    }

    private var filteredEntities: [TrackedEntity] {
        entities.filter { selectedGroupFilter.matches($0) }
    }

    @ViewBuilder
    private var groupFilterMenu: some View {
        Menu {
            Button {
                selectedGroupFilter = .all
            } label: {
                Label("All groups", systemImage: selectedGroupFilter == .all ? "checkmark" : "circle.grid.2x2")
            }

            Button {
                selectedGroupFilter = .common
            } label: {
                groupMenuItem(
                    title: ThreadGroup.commonName,
                    rarity: ThreadGroup.commonRarity,
                    isSelected: selectedGroupFilter == .common
                )
            }

            if !threadGroups.isEmpty {
                Divider()
                ForEach(threadGroups) { group in
                    Button {
                        selectedGroupFilter = .group(group.id)
                    } label: {
                        groupMenuItem(
                            title: "\(group.displayEmoji) \(group.displayName)",
                            rarity: group.rarity,
                            isSelected: selectedGroupFilter == .group(group.id)
                        )
                    }
                }
            }
        } label: {
            groupFilterLabel
        }
        .accessibilityLabel("Filter threads by group")
        .onChange(of: threadGroups.map(\.id)) { _, groupIDs in
            if case .group(let groupID) = selectedGroupFilter,
               !groupIDs.contains(groupID) {
                selectedGroupFilter = .all
            }
        }
    }

    @ViewBuilder
    private var groupFilterLabel: some View {
        if let rarity = selectedGroupFilter.rarity(groups: threadGroups),
           rarity != .common
        {
            FlipRarityGlyphIcon(rarity: rarity, harmonicDepth: harmonicDepth, size: 22)
        } else {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    private func groupMenuItem(title: String, rarity: FlipRarity, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            if isSelected {
                Image(systemName: "checkmark")
            }
            FlipRarityGlyphIcon(rarity: rarity, harmonicDepth: harmonicDepth, size: 18)
            Text(title)
        }
    }

    private func currentRarityCountdown(for reading: SarosClockReading, at date: Date) -> SarosFlipCountdown? {
        reading.rarityCountdowns(now: date)
            .filter { countdown in
                countdown.timeUntilFlip >= 0 && countdown.timeUntilFlip <= Self.currentRarityWindow
            }
            .sorted {
                if $0.timeUntilFlip != $1.timeUntilFlip {
                    return $0.timeUntilFlip < $1.timeUntilFlip
                }
                return $0.rarity > $1.rarity
            }
            .first
    }

    private func nearestRarityCountdown(for reading: SarosClockReading, at date: Date) -> SarosFlipCountdown? {
        reading.rarityCountdowns(now: date)
            .filter { $0.timeUntilFlip >= 0 }
            .min { $0.timeUntilFlip < $1.timeUntilFlip }
    }

    private func flipPrioritySort(
        _ lhs: DashboardFlipItem,
        _ rhs: DashboardFlipItem
    ) -> Bool {
        if lhs.timeUntilFlip != rhs.timeUntilFlip {
            return lhs.timeUntilFlip < rhs.timeUntilFlip
        }
        return lhs.priorityRank > rhs.priorityRank
    }

    private static let currentRarityWindow: TimeInterval = 24 * 60 * 60

    private func reading(for entity: TrackedEntity, at date: Date) -> SarosClockReading? {
        try? services.clockService.reading(
            saros: entity.saros,
            date: date,
            harmonicDepth: harmonicDepth
        )
    }

    private func latestRecord(for entity: TrackedEntity) -> JournalRecord? {
        records.first { $0.entityID == entity.id }
    }

    private func draft(for entity: TrackedEntity) -> RecordDraft? {
        recordDrafts.first { $0.entityID == entity.id }
    }

    private func group(for entity: TrackedEntity) -> ThreadGroup? {
        guard let groupID = entity.groupID else { return nil }
        return threadGroups.first { $0.id == groupID }
    }

    private func nextCustomFlip(for entity: TrackedEntity, after date: Date) -> CustomFlipEvent? {
        customFlips
            .filter { $0.entityID == entity.id && $0.date >= date }
            .min { $0.date < $1.date }
    }

    private func countdownText(for interval: TimeInterval) -> String {
        let totalSeconds = max(Int(interval.rounded(.up)), 0)
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        }
        return "\(minutes)m \(seconds)s"
    }

    private func deleteEntities(at offsets: IndexSet) {
        let visibleEntities = filteredEntities
        for offset in offsets {
            modelContext.delete(visibleEntities[offset])
        }
        try? modelContext.save()
    }
}

private enum ThreadGroupFilter: Equatable {
    case all
    case common
    case group(UUID)

    func matches(_ entity: TrackedEntity) -> Bool {
        switch self {
        case .all:
            true
        case .common:
            entity.groupID == nil
        case .group(let groupID):
            entity.groupID == groupID
        }
    }

    func title(groups: [ThreadGroup]) -> String {
        switch self {
        case .all:
            "All groups"
        case .common:
            ThreadGroup.commonName
        case .group(let groupID):
            groups.first { $0.id == groupID }?.displayName ?? "Group"
        }
    }

    func rarity(groups: [ThreadGroup]) -> FlipRarity? {
        switch self {
        case .all:
            nil
        case .common:
            ThreadGroup.commonRarity
        case .group(let groupID):
            groups.first { $0.id == groupID }?.rarity
        }
    }
}

private struct ThreadCaptureRequest: Identifiable {
    let id = UUID()
    let entity: TrackedEntity
    let startedAt: Date
}

private struct DashboardFlipItem {
    let entity: TrackedEntity
    let reading: SarosClockReading
    let countdown: SarosFlipCountdown?
    let customFlip: CustomFlipEvent?
    let timeUntilFlip: TimeInterval

    init(entity: TrackedEntity, reading: SarosClockReading, countdown: SarosFlipCountdown) {
        self.entity = entity
        self.reading = reading
        self.countdown = countdown
        self.customFlip = nil
        self.timeUntilFlip = countdown.timeUntilFlip
    }

    init(entity: TrackedEntity, reading: SarosClockReading, customFlip: CustomFlipEvent, now: Date) {
        self.entity = entity
        self.reading = reading
        self.countdown = nil
        self.customFlip = customFlip
        self.timeUntilFlip = customFlip.date.timeIntervalSince(now)
    }

    var color: Color {
        if let customFlip {
            return Color(hex: customFlip.colorHex, fallback: .green)
        }
        return countdown?.rarity.color ?? .secondary
    }

    var title: String {
        customFlip?.displayName ?? countdown?.rarity.title ?? "Flip"
    }

    var orderLabel: String {
        customFlip == nil ? countdown?.rarity.patternLabel(harmonicDepth: reading.harmonicDepth) ?? "" : "Custom"
    }

    var octalAddress: String {
        customFlip?.octalAddress ?? countdown?.targetOctalAddress ?? reading.octalAddress
    }

    var flipDate: Date {
        customFlip?.date ?? countdown?.flipDate ?? reading.nextFlipDate
    }

    var priorityRank: Int {
        customFlip == nil ? countdown?.rarity.rank ?? 0 : 100
    }
}

private struct ClosestFlipCard: View {
    let flip: DashboardFlipItem
    let countdownText: String
    let record: () -> Void

    var body: some View {
        let rarityColor = flip.color

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                glyph(color: rarityColor)

                VStack(alignment: .leading, spacing: 5) {
                    Text(flip.entity.displayTitle)
                        .font(.headline)
                    Text("Saros \(flip.reading.saros) · \(flip.title) · \(flip.orderLabel)")
                        .font(.subheadline)
                        .foregroundStyle(rarityColor)
                    Text(countdownText)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(rarityColor)
                        .contentTransition(.numericText())
                }

                Spacer()
            }

            HStack {
                Text("Flip \(JournalFormatters.dateTime.string(from: flip.flipDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: record) {
                    Image(systemName: "record.circle.fill")
                        .font(.title3)
                        .frame(width: 44, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Record \(flip.entity.displayTitle)")
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func glyph(color: Color) -> some View {
        if let countdown = flip.countdown {
            DynamicFlipGlyph(reading: flip.reading, countdown: countdown, color: color)
                .frame(width: 74, height: 74)
                .padding(8)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        } else {
            OctalGlyph(value: flip.octalAddress, depth: flip.reading.harmonicDepth, color: color)
                .frame(width: 74, height: 74)
                .padding(8)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct EntityCardView: View {
    let entity: TrackedEntity
    let reading: SarosClockReading?
    let countdown: SarosFlipCountdown?
    let latestRecord: JournalRecord?
    let draft: RecordDraft?
    let group: ThreadGroup?

    var body: some View {
        let displayRarity = displayedRarity
        let rarityColor = displayRarity.color

        HStack(spacing: 14) {
            avatar(color: rarityColor)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(entity.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if let group {
                        ThreadGroupInlineBadge(group: group)
                    }
                    if draft != nil {
                        Label("Draft", systemImage: "square.and.pencil")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    }
                }
                Text("Saros \(entity.saros) · \(reading?.octalAddress ?? "----")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let countdown {
                    EntityCardCountdownText(countdown: countdown)
                }

                if let draft {
                    Text("Draft · \(JournalFormatters.dateTime.string(from: draft.eventDate))")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.orange)
                } else if let latestRecord {
                    Text(latestRecord.text ?? latestRecord.emoji ?? latestRecord.triggerType.displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let reading, let countdown {
                DynamicFlipGlyph(reading: reading, countdown: countdown, color: countdown.rarity.color)
                    .frame(width: 42, height: 42)
            }
        }
        .padding(.vertical, 6)
    }

    private var displayedRarity: FlipRarity {
        let current = reading?.currentRarity ?? .common
        guard let countdown else { return current }
        return max(current, countdown.rarity)
    }

    @ViewBuilder
    private func avatar(color: Color) -> some View {
        if let reading {
            OctalGlyph(value: reading.octalAddress, depth: reading.harmonicDepth, color: color)
                .frame(width: 48, height: 48)
                .padding(6)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        } else if let emoji = entity.emoji, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: 30))
                .frame(width: 48, height: 48)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else {
            OctalGlyph(value: String(repeating: "7", count: JournalSettings.defaultHarmonicDepth), color: .secondary)
                .frame(width: 48, height: 48)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct EntityCardCountdownText: View {
    let countdown: SarosFlipCountdown

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            Text("\(countdown.rarity.title) in \(timeLeft(at: context.date).compactDuration)")
                .font(.caption)
                .foregroundStyle(countdown.rarity.color)
                .contentTransition(.numericText())
        }
    }

    private func timeLeft(at date: Date) -> TimeInterval {
        max(countdown.flipDate.timeIntervalSince(date), 0)
    }
}

private struct DynamicFlipGlyph: View {
    let reading: SarosClockReading
    let countdown: SarosFlipCountdown?
    let color: Color

    init(reading: SarosClockReading, countdown: SarosFlipCountdown? = nil, color: Color = .blue) {
        self.reading = reading
        self.countdown = countdown
        self.color = color
    }

    var body: some View {
        if let activeCountdown = countdown ?? reading.countdown(order: 1) {
            TimelineView(.periodic(from: activeCountdown.periodStartDate, by: refreshPeriod(for: activeCountdown))) { context in
                OctalGlyph(
                    value: dynamicAddress(at: context.date, countdown: activeCountdown),
                    depth: reading.harmonicDepth,
                    style: activeCountdown.rarity.glyphStyle
                )
            }
            .accessibilityLabel("Flip countdown glyph")
        }
    }

    private func refreshPeriod(for countdown: SarosFlipCountdown) -> TimeInterval {
        let periodDuration = max(countdown.flipDate.timeIntervalSince(countdown.periodStartDate), 1)
        return max(periodDuration / Double(reading.binCount), 1.0 / 30.0)
    }

    private func dynamicAddress(at date: Date, countdown: SarosFlipCountdown) -> String {
        let periodDuration = max(countdown.flipDate.timeIntervalSince(countdown.periodStartDate), 1)
        let progress = min(max(date.timeIntervalSince(countdown.periodStartDate) / periodDuration, 0), 1 - Double.ulpOfOne)
        let subIndex = min(Int(floor(progress * Double(reading.binCount))), reading.binCount - 1)
        return String(subIndex, radix: 8).leftPadded(toLength: reading.harmonicDepth, withPad: "0")
    }
}

private struct EntityDetailView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var allEntities: [TrackedEntity]
    @Query(sort: \ThreadGroup.createdAt, order: .forward) private var threadGroups: [ThreadGroup]
    @Query(sort: \JournalRecord.eventDate, order: .reverse) private var records: [JournalRecord]
    @Query(sort: \RecordDraft.updatedAt, order: .reverse) private var recordDrafts: [RecordDraft]
    @Query(sort: \CustomFlipEvent.date, order: .forward) private var customFlips: [CustomFlipEvent]

    let entity: TrackedEntity
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @State private var selectedTab: ThreadDetailTab = .records
    @State private var selectedRecordRarity: FlipRarity?
    @State private var selectedRecord: JournalRecord?
    @State private var captureRequest: ThreadCaptureRequest?
    @State private var isStartingLiveTracking = false
    @State private var liveTrackingError: String?
    @State private var customFlipDraft: CustomFlipDraft?
    @State private var threadGroupDraft: ThreadGroupDraft?
    @State private var isEditingEntity = false

    var body: some View {
        List {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                threadHeaderSection(at: context.date)
            }

            Section {
                Picker("Thread tab", selection: $selectedTab) {
                    ForEach(ThreadDetailTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch selectedTab {
            case .records:
                recordsTab
            case .info:
                infoTab
            case .flips:
                flipsTab
            case .custom:
                searchTab
            }
        }
        .navigationTitle(entity.displayTitle)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Menu {
                        ForEach(FlipRarity.rarityGroups(for: harmonicDepth)) { group in
                            Menu {
                                Button {
                                    startLiveTracking(rarity: group.header)
                                } label: {
                                    HStack {
                                        FlipRarityGlyphIcon(rarity: group.header, harmonicDepth: harmonicDepth, size: 18)
                                        Text("Track \(group.header.title)")
                                    }
                                }
                                .disabled(isStartingLiveTracking)

                                Divider()

                                ForEach(group.subrarities) { rarity in
                                    Button {
                                        startLiveTracking(rarity: rarity)
                                    } label: {
                                        HStack {
                                            FlipRarityGlyphIcon(rarity: rarity, harmonicDepth: harmonicDepth, size: 18)
                                            Text("Track \(rarity.patternLabel(harmonicDepth: harmonicDepth))")
                                        }
                                    }
                                    .disabled(isStartingLiveTracking)
                                }
                            } label: {
                                HStack {
                                    FlipRarityGlyphIcon(rarity: group.header, harmonicDepth: harmonicDepth, size: 18)
                                    Text(group.header.title)
                                }
                            }
                        }
                    } label: {
                        Label("Track", systemImage: "dot.radiowaves.left.and.right")
                    }

                    Button {
                        isEditingEntity = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: isStartingLiveTracking ? "dot.radiowaves.left.and.right" : "ellipsis.circle")
                }
                .accessibilityLabel("Thread actions")

                Button {
                    captureRequest = ThreadCaptureRequest(entity: entity, startedAt: entityDraft?.createdAt ?? Date())
                } label: {
                    Label("Rec", systemImage: "record.circle")
                }
            }
        }
        .sheet(item: $captureRequest) { request in
            NavigationStack {
                CaptureView(entity: request.entity, harmonicDepth: harmonicDepth, recordStartedAt: request.startedAt) {}
            }
        }
        .sheet(isPresented: $isEditingEntity) {
            NavigationStack {
                EntityEditorView(entity: entity)
            }
        }
        .sheet(item: $customFlipDraft) { draft in
            NavigationStack {
                CustomFlipEditorView(draft: draft) { savedDraft in
                    addCustomFlip(savedDraft)
                }
            }
        }
        .sheet(item: $threadGroupDraft) { draft in
            NavigationStack {
                ThreadGroupEditorView(draft: draft) { savedDraft in
                    addThreadGroup(savedDraft)
                }
            }
        }
        .alert(
            "Live Tracking",
            isPresented: Binding(
                get: { liveTrackingError != nil },
                set: { isPresented in
                    if !isPresented {
                        liveTrackingError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(liveTrackingError ?? "")
        }
        .navigationDestination(item: $selectedRecord) { record in
            JournalRecordDetailView(record: record, entityTitle: entity.displayTitle)
        }
    }

    @ViewBuilder
    private func threadHeaderSection(at date: Date) -> some View {
        Section {
            if let reading = reading(at: date) {
                let activeCountdown = currentRarityCountdown(for: reading, at: date)
                let displayRarity = max(reading.currentRarity, activeCountdown?.rarity ?? .common)
                let glyphColor = displayRarity.color
                HStack(spacing: 16) {
                    OctalGlyph(
                        value: reading.octalAddress,
                        depth: reading.harmonicDepth,
                        style: displayRarity.glyphStyle
                    )
                        .frame(width: 72, height: 72)
                        .padding(8)
                        .background(glyphColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reading.octalAddress)
                            .font(.system(.title, design: .monospaced))
                            .contentTransition(.numericText())
                        Text("Next flip \(JournalFormatters.dateTime.string(from: reading.nextFlipDate))")
                            .foregroundStyle(.secondary)
                        ThreadHeaderCountdownText(reading: reading)
                    }
                }
            }

            if let notes = entity.notes, !notes.isEmpty {
                Text(notes)
            }
        }
    }

    private var currentReading: SarosClockReading? {
        reading(at: Date())
    }

    private func reading(at date: Date) -> SarosClockReading? {
        try? services.clockService.reading(
            saros: entity.saros,
            date: date,
            harmonicDepth: harmonicDepth
        )
    }

    private var entityRecords: [JournalRecord] {
        records.filter { $0.entityID == entity.id }
    }

    private var filteredEntityRecords: [JournalRecord] {
        guard let selectedRecordRarity else { return entityRecords }
        return entityRecords.filter { recordRarity(for: $0).baseRarity == selectedRecordRarity.baseRarity }
    }

    private var entityCustomFlips: [CustomFlipEvent] {
        customFlips.filter { $0.entityID == entity.id }
    }

    private var entityDraft: RecordDraft? {
        recordDrafts.first { $0.entityID == entity.id }
    }

    private var selectedThreadGroup: ThreadGroup? {
        threadGroup(for: entity)
    }

    private var sarosBuddies: [TrackedEntity] {
        allEntities
            .filter { $0.id != entity.id && $0.saros == entity.saros }
            .sorted {
                let comparison = $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle)
                if comparison == .orderedSame {
                    return $0.createdAt < $1.createdAt
                }
                return comparison == .orderedAscending
            }
    }

    private func threadGroup(for entity: TrackedEntity) -> ThreadGroup? {
        guard let groupID = entity.groupID else { return nil }
        return threadGroups.first { $0.id == groupID }
    }

    private func currentRarityCountdown(for reading: SarosClockReading, at date: Date = Date()) -> SarosFlipCountdown? {
        reading.rarityCountdowns(now: date)
            .filter { $0.timeUntilFlip >= 0 && $0.timeUntilFlip <= 24 * 60 * 60 }
            .sorted {
                if $0.timeUntilFlip != $1.timeUntilFlip {
                    return $0.timeUntilFlip < $1.timeUntilFlip
                }
                return $0.rarity > $1.rarity
            }
            .first
    }

    private func startLiveTracking(rarity: FlipRarity) {
        guard let reading = reading(at: Date()) else {
            liveTrackingError = "The current thread timing is unavailable."
            return
        }

        let snapshot = ThreadLiveActivityService.snapshot(
            entity: entity,
            reading: reading,
            trackingRarity: rarity
        )
        isStartingLiveTracking = true

        Task { @MainActor in
            defer { isStartingLiveTracking = false }

            do {
                try await ThreadLiveActivityService.start(snapshot: snapshot)
            } catch {
                liveTrackingError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var recordsTab: some View {
        Section("Records") {
            if let entityDraft {
                Button {
                    captureRequest = ThreadCaptureRequest(entity: entity, startedAt: entityDraft.createdAt)
                } label: {
                    Label(
                        "Resume draft · \(JournalFormatters.dateTime.string(from: entityDraft.eventDate))",
                        systemImage: "square.and.pencil"
                    )
                    .foregroundStyle(.orange)
                }
            }

            if entityRecords.isEmpty {
                Text("No records yet")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Rarity", selection: $selectedRecordRarity) {
                    Text("All").tag(nil as FlipRarity?)
                    ForEach(FlipRarity.baseRarities) { rarity in
                        Text(rarity.title).tag(Optional(rarity))
                    }
                }
                .pickerStyle(.menu)

                if filteredEntityRecords.isEmpty {
                    ContentUnavailableView("No \(selectedRecordRarity?.title ?? "") records", systemImage: "line.3.horizontal.decrease.circle")
                }

                ForEach(filteredEntityRecords) { record in
                    Button {
                        selectedRecord = record
                    } label: {
                        JournalRecordRow(
                            record: record,
                            entityTitle: entity.displayTitle,
                            rarity: recordRarity(for: record)
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.visible)
                    .listRowSeparatorTint(.white.opacity(0.28))
                }
            }
        }
    }

    @ViewBuilder
    private var infoTab: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            if let reading = reading(at: context.date) {
                RarityCountdownSection(reading: reading, depth: harmonicDepth, now: context.date)
            } else {
                Section("Info") {
                    ContentUnavailableView("Info unavailable", systemImage: "clock.badge.questionmark")
                }
            }
        }

        threadGroupSection
        anchorMoonSection
        sarosBuddiesSection
        anchorEclipseSection
    }

    private var threadGroupSection: some View {
        Section("Group") {
            HStack(spacing: 12) {
                ThreadGroupSummaryView(group: selectedThreadGroup)

                Spacer(minLength: 12)

                Menu {
                    Button {
                        assignThreadGroup(nil)
                    } label: {
                        groupSelectionMenuItem(
                            title: ThreadGroup.commonName,
                            rarity: ThreadGroup.commonRarity
                        )
                    }

                    if !threadGroups.isEmpty {
                        Divider()
                        ForEach(threadGroups) { group in
                            Button {
                                assignThreadGroup(group)
                            } label: {
                                groupSelectionMenuItem(
                                    title: "\(group.displayEmoji) \(group.displayName)",
                                    rarity: group.rarity
                                )
                            }
                        }
                    }

                    Divider()

                    Button {
                        threadGroupDraft = ThreadGroupDraft()
                    } label: {
                        Label("New group", systemImage: "plus.circle")
                    }
                } label: {
                    Text("Change")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func groupSelectionMenuItem(title: String, rarity: FlipRarity) -> some View {
        HStack(spacing: 8) {
            FlipRarityGlyphIcon(rarity: rarity, harmonicDepth: harmonicDepth, size: 18)
            Text(title)
        }
    }

    @ViewBuilder
    private var anchorMoonSection: some View {
        Section("Moon phase") {
            if let moonReading = try? services.moonPhaseService.octalReading(for: entity.anchorDate, depth: 8) {
                HStack(spacing: 14) {
                    MoonPhaseGlyph(reading: moonReading)
                        .frame(width: 58, height: 58)
                        .padding(8)
                        .background(moonReading.rarity.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(moonReading.octalAddress)
                                .font(.system(.title3, design: .monospaced).weight(.semibold))
                            FlipRarityBadge(rarity: moonReading.rarity, compact: true)
                        }
                        Text(moonReading.phaseReading.phase.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)
                }
                .padding(.vertical, 4)

                MetadataRow(title: "Anchor moon", value: JournalFormatters.dateTime.string(from: entity.anchorDate))
                ForEach(moonReading.components) { component in
                    MetadataRow(
                        title: "\(component.kind.displayName) phase",
                        value: component.detailOctalAddress
                    )
                    MetadataRow(
                        title: "Previous \(component.kind.eventName.lowercased())",
                        value: JournalFormatters.dateTime.string(from: component.cycleReading.previousEvent.date)
                    )
                    MetadataRow(
                        title: "Next \(component.kind.eventName.lowercased())",
                        value: JournalFormatters.dateTime.string(from: component.cycleReading.nextEvent.date)
                    )
                }
            } else {
                ContentUnavailableView("Moon phase unavailable", systemImage: "moonphase.new.moon")
            }
        }
    }

    private var sarosBuddiesSection: some View {
        Section("Saros buddies") {
            if sarosBuddies.isEmpty {
                ContentUnavailableView("No Saros buddies", systemImage: "person.2.slash")
                    .font(.caption)
            } else {
                ForEach(sarosBuddies) { buddy in
                    NavigationLink {
                        EntityDetailView(entity: buddy)
                    } label: {
                        SarosBuddyRow(entity: buddy, group: threadGroup(for: buddy))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var anchorEclipseSection: some View {
        let globalBracket = try? services.eclipseService.eclipseBracket(around: entity.anchorDate)
        let sarosInterval = try? services.eclipseService.previousAndNextEclipse(
            saros: entity.saros,
            around: entity.anchorDate
        )
        let storedAnchor = entity.nearestEclipseID.flatMap {
            try? services.eclipseService.eclipse(withID: $0)
        }
        let nearestAnchor = try? services.eclipseService.nearestEclipse(to: entity.anchorDate)
        let anchorEclipse = storedAnchor ?? globalBracket?.closest(to: entity.anchorDate) ?? nearestAnchor
        let referenceCycleDuration = sarosInterval.map {
            max($0.next.date.timeIntervalSince($0.previous.date), 1)
        } ?? AnchorEclipseMetrics.averageSarosCycleDuration

        Section("Anchor eclipse") {
            if let globalBracket {
                let metrics = AnchorEclipseMetrics(
                    anchorDate: entity.anchorDate,
                    bracket: globalBracket,
                    depth: harmonicDepth,
                    referenceCycleDuration: referenceCycleDuration
                )

                AnchorEclipseTimelineView(
                    anchorDate: entity.anchorDate,
                    bracket: globalBracket,
                    depth: harmonicDepth,
                    referenceCycleDuration: referenceCycleDuration
                )

                MetadataRow(title: "Anchor", value: JournalFormatters.dateTime.string(from: entity.anchorDate))
                MetadataRow(title: "Left eclipse", value: AnchorEclipseFormat.summary(globalBracket.previous))
                MetadataRow(title: "Right eclipse", value: AnchorEclipseFormat.summary(globalBracket.next))
                MetadataRow(title: "Gap period", value: AnchorEclipseFormat.period(globalBracket.gapDuration))
                MetadataRow(title: "To left eclipse", value: AnchorEclipseFormat.period(metrics.previousDistance))
                MetadataRow(title: "To right eclipse", value: AnchorEclipseFormat.period(metrics.nextDistance))
                MetadataRow(title: "To marginal center", value: AnchorEclipseFormat.period(metrics.midpointDistance))
                MetadataRow(title: "Marginality", value: AnchorEclipseFormat.percent(metrics.marginality))

                AnchorEclipseProximityView(metrics: metrics)
            } else {
                ContentUnavailableView("Eclipse interval unavailable", systemImage: "moonphase.new.moon.inverse")
            }
        }

        if let anchorEclipse {
            Section("Anchor path") {
                ThreadAnchorCubeMapView(eclipse: anchorEclipse)
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
            }
        }
    }

    @ViewBuilder
    private var flipsTab: some View {
        if let reading = currentReading {
            let snapshotNow = Date()
            let timeline = ThreadFlipTimeline(
                reading: reading,
                now: snapshotNow,
                customFlips: entityCustomFlips
            )

            Section("Future") {
                ForEach(timeline.futureEvents) { event in
                    flipNavigationLink(event: event, reading: reading)
                }
            }

            Section("Past") {
                ForEach(timeline.pastEvents) { event in
                    flipNavigationLink(event: event, reading: reading)
                }
            }
        } else {
            Section("Flips") {
                ContentUnavailableView("Flips unavailable", systemImage: "clock.badge.questionmark")
            }
        }
    }

    private func flipNavigationLink(event: ThreadFlipEvent, reading: SarosClockReading) -> some View {
        NavigationLink {
            ThreadFlipResonanceDetailView(
                event: event,
                sourceTitle: entity.displayTitle,
                sourceSaros: entity.saros,
                harmonicDepth: harmonicDepth,
                sarosReferences: otherSarosReferences,
                customFlips: customFlips
            )
        } label: {
            ThreadFlipRow(
                event: event,
                depth: harmonicDepth,
                now: Date(),
                resonances: resonances(for: event)
            )
        }
    }

    private var otherSarosReferences: [ThreadSarosReference] {
        Dictionary(grouping: allEntities.filter { $0.saros != entity.saros }, by: \.saros)
            .map { saros, entities in
                ThreadSarosReference(
                    saros: saros,
                    title: entities.first?.displayTitle ?? "Saros \(saros)",
                    entityIDs: entities.map(\.id)
                )
            }
            .sorted { $0.saros < $1.saros }
    }

    private func resonances(for event: ThreadFlipEvent) -> [ThreadFlipOverlap] {
        ThreadFlipResonanceCalculator.overlaps(
            for: event,
            sourceSaros: entity.saros,
            references: otherSarosReferences,
            clockService: services.clockService,
            harmonicDepth: harmonicDepth,
            customFlips: customFlips
        )
    }

    @ViewBuilder
    private var searchTab: some View {
        if let reading = currentReading {
            Section {
                ThreadGlyphSearchView(
                    reading: reading,
                    clockService: services.clockService
                ) { address, binIndex, date in
                    customFlipDraft = CustomFlipDraft(
                        entityID: entity.id,
                        name: "Custom flip",
                        date: date,
                        octalAddress: address,
                        binIndex: binIndex,
                        colorHex: "#00D084"
                    )
                }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }
            if !entityCustomFlips.isEmpty {
                Section("Custom flips") {
                    ForEach(entityCustomFlips) { customFlip in
                        CustomFlipRow(customFlip: customFlip, harmonicDepth: harmonicDepth)
                    }
                    .onDelete(perform: deleteCustomFlips)
                }
            }
        } else {
            Section("Custom") {
                ContentUnavailableView("Custom flips unavailable", systemImage: "star.circle")
            }
        }
    }

    private func recordRarity(for record: JournalRecord) -> FlipRarity {
        FlipRarity.rarity(
            forOctalAddress: record.octalAddress,
            harmonicDepth: record.harmonicDepth,
            isEclipse: record.triggerType == .eclipse
        )
    }

    private func addCustomFlip(_ draft: CustomFlipDraft) {
        modelContext.insert(CustomFlipEvent(
            entityID: draft.entityID,
            name: draft.name,
            date: draft.date,
            octalAddress: draft.octalAddress,
            binIndex: draft.binIndex,
            colorHex: draft.colorHex
        ))
        entity.touch()
        try? modelContext.save()
    }

    private func addThreadGroup(_ draft: ThreadGroupDraft) {
        let group = ThreadGroup(
            name: draft.name,
            emoji: draft.emoji,
            rarity: draft.rarity
        )
        modelContext.insert(group)
        assignThreadGroup(group)
    }

    private func assignThreadGroup(_ group: ThreadGroup?) {
        entity.groupID = group?.id
        entity.touch()
        try? modelContext.save()
    }

    private func deleteCustomFlips(at offsets: IndexSet) {
        let visible = entityCustomFlips
        for offset in offsets {
            modelContext.delete(visible[offset])
        }
        try? modelContext.save()
    }
}

private enum ThreadDetailTab: String, CaseIterable, Identifiable {
    case records
    case info
    case flips
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .records: "Records"
        case .info: "Info"
        case .flips: "Flips"
        case .custom: "Custom"
        }
    }
}

private struct ThreadGroupInlineBadge: View {
    let group: ThreadGroup

    var body: some View {
        HStack(spacing: 4) {
            Text(group.displayEmoji)
                .font(.caption.weight(.semibold))
                .frame(width: 18, height: 18)
                .background(group.rarity.color.opacity(0.16), in: Circle())
            FlipRarityBadge(rarity: group.rarity, compact: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.displayName), \(group.rarity.title)")
    }
}

private struct ThreadGroupSummaryView: View {
    let group: ThreadGroup?

    private var name: String {
        group?.displayName ?? ThreadGroup.commonName
    }

    private var emoji: String {
        group?.displayEmoji ?? ThreadGroup.commonEmoji
    }

    private var rarity: FlipRarity {
        group?.rarity ?? ThreadGroup.commonRarity
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(emoji)
                .font(.title2)
                .frame(width: 42, height: 42)
                .background(rarity.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(rarity.color.opacity(0.25), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                FlipRarityBadge(rarity: rarity)
            }
        }
    }
}

private struct SarosBuddyRow: View {
    let entity: TrackedEntity
    let group: ThreadGroup?

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                Text(entity.displayTitle)
                    .font(.subheadline.weight(.semibold))
                Text("Anchor \(JournalFormatters.date.string(from: entity.anchorDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if let group {
                ThreadGroupInlineBadge(group: group)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var avatar: some View {
        if let emoji = entity.emoji, !emoji.isEmpty {
            Text(emoji)
                .font(.title3)
                .frame(width: 38, height: 38)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct ThreadHeaderCountdownText: View {
    let reading: SarosClockReading

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            if let countdown = activeCountdown(at: context.date) {
                Text("\(countdown.rarity.title) in \(timeLeft(for: countdown, at: context.date).compactDuration)")
                    .font(.caption)
                    .foregroundStyle(countdown.rarity.color)
                    .contentTransition(.numericText())
            }
        }
    }

    private func activeCountdown(at date: Date) -> SarosFlipCountdown? {
        reading.rarityCountdowns(now: date)
            .filter { $0.flipDate.timeIntervalSince(date) >= 0 && $0.flipDate.timeIntervalSince(date) <= 24 * 60 * 60 }
            .sorted {
                let lhsDelta = $0.flipDate.timeIntervalSince(date)
                let rhsDelta = $1.flipDate.timeIntervalSince(date)
                if lhsDelta != rhsDelta {
                    return lhsDelta < rhsDelta
                }
                return $0.rarity > $1.rarity
            }
            .first
    }

    private func timeLeft(for countdown: SarosFlipCountdown, at date: Date) -> TimeInterval {
        max(countdown.flipDate.timeIntervalSince(date), 0)
    }
}

private struct RarityCountdownSection: View {
    let reading: SarosClockReading
    let depth: Int
    let now: Date

    var body: some View {
        Section("Rarity countdowns") {
            ForEach(sortedCountdowns, id: \.rarity) { countdown in
                RarityCountdownRow(
                    countdown: countdown,
                    depth: depth,
                    now: now
                )
            }
        }
    }

    private var sortedCountdowns: [SarosFlipCountdown] {
        reading.rarityCountdowns(now: now)
            .filter { $0.timeUntilFlip >= 0 }
            .sorted {
                if $0.timeUntilFlip != $1.timeUntilFlip {
                    return $0.timeUntilFlip < $1.timeUntilFlip
                }
                return $0.rarity > $1.rarity
            }
    }
}

struct ThreadGroupDraft: Identifiable {
    let id = UUID()
    var groupID: UUID?
    var name: String
    var emoji: String
    var rarity: FlipRarity

    init(
        groupID: UUID? = nil,
        name: String = "",
        emoji: String = "✨",
        rarity: FlipRarity = .common
    ) {
        self.groupID = groupID
        self.name = name
        self.emoji = emoji
        self.rarity = rarity
    }

    init(group: ThreadGroup) {
        self.init(
            groupID: group.id,
            name: group.displayName,
            emoji: group.displayEmoji,
            rarity: group.rarity
        )
    }
}

struct ThreadGroupEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let save: (ThreadGroupDraft) -> Void
    private let groupID: UUID?
    @State private var name: String
    @State private var emoji: String
    @State private var rarity: FlipRarity

    init(draft: ThreadGroupDraft, save: @escaping (ThreadGroupDraft) -> Void) {
        self.save = save
        self.groupID = draft.groupID
        _name = State(initialValue: draft.name)
        _emoji = State(initialValue: draft.emoji)
        _rarity = State(initialValue: draft.rarity)
    }

    var body: some View {
        Form {
            Section("Group") {
                TextField("Name", text: $name)
                TextField("Emoji", text: $emoji)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Picker("Rarity", selection: $rarity) {
                    ForEach(FlipRarity.baseRarities) { rarity in
                        Text(rarity.title).tag(rarity)
                    }
                }
            }
        }
        .navigationTitle(groupID == nil ? "New Group" : "Edit Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(groupID == nil ? "Create" : "Save") {
                    save(ThreadGroupDraft(
                        groupID: groupID,
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        emoji: emoji.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? ThreadGroup.commonEmoji,
                        rarity: rarity
                    ))
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private enum AnchorEclipseFormat {
    private static let periodFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.year, .month, .day, .hour]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func summary(_ eclipse: Eclipse) -> String {
        "Saros \(eclipse.saros) \(eclipse.displayTypeLabel) · \(JournalFormatters.date.string(from: eclipse.date))"
    }

    static func period(_ interval: TimeInterval) -> String {
        periodFormatter.string(from: abs(interval)) ?? "\(Int(abs(interval) / 86_400)) days"
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct AnchorEclipseMetrics {
    static let averageSarosCycleDuration: TimeInterval = 6_585.3211 * 24 * 60 * 60

    let anchorDate: Date
    let bracket: EclipseBracket
    let depth: Int
    let referenceCycleDuration: TimeInterval

    private var bracketDuration: TimeInterval {
        max(bracket.next.date.timeIntervalSince(bracket.previous.date), 1)
    }

    var progress: Double {
        let elapsed = anchorDate.timeIntervalSince(bracket.previous.date)
        return min(max(elapsed / bracketDuration, 0), 1)
    }

    var previousDistance: TimeInterval {
        abs(anchorDate.timeIntervalSince(bracket.previous.date))
    }

    var nextDistance: TimeInterval {
        abs(bracket.next.date.timeIntervalSince(anchorDate))
    }

    var closestDistance: TimeInterval {
        min(previousDistance, nextDistance)
    }

    var midpointDate: Date {
        bracket.previous.date.addingTimeInterval(bracketDuration / 2)
    }

    var midpointDistance: TimeInterval {
        abs(anchorDate.timeIntervalSince(midpointDate))
    }

    var rarityDistance: TimeInterval {
        min(closestDistance, midpointDistance)
    }

    var marginality: Double {
        let balance = abs(previousDistance - nextDistance) / bracketDuration
        return min(max(1 - balance, 0), 1)
    }

    var inverseRarity: FlipRarity {
        let rarePeriod = periodDuration(for: .rare)
        let commonPeriod = rarePeriod / 7
        let epicPeriod = periodDuration(for: .epic)
        let legendaryPeriod = periodDuration(for: .legendary)

        if rarityDistance <= commonPeriod {
            return .mythic
        }
        if rarityDistance <= rarePeriod {
            return .legendary
        }
        if rarityDistance <= epicPeriod {
            return .epic
        }
        if rarityDistance <= legendaryPeriod {
            return .rare
        }
        return .rare
    }

    private func periodDuration(for rarity: FlipRarity) -> TimeInterval {
        max(referenceCycleDuration, 1) / Double(max(rarity.basePeriodDivisions, 1))
    }
}

private struct AnchorEclipseTimelineView: View {
    let anchorDate: Date
    let bracket: EclipseBracket
    let depth: Int
    let referenceCycleDuration: TimeInterval

    private var metrics: AnchorEclipseMetrics {
        AnchorEclipseMetrics(
            anchorDate: anchorDate,
            bracket: bracket,
            depth: depth,
            referenceCycleDuration: referenceCycleDuration
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                endpoint(bracket.previous, alignment: .leading)
                Spacer(minLength: 16)
                endpoint(bracket.next, alignment: .trailing)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let dotX = min(max(metrics.progress * width, 9), width - 9)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.secondary.opacity(0.26))
                        .frame(height: 3)
                        .position(x: width / 2, y: 18)

                    Circle()
                        .fill(metrics.inverseRarity.color)
                        .frame(width: 18, height: 18)
                        .shadow(color: metrics.inverseRarity.color.opacity(0.45), radius: 6)
                        .position(x: dotX, y: 18)
                }
            }
            .frame(height: 36)

            HStack {
                Text("Birthday / anchor \(JournalFormatters.dateTime.string(from: anchorDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                FlipRarityBadge(rarity: metrics.inverseRarity, compact: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func endpoint(_ eclipse: Eclipse, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text("Saros \(eclipse.saros) \(eclipse.displayTypeLabel)")
                .font(.caption.weight(.semibold))
            Text(JournalFormatters.date.string(from: eclipse.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AnchorEclipseProximityView: View {
    let metrics: AnchorEclipseMetrics

    var body: some View {
        HStack(spacing: 12) {
            FlipRarityBadge(rarity: metrics.inverseRarity)

            VStack(alignment: .leading, spacing: 3) {
                Text("Anchor rarity")
                    .font(.caption.weight(.semibold))
                Text("Uses closest eclipse or exact marginal center")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 3)
    }
}

private struct ThreadAnchorCubeMapView: View {
    @EnvironmentObject private var services: AppServices

    let eclipse: Eclipse

    @State private var overlay: CubeMapEclipseOverlay?
    @State private var focus = CubeMapProjectionFocus.zero
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if let overlay {
                CubeMapView(
                    overlays: [overlay],
                    displayMode: .isometric,
                    projectionOffsets: focus.offsets,
                    initialYawQuarter: focus.yawQuarter,
                    initialShowsTop: focus.showsTop,
                    allowsInteraction: false
                )
                .id("\(eclipse.id)-\(focus.offsets.longitude)-\(focus.showsTop)")
            } else if !isLoading {
                ContentUnavailableView("No eclipse path", systemImage: "map")
                    .font(.caption)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: eclipse.id) {
            await loadPath()
        }
    }

    @MainActor
    private func loadPath() async {
        isLoading = true
        errorMessage = nil
        overlay = nil

        do {
            guard let geometry = try services.eclipseService.pathGeometry(for: eclipse.id),
                  !geometry.polygons.isEmpty
            else {
                isLoading = false
                return
            }

            focus = CubeMapProjectionFocus.fitting(rings: geometry.polygons)
            overlay = CubeMapEclipseOverlay(
                id: eclipse.id,
                saros: eclipse.saros,
                title: "Saros \(eclipse.saros)",
                date: eclipse.date,
                color: .green,
                polygons: geometry.polygons
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

private struct RarityCountdownRow: View {
    let countdown: SarosFlipCountdown
    let depth: Int
    let now: Date

    private var canonicalAddress: String {
        JournalSettings.rarityOctalAddress(
            countdown.targetOctalAddress,
            storedDepth: depth,
            rarity: countdown.rarity
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            OctalGlyph(value: countdown.targetOctalAddress, depth: depth, style: countdown.rarity.glyphStyle)
                .frame(width: 42, height: 42)
                .padding(5)
                .background(countdown.rarity.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(countdown.rarity.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(countdown.rarity.color)
                Text(canonicalAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(countdownText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(countdown.rarity.color)
                    .contentTransition(.numericText())
                Text(JournalFormatters.dateTime.string(from: countdown.flipDate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 3)
    }

    private var countdownText: String {
        let interval = max(countdown.flipDate.timeIntervalSince(now), 0)
        return interval.compactDuration
    }
}

private struct ThreadFlipEvent: Identifiable {
    let id: String
    let title: String
    let date: Date
    let octalAddress: String
    let order: Int
    let rarity: FlipRarity
    let customColorHex: String?
    let isCustom: Bool
    let isFuture: Bool
    let periodDuration: TimeInterval?

    var color: Color {
        customColorHex.map { Color(hex: $0) } ?? rarity.color
    }

    var glyphStyle: OctalGlyphStyle {
        customColorHex.map { .single(Color(hex: $0)) } ?? rarity.glyphStyle
    }

    var priorityRank: Int {
        isCustom ? 100 : rarity.rank
    }
}

private struct ThreadFlipTimeline {
    let reading: SarosClockReading
    let now: Date
    let futureEvents: [ThreadFlipEvent]
    let pastEvents: [ThreadFlipEvent]

    init(
        reading: SarosClockReading,
        now: Date,
        customFlips: [CustomFlipEvent] = []
    ) {
        self.reading = reading
        self.now = now
        self.futureEvents = Self.events(reading: reading, now: now, direction: .forward, customFlips: customFlips)
        self.pastEvents = Self.events(reading: reading, now: now, direction: .backward, customFlips: customFlips)
    }

    private static func events(
        reading: SarosClockReading,
        now: Date,
        direction: ThreadFlipBinCollection.Direction,
        customFlips: [CustomFlipEvent]
    ) -> [ThreadFlipEvent] {
        var events: [ThreadFlipEvent] = []
        var seenIDs: Set<String> = []

        for rarity in FlipRarity.eventRarities(for: reading.harmonicDepth) where rarity >= .epic {
            let firstBin: Int?
            switch direction {
            case .forward:
                firstBin = reading.nextQualifiedFlipBin(after: reading.binIndex, rarity: rarity, exact: true)
            case .backward:
                firstBin = reading.previousQualifiedFlipBin(atOrBefore: reading.binIndex, rarity: rarity, exact: true)
            }

            var bin = firstBin
            var count = 0
            let limit = 24
            while let currentBin = bin, currentBin > 0, currentBin < reading.binCount, count < limit {
                let event = event(for: currentBin, rarity: rarity, reading: reading, now: now)
                if seenIDs.insert(event.id).inserted {
                    events.append(event)
                    count += 1
                }

                switch direction {
                case .forward:
                    bin = reading.nextQualifiedFlipBin(after: currentBin, rarity: rarity, exact: true)
                case .backward:
                    bin = reading.previousQualifiedFlipBin(atOrBefore: currentBin - 1, rarity: rarity, exact: true)
                }
            }
        }

        for customFlip in customFlips {
            let include = switch direction {
            case .forward:
                customFlip.date >= now
            case .backward:
                customFlip.date < now
            }
            guard include else { continue }
            let event = event(for: customFlip, now: now)
            if seenIDs.insert(event.id).inserted {
                events.append(event)
            }
        }

        return events.sorted {
            return direction == .forward ? $0.date < $1.date : $0.date > $1.date
        }
    }

    private static func event(for binIndex: Int, rarity: FlipRarity, reading: SarosClockReading, now: Date) -> ThreadFlipEvent {
        let date = reading.date(forBinIndex: binIndex)
        let isEclipse = binIndex <= 0 || binIndex >= reading.binCount
        let octalAddress = reading.octalAddress(forBinIndex: binIndex)
        let baseOrder = reading.flipOrder(forBinIndex: binIndex)
        let eventRarity = isEclipse ? .mythicDigit(7) : rarity
        let order = max(eventRarity.order, baseOrder)
        let stride = eventRarity.binStride(harmonicDepth: reading.harmonicDepth) ?? reading.binCount
        let periodDuration = Double(stride) * reading.binDuration
        return ThreadFlipEvent(
            id: "flip-\(binIndex)-\(eventRarity.id)",
            title: "Flip",
            date: date,
            octalAddress: octalAddress,
            order: order,
            rarity: eventRarity,
            customColorHex: nil,
            isCustom: false,
            isFuture: date >= now,
            periodDuration: periodDuration
        )
    }

    static func event(for customFlip: CustomFlipEvent, now: Date) -> ThreadFlipEvent {
        ThreadFlipEvent(
            id: "custom-\(customFlip.id.uuidString)",
            title: customFlip.displayName,
            date: customFlip.date,
            octalAddress: customFlip.octalAddress,
            order: 8,
            rarity: .mythicDigit(7),
            customColorHex: customFlip.colorHex,
            isCustom: true,
            isFuture: customFlip.date >= now,
            periodDuration: nil
        )
    }
}

private struct ThreadFlipBinCollection: RandomAccessCollection {
    enum Direction {
        case forward
        case backward
    }

    typealias Index = Int
    typealias Element = Int

    let startIndex = 0
    let endIndex: Int

    private let firstBin: Int
    private let step: Int
    private let direction: Direction

    init(firstBin: Int?, lastBin: Int, step: Int, direction: Direction) {
        guard let firstBin, step > 0 else {
            self.firstBin = 0
            self.step = Swift.max(step, 1)
            self.direction = direction
            self.endIndex = 0
            return
        }

        self.firstBin = firstBin
        self.step = step
        self.direction = direction

        switch direction {
        case .forward:
            endIndex = firstBin <= lastBin ? ((lastBin - firstBin) / step) + 1 : 0
        case .backward:
            endIndex = firstBin >= lastBin ? ((firstBin - lastBin) / step) + 1 : 0
        }
    }

    subscript(position: Int) -> Int {
        switch direction {
        case .forward:
            firstBin + position * step
        case .backward:
            firstBin - position * step
        }
    }
}

private struct ThreadFlipRow: View {
    let event: ThreadFlipEvent
    let depth: Int
    let now: Date
    let resonances: [ThreadFlipOverlap]

    private var rowColor: Color {
        event.color
    }

    private var dateText: String {
        Self.dateFormatter.string(from: event.date)
    }

    private var timeText: String {
        Self.timeFormatter.string(from: event.date)
    }

    private var deltaText: String {
        Self.deltaText(from: now, to: event.date)
    }

    var body: some View {
        HStack(spacing: 12) {
                OctalGlyph(value: event.octalAddress, depth: depth, style: event.glyphStyle)
                    .frame(width: 42, height: 42)
                    .padding(5)
                    .background(rowColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(dateText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(rowColor)
                    if event.isCustom {
                        Image(systemName: "star.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(rowColor)
                            .padding(5)
                            .background(rowColor.opacity(0.16), in: Circle())
                    } else {
                        FlipRarityBadge(rarity: event.rarity, compact: true)
                    }
                }
                Text(timeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(event.isCustom ? "\(event.title) · \(event.octalAddress)" : event.octalAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(rowColor)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                if !resonances.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(rowColor)
                            .padding(5)
                            .background(rowColor.opacity(0.16), in: Circle())
                        Text("\(resonances.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(deltaText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 3)
    }

    private static func deltaText(from now: Date, to date: Date) -> String {
        let isFuture = date >= now
        let startDate = isFuture ? now : date
        let endDate = isFuture ? date : now
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: startDate,
            to: endDate
        )

        let parts = [
            unitText(components.year, singular: "year"),
            unitText(components.month, singular: "month"),
            unitText(components.day, singular: "day"),
            unitText(components.hour, singular: "hour"),
            unitText(components.minute, singular: "minute")
        ]
        .compactMap { $0 }
        .prefix(4)

        let body = parts.isEmpty ? "now" : parts.joined(separator: " ")
        guard body != "now" else { return body }
        return isFuture ? "in \(body)" : "\(body) ago"
    }

    private static func unitText(_ value: Int?, singular: String) -> String? {
        guard let value, value > 0 else { return nil }
        return "\(value) \(singular)\(value == 1 ? "" : "s")"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM yyyy"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct ThreadSarosReference: Identifiable, Hashable {
    let saros: Int
    let title: String
    let entityIDs: [UUID]

    var id: Int { saros }
}

private struct ThreadFlipOverlap: Identifiable, Hashable {
    let saros: Int
    let title: String
    let date: Date
    let octalAddress: String
    let rarity: FlipRarity
    let customColorHex: String?
    let isCustom: Bool
    let delta: TimeInterval
    let resonanceOffset: TimeInterval

    var id: Int { saros }

    var badgeTitle: String {
        "S\(saros)"
    }
}

private enum ThreadFlipResonanceCalculator {
    private static let resonanceWindow: TimeInterval = 24 * 60 * 60

    static func overlaps(
        for event: ThreadFlipEvent,
        sourceSaros: Int,
        references: [ThreadSarosReference],
        clockService: any SarosClockService,
        harmonicDepth: Int,
        customFlips: [CustomFlipEvent]
    ) -> [ThreadFlipOverlap] {
        references
            .filter { $0.saros != sourceSaros }
            .compactMap { reference in
                nearestOverlap(
                    for: reference,
                    selectedDate: event.date,
                    clockService: clockService,
                    harmonicDepth: harmonicDepth,
                    customFlips: customFlips
                )
            }
            .sorted { $0.resonanceOffset < $1.resonanceOffset }
    }

    private static func nearestOverlap(
        for reference: ThreadSarosReference,
        selectedDate: Date,
        clockService: any SarosClockService,
        harmonicDepth: Int,
        customFlips: [CustomFlipEvent]
    ) -> ThreadFlipOverlap? {
        guard let reading = try? clockService.reading(
            saros: reference.saros,
            date: selectedDate,
            harmonicDepth: harmonicDepth
        ) else {
            return nil
        }

        var seenCandidates: Set<String> = []
        let regularCandidates = candidateBins(for: reading)
            .compactMap { bin -> ThreadFlipCandidate? in
                let id = "\(reading.previousEclipse.id)-\(bin)"
                guard seenCandidates.insert(id).inserted else { return nil }
                let isEclipse = bin <= 0 || bin >= reading.binCount
                return ThreadFlipCandidate(
                    title: reference.title,
                    date: reading.date(forBinIndex: bin),
                    octalAddress: reading.octalAddress(forBinIndex: bin),
                    rarity: FlipRarity.rarity(
                        forOctalAddress: reading.octalAddress(forBinIndex: bin),
                        harmonicDepth: reading.harmonicDepth,
                        isEclipse: isEclipse
                    ),
                    customColorHex: nil,
                    isCustom: false
                )
            }

        let customCandidates = customFlips
            .filter { reference.entityIDs.contains($0.entityID) }
            .compactMap { customFlip -> ThreadFlipCandidate? in
                guard seenCandidates.insert("custom-\(customFlip.id.uuidString)").inserted else { return nil }
                return ThreadFlipCandidate(
                    title: customFlip.displayName,
                    date: customFlip.date,
                    octalAddress: customFlip.octalAddress,
                    rarity: .mythicDigit(7),
                    customColorHex: customFlip.colorHex,
                    isCustom: true
                )
            }

        let candidates = (regularCandidates + customCandidates)
            .filter { abs($0.date.timeIntervalSince(selectedDate)) <= resonanceWindow }

        guard let nearest = candidates
            .min(by: { lhs, rhs in
                let lhsOffset = abs(lhs.date.timeIntervalSince(selectedDate))
                let rhsOffset = abs(rhs.date.timeIntervalSince(selectedDate))
                if lhsOffset != rhsOffset {
                    return lhsOffset < rhsOffset
                }
                return lhs.priorityRank > rhs.priorityRank
            }) else {
            return nil
        }

        let delta = nearest.date.timeIntervalSince(selectedDate)

        return ThreadFlipOverlap(
            saros: reference.saros,
            title: nearest.title,
            date: nearest.date,
            octalAddress: nearest.octalAddress,
            rarity: nearest.rarity,
            customColorHex: nearest.customColorHex,
            isCustom: nearest.isCustom,
            delta: delta,
            resonanceOffset: abs(delta)
        )
    }

    private static func candidateBins(for reading: SarosClockReading) -> [Int] {
        var bins: [Int] = [0, reading.binCount]

        for rarity in FlipRarity.eventRarities(for: reading.harmonicDepth) where rarity >= .epic {
            bins.append(contentsOf: [
                reading.previousQualifiedFlipBin(atOrBefore: reading.binIndex, rarity: rarity, exact: true),
                reading.nextQualifiedFlipBin(after: reading.binIndex, rarity: rarity, exact: true)
            ].compactMap { $0 })
        }

        return Array(Set(bins)).sorted()
    }
}

private struct ThreadFlipCandidate {
    let title: String
    let date: Date
    let octalAddress: String
    let rarity: FlipRarity
    let customColorHex: String?
    let isCustom: Bool

    var priorityRank: Int {
        isCustom ? 100 : rarity.rank
    }
}

private struct ThreadFlipResonanceDetailView: View {
    @EnvironmentObject private var services: AppServices

    let event: ThreadFlipEvent
    let sourceTitle: String
    let sourceSaros: Int
    let harmonicDepth: Int
    let sarosReferences: [ThreadSarosReference]
    let customFlips: [CustomFlipEvent]

    private var overlaps: [ThreadFlipOverlap] {
        ThreadFlipResonanceCalculator.overlaps(
            for: event,
            sourceSaros: sourceSaros,
            references: sarosReferences,
            clockService: services.clockService,
            harmonicDepth: harmonicDepth,
            customFlips: customFlips
        )
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    OctalGlyph(value: event.octalAddress, depth: harmonicDepth, style: event.glyphStyle)
                        .frame(width: 76, height: 76)
                        .padding(8)
                        .background(event.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.dateFormatter.string(from: event.date))
                            .font(.headline)
                        Text(Self.timeFormatter.string(from: event.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Saros \(sourceSaros) · \(event.octalAddress)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(event.color)
                        if event.isCustom {
                            Label(event.title, systemImage: "star.circle.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(event.color)
                        } else {
                            FlipRarityBadge(rarity: event.rarity)
                        }
                    }
                }

                MetadataRow(title: "Thread", value: sourceTitle)
                MetadataRow(title: "24h overlaps", value: "\(overlaps.count)")
            }

            Section("Overlaps") {
                if overlaps.isEmpty {
                    ContentUnavailableView("No 24-hour overlaps", systemImage: "point.3.connected.trianglepath.dotted")
                } else {
                    ForEach(overlaps) { overlap in
                        ThreadFlipOverlapRow(overlap: overlap, harmonicDepth: harmonicDepth)
                    }
                }
            }
        }
        .navigationTitle("Flip")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM yyyy"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct ThreadFlipOverlapRow: View {
    let overlap: ThreadFlipOverlap
    let harmonicDepth: Int

    private var color: Color {
        overlap.customColorHex.map { Color(hex: $0) } ?? overlap.rarity.color
    }

    private var glyphStyle: OctalGlyphStyle {
        overlap.customColorHex.map { .single(Color(hex: $0)) } ?? overlap.rarity.glyphStyle
    }

    var body: some View {
        HStack(spacing: 12) {
            OctalGlyph(value: overlap.octalAddress, depth: harmonicDepth, style: glyphStyle)
                .frame(width: 42, height: 42)
                .padding(5)
                .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Saros \(overlap.saros)")
                        .font(.subheadline.weight(.semibold))
                    if overlap.isCustom {
                        Image(systemName: "star.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(color)
                            .padding(5)
                            .background(color.opacity(0.16), in: Circle())
                    } else {
                        FlipRarityBadge(rarity: overlap.rarity, compact: true)
                    }
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(color)
                        .padding(5)
                        .background(color.opacity(0.16), in: Circle())
                }
                Text(overlap.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(overlap.octalAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(color)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.dateFormatter.string(from: overlap.date))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Text(Self.timeFormatter.string(from: overlap.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(deltaText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 3)
    }

    private var deltaText: String {
        let seconds = abs(overlap.delta)
        let body = JournalFormatters.time.string(from: seconds) ?? "\(Int(seconds / 60))m"
        if overlap.delta == 0 {
            return "same time"
        }
        return overlap.delta > 0 ? "+\(body)" : "-\(body)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM yyyy"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct CustomFlipDraft: Identifiable {
    let id = UUID()
    let entityID: UUID
    var name: String
    let date: Date
    let octalAddress: String
    let binIndex: Int
    var colorHex: String
}

private struct CustomFlipEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let draft: CustomFlipDraft
    let save: (CustomFlipDraft) -> Void

    @State private var name: String
    @State private var color: Color

    init(draft: CustomFlipDraft, save: @escaping (CustomFlipDraft) -> Void) {
        self.draft = draft
        self.save = save
        _name = State(initialValue: draft.name)
        _color = State(initialValue: Color(hex: draft.colorHex))
    }

    var body: some View {
        Form {
            Section("Custom rarity") {
                TextField("Name", text: $name)
                ColorPicker("Color", selection: $color, supportsOpacity: false)
            }

            Section("Flip") {
                MetadataRow(title: "Octal", value: draft.octalAddress)
                MetadataRow(title: "Date", value: JournalFormatters.dateTime.string(from: draft.date))
            }
        }
        .navigationTitle("Add Flip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    var savedDraft = draft
                    savedDraft.name = name
                    savedDraft.colorHex = color.hexRGBString
                    save(savedDraft)
                    dismiss()
                }
            }
        }
    }
}

private struct CustomFlipRow: View {
    let customFlip: CustomFlipEvent
    let harmonicDepth: Int

    private var color: Color {
        Color(hex: customFlip.colorHex)
    }

    var body: some View {
        HStack(spacing: 12) {
            OctalGlyph(value: customFlip.octalAddress, depth: harmonicDepth, color: color)
                .frame(width: 42, height: 42)
                .padding(5)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Label(customFlip.displayName, systemImage: "star.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                Text(customFlip.octalAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(JournalFormatters.dateTime.string(from: customFlip.date))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 3)
    }
}

private struct ThreadGlyphSearchView: View {
    let reading: SarosClockReading
    let clockService: any SarosClockService
    let addFlip: (String, Int, Date) -> Void

    @State private var digits: [Int] = []
    @State private var selectedDate = Date()
    @State private var dateReading: SarosClockReading?
    @State private var dateResolutionError: String?

    private var selectedAddress: String {
        normalizedDigits.map(String.init).joined()
    }

    private var activeReading: SarosClockReading {
        dateReading ?? reading
    }

    private var selectedBinIndex: Int {
        activeReading.binIndex(forOctalAddress: selectedAddress)
    }

    private var selectedStartDate: Date {
        activeReading.date(forBinIndex: selectedBinIndex)
    }

    private var normalizedDigits: [Int] {
        let prefix = Array(digits.prefix(reading.harmonicDepth))
        if prefix.count == reading.harmonicDepth {
            return prefix
        }
        return prefix + Array(repeating: 0, count: reading.harmonicDepth - prefix.count)
    }

    var body: some View {
        VStack(spacing: 12) {
            GlyphRarityProximityBar(reading: activeReading, date: selectedDate)

            OctalGlyph(value: selectedAddress, depth: reading.harmonicDepth)
                .frame(width: 128, height: 128)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

            DatePicker(
                "Date",
                selection: $selectedDate,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .onChange(of: selectedDate) { _, newDate in
                syncDigits(from: newDate)
            }

            HStack(spacing: 4) {
                ForEach(0..<reading.harmonicDepth, id: \.self) { index in
                    OctalDigitWheel(digit: digitBinding(at: index))
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 4) {
                Text(JournalFormatters.dateTime.string(from: selectedStartDate))
                    .font(.subheadline.weight(.semibold))
                if let dateResolutionError {
                    Text(dateResolutionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Button {
                addFlip(selectedAddress, selectedBinIndex, selectedDate)
            } label: {
                Label("Add flip", systemImage: "plus.circle")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(dateResolutionError != nil)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            syncDigitsIfNeeded()
        }
        .onChange(of: reading.harmonicDepth) { _, _ in
            syncDigitsIfNeeded()
        }
    }

    private func digitBinding(at index: Int) -> Binding<Int> {
        Binding {
            guard index < digits.count else { return 0 }
            return digits[index]
        } set: { newValue in
            guard index < digits.count else { return }
            digits[index] = min(max(newValue, 0), 7)
            syncDateFromDigits()
        }
    }

    private func syncDigitsIfNeeded() {
        guard digits.count != reading.harmonicDepth else { return }
        digits = reading.octalAddress.map { Int(String($0)) ?? 0 }
        dateReading = reading
        selectedDate = reading.date(forBinIndex: reading.binIndex)
        dateResolutionError = nil
    }

    private func syncDigits(from date: Date) {
        do {
            let resolved = try clockService.reading(
                saros: reading.saros,
                date: date,
                harmonicDepth: reading.harmonicDepth
            )
            dateReading = resolved
            digits = resolved.octalAddress.map { Int(String($0)) ?? 0 }
            dateResolutionError = nil
        } catch {
            dateResolutionError = error.localizedDescription
        }
    }

    private func syncDateFromDigits() {
        let date = selectedStartDate
        selectedDate = date
        dateReading = activeReading
        dateResolutionError = nil
    }
}

private struct GlyphRarityProximityBar: View {
    let reading: SarosClockReading
    let date: Date

    private let rarities: [FlipRarity] = [.rare, .epic, .legendary, .mythic]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(rarities) { rarity in
                GlyphRarityProximityCell(
                    rarity: rarity,
                    octalScore: octalScore(for: rarity)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func octalScore(for rarity: FlipRarity) -> String {
        guard let strideValue = rarity.binStride(harmonicDepth: reading.harmonicDepth) else {
            return "000"
        }
        let stride = Double(strideValue)
        guard stride > 0 else { return "000" }

        let rawPhase = date.timeIntervalSince(reading.previousEclipse.date) / max(reading.intervalDuration, 1)
        let continuousBin = min(max(rawPhase * Double(reading.binCount), 0), Double(reading.binCount))
        let offsets = rarity.isHeaderRarity
            ? rarity.subrarities.compactMap { $0.subeventOffset(harmonicDepth: reading.harmonicDepth) }
            : [rarity.subeventOffset(harmonicDepth: reading.harmonicDepth)].compactMap { $0 }
        let distance = offsets
            .map { offset in Self.wrappedDistance(from: continuousBin, to: Double(offset), period: stride) }
            .min() ?? 0
        let halfPeriod = stride / 2
        let proximity = 1 - min(max(distance / halfPeriod, 0), 1)
        let scaled = min(max(Int((proximity * 511).rounded()), 0), 511)
        return String(scaled, radix: 8).leftPadded(toLength: 3, withPad: "0")
    }

    private static func wrappedDistance(from value: Double, to offset: Double, period: Double) -> Double {
        guard period > 0 else { return 0 }
        var delta = (value - offset).truncatingRemainder(dividingBy: period)
        if delta < 0 {
            delta += period
        }
        return min(delta, period - delta)
    }
}

private struct GlyphRarityProximityCell: View {
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    let rarity: FlipRarity
    let octalScore: String

    var body: some View {
        VStack(spacing: 5) {
            FlipRarityGlyphIcon(rarity: rarity, harmonicDepth: harmonicDepth, size: 22)
            OctalGlyph(value: octalScore, depth: 3, color: rarity.color)
                .frame(width: 34, height: 34)
                .padding(4)
                .background(rarity.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(rarity.title) proximity \(octalScore)")
    }
}

private struct OctalDigitWheel: View {
    @Binding var digit: Int

    var body: some View {
        Picker("Octal digit", selection: $digit) {
            ForEach(0..<8, id: \.self) { value in
                Text("\(value)")
                    .font(.system(.headline, design: .monospaced))
                    .tag(value)
            }
        }
        .pickerStyle(.wheel)
        .frame(width: 40, height: 78)
        .clipped()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Octal digit")
    }
}

struct MirrorCameraCapturedMedia {
    let type: MediaType
    let data: Data?
    let sourceURL: URL?
    let fileExtension: String
}

private enum MirrorCameraReviewCapture {
    case photo(UIImage)
    case video(URL, thumbnail: UIImage)

    var sourceImage: UIImage {
        switch self {
        case .photo(let image):
            image
        case .video(_, let thumbnail):
            thumbnail
        }
    }

    var isVideo: Bool {
        switch self {
        case .photo:
            false
        case .video:
            true
        }
    }
}

private struct MirrorOutputConfiguration: Hashable, Sendable {
    var mode: ThreadMirrorCameraMode
    var reflectionSelection: MirrorReflectionSelection
    var imageTransform: MirrorImageTransform
    var isBinaryFilterEnabled: Bool
    var thresholdLevel: Double
    var isDoubleOutputEnabled: Bool
    var temporalMode: MediaTemporalMode
}

private struct MirrorImageTransform: Hashable, Sendable {
    var freeRotationRadians: CGFloat
    var scale: CGFloat
    var offset: CGSize
}

private enum MirrorOutputComposer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func renderPhoto(
        source: UIImage,
        configuration: MirrorOutputConfiguration
    ) -> UIImage? {
        guard let square = squareImage(source) else { return nil }
        let transformedSource = transformedImage(square, transform: configuration.imageTransform)

        if configuration.isDoubleOutputEnabled {
            return renderDoublePhoto(source: transformedSource, configuration: configuration)
        }

        return renderedImage(from: processedImage(
            source: transformedSource,
            configuration: configuration,
            reflectionSelection: configuration.reflectionSelection
        ))
    }

    static func processedVideoImage(
        source: CIImage,
        configuration: MirrorOutputConfiguration
    ) -> CIImage {
        let square = transformedImage(
            squareImage(source),
            transform: configuration.imageTransform
        )
        guard configuration.isDoubleOutputEnabled else {
            return processedImage(
                source: square,
                configuration: configuration,
                reflectionSelection: configuration.reflectionSelection
            )
        }

        let positive = processedImage(
            source: square,
            configuration: configuration,
            reflectionSelection: .positive
        )
        let negative = processedImage(
            source: square,
            configuration: configuration,
            reflectionSelection: .negative
        )
        let side = square.extent.width
        let bottom = negative.transformed(by: CGAffineTransform(translationX: -negative.extent.minX, y: -negative.extent.minY))
        let top = positive
            .transformed(by: CGAffineTransform(translationX: -positive.extent.minX, y: -positive.extent.minY + side))
            .composited(over: bottom)
        return top.cropped(to: CGRect(x: 0, y: 0, width: side, height: side * 2))
    }

    static func renderPreview(
        source: UIImage,
        configuration: MirrorOutputConfiguration
    ) -> UIImage? {
        renderPhoto(source: source, configuration: configuration)
    }

    static func renderDatasetImage(
        source: UIImage,
        configuration: MirrorOutputConfiguration,
        outputSide: CGFloat = 224
    ) -> UIImage? {
        guard let square = squareImage(source) else { return nil }
        let transformedSource = transformedImage(square, transform: configuration.imageTransform)
        let output = processedImage(
            source: transformedSource,
            configuration: configuration,
            reflectionSelection: configuration.reflectionSelection
        )
        return renderedImage(from: resizedSquareImage(output, side: outputSide))
    }

    private static func renderDoublePhoto(
        source: CIImage,
        configuration: MirrorOutputConfiguration
    ) -> UIImage? {
        guard
            let topImage = renderedImage(from: processedImage(
                source: source,
                configuration: configuration,
                reflectionSelection: .positive
            )),
            let bottomImage = renderedImage(from: processedImage(
                source: source,
                configuration: configuration,
                reflectionSelection: .negative
            ))
        else {
            return nil
        }

        let side = max(topImage.size.width, 2)
        let size = CGSize(width: side, height: side * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.black.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            topImage.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            bottomImage.draw(in: CGRect(x: 0, y: side, width: side, height: side))
        }
    }

    private static func processedImage(
        source: CIImage,
        configuration: MirrorOutputConfiguration,
        reflectionSelection: MirrorReflectionSelection
    ) -> CIImage {
        var output = MirrorReflectionProcessor.process(
            source,
            edges: configuration.mode.edges(
                reflectionSelection: reflectionSelection
            )
        )
        if configuration.isBinaryFilterEnabled {
            output = thresholdImage(output, threshold: configuration.thresholdLevel)
        }
        return output
    }

    private static func renderedImage(from image: CIImage) -> UIImage? {
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private static func resizedSquareImage(_ image: CIImage, side: CGFloat) -> CIImage {
        let extent = image.extent
        let sourceSide = min(extent.width, extent.height)
        let crop = CGRect(
            x: extent.midX - sourceSide / 2,
            y: extent.midY - sourceSide / 2,
            width: sourceSide,
            height: sourceSide
        )
        let safeSide = max(side, 2)
        let scale = safeSide / max(sourceSide, 1)
        return image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: safeSide, height: safeSide))
    }

    private static func squareImage(_ image: UIImage) -> CIImage? {
        guard let input = CIImage(image: image)?.oriented(CGImagePropertyOrientation(image.imageOrientation)) else {
            return nil
        }
        return squareImage(input)
    }

    private static func transformedImage(
        _ image: CIImage,
        transform: MirrorImageTransform
    ) -> CIImage {
        let extent = image.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let radians = transform.freeRotationRadians
        let coverScale = abs(cos(radians)) + abs(sin(radians))
        let scale = max(transform.scale, coverScale, 0.1)
        let offset = transform.offset

        let affineTransform = CGAffineTransform(translationX: center.x + offset.width * extent.width, y: center.y - offset.height * extent.height)
            .rotated(by: radians)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -center.x, y: -center.y)

        return reflectedTile(from: image)
            .transformed(by: affineTransform)
            .cropped(to: extent)
    }

    private static func reflectedTile(from image: CIImage) -> CIImage {
        let source = squareImage(image)
        let side = source.extent.width
        let bleed = max(side * 0.006, 4)
        let paddedSource = source
            .clampedToExtent()
            .cropped(to: source.extent.insetBy(dx: -bleed, dy: -bleed))
        let tileExtent = CGRect(x: 0, y: 0, width: side * 2, height: side * 2)

        let right = paddedSource.transformed(by: CGAffineTransform(
            a: -1,
            b: 0,
            c: 0,
            d: 1,
            tx: side * 2,
            ty: 0
        ))
        let top = paddedSource.transformed(by: CGAffineTransform(
            a: 1,
            b: 0,
            c: 0,
            d: -1,
            tx: 0,
            ty: side * 2
        ))
        let topRight = paddedSource.transformed(by: CGAffineTransform(
            a: -1,
            b: 0,
            c: 0,
            d: -1,
            tx: side * 2,
            ty: side * 2
        ))

        let tile = topRight
            .composited(over: top)
            .composited(over: right)
            .composited(over: paddedSource)
            .cropped(to: tileExtent)

        let filter = CIFilter(name: "CIAffineTile")
        filter?.setValue(tile, forKey: kCIInputImageKey)
        return filter?.outputImage ?? tile.clampedToExtent()
    }

    private static func squareImage(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let side = min(extent.width, extent.height)
        let crop = CGRect(
            x: extent.midX - side / 2,
            y: extent.midY - side / 2,
            width: side,
            height: side
        )
        return image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    private static func thresholdImage(_ image: CIImage, threshold: Double) -> CIImage {
        guard let thresholdFilter = CIFilter(name: "CIColorThreshold") else { return image }
        let clampedThreshold = min(max(threshold, 0), 1)

        thresholdFilter.setValue(image, forKey: kCIInputImageKey)
        thresholdFilter.setValue(clampedThreshold, forKey: "inputThreshold")

        guard let mask = thresholdFilter.outputImage?.cropped(to: image.extent) else {
            return image
        }

        let white = CIImage(color: .white).cropped(to: image.extent)
        let black = CIImage(color: .black).cropped(to: image.extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = white
        blend.backgroundImage = black
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: image.extent) ?? image
    }
}

private extension CGImagePropertyOrientation {
    init(_ imageOrientation: UIImage.Orientation) {
        switch imageOrientation {
        case .up:
            self = .up
        case .down:
            self = .down
        case .left:
            self = .left
        case .right:
            self = .right
        case .upMirrored:
            self = .upMirrored
        case .downMirrored:
            self = .downMirrored
        case .leftMirrored:
            self = .leftMirrored
        case .rightMirrored:
            self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}

struct MirrorCameraView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = ThreadMirrorCameraController()
    @StateObject private var saver = CameraRollMediaSaver()
    @AppStorage(JournalSettings.cameraPositionKey) private var cameraPositionRaw = "back"
    @AppStorage(JournalSettings.cameraBackLensKey) private var cameraBackLensRaw = MirrorCameraBackLens.wide.rawValue
    @AppStorage(JournalSettings.cameraMirrorModeKey) private var mirrorModeRaw = ThreadMirrorCameraMode.vertical.rawValue
    @AppStorage(JournalSettings.cameraReflectionSelectionKey) private var reflectionSelectionRaw = MirrorReflectionSelection.positive.rawValue
    @AppStorage(JournalSettings.cameraLensPositionKey) private var lensPosition = 0.5
    @AppStorage(JournalSettings.cameraExposureLevelKey) private var exposureLevel = 0.5
    @AppStorage(JournalSettings.cameraThresholdLevelKey) private var thresholdLevel = 0.5
    @AppStorage(JournalSettings.cameraBinaryFilterEnabledKey) private var isBinaryFilterEnabled = false
    @AppStorage(JournalSettings.cameraFocusManualKey) private var isFocusManual = false
    @AppStorage(JournalSettings.cameraExposureManualKey) private var isExposureManual = false
    @AppStorage(JournalSettings.cameraTimedVideoDurationKey) private var timedVideoDuration = 3
    @AppStorage(JournalSettings.cameraTimedVideoForwardEnabledKey) private var isTimedVideoForwardEnabled = true
    @AppStorage(JournalSettings.cameraTimedVideoBackwardEnabledKey) private var isTimedVideoBackwardEnabled = true
    @State private var isDoubleOutputEnabled = false
    @State private var reviewFreeRotationRadians: CGFloat = 0
    @State private var reviewScale: CGFloat = 1
    @State private var lastReviewScale: CGFloat = 1
    @State private var reviewOffset: CGSize = .zero
    @State private var lastReviewOffset: CGSize = .zero
    @State private var liveFocusPoint: CGPoint?
    @State private var captureHoldWorkItem: DispatchWorkItem?
    @State private var isCapturePressActive = false
    @State private var didStartVideoDuringPress = false
    @State private var timedCaptureCountdownStart: Date?
    @State private var timedCaptureCountdownTask: Task<Void, Never>?
    @State private var timedCaptureStopTask: Task<Void, Never>?
    @State private var reviewCapture: MirrorCameraReviewCapture?
    @State private var reviewCaptureID = UUID()
    @State private var reviewPreviewImage: UIImage?
    @State private var isProcessingReview = false
    @State private var isTrackingAnimacyDataset = false
    @State private var sonificationSession: ImageSonificationSession?
    @State private var importPhotoItem: PhotosPickerItem?
    @State private var isImportingPhoto = false

    private let onCapturedMedia: ((MirrorCameraCapturedMedia) -> Void)?

    init(onCapturedMedia: ((MirrorCameraCapturedMedia) -> Void)? = nil) {
        self.onCapturedMedia = onCapturedMedia
    }

    private static let timedCaptureCountdownDuration: TimeInterval = 3
    private static let timedVideoDurationRange = 1...12

    private static func clampedTimedVideoDuration(_ value: Int) -> Int {
        min(max(value, timedVideoDurationRange.lowerBound), timedVideoDurationRange.upperBound)
    }

    private var preferredCameraPosition: AVCaptureDevice.Position {
        cameraPositionRaw == "front" ? .front : .back
    }

    private var preferredBackLens: MirrorCameraBackLens {
        MirrorCameraBackLens(rawValue: cameraBackLensRaw) ?? .wide
    }

    private var mode: ThreadMirrorCameraMode {
        ThreadMirrorCameraMode(rawValue: mirrorModeRaw) ?? .vertical
    }

    private var reflectionSelection: MirrorReflectionSelection {
        MirrorReflectionSelection(rawValue: reflectionSelectionRaw) ?? .positive
    }

    private func setMode(_ newMode: ThreadMirrorCameraMode) {
        mirrorModeRaw = newMode.rawValue
    }

    private func setReflectionSelection(_ newSelection: MirrorReflectionSelection) {
        reflectionSelectionRaw = newSelection.rawValue
    }

    private var outputConfiguration: MirrorOutputConfiguration {
        MirrorOutputConfiguration(
            mode: mode,
            reflectionSelection: reflectionSelection,
            imageTransform: MirrorImageTransform(
                freeRotationRadians: reviewFreeRotationRadians,
                scale: reviewScale,
                offset: reviewOffset
            ),
            isBinaryFilterEnabled: isBinaryFilterEnabled,
            thresholdLevel: thresholdLevel,
            isDoubleOutputEnabled: isDoubleOutputEnabled,
            temporalMode: temporalMode
        )
    }

    private var temporalMode: MediaTemporalMode {
        switch (isTimedVideoForwardEnabled, isTimedVideoBackwardEnabled) {
        case (true, true):
            .forwardBackward
        case (true, false):
            .forward
        case (false, true):
            .backward
        case (false, false):
            .forwardBackward
        }
    }

    private var reviewPreviewKey: String {
        [
            reviewCapture == nil ? "live" : reviewCaptureID.uuidString,
            mode.id,
            "\(reflectionSelection)",
            "\(reviewFreeRotationRadians)",
            "\(reviewScale)",
            "\(reviewOffset.width)",
            "\(reviewOffset.height)",
            isBinaryFilterEnabled ? "binary" : "color",
            "\(thresholdLevel)",
            isDoubleOutputEnabled ? "double" : "single"
        ].joined(separator: "|")
    }

    var body: some View {
        GeometryReader { proxy in
            let previewSide = Self.previewSide(for: proxy.size)

            VStack(spacing: 0) {
                cameraPreview(side: previewSide)
                    .padding(.top, 16)

                if reviewCapture != nil {
                    reviewRotationSlider
                        .padding(.horizontal, 24)
                        .padding(.top, 10)
                } else {
                    liveCapturePrepControls
                        .padding(.top, 10)
                }

                Spacer(minLength: reviewCapture == nil ? 14 : 10)

                controlPanel
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            ensureTemporalCaptureSelection()
            camera.configurePreferredCamera(
                position: preferredCameraPosition,
                backLens: preferredBackLens
            )
            camera.setMirror(
                mode: mode,
                reflectionSelection: reflectionSelection
            )
            camera.setFilter(isBinaryEnabled: isBinaryFilterEnabled, threshold: thresholdLevel)
            if isFocusManual {
                camera.setLensPosition(lensPosition)
            }
            if isExposureManual {
                camera.setExposureLevel(exposureLevel)
            }
            await camera.start()
        }
        .onChange(of: camera.cameraPosition) { _, newValue in
            cameraPositionRaw = newValue == .front ? "front" : "back"
        }
        .onChange(of: camera.backLens) { _, newValue in
            cameraBackLensRaw = newValue.rawValue
        }
        .onChange(of: timedVideoDuration) { _, newValue in
            timedVideoDuration = Self.clampedTimedVideoDuration(newValue)
        }
        .onDisappear {
            captureHoldWorkItem?.cancel()
            cancelTimedCapture()
            if camera.isRecordingVideo {
                camera.stopVideoRecording { _ in }
            }
            camera.stop()
        }
        .sheet(isPresented: $isTrackingAnimacyDataset) {
            if let reviewCapture, !reviewCapture.isVideo {
                NavigationStack {
                    AnimacyDatasetTrackerView(
                        sourceImage: reviewCapture.sourceImage,
                        initialConfiguration: outputConfiguration
                    )
                }
            }
        }
        .sheet(item: $sonificationSession) { session in
            NavigationStack {
                ImageSonificationPanelView(image: session.image)
            }
        }
        .onChange(of: importPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await importPhoto(from: newItem)
            }
        }
    }

    @ViewBuilder
    private func cameraPreview(side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.06))

            if let reviewCapture {
                Image(uiImage: reviewPreviewImage ?? reviewCapture.sourceImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .clipped()

                reviewOverlayButtons
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
            } else if let previewImage = camera.previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()

                if let liveFocusPoint {
                    Circle()
                        .stroke(.yellow, lineWidth: 2)
                        .frame(width: 58, height: 58)
                        .position(liveFocusPoint)
                        .transition(.scale.combined(with: .opacity))
                }
            } else {
                ThreadCameraPlaceholderView(
                    state: camera.authorizationState,
                    errorMessage: camera.errorMessage
                )
            }

            if onCapturedMedia != nil {
                cameraCloseButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            }

            if let timedCaptureCountdownStart {
                TimedVideoCountdownView(
                    startDate: timedCaptureCountdownStart,
                    duration: Self.timedCaptureCountdownDuration
                )
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .task(id: reviewPreviewKey) {
            updateReviewPreview()
        }
        .simultaneousGesture(liveFocusGesture(side: side))
        .simultaneousGesture(reviewPanGesture(side: side))
        .simultaneousGesture(reviewZoomGesture())
    }

    private var cameraCloseButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.42), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close camera")
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            if let statusMessage = saver.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(saver.didFail ? .red : .white.opacity(0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.45), in: Capsule())
            }

            if reviewCapture == nil {
                liveAdjustmentControls
            }

            if let reviewCapture, !reviewCapture.isVideo {
                trackEntityButton
            }

            cameraControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var liveAdjustmentControls: some View {
        HStack(alignment: .center, spacing: 12) {
            RadialTickSlider(
                value: $lensPosition,
                systemImage: "scope",
                tint: .cyan,
                orientation: .inwardFromLeft,
                accessibilityLabel: "Lens position"
            )
            .frame(maxWidth: .infinity)
            .frame(height: 112)
            .onChange(of: lensPosition) { _, newValue in
                isFocusManual = true
                camera.setLensPosition(newValue)
            }

            binaryFilterToggle

            RadialTickSlider(
                value: isBinaryFilterEnabled ? $thresholdLevel : $exposureLevel,
                systemImage: isBinaryFilterEnabled ? "circle.lefthalf.filled" : "sun.max",
                tint: isBinaryFilterEnabled ? .cyan : .yellow,
                orientation: .inwardFromRight,
                accessibilityLabel: isBinaryFilterEnabled ? "Threshold" : "Exposure"
            )
            .frame(maxWidth: .infinity)
            .frame(height: 112)
            .onChange(of: thresholdLevel) { _, newValue in
                camera.setFilter(isBinaryEnabled: isBinaryFilterEnabled, threshold: newValue)
            }
            .onChange(of: exposureLevel) { _, newValue in
                isExposureManual = true
                camera.setExposureLevel(newValue)
            }
        }
    }

    private var reviewTopToggle: some View {
        Button {
            isDoubleOutputEnabled.toggle()
        } label: {
            Image(systemName: isDoubleOutputEnabled ? "rectangle.stack.fill" : "rectangle.stack")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(isDoubleOutputEnabled ? .cyan.opacity(0.72) : .black.opacity(0.42), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isProcessingReview)
        .accessibilityLabel("Toggle double output")
    }

    @ViewBuilder
    private var reviewOverlayButtons: some View {
        VStack(spacing: 10) {
            reviewTopToggle

            if let reviewCapture, !reviewCapture.isVideo {
                reviewSoundButton
            }
        }
    }

    private var reviewSoundButton: some View {
        Button {
            openSonificationPanel()
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.42), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isProcessingReview)
        .accessibilityLabel("Sonify image")
    }

    private var liveCapturePrepControls: some View {
        HStack(spacing: 12) {
            timedVideoDurationWheel
            temporalDirectionButton(
                systemImage: "arrow.left",
                isSelected: isTimedVideoBackwardEnabled,
                accessibilityLabel: "Capture backward video"
            ) {
                setBackwardTemporalCaptureEnabled(!isTimedVideoBackwardEnabled)
            }
            timedVideoButton
            temporalDirectionButton(
                systemImage: "arrow.right",
                isSelected: isTimedVideoForwardEnabled,
                accessibilityLabel: "Capture forward video"
            ) {
                setForwardTemporalCaptureEnabled(!isTimedVideoForwardEnabled)
            }
            importPhotoButton
                .frame(width: 72)
        }
        .frame(maxWidth: .infinity)
    }

    private var timedVideoDurationWheel: some View {
        Picker("Timed video duration", selection: $timedVideoDuration) {
            ForEach(Self.timedVideoDurationRange, id: \.self) { seconds in
                Text("\(seconds)s")
                    .tag(seconds)
            }
        }
        .pickerStyle(.wheel)
        .frame(width: 64, height: 58)
        .clipped()
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .disabled(camera.isRecordingVideo || timedCaptureCountdownStart != nil || saver.isSaving)
        .opacity((camera.isRecordingVideo || timedCaptureCountdownStart != nil || saver.isSaving) ? 0.55 : 1)
        .accessibilityLabel("Timed video duration")
    }

    private var timedVideoButton: some View {
        Button {
            if timedCaptureCountdownStart == nil {
                startTimedVideoCountdown()
            } else {
                cancelTimedCapture()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.42))
                    .frame(width: 54, height: 54)

                if timedCaptureCountdownStart != nil {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "timer")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(
            timedCaptureCountdownStart == nil
                && (camera.previewImage == nil || camera.isRecordingVideo || saver.isSaving || isImportingPhoto)
        )
        .opacity(
            timedCaptureCountdownStart == nil
                && (camera.previewImage == nil || camera.isRecordingVideo || saver.isSaving || isImportingPhoto)
                ? 0.45
                : 1
        )
        .accessibilityLabel(timedCaptureCountdownStart == nil ? "Start timed video" : "Cancel timed video countdown")
    }

    private func temporalDirectionButton(
        systemImage: String,
        isSelected: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.bold))
                .foregroundStyle(isSelected ? .black : .white)
                .frame(width: 44, height: 44)
                .background(isSelected ? .white : .black.opacity(0.42), in: Circle())
                .overlay {
                    Circle()
                        .stroke(isSelected ? .white.opacity(0.85) : .white.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecordingVideo || timedCaptureCountdownStart != nil || saver.isSaving)
        .opacity((camera.isRecordingVideo || timedCaptureCountdownStart != nil || saver.isSaving) ? 0.55 : 1)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var importPhotoButton: some View {
        PhotosPicker(selection: $importPhotoItem, matching: .images) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(.black.opacity(0.42))
                        .frame(width: 54, height: 54)

                    if isImportingPhoto {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }

                Text("Import")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecordingVideo || saver.isSaving || isImportingPhoto || timedCaptureCountdownStart != nil)
        .opacity((camera.isRecordingVideo || saver.isSaving || isImportingPhoto || timedCaptureCountdownStart != nil) ? 0.5 : 1)
        .accessibilityLabel("Import image")
    }

    private var trackEntityButton: some View {
        Button {
            isTrackingAnimacyDataset = true
        } label: {
            Label("Track entity", systemImage: "scope")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.cyan.opacity(0.28), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.cyan.opacity(0.55), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(isProcessingReview)
    }

    private var reviewRotationDegrees: Binding<Double> {
        Binding {
            Double(reviewFreeRotationRadians) * 180 / Double.pi
        } set: { newValue in
            setReviewRotation(CGFloat(newValue * Double.pi / 180))
        }
    }

    private var reviewRotationSlider: some View {
        HStack(spacing: 10) {
            rotationStepButton(
                systemImage: "rotate.left",
                degrees: -45,
                accessibilityLabel: "Rotate image counterclockwise 45 degrees"
            )

            Slider(value: reviewRotationDegrees, in: -180...180, step: 1)
                .tint(.cyan)

            rotationStepButton(
                systemImage: "rotate.right",
                degrees: 45,
                accessibilityLabel: "Rotate image clockwise 45 degrees"
            )
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.42), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.1), lineWidth: 1)
        }
        .accessibilityLabel("Image rotation")
    }

    private func rotationStepButton(
        systemImage: String,
        degrees: Double,
        accessibilityLabel: String
    ) -> some View {
        Button {
            rotateReviewImage(byDegrees: degrees)
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var binaryFilterToggle: some View {
        Button {
            isBinaryFilterEnabled.toggle()
            camera.setFilter(isBinaryEnabled: isBinaryFilterEnabled, threshold: thresholdLevel)
        } label: {
            Image(systemName: isBinaryFilterEnabled ? "circle.lefthalf.filled" : "sun.max")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(isBinaryFilterEnabled ? .cyan.opacity(0.75) : .black.opacity(0.38), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle binary filter")
    }

    private var cameraControls: some View {
        HStack(spacing: 10) {
            if reviewCapture == nil {
                cameraToolButton(
                    systemImage: "camera.rotate",
                    accessibilityLabel: "Switch camera",
                    action: camera.switchCamera
                )

                cameraToolButton(
                    systemImage: camera.backLens.symbolName,
                    accessibilityLabel: "Switch back lens",
                    action: camera.cycleBackLens
                )
            } else {
                cameraToolButton(
                    systemImage: "xmark",
                    accessibilityLabel: "Discard capture",
                    action: discardReviewCapture
                )

                cameraToolButton(
                    systemImage: "arrow.counterclockwise",
                    accessibilityLabel: "Reset edit transform",
                    action: resetReviewTransform
                )
            }

            captureControl

            cameraToolButton(
                systemImage: mode.symbolName,
                accessibilityLabel: "Toggle mirror mode"
            ) {
                setMode(mode.next)
                camera.setMirror(
                    mode: mode,
                    reflectionSelection: reflectionSelection
                )
            }

            cameraToolButton(
                systemImage: reflectionSelection.symbolName,
                accessibilityLabel: "Toggle reflected side"
            ) {
                setReflectionSelection(reflectionSelection.next)
                camera.setMirror(
                    mode: mode,
                    reflectionSelection: reflectionSelection
                )
            }
        }
    }

    @ViewBuilder
    private var captureControl: some View {
        if reviewCapture == nil {
            ZStack {
                Circle()
                    .stroke(camera.isRecordingVideo ? .red : .white, lineWidth: 4)
                    .frame(width: 64, height: 64)
                Circle()
                    .fill(camera.isRecordingVideo ? .red : .white)
                    .frame(width: camera.isRecordingVideo ? 34 : 48, height: camera.isRecordingVideo ? 34 : 48)
                    .animation(.snappy(duration: 0.18), value: camera.isRecordingVideo)
            }
            .contentShape(Circle())
            .opacity((camera.previewImage == nil || saver.isSaving) && !camera.isRecordingVideo ? 0.45 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        handleCapturePressBegan()
                    }
                    .onEnded { _ in
                        handleCapturePressEnded()
                    }
            )
            .accessibilityLabel(camera.isRecordingVideo ? "Stop video recording" : "Capture photo or hold to record video")
        } else {
            Button {
                saveReviewCapture()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(width: 64, height: 64)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isProcessingReview || saver.isSaving)
            .opacity((isProcessingReview || saver.isSaving) ? 0.55 : 1)
            .accessibilityLabel("Save edited capture")
        }
    }

    private func liveFocusGesture(side: CGFloat) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard reviewCapture == nil else { return }
                let location = value.location
                guard CGRect(x: 0, y: 0, width: side, height: side).contains(location) else { return }

                withAnimation(.snappy(duration: 0.18)) {
                    liveFocusPoint = location
                }
                camera.focusAndExpose(at: CGPoint(
                    x: min(max(location.x / side, 0), 1),
                    y: min(max(location.y / side, 0), 1)
                ))
                isFocusManual = false
                isExposureManual = false

                let focusedPoint = location
                Task {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    await MainActor.run {
                        guard liveFocusPoint == focusedPoint else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            liveFocusPoint = nil
                        }
                    }
                }
            }
    }

    private func reviewPanGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard reviewCapture != nil, side > 0 else { return }
                reviewOffset = clampedReviewOffset(CGSize(
                    width: lastReviewOffset.width + value.translation.width / side,
                    height: lastReviewOffset.height + value.translation.height / side
                ))
            }
            .onEnded { _ in
                lastReviewOffset = reviewOffset
            }
    }

    private func reviewZoomGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard reviewCapture != nil else { return }
                reviewScale = min(max(lastReviewScale * value, 1), 4)
            }
            .onEnded { _ in
                lastReviewScale = reviewScale
            }
    }

    private func rotateReviewImage(byDegrees degrees: Double) {
        setReviewRotation(reviewFreeRotationRadians + CGFloat(degrees * Double.pi / 180))
    }

    private func setReviewRotation(_ radians: CGFloat) {
        let normalizedRadians = Self.normalizedReviewRotation(radians)
        guard reviewCapture != nil else {
            reviewFreeRotationRadians = normalizedRadians
            return
        }

        let focus = reviewFocusVector(
            rotation: reviewFreeRotationRadians,
            scale: effectiveReviewScale(for: reviewFreeRotationRadians),
            offset: reviewOffset
        )
        let nextScale = effectiveReviewScale(for: normalizedRadians)
        let rotatedFocus = Self.rotated(focus, by: normalizedRadians)
        let translation = CGPoint(
            x: -rotatedFocus.x * nextScale,
            y: -rotatedFocus.y * nextScale
        )

        reviewFreeRotationRadians = normalizedRadians
        reviewOffset = CGSize(width: translation.x, height: -translation.y)
        lastReviewOffset = reviewOffset
    }

    private func reviewFocusVector(
        rotation: CGFloat,
        scale: CGFloat,
        offset: CGSize
    ) -> CGPoint {
        let safeScale = max(scale, 0.1)
        let translation = CGPoint(x: offset.width, y: -offset.height)
        let unrotatedTranslation = CGPoint(
            x: -translation.x / safeScale,
            y: -translation.y / safeScale
        )
        return Self.rotated(unrotatedTranslation, by: -rotation)
    }

    private func effectiveReviewScale(for radians: CGFloat) -> CGFloat {
        let coverScale = abs(cos(radians)) + abs(sin(radians))
        return max(reviewScale, coverScale, 0.1)
    }

    private static func rotated(_ point: CGPoint, by radians: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x * cos(radians) - point.y * sin(radians),
            y: point.x * sin(radians) + point.y * cos(radians)
        )
    }

    private static func normalizedReviewRotation(_ radians: CGFloat) -> CGFloat {
        let fullTurn = CGFloat.pi * 2
        var value = radians.truncatingRemainder(dividingBy: fullTurn)
        if value > CGFloat.pi {
            value -= fullTurn
        } else if value < -CGFloat.pi {
            value += fullTurn
        }
        return value
    }

    private func clampedReviewOffset(_ offset: CGSize) -> CGSize {
        offset
    }

    private func handleCapturePressBegan() {
        guard !isCapturePressActive else { return }
        guard timedCaptureCountdownStart == nil else { return }
        isCapturePressActive = true
        didStartVideoDuringPress = false

        guard !camera.isRecordingVideo, camera.previewImage != nil, !saver.isSaving else {
            return
        }

        let workItem = DispatchWorkItem {
            didStartVideoDuringPress = true
            camera.startVideoRecording()
        }
        captureHoldWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func handleCapturePressEnded() {
        captureHoldWorkItem?.cancel()
        captureHoldWorkItem = nil
        isCapturePressActive = false

        if camera.isRecordingVideo {
            if didStartVideoDuringPress {
                didStartVideoDuringPress = false
            } else {
                stopVideoCapture()
            }
            return
        }

        guard !didStartVideoDuringPress else {
            didStartVideoDuringPress = false
            return
        }
        capturePhoto()
    }

    private func capturePhoto() {
        guard timedCaptureCountdownStart == nil else { return }
        guard let image = camera.captureImage(), !saver.isSaving else { return }
        beginReview(.photo(image))
    }

    private func startTimedVideoCountdown() {
        guard reviewCapture == nil,
              timedCaptureCountdownStart == nil,
              camera.previewImage != nil,
              !camera.isRecordingVideo,
              !saver.isSaving,
              !isImportingPhoto else {
            return
        }

        captureHoldWorkItem?.cancel()
        captureHoldWorkItem = nil
        isCapturePressActive = false
        didStartVideoDuringPress = false
        timedVideoDuration = Self.clampedTimedVideoDuration(timedVideoDuration)

        withAnimation(.snappy(duration: 0.18)) {
            timedCaptureCountdownStart = Date()
        }

        timedCaptureCountdownTask?.cancel()
        timedCaptureCountdownTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.timedCaptureCountdownDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            startTimedVideoCapture()
        }
    }

    private func setForwardTemporalCaptureEnabled(_ isEnabled: Bool) {
        if !isEnabled && !isTimedVideoBackwardEnabled {
            return
        }
        isTimedVideoForwardEnabled = isEnabled
    }

    private func setBackwardTemporalCaptureEnabled(_ isEnabled: Bool) {
        if !isEnabled && !isTimedVideoForwardEnabled {
            return
        }
        isTimedVideoBackwardEnabled = isEnabled
    }

    private func ensureTemporalCaptureSelection() {
        if !isTimedVideoForwardEnabled && !isTimedVideoBackwardEnabled {
            isTimedVideoForwardEnabled = true
            isTimedVideoBackwardEnabled = true
        }
    }

    private func startTimedVideoCapture() {
        withAnimation(.easeOut(duration: 0.16)) {
            timedCaptureCountdownStart = nil
        }
        timedCaptureCountdownTask = nil

        guard reviewCapture == nil,
              camera.previewImage != nil,
              !camera.isRecordingVideo,
              !saver.isSaving else {
            return
        }

        camera.startVideoRecording()
        let duration = Self.clampedTimedVideoDuration(timedVideoDuration)
        timedCaptureStopTask?.cancel()
        timedCaptureStopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
            guard !Task.isCancelled, camera.isRecordingVideo else { return }
            stopVideoCapture(cancelTimedTask: false)
        }
    }

    private func cancelTimedCapture() {
        timedCaptureCountdownTask?.cancel()
        timedCaptureCountdownTask = nil
        timedCaptureStopTask?.cancel()
        timedCaptureStopTask = nil
        withAnimation(.easeOut(duration: 0.16)) {
            timedCaptureCountdownStart = nil
        }
    }

    @MainActor
    private func importPhoto(from item: PhotosPickerItem) async {
        guard reviewCapture == nil else {
            importPhotoItem = nil
            return
        }

        isImportingPhoto = true
        defer {
            isImportingPhoto = false
            importPhotoItem = nil
        }

        do {
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
            else {
                saver.showFailure("The selected image could not be loaded.")
                return
            }

            beginReview(.photo(Self.centerSquareCropped(image)))
        } catch {
            saver.showFailure(error.localizedDescription)
        }
    }

    private static func centerSquareCropped(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return image }

        let targetSize = CGSize(width: side, height: side)
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = image.scale
        rendererFormat.opaque = false

        return UIGraphicsImageRenderer(size: targetSize, format: rendererFormat).image { _ in
            let scale = max(targetSize.width / image.size.width, targetSize.height / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let drawRect = CGRect(
                x: (targetSize.width - drawSize.width) / 2,
                y: (targetSize.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            image.draw(in: drawRect)
        }
    }

    private func stopVideoCapture(cancelTimedTask: Bool = true) {
        if cancelTimedTask {
            timedCaptureStopTask?.cancel()
        }
        timedCaptureStopTask = nil
        camera.stopVideoRecording { result in
            switch result {
            case .success(let url):
                let thumbnail = MirrorVideoPostProcessor.thumbnail(from: url)
                    ?? camera.captureImage()
                    ?? UIImage()
                beginReview(.video(url, thumbnail: thumbnail))
            case .failure(let error):
                saver.showFailure(error.localizedDescription)
            }
        }
    }

    private func beginReview(_ capture: MirrorCameraReviewCapture) {
        cancelTimedCapture()
        reviewCapture = capture
        reviewCaptureID = UUID()
        reviewPreviewImage = nil
        isDoubleOutputEnabled = false
        resetReviewTransform()
        updateReviewPreview()
    }

    private func discardReviewCapture() {
        if case .video(let url, _) = reviewCapture {
            try? FileManager.default.removeItem(at: url)
        }
        reviewCapture = nil
        reviewCaptureID = UUID()
        reviewPreviewImage = nil
        sonificationSession = nil
        isDoubleOutputEnabled = false
        resetReviewTransform()
        isProcessingReview = false
        camera.setMirror(
            mode: mode,
            reflectionSelection: reflectionSelection
        )
    }

    private func resetReviewTransform() {
        reviewFreeRotationRadians = 0
        reviewScale = 1
        lastReviewScale = 1
        reviewOffset = .zero
        lastReviewOffset = .zero
    }

    private func saveReviewCapture() {
        guard let reviewCapture, !isProcessingReview else { return }
        isProcessingReview = true

        switch reviewCapture {
        case .photo(let image):
            let imageId = UUID().uuidString
            guard let renderedImage = MirrorOutputComposer.renderPhoto(
                source: image,
                configuration: outputConfiguration
            ) else {
                saver.showFailure("The edited photo could not be rendered.")
                isProcessingReview = false
                return
            }

            if let onCapturedMedia {
                guard let data = renderedImage.jpegData(compressionQuality: 0.94) else {
                    saver.showFailure("The edited photo could not be encoded.")
                    isProcessingReview = false
                    return
                }
                onCapturedMedia(MirrorCameraCapturedMedia(
                    type: .symbolicPhoto,
                    data: data,
                    sourceURL: nil,
                    fileExtension: "jpg"
                ))
                logAnimacyCapture(imageId: imageId, userAccepted: true)
                saver.showStatus("Saved version")
                isProcessingReview = false
            } else {
                saver.save(renderedImage)
                logAnimacyCapture(imageId: imageId, userAccepted: true)
                isProcessingReview = false
            }

        case .video(let url, _):
            let configuration = outputConfiguration
            saver.showStatus("Processing video")
            Task {
                do {
                    let processedURL = try await MirrorVideoPostProcessor.process(
                        inputURL: url,
                        configuration: configuration
                    )

                    if let onCapturedMedia {
                        onCapturedMedia(MirrorCameraCapturedMedia(
                            type: .video,
                            data: nil,
                            sourceURL: processedURL,
                            fileExtension: processedURL.pathExtension.isEmpty ? "mov" : processedURL.pathExtension
                        ))
                        saver.showStatus("Saved version")
                        isProcessingReview = false
                    } else {
                        saver.saveVideo(at: processedURL)
                        isProcessingReview = false
                    }
                } catch {
                    saver.showFailure(error.localizedDescription)
                    isProcessingReview = false
                }
            }
        }
    }

    @MainActor
    private func updateReviewPreview() {
        guard let reviewCapture else {
            reviewPreviewImage = nil
            return
        }
        reviewPreviewImage = MirrorOutputComposer.renderPreview(
            source: reviewCapture.sourceImage,
            configuration: outputConfiguration
        )
    }

    private func openSonificationPanel() {
        guard let reviewCapture, !reviewCapture.isVideo else { return }

        let renderedImage = MirrorOutputComposer.renderPhoto(
            source: reviewCapture.sourceImage,
            configuration: outputConfiguration
        ) ?? reviewPreviewImage ?? reviewCapture.sourceImage
        sonificationSession = ImageSonificationSession(image: renderedImage)
    }

    private func logAnimacyCapture(imageId: String, userAccepted: Bool) {
        let log = AnimacyCaptureLog(
            imageId: imageId,
            timestamp: Date(),
            animacyScore: 0,
            userAccepted: userAccepted,
            mirrorAngle: mode.primaryMirrorAngle,
            mirrorOffset: reflectionSelection.reflectedSide == nil ? nil : 0
        )
        try? AnimacyCaptureLogger.append(log)
    }

    private func cameraToolButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.38), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private static func previewSide(for size: CGSize) -> CGFloat {
        let horizontalSide = max(size.width - 28, 180)
        let verticalSide = max(size.height - 330, 180)
        return min(horizontalSide, verticalSide)
    }
}

private struct AnimacyDatasetTrackerView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""

    let sourceImage: UIImage

    @State private var captureID = UUID()
    @State private var mode: ThreadMirrorCameraMode
    @State private var reflectionSelection: MirrorReflectionSelection
    @State private var reviewFreeRotationRadians: CGFloat
    @State private var reviewScale: CGFloat
    @State private var lastReviewScale: CGFloat
    @State private var reviewOffset: CGSize
    @State private var lastReviewOffset: CGSize
    @State private var isBinaryFilterEnabled: Bool
    @State private var thresholdLevel: Double
    @State private var selectedRarity: AnimacyDatasetRarity = .rare
    @State private var previewImage: UIImage?
    @State private var samples: [AnimacyDatasetTransformationDraft] = []
    @State private var statusMessage = ""
    @State private var isSubmitting = false

    init(
        sourceImage: UIImage,
        initialConfiguration: MirrorOutputConfiguration
    ) {
        self.sourceImage = sourceImage
        _mode = State(initialValue: initialConfiguration.mode)
        _reflectionSelection = State(initialValue: initialConfiguration.reflectionSelection)
        _reviewFreeRotationRadians = State(initialValue: initialConfiguration.imageTransform.freeRotationRadians)
        _reviewScale = State(initialValue: initialConfiguration.imageTransform.scale)
        _lastReviewScale = State(initialValue: initialConfiguration.imageTransform.scale)
        _reviewOffset = State(initialValue: initialConfiguration.imageTransform.offset)
        _lastReviewOffset = State(initialValue: initialConfiguration.imageTransform.offset)
        _isBinaryFilterEnabled = State(initialValue: initialConfiguration.isBinaryFilterEnabled)
        _thresholdLevel = State(initialValue: initialConfiguration.thresholdLevel)
    }

    private var currentConfiguration: MirrorOutputConfiguration {
        MirrorOutputConfiguration(
            mode: mode,
            reflectionSelection: reflectionSelection,
            imageTransform: MirrorImageTransform(
                freeRotationRadians: reviewFreeRotationRadians,
                scale: reviewScale,
                offset: reviewOffset
            ),
            isBinaryFilterEnabled: isBinaryFilterEnabled,
            thresholdLevel: thresholdLevel,
            isDoubleOutputEnabled: false,
            temporalMode: .forwardBackward
        )
    }

    private var previewKey: String {
        [
            captureID.uuidString,
            mode.id,
            "\(reflectionSelection)",
            "\(reviewFreeRotationRadians)",
            "\(reviewScale)",
            "\(reviewOffset.width)",
            "\(reviewOffset.height)",
            isBinaryFilterEnabled ? "binary" : "color",
            "\(thresholdLevel)"
        ].joined(separator: "|")
    }

    private var trackerRotationDegrees: Binding<Double> {
        Binding {
            Double(reviewFreeRotationRadians) * 180 / Double.pi
        } set: { newValue in
            setRotationRadians(CGFloat(newValue * Double.pi / 180))
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                preview

                rarityControls
                mirrorControls
                sampleControls

                if !samples.isEmpty {
                    samplePreviewList
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Track Entity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text("Submit")
                    }
                }
                .disabled(samples.isEmpty || isSubmitting)
            }
        }
        .task(id: previewKey) {
            updatePreview()
        }
    }

    private var preview: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.07))

                Image(uiImage: previewImage ?? sourceImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .gesture(panGesture(side: side))
            .simultaneousGesture(zoomGesture())
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var rarityControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Rarity", systemImage: "diamond")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                ForEach(AnimacyDatasetRarity.allCases) { rarity in
                    Button {
                        selectedRarity = rarity
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: selectedRarity == rarity ? "largecircle.fill.circle" : "circle")
                                .font(.subheadline.weight(.semibold))
                            Text(rarity.title)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .foregroundStyle(selectedRarity == rarity ? rarity.tintColor : .white.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background((selectedRarity == rarity ? rarity.tintColor : .white).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke((selectedRarity == rarity ? rarity.tintColor : .white).opacity(0.2), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var mirrorControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                trackerButton(systemImage: "rotate.left") {
                    rotate(byDegrees: -45)
                }
                trackerButton(systemImage: mode.symbolName) {
                    mode = mode.next
                }
                trackerButton(systemImage: reflectionSelection.symbolName) {
                    reflectionSelection = reflectionSelection.next
                }
                trackerButton(systemImage: "arrow.counterclockwise") {
                    resetTransform()
                }
                trackerButton(systemImage: isBinaryFilterEnabled ? "circle.lefthalf.filled" : "circle.lefthalf.filled.inverse") {
                    isBinaryFilterEnabled.toggle()
                }
                trackerButton(systemImage: "rotate.right") {
                    rotate(byDegrees: 45)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "rotate.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
                Slider(value: trackerRotationDegrees, in: -180...180, step: 1)
                    .tint(.cyan)
            }

            if isBinaryFilterEnabled {
                Slider(value: $thresholdLevel, in: 0...1)
                    .tint(.cyan)
            }
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var sampleControls: some View {
        Button {
            addCurrentTransformation()
        } label: {
            Label("Add transformation", systemImage: "plus.circle")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(.white, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var samplePreviewList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview Set")
                .font(.headline)
                .foregroundStyle(.white)

            ForEach(samples) { sample in
                HStack(spacing: 12) {
                    if let previewImage = sample.previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(sample.rarity.title)
                            .font(.system(.headline, design: .rounded))
                            .foregroundStyle(sample.rarity.tintColor)
                        Text("rotation \(Int((Double(sample.configuration.imageTransform.freeRotationRadians) * 180 / Double.pi).rounded()))")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(2)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        samples.removeAll { $0.id == sample.id }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.white.opacity(0.86))
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func trackerButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.38), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func panGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard side > 0 else { return }
                reviewOffset = CGSize(
                    width: lastReviewOffset.width + value.translation.width / side,
                    height: lastReviewOffset.height + value.translation.height / side
                )
            }
            .onEnded { _ in
                lastReviewOffset = reviewOffset
            }
    }

    private func zoomGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                reviewScale = min(max(lastReviewScale * value, 1), 4)
            }
            .onEnded { _ in
                lastReviewScale = reviewScale
            }
    }

    private func rotate(byDegrees degrees: Double) {
        setRotationRadians(reviewFreeRotationRadians + CGFloat(degrees * Double.pi / 180))
    }

    private func setRotationRadians(_ radians: CGFloat) {
        let normalized = Self.normalizedRotation(radians)
        let focus = reviewFocusVector(
            rotation: reviewFreeRotationRadians,
            scale: effectiveReviewScale(for: reviewFreeRotationRadians),
            offset: reviewOffset
        )
        let nextScale = effectiveReviewScale(for: normalized)
        let rotatedFocus = Self.rotated(focus, by: normalized)
        let translation = CGPoint(
            x: -rotatedFocus.x * nextScale,
            y: -rotatedFocus.y * nextScale
        )
        reviewFreeRotationRadians = normalized
        reviewOffset = CGSize(width: translation.x, height: -translation.y)
        lastReviewOffset = reviewOffset
    }

    private func resetTransform() {
        reviewFreeRotationRadians = 0
        reviewScale = 1
        lastReviewScale = 1
        reviewOffset = .zero
        lastReviewOffset = .zero
    }

    private func reviewFocusVector(
        rotation: CGFloat,
        scale: CGFloat,
        offset: CGSize
    ) -> CGPoint {
        let safeScale = max(scale, 0.1)
        let translation = CGPoint(x: offset.width, y: -offset.height)
        let unrotatedTranslation = CGPoint(
            x: -translation.x / safeScale,
            y: -translation.y / safeScale
        )
        return Self.rotated(unrotatedTranslation, by: -rotation)
    }

    private func effectiveReviewScale(for radians: CGFloat) -> CGFloat {
        let coverScale = abs(cos(radians)) + abs(sin(radians))
        return max(reviewScale, coverScale, 0.1)
    }

    private static func rotated(_ point: CGPoint, by radians: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x * cos(radians) - point.y * sin(radians),
            y: point.x * sin(radians) + point.y * cos(radians)
        )
    }

    private static func normalizedRotation(_ radians: CGFloat) -> CGFloat {
        let fullTurn = CGFloat.pi * 2
        var value = radians.truncatingRemainder(dividingBy: fullTurn)
        if value > CGFloat.pi {
            value -= fullTurn
        } else if value < -CGFloat.pi {
            value += fullTurn
        }
        return value
    }

    @MainActor
    private func updatePreview() {
        previewImage = MirrorOutputComposer.renderPreview(
            source: sourceImage,
            configuration: currentConfiguration
        )
    }

    private func addCurrentTransformation() {
        let configuration = currentConfiguration
        let preview = MirrorOutputComposer.renderDatasetImage(
            source: sourceImage,
            configuration: configuration
        )
        let draft = AnimacyDatasetTransformationDraft(
            id: UUID(),
            createdAt: Date(),
            configuration: configuration,
            rarity: selectedRarity,
            previewImage: preview
        )
        samples.append(draft)
        statusMessage = "Added \(samples.count) transformation\(samples.count == 1 ? "" : "s")."
    }

    @MainActor
    private func submit() async {
        guard !samples.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let payload = try makePayload()
            try services.animacyDatasetQueue.enqueue(payload)
            statusMessage = "Queued locally with \(samples.count) samples."

            if syncServerURL.nilIfBlank != nil {
                let upload = try await services.animacyDatasetQueue.uploadPending(to: syncServerURL)
                if upload.failedCount > 0 {
                    statusMessage = "Queued locally. Upload failed for \(upload.failedCount): \(upload.lastError ?? "server unavailable")"
                } else if upload.uploadedCount > 0 {
                    statusMessage = "Uploaded \(upload.uploadedCount) queued capture\(upload.uploadedCount == 1 ? "" : "s")."
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func makePayload() throws -> AnimacyDatasetUploadPayload {
        guard let originalData = sourceImage.jpegData(compressionQuality: 0.94) else {
            throw AnimacyDatasetTrackerError.couldNotEncodeOriginal
        }

        return AnimacyDatasetUploadPayload(
            schemaVersion: 1,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            createdAt: Date(),
            capture: AnimacyDatasetCapturePayload(
                id: captureID,
                source: "camera",
                originalWidth: sourceImage.cgImage?.width ?? Int(sourceImage.size.width * sourceImage.scale),
                originalHeight: sourceImage.cgImage?.height ?? Int(sourceImage.size.height * sourceImage.scale),
                transformations: try samples.map(transformationPayload)
            ),
            originalImage: AnimacyDatasetImageBlob(
                fileName: "\(captureID.uuidString)-original.jpg",
                contentType: "image/jpeg",
                dataBase64: originalData.base64EncodedString()
            )
        )
    }

    private func transformationPayload(
        from sample: AnimacyDatasetTransformationDraft
    ) throws -> AnimacyDatasetTransformationPayload {
        guard
            let datasetImage = MirrorOutputComposer.renderDatasetImage(
                source: sourceImage,
                configuration: sample.configuration
            ),
            let datasetData = datasetImage.jpegData(compressionQuality: 0.92)
        else {
            throw AnimacyDatasetTrackerError.couldNotRenderSample
        }

        return AnimacyDatasetTransformationPayload(
            id: sample.id,
            createdAt: sample.createdAt,
            rarity: sample.rarity,
            mirrorMode: sample.configuration.mode.id,
            reflectedSide: sample.configuration.reflectionSelection.reflectedSide?.rawValue,
            mirrorEdges: sample.configuration.mode
                .edges(reflectionSelection: sample.configuration.reflectionSelection)
                .map(AnimacyDatasetMirrorEdgePayload.init(edge:)),
            imageTransform: AnimacyDatasetImageTransformPayload(transform: sample.configuration.imageTransform),
            isBinaryFilterEnabled: sample.configuration.isBinaryFilterEnabled,
            thresholdLevel: sample.configuration.thresholdLevel,
            isDoubleOutputEnabled: sample.configuration.isDoubleOutputEnabled,
            datasetImage: AnimacyDatasetImageBlob(
                fileName: "\(sample.id.uuidString).jpg",
                contentType: "image/jpeg",
                dataBase64: datasetData.base64EncodedString()
            )
        )
    }
}

private struct AnimacyDatasetTransformationDraft: Identifiable {
    let id: UUID
    let createdAt: Date
    let configuration: MirrorOutputConfiguration
    let rarity: AnimacyDatasetRarity
    let previewImage: UIImage?
}

private enum AnimacyDatasetTrackerError: LocalizedError {
    case couldNotEncodeOriginal
    case couldNotRenderSample

    var errorDescription: String? {
        switch self {
        case .couldNotEncodeOriginal:
            "The original capture could not be encoded."
        case .couldNotRenderSample:
            "One of the reflected samples could not be rendered."
        }
    }
}

private extension AnimacyDatasetMirrorEdgePayload {
    init(edge: MirrorEdge) {
        self.init(
            normalizedX: Double(edge.normalizedPoint.x),
            normalizedY: Double(edge.normalizedPoint.y),
            angleRadians: Double(edge.angleRadians),
            reflectedSide: edge.reflectedSide.rawValue
        )
    }
}

private extension AnimacyDatasetImageTransformPayload {
    init(transform: MirrorImageTransform) {
        self.init(
            rotationRadians: Double(transform.freeRotationRadians),
            scale: Double(transform.scale),
            offsetX: Double(transform.offset.width),
            offsetY: Double(transform.offset.height)
        )
    }
}

private extension AnimacyDatasetRarity {
    var tintColor: Color {
        switch self {
        case .common:
            .gray
        case .rare:
            .cyan
        case .epic:
            .purple
        case .legendary:
            .yellow
        case .mythic:
            .red
        }
    }
}

private struct TimedVideoCountdownView: View {
    let startDate: Date
    let duration: TimeInterval

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = min(max(context.date.timeIntervalSince(startDate), 0), max(duration, 0.1))
            let progress = elapsed / max(duration, 0.1)
            let remaining = max(1, Int(ceil(duration - elapsed)))

            ZStack {
                Circle()
                    .fill(.black.opacity(0.52))
                    .frame(width: 132, height: 132)

                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: 8)
                    .frame(width: 104, height: 104)

                Circle()
                    .trim(from: 0, to: max(0.001, 1 - progress))
                    .stroke(
                        .cyan,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 104, height: 104)
                    .rotationEffect(.degrees(-90))

                Text("\(remaining)")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            .shadow(color: .black.opacity(0.32), radius: 12, y: 6)
        }
        .accessibilityLabel("Timed recording countdown")
    }
}

private struct RadialTickSlider: View {
    @Binding var value: Double

    let systemImage: String
    let tint: Color
    let orientation: RadialTickSliderOrientation
    let accessibilityLabel: String

    var body: some View {
        GeometryReader { proxy in
            let radius = orientation.radius(in: proxy.size)
            let center = orientation.center(in: proxy.size)

            ZStack {
                Canvas { context, _ in
                    let tickCount = 37
                    for tick in 0..<tickCount {
                        let progress = Double(tick) / Double(tickCount - 1)
                        let angle = orientation.angle(for: progress)
                        let isMajor = tick % 6 == 0
                        let tickLength = isMajor ? 12.0 : 7.0
                        let start = Self.point(center: center, radius: radius - tickLength, angle: angle)
                        let end = Self.point(center: center, radius: radius, angle: angle)
                        var path = Path()
                        path.move(to: start)
                        path.addLine(to: end)
                        let opacity = progress <= value ? 0.92 : 0.34
                        context.stroke(
                            path,
                            with: .color((progress <= value ? tint : .white).opacity(opacity)),
                            lineWidth: isMajor ? 1.5 : 0.9
                        )
                    }

                    let markerAngle = orientation.angle(for: value)
                    var markerPath = Path()
                    markerPath.move(to: Self.point(center: center, radius: radius - 18, angle: markerAngle))
                    markerPath.addLine(to: Self.point(center: center, radius: radius + 2, angle: markerAngle))
                    context.stroke(
                        markerPath,
                        with: .color(tint),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                    )
                }

                VStack(spacing: 4) {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text("\(Int((value * 100).rounded()))")
                        .font(.system(size: 23, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                .position(orientation.labelPosition(in: proxy.size))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        value = orientation.value(for: gesture.location, center: center)
                    }
            )
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(Int(value * 100)) percent")
    }

    private static func point(center: CGPoint, radius: CGFloat, angle: Angle) -> CGPoint {
        CGPoint(
            x: center.x + cos(angle.radians) * radius,
            y: center.y + sin(angle.radians) * radius
        )
    }
}

private enum RadialTickSliderOrientation {
    case inwardFromLeft
    case inwardFromRight

    func center(in size: CGSize) -> CGPoint {
        switch self {
        case .inwardFromLeft:
            CGPoint(x: size.width * 0.12, y: size.height * 0.5)
        case .inwardFromRight:
            CGPoint(x: size.width * 0.88, y: size.height * 0.5)
        }
    }

    func labelPosition(in size: CGSize) -> CGPoint {
        switch self {
        case .inwardFromLeft:
            CGPoint(x: size.width * 0.62, y: size.height * 0.5)
        case .inwardFromRight:
            CGPoint(x: size.width * 0.38, y: size.height * 0.5)
        }
    }

    func radius(in size: CGSize) -> CGFloat {
        min(size.width * 0.66, size.height * 0.46)
    }

    func angle(for value: Double) -> Angle {
        .degrees(startDegrees + value * (endDegrees - startDegrees))
    }

    func value(for location: CGPoint, center: CGPoint) -> Double {
        let radians = atan2(location.y - center.y, location.x - center.x)
        let rawDegrees = (radians * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let degrees = wrapsAroundZero && rawDegrees < startDegrees.truncatingRemainder(dividingBy: 360)
            ? rawDegrees + 360
            : rawDegrees
        let clamped = min(max(degrees, startDegrees), endDegrees)
        return min(max((clamped - startDegrees) / (endDegrees - startDegrees), 0), 1)
    }

    private var startDegrees: Double {
        switch self {
        case .inwardFromLeft:
            295
        case .inwardFromRight:
            115
        }
    }

    private var endDegrees: Double {
        switch self {
        case .inwardFromLeft:
            425
        case .inwardFromRight:
            245
        }
    }

    private var wrapsAroundZero: Bool {
        endDegrees > 360
    }
}

private enum ThreadMirrorCameraMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case horizontal
    case vertical
    case cross

    var id: String { rawValue }

    var next: ThreadMirrorCameraMode {
        switch self {
        case .horizontal: .vertical
        case .vertical: .cross
        case .cross: .horizontal
        }
    }

    var symbolName: String {
        switch self {
        case .horizontal: "arrow.up.and.down"
        case .vertical: "arrow.left.and.right"
        case .cross: "plus"
        }
    }

    var primaryMirrorAngle: Float? {
        switch self {
        case .horizontal:
            0
        case .vertical:
            Float.pi / 2
        case .cross:
            nil
        }
    }

    func edges(reflectionSelection: MirrorReflectionSelection) -> [MirrorEdge] {
        guard let reflectedSide = reflectionSelection.reflectedSide else {
            return []
        }

        return switch self {
        case .horizontal:
            [
                MirrorEdge(
                    normalizedPoint: CGPoint(x: 0.5, y: 0.5),
                    angleRadians: 0,
                    reflectedSide: reflectedSide
                )
            ]
        case .vertical:
            [
                MirrorEdge(
                    normalizedPoint: CGPoint(x: 0.5, y: 0.5),
                    angleRadians: .pi / 2,
                    reflectedSide: reflectedSide
                )
            ]
        case .cross:
            [
                MirrorEdge(
                    normalizedPoint: CGPoint(x: 0.5, y: 0.5),
                    angleRadians: .pi / 2,
                    reflectedSide: reflectedSide
                ),
                MirrorEdge(
                    normalizedPoint: CGPoint(x: 0.5, y: 0.5),
                    angleRadians: 0,
                    reflectedSide: reflectedSide
                )
            ]
        }
    }
}

private enum MirrorReflectionSelection: String, CaseIterable, Hashable, Sendable {
    case positive
    case negative
    case off

    var next: MirrorReflectionSelection {
        switch self {
        case .positive:
            .negative
        case .negative:
            .off
        case .off:
            .positive
        }
    }

    var reflectedSide: MirrorReflectionSide? {
        switch self {
        case .positive:
            .positive
        case .negative:
            .negative
        case .off:
            nil
        }
    }

    var symbolName: String {
        switch self {
        case .positive:
            "arrow.right"
        case .negative:
            "arrow.left"
        case .off:
            "slash.circle"
        }
    }
}

private enum MirrorCameraBackLens: String, CaseIterable {
    case ultraWide
    case wide
    case telephoto

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: .builtInUltraWideCamera
        case .wide: .builtInWideAngleCamera
        case .telephoto: .builtInTelephotoCamera
        }
    }

    var symbolName: String {
        switch self {
        case .ultraWide: "arrow.down.left.and.arrow.up.right"
        case .wide: "circle"
        case .telephoto: "plus.magnifyingglass"
        }
    }

    static var available: [MirrorCameraBackLens] {
        let lenses = allCases.filter { lens in
            AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) != nil
        }
        return lenses.isEmpty ? [.wide] : lenses
    }
}

private struct ThreadCameraPlaceholderView: View {
    let state: CameraAuthorizationState
    let errorMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
        }
    }

    private var message: String {
        if let errorMessage {
            return errorMessage
        }

        switch state {
        case .notDetermined:
            return "Preparing camera"
        case .authorized:
            return "Opening camera"
        case .denied:
            return "Camera access is disabled"
        case .unavailable:
            return "Camera unavailable"
        }
    }
}

private final class ThreadMirrorCameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var animacyResult: AnimacyResult?
    @Published private(set) var authorizationState: CameraAuthorizationState = .notDetermined
    @Published private(set) var errorMessage: String?
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
    @Published private(set) var backLens: MirrorCameraBackLens = .wide
    @Published private(set) var isRecordingVideo = false

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "exeligmos.thread-mirror-camera.session")
    private let videoQueue = DispatchQueue(label: "exeligmos.thread-mirror-camera.video")
    private let animacyScorer: any AnimacyScoring

    private var output: AVCaptureVideoDataOutput?
    private var audioInput: AVCaptureDeviceInput?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var latestFrame: CIImage?
    private var latestOriginalImage: UIImage?
    private var currentDevice: AVCaptureDevice?
    private var selectedBackLens: MirrorCameraBackLens = .wide
    private var currentMode: ThreadMirrorCameraMode = .vertical
    private var currentReflectionSelection: MirrorReflectionSelection = .positive
    private var lensPosition: Double = 0.5
    private var exposureLevel: Double = 0.5
    private var isFocusManual = false
    private var isExposureManual = false
    private var isBinaryFilterEnabled = false
    private var thresholdLevel: Double = 0.5
    private var lastFrameTime: CFTimeInterval = 0
    private var lastAnimacyFrameTime: CFTimeInterval = 0
    private var isAnimacyScoreInFlight = false
    private let isAnimacyScoringEnabled = false
    private var videoRecorder: MirrorVideoRecorder?
    private var videoRecordingURL: URL?
    private var videoRecordingCompletion: ((Result<URL, Error>) -> Void)?
    private var isAudioCaptureAuthorized = false

    init(animacyScorer: any AnimacyScoring = AnimacyScorer()) {
        self.animacyScorer = animacyScorer
        super.init()
    }

    @MainActor
    func configurePreferredCamera(position: AVCaptureDevice.Position, backLens: MirrorCameraBackLens) {
        let availableLenses = MirrorCameraBackLens.available
        let resolvedBackLens = availableLenses.contains(backLens) ? backLens : (availableLenses.first ?? .wide)
        cameraPosition = position
        self.backLens = resolvedBackLens
        selectedBackLens = resolvedBackLens
    }

    func start() async {
        guard await requestAccessIfNeeded() else { return }
        let isAudioCaptureAuthorized = await requestAudioAccessIfNeeded()

        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                self.isAudioCaptureAuthorized = isAudioCaptureAuthorized
                try self.configureCamera(position: self.cameraPosition)
                guard !self.session.isRunning else { return }
                self.session.startRunning()
            } catch {
                Task { @MainActor in
                    self.authorizationState = .unavailable
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func switchCamera() {
        let nextPosition: AVCaptureDevice.Position = cameraPosition == .front ? .back : .front
        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.configureCamera(position: nextPosition)
                Task { @MainActor in
                    self.cameraPosition = nextPosition
                    self.previewImage = nil
                    self.animacyResult = nil
                }
            } catch {
                Task { @MainActor in
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cycleBackLens() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            let available = MirrorCameraBackLens.available
            let currentIndex = available.firstIndex(of: self.selectedBackLens) ?? 0
            let nextLens = available[(currentIndex + 1) % available.count]

            do {
                self.selectedBackLens = nextLens
                try self.configureCamera(position: .back)
                Task { @MainActor in
                    self.cameraPosition = .back
                    self.backLens = nextLens
                    self.previewImage = nil
                    self.animacyResult = nil
                }
            } catch {
                Task { @MainActor in
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func setMirror(
        mode: ThreadMirrorCameraMode,
        reflectionSelection: MirrorReflectionSelection
    ) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.currentMode = mode
            self.currentReflectionSelection = reflectionSelection
            self.renderLatestFrame(force: true)
        }
    }

    func setLensPosition(_ value: Double) {
        let clampedValue = min(max(value, 0), 1)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lensPosition = clampedValue
            self.isFocusManual = true
            if let currentDevice = self.currentDevice {
                self.applyLensPosition(to: currentDevice)
            }
        }
    }

    func setExposureLevel(_ value: Double) {
        let clampedValue = min(max(value, 0), 1)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.exposureLevel = clampedValue
            self.isExposureManual = true
            if let currentDevice = self.currentDevice {
                self.applyExposure(to: currentDevice)
            }
        }
    }

    func focusAndExpose(at normalizedPoint: CGPoint) {
        let point = CGPoint(
            x: min(max(normalizedPoint.x, 0), 1),
            y: min(max(normalizedPoint.y, 0), 1)
        )

        sessionQueue.async { [weak self] in
            guard let self, let currentDevice = self.currentDevice else { return }

            do {
                try currentDevice.lockForConfiguration()

                if currentDevice.isFocusPointOfInterestSupported {
                    currentDevice.focusPointOfInterest = point
                }
                if currentDevice.isFocusModeSupported(.autoFocus) {
                    currentDevice.focusMode = .autoFocus
                } else if currentDevice.isFocusModeSupported(.continuousAutoFocus) {
                    currentDevice.focusMode = .continuousAutoFocus
                }

                if currentDevice.isExposurePointOfInterestSupported {
                    currentDevice.exposurePointOfInterest = point
                }
                if currentDevice.isExposureModeSupported(.continuousAutoExposure) {
                    currentDevice.exposureMode = .continuousAutoExposure
                } else if currentDevice.isExposureModeSupported(.autoExpose) {
                    currentDevice.exposureMode = .autoExpose
                }

                self.isFocusManual = false
                self.isExposureManual = false
                currentDevice.unlockForConfiguration()
            } catch {
                Task { @MainActor in
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func setFilter(isBinaryEnabled: Bool, threshold: Double) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.isBinaryFilterEnabled = isBinaryEnabled
            self.thresholdLevel = min(max(threshold, 0), 1)
            self.renderLatestFrame(force: true)
        }
    }

    @MainActor
    func captureImage() -> UIImage? {
        latestOriginalImage
    }

    @MainActor
    func startVideoRecording() {
        guard !isRecordingVideo else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? AVAudioSession.sharedInstance().setActive(true)
        isRecordingVideo = true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.videoRecordingURL = url
            guard let movieOutput = self.movieOutput else {
                Task { @MainActor in
                    self.isRecordingVideo = false
                    self.errorMessage = ThreadMirrorCameraError.cameraUnavailable.localizedDescription
                }
                return
            }
            self.configureAudioCaptureForRecordingIfNeeded()
            movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    @MainActor
    func stopVideoRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard isRecordingVideo else {
            completion(.failure(MirrorVideoRecorder.RecorderError.notRecording))
            return
        }

        isRecordingVideo = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let movieOutput = self.movieOutput, movieOutput.isRecording else {
                Task { @MainActor in
                    completion(.failure(MirrorVideoRecorder.RecorderError.notRecording))
                }
                return
            }

            self.videoRecordingCompletion = completion
            movieOutput.stopRecording()
        }
    }

    private func requestAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await MainActor.run {
                authorizationState = .authorized
            }
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            await MainActor.run {
                authorizationState = granted ? .authorized : .denied
            }
            return granted
        case .denied, .restricted:
            await MainActor.run {
                authorizationState = .denied
            }
            return false
        @unknown default:
            await MainActor.run {
                authorizationState = .unavailable
            }
            return false
        }
    }

    private func requestAudioAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    private func configureCamera(position: AVCaptureDevice.Position) throws {
        session.beginConfiguration()
        session.sessionPreset = .high
        defer {
            session.commitConfiguration()
        }

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        audioInput = nil
        movieOutput = nil

        let device = captureDevice(for: position)
        guard let device else {
            throw ThreadMirrorCameraError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw ThreadMirrorCameraError.cameraUnavailable
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(output) else {
            throw ThreadMirrorCameraError.cameraUnavailable
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            configure(connection: connection)
        }

        let movieOutput = AVCaptureMovieFileOutput()
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            if let connection = movieOutput.connection(with: .video) {
                configure(connection: connection)
            }
            self.movieOutput = movieOutput
        }

        self.output = output
        currentDevice = device
        latestFrame = nil
        configurePreferredFrameRate(on: device)
        applyFocusAndExposureDefaults(to: device)
    }

    private func configureAudioCaptureForRecordingIfNeeded() {
        guard isAudioCaptureAuthorized, audioInput == nil else { return }
        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
              session.canAddInput(audioInput) else {
            return
        }
        session.beginConfiguration()
        session.addInput(audioInput)
        session.commitConfiguration()
        self.audioInput = audioInput
    }

    private func captureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back,
           let device = AVCaptureDevice.default(selectedBackLens.deviceType, for: .video, position: .back) {
            return device
        }

        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }

    private func configure(connection: AVCaptureConnection) {
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let squareFrame = Self.squareImage(CIImage(cvPixelBuffer: pixelBuffer))
        latestFrame = squareFrame
        renderLatestFrame()
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let completion = videoRecordingCompletion
        videoRecordingCompletion = nil
        videoRecordingURL = nil

        Task { @MainActor in
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            if let error {
                completion?(.failure(error))
            } else {
                completion?(.success(outputFileURL))
            }
        }
    }

    private func renderLatestFrame(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastFrameTime >= 1.0 / 15.0 else { return }
        lastFrameTime = now

        guard let square = latestFrame else { return }
        var output = MirrorReflectionProcessor.process(
            square,
            edges: currentMode.edges(
                reflectionSelection: currentReflectionSelection
            )
        )
        if isBinaryFilterEnabled {
            output = Self.thresholdImage(output, threshold: thresholdLevel)
        }
        let originalImage = MirrorReflectionProcessor.renderedImage(from: square, edges: [])
        guard let image = MirrorReflectionProcessor.renderedImage(
            from: output,
            edges: []
        ) else {
            return
        }
        if isAnimacyScoringEnabled, let cgImage = image.cgImage {
            submitAnimacyFrame(cgImage, now: now)
        }

        Task { @MainActor in
            self.previewImage = image
            self.latestOriginalImage = originalImage
        }
    }

    private func submitAnimacyFrame(_ cgImage: CGImage, now: CFTimeInterval) {
        guard isAnimacyScoringEnabled else { return }
        guard now - lastAnimacyFrameTime >= 1.0 / 10.0, !isAnimacyScoreInFlight else { return }
        lastAnimacyFrameTime = now
        isAnimacyScoreInFlight = true

        let scorer = animacyScorer
        Task.detached(priority: .utility) { [weak self, scorer] in
            guard let controller = self else { return }
            defer {
                controller.videoQueue.async { [weak controller] in
                    controller?.isAnimacyScoreInFlight = false
                }
            }

            do {
                let result = try await scorer.score(cgImage: cgImage)
                await controller.publishAnimacyResult(result)
            } catch {
                await controller.publishAnimacyError(error)
            }
        }
    }

    @MainActor
    private func publishAnimacyResult(_ result: AnimacyResult) {
        animacyResult = result
    }

    @MainActor
    private func publishAnimacyError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private static func squareImage(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let side = min(extent.width, extent.height)
        let crop = CGRect(
            x: extent.midX - side / 2,
            y: extent.midY - side / 2,
            width: side,
            height: side
        )
        return image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    private func configurePreferredFrameRate(on device: AVCaptureDevice) {
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 60 }) else {
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
            device.unlockForConfiguration()
        } catch {
            Task { @MainActor in
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func applyFocusAndExposureDefaults(to device: AVCaptureDevice) {
        if isFocusManual {
            applyLensPosition(to: device)
        } else {
            applyAutofocus(to: device)
        }

        if isExposureManual {
            applyExposure(to: device)
        } else {
            applyAutoExposure(to: device)
        }
    }

    private func applyAutofocus(to device: AVCaptureDevice) {
        guard device.isFocusModeSupported(.continuousAutoFocus) || device.isFocusModeSupported(.autoFocus) else { return }

        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            device.unlockForConfiguration()
        } catch {
            Task { @MainActor in
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func applyAutoExposure(to device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.continuousAutoExposure) || device.isExposureModeSupported(.autoExpose) else { return }

        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            } else if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }
            device.setExposureTargetBias(0)
            device.unlockForConfiguration()
        } catch {
            Task { @MainActor in
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func applyLensPosition(to device: AVCaptureDevice) {
        guard device.isFocusModeSupported(.locked) else { return }

        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: Float(lensPosition))
            device.unlockForConfiguration()
        } catch {
            Task { @MainActor in
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func applyExposure(to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let minimumBias = device.minExposureTargetBias
            let maximumBias = device.maxExposureTargetBias
            let bias = minimumBias + Float(exposureLevel) * (maximumBias - minimumBias)
            device.setExposureTargetBias(bias)
            device.unlockForConfiguration()
        } catch {
            Task { @MainActor in
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private static func thresholdImage(_ image: CIImage, threshold: Double) -> CIImage {
        guard let thresholdFilter = CIFilter(name: "CIColorThreshold") else { return image }
        let clampedThreshold = min(max(threshold, 0), 1)

        thresholdFilter.setValue(image, forKey: kCIInputImageKey)
        thresholdFilter.setValue(clampedThreshold, forKey: "inputThreshold")

        guard let mask = thresholdFilter.outputImage?.cropped(to: image.extent) else {
            return image
        }

        let white = CIImage(color: .white).cropped(to: image.extent)
        let black = CIImage(color: .black).cropped(to: image.extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = white
        blend.backgroundImage = black
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: image.extent) ?? image
    }
}

private final class MirrorVideoRecorder {
    enum RecorderError: LocalizedError {
        case notRecording
        case couldNotCreatePixelBuffer
        case noFrames
        case writerFailed

        var errorDescription: String? {
            switch self {
            case .notRecording:
                "Video recording is not active."
            case .couldNotCreatePixelBuffer:
                "The video frame could not be encoded."
            case .noFrames:
                "No video frames were captured."
            case .writerFailed:
                "The video could not be written."
            }
        }
    }

    private let outputURL: URL
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameSize = CGSize(width: 720, height: 720)
    private var startSourceTime: CMTime?
    private var didAppendFrame = false
    private var storedError: Error?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func append(image: CIImage, sourceTime: CMTime) {
        guard storedError == nil else { return }

        do {
            if writer == nil {
                try configure(for: image.extent.size, firstSourceTime: sourceTime)
            }
            guard let videoInput, videoInput.isReadyForMoreMediaData, let adaptor, let pool = adaptor.pixelBufferPool else {
                return
            }

            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else {
                throw RecorderError.couldNotCreatePixelBuffer
            }

            let normalizedImage = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            ))
            let bounds = CGRect(origin: .zero, size: frameSize)
            context.render(normalizedImage, to: pixelBuffer, bounds: bounds, colorSpace: colorSpace)

            let presentationTime = relativeTime(for: sourceTime)
            if adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
                didAppendFrame = true
            }
        } catch {
            storedError = error
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard storedError == nil,
              writer != nil,
              let audioInput,
              audioInput.isReadyForMoreMediaData,
              let adjustedBuffer = retimedAudioBuffer(sampleBuffer) else {
            return
        }

        if !audioInput.append(adjustedBuffer) {
            storedError = writer?.error ?? RecorderError.writerFailed
        }
    }

    func finish(completion: @escaping (Result<Void, Error>) -> Void) {
        if let storedError {
            writer?.cancelWriting()
            completion(.failure(storedError))
            return
        }

        guard let writer, let videoInput else {
            completion(.failure(RecorderError.noFrames))
            return
        }

        guard didAppendFrame else {
            writer.cancelWriting()
            completion(.failure(RecorderError.noFrames))
            return
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(()))
            } else {
                completion(.failure(writer.error ?? RecorderError.writerFailed))
            }
        }
    }

    private func configure(for size: CGSize, firstSourceTime: CMTime) throws {
        try? FileManager.default.removeItem(at: outputURL)

        let side = Self.evenDimension(from: min(size.width, size.height))
        frameSize = CGSize(width: side, height: side)
        startSourceTime = firstSourceTime

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(frameSize.width),
            AVVideoHeightKey: Int(frameSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(frameSize.width * frameSize.height * 4)
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw RecorderError.writerFailed
        }
        writer.add(input)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        if writer.canAdd(audioInput) {
            writer.add(audioInput)
            self.audioInput = audioInput
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(frameSize.width),
            kCVPixelBufferHeightKey as String: Int(frameSize.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = input
    }

    private func relativeTime(for sourceTime: CMTime) -> CMTime {
        guard let startSourceTime, sourceTime.isValid else {
            return .zero
        }
        return max(CMTimeSubtract(sourceTime, startSourceTime), .zero)
    }

    private func retimedAudioBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let startSourceTime else { return nil }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return nil }

        var timing = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .zero,
                decodeTimeStamp: .invalid
            ),
            count: sampleCount
        )
        var timingEntries = 0
        let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: sampleCount,
            arrayToFill: &timing,
            entriesNeededOut: &timingEntries
        )
        guard timingStatus == noErr else { return nil }

        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = max(
                    CMTimeSubtract(timing[index].presentationTimeStamp, startSourceTime),
                    .zero
                )
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = max(
                    CMTimeSubtract(timing[index].decodeTimeStamp, startSourceTime),
                    .zero
                )
            }
        }

        var adjustedBuffer: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing,
            sampleBufferOut: &adjustedBuffer
        )
        guard copyStatus == noErr else { return nil }
        return adjustedBuffer
    }

    private static func evenDimension(from value: CGFloat) -> Int {
        let clamped = max(Int(value.rounded(.down)), 2)
        return clamped.isMultiple(of: 2) ? clamped : clamped - 1
    }
}

private enum MirrorVideoPostProcessor {
    enum ProcessorError: LocalizedError {
        case exportUnavailable
        case exportFailed
        case noVideoTrack
        case noVideoFrames
        case couldNotCopyFrame
        case writerFailed

        var errorDescription: String? {
            switch self {
            case .exportUnavailable:
                "The video exporter could not be created."
            case .exportFailed:
                "The edited video could not be exported."
            case .noVideoTrack:
                "The video track could not be found."
            case .noVideoFrames:
                "No video frames were found."
            case .couldNotCopyFrame:
                "A video frame could not be copied."
            case .writerFailed:
                "The reflected video could not be written."
            }
        }
    }

    static func thumbnail(from url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 900)

        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    static func process(
        inputURL: URL,
        configuration: MirrorOutputConfiguration
    ) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        let forwardURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        try? FileManager.default.removeItem(at: forwardURL)

        let renderSize = await renderSize(for: asset, configuration: configuration)
        let videoComposition = AVMutableVideoComposition(asset: asset) { request in
            let output = MirrorOutputComposer.processedVideoImage(
                source: request.sourceImage,
                configuration: configuration
            )
            request.finish(with: output, context: nil)
        }
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ProcessorError.exportUnavailable
        }
        exporter.outputURL = forwardURL
        exporter.outputFileType = .mov
        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = true

        nonisolated(unsafe) let unsafeExporter = exporter
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            unsafeExporter.exportAsynchronously {
                switch unsafeExporter.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: unsafeExporter.error ?? ProcessorError.exportFailed)
                default:
                    continuation.resume(throwing: ProcessorError.exportFailed)
                }
            }
        }

        guard configuration.temporalMode != .forward else {
            return forwardURL
        }

        let temporalURL = try await makeTemporalVideo(from: forwardURL, mode: configuration.temporalMode)
        try? FileManager.default.removeItem(at: forwardURL)
        return temporalURL
    }

    private static func makeTemporalVideo(from forwardURL: URL, mode: MediaTemporalMode) async throws -> URL {
        let videoOnlyURL = try await renderTemporalVideoFrames(from: forwardURL, mode: mode)
        let forwardAsset = AVURLAsset(url: forwardURL)

        guard let audioURL = try await MediaPalindromeProcessor.makeTemporalAudio(from: forwardAsset, mode: mode) else {
            return videoOnlyURL
        }
        defer {
            try? FileManager.default.removeItem(at: videoOnlyURL)
            try? FileManager.default.removeItem(at: audioURL)
        }

        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        return try await combine(videoURL: videoOnlyURL, audioURL: audioURL, outputURL: finalURL)
    }

    private static func renderTemporalVideoFrames(from forwardURL: URL, mode: MediaTemporalMode) async throws -> URL {
        let asset = AVURLAsset(url: forwardURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessorError.noVideoTrack
        }
        let loadedFrameDuration = try await videoTrack.load(.minFrameDuration)
        let fallbackDuration = loadedFrameDuration.isValid && loadedFrameDuration.seconds > 0
            ? loadedFrameDuration
            : CMTime(value: 1, timescale: 60)

        nonisolated(unsafe) let unsafeVideoTrack = videoTrack
        return try await Task.detached(priority: .userInitiated) {
            try renderTemporalVideoFramesSynchronously(
                asset: asset,
                videoTrack: unsafeVideoTrack,
                fallbackDuration: fallbackDuration,
                mode: mode
            )
        }.value
    }

    private static func renderTemporalVideoFramesSynchronously(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        fallbackDuration: CMTime,
        mode: MediaTemporalMode
    ) throws -> URL {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ProcessorError.exportUnavailable
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? ProcessorError.exportFailed
        }

        var buffers: [CVPixelBuffer] = []
        var presentationTimes: [CMTime] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let copiedBuffer = copyPixelBuffer(sourceBuffer) else {
                throw ProcessorError.couldNotCopyFrame
            }
            buffers.append(copiedBuffer)
            presentationTimes.append(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }

        if reader.status == .failed {
            throw reader.error ?? ProcessorError.exportFailed
        }
        guard !buffers.isEmpty else {
            throw ProcessorError.noVideoFrames
        }

        let durations = frameDurations(
            presentationTimes: presentationTimes,
            fallback: fallbackDuration
        )
        let width = CVPixelBufferGetWidth(buffers[0])
        let height = CVPixelBufferGetHeight(buffers[0])
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 4, 1_000_000)
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw ProcessorError.writerFailed
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )

        guard writer.startWriting() else {
            throw writer.error ?? ProcessorError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)

        var cursor = CMTime.zero
        switch mode {
        case .forward:
            try append(buffers: buffers, durations: durations, input: input, adaptor: adaptor, cursor: &cursor)
        case .backward:
            try append(buffers: buffers.reversed(), durations: durations.reversed(), input: input, adaptor: adaptor, cursor: &cursor)
        case .forwardBackward:
            try append(buffers: buffers, durations: durations, input: input, adaptor: adaptor, cursor: &cursor)
            try append(buffers: buffers.reversed(), durations: durations.reversed(), input: input, adaptor: adaptor, cursor: &cursor)
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        var finishError: Error?
        writer.finishWriting {
            if writer.status != .completed {
                finishError = writer.error ?? ProcessorError.writerFailed
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let finishError {
            throw finishError
        }
        return outputURL
    }

    private static func append<Buffers: Collection, Durations: Collection>(
        buffers: Buffers,
        durations: Durations,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        cursor: inout CMTime
    ) throws where Buffers.Element == CVPixelBuffer, Durations.Element == CMTime {
        for (buffer, duration) in zip(buffers, durations) {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard adaptor.append(buffer, withPresentationTime: cursor) else {
                throw ProcessorError.writerFailed
            }
            cursor = CMTimeAdd(cursor, duration)
        }
    }

    private static func frameDurations(presentationTimes: [CMTime], fallback: CMTime) -> [CMTime] {
        guard !presentationTimes.isEmpty else { return [] }
        return presentationTimes.indices.map { index in
            if index + 1 < presentationTimes.count {
                let duration = CMTimeSubtract(presentationTimes[index + 1], presentationTimes[index])
                if duration.isValid && duration.seconds > 0 {
                    return duration
                }
            }
            return fallback
        }
    }

    private static func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)

        var destination: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary,
            &destination
        )
        guard status == kCVReturnSuccess, let destination else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
            return nil
        }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
        let bytesToCopy = min(sourceBytesPerRow, destinationBytesPerRow)

        for row in 0..<height {
            memcpy(
                destinationBase.advanced(by: row * destinationBytesPerRow),
                sourceBase.advanced(by: row * sourceBytesPerRow),
                bytesToCopy
            )
        }

        return destination
    }

    private static func combine(videoURL: URL, audioURL: URL, outputURL: URL) async throws -> URL {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let videoDuration = try await videoAsset.load(.duration)

        guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw ProcessorError.noVideoTrack
        }

        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideoTrack,
            at: .zero
        )
        videoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        if let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let audioDuration = try await audioAsset.load(.duration)
            let insertDuration = CMTimeCompare(audioDuration, videoDuration) < 0 ? audioDuration : videoDuration
            try audioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: insertDuration),
                of: sourceAudioTrack,
                at: .zero
            )
        }

        try? FileManager.default.removeItem(at: outputURL)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ProcessorError.exportUnavailable
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = true

        nonisolated(unsafe) let unsafeExporter = exporter
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            unsafeExporter.exportAsynchronously {
                switch unsafeExporter.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: unsafeExporter.error ?? ProcessorError.exportFailed)
                default:
                    continuation.resume(throwing: ProcessorError.exportFailed)
                }
            }
        }

        return outputURL
    }

    private static func renderSize(
        for asset: AVAsset,
        configuration: MirrorOutputConfiguration
    ) async -> CGSize {
        let trackSize: CGSize
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ProcessorError.exportUnavailable
            }
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            trackSize = naturalSize.applying(preferredTransform)
        } catch {
            trackSize = CGSize(width: 720, height: 720)
        }
        let side = max(min(abs(trackSize.width), abs(trackSize.height)), 2)
        return configuration.isDoubleOutputEnabled
            ? CGSize(width: side, height: side * 2)
            : CGSize(width: side, height: side)
    }
}

private enum ThreadMirrorCameraError: LocalizedError {
    case cameraUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            "Camera unavailable."
        }
    }
}

@MainActor
private final class CameraRollMediaSaver: ObservableObject {
    @Published private(set) var statusMessage: String?
    @Published private(set) var didFail = false
    @Published private(set) var isSaving = false

    func save(_ image: UIImage) {
        guard !isSaving else { return }
        isSaving = true
        statusMessage = "Saving photo"
        didFail = false

        Task {
            do {
                try await requestAddPermissionIfNeeded()
                try await saveToPhotoLibrary(image)
                statusMessage = "Saved to Photos"
                didFail = false
            } catch {
                statusMessage = error.localizedDescription
                didFail = true
            }
            isSaving = false
        }
    }

    func saveVideo(at url: URL) {
        guard !isSaving else { return }
        isSaving = true
        statusMessage = "Saving video"
        didFail = false

        Task {
            do {
                try await requestAddPermissionIfNeeded()
                try await saveVideoToPhotoLibrary(url)
                statusMessage = "Saved to Photos"
                didFail = false
            } catch {
                statusMessage = error.localizedDescription
                didFail = true
            }
            isSaving = false
        }
    }

    func showFailure(_ message: String) {
        statusMessage = message
        didFail = true
        isSaving = false
    }

    func showStatus(_ message: String) {
        statusMessage = message
        didFail = false
    }

    private func requestAddPermissionIfNeeded() async throws {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard currentStatus == .notDetermined else {
            try validate(status: currentStatus)
            return
        }

        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
        try validate(status: status)
    }

    private func validate(status: PHAuthorizationStatus) throws {
        switch status {
        case .authorized, .limited:
            return
        default:
            throw CameraRollSaveError.notAuthorized
        }
    }

    private func saveToPhotoLibrary(_ image: UIImage) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CameraRollSaveError.saveFailed)
                }
            }
        }
    }

    private func saveVideoToPhotoLibrary(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CameraRollSaveError.saveFailed)
                }
            }
        }
    }
}

private enum CameraRollSaveError: LocalizedError {
    case notAuthorized
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Photos access is disabled."
        case .saveFailed:
            "The photo could not be saved."
        }
    }
}

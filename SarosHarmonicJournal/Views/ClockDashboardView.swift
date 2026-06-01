import AVFoundation
import CoreImage
import Photos
import SwiftData
import SwiftUI
import UIKit

struct ClockDashboardView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \JournalRecord.createdAt, order: .reverse) private var records: [JournalRecord]

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @AppStorage(JournalSettings.countdownMinimumTierKey) private var countdownMinimumTierSetting = JournalSettings.defaultCountdownMinimumTier
    @State private var isAddingEntity = false
    @State private var captureEntity: TrackedEntity?
    @State private var now = Date()

    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            if let closestFlip {
                Section("Next flip") {
                    ClosestFlipCard(
                        entity: closestFlip.entity,
                        reading: closestFlip.reading,
                        flipCountdown: closestFlip.countdown,
                        countdownText: countdownText(for: closestFlip.countdown.timeUntilFlip)
                    ) {
                        captureEntity = closestFlip.entity
                    }
                }
            }

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
                } else {
                    ForEach(entities) { entity in
                        let reading = reading(for: entity)
                        let countdown = reading?.countdown(minimumTier: countdownMinimumTier, now: now)
                        NavigationLink {
                            EntityDetailView(entity: entity)
                        } label: {
                            EntityCardView(
                                entity: entity,
                                reading: reading,
                                countdown: countdown,
                                latestRecord: latestRecord(for: entity)
                            )
                        }
                    }
                    .onDelete(perform: deleteEntities)
                }
            }

            if let resonance = nextResonance {
                Section("Next resonance") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(resonance.entityIDs.count) threads flip close together")
                            .font(.headline)
                        Text("\(JournalFormatters.dateTime.string(from: resonance.startDate)) - \(JournalFormatters.dateTime.string(from: resonance.endDate))")
                            .foregroundStyle(.secondary)
                        Text("Saros \(resonance.sarosValues.map(String.init).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Threads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
        .sheet(item: $captureEntity) { entity in
            NavigationStack {
                CaptureView(entity: entity, harmonicDepth: harmonicDepth) {
                    now = Date()
                }
            }
        }
        .onReceive(countdownTimer) { date in
            now = date
        }
    }

    private var countdownMinimumTier: Int {
        JournalSettings.clampedCountdownMinimumTier(countdownMinimumTierSetting, harmonicDepth: harmonicDepth)
    }

    private var closestFlip: (entity: TrackedEntity, reading: SarosClockReading, countdown: SarosFlipCountdown)? {
        entityReadings.min { lhs, rhs in
            lhs.countdown.timeUntilFlip < rhs.countdown.timeUntilFlip
        }
    }

    private var entityReadings: [(entity: TrackedEntity, reading: SarosClockReading, countdown: SarosFlipCountdown)] {
        entities.compactMap { entity in
            guard let reading = reading(for: entity) else { return nil }
            return (entity, reading, reading.countdown(minimumTier: countdownMinimumTier, now: now))
        }
    }

    private var nextResonance: ResonanceEvent? {
        let flips = entities.compactMap { entity -> EntityFlip? in
            guard let reading = try? services.clockService.reading(
                saros: entity.saros,
                date: now,
                harmonicDepth: harmonicDepth
            ) else {
                return nil
            }

            let nextIndex = min(reading.binIndex + 1, reading.binCount - 1)
            return EntityFlip(
                entityID: entity.id,
                entityTitle: entity.displayTitle,
                date: reading.nextFlipDate,
                saros: entity.saros,
                octalAddress: String(nextIndex, radix: 8).leftPadded(toLength: harmonicDepth, withPad: "0")
            )
        }

        return ResonanceDetector.detectResonances(flips: flips, window: 60 * 60)
            .filter { $0.endDate >= now }
            .first
    }

    private func reading(for entity: TrackedEntity) -> SarosClockReading? {
        try? services.clockService.reading(
            saros: entity.saros,
            date: now,
            harmonicDepth: harmonicDepth
        )
    }

    private func latestRecord(for entity: TrackedEntity) -> JournalRecord? {
        records.first { $0.entityID == entity.id }
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
        for offset in offsets {
            modelContext.delete(entities[offset])
        }
        try? modelContext.save()
    }
}

private struct ClosestFlipCard: View {
    let entity: TrackedEntity
    let reading: SarosClockReading
    let flipCountdown: SarosFlipCountdown
    let countdownText: String
    let record: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                DynamicFlipGlyph(reading: reading, countdown: flipCountdown)
                    .frame(width: 74, height: 74)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    Text(entity.displayTitle)
                        .font(.headline)
                    Text("Saros \(reading.saros) · tier \(flipCountdown.flipTier) · \(flipCountdown.targetOctalAddress)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(countdownText)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .contentTransition(.numericText())
                }

                Spacer()
            }

            HStack {
                Text("Flip \(JournalFormatters.dateTime.string(from: flipCountdown.flipDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: record) {
                    Image(systemName: "record.circle.fill")
                        .font(.title3)
                        .frame(width: 44, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Record \(entity.displayTitle)")
            }
        }
        .padding(.vertical, 6)
    }
}

private struct EntityCardView: View {
    let entity: TrackedEntity
    let reading: SarosClockReading?
    let countdown: SarosFlipCountdown?
    let latestRecord: JournalRecord?

    var body: some View {
        HStack(spacing: 14) {
            avatar

            VStack(alignment: .leading, spacing: 6) {
                Text(entity.displayTitle)
                    .font(.headline)
                Text("Saros \(entity.saros) · \(reading?.octalAddress ?? "----")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let countdown {
                    Text("Tier \(countdown.flipTier) in \(countdown.timeUntilFlip.compactDuration)")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                }

                if let latestRecord {
                    Text(latestRecord.text ?? latestRecord.emoji ?? latestRecord.triggerType.displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let reading, let countdown {
                DynamicFlipGlyph(reading: reading, countdown: countdown)
                    .frame(width: 42, height: 42)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var avatar: some View {
        if let reading {
            OctalGlyph(value: reading.octalAddress, depth: reading.harmonicDepth)
                .frame(width: 48, height: 48)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
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

private struct DynamicFlipGlyph: View {
    let reading: SarosClockReading
    let countdown: SarosFlipCountdown?

    init(reading: SarosClockReading, countdown: SarosFlipCountdown? = nil) {
        self.reading = reading
        self.countdown = countdown
    }

    var body: some View {
        let activeCountdown = countdown ?? reading.countdown(minimumTier: reading.harmonicDepth - 1)
        TimelineView(.periodic(from: activeCountdown.periodStartDate, by: refreshPeriod(for: activeCountdown))) { context in
            OctalGlyph(
                value: dynamicAddress(at: context.date, countdown: activeCountdown),
                depth: reading.harmonicDepth,
                color: .cyan
            )
        }
        .accessibilityLabel("Flip countdown glyph")
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
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var allEntities: [TrackedEntity]
    @Query(sort: \JournalRecord.eventDate, order: .reverse) private var records: [JournalRecord]

    let entity: TrackedEntity
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @State private var selectedTab: ThreadDetailTab = .records
    @State private var isCapturing = false
    @State private var now = Date()

    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section {
                if let reading = currentReading {
                    HStack(spacing: 16) {
                        OctalGlyph(value: reading.octalAddress, depth: reading.harmonicDepth)
                            .frame(width: 72, height: 72)
                            .padding(8)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(reading.octalAddress)
                                .font(.system(.title, design: .monospaced))
                            Text("Next flip \(JournalFormatters.dateTime.string(from: reading.nextFlipDate))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let notes = entity.notes, !notes.isEmpty {
                    Text(notes)
                }
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
            case .flips:
                flipsTab
            case .search:
                searchTab
            }
        }
        .navigationTitle(entity.displayTitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isCapturing = true
                } label: {
                    Label("Rec", systemImage: "record.circle")
                }
            }
        }
        .sheet(isPresented: $isCapturing) {
            NavigationStack {
                CaptureView(entity: entity, harmonicDepth: harmonicDepth) {
                    now = Date()
                }
            }
        }
        .onReceive(countdownTimer) { date in
            now = date
        }
    }

    private var currentReading: SarosClockReading? {
        try? services.clockService.reading(
            saros: entity.saros,
            date: now,
            harmonicDepth: harmonicDepth
        )
    }

    private var entityRecords: [JournalRecord] {
        records.filter { $0.entityID == entity.id }
    }

    @ViewBuilder
    private var recordsTab: some View {
        Section("Records") {
            if entityRecords.isEmpty {
                Text("No records yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entityRecords) { record in
                    NavigationLink {
                        JournalRecordDetailView(record: record, entityTitle: entity.displayTitle)
                    } label: {
                        JournalRecordRow(record: record, entityTitle: entity.displayTitle)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var flipsTab: some View {
        if let reading = currentReading {
            let timeline = ThreadFlipTimeline(
                reading: reading,
                now: now,
                selectedTier: 2
            )

            Section("Future") {
                ForEach(timeline.futureBins, id: \.self) { bin in
                    flipNavigationLink(event: timeline.event(for: bin), reading: reading)
                }
                if let nextEclipse = timeline.nextEclipseEvent {
                    flipNavigationLink(event: nextEclipse, reading: reading)
                }
            }

            Section("Past") {
                ForEach(timeline.pastBins, id: \.self) { bin in
                    flipNavigationLink(event: timeline.event(for: bin), reading: reading)
                }
                if let previousEclipse = timeline.previousEclipseEvent {
                    flipNavigationLink(event: previousEclipse, reading: reading)
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
                sarosReferences: otherSarosReferences
            )
        } label: {
            ThreadFlipRow(
                event: event,
                depth: harmonicDepth,
                now: now,
                resonances: resonances(for: event)
            )
        }
    }

    private var otherSarosReferences: [ThreadSarosReference] {
        var seenSaroses: Set<Int> = []
        return allEntities.compactMap { trackedEntity in
            guard trackedEntity.saros != entity.saros,
                  seenSaroses.insert(trackedEntity.saros).inserted else {
                return nil
            }
            return ThreadSarosReference(
                saros: trackedEntity.saros,
                title: trackedEntity.displayTitle
            )
        }
    }

    private func resonances(for event: ThreadFlipEvent) -> [ThreadFlipOverlap] {
        ThreadFlipResonanceCalculator.overlaps(
            for: event,
            sourceSaros: entity.saros,
            references: otherSarosReferences,
            clockService: services.clockService,
            harmonicDepth: harmonicDepth
        )
        .filter(\.isResonance)
    }

    @ViewBuilder
    private var searchTab: some View {
        if let reading = currentReading {
            Section {
                ThreadGlyphSearchView(reading: reading)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }
        } else {
            Section("Search") {
                ContentUnavailableView("Search unavailable", systemImage: "magnifyingglass")
            }
        }
    }
}

private enum ThreadDetailTab: String, CaseIterable, Identifiable {
    case records
    case flips
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .records: "Records"
        case .flips: "Flips"
        case .search: "Search"
        }
    }
}

private struct ThreadFlipEvent: Identifiable {
    let id: String
    let title: String
    let date: Date
    let octalAddress: String
    let isFuture: Bool
    let periodDuration: TimeInterval?

    var color: Color {
        isFuture ? .green : .red
    }
}

private struct ThreadFlipTimeline {
    let reading: SarosClockReading
    let now: Date
    let selectedTier: Int
    let stride: Int
    let futureBins: ThreadFlipBinCollection
    let pastBins: ThreadFlipBinCollection
    let previousEclipseEvent: ThreadFlipEvent?
    let nextEclipseEvent: ThreadFlipEvent?

    var trailingZeroCount: Int {
        max(reading.harmonicDepth - selectedTier - 1, 0)
    }

    var stepOctalLabel: String {
        String(stride, radix: 8).leftPadded(toLength: trailingZeroCount + 1, withPad: "0")
    }

    init(
        reading: SarosClockReading,
        now: Date,
        selectedTier rawSelectedTier: Int
    ) {
        self.reading = reading
        self.now = now
        self.selectedTier = JournalSettings.clampedCountdownMinimumTier(
            rawSelectedTier,
            harmonicDepth: reading.harmonicDepth
        )
        self.stride = reading.qualifiedFlipStride(forTier: self.selectedTier)

        let firstFutureBin = reading.nextQualifiedFlipBin(after: reading.binIndex, tier: self.selectedTier)
        self.futureBins = ThreadFlipBinCollection(
            firstBin: firstFutureBin,
            lastBin: max(reading.binCount - 1, 0),
            step: stride,
            direction: .forward
        )

        let firstPastBin = reading.previousQualifiedFlipBin(atOrBefore: reading.binIndex, tier: self.selectedTier)
        self.pastBins = ThreadFlipBinCollection(
            firstBin: firstPastBin,
            lastBin: stride,
            step: stride,
            direction: .backward
        )

        self.previousEclipseEvent = ThreadFlipEvent(
            id: "previous-eclipse-\(reading.previousEclipse.id)",
            title: "Previous eclipse",
            date: reading.previousEclipse.date,
            octalAddress: reading.octalAddress(forBinIndex: 0),
            isFuture: reading.previousEclipse.date >= now,
            periodDuration: reading.intervalDuration
        )

        self.nextEclipseEvent = ThreadFlipEvent(
            id: "next-eclipse-\(reading.nextEclipse.id)",
            title: "Next eclipse",
            date: reading.nextEclipse.date,
            octalAddress: reading.octalAddress(forBinIndex: reading.binCount),
            isFuture: reading.nextEclipse.date >= now,
            periodDuration: reading.intervalDuration
        )
    }

    func event(for binIndex: Int) -> ThreadFlipEvent {
        let date = reading.date(forBinIndex: binIndex)
        return ThreadFlipEvent(
            id: "flip-\(binIndex)",
            title: "Flip",
            date: date,
            octalAddress: reading.octalAddress(forBinIndex: binIndex),
            isFuture: date >= now,
            periodDuration: Double(stride) * reading.binDuration
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

    private var isTierOneFlip: Bool {
        event.title == "Flip" &&
            FlipNotificationPreferences.tier(
                forOctalAddress: event.octalAddress,
                harmonicDepth: depth
            ) == 1
    }

    private var rowColor: Color {
        isTierOneFlip ? .yellow : event.color
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
            OctalGlyph(value: event.octalAddress, depth: depth, color: rowColor)
                .frame(width: 42, height: 42)
                .padding(5)
                .background(rowColor.opacity(isTierOneFlip ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(dateText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(rowColor)
                Text(timeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(event.octalAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(rowColor)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                if !resonances.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(resonances.prefix(2))) { overlap in
                            Text(overlap.badgeTitle)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(rowColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(rowColor.opacity(0.16), in: Capsule())
                        }
                        if resonances.count > 2 {
                            Text("+\(resonances.count - 2)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
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

    var id: Int { saros }
}

private enum ThreadFlipResonanceKind: Hashable {
    case none
    case direct
    case harmonic
}

private struct ThreadFlipOverlap: Identifiable, Hashable {
    let saros: Int
    let title: String
    let date: Date
    let octalAddress: String
    let delta: TimeInterval
    let resonanceKind: ThreadFlipResonanceKind
    let resonanceOffset: TimeInterval
    let harmonicTargetOffset: TimeInterval?

    var id: Int { saros }
    var isSameDayResonance: Bool { resonanceKind == .direct }
    var isHarmonicResonance: Bool { resonanceKind == .harmonic }
    var isResonance: Bool { resonanceKind != .none }

    var badgeTitle: String {
        isHarmonicResonance ? "H\(saros)" : "S\(saros)"
    }
}

private enum ThreadFlipResonanceCalculator {
    static let comparisonTier = 2
    private static let resonanceWindow: TimeInterval = 24 * 60 * 60

    static func overlaps(
        for event: ThreadFlipEvent,
        sourceSaros: Int,
        references: [ThreadSarosReference],
        clockService: any SarosClockService,
        harmonicDepth: Int
    ) -> [ThreadFlipOverlap] {
        references
            .filter { $0.saros != sourceSaros }
            .compactMap { reference in
                nearestOverlap(
                    for: reference,
                    selectedDate: event.date,
                    sourcePeriod: event.periodDuration,
                    clockService: clockService,
                    harmonicDepth: harmonicDepth
                )
            }
            .sorted { $0.resonanceOffset < $1.resonanceOffset }
    }

    private static func nearestOverlap(
        for reference: ThreadSarosReference,
        selectedDate: Date,
        sourcePeriod: TimeInterval?,
        clockService: any SarosClockService,
        harmonicDepth: Int
    ) -> ThreadFlipOverlap? {
        let probeDates = probeDates(selectedDate: selectedDate, sourcePeriod: sourcePeriod)
        var seenCandidates: Set<String> = []
        let candidates = probeDates.flatMap { probeDate -> [ThreadFlipCandidate] in
            guard let reading = try? clockService.reading(
                saros: reference.saros,
                date: probeDate,
                harmonicDepth: harmonicDepth
            ) else {
                return []
            }

            return [
                reading.previousQualifiedFlipBin(atOrBefore: reading.binIndex, tier: comparisonTier),
                reading.nextQualifiedFlipBin(after: reading.binIndex, tier: comparisonTier)
            ]
            .compactMap { $0 }
            .compactMap { bin -> ThreadFlipCandidate? in
                let id = "\(reading.previousEclipse.id)-\(bin)"
                guard seenCandidates.insert(id).inserted else { return nil }
                return ThreadFlipCandidate(
                    date: reading.date(forBinIndex: bin),
                    octalAddress: reading.octalAddress(forBinIndex: bin)
                )
            }
        }

        guard let nearest = candidates
            .min(by: { lhs, rhs in
                resonanceScore(
                    delta: lhs.date.timeIntervalSince(selectedDate),
                    sourcePeriod: sourcePeriod
                ).offset < resonanceScore(
                    delta: rhs.date.timeIntervalSince(selectedDate),
                    sourcePeriod: sourcePeriod
                ).offset
            }) else {
            return nil
        }

        let delta = nearest.date.timeIntervalSince(selectedDate)
        let score = resonanceScore(delta: delta, sourcePeriod: sourcePeriod)
        let resonanceKind = score.offset < resonanceWindow ? score.kind : .none

        return ThreadFlipOverlap(
            saros: reference.saros,
            title: reference.title,
            date: nearest.date,
            octalAddress: nearest.octalAddress,
            delta: delta,
            resonanceKind: resonanceKind,
            resonanceOffset: score.offset,
            harmonicTargetOffset: score.harmonicTargetOffset
        )
    }

    private static func probeDates(selectedDate: Date, sourcePeriod: TimeInterval?) -> [Date] {
        guard let sourcePeriod, sourcePeriod > 0 else {
            return [selectedDate]
        }

        let halfPeriod = sourcePeriod / 2
        return [
            selectedDate,
            selectedDate.addingTimeInterval(-halfPeriod),
            selectedDate.addingTimeInterval(halfPeriod)
        ]
    }

    private static func resonanceScore(
        delta: TimeInterval,
        sourcePeriod: TimeInterval?
    ) -> (kind: ThreadFlipResonanceKind, offset: TimeInterval, harmonicTargetOffset: TimeInterval?) {
        let directOffset = abs(delta)
        guard let sourcePeriod, sourcePeriod > 0 else {
            return (.direct, directOffset, nil)
        }

        let halfPeriod = sourcePeriod / 2
        let harmonicOffset = abs(abs(delta) - halfPeriod)
        if harmonicOffset < directOffset {
            return (.harmonic, harmonicOffset, halfPeriod)
        }

        return (.direct, directOffset, halfPeriod)
    }
}

private struct ThreadFlipCandidate {
    let date: Date
    let octalAddress: String
}

private struct ThreadFlipResonanceDetailView: View {
    @EnvironmentObject private var services: AppServices

    let event: ThreadFlipEvent
    let sourceTitle: String
    let sourceSaros: Int
    let harmonicDepth: Int
    let sarosReferences: [ThreadSarosReference]

    private var overlaps: [ThreadFlipOverlap] {
        ThreadFlipResonanceCalculator.overlaps(
            for: event,
            sourceSaros: sourceSaros,
            references: sarosReferences,
            clockService: services.clockService,
            harmonicDepth: harmonicDepth
        )
    }

    private var sameDayResonanceCount: Int {
        overlaps.filter(\.isSameDayResonance).count
    }

    private var harmonicResonanceCount: Int {
        overlaps.filter(\.isHarmonicResonance).count
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    OctalGlyph(value: event.octalAddress, depth: harmonicDepth, color: event.color)
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
                    }
                }

                MetadataRow(title: "Thread", value: sourceTitle)
                MetadataRow(title: "Direct resonances", value: "\(sameDayResonanceCount)")
                MetadataRow(title: "Harmonics", value: "\(harmonicResonanceCount)")
            }

            Section("Overlaps") {
                if overlaps.isEmpty {
                    ContentUnavailableView("No other Saros threads", systemImage: "point.3.connected.trianglepath.dotted")
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
        if overlap.isSameDayResonance {
            return .yellow
        }
        if overlap.isHarmonicResonance {
            return .cyan
        }
        return overlap.delta >= 0 ? .green : .red
    }

    private var badgeText: String? {
        if overlap.isSameDayResonance {
            return "resonant"
        }
        if overlap.isHarmonicResonance {
            return "harmonic"
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            OctalGlyph(value: overlap.octalAddress, depth: harmonicDepth, color: color)
                .frame(width: 42, height: 42)
                .padding(5)
                .background(color.opacity(overlap.isResonance ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Saros \(overlap.saros)")
                        .font(.subheadline.weight(.semibold))
                    if let badgeText {
                        Text(badgeText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(overlap.isSameDayResonance ? .black : .white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(color, in: Capsule())
                    }
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
                if overlap.isHarmonicResonance, let halfPeriodText {
                    Text("half \(halfPeriodText)")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                }
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

    private var halfPeriodText: String? {
        guard let harmonicTargetOffset = overlap.harmonicTargetOffset else { return nil }
        return JournalFormatters.time.string(from: harmonicTargetOffset) ?? "\(Int(harmonicTargetOffset / 60))m"
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

private struct ThreadGlyphSearchView: View {
    let reading: SarosClockReading

    @State private var digits: [Int] = []

    private var selectedAddress: String {
        normalizedDigits.map(String.init).joined()
    }

    private var selectedBinIndex: Int {
        reading.binIndex(forOctalAddress: selectedAddress)
    }

    private var selectedStartDate: Date {
        reading.date(forBinIndex: selectedBinIndex)
    }

    private var selectedEndDate: Date {
        reading.date(forBinIndex: min(selectedBinIndex + 1, reading.binCount))
    }

    private var normalizedDigits: [Int] {
        let prefix = Array(digits.prefix(reading.harmonicDepth))
        if prefix.count == reading.harmonicDepth {
            return prefix
        }
        return prefix + Array(repeating: 0, count: reading.harmonicDepth - prefix.count)
    }

    var body: some View {
        VStack(spacing: 10) {
            OctalGlyph(value: selectedAddress, depth: reading.harmonicDepth)
                .frame(width: 128, height: 128)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 4) {
                ForEach(0..<reading.harmonicDepth, id: \.self) { index in
                    OctalDigitWheel(digit: digitBinding(at: index))
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 4) {
                Text(JournalFormatters.dateTime.string(from: selectedStartDate))
                    .font(.subheadline.weight(.semibold))
                Text("Until \(JournalFormatters.dateTime.string(from: selectedEndDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        }
    }

    private func syncDigitsIfNeeded() {
        guard digits.count != reading.harmonicDepth else { return }
        digits = reading.octalAddress.map { Int(String($0)) ?? 0 }
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

struct MirrorCameraView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = ThreadMirrorCameraController()
    @StateObject private var saver = CameraRollMediaSaver()
    @State private var mode: ThreadMirrorCameraMode = .vertical
    @State private var reflectionSelection: MirrorReflectionSelection = .positive
    @State private var lensPosition = 0.5
    @State private var exposureLevel = 0.5
    @State private var thresholdLevel = 0.5
    @State private var isBinaryFilterEnabled = false
    @State private var captureHoldWorkItem: DispatchWorkItem?
    @State private var isCapturePressActive = false
    @State private var didStartVideoDuringPress = false

    private let onCapturedMedia: ((MirrorCameraCapturedMedia) -> Void)?

    init(onCapturedMedia: ((MirrorCameraCapturedMedia) -> Void)? = nil) {
        self.onCapturedMedia = onCapturedMedia
    }

    var body: some View {
        GeometryReader { proxy in
            let previewSide = Self.previewSide(for: proxy.size)

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    cameraPreview(side: previewSide)
                        .padding(.top, 16)

                    Spacer(minLength: 14)

                    controlPanel
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }

                if onCapturedMedia != nil {
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
                    .padding(.top, 12)
                    .padding(.leading, 14)
                    .accessibilityLabel("Close camera")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            camera.setMirror(mode: mode, reflectionSelection: reflectionSelection)
            camera.setLensPosition(lensPosition)
            camera.setExposureLevel(exposureLevel)
            camera.setFilter(isBinaryEnabled: isBinaryFilterEnabled, threshold: thresholdLevel)
            await camera.start()
        }
        .onDisappear {
            captureHoldWorkItem?.cancel()
            if camera.isRecordingVideo {
                camera.stopVideoRecording { _ in }
            }
            camera.stop()
        }
    }

    @ViewBuilder
    private func cameraPreview(side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.06))

            if let previewImage = camera.previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()
            } else {
                ThreadCameraPlaceholderView(
                    state: camera.authorizationState,
                    errorMessage: camera.errorMessage
                )
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
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
                    camera.setExposureLevel(newValue)
                }
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

            captureControl

            cameraToolButton(
                systemImage: mode.symbolName,
                accessibilityLabel: "Toggle mirror mode"
            ) {
                mode = mode.next
                camera.setMirror(mode: mode, reflectionSelection: reflectionSelection)
            }

            cameraToolButton(
                systemImage: reflectionSelection.symbolName,
                accessibilityLabel: "Toggle reflected side"
            ) {
                reflectionSelection = reflectionSelection.next
                camera.setMirror(mode: mode, reflectionSelection: reflectionSelection)
            }
        }
    }

    private var captureControl: some View {
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
    }

    private func handleCapturePressBegan() {
        guard !isCapturePressActive else { return }
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
        guard let image = camera.captureImage(), !saver.isSaving else { return }

        if let onCapturedMedia {
            guard let data = image.jpegData(compressionQuality: 0.94) else { return }
            onCapturedMedia(MirrorCameraCapturedMedia(
                type: .symbolicPhoto,
                data: data,
                sourceURL: nil,
                fileExtension: "jpg"
            ))
            dismiss()
        } else {
            saver.save(image)
        }
    }

    private func stopVideoCapture() {
        camera.stopVideoRecording { result in
            switch result {
            case .success(let url):
                if let onCapturedMedia {
                    onCapturedMedia(MirrorCameraCapturedMedia(
                        type: .video,
                        data: nil,
                        sourceURL: url,
                        fileExtension: url.pathExtension.isEmpty ? "mov" : url.pathExtension
                    ))
                    dismiss()
                } else {
                    saver.saveVideo(at: url)
                }
            case .failure(let error):
                saver.showFailure(error.localizedDescription)
            }
        }
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

private enum ThreadMirrorCameraMode: CaseIterable, Identifiable {
    case horizontal
    case vertical
    case cross

    var id: String { symbolName }

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

private enum MirrorReflectionSelection: CaseIterable {
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

private enum MirrorCameraBackLens: CaseIterable {
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

private final class ThreadMirrorCameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var authorizationState: CameraAuthorizationState = .notDetermined
    @Published private(set) var errorMessage: String?
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .front
    @Published private(set) var backLens: MirrorCameraBackLens = .wide
    @Published private(set) var isRecordingVideo = false

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "exeligmos.thread-mirror-camera.session")
    private let videoQueue = DispatchQueue(label: "exeligmos.thread-mirror-camera.video")

    private var output: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var latestFrame: CIImage?
    private var currentDevice: AVCaptureDevice?
    private var selectedBackLens: MirrorCameraBackLens = .wide
    private var currentMode: ThreadMirrorCameraMode = .vertical
    private var currentReflectionSelection: MirrorReflectionSelection = .positive
    private var lensPosition: Double = 0.5
    private var exposureLevel: Double = 0.5
    private var isBinaryFilterEnabled = false
    private var thresholdLevel: Double = 0.5
    private var lastFrameTime: CFTimeInterval = 0
    private var videoRecorder: MirrorVideoRecorder?
    private var videoRecordingURL: URL?
    private var isAudioCaptureAuthorized = false

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
                }
            } catch {
                Task { @MainActor in
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func setMirror(mode: ThreadMirrorCameraMode, reflectionSelection: MirrorReflectionSelection) {
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
            if let currentDevice = self.currentDevice {
                self.applyExposure(to: currentDevice)
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
        previewImage
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

        videoQueue.async { [weak self] in
            guard let self else { return }
            self.videoRecordingURL = url
            self.videoRecorder = MirrorVideoRecorder(outputURL: url)
        }
    }

    @MainActor
    func stopVideoRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard isRecordingVideo else {
            completion(.failure(MirrorVideoRecorder.RecorderError.notRecording))
            return
        }

        isRecordingVideo = false
        videoQueue.async { [weak self] in
            guard let self else { return }
            guard let recorder = self.videoRecorder, let url = self.videoRecordingURL else {
                Task { @MainActor in
                    completion(.failure(MirrorVideoRecorder.RecorderError.notRecording))
                }
                return
            }

            self.videoRecorder = nil
            self.videoRecordingURL = nil
            recorder.finish { result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        completion(.success(url))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
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
        session.sessionPreset = .photo
        defer {
            session.commitConfiguration()
        }

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        audioOutput = nil

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

        if isAudioCaptureAuthorized {
            configureAudioCapture()
        }

        self.output = output
        currentDevice = device
        latestFrame = nil
        applyLensPosition(to: device)
        applyExposure(to: device)
    }

    private func configureAudioCapture() {
        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
              session.canAddInput(audioInput) else {
            return
        }
        session.addInput(audioInput)

        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(audioOutput) else { return }
        session.addOutput(audioOutput)
        self.audioOutput = audioOutput
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
        if output === audioOutput {
            videoRecorder?.appendAudio(sampleBuffer)
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        latestFrame = CIImage(cvPixelBuffer: pixelBuffer)
        renderLatestFrame(sourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    private func renderLatestFrame(force: Bool = false, sourceTime: CMTime? = nil) {
        let now = CACurrentMediaTime()
        guard force || now - lastFrameTime >= 1.0 / 15.0 else { return }
        lastFrameTime = now

        guard let latestFrame else { return }
        let square = Self.squareImage(latestFrame)
        var output = MirrorReflectionProcessor.process(
            square,
            edges: currentMode.edges(reflectionSelection: currentReflectionSelection)
        )
        if isBinaryFilterEnabled {
            output = Self.thresholdImage(output, threshold: thresholdLevel)
        }
        if let sourceTime {
            videoRecorder?.append(image: output, sourceTime: sourceTime)
        }
        guard let image = MirrorReflectionProcessor.renderedImage(
            from: output,
            edges: []
        ) else {
            return
        }

        Task { @MainActor in
            self.previewImage = image
        }
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

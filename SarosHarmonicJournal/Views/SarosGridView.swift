import SwiftUI

struct SarosGridView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    @State private var activeSeries: [ActiveSarosPhaseSeries] = []
    @State private var selectedSeries: ActiveSarosPhaseSeries?
    @State private var errorMessage: String?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 5)) { context in
            GeometryReader { geometry in
                let metrics = Self.gridMetrics(in: geometry.size)

                ZStack(alignment: .bottom) {
                    if activeSeries.isEmpty {
                        ContentUnavailableView(
                            errorMessage ?? "No active Saros series",
                            systemImage: "circle.grid.3x3"
                        )
                        .padding(.bottom, 80)
                    }

                    LazyVGrid(columns: metrics.columns, spacing: metrics.spacing) {
                        ForEach(Array(activeSeries.prefix(Self.gridCapacity))) { series in
                            if let reading = series.reading(at: context.date, harmonicDepth: harmonicDepth) {
                                Button {
                                    selectedSeries = series
                                } label: {
                                    SarosPhaseGridCell(
                                        saros: series.saros,
                                        reading: reading,
                                        date: context.date,
                                        size: metrics.cellSize
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.bottom, metrics.bottomPadding)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .task {
            loadActiveSeries()
        }
        .refreshable {
            loadActiveSeries()
        }
        .navigationDestination(item: $selectedSeries) { series in
            SarosPhaseDetailView(series: series)
        }
    }

    private static let gridColumnCount = 5
    private static let gridRowCount = 8
    private static let gridCapacity = 40

    private struct GridMetrics {
        let cellSize: CGFloat
        let spacing: CGFloat
        let horizontalPadding: CGFloat
        let bottomPadding: CGFloat

        var columns: [GridItem] {
            Array(
                repeating: GridItem(.fixed(cellSize), spacing: spacing),
                count: SarosGridView.gridColumnCount
            )
        }
    }

    private static func gridMetrics(in size: CGSize) -> GridMetrics {
        let horizontalPadding: CGFloat = 16
        let bottomPadding: CGFloat = 24
        let topBreathingRoom: CGFloat = 12
        let targetSpacing: CGFloat = 10
        let availableWidth = max(size.width - horizontalPadding * 2, 1)
        let availableHeight = max(size.height - bottomPadding - topBreathingRoom, 1)
        let widthCell = (availableWidth - targetSpacing * CGFloat(gridColumnCount - 1)) / CGFloat(gridColumnCount)
        let heightCell = (availableHeight - targetSpacing * CGFloat(gridRowCount - 1)) / CGFloat(gridRowCount)
        let cellSize = max(min(widthCell, heightCell), 34)
        let horizontalSpacing = max(
            (availableWidth - cellSize * CGFloat(gridColumnCount)) / CGFloat(max(gridColumnCount - 1, 1)),
            4
        )
        let verticalSpacing = max(
            (availableHeight - cellSize * CGFloat(gridRowCount)) / CGFloat(max(gridRowCount - 1, 1)),
            4
        )

        return GridMetrics(
            cellSize: cellSize,
            spacing: min(horizontalSpacing, verticalSpacing, 14),
            horizontalPadding: horizontalPadding,
            bottomPadding: bottomPadding
        )
    }

    @MainActor
    private func loadActiveSeries() {
        let now = Date()
        let eclipseService = services.eclipseService

        Task.detached(priority: .userInitiated) {
            let result: Result<[ActiveSarosPhaseSeries], Error> = Result {
                try eclipseService.allSarosSeries()
                    .filter { summary in
                        summary.firstEclipseDate < now && summary.lastEclipseDate > now
                    }
                    .compactMap { summary -> ActiveSarosPhaseSeries? in
                        guard let interval = try? eclipseService.previousAndNextEclipse(
                            saros: summary.saros,
                            around: now
                        ) else {
                            return nil
                        }

                        return ActiveSarosPhaseSeries(
                            summary: summary,
                            previousEclipse: interval.previous,
                            nextEclipse: interval.next
                        )
                    }
                    .sorted { $0.saros < $1.saros }
            }

            await MainActor.run {
                switch result {
                case .success(let series):
                    activeSeries = series
                    errorMessage = nil
                case .failure(let error):
                    activeSeries = []
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct ActiveSarosPhaseSeries: Identifiable, Hashable {
    let summary: SarosSeriesSummary
    let previousEclipse: Eclipse
    let nextEclipse: Eclipse

    var id: Int { saros }
    var saros: Int { summary.saros }

    func reading(at date: Date, harmonicDepth: Int) -> SarosClockReading? {
        try? SarosClockCalculator.reading(
            saros: saros,
            previous: previousEclipse,
            next: nextEclipse,
            now: date,
            harmonicDepth: JournalSettings.clampedHarmonicDepth(harmonicDepth)
        )
    }
}

private struct SarosPhaseGridCell: View {
    let saros: Int
    let reading: SarosClockReading
    let date: Date
    let size: CGFloat

    private var upcomingRarity: FlipRarity? {
        reading.rarityCountdowns(now: date)
            .filter { $0.timeUntilFlip >= 0 && $0.timeUntilFlip <= 24 * 60 * 60 && $0.rarity >= .epic }
            .sorted {
                if $0.timeUntilFlip != $1.timeUntilFlip {
                    return $0.timeUntilFlip < $1.timeUntilFlip
                }
                return $0.rarity > $1.rarity
            }.first?.rarity
    }

    private var tint: Color {
        upcomingRarity?.color ?? .white
    }

    var body: some View {
        OctalGlyph(
            value: reading.octalAddress,
            depth: reading.harmonicDepth,
            color: tint
        )
        .frame(width: size * 0.66, height: size * 0.66)
        .padding(size * 0.17)
        .background(.black.opacity(upcomingRarity == nil ? 0.18 : 0.38), in: Circle())
        .overlay {
            Circle()
                .stroke(tint.opacity(upcomingRarity == nil ? 0.24 : 0.62), lineWidth: upcomingRarity == nil ? 1 : 2)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saros \(saros), phase \(reading.octalAddress)")
    }
}

private struct SarosPhaseDetailView: View {
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    let series: ActiveSarosPhaseSeries

    @State private var selectedGlobalTimelineEvent: SarosPhaseFlipEvent?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            if let reading = series.reading(at: context.date, harmonicDepth: harmonicDepth) {
                let reference = SarosPhaseTimelineReference.upcoming(reading: reading, now: context.date)

                VStack(spacing: 0) {
                    SarosPhaseHeaderPanel(
                        reading: reading,
                        reference: reference,
                        now: context.date
                    )
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 14)

                    Divider()

                    SarosFlipEventTimelineView(
                        series: series,
                        reference: reference,
                        now: context.date,
                        onSelectEvent: { event in
                            selectedGlobalTimelineEvent = event
                        }
                    )
                }
            } else {
                ContentUnavailableView(
                    "Saros phase unavailable",
                    systemImage: "clock.badge.questionmark"
                )
            }
        }
        .navigationTitle("Saros \(series.saros)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedGlobalTimelineEvent) { event in
            SarosGlobalFlipTimelineView(
                referenceDate: event.date,
                referenceEvent: event
            )
        }
    }
}

private struct SarosPhaseHeaderPanel: View {
    let reading: SarosClockReading
    let reference: SarosPhaseTimelineReference?
    let now: Date

    private var tint: Color {
        reference?.event.rarity.color ?? .white
    }

    private var fineAddress: String {
        let bins = Self.octalPower(3)
        let value = min(max(Int(floor(reading.progressWithinBin * Double(bins))), 0), bins - 1)
        return String(value, radix: 8).leftPadded(toLength: 3, withPad: "0")
    }

    private var countdownText: String {
        guard let reference else { return "none" }
        return max(reference.event.date.timeIntervalSince(now), 0).compactDuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                OctalGlyph(
                    value: reading.octalAddress,
                    depth: reading.harmonicDepth,
                    color: tint
                )
                .frame(width: 84, height: 84)
                .padding(10)
                .background(.black.opacity(0.28), in: Circle())
                .overlay {
                    Circle()
                        .stroke(tint.opacity(0.28), lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(reference?.event.rarity.title ?? "No Duplex event")
                        .font(.headline)
                        .foregroundStyle(tint)
                    Text(countdownText)
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                    Text(reference.map { JournalFormatters.dateTime.string(from: $0.event.date) } ?? "No upcoming event")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                OctalGlyph(
                    value: fineAddress,
                    depth: 3,
                    color: tint
                )
                .frame(width: 40, height: 40)
                .padding(8)
                .background(.black.opacity(0.22), in: Circle())
                .overlay {
                    Circle()
                        .stroke(tint.opacity(0.22), lineWidth: 1)
                }
            }

            VStack(spacing: 8) {
                MetadataRow(
                    title: "Previous eclipse",
                    value: SarosPhaseFormat.eclipseSummary(reading.previousEclipse)
                )
                MetadataRow(
                    title: "Next eclipse",
                    value: SarosPhaseFormat.eclipseSummary(reading.nextEclipse)
                )
            }
        }
    }

    private static func octalPower(_ exponent: Int) -> Int {
        guard exponent > 0 else { return 1 }
        return (0..<exponent).reduce(1) { value, _ in value * 8 }
    }
}

private struct SarosFlipEventTimelineView: View {
    let series: ActiveSarosPhaseSeries
    let reference: SarosPhaseTimelineReference?
    let now: Date
    var pastLimit = 28
    var futureLimit = 28
    let onSelectEvent: (SarosPhaseFlipEvent) -> Void

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @State private var didScrollToReference = false

    private var model: SarosPhaseTimelineModel? {
        guard let reference,
              let reading = series.reading(at: reference.event.date, harmonicDepth: harmonicDepth)
        else {
            return nil
        }

        return SarosPhaseTimelineModel(
            reading: reading,
            reference: reference,
            pastLimit: pastLimit,
            futureLimit: futureLimit
        )
    }

    var body: some View {
        if let model {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear
                            .frame(height: 180)

                        ForEach(model.events) { event in
                            Button {
                                onSelectEvent(event)
                            } label: {
                                SarosPhaseTimelineRow(
                                    event: event,
                                    now: model.reference.event.date,
                                    harmonicDepth: model.reading.harmonicDepth,
                                    isReference: event.id == model.referenceID
                                )
                            }
                            .buttonStyle(.plain)
                            .id(event.id)
                        }

                        Color.clear
                            .frame(height: 180)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .onAppear {
                    scrollToReference(with: proxy, referenceID: model.referenceID)
                }
                .onChange(of: model.referenceID) { _, referenceID in
                    didScrollToReference = false
                    scrollToReference(with: proxy, referenceID: referenceID)
                }
            }
        } else {
            ContentUnavailableView("Timeline unavailable", systemImage: "timeline.selection")
        }
    }

    private func scrollToReference(with proxy: ScrollViewProxy, referenceID: String) {
        guard !didScrollToReference else { return }
        didScrollToReference = true
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.35)) {
                proxy.scrollTo(referenceID, anchor: .center)
            }
        }
    }
}

private struct SarosPhaseTimelineModel {
    let reading: SarosClockReading
    let reference: SarosPhaseTimelineReference
    let events: [SarosPhaseFlipEvent]

    var referenceID: String {
        reference.event.id
    }

    init(
        reading: SarosClockReading,
        reference: SarosPhaseTimelineReference,
        pastLimit: Int,
        futureLimit: Int
    ) {
        self.reading = reading
        self.reference = reference

        let past = Self.events(
            reading: reading,
            startIndex: reference.event.binIndex - 1,
            direction: .backward,
            limit: pastLimit
        ).reversed()
        let future = Self.events(
            reading: reading,
            startIndex: reference.event.binIndex,
            direction: .forward,
            limit: futureLimit
        )
        events = Array(past) + [reference.event] + future
    }

    private enum Direction {
        case forward
        case backward
    }

    static func upcomingReference(reading: SarosClockReading, now: Date) -> SarosPhaseTimelineReference? {
        events(
            reading: reading,
            startIndex: reading.binIndex,
            direction: .forward,
            limit: 1
        )
        .first
        .map(SarosPhaseTimelineReference.init(event:))
    }

    private static func events(
        reading: SarosClockReading,
        startIndex: Int,
        direction: Direction,
        limit: Int
    ) -> [SarosPhaseFlipEvent] {
        var eventsByBin: [Int: SarosPhaseFlipEvent] = [:]

        for rarity in FlipRarity.eventRarities(for: reading.harmonicDepth) where rarity >= .epic {
            let firstBin: Int?
            switch direction {
            case .forward:
                firstBin = reading.nextQualifiedFlipBin(after: startIndex, rarity: rarity, exact: true)
            case .backward:
                firstBin = reading.previousQualifiedFlipBin(atOrBefore: startIndex, rarity: rarity, exact: true)
            }

            var bin = firstBin
            var perRarityCount = 0
            while let currentBin = bin,
                  currentBin > 0,
                  currentBin < reading.binCount,
                  perRarityCount < limit
            {
                let event = SarosPhaseFlipEvent(
                    saros: reading.saros,
                    binIndex: currentBin,
                    date: reading.date(forBinIndex: currentBin),
                    octalAddress: reading.octalAddress(forBinIndex: currentBin),
                    harmonicDepth: reading.harmonicDepth,
                    rarity: rarity
                )

                if let existing = eventsByBin[currentBin] {
                    if event.rarity > existing.rarity {
                        eventsByBin[currentBin] = event
                    }
                } else {
                    eventsByBin[currentBin] = event
                }

                perRarityCount += 1

                switch direction {
                case .forward:
                    let nextBin = reading.nextQualifiedFlipBin(after: currentBin, rarity: rarity, exact: true)
                    guard let nextBin, nextBin > currentBin else {
                        bin = nil
                        continue
                    }
                    bin = nextBin
                case .backward:
                    let previousBin = reading.previousQualifiedFlipBin(atOrBefore: currentBin - 1, rarity: rarity, exact: true)
                    guard let previousBin, previousBin < currentBin else {
                        bin = nil
                        continue
                    }
                    bin = previousBin
                }
            }
        }

        let sorted = eventsByBin.values.sorted {
            switch direction {
            case .forward:
                if $0.date != $1.date {
                    return $0.date < $1.date
                }
            case .backward:
                if $0.date != $1.date {
                    return $0.date > $1.date
                }
            }
            return $0.rarity > $1.rarity
        }

        return Array(sorted.prefix(limit))
    }
}

private struct SarosPhaseTimelineReference: Identifiable, Hashable {
    let event: SarosPhaseFlipEvent

    var id: String { event.id }

    static func upcoming(reading: SarosClockReading, now: Date) -> SarosPhaseTimelineReference? {
        SarosPhaseTimelineModel.upcomingReference(reading: reading, now: now)
    }
}

private struct SarosPhaseFlipEvent: Identifiable, Hashable {
    let saros: Int
    let binIndex: Int
    let date: Date
    let octalAddress: String
    let harmonicDepth: Int
    let rarity: FlipRarity

    var id: String {
        "\(saros)-\(binIndex)-\(rarity.id)"
    }
}

private struct SarosPhaseTimelineRow: View {
    let event: SarosPhaseFlipEvent
    let now: Date
    let harmonicDepth: Int
    let isReference: Bool

    private var delta: TimeInterval {
        event.date.timeIntervalSince(now)
    }

    private var deltaText: String {
        if delta >= 0 {
            return delta.compactDuration
        }
        return "\((-delta).compactDuration) ago"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(JournalFormatters.date.string(from: event.date))
                    .font(.caption2.weight(.semibold))
                Text(SarosPhaseFormat.time.string(from: event.date))
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(isReference ? event.rarity.color : .secondary)
            .frame(width: 78, alignment: .trailing)

            ZStack {
                Rectangle()
                    .fill(event.rarity.color.opacity(0.22))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)

                OctalGlyph(
                    value: event.octalAddress,
                    depth: harmonicDepth,
                    color: event.rarity.color
                )
                .frame(width: isReference ? 50 : 38, height: isReference ? 50 : 38)
                .padding(isReference ? 8 : 5)
                .background(.black.opacity(isReference ? 0.42 : 0.18), in: Circle())
                .overlay {
                    Circle()
                        .stroke(event.rarity.color.opacity(isReference ? 0.7 : 0.28), lineWidth: isReference ? 2 : 1)
                }
            }
            .frame(width: 70)

            VStack(alignment: .leading, spacing: 5) {
                Text(event.rarity.title)
                    .font(isReference ? .headline : .subheadline.weight(.semibold))
                    .foregroundStyle(event.rarity.color)
                Text(deltaText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isReference ? event.rarity.color : .secondary)
                    .contentTransition(.numericText())
                Text(event.octalAddress)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: isReference ? 96 : 82)
        .padding(.horizontal, 10)
        .background(
            isReference ? event.rarity.color.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
    }
}

fileprivate struct SarosFlipDayDistribution: Hashable {
    let duplexCount: Int
    let simplexCount: Int
    let nihilCount: Int
    let containsOmegaNihil: Bool

    var totalFlipCount: Int {
        duplexCount + simplexCount + nihilCount
    }

    var isVoid: Bool {
        totalFlipCount == 0
    }

    init(events: [SarosGlobalFlipEvent]) {
        duplexCount = events.filter { $0.rarity.baseRarity == .epic }.count
        simplexCount = events.filter { $0.rarity.baseRarity == .legendary }.count
        nihilCount = events.filter { $0.rarity.baseRarity == .mythic }.count
        containsOmegaNihil = events.contains { $0.rarity == .mythicDigit(7) }
    }
}

fileprivate struct SarosFlipMonthDistribution: Hashable {
    var duplexCount = 0
    var simplexCount = 0
    var nihilCount = 0
    var voidDayCount = 0
    var containsOmegaNihil = false

    mutating func add(day distribution: SarosFlipDayDistribution) {
        duplexCount += distribution.duplexCount
        simplexCount += distribution.simplexCount
        nihilCount += distribution.nihilCount
        if distribution.isVoid {
            voidDayCount += 1
        }
        containsOmegaNihil = containsOmegaNihil || distribution.containsOmegaNihil
    }
}

actor SarosFlipDistributionStore {
    private var monthCache: [Int: [String: SarosFlipMonthDistribution]] = [:]
    private var dayCache: [Int: [Int: SarosFlipDayDistribution]] = [:]
    private var prewarmingDepths: Set<Int> = []

    func prewarm(
        around date: Date,
        harmonicDepth rawHarmonicDepth: Int,
        eclipseService: any EclipseService
    ) async {
        let harmonicDepth = JournalSettings.clampedHarmonicDepth(rawHarmonicDepth)
        guard !prewarmingDepths.contains(harmonicDepth) else { return }
        prewarmingDepths.insert(harmonicDepth)

        _ = monthDistributions(
            for: SarosGlobalTimelineMonth.months(around: date),
            harmonicDepth: harmonicDepth,
            eclipseService: eclipseService
        )
        prewarmingDepths.remove(harmonicDepth)
    }

    fileprivate func monthDistributions(
        for months: [SarosGlobalTimelineMonth],
        harmonicDepth rawHarmonicDepth: Int,
        eclipseService: any EclipseService
    ) -> [String: SarosFlipMonthDistribution] {
        let harmonicDepth = JournalSettings.clampedHarmonicDepth(rawHarmonicDepth)
        let cachedMonths = monthCache[harmonicDepth] ?? [:]
        let missingMonths = months.filter { cachedMonths[$0.id] == nil }

        if !missingMonths.isEmpty,
           let computed = try? computeDistributions(
            for: missingMonths,
            harmonicDepth: harmonicDepth,
            eclipseService: eclipseService
           )
        {
            monthCache[harmonicDepth, default: [:]].merge(computed.months) { _, new in new }
            dayCache[harmonicDepth, default: [:]].merge(computed.days) { _, new in new }
        }

        let currentMonths = monthCache[harmonicDepth] ?? [:]
        return Dictionary(uniqueKeysWithValues: months.compactMap { month in
            currentMonths[month.id].map { (month.id, $0) }
        })
    }

    fileprivate func dayDistribution(
        for day: Date,
        harmonicDepth rawHarmonicDepth: Int
    ) -> SarosFlipDayDistribution? {
        let harmonicDepth = JournalSettings.clampedHarmonicDepth(rawHarmonicDepth)
        return dayCache[harmonicDepth]?[SarosGlobalTimelineBuilder.dayKey(for: day)]
    }

    private func computeDistributions(
        for months: [SarosGlobalTimelineMonth],
        harmonicDepth: Int,
        eclipseService: any EclipseService
    ) throws -> (
        months: [String: SarosFlipMonthDistribution],
        days: [Int: SarosFlipDayDistribution]
    ) {
        let summaries = try eclipseService.allSarosSeries()
            .sorted { $0.saros < $1.saros }
        var monthDistributions: [String: SarosFlipMonthDistribution] = [:]
        var dayDistributions: [Int: SarosFlipDayDistribution] = [:]

        for month in months {
            let eventsByDay = SarosGlobalTimelineBuilder.eventsByDay(
                in: month.dateInterval,
                summaries: summaries,
                eclipseService: eclipseService,
                harmonicDepth: harmonicDepth
            )
            var monthDistribution = SarosFlipMonthDistribution()

            for day in month.days {
                let key = SarosGlobalTimelineBuilder.dayKey(for: day)
                let dayDistribution = SarosFlipDayDistribution(events: eventsByDay[key] ?? [])
                dayDistributions[key] = dayDistribution
                monthDistribution.add(day: dayDistribution)
            }

            monthDistributions[month.id] = monthDistribution
        }

        return (monthDistributions, dayDistributions)
    }
}

private struct SarosGlobalFlipTimelineView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    let referenceDate: Date
    let referenceEvent: SarosPhaseFlipEvent?

    @State private var selectedMonth: SarosGlobalTimelineMonth?
    @State private var monthDistributions: [String: SarosFlipMonthDistribution] = [:]
    @State private var didScrollToReferenceMonth = false

    private var months: [SarosGlobalTimelineMonth] {
        SarosGlobalTimelineMonth.months(around: referenceDate)
    }

    private var referenceMonthID: String {
        SarosGlobalTimelineMonth.containing(referenceDate).id
    }

    private var firstMonthID: String? {
        months.first?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    ForEach(months) { month in
                        if month.isFirstMonthOfYear || month.id == firstMonthID {
                            SarosGlobalYearDivider(year: month.year)
                                .id(month.yearDividerID)
                        }

                        Button {
                            selectedMonth = month
                        } label: {
                            SarosGlobalMonthRow(
                                month: month,
                                distribution: monthDistributions[month.id],
                                isReference: month.id == referenceMonthID
                            )
                        }
                        .buttonStyle(.plain)
                        .id(month.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .navigationTitle("Saros calendar")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: harmonicDepth) {
                loadMonthDistributions()
                scrollToReferenceMonth(with: proxy)
            }
        }
        .navigationDestination(item: $selectedMonth) { month in
            SarosGlobalMonthTimelineView(
                month: month,
                referenceDate: referenceDate,
                referenceEvent: referenceEvent
            )
        }
    }

    private func scrollToReferenceMonth(with proxy: ScrollViewProxy) {
        guard !didScrollToReferenceMonth else { return }
        didScrollToReferenceMonth = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.snappy(duration: 0.35)) {
                proxy.scrollTo(referenceMonthID, anchor: .center)
            }
        }
    }

    private func loadMonthDistributions() {
        let months = months
        let harmonicDepth = harmonicDepth
        let eclipseService = services.eclipseService
        let store = services.sarosFlipDistributionStore

        Task {
            monthDistributions = await store.monthDistributions(
                for: months,
                harmonicDepth: harmonicDepth,
                eclipseService: eclipseService
            )
        }
    }
}

private struct SarosGlobalMonthTimelineView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    let referenceDate: Date
    let referenceEvent: SarosPhaseFlipEvent?

    @State private var visibleMonth: SarosGlobalTimelineMonth
    @State private var dayEvents: [Int: [SarosGlobalFlipEvent]] = [:]
    @State private var isLoadingEvents = false
    @State private var didScrollToReference = false
    @State private var errorMessage: String?
    @State private var pendingScrollTarget: SarosMonthScrollTarget = .reference

    init(
        month: SarosGlobalTimelineMonth,
        referenceDate: Date,
        referenceEvent: SarosPhaseFlipEvent?
    ) {
        self.referenceDate = referenceDate
        self.referenceEvent = referenceEvent
        _visibleMonth = State(initialValue: month)
    }

    private var days: [Date] {
        visibleMonth.days
    }

    private var referenceDay: Date {
        Self.calendar.startOfDay(for: referenceDate)
    }

    private var isReferenceMonth: Bool {
        Self.calendar.isDate(referenceDate, equalTo: visibleMonth.startDate, toGranularity: .month)
    }

    private var referenceGlobalEvent: SarosGlobalFlipEvent? {
        guard isReferenceMonth else { return nil }
        return referenceEvent.map(SarosGlobalFlipEvent.init(event:))
    }

    private var referenceScrollID: String {
        referenceGlobalEvent?.id ?? Self.referenceMarkerID
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    SarosAdjacentMonthButton(month: visibleMonth.previous, direction: .previous) {
                        transition(to: visibleMonth.previous, scrollTarget: .end)
                    }
                    .id("previous-\(visibleMonth.previous.id)")

                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        SarosGlobalDaySection(
                            offset: dayOffset(fromReferenceTo: day),
                            day: day,
                            events: dayEvents[index],
                            referenceDate: referenceDate,
                            referenceEvent: referenceGlobalEvent
                        )
                        .id(dayID(for: day))
                    }

                    SarosAdjacentMonthButton(month: visibleMonth.next, direction: .next) {
                        transition(to: visibleMonth.next, scrollTarget: .start)
                    }
                    .id("next-\(visibleMonth.next.id)")
                }
                .padding(.horizontal)
            }
            .overlay {
                if let errorMessage {
                    ContentUnavailableView(errorMessage, systemImage: "timeline.selection")
                } else if isLoadingEvents && dayEvents.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle(visibleMonth.title)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: "\(visibleMonth.id)-\(harmonicDepth)") {
                loadFixedTimeline()
                scrollToReference(with: proxy)
            }
            .onChange(of: isLoadingEvents) { _, loading in
                guard !loading else { return }
                scrollToReference(with: proxy, force: true)
            }
        }
    }

    private func dayOffset(fromReferenceTo day: Date) -> Int {
        Self.calendar.dateComponents([.day], from: referenceDay, to: day).day ?? 0
    }

    private func dayID(for day: Date) -> String {
        "global-day-\(Int(day.timeIntervalSince1970))"
    }

    private func loadFixedTimeline() {
        isLoadingEvents = true
        errorMessage = nil
        dayEvents.removeAll()

        let eclipseService = services.eclipseService
        let harmonicDepth = harmonicDepth
        let days = days
        let monthInterval = visibleMonth.dateInterval

        Task.detached(priority: .userInitiated) {
            let result: Result<[Int: [SarosGlobalFlipEvent]], Error> = Result {
                let summaries = try eclipseService.allSarosSeries()
                    .sorted { $0.saros < $1.saros }
                let eventsByDay = SarosGlobalTimelineBuilder.eventsByDay(
                    in: monthInterval,
                    summaries: summaries,
                    eclipseService: eclipseService,
                    harmonicDepth: harmonicDepth
                )

                return Dictionary(uniqueKeysWithValues: days.enumerated().map { index, day in
                    return (
                        index,
                        eventsByDay[SarosGlobalTimelineBuilder.dayKey(for: day)] ?? []
                    )
                })
            }

            await MainActor.run {
                isLoadingEvents = false
                switch result {
                case .success(let eventsByOffset):
                    dayEvents = eventsByOffset
                    errorMessage = nil
                case .failure(let error):
                    dayEvents = [:]
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func transition(to month: SarosGlobalTimelineMonth, scrollTarget: SarosMonthScrollTarget) {
        pendingScrollTarget = scrollTarget
        didScrollToReference = false
        visibleMonth = month
    }

    private func scrollToReference(with proxy: ScrollViewProxy, force: Bool = false) {
        let target = pendingScrollTarget
        guard force || !didScrollToReference else { return }
        didScrollToReference = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let id: String?
            let anchor: UnitPoint
            switch target {
            case .reference:
                guard isReferenceMonth else { return }
                id = referenceScrollID
                anchor = .center
            case .start:
                id = days.first.map(dayID(for:))
                anchor = .top
            case .end:
                id = days.last.map(dayID(for:))
                anchor = .bottom
            }

            guard let id else { return }
            withAnimation(.snappy(duration: 0.35)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }

    fileprivate static let referenceMarkerID = "global-reference-marker"

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()
}

private enum SarosMonthScrollTarget {
    case reference
    case start
    case end
}

private enum SarosAdjacentMonthDirection {
    case previous
    case next

    var symbolName: String {
        switch self {
        case .previous: "chevron.up"
        case .next: "chevron.down"
        }
    }
}

private struct SarosAdjacentMonthButton: View {
    let month: SarosGlobalTimelineMonth
    let direction: SarosAdjacentMonthDirection
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: direction.symbolName)
                    .font(.caption.weight(.bold))
                Text(month.title)
                    .font(.caption.weight(.semibold))
                Text(month.subtitle)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.primary)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }
}

private struct SarosGlobalTimelineMonth: Identifiable, Hashable {
    let startDate: Date
    let year: Int
    let month: Int

    var id: String {
        String(format: "%04d-%02d", year, month)
    }

    var yearDividerID: String {
        "year-\(year)"
    }

    var isFirstMonthOfYear: Bool {
        month == 1
    }

    var title: String {
        Self.monthTitleFormatter.string(from: startDate)
    }

    var subtitle: String {
        Self.monthSubtitleFormatter.string(from: startDate)
    }

    var days: [Date] {
        guard let range = Self.calendar.range(of: .day, in: .month, for: startDate) else {
            return [startDate]
        }

        return range.compactMap { day in
            Self.calendar.date(byAdding: .day, value: day - 1, to: startDate)
        }
    }

    var dateInterval: DateInterval {
        Self.calendar.dateInterval(of: .month, for: startDate)
            ?? DateInterval(start: startDate, duration: 31 * 86_400)
    }

    var previous: SarosGlobalTimelineMonth {
        offset(by: -1)
    }

    var next: SarosGlobalTimelineMonth {
        offset(by: 1)
    }

    static func containing(_ date: Date) -> SarosGlobalTimelineMonth {
        make(from: calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date))
    }

    static func months(around date: Date) -> [SarosGlobalTimelineMonth] {
        let reference = containing(date).startDate
        return (-120...120).compactMap { offset in
            guard let monthStart = calendar.date(byAdding: .month, value: offset, to: reference) else {
                return nil
            }
            return make(from: monthStart)
        }
    }

    private func offset(by monthOffset: Int) -> SarosGlobalTimelineMonth {
        guard let date = Self.calendar.date(byAdding: .month, value: monthOffset, to: startDate) else {
            return self
        }
        return Self.make(from: date)
    }

    private static func make(from date: Date) -> SarosGlobalTimelineMonth {
        let components = calendar.dateComponents([.year, .month], from: date)
        return SarosGlobalTimelineMonth(
            startDate: calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date),
            year: components.year ?? 0,
            month: components.month ?? 1
        )
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL"
        return formatter
    }()

    private static let monthSubtitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter
    }()
}

private struct SarosGlobalYearDivider: View {
    let year: Int

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(.secondary.opacity(0.32))
                .frame(height: 1)

            Text("\(year)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Rectangle()
                .fill(.secondary.opacity(0.32))
                .frame(height: 1)
        }
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

private struct SarosGlobalMonthRow: View {
    let month: SarosGlobalTimelineMonth
    let distribution: SarosFlipMonthDistribution?
    let isReference: Bool

    private var tint: Color {
        if distribution?.containsOmegaNihil == true {
            return .red
        }
        return isReference ? .primary : .secondary
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(month.title)
                    .font(.headline)
                    .foregroundStyle(tint)
                Text(month.subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let distribution {
                HStack(spacing: 5) {
                    SarosGlobalMonthCountTag(
                        count: distribution.duplexCount,
                        color: FlipRarity.epic.color
                    )
                    SarosGlobalMonthCountTag(
                        count: distribution.simplexCount,
                        color: FlipRarity.legendary.color
                    )
                    SarosGlobalMonthCountTag(
                        count: distribution.nihilCount,
                        color: FlipRarity.mythic.color
                    )
                    SarosGlobalMonthCountTag(
                        count: distribution.voidDayCount,
                        color: .white
                    )
                }
            }

            if isReference {
                Text("reference")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 64)
        .padding(.horizontal, 14)
        .background(
            distribution?.containsOmegaNihil == true
                ? Color.red.opacity(0.14)
                : (isReference ? Color.white.opacity(0.08) : Color.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
    }
}

private struct SarosGlobalMonthCountTag: View {
    let count: Int
    let color: Color

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(color.opacity(0.12), in: Capsule())
        }
    }
}

private struct SarosGlobalDaySection: View {
    let offset: Int
    let day: Date
    let events: [SarosGlobalFlipEvent]?
    let referenceDate: Date
    let referenceEvent: SarosGlobalFlipEvent?

    private var isReferenceDay: Bool {
        SarosGlobalTimelineBuilder.calendar.isDate(day, inSameDayAs: referenceDate)
    }

    private var visibleEvents: [SarosGlobalFlipEvent] {
        var values = events ?? []
        if let referenceEvent,
           isReferenceDay,
           !values.contains(where: { $0.id == referenceEvent.id })
        {
            values.append(referenceEvent)
        }
        return values.sorted {
            if $0.date != $1.date {
                return $0.date < $1.date
            }
            if $0.saros != $1.saros {
                return $0.saros < $1.saros
            }
            return $0.rarity > $1.rarity
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(SarosPhaseFormat.dayTitle.string(from: day))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isReferenceDay ? .primary : .secondary)
                    .frame(width: 78, alignment: .trailing)

                Rectangle()
                    .fill(.secondary.opacity(0.28))
                    .frame(height: 1)

                Text(offset == 0 ? "reference" : "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)
            }
            .padding(.vertical, 8)

            let rows = visibleEvents
            if events == nil {
                Color.clear
                    .frame(height: 56)
            } else if rows.isEmpty {
                SarosGlobalVoidRow(day: day, referenceDate: referenceDate, isReference: isReferenceDay)
                    .id(isReferenceDay ? SarosGlobalMonthTimelineView.referenceMarkerID : "void-\(Int(day.timeIntervalSince1970))")
            } else {
                ForEach(rows) { event in
                    SarosGlobalFlipRow(
                        event: event,
                        referenceDate: referenceDate,
                        isReference: event.id == referenceEvent?.id
                    )
                    .id(event.id)
                }

                if isReferenceDay, referenceEvent == nil {
                    SarosGlobalReferenceRow(referenceDate: referenceDate)
                        .id(SarosGlobalMonthTimelineView.referenceMarkerID)
                }
            }
        }
    }
}

private struct SarosGlobalVoidRow: View {
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    let day: Date
    let referenceDate: Date
    let isReference: Bool

    private var zeroAddress: String {
        String(repeating: "0", count: JournalSettings.clampedHarmonicDepth(harmonicDepth))
    }

    private var delta: TimeInterval {
        day.timeIntervalSince(SarosGlobalTimelineBuilder.calendar.startOfDay(for: referenceDate))
    }

    private var deltaText: String {
        if isReference {
            return "reference"
        }
        if delta >= 0 {
            return delta.compactDuration
        }
        return "\((-delta).compactDuration) ago"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(SarosPhaseFormat.dayTitle.string(from: day))
                    .font(.caption2.weight(.semibold))
                Text("00:00")
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .frame(width: 78, alignment: .trailing)

            ZStack {
                Rectangle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)

                OctalGlyph(
                    value: zeroAddress,
                    depth: JournalSettings.clampedHarmonicDepth(harmonicDepth),
                    color: .white
                )
                .frame(width: isReference ? 48 : 36, height: isReference ? 48 : 36)
                .padding(isReference ? 8 : 6)
                .background(.black.opacity(isReference ? 0.34 : 0.16), in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(isReference ? 0.45 : 0.22), lineWidth: isReference ? 2 : 1)
                }
            }
            .frame(width: 70)

            VStack(alignment: .leading, spacing: 4) {
                Text("Void")
                    .font(isReference ? .headline : .subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(deltaText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: isReference ? 92 : 76)
        .padding(.horizontal, 10)
        .background(
            isReference ? Color.white.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

private struct SarosGlobalFlipRow: View {
    let event: SarosGlobalFlipEvent
    let referenceDate: Date
    let isReference: Bool

    private var delta: TimeInterval {
        event.date.timeIntervalSince(referenceDate)
    }

    private var deltaText: String {
        if isReference {
            return "reference"
        }
        if delta >= 0 {
            return delta.compactDuration
        }
        return "\((-delta).compactDuration) ago"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(SarosPhaseFormat.dayTitle.string(from: event.date))
                    .font(.caption2.weight(.semibold))
                Text(SarosPhaseFormat.time.string(from: event.date))
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(isReference ? event.rarity.color : .secondary)
            .frame(width: 78, alignment: .trailing)

            ZStack {
                Rectangle()
                    .fill(event.rarity.color.opacity(0.22))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)

                OctalGlyph(
                    value: event.octalAddress,
                    depth: event.harmonicDepth,
                    color: event.rarity.color
                )
                .frame(width: isReference ? 48 : 36, height: isReference ? 48 : 36)
                .padding(isReference ? 8 : 6)
                .background(.black.opacity(isReference ? 0.42 : 0.2), in: Circle())
                .overlay {
                    Circle()
                        .stroke(event.rarity.color.opacity(isReference ? 0.7 : 0.28), lineWidth: isReference ? 2 : 1)
                }
            }
            .frame(width: 70)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(event.saros)")
                    .font(isReference ? .headline.monospacedDigit() : .subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(event.rarity.color)
                Text(deltaText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isReference ? event.rarity.color : .secondary)
                Text(event.octalAddress)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: isReference ? 92 : 76)
        .padding(.horizontal, 10)
        .background(
            isReference ? event.rarity.color.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

private struct SarosGlobalReferenceRow: View {
    let referenceDate: Date

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(SarosPhaseFormat.dayTitle.string(from: referenceDate))
                    .font(.caption2.weight(.semibold))
                Text(SarosPhaseFormat.time.string(from: referenceDate))
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.primary)
            .frame(width: 78, alignment: .trailing)

            ZStack {
                Rectangle()
                    .fill(.secondary.opacity(0.25))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)

                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
            }
            .frame(width: 70)

            Text("reference")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .frame(minHeight: 70)
        .padding(.horizontal, 10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SarosGlobalFlipEvent: Identifiable, Hashable {
    let saros: Int
    let binIndex: Int
    let date: Date
    let octalAddress: String
    let harmonicDepth: Int
    let rarity: FlipRarity

    var id: String {
        "\(saros)-\(binIndex)-\(Int(date.timeIntervalSince1970))-\(rarity.id)"
    }

    init(
        saros: Int,
        binIndex: Int,
        date: Date,
        octalAddress: String,
        harmonicDepth: Int,
        rarity: FlipRarity
    ) {
        self.saros = saros
        self.binIndex = binIndex
        self.date = date
        self.octalAddress = octalAddress
        self.harmonicDepth = harmonicDepth
        self.rarity = rarity
    }

    init(event: SarosPhaseFlipEvent) {
        self.init(
            saros: event.saros,
            binIndex: event.binIndex,
            date: event.date,
            octalAddress: event.octalAddress,
            harmonicDepth: event.harmonicDepth,
            rarity: event.rarity
        )
    }
}

private enum SarosGlobalTimelineBuilder {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    static func events(
        on day: Date,
        summaries: [SarosSeriesSummary],
        eclipseService: any EclipseService,
        harmonicDepth rawHarmonicDepth: Int
    ) -> [SarosGlobalFlipEvent] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return events(
            in: DateInterval(start: start, end: end),
            summaries: summaries,
            eclipseService: eclipseService,
            harmonicDepth: rawHarmonicDepth
        )
    }

    static func eventsByDay(
        in interval: DateInterval,
        summaries: [SarosSeriesSummary],
        eclipseService: any EclipseService,
        harmonicDepth rawHarmonicDepth: Int
    ) -> [Int: [SarosGlobalFlipEvent]] {
        Dictionary(grouping: events(
            in: interval,
            summaries: summaries,
            eclipseService: eclipseService,
            harmonicDepth: rawHarmonicDepth
        )) { event in
            dayKey(for: event.date)
        }
    }

    static func dayKey(for date: Date) -> Int {
        Int(calendar.startOfDay(for: date).timeIntervalSince1970)
    }

    static func events(
        in interval: DateInterval,
        summaries: [SarosSeriesSummary],
        eclipseService: any EclipseService,
        harmonicDepth rawHarmonicDepth: Int
    ) -> [SarosGlobalFlipEvent] {
        let harmonicDepth = JournalSettings.clampedHarmonicDepth(rawHarmonicDepth)
        let start = interval.start
        let end = interval.end
        var eventsByBin: [String: SarosGlobalFlipEvent] = [:]

        for summary in summaries where summary.firstEclipseDate < end && summary.lastEclipseDate > start {
            let intervals = candidateIntervals(
                summary: summary,
                start: start,
                end: end,
                eclipseService: eclipseService
            )

            for interval in intervals {
                guard let reading = try? SarosClockCalculator.reading(
                    saros: summary.saros,
                    previous: interval.previous,
                    next: interval.next,
                    now: max(start, interval.previous.date),
                    harmonicDepth: harmonicDepth
                ) else {
                    continue
                }

                appendBoundaryEventIfNeeded(
                    date: interval.previous.date,
                    reading: reading,
                    start: start,
                    end: end,
                    eventsByBin: &eventsByBin
                )
                appendBoundaryEventIfNeeded(
                    date: interval.next.date,
                    reading: reading,
                    start: start,
                    end: end,
                    eventsByBin: &eventsByBin
                )

                for rarity in FlipRarity.eventRarities(for: harmonicDepth) where rarity >= .epic {
                    var bin = firstCandidateBin(reading: reading, rarity: rarity)
                    var safetyCount = 0
                    while let currentBin = bin,
                          currentBin > 0,
                          currentBin < reading.binCount,
                          safetyCount < 256
                    {
                        safetyCount += 1
                        let date = reading.date(forBinIndex: currentBin)
                        if date >= end { break }

                        if date >= start {
                            let event = SarosGlobalFlipEvent(
                                saros: reading.saros,
                                binIndex: currentBin,
                                date: date,
                                octalAddress: reading.octalAddress(forBinIndex: currentBin),
                                harmonicDepth: harmonicDepth,
                                rarity: rarity
                            )
                            upsert(event, into: &eventsByBin)
                        }

                        let nextBin = reading.nextQualifiedFlipBin(after: currentBin, rarity: rarity, exact: true)
                        guard let nextBin, nextBin > currentBin else {
                            break
                        }
                        bin = nextBin
                    }
                }
            }
        }

        return eventsByBin.values.sorted {
            if $0.date != $1.date {
                return $0.date < $1.date
            }
            if $0.saros != $1.saros {
                return $0.saros < $1.saros
            }
            return $0.rarity > $1.rarity
        }
    }

    private static func appendBoundaryEventIfNeeded(
        date: Date,
        reading: SarosClockReading,
        start: Date,
        end: Date,
        eventsByBin: inout [String: SarosGlobalFlipEvent]
    ) {
        guard date >= start, date < end else { return }

        let event = SarosGlobalFlipEvent(
            saros: reading.saros,
            binIndex: reading.binCount,
            date: date,
            octalAddress: String(repeating: "0", count: reading.harmonicDepth),
            harmonicDepth: reading.harmonicDepth,
            rarity: .mythicDigit(7)
        )
        upsert(event, into: &eventsByBin)
    }

    private static func upsert(
        _ event: SarosGlobalFlipEvent,
        into eventsByBin: inout [String: SarosGlobalFlipEvent]
    ) {
        let key = "\(event.saros)-\(Int(event.date.timeIntervalSince1970))"
        if let existing = eventsByBin[key] {
            if event.rarity > existing.rarity {
                eventsByBin[key] = event
            }
        } else {
            eventsByBin[key] = event
        }
    }

    private static func candidateIntervals(
        summary: SarosSeriesSummary,
        start: Date,
        end: Date,
        eclipseService: any EclipseService
    ) -> [SarosInterval] {
        let duration = end.timeIntervalSince(start)
        let probes = [
            start,
            start.addingTimeInterval(duration / 2),
            end.addingTimeInterval(-1)
        ]

        var seen = Set<String>()
        var intervals: [SarosInterval] = []

        for probe in probes {
            guard let interval = try? eclipseService.previousAndNextEclipse(
                saros: summary.saros,
                around: probe
            ) else {
                continue
            }

            let key = "\(interval.previous.id)-\(interval.next.id)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            intervals.append(interval)
        }

        return intervals
    }

    private static func firstCandidateBin(reading: SarosClockReading, rarity: FlipRarity) -> Int? {
        if let previous = reading.previousQualifiedFlipBin(atOrBefore: reading.binIndex, rarity: rarity, exact: true),
           reading.date(forBinIndex: previous) >= reading.date(forBinIndex: reading.binIndex)
        {
            return previous
        }
        return reading.nextQualifiedFlipBin(after: max(reading.binIndex - 1, -1), rarity: rarity, exact: true)
    }
}

private enum SarosPhaseFormat {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let dayTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    static func eclipseSummary(_ eclipse: Eclipse) -> String {
        "\(JournalFormatters.date.string(from: eclipse.date)) · \(eclipse.displayTypeLabel)"
    }
}

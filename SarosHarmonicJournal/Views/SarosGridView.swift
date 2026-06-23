import SwiftUI

struct SarosGridView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    @State private var activeSeries: [ActiveSarosPhaseSeries] = []
    @State private var selectedSeries: ActiveSarosPhaseSeries?
    @State private var selectedWaveFlip: SarosGridNearestFlip?
    @State private var errorMessage: String?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 5)) { context in
            GeometryReader { geometry in
                let metrics = Self.gridMetrics(in: geometry.size)
                let nearestFlip = nearestFlip(at: context.date)

                ZStack(alignment: .bottom) {
                    if activeSeries.isEmpty {
                        ContentUnavailableView(
                            errorMessage ?? "No active Saros series",
                            systemImage: "circle.grid.3x3"
                        )
                        .padding(.bottom, 80)
                    }

                    VStack {
                        if let nearestFlip {
                            Button {
                                selectedWaveFlip = nearestFlip
                            } label: {
                                SarosGridNearestFlipPanel(flip: nearestFlip)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, metrics.horizontalPadding)
                            .padding(.top, 12)
                        }

                        Spacer(minLength: 0)
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
                                        size: metrics.cellSize,
                                        highlightRarity: nearestFlip?.saros == series.saros ? nearestFlip?.rarity : nil
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
        .navigationDestination(item: $selectedWaveFlip) { flip in
            SarosSpikeWaveTimelineView(flip: flip)
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

    private func nearestFlip(at date: Date) -> SarosGridNearestFlip? {
        activeSeries.compactMap { series -> SarosGridNearestFlip? in
            guard let reading = series.reading(at: date, harmonicDepth: harmonicDepth),
                  let countdown = reading.rarityCountdowns(now: date)
                .filter({ $0.timeUntilFlip >= 0 && $0.rarity >= .epic })
                .min(by: { lhs, rhs in
                    if lhs.timeUntilFlip != rhs.timeUntilFlip {
                        return lhs.timeUntilFlip < rhs.timeUntilFlip
                    }
                    return lhs.rarity > rhs.rarity
                })
            else {
                return nil
            }

            return SarosGridNearestFlip(
                saros: series.saros,
                rarity: countdown.rarity,
                octalAddress: countdown.targetOctalAddress,
                harmonicDepth: reading.harmonicDepth,
                date: countdown.flipDate,
                timeUntil: countdown.timeUntilFlip,
                observedAt: date
            )
        }
        .min { lhs, rhs in
            if lhs.timeUntil != rhs.timeUntil {
                return lhs.timeUntil < rhs.timeUntil
            }
            return lhs.rarity > rhs.rarity
        }
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

private struct SarosGridNearestFlip: Identifiable, Hashable {
    let saros: Int
    let rarity: FlipRarity
    let octalAddress: String
    let harmonicDepth: Int
    let date: Date
    let timeUntil: TimeInterval
    let observedAt: Date

    var id: String {
        "\(saros)-\(Int(date.timeIntervalSince1970))-\(rarity.id)"
    }

    var countdownText: String {
        max(timeUntil, 0).compactDuration
    }
}

private struct SarosGridNearestFlipPanel: View {
    let flip: SarosGridNearestFlip

    var body: some View {
        HStack(spacing: 14) {
            OctalGlyph(
                value: flip.octalAddress,
                depth: flip.harmonicDepth,
                color: flip.rarity.color
            )
            .frame(width: 44, height: 44)
            .padding(8)
            .background(.black.opacity(0.28), in: Circle())
            .overlay {
                Circle()
                    .stroke(flip.rarity.color.opacity(0.48), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Saros \(flip.saros)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(flip.rarity.color)
                Text(flip.rarity.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                Text(flip.countdownText)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundStyle(flip.rarity.color)
                    .contentTransition(.numericText())
                Text(JournalFormatters.dateTime.string(from: flip.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(flip.rarity.color.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct SarosSpikePeriod: Hashable {
    let previousSpike: SarosGlobalFlipEvent
    let spike: SarosGlobalFlipEvent
    let nextSpike: SarosGlobalFlipEvent
    let leftBoundary: Date
    let rightBoundary: Date

    var leftDuration: TimeInterval {
        max(spike.date.timeIntervalSince(leftBoundary), 1)
    }

    var rightDuration: TimeInterval {
        max(rightBoundary.timeIntervalSince(spike.date), 1)
    }

    var duration: TimeInterval {
        leftDuration + rightDuration
    }

    var spikePosition: Double {
        leftDuration / max(duration, 1)
    }
}

private struct SarosSpikeWaveState: Hashable {
    let period: SarosSpikePeriod
    let date: Date
    let normalizedPosition: Double
    let peakHeight: Double
    let width: TimeInterval
    let normalizedEnergy: Double
    let energy: Double
    let normalizedDerivative: Double
    let derivative: Double
    let hasPassedSpike: Bool

    var slopeDirection: String {
        if abs(derivative) < 0.000_000_1 {
            return "flat"
        }
        return derivative > 0 ? "rising" : "falling"
    }
}

private struct SarosSpikeWaveComponent: Hashable {
    let id: String
    let sourceEventID: String
    let period: SarosSpikePeriod
    let sequenceKey: String
    let leftBoundary: Date
    let rightBoundary: Date
    let peakHeight: Double

    func width(for offset: TimeInterval) -> TimeInterval {
        offset < 0
            ? max(period.spike.date.timeIntervalSince(leftBoundary), 1)
            : max(rightBoundary.timeIntervalSince(period.spike.date), 1)
    }
}

private struct SarosSpikeWaveSample: Hashable {
    let position: Double
    let energy: Double
}

private struct SarosSpikeWaveSamples {
    static let empty = SarosSpikeWaveSamples(
        interval: DateInterval(start: .distantPast, duration: 1),
        points: [],
        maxEnergy: 1,
        eventEnergyByID: [:]
    )

    let interval: DateInterval
    let points: [SarosSpikeWaveSample]
    let maxEnergy: Double
    let eventEnergyByID: [String: Double]

    func energy(for event: SarosGlobalFlipEvent) -> Double {
        eventEnergyByID[event.id] ?? 0
    }
}

private struct SarosSpikeWaveCacheKey: Hashable {
    let harmonicDepth: Int
    let displayStart: Int
    let displayEnd: Int
    let loadStart: Int
    let loadEnd: Int
    let sampleCount: Int
    let minimumRarityID: String
}

private struct SarosSpikeWaveCacheEntry {
    let events: [SarosGlobalFlipEvent]
    let field: SarosSpikeWaveField
    let samples: SarosSpikeWaveSamples
}

@MainActor
private enum SarosSpikeWaveTimelineCache {
    private static let maxEntryCount = 6
    private static var entries: [SarosSpikeWaveCacheKey: SarosSpikeWaveCacheEntry] = [:]
    private static var accessOrder: [SarosSpikeWaveCacheKey] = []

    static func entry(for key: SarosSpikeWaveCacheKey) -> SarosSpikeWaveCacheEntry? {
        guard let entry = entries[key] else { return nil }
        markRecentlyUsed(key)
        return entry
    }

    static func store(_ entry: SarosSpikeWaveCacheEntry, for key: SarosSpikeWaveCacheKey) {
        entries[key] = entry
        markRecentlyUsed(key)

        while accessOrder.count > maxEntryCount, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    private static func markRecentlyUsed(_ key: SarosSpikeWaveCacheKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}

private struct SarosSpikeWaveField {
    static let empty = SarosSpikeWaveField(components: [])

    let components: [SarosSpikeWaveComponent]
    let maxPeakHeight: Double

    private let componentsByEventID: [String: SarosSpikeWaveComponent]

    init(components: [SarosSpikeWaveComponent]) {
        self.components = components
        self.maxPeakHeight = components.map(\.peakHeight).max() ?? 0
        self.componentsByEventID = components.reduce(into: [:]) { lookup, component in
            guard component.sourceEventID == component.period.spike.id else { return }
            lookup[component.sourceEventID] = component
        }
    }

    func sample(at date: Date) -> SarosSpikeWaveState? {
        guard !components.isEmpty else { return nil }

        var totalEnergy = 0.0
        var totalDerivative = 0.0
        var dominantComponent: SarosSpikeWaveComponent?
        var dominantEnergy = 0.0

        for component in components {
            guard component.contains(date) else { continue }

            let energy = component.energy(at: date)
            let derivative = component.derivative(at: date)

            totalEnergy += energy
            totalDerivative += derivative

            if energy > dominantEnergy {
                dominantEnergy = energy
                dominantComponent = component
            }
        }

        let component = dominantComponent ?? nearestComponent(to: date)
        guard let component else { return nil }

        let period = component.period
        let periodDuration = max(period.duration, 1)
        let normalizedPosition = min(
            max(date.timeIntervalSince(period.leftBoundary) / periodDuration, 0),
            1
        )
        let offset = date.timeIntervalSince(period.spike.date)
        let width = component.width(for: offset)
        let peakHeight = max(component.peakHeight, 0.000_000_001)

        return SarosSpikeWaveState(
            period: period,
            date: date,
            normalizedPosition: normalizedPosition,
            peakHeight: component.peakHeight,
            width: width,
            normalizedEnergy: min(max(totalEnergy / peakHeight, 0), 1),
            energy: totalEnergy,
            normalizedDerivative: totalDerivative / peakHeight,
            derivative: totalDerivative,
            hasPassedSpike: date >= period.spike.date
        )
    }

    private func nearestComponent(to date: Date) -> SarosSpikeWaveComponent? {
        components.min {
            abs($0.period.spike.date.timeIntervalSince(date)) < abs($1.period.spike.date.timeIntervalSince(date))
        }
    }

    func component(for event: SarosGlobalFlipEvent) -> SarosSpikeWaveComponent? {
        componentsByEventID[event.id]
    }

    func energy(at date: Date) -> Double {
        energy(at: date, in: components)
    }

    func samples(
        in interval: DateInterval,
        sampleCount: Int,
        events: [SarosGlobalFlipEvent]
    ) -> SarosSpikeWaveSamples {
        let visibleComponents = components.filter { interval.intersects($0.periodInterval) }
        guard !visibleComponents.isEmpty, sampleCount > 1 else {
            return SarosSpikeWaveSamples(
                interval: interval,
                points: [],
                maxEnergy: max(maxPeakHeight, 0.000_000_001),
                eventEnergyByID: [:]
            )
        }

        var maxEnergy = 0.0
        let points = (0...sampleCount).map { index in
            let position = Double(index) / Double(sampleCount)
            let date = interval.start.addingTimeInterval(interval.duration * position)
            let energy = energy(at: date, in: visibleComponents)
            maxEnergy = max(maxEnergy, energy)

            return SarosSpikeWaveSample(position: position, energy: energy)
        }

        let eventEnergyByID = Dictionary(uniqueKeysWithValues: events.map { event in
            (event.id, energy(at: event.date, in: visibleComponents))
        })

        return SarosSpikeWaveSamples(
            interval: interval,
            points: points,
            maxEnergy: max(maxEnergy, maxPeakHeight, 0.000_000_001),
            eventEnergyByID: eventEnergyByID
        )
    }

    private func energy(at date: Date, in candidateComponents: [SarosSpikeWaveComponent]) -> Double {
        candidateComponents.reduce(0) { total, component in
            guard component.contains(date) else { return total }
            return total + component.energy(at: date)
        }
    }

    func maxEnergy(in interval: DateInterval) -> Double {
        let visibleComponents = components.filter { interval.intersects($0.periodInterval) }
        guard !visibleComponents.isEmpty else {
            return max(maxPeakHeight, 0.000_000_001)
        }

        let sampleCount = 960
        let visiblePeak = (0...sampleCount).reduce(0.0) { currentMax, index in
            let ratio = Double(index) / Double(sampleCount)
            let date = interval.start.addingTimeInterval(interval.duration * ratio)
            let energy = visibleComponents.reduce(0.0) { total, component in
                guard component.contains(date) else { return total }
                return total + component.energy(at: date)
            }

            return max(currentMax, energy)
        }

        return max(visiblePeak, maxPeakHeight, 0.000_000_001)
    }
}

private enum SarosSpikeWaveCalculator {
    static func field(events: [SarosGlobalFlipEvent]) -> SarosSpikeWaveField {
        let spikes = events.sorted { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date < rhs.date
            }
            return lhs.rarity > rhs.rarity
        }

        let components = spikes.indices.compactMap { index -> SarosSpikeWaveComponent? in
            let spike = spikes[index]
            let previous = previousDistinctEvent(in: spikes, before: index)
            let next = nextDistinctEvent(in: spikes, after: index)
            let leftGap = max(previous.map { spike.date.timeIntervalSince($0.date) } ?? next.map { $0.date.timeIntervalSince(spike.date) } ?? 86_400, 1)
            let rightGap = max(next.map { $0.date.timeIntervalSince(spike.date) } ?? leftGap, 1)
            let leftBoundary = previous.map { midpoint($0.date, spike.date) }
                ?? spike.date.addingTimeInterval(-leftGap / 2)
            let rightBoundary = next.map { midpoint(spike.date, $0.date) }
                ?? spike.date.addingTimeInterval(rightGap / 2)

            return component(
                source: spike,
                previous: previous,
                next: next,
                leftBoundary: leftBoundary,
                rightBoundary: rightBoundary,
                index: index
            )
        }

        return SarosSpikeWaveField(components: components)
    }

    static func state(
        at date: Date,
        events: [SarosGlobalFlipEvent]
    ) -> SarosSpikeWaveState? {
        field(events: events).sample(at: date)
    }

    private static func peakHeight(for rarity: FlipRarity) -> Double {
        switch rarity.baseRarity {
        case .mythic:
            return 4
        case .legendary:
            return 2
        case .epic:
            return 1
        case .rare:
            return 0.5
        default:
            return 0.25
        }
    }

    private static func component(
        source: SarosGlobalFlipEvent,
        previous: SarosGlobalFlipEvent?,
        next: SarosGlobalFlipEvent?,
        leftBoundary: Date,
        rightBoundary: Date,
        index: Int
    ) -> SarosSpikeWaveComponent? {
        let duration = rightBoundary.timeIntervalSince(leftBoundary)
        guard duration > 1 else { return nil }

        return SarosSpikeWaveComponent(
            id: "\(source.id)-gaussian-\(index)",
            sourceEventID: source.id,
            period: SarosSpikePeriod(
                previousSpike: previous ?? source,
                spike: source,
                nextSpike: next ?? source,
                leftBoundary: leftBoundary,
                rightBoundary: rightBoundary
            ),
            sequenceKey: "\(source.saros)-\(source.rarity.baseRarity.id)",
            leftBoundary: leftBoundary,
            rightBoundary: rightBoundary,
            peakHeight: peakHeight(for: source.rarity)
        )
    }

    private static func midpoint(_ lhs: Date, _ rhs: Date) -> Date {
        lhs.addingTimeInterval(rhs.timeIntervalSince(lhs) / 2)
    }

    private static func previousDistinctEvent(
        in spikes: [SarosGlobalFlipEvent],
        before index: Int
    ) -> SarosGlobalFlipEvent? {
        guard index > spikes.startIndex else { return nil }
        var cursor = index - 1

        while cursor >= spikes.startIndex {
            if spikes[cursor].date != spikes[index].date {
                return spikes[cursor]
            }
            cursor -= 1
        }

        return nil
    }

    private static func nextDistinctEvent(
        in spikes: [SarosGlobalFlipEvent],
        after index: Int
    ) -> SarosGlobalFlipEvent? {
        var cursor = index + 1

        while cursor < spikes.endIndex {
            if spikes[cursor].date != spikes[index].date {
                return spikes[cursor]
            }
            cursor += 1
        }

        return nil
    }
}

private extension SarosSpikeWaveComponent {
    static let gaussianExtent = 3.2

    var periodInterval: DateInterval {
        DateInterval(start: leftBoundary, end: rightBoundary)
    }

    func contains(_ date: Date) -> Bool {
        date >= leftBoundary && date <= rightBoundary
    }

    func energy(at date: Date) -> Double {
        guard contains(date) else { return 0 }

        let x = gaussianCoordinate(at: date)
        let boundaryValue = exp(-0.5 * Self.gaussianExtent * Self.gaussianExtent)
        let raw = exp(-0.5 * x * x)
        let normalized = max((raw - boundaryValue) / max(1 - boundaryValue, 0.000_000_001), 0)

        return peakHeight * normalized
    }

    func derivative(at date: Date) -> Double {
        guard contains(date) else { return 0 }
        let step = min(max(width(for: date.timeIntervalSince(period.spike.date)) / 600, 60), 1_800)
        let before = max(leftBoundary, date.addingTimeInterval(-step))
        let after = min(rightBoundary, date.addingTimeInterval(step))
        let duration = max(after.timeIntervalSince(before), 1)

        return (energy(at: after) - energy(at: before)) / duration
    }

    private func gaussianCoordinate(at date: Date) -> Double {
        let offset = date.timeIntervalSince(period.spike.date)
        let span = max(width(for: offset), 1)
        let normalized = min(max(offset / span, -1), 1)
        return normalized * Self.gaussianExtent
    }
}

private enum SarosSpikeWaveError: LocalizedError {
    case missingSaros(Int)

    var errorDescription: String? {
        switch self {
        case .missingSaros(let saros):
            "No Saros \(saros) series found."
        }
    }
}

private struct SarosSpikeCalendarReference: Identifiable, Hashable {
    let id = UUID()
    let date: Date
}

private struct SarosSpikeWaveTimelineView: View {
    @EnvironmentObject private var services: AppServices

    let flip: SarosGridNearestFlip

    @State private var events: [SarosGlobalFlipEvent] = []
    @State private var waveField = SarosSpikeWaveField.empty
    @State private var waveSamples = SarosSpikeWaveSamples.empty
    @State private var currentState: SarosSpikeWaveState?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var zoom: CGFloat = Self.initialZoom
    @State private var gestureScale: CGFloat = 1
    @State private var presentDate = Date()
    @State private var contentMinX: CGFloat = 0
    @State private var scrollAnchorDate: Date?
    @State private var scrollAnchorID: String?
    @State private var zoomAnchorDate: Date?
    @State private var selectedCalendarReference: SarosSpikeCalendarReference?
    @State private var probeDate: Date?

    private var month: SarosGlobalTimelineMonth {
        SarosGlobalTimelineMonth.containing(flip.observedAt)
    }

    private var displayInterval: DateInterval {
        guard
            let start = Self.calendar.date(byAdding: .month, value: -3, to: month.startDate),
            let end = Self.calendar.date(byAdding: .month, value: 4, to: month.startDate)
        else {
            return month.dateInterval
        }

        return DateInterval(start: start, end: end)
    }

    private var loadInterval: DateInterval {
        DateInterval(
            start: displayInterval.start.addingTimeInterval(-Self.loadPaddingDuration),
            end: displayInterval.end.addingTimeInterval(Self.loadPaddingDuration)
        )
    }

    private var effectiveZoom: CGFloat {
        min(max(zoom * gestureScale, Self.minimumZoom), Self.maximumZoom)
    }

    private var visibleEvents: [SarosGlobalFlipEvent] {
        events.filter { event in
            event.date >= displayInterval.start && event.date < displayInterval.end
        }
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            VStack(spacing: 14) {
                if let currentState {
                    Button {
                        scrollToPresent(proxy: scrollProxy)
                    } label: {
                        SarosSpikeWaveStatePanel(state: displayedWaveState ?? currentState)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.top, 12)
                }

                GeometryReader { geometry in
                    let contentWidth = max(geometry.size.width * effectiveZoom, geometry.size.width)
                    let height = max(geometry.size.height, 320)
                    let axisTicks = axisTicks()
                    let hourTicks = axisHourTicks(showLabels: effectiveZoom >= 80)
                    let dayLabels = axisDayLabels()
                    let markerEvents = visibleEvents
                    let waveMaxEnergy = waveSamples.maxEnergy
                    let displayedState = displayedWaveState
                    let dotMarkers = eventDotMarkers(
                        events: markerEvents,
                        contentWidth: contentWidth,
                        height: height,
                        maxEnergy: waveMaxEnergy
                    )
                    let markerDate = probeDate ?? displayedState?.date ?? presentDate

                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            SarosSpikeWaveCanvas(
                                samples: waveSamples,
                                currentState: displayedState,
                                displayInterval: displayInterval,
                                maxEnergy: waveMaxEnergy
                            )
                            .frame(width: contentWidth, height: height)

                            SarosSpikeMarkersCanvas(
                                events: markerEvents,
                                dots: dotMarkers,
                                displayInterval: displayInterval
                            )
                            .frame(width: contentWidth, height: height)

                            if displayInterval.contains(markerDate) {
                                Color.clear
                                    .frame(width: 1, height: height)
                                    .position(
                                        x: xPosition(for: markerDate, width: contentWidth),
                                        y: height / 2
                                    )
                                    .id(Self.referenceScrollID)

                                SarosSpikeCurrentMarker(
                                    state: displayedState,
                                    color: displayedState?.period.spike.rarity.color ?? flip.rarity.color
                                )
                                .position(
                                    x: xPosition(for: markerDate, width: contentWidth),
                                    y: displayedState.map { yPosition(for: $0, height: height, maxEnergy: waveMaxEnergy) } ?? height / 2
                                )
                            }

                            if let scrollAnchorDate,
                               let scrollAnchorID,
                               displayInterval.contains(scrollAnchorDate)
                            {
                                SarosSpikeScrollAnchor(
                                    id: scrollAnchorID,
                                    x: xPosition(for: scrollAnchorDate, width: contentWidth),
                                    width: contentWidth
                                )
                            }

                            ForEach(axisTicks) { tick in
                                SarosSpikeWaveAxisTickView(tick: tick)
                                    .position(
                                        x: xPosition(for: tick.date, width: contentWidth),
                                        y: height - 24
                                    )
                            }

                            ForEach(hourTicks) { tick in
                                SarosSpikeWaveHourTickView(tick: tick)
                                    .position(
                                        x: xPosition(for: tick.date, width: contentWidth),
                                        y: height - 48
                                    )
                            }

                            ForEach(dayLabels) { label in
                                SarosSpikeWaveDayLabelView(label: label)
                                    .position(
                                        x: xPosition(for: label.date, width: contentWidth),
                                        y: height - 66
                                    )
                            }

                            if displayInterval.contains(markerDate) {
                                let markerX = xPosition(for: markerDate, width: contentWidth)
                                SarosSpikeWaveProbeHandle(
                                    date: markerDate,
                                    state: displayedState,
                                    color: displayedState?.period.spike.rarity.color ?? flip.rarity.color,
                                    x: markerX,
                                    onDrag: { x in
                                        moveProbe(toX: x, contentWidth: contentWidth)
                                    }
                                )
                                .position(
                                    x: markerX,
                                    y: displayedState.map { yPosition(for: $0, height: height, maxEnergy: waveMaxEnergy) } ?? height / 2
                                )
                            }
                        }
                        .frame(width: contentWidth, height: height)
                        .contentShape(Rectangle())
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: SarosSpikeContentMinXPreferenceKey.self,
                                    value: proxy.frame(in: .named(Self.scrollCoordinateSpace)).minX
                                )
                            }
                        )
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    if zoomAnchorDate == nil {
                                        let anchorDate = centerDate(
                                            contentWidth: contentWidth,
                                            viewportWidth: geometry.size.width
                                        )
                                        zoomAnchorDate = anchorDate
                                        scrollAnchorDate = anchorDate
                                    }
                                    gestureScale = value
                                }
                                .onEnded { value in
                                    zoom = min(max(zoom * value, Self.minimumZoom), Self.maximumZoom)
                                    gestureScale = 1
                                    let anchorDate = zoomAnchorDate ?? centerDate(
                                        contentWidth: contentWidth,
                                        viewportWidth: geometry.size.width
                                    )
                                    zoomAnchorDate = nil
                                    scroll(to: anchorDate, proxy: scrollProxy, animated: false, layoutDelay: 0.06)
                                }
                        )
                    }
                    .coordinateSpace(name: Self.scrollCoordinateSpace)
                    .onPreferenceChange(SarosSpikeContentMinXPreferenceKey.self) { value in
                        guard abs(contentMinX - value) > Self.scrollOffsetUpdateThreshold else { return }
                        contentMinX = value
                    }
                    .onAppear {
                        scrollToPresent(proxy: scrollProxy, animated: false)
                    }
                    .onChange(of: events.count) { _, _ in
                        scrollToPresent(proxy: scrollProxy, animated: false)
                    }
                }
            }
            .overlay {
                if let errorMessage {
                    ContentUnavailableView(errorMessage, systemImage: "waveform.path.ecg")
                } else if isLoading && events.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle("Saros \(flip.saros) wave")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectedCalendarReference = SarosSpikeCalendarReference(date: Date())
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Open Saros calendar")
                }
            }
            .task {
                loadEvents()
            }
        }
        .navigationDestination(item: $selectedCalendarReference) { reference in
            SarosGlobalFlipTimelineView(
                referenceDate: reference.date,
                referenceEvent: nil
            )
        }
    }

    private static let loadPaddingDuration: TimeInterval = 180 * 86_400
    private static let minimumZoom: CGFloat = 8
    private static let initialZoom: CGFloat = 220
    private static let maximumZoom: CGFloat = 420
    private static let waveSampleCount = 65_536
    private static let minimumWaveRarity = FlipRarity.epic
    private static let scrollOffsetUpdateThreshold: CGFloat = 28
    private static let referenceScrollID = "saros-spike-reference"
    private static let scrollCoordinateSpace = "saros-spike-scroll"

    private var displayedWaveState: SarosSpikeWaveState? {
        if let probeDate,
           let state = waveField.sample(at: probeDate)
        {
            return state
        }

        return currentState
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    private static let monthTickFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    private static let dayTickFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    private static let centerDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, EEEE"
        return formatter
    }()

    @MainActor
    private func loadEvents() {
        guard events.isEmpty else { return }

        let eclipseService = services.eclipseService
        let harmonicDepth = flip.harmonicDepth
        let loadInterval = loadInterval
        let displayInterval = displayInterval
        let waveSampleCount = Self.waveSampleCount
        let minimumRarity = Self.minimumWaveRarity
        let presentDate = Date()
        self.presentDate = presentDate
        let cacheKey = Self.cacheKey(
            harmonicDepth: harmonicDepth,
            displayInterval: displayInterval,
            loadInterval: loadInterval,
            sampleCount: waveSampleCount,
            minimumRarity: minimumRarity
        )

        if let cached = SarosSpikeWaveTimelineCache.entry(for: cacheKey) {
            events = cached.events
            waveField = cached.field
            waveSamples = cached.samples
            currentState = cached.field.sample(at: presentDate)
            isLoading = false
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil

        Task.detached(priority: .userInitiated) {
            let result: Result<(events: [SarosGlobalFlipEvent], field: SarosSpikeWaveField, samples: SarosSpikeWaveSamples, currentState: SarosSpikeWaveState?), Error> = Result {
                let summaries = try eclipseService.allSarosSeries()

                let loadedEvents = SarosGlobalTimelineBuilder.events(
                    in: loadInterval,
                    summaries: summaries,
                    eclipseService: eclipseService,
                    harmonicDepth: harmonicDepth,
                    minimumRarity: minimumRarity
                )
                let field = SarosSpikeWaveCalculator.field(events: loadedEvents)
                let samples = field.samples(
                    in: displayInterval,
                    sampleCount: waveSampleCount,
                    events: loadedEvents
                )

                return (
                    events: loadedEvents,
                    field: field,
                    samples: samples,
                    currentState: field.sample(at: presentDate)
                )
            }

            await MainActor.run {
                isLoading = false
                switch result {
                case .success(let loaded):
                    events = loaded.events
                    waveField = loaded.field
                    waveSamples = loaded.samples
                    currentState = loaded.currentState
                    SarosSpikeWaveTimelineCache.store(
                        SarosSpikeWaveCacheEntry(
                            events: loaded.events,
                            field: loaded.field,
                            samples: loaded.samples
                        ),
                        for: cacheKey
                    )
                    errorMessage = nil
                case .failure(let error):
                    events = []
                    waveField = .empty
                    waveSamples = .empty
                    currentState = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private static func cacheKey(
        harmonicDepth: Int,
        displayInterval: DateInterval,
        loadInterval: DateInterval,
        sampleCount: Int,
        minimumRarity: FlipRarity
    ) -> SarosSpikeWaveCacheKey {
        SarosSpikeWaveCacheKey(
            harmonicDepth: harmonicDepth,
            displayStart: Int(displayInterval.start.timeIntervalSince1970),
            displayEnd: Int(displayInterval.end.timeIntervalSince1970),
            loadStart: Int(loadInterval.start.timeIntervalSince1970),
            loadEnd: Int(loadInterval.end.timeIntervalSince1970),
            sampleCount: sampleCount,
            minimumRarityID: minimumRarity.id
        )
    }

    private func axisTicks() -> [SarosSpikeAxisTick] {
        var ticks: [SarosSpikeAxisTick] = []
        var cursor = Self.calendar.startOfDay(for: displayInterval.start)

        while cursor < displayInterval.end {
            let day = Self.calendar.component(.day, from: cursor)
            let isMajor = day == 1

            ticks.append(
                SarosSpikeAxisTick(
                    date: cursor,
                    title: isMajor
                        ? Self.monthTickFormatter.string(from: cursor)
                        : "\(day)",
                    isMajor: isMajor
                )
            )

            guard let nextDay = Self.calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = nextDay
        }

        return ticks
    }

    private func axisHourTicks(showLabels: Bool) -> [SarosSpikeHourTick] {
        var ticks: [SarosSpikeHourTick] = []
        var cursor = Self.calendar.startOfDay(for: displayInterval.start)

        while cursor < displayInterval.end {
            for hour in [6, 12, 18] {
                guard let date = Self.calendar.date(byAdding: .hour, value: hour, to: cursor),
                      displayInterval.contains(date)
                else {
                    continue
                }

                ticks.append(
                    SarosSpikeHourTick(
                        date: date,
                        title: showLabels ? String(format: "%02d:00", hour) : ""
                    )
                )
            }

            guard let nextDay = Self.calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = nextDay
        }

        return ticks
    }

    private func axisDayLabels() -> [SarosSpikeAxisDayLabel] {
        var labels: [SarosSpikeAxisDayLabel] = []
        var cursor = Self.calendar.startOfDay(for: displayInterval.start)

        while cursor < displayInterval.end {
            guard
                let midday = Self.calendar.date(byAdding: .hour, value: 12, to: cursor),
                let nextDay = Self.calendar.date(byAdding: .day, value: 1, to: cursor)
            else {
                break
            }

            if displayInterval.contains(midday) {
                labels.append(
                    SarosSpikeAxisDayLabel(
                        date: midday,
                        title: Self.centerDayFormatter.string(from: midday)
                    )
                )
            }

            cursor = nextDay
        }

        return labels
    }

    @MainActor
    private func scrollToPresent(
        proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        let now = Date()
        presentDate = now
        probeDate = now
        currentState = waveField.sample(at: now) ?? currentState
        scroll(to: now, proxy: proxy, animated: animated)
    }

    @MainActor
    private func scroll(
        to date: Date,
        proxy: ScrollViewProxy,
        animated: Bool = true,
        layoutDelay: TimeInterval = 0.04
    ) {
        guard displayInterval.contains(date) else { return }
        let targetID = "saros-spike-scroll-anchor-\(Int(date.timeIntervalSince1970))"
        scrollAnchorDate = date
        scrollAnchorID = targetID

        DispatchQueue.main.asyncAfter(deadline: .now() + layoutDelay) {
            if animated {
                withAnimation(.easeOut(duration: 0.24)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            } else {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
    }

    private func centerDate(contentWidth: CGFloat, viewportWidth: CGFloat) -> Date {
        let centerX = min(max(-contentMinX + viewportWidth / 2, 0), contentWidth)
        let ratio = min(max(centerX / max(contentWidth, 1), 0), 1)
        return displayInterval.start.addingTimeInterval(displayInterval.duration * Double(ratio))
    }

    private func moveProbe(toX x: CGFloat, contentWidth: CGFloat) {
        let ratio = min(max(x / max(contentWidth, 1), 0), 1)
        let date = displayInterval.start.addingTimeInterval(displayInterval.duration * Double(ratio))
        probeDate = date
    }

    private func eventDotMarkers(
        events: [SarosGlobalFlipEvent],
        contentWidth: CGFloat,
        height: CGFloat,
        maxEnergy: Double
    ) -> [SarosSpikeDotMarker] {
        var placed: [(x: CGFloat, y: CGFloat)] = []

        return events.sorted {
            if $0.date != $1.date {
                return $0.date < $1.date
            }
            return $0.rarity > $1.rarity
        }
        .map { event in
            var x = xPosition(for: event.date, width: contentWidth)
            let size = dotSize(for: event.rarity)
            let baseY = dotBaseY(
                for: event,
                samples: waveSamples,
                maxEnergy: maxEnergy,
                height: height
            )
            var y = baseY
            var level = 0
            let step = size + 6
            let maxUpLevels = max(Int((baseY - 12) / step), 0)

            while placed.contains(where: { abs($0.x - x) < size + 4 && abs($0.y - y) < size + 4 }),
                  level < 48
            {
                level += 1
                let upLevel = min(level, maxUpLevels)
                let overflowLevel = max(level - maxUpLevels, 0)

                y = max(12, baseY - CGFloat(upLevel) * step)
                x = min(contentWidth - size / 2, x + CGFloat(overflowLevel) * (size + 4))
            }

            placed.append((x, y))
            return SarosSpikeDotMarker(event: event, x: x, y: y, size: size)
        }
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let ratio = min(
            max(date.timeIntervalSince(displayInterval.start) / displayInterval.duration, 0),
            1
        )
        return CGFloat(ratio) * width
    }

    private func yPosition(
        for state: SarosSpikeWaveState,
        height: CGFloat,
        maxEnergy: Double
    ) -> CGFloat {
        let baseline = height * 0.76
        let top = height * 0.18
        let waveHeight = baseline - top
        let ratio = min(max(state.energy / maxEnergy, 0), 1)
        return baseline - CGFloat(ratio) * waveHeight
    }

    private func dotBaseY(
        for event: SarosGlobalFlipEvent,
        samples: SarosSpikeWaveSamples,
        maxEnergy: Double,
        height: CGFloat
    ) -> CGFloat {
        let baseline = height * 0.76
        let top = height * 0.18
        let waveHeight = baseline - top
        let maxEnergy = max(maxEnergy, 0.000_000_001)
        let eventEnergy = samples.energy(for: event)
        let peakY = baseline - CGFloat(eventEnergy / maxEnergy) * waveHeight

        return max(14, peakY - 10)
    }

    private func dotSize(for rarity: FlipRarity) -> CGFloat {
        switch rarity.baseRarity {
        case .mythic: 10
        case .legendary: 8
        case .epic: 6.5
        default: 6
        }
    }
}

private struct SarosSpikeDotMarker: Identifiable {
    let event: SarosGlobalFlipEvent
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat

    var id: String { event.id }
}

private struct SarosSpikeContentMinXPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SarosSpikeWaveStatePanel: View {
    let state: SarosSpikeWaveState

    private var normalizedSlopePerDay: Double {
        state.normalizedDerivative * 86_400
    }

    private var derivativePerDay: Double {
        state.derivative * 86_400
    }

    private var widthDays: Double {
        state.width / 86_400
    }

    var body: some View {
        HStack(spacing: 12) {
            OctalGlyph(
                value: state.period.spike.octalAddress,
                depth: state.period.spike.harmonicDepth,
                color: state.period.spike.rarity.color
            )
            .frame(width: 44, height: 44)
            .padding(8)
            .background(.black.opacity(0.28), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(state.period.spike.rarity.title)
                    .font(.headline)
                    .foregroundStyle(state.period.spike.rarity.color)
                Text(state.hasPassedSpike ? "past spike" : "approaching spike")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "E %.3f / H %.2f", state.energy, state.peakHeight))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                Text(String(format: "%@ %.3f/day", state.slopeDirection, derivativePerDay))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(state.derivative >= 0 ? .green : .red)
                Text(String(format: "width %.1fd · unit slope %.3f/day", widthDays, normalizedSlopePerDay))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(state.period.spike.rarity.color.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct SarosSpikeWaveCanvas: View {
    let samples: SarosSpikeWaveSamples
    let currentState: SarosSpikeWaveState?
    let displayInterval: DateInterval
    let maxEnergy: Double

    var body: some View {
        Canvas { context, size in
            let baseline = size.height * 0.76
            let top = size.height * 0.18
            let waveHeight = baseline - top
            let maxEnergy = max(maxEnergy, 0.000_000_001)

            var grid = Path()
            grid.move(to: CGPoint(x: 0, y: baseline))
            grid.addLine(to: CGPoint(x: size.width, y: baseline))
            context.stroke(grid, with: .color(.white.opacity(0.16)), lineWidth: 1)

            for i in 0...4 {
                let y = top + waveHeight * CGFloat(i) / 4
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }

            drawCombinedWave(
                in: context,
                size: size,
                baseline: baseline,
                waveHeight: waveHeight,
                maxEnergy: maxEnergy
            )

            if let currentState {
                let x = xPosition(for: currentState.date, width: size.width)
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: top - 10))
                marker.addLine(to: CGPoint(x: x, y: baseline + 18))
                context.stroke(
                    marker,
                    with: .color(currentState.period.spike.rarity.color.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 1.4, dash: [5, 5])
                )
            }
        }
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let ratio = min(
            max(date.timeIntervalSince(displayInterval.start) / displayInterval.duration, 0),
            1
        )
        return CGFloat(ratio) * width
    }

    private func yPosition(
        for energy: Double,
        baseline: CGFloat,
        waveHeight: CGFloat,
        maxEnergy: Double
    ) -> CGFloat {
        let ratio = min(max(energy / maxEnergy, 0), 1)
        return baseline - CGFloat(ratio) * waveHeight
    }

    private func drawCombinedWave(
        in context: GraphicsContext,
        size: CGSize,
        baseline: CGFloat,
        waveHeight: CGFloat,
        maxEnergy: Double
    ) {
        guard !samples.points.isEmpty else { return }

        var line = Path()
        var fill = Path()
        fill.move(to: CGPoint(x: 0, y: baseline))

        for (index, sample) in samples.points.enumerated() {
            let x = CGFloat(sample.position) * size.width
            let y = yPosition(
                for: sample.energy,
                baseline: baseline,
                waveHeight: waveHeight,
                maxEnergy: maxEnergy
            )
            let point = CGPoint(x: x, y: y)

            if index == 0 {
                line.move(to: point)
            } else {
                line.addLine(to: point)
            }

            fill.addLine(to: point)
        }

        fill.addLine(to: CGPoint(x: size.width, y: baseline))
        fill.closeSubpath()

        context.fill(fill, with: .color(.white.opacity(0.11)))
        context.stroke(line, with: .color(.white.opacity(0.96)), lineWidth: 1.7)
    }

    private func lineWidth(for rarity: FlipRarity) -> CGFloat {
        switch rarity.baseRarity {
        case .mythic: 1.8
        case .legendary: 1.45
        default: 1.15
        }
    }
}

private struct SarosSpikeMarkersCanvas: View {
    let events: [SarosGlobalFlipEvent]
    let dots: [SarosSpikeDotMarker]
    let displayInterval: DateInterval

    var body: some View {
        Canvas { context, size in
            for event in events {
                let x = xPosition(for: event.date, width: size.width)
                let lineWidth: CGFloat = event.rarity.baseRarity == .mythic ? 2.0 : 1.2
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height * 0.15))
                line.addLine(to: CGPoint(x: x, y: size.height * 0.85))
                context.stroke(
                    line,
                    with: .color(event.rarity.color.opacity(0.58)),
                    lineWidth: lineWidth
                )
            }

            for marker in dots {
                let rect = CGRect(
                    x: marker.x - marker.size / 2,
                    y: marker.y - marker.size / 2,
                    width: marker.size,
                    height: marker.size
                )
                let dot = Path(ellipseIn: rect)
                context.fill(dot, with: .color(marker.event.rarity.color))
                context.stroke(dot, with: .color(.black.opacity(0.38)), lineWidth: 0.8)
            }
        }
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let ratio = min(
            max(date.timeIntervalSince(displayInterval.start) / displayInterval.duration, 0),
            1
        )
        return CGFloat(ratio) * width
    }
}

private struct SarosSpikeScrollAnchor: View {
    let id: String
    let x: CGFloat
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: max(x, 0))
            Color.clear
                .frame(width: 1, height: 1)
                .id(id)
            Color.clear
                .frame(width: max(width - x - 1, 0))
        }
        .frame(width: width, height: 1, alignment: .leading)
    }
}

private struct SarosSpikeCurrentMarker: View {
    let state: SarosSpikeWaveState?
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .shadow(color: color.opacity(0.7), radius: 8)
            Text(state?.slopeDirection ?? "now")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .rotationEffect(.degrees(-90))
                .fixedSize()
        }
    }
}

private struct SarosSpikeAxisTick: Identifiable, Hashable {
    let date: Date
    let title: String
    let isMajor: Bool

    var id: String {
        "\(Int(date.timeIntervalSince1970))-\(isMajor ? "major" : "minor")"
    }
}

private struct SarosSpikeHourTick: Identifiable, Hashable {
    let date: Date
    let title: String

    var id: String {
        "\(Int(date.timeIntervalSince1970))-hour"
    }
}

private struct SarosSpikeAxisDayLabel: Identifiable, Hashable {
    let date: Date
    let title: String

    var id: String {
        "\(Int(date.timeIntervalSince1970))-center-day"
    }
}

private struct SarosSpikeWaveAxisTickView: View {
    let tick: SarosSpikeAxisTick

    var body: some View {
        VStack(spacing: 4) {
            Rectangle()
                .fill(.white.opacity(tick.isMajor ? 0.34 : 0.16))
                .frame(width: 1, height: tick.isMajor ? 28 : 15)

            Text(tick.title)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(tick.isMajor ? Color.white.opacity(0.78) : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: tick.isMajor ? 78 : 54, height: 48, alignment: .top)
    }
}

private struct SarosSpikeWaveHourTickView: View {
    let tick: SarosSpikeHourTick

    var body: some View {
        VStack(spacing: 3) {
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(width: 1, height: 12)

            if !tick.title.isEmpty {
                Text(tick.title)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.secondary.opacity(0.86))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
        .frame(width: 48, height: 34, alignment: .top)
    }
}

private struct SarosSpikeWaveDayLabelView: View {
    let label: SarosSpikeAxisDayLabel

    var body: some View {
        Text(label.title)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.78))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.4), in: Capsule())
            .frame(width: 132, height: 24)
    }
}

private struct SarosSpikeWaveProbeHandle: View {
    let date: Date
    let state: SarosSpikeWaveState?
    let color: Color
    let x: CGFloat
    let onDrag: (CGFloat) -> Void

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 6) {
            Text(Self.formatter.string(from: date))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.58), in: Capsule())

            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.72), lineWidth: 1.2)
                }
                .shadow(color: color.opacity(0.74), radius: 9)

            if let state {
                Text(String(format: "E %.3f", state.energy))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.44), in: Capsule())
            }
        }
        .frame(width: 112, height: 88)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onDrag(x + value.translation.width)
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wave probe")
        .accessibilityValue(Self.formatter.string(from: date))
    }
}

private struct SarosSpikeWaveAxisLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.36), in: Capsule())
    }
}

private struct SarosPhaseGridCell: View {
    let saros: Int
    let reading: SarosClockReading
    let date: Date
    let size: CGFloat
    let highlightRarity: FlipRarity?

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
        highlightRarity?.color ?? upcomingRarity?.color ?? .white
    }

    private var isHighlighted: Bool {
        highlightRarity != nil || upcomingRarity != nil
    }

    var body: some View {
        OctalGlyph(
            value: reading.octalAddress,
            depth: reading.harmonicDepth,
            color: tint
        )
        .frame(width: size * 0.66, height: size * 0.66)
        .padding(size * 0.17)
        .background(.black.opacity(isHighlighted ? 0.38 : 0.18), in: Circle())
        .overlay {
            Circle()
                .stroke(tint.opacity(isHighlighted ? 0.62 : 0.24), lineWidth: isHighlighted ? 2 : 1)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saros \(saros), phase \(reading.octalAddress)")
    }
}

private struct SarosPhaseDetailView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    let series: ActiveSarosPhaseSeries

    @State private var selectedGlobalTimelineEvent: SarosPhaseFlipEvent?
    @State private var selectedMapSequence: ActiveSarosPhaseSeries?
    @State private var seriesEclipses: [Eclipse] = []

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            if let reading = series.reading(at: context.date, harmonicDepth: harmonicDepth) {
                let reference = SarosPhaseTimelineReference.upcoming(reading: reading, now: context.date)

                VStack(spacing: 0) {
                    SarosPhaseHeaderPanel(
                        reading: reading,
                        reference: reference,
                        now: context.date,
                        seriesEclipses: seriesEclipses
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    selectedMapSequence = series
                } label: {
                    Image(systemName: "map")
                }
                .accessibilityLabel("Open eclipse maps")
            }
        }
        .navigationDestination(item: $selectedGlobalTimelineEvent) { event in
            SarosGlobalFlipTimelineView(
                referenceDate: event.date,
                referenceEvent: event
            )
        }
        .navigationDestination(item: $selectedMapSequence) { series in
            SarosEclipseMapSequenceView(series: series)
        }
        .task(id: series.saros) {
            await loadSeriesEclipses()
        }
    }

    @MainActor
    private func loadSeriesEclipses() async {
        let saros = series.saros
        let eclipseService = services.eclipseService
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try eclipseService.eclipses(forSaros: saros)
                    .sorted { $0.date < $1.date }
            }
        }.value

        if case .success(let eclipses) = result {
            seriesEclipses = eclipses
        }
    }
}

private struct SarosPhaseHeaderPanel: View {
    let reading: SarosClockReading
    let reference: SarosPhaseTimelineReference?
    let now: Date
    let seriesEclipses: [Eclipse]

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

    private var yearMarkers: [SarosEclipseYearMarker] {
        let sorted = seriesEclipses.isEmpty
            ? [reading.previousEclipse, reading.nextEclipse]
            : seriesEclipses
        guard let nextIndex = sorted.firstIndex(where: { $0.id == reading.nextEclipse.id }) else {
            return [
                SarosEclipseYearMarker(eclipse: reading.previousEclipse, isUpcoming: false),
                SarosEclipseYearMarker(eclipse: reading.nextEclipse, isUpcoming: true)
            ]
        }

        let lowerBound = max(nextIndex - 2, sorted.startIndex)
        return sorted[lowerBound...nextIndex].map { eclipse in
            SarosEclipseYearMarker(
                eclipse: eclipse,
                isUpcoming: eclipse.id == reading.nextEclipse.id
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                VStack(spacing: 8) {
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

                    OctalGlyph(
                        value: fineAddress,
                        depth: 3,
                        color: tint
                    )
                    .frame(width: 28, height: 28)
                    .padding(6)
                    .background(.black.opacity(0.22), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(tint.opacity(0.22), lineWidth: 1)
                    }
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

                SarosEclipseCubeMapPreview(
                    eclipse: reading.nextEclipse,
                    color: tint,
                    compact: true
                )
                .frame(width: 124, height: 124)
            }

            SarosEclipseYearMarkersView(
                markers: yearMarkers,
                tint: tint
            )
        }
    }

    private static func octalPower(_ exponent: Int) -> Int {
        guard exponent > 0 else { return 1 }
        return (0..<exponent).reduce(1) { value, _ in value * 8 }
    }
}

private struct SarosEclipseYearMarker: Identifiable, Hashable {
    let eclipse: Eclipse
    let isUpcoming: Bool

    var id: String { eclipse.id }
}

private struct SarosEclipseYearMarkersView: View {
    let markers: [SarosEclipseYearMarker]
    let tint: Color

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            ForEach(markers) { marker in
                Text(Self.yearFormatter.string(from: marker.eclipse.date))
                    .font(.caption.monospacedDigit().weight(marker.isUpcoming ? .bold : .semibold))
                    .foregroundStyle(marker.isUpcoming ? tint : .secondary)
                    .frame(maxWidth: .infinity, alignment: marker.isUpcoming ? .trailing : .leading)
            }
        }
        .padding(.top, 2)
    }
}

private struct SarosEclipseMapSequenceView: View {
    @EnvironmentObject private var services: AppServices

    let series: ActiveSarosPhaseSeries

    @State private var eclipses: [Eclipse] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didScrollToUpcoming = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if eclipses.isEmpty && !isLoading {
                        ContentUnavailableView(
                            errorMessage ?? "No eclipse maps",
                            systemImage: "map"
                        )
                        .padding(.top, 80)
                    }

                    ForEach(eclipses) { eclipse in
                        SarosEclipseMapSequenceCard(
                            eclipse: eclipse,
                            color: color(for: eclipse),
                            isUpcoming: eclipse.id == series.nextEclipse.id
                        )
                        .id(eclipse.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
            .navigationTitle("Saros \(series.saros) maps")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadEclipses()
            }
            .onChange(of: eclipses.count) { _, _ in
                scrollToUpcoming(with: proxy)
            }
        }
    }

    @MainActor
    private func loadEclipses() async {
        guard eclipses.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        let eclipseService = services.eclipseService
        let saros = series.saros

        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try eclipseService.eclipses(forSaros: saros)
                    .sorted { $0.date < $1.date }
            }
        }.value

        isLoading = false
        switch result {
        case .success(let loaded):
            eclipses = loaded
        case .failure(let error):
            eclipses = []
            errorMessage = error.localizedDescription
        }
    }

    private func scrollToUpcoming(with proxy: ScrollViewProxy) {
        guard !didScrollToUpcoming, !eclipses.isEmpty else { return }
        didScrollToUpcoming = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.snappy(duration: 0.35)) {
                proxy.scrollTo(series.nextEclipse.id, anchor: .center)
            }
        }
    }

    private func color(for eclipse: Eclipse) -> Color {
        if eclipse.id == series.nextEclipse.id {
            return .green
        }
        if eclipse.date < Date() {
            return .secondary
        }
        return .cyan
    }
}

private struct SarosEclipseMapSequenceCard: View {
    let eclipse: Eclipse
    let color: Color
    let isUpcoming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(JournalFormatters.dateTime.string(from: eclipse.date))
                        .font(.headline)
                        .foregroundStyle(isUpcoming ? color : .primary)
                    Text(eclipse.displayTypeLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if let sequence = eclipse.sarosSequence,
                   let count = eclipse.sarosSeriesCount
                {
                    Text("\(sequence)/\(count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(isUpcoming ? color : .secondary)
                }
            }

            SarosEclipseMetricStrip(eclipse: eclipse, color: color)

            SarosEclipseCubeMapPreview(
                eclipse: eclipse,
                color: color,
                compact: false
            )
            .frame(height: 260)
        }
        .padding(12)
        .background(.white.opacity(isUpcoming ? 0.09 : 0.055), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(isUpcoming ? 0.36 : 0.12), lineWidth: isUpcoming ? 1.2 : 1)
        }
    }
}

private struct SarosEclipseMetricStrip: View {
    let eclipse: Eclipse
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            if let gamma = eclipse.gamma {
                metric(title: "Gamma", value: String(format: "%+.3f", gamma))
            }

            if let magnitude = eclipse.magnitude {
                metric(title: "Mag", value: String(format: "%.3f", magnitude))
            }
        }
    }

    private func metric(title: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(color)
        }
        .font(.caption.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.white.opacity(0.07), in: Capsule())
    }
}

private struct SarosEclipseCubeMapPreview: View {
    @EnvironmentObject private var services: AppServices

    let eclipse: Eclipse
    let color: Color
    let compact: Bool

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
                    allowsInteraction: false,
                    showsFrame: !compact,
                    showsBackground: !compact
                )
                .id("\(eclipse.id)-\(focus.offsets.longitude)-\(focus.showsTop)-\(compact)")
            } else if !isLoading {
                Image(systemName: "map")
                    .font(compact ? .title3 : .largeTitle)
                    .foregroundStyle(.secondary)
            }

            if isLoading {
                ProgressView()
                    .controlSize(compact ? .mini : .regular)
            }

            if let errorMessage, !compact {
                Text(errorMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.035))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 8))
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
                color: color,
                polygons: geometry.polygons
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
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
    @State private var didOpenReferenceMonth = false

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
                openReferenceMonth()
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

    private func openReferenceMonth() {
        guard !didOpenReferenceMonth else { return }
        didOpenReferenceMonth = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            selectedMonth = SarosGlobalTimelineMonth.containing(referenceDate)
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
    @State private var selectedSeries: ActiveSarosPhaseSeries?
    @State private var openingSarosID: Int?

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
        dayID(for: referenceDay)
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
                            referenceEvent: referenceGlobalEvent,
                            onSelectEvent: openSaros
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
                scrollToReference(with: proxy, delay: 0.18)
            }
            .onChange(of: isLoadingEvents) { _, loading in
                guard !loading else { return }
                scrollToReference(with: proxy, force: true, delay: 0.16)
            }
            .onChange(of: dayEvents.count) { _, _ in
                scrollToReference(with: proxy, force: true, delay: 0.16)
            }
        }
        .navigationDestination(item: $selectedSeries) { series in
            SarosPhaseDetailView(series: series)
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

    private func openSaros(_ event: SarosGlobalFlipEvent) {
        guard openingSarosID != event.saros else { return }
        openingSarosID = event.saros

        let saros = event.saros
        let eventDate = event.date
        let eclipseService = services.eclipseService

        Task.detached(priority: .userInitiated) {
            let result: Result<ActiveSarosPhaseSeries, Error> = Result {
                guard let summary = try eclipseService.allSarosSeries().first(where: { $0.saros == saros }) else {
                    throw SarosSpikeWaveError.missingSaros(saros)
                }

                let currentInterval = try eclipseService.previousAndNextEclipse(saros: saros, around: Date())
                let fallbackInterval = try eclipseService.previousAndNextEclipse(saros: saros, around: eventDate)
                let interval = currentInterval ?? fallbackInterval

                guard let interval else {
                    throw SarosSpikeWaveError.missingSaros(saros)
                }

                return ActiveSarosPhaseSeries(
                    summary: summary,
                    previousEclipse: interval.previous,
                    nextEclipse: interval.next
                )
            }

            await MainActor.run {
                openingSarosID = nil
                switch result {
                case .success(let series):
                    selectedSeries = series
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func scrollToReference(with proxy: ScrollViewProxy, force: Bool = false) {
        scrollToReference(with: proxy, force: force, delay: 0.08)
    }

    private func scrollToReference(
        with proxy: ScrollViewProxy,
        force: Bool = false,
        delay: TimeInterval
    ) {
        let target = pendingScrollTarget
        guard force || !didScrollToReference else { return }
        didScrollToReference = true

        let delays: [TimeInterval] = target == .reference
            ? [delay, delay + 0.22, delay + 0.48]
            : [delay, delay + 0.18]
        let monthID = visibleMonth.id

        for scrollDelay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + scrollDelay) {
                guard visibleMonth.id == monthID else { return }
                scrollToTarget(target, with: proxy, animated: scrollDelay == delay)
            }
        }
    }

    private func scrollToTarget(
        _ target: SarosMonthScrollTarget,
        with proxy: ScrollViewProxy,
        animated: Bool
    ) {
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
        if animated {
            withAnimation(.snappy(duration: 0.35)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            proxy.scrollTo(id, anchor: anchor)
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
    let onSelectEvent: (SarosGlobalFlipEvent) -> Void

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
                    Button {
                        onSelectEvent(event)
                    } label: {
                        SarosGlobalFlipRow(
                            event: event,
                            referenceDate: referenceDate,
                            isReference: event.id == referenceEvent?.id
                        )
                    }
                    .buttonStyle(.plain)
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
        harmonicDepth rawHarmonicDepth: Int,
        minimumRarity: FlipRarity = .epic
    ) -> [SarosGlobalFlipEvent] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return events(
            in: DateInterval(start: start, end: end),
            summaries: summaries,
            eclipseService: eclipseService,
            harmonicDepth: rawHarmonicDepth,
            minimumRarity: minimumRarity
        )
    }

    static func eventsByDay(
        in interval: DateInterval,
        summaries: [SarosSeriesSummary],
        eclipseService: any EclipseService,
        harmonicDepth rawHarmonicDepth: Int,
        minimumRarity: FlipRarity = .epic
    ) -> [Int: [SarosGlobalFlipEvent]] {
        Dictionary(grouping: events(
            in: interval,
            summaries: summaries,
            eclipseService: eclipseService,
            harmonicDepth: rawHarmonicDepth,
            minimumRarity: minimumRarity
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
        harmonicDepth rawHarmonicDepth: Int,
        minimumRarity: FlipRarity = .epic
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

                for rarity in FlipRarity.eventRarities(for: harmonicDepth) where rarity >= minimumRarity {
                    var bin = firstCandidateBin(reading: reading, rarity: rarity)
                    while let currentBin = bin,
                          currentBin > 0,
                          currentBin < reading.binCount
                    {
                        let date = reading.date(forBinIndex: currentBin)
                        if date >= end { break }

                        if date >= start && !isBoundaryDuplicate(bin: currentBin, rarity: rarity, reading: reading) {
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
            octalAddress: String(repeating: "7", count: reading.harmonicDepth),
            harmonicDepth: reading.harmonicDepth,
            rarity: .mythicDigit(7)
        )
        upsert(event, into: &eventsByBin)
    }

    private static func isBoundaryDuplicate(
        bin: Int,
        rarity: FlipRarity,
        reading: SarosClockReading
    ) -> Bool {
        rarity == .mythicDigit(7) && bin == reading.binCount - 1
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

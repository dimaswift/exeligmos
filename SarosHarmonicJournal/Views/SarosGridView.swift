import SwiftData
import SwiftUI

struct SarosGridView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @AppStorage(JournalSettings.pulseSarosKey) private var pulseSaros = 0
    @Query(sort: \JournalTag.createdAt, order: .forward) private var tags: [JournalTag]

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
                                SarosGridLiveGlyphRow(
                                    flip: nearestFlip,
                                    sarosReading: reading(for: nearestFlip.saros, at: context.date),
                                    pulseReading: pulseReading(at: context.date),
                                    moonReading: moonReading(at: context.date)
                                )
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
                                        highlightRarity: nearestFlip?.saros == series.saros ? nearestFlip?.rarity : nil,
                                        primeTint: primeColorsBySaros[series.saros]
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

    private var primeColorsBySaros: [Int: Color] {
        tags.filter(\.isPrime).reduce(into: [Int: Color]()) { colors, tag in
            colors[tag.saros] = colors[tag.saros] ?? Color(hex: tag.tintHex, fallback: .white)
        }
    }

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
        let topBreathingRoom: CGFloat = 78
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

    private func reading(for saros: Int, at date: Date) -> SarosClockReading? {
        activeSeries.first(where: { $0.saros == saros })?
            .reading(at: date, harmonicDepth: harmonicDepth)
    }

    private func pulseReading(at date: Date) -> SarosPulseReading? {
        let resolvedSaros: Int?
        if pulseSaros > 0 {
            resolvedSaros = pulseSaros
        } else {
            resolvedSaros = try? SarosPulseCalculator.defaultActiveSaros(
                at: date,
                eclipseService: services.eclipseService
            )
        }

        guard let resolvedSaros else { return nil }
        return try? SarosPulseCalculator.reading(
            saros: resolvedSaros,
            date: date,
            harmonicDepth: harmonicDepth,
            eclipseService: services.eclipseService
        )
    }

    private func moonReading(at date: Date) -> MoonPhaseOctalReading? {
        try? services.moonPhaseService.octalReading(for: date, depth: 3)
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

struct SarosCurrentWaveTimelineView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    @State private var activeSeries: [ActiveSarosPhaseSeries] = []
    @State private var currentFlip: SarosGridNearestFlip?
    @State private var errorMessage: String?

    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let currentFlip {
                SarosSpikeWaveTimelineView(flip: currentFlip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    errorMessage ?? "No active Saros waveform",
                    systemImage: "waveform.path.ecg"
                )
                .navigationTitle("Waveform")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            loadActiveSeries()
        }
        .onReceive(timer) { date in
            updateCurrentFlip(at: date)
        }
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
                    updateCurrentFlip(at: now)
                case .failure(let error):
                    activeSeries = []
                    currentFlip = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func updateCurrentFlip(at date: Date) {
        guard let nextFlip = nearestFlip(at: date) else {
            currentFlip = nil
            return
        }

        if currentFlip?.id != nextFlip.id {
            currentFlip = nextFlip
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

private struct SarosGridLiveGlyphRow: View {
    let flip: SarosGridNearestFlip
    let sarosReading: SarosClockReading?
    let pulseReading: SarosPulseReading?
    let moonReading: MoonPhaseOctalReading?

    var body: some View {
        HStack(spacing: 24) {
            sarosGlyph
            pulseGlyph
            moonGlyph
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open waveform")
    }

    private var sarosGlyph: some View {
        let value = sarosReading?.octalAddress ?? flip.octalAddress
        let depth = sarosReading?.harmonicDepth ?? flip.harmonicDepth
        let color = sarosReading?.currentRarity.color ?? flip.rarity.color

        return OctalGlyph(value: value, depth: depth, color: color)
            .frame(width: Self.glyphSize, height: Self.glyphSize)
            .accessibilityLabel("Saros phase")
    }

    @ViewBuilder
    private var pulseGlyph: some View {
        if let pulseReading {
            SarosPulseGlyph(reading: pulseReading, size: Self.glyphSize)
        } else {
            OctalGlyph(value: "000000", depth: SarosPulseCalculator.pulseDepth, color: .white.opacity(0.45))
                .frame(width: Self.glyphSize, height: Self.glyphSize)
                .accessibilityLabel("Pulse unavailable")
        }
    }

    @ViewBuilder
    private var moonGlyph: some View {
        if let moonReading {
            MoonPhaseGlyph(reading: moonReading)
                .frame(width: Self.glyphSize, height: Self.glyphSize)
        } else {
            OctalGlyph(value: "000", depth: 3, color: .white.opacity(0.45))
                .frame(width: Self.glyphSize, height: Self.glyphSize)
                .accessibilityLabel("Moon phase unavailable")
        }
    }

    private static let glyphSize: CGFloat = 54
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
    let momentumEnergyPerSaros: Double
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
    let contributors: [SarosGlobalFlipEvent]
    let period: SarosSpikePeriod
    let sequenceKey: String
    let leftBoundary: Date
    let rightBoundary: Date
    let peakHeight: Double
    let waveformModel: JournalWaveformModel
    let parabolaA: Double
    let parabolaAscentAccelerates: Bool
    let parabolaDescentAccelerates: Bool

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

    func energy(at date: Date) -> Double {
        guard !points.isEmpty, interval.duration > 0 else { return 0 }
        let targetPos = date.timeIntervalSince(interval.start) / interval.duration
        
        var low = 0
        var high = points.count - 1
        
        while low < high {
            let mid = (low + high) / 2
            if points[mid].position < targetPos {
                low = mid + 1
            } else {
                high = mid
            }
        }
        
        var closestIndex = low
        if low > 0 {
            let diffCurrent = abs(points[low].position - targetPos)
            let diffPrev = abs(points[low - 1].position - targetPos)
            if diffPrev < diffCurrent {
                closestIndex = low - 1
            }
        }
        
        return points[closestIndex].energy
    }
}

private struct SarosSpikeWaveCacheKey: Hashable {
    let harmonicDepth: Int
    let waveformModelID: String
    let parabolaAKey: Int
    let mergesCloseSpikes: Bool
    let normalizesAmplitude: Bool
    let amplitudeMultiplierKey: Int
    let subdivisionDepth: Int
    let displayStart: Int
    let displayEnd: Int
    let loadStart: Int
    let loadEnd: Int
    let sampleCount: Int
    let minimumRarityID: String
    let includesSeriesEclipseMetrics: Bool
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
    let subdivisionDepth: Int

    private let componentsByEventID: [String: SarosSpikeWaveComponent]

    init(
        components: [SarosSpikeWaveComponent],
        subdivisionDepth: Int = JournalWaveformSettings.defaultSubdivisionDepth
    ) {
        self.components = components
        self.maxPeakHeight = components.map(\.peakHeight).max() ?? 0
        self.subdivisionDepth = min(
            max(subdivisionDepth, JournalWaveformSettings.subdivisionDepthRange.lowerBound),
            JournalWaveformSettings.subdivisionDepthRange.upperBound
        )
        self.componentsByEventID = components.reduce(into: [:]) { lookup, component in
            for event in component.contributors {
                lookup[event.id] = component
            }
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
        let sarosDuration = SarosPulseCalculator.averageDuration(for: .saros)
        let beforeEnergy = energy(at: date.addingTimeInterval(-sarosDuration))
        let afterEnergy = energy(at: date.addingTimeInterval(sarosDuration))
        let momentumEnergyPerSaros = (afterEnergy - beforeEnergy) / peakHeight

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
            momentumEnergyPerSaros: momentumEnergyPerSaros,
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
        let sampleDates = adaptiveSampleDates(
            in: interval,
            components: visibleComponents,
            preferredSampleCount: sampleCount
        )
        let points = sampleDates.map { date in
            let position = min(max(date.timeIntervalSince(interval.start) / interval.duration, 0), 1)
            let energy = energy(at: date, in: visibleComponents)
            maxEnergy = max(maxEnergy, energy)

            return SarosSpikeWaveSample(position: position, energy: energy)
        }

        let eventEnergyByID = Dictionary(uniqueKeysWithValues: events.map { event in
            if let component = componentsByEventID[event.id], visibleComponents.contains(where: { $0.id == component.id }) {
                return (event.id, component.energy(at: component.period.spike.date))
            }
            return (event.id, energy(at: event.date, in: visibleComponents))
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
        let visiblePeak = adaptiveSampleDates(
            in: interval,
            components: visibleComponents,
            preferredSampleCount: sampleCount
        )
        .reduce(0.0) { currentMax, date in
            let energy = visibleComponents.reduce(0.0) { total, component in
                guard component.contains(date) else { return total }
                return total + component.energy(at: date)
            }

            return max(currentMax, energy)
        }

        return max(visiblePeak, maxPeakHeight, 0.000_000_001)
    }

    private func adaptiveSampleDates(
        in interval: DateInterval,
        components visibleComponents: [SarosSpikeWaveComponent],
        preferredSampleCount: Int
    ) -> [Date] {
        guard interval.duration > 0 else { return [] }

        let anchors = ([interval.start, interval.end] + visibleComponents.flatMap { component in
            [
                interval.start,
                component.leftBoundary,
                component.period.spike.date,
                component.rightBoundary,
                interval.end
            ]
            .filter { interval.contains($0) || $0 == interval.end }
        })
        .sorted()
        .reduce(into: [Date]()) { unique, date in
            guard unique.last.map({ abs($0.timeIntervalSince(date)) > 0.001 }) ?? true else { return }
            unique.append(date)
        }

        guard anchors.count > 1 else { return anchors }

        let segmentCount = max(anchors.count - 1, 1)
        let maximumDivisions = 1 << subdivisionDepth
        let preferredDivisions = max(preferredSampleCount / segmentCount, 1)
        let divisions = min(maximumDivisions, preferredDivisions)
        var dates: [Date] = []
        dates.reserveCapacity(segmentCount * divisions + 1)

        for index in 0..<(anchors.count - 1) {
            let start = anchors[index]
            let end = anchors[index + 1]
            let duration = end.timeIntervalSince(start)
            if index == 0 {
                dates.append(start)
            }
            guard duration > 0 else { continue }
            for step in 1...divisions {
                dates.append(start.addingTimeInterval(duration * Double(step) / Double(divisions)))
            }
        }

        return dates
    }
}

private enum SarosSpikeWaveCalculator {
    private static let baseAmplitudeMultiplier = 2.5

    private struct EventCluster {
        let primary: SarosGlobalFlipEvent
        let contributors: [SarosGlobalFlipEvent]

        var date: Date {
            primary.date
        }
    }

    static func field(
        events: [SarosGlobalFlipEvent],
        model: JournalWaveformModel = JournalWaveformModel.current,
        parabolaA: Double = JournalWaveformSettings.currentParabolaA,
        options: JournalWaveformOptions = .current
    ) -> SarosSpikeWaveField {
        let clusters = preprocessedClusters(events: events, options: options)

        let components = clusters.indices.compactMap { index -> SarosSpikeWaveComponent? in
            let cluster = clusters[index]
            let spike = cluster.primary
            let previous = previousDistinctCluster(in: clusters, before: index)?.primary
            let next = nextDistinctCluster(in: clusters, after: index)?.primary
            let leftGap = max(previous.map { spike.date.timeIntervalSince($0.date) } ?? next.map { $0.date.timeIntervalSince(spike.date) } ?? 86_400, 1)
            let rightGap = max(next.map { $0.date.timeIntervalSince(spike.date) } ?? leftGap, 1)
            let leftBoundary = previous.map { midpoint($0.date, spike.date) }
                ?? spike.date.addingTimeInterval(-leftGap / 2)
            let rightBoundary = next.map { midpoint(spike.date, $0.date) }
                ?? spike.date.addingTimeInterval(rightGap / 2)

            return component(
                cluster: cluster,
                previous: previous,
                next: next,
                leftBoundary: leftBoundary,
                rightBoundary: rightBoundary,
                index: index,
                model: model,
                parabolaA: parabolaA,
                options: options
            )
        }

        return SarosSpikeWaveField(
            components: components,
            subdivisionDepth: options.subdivisionDepth
        )
    }

    static func state(
        at date: Date,
        events: [SarosGlobalFlipEvent],
        model: JournalWaveformModel = JournalWaveformModel.current,
        parabolaA: Double = JournalWaveformSettings.currentParabolaA
    ) -> SarosSpikeWaveState? {
        field(events: events, model: model, parabolaA: parabolaA).sample(at: date)
    }

    private static func preprocessedClusters(
        events: [SarosGlobalFlipEvent],
        options: JournalWaveformOptions
    ) -> [EventCluster] {
        let sortedEvents = events
            .filter { !options.ignorePartialEclipses || !$0.isPartialEclipse }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date < rhs.date
                }
                if lhs.rarity != rhs.rarity {
                    return lhs.rarity > rhs.rarity
                }
                return lhs.saros < rhs.saros
            }

        guard options.mergeCloseSpikes else {
            return sortedEvents.map { EventCluster(primary: $0, contributors: [$0]) }
        }

        var clusters: [EventCluster] = []
        var current: [SarosGlobalFlipEvent] = []

        for event in sortedEvents {
            if let last = current.last,
               event.date.timeIntervalSince(last.date) > options.mergeThreshold
            {
                clusters.append(makeCluster(from: current))
                current = []
            }
            current.append(event)
        }

        if !current.isEmpty {
            clusters.append(makeCluster(from: current))
        }

        return clusters.sorted {
            if $0.date != $1.date {
                return $0.date < $1.date
            }
            return $0.primary.rarity > $1.primary.rarity
        }
    }

    private static func makeCluster(from events: [SarosGlobalFlipEvent]) -> EventCluster {
        let primary = events.max {
            if $0.rarity != $1.rarity {
                return $0.rarity < $1.rarity
            }
            if $0.seriesEclipseMagnitude ?? 0 != $1.seriesEclipseMagnitude ?? 0 {
                return ($0.seriesEclipseMagnitude ?? 0) < ($1.seriesEclipseMagnitude ?? 0)
            }
            return $0.date > $1.date
        } ?? events[0]
        return EventCluster(primary: primary, contributors: events)
    }

    private static func basePeakHeight(for rarity: FlipRarity) -> Double {
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

    private static func peakHeight(
        for event: SarosGlobalFlipEvent,
        normalizedAmplitude: Bool,
        amplitudeMultiplier: Double
    ) -> Double {
        (normalizedAmplitude ? 1 : basePeakHeight(for: event.rarity))
            * Self.baseAmplitudeMultiplier
            * amplitudeMultiplier
            * magnitudeAmplitudeMultiplier(for: event.seriesEclipseMagnitude)
    }

    private static func magnitudeAmplitudeMultiplier(for magnitude: Double?) -> Double {
        guard let magnitude, magnitude.isFinite else { return 1 }
        return min(max(magnitude, 0.18), 1.8)
    }

    private static func component(
        cluster: EventCluster,
        previous: SarosGlobalFlipEvent?,
        next: SarosGlobalFlipEvent?,
        leftBoundary: Date,
        rightBoundary: Date,
        index: Int,
        model: JournalWaveformModel,
        parabolaA: Double,
        options: JournalWaveformOptions
    ) -> SarosSpikeWaveComponent? {
        let source = cluster.primary
        let duration = rightBoundary.timeIntervalSince(leftBoundary)
        guard duration > 1 else { return nil }

        return SarosSpikeWaveComponent(
            id: "\(source.id)-\(model.id)-\(index)",
            sourceEventID: source.id,
            contributors: cluster.contributors,
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
            peakHeight: cluster.contributors
                .map {
                    peakHeight(
                        for: $0,
                        normalizedAmplitude: options.normalizedAmplitude,
                        amplitudeMultiplier: options.amplitudeMultiplier
                    )
                }
                .reduce(0, +),
            waveformModel: model,
            parabolaA: parabolaA,
            parabolaAscentAccelerates: parabolaAscentAccelerates(
                event: source,
                fallbackSeed: source.saros + index
            ),
            parabolaDescentAccelerates: parabolaDescentAccelerates(
                event: source,
                fallbackSeed: source.saros + index
            )
        )
    }

    private static func parabolaAscentAccelerates(
        event: SarosGlobalFlipEvent,
        fallbackSeed: Int
    ) -> Bool {
        if let seriesProgressesSouthToNorth = event.seriesProgressesSouthToNorth {
            return seriesProgressesSouthToNorth
        }

        guard let gamma = event.seriesEclipseGamma, gamma.isFinite, gamma != 0 else {
            return fallbackSeed.isMultiple(of: 2)
        }
        return gamma > 0
    }

    private static func parabolaDescentAccelerates(
        event: SarosGlobalFlipEvent,
        fallbackSeed: Int
    ) -> Bool {
        if let isPastSeriesMidpoint = event.isPastSeriesMidpoint {
            return isPastSeriesMidpoint
        }
        return !fallbackSeed.isMultiple(of: 2)
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

    private static func previousDistinctCluster(
        in clusters: [EventCluster],
        before index: Int
    ) -> EventCluster? {
        guard index > clusters.startIndex else { return nil }
        var cursor = index - 1

        while cursor >= clusters.startIndex {
            if clusters[cursor].date != clusters[index].date {
                return clusters[cursor]
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

    private static func nextDistinctCluster(
        in clusters: [EventCluster],
        after index: Int
    ) -> EventCluster? {
        var cursor = index + 1

        while cursor < clusters.endIndex {
            if clusters[cursor].date != clusters[index].date {
                return clusters[cursor]
            }
            cursor += 1
        }

        return nil
    }
}

private extension SarosSpikeWaveComponent {
    var periodInterval: DateInterval {
        DateInterval(start: leftBoundary, end: rightBoundary)
    }

    func contains(_ date: Date) -> Bool {
        date >= leftBoundary && date <= rightBoundary
    }

    func energy(at date: Date) -> Double {
        guard contains(date) else { return 0 }
        return parabolaEnergy(at: date)
    }

    func derivative(at date: Date) -> Double {
        guard contains(date) else { return 0 }

        let step = min(max(width(for: date.timeIntervalSince(period.spike.date)) / 600, 60), 1_800)
        let before = max(leftBoundary, date.addingTimeInterval(-step))
        let after = min(rightBoundary, date.addingTimeInterval(step))
        let duration = max(after.timeIntervalSince(before), 1)

        return (energy(at: after) - energy(at: before)) / duration
    }

    private func parabolaEnergy(at date: Date) -> Double {
        let a = min(max(parabolaA, 1.0), 8.0)
        let value: Double

        if date <= period.spike.date {
            let duration = max(period.spike.date.timeIntervalSince(leftBoundary), 1)
            let t = min(max(date.timeIntervalSince(leftBoundary) / duration, 0), 1)
            value = parabolaAscentAccelerates
                ? pow(t, a)
                : 1 - pow(1 - t, a)
        } else {
            let duration = max(rightBoundary.timeIntervalSince(period.spike.date), 1)
            let t = min(max(date.timeIntervalSince(period.spike.date) / duration, 0), 1)
            value = parabolaDescentAccelerates
                ? 1 - pow(t, a)
                : pow(1 - t, a)
        }

        return peakHeight * min(max(value, 0), 1)
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

private struct SarosSpikeDateJump: Identifiable, Hashable {
    let id = UUID()
    let date: Date
}

private class TimelineCurrentTimeTicker: ObservableObject {
    @Published var date = Date()
    private var timer: Timer?
    
    init() {
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.date = Date()
            }
        }
    }
    
    deinit {
        timer?.invalidate()
    }
}

private struct SarosSpikeWaveTimelineView: View {
    @EnvironmentObject private var services: AppServices
    @Query(sort: \JournalEntry.eventDate, order: .reverse) private var allEntries: [JournalEntry]
    @Query(sort: \JournalTag.createdAt, order: .forward) private var tags: [JournalTag]

    let flip: SarosGridNearestFlip

    @State private var events: [SarosGlobalFlipEvent] = []
    @State private var waveField = SarosSpikeWaveField.empty
    @State private var waveSamples = SarosSpikeWaveSamples.empty
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var zoom: CGFloat = Self.initialZoom
    @State private var gestureScale: CGFloat = 1
    @State private var contentMinX: CGFloat = 0
    @State private var scrollAnchorDate: Date?
    @State private var scrollAnchorID: String?
    @State private var zoomAnchorDate: Date?
    @State private var selectedCalendarReference: SarosSpikeCalendarReference?
    @State private var probeDate: Date?
    @State private var solarTicks: [SolarYearRulerTick] = []
    @State private var lunarTicks: [LunarRulerTick] = []
    @State private var pulseTicks: [SarosPulseTick] = []
    @State private var selectedSegmentID: String?
    @State private var didApplyInitialZoom = false
    @State private var didApplyInitialScroll = false
    @State private var loadedPageStarts: [Date] = []
    @State private var pendingPageScrollDate: Date?
    @State private var isEdgeLoading = false
    @State private var selectedEntry: JournalEntry?
    @State private var selectedDetailEntry: JournalEntry?
    @State private var showingSegmentEvents: SarosSpikeWaveSegment?
    @State private var dateJump: SarosSpikeDateJump?
    @AppStorage("timelineShowEvents") private var timelineShowEvents = true
 
    @AppStorage("timelineMinimumWaveRarity") private var timelineMinimumWaveRarityRaw = "epic"
    @AppStorage("timelineUseSineWaveforms") private var timelineUseSineWaveforms = false
    @AppStorage("timelineSineWaveSumMode") private var timelineSineWaveSumMode = false
    @AppStorage("timelineWavelengthOption") private var timelineWavelengthOption = 2.0
    @AppStorage(JournalSettings.timelineWaveColorModeKey) private var timelineWaveColorModeRaw = TimelineWaveColorMode.current.rawValue

    @AppStorage(JournalSettings.pulseSarosKey) private var pulseSaros = 0

    private let densityOptions: [FlipRarity] = [.rare, .epic, .legendary, .mythic]

    private var timelineMinimumWaveRarity: FlipRarity {
        FlipRarity(rawValue: timelineMinimumWaveRarityRaw) ?? .epic
    }

    private var timelineWaveColorMode: TimelineWaveColorMode {
        TimelineWaveColorMode(rawValue: timelineWaveColorModeRaw) ?? .current
    }
    @AppStorage(JournalSettings.waveformMergeCloseSpikesKey) private var waveformMergeCloseSpikes = false
    @AppStorage(JournalSettings.waveformNormalizedAmplitudeKey) private var waveformNormalizedAmplitude = false
    @AppStorage(JournalSettings.waveformSubdivisionDepthKey) private var waveformSubdivisionDepth = JournalWaveformSettings.defaultSubdivisionDepth
    @AppStorage(JournalSettings.waveformAmplitudeMultiplierKey) private var waveformAmplitudeMultiplier = JournalWaveformSettings.defaultAmplitudeMultiplier
    @AppStorage(JournalSettings.solarSiderealReferenceDateKey) private var solarSiderealReferenceTimestamp = SolarYearRuler.defaultSiderealReferenceDate.timeIntervalSince1970

    private var displayInterval: DateInterval {
        let starts = normalizedLoadedPageStarts
        guard let start = starts.first else {
            return DateInterval(
                start: pageStart(containing: flip.observedAt),
                duration: Self.tetrasarosDuration
            )
        }

        return DateInterval(
            start: start,
            duration: Self.tetrasarosDuration * Double(max(starts.count, 1))
        )
    }

    private var normalizedLoadedPageStarts: [Date] {
        let starts = loadedPageStarts.isEmpty
            ? [pageStart(containing: flip.observedAt)]
            : loadedPageStarts
        return Array(Set(starts)).sorted()
    }

    private var loadInterval: DateInterval {
        DateInterval(
            start: displayInterval.start.addingTimeInterval(-Self.loadPaddingDuration),
            end: displayInterval.end.addingTimeInterval(Self.loadPaddingDuration)
        )
    }

    private var effectiveZoom: CGFloat {
        min(max(zoom * gestureScale, Self.minimumZoom), maximumZoom)
    }

    private var visibleEvents: [SarosGlobalFlipEvent] {
        events.filter { event in
            event.date >= displayInterval.start && event.date < displayInterval.end
        }
    }

    private var visibleEntries: [JournalEntry] {
        allEntries.filter { entry in
            guard let emoji = entry.emoji, !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            let start = entry.eventDate
            let end = entry.effectiveEndDate
            return start <= displayInterval.end && end >= displayInterval.start
        }
    }

    private struct OneTimeEmojiMarker: Identifiable {
        let entry: JournalEntry
        let x: CGFloat
        let y: CGFloat
        var id: UUID { entry.id }
    }

    private struct ContinuousEmojiMarker: Identifiable {
        let entry: JournalEntry
        let startX: CGFloat
        let endX: CGFloat
        let midX: CGFloat
        let controlY: CGFloat
        let emojiY: CGFloat
        var id: UUID { entry.id }
    }

    private func computeEmojiMarkers(
        entries: [JournalEntry],
        contentWidth: CGFloat,
        height: CGFloat,
        waveBaseline: CGFloat,
        waveHeight: CGFloat,
        waveMaxEnergy: Double
    ) -> (oneTime: [OneTimeEmojiMarker], continuous: [ContinuousEmojiMarker]) {
        let KsDuration = SarosPulseCalculator.averageDuration(for: .kilo)
        let visible = entries.filter { entry in
            guard let emoji = entry.emoji, !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            return true
        }
        
        let oneTimeEntries = visible.filter { $0.effectiveEndDate.timeIntervalSince($0.eventDate) <= KsDuration }
        let continuousEntries = visible.filter { $0.effectiveEndDate.timeIntervalSince($0.eventDate) > KsDuration }
        
        // 1. Compute One-Time Markers
        var oneTimeMarkers: [OneTimeEmojiMarker] = []
        var oneTimePlaced: [Int: [ClosedRange<CGFloat>]] = [:] // level -> ranges
        
        let sortedOneTime = oneTimeEntries.sorted(by: { $0.eventDate < $1.eventDate })
        for entry in sortedOneTime {
            let x = xPosition(for: entry.eventDate, width: contentWidth)
            let eventEnergy = waveSamples.energy(at: entry.eventDate)
            let waveY = waveBaseline - CGFloat(eventEnergy / max(waveMaxEnergy, 0.000_000_001)) * waveHeight
            
            let range = (x - 10)...(x + 10)
            var level = 0
            while true {
                let overlaps = oneTimePlaced[level]?.contains(where: { $0.overlaps(range) }) ?? false
                if !overlaps { break }
                level += 1
            }
            if oneTimePlaced[level] == nil {
                oneTimePlaced[level] = []
            }
            oneTimePlaced[level]?.append(range)
            
            let y = waveY - 12 - CGFloat(level) * 16
            oneTimeMarkers.append(OneTimeEmojiMarker(entry: entry, x: x, y: y))
        }
        
        // 2. Compute Continuous Markers
        var continuousMarkers: [ContinuousEmojiMarker] = []
        var continuousPlaced: [Int: [ClosedRange<CGFloat>]] = [:] // level -> ranges
        
        let sortedContinuous = continuousEntries.sorted(by: { $0.eventDate < $1.eventDate })
        for entry in sortedContinuous {
            let startX = xPosition(for: entry.eventDate, width: contentWidth)
            let endX = xPosition(for: entry.effectiveEndDate, width: contentWidth)
            let midX = (startX + endX) / 2
            
            let range = (startX - 6)...(endX + 6)
            var level = 0
            while true {
                let overlaps = continuousPlaced[level]?.contains(where: { $0.overlaps(range) }) ?? false
                if !overlaps { break }
                level += 1
            }
            if continuousPlaced[level] == nil {
                continuousPlaced[level] = []
            }
            continuousPlaced[level]?.append(range)
            
            let controlY = waveBaseline + 36 + CGFloat(level) * 24
            let emojiY = waveBaseline + (controlY - waveBaseline) * 0.72
            
            continuousMarkers.append(ContinuousEmojiMarker(
                entry: entry,
                startX: startX,
                endX: endX,
                midX: midX,
                controlY: controlY,
                emojiY: emojiY
            ))
        }
        
        return (oneTimeMarkers, continuousMarkers)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            VStack(spacing: 14) {
                TickingStatePanel(
                    probeDate: probeDate,
                    waveField: waveField,
                    events: events,
                    segment: selectedSegment,
                    pulseReadingAt: { date in pulseReading(at: date) },
                    sarosReadingFor: { state in sarosReading(for: state) },
                    onHeaderTap: { scrollToPresent(proxy: scrollProxy) },
                    onShowEvents: { showingSegmentEvents = selectedSegment }
                )

                if let selectedEntry {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Selected Entry")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                self.selectedEntry = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        JournalEntryRow(entry: selectedEntry, tags: tags)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                            .onTapGesture {
                                selectedDetailEntry = selectedEntry
                            }
                    }
                    .padding(.horizontal)
                    .transition(.opacity)
                }

                HStack(spacing: 10) {
                    Button {
                        appendAdjacentPage(-1, proxy: scrollProxy)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Previous period")

                    Button {
                        dateJump = SarosSpikeDateJump(date: defaultJumpDate)
                    } label: {
                        Text(periodRangeTitle)
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to date")

                    Button {
                        appendAdjacentPage(1, proxy: scrollProxy)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Next period")
                }
                .padding(.horizontal)

                GeometryReader { geometry in
                    let contentWidth = max(
                        geometry.size.width * effectiveZoom,
                        geometry.size.width
                    )
                    let height = max(geometry.size.height, 320)
                    let axisTicks = axisTicks()
                    let hourTicks = axisHourTicks(showLabels: effectiveZoom >= 80)
                    let dayLabels = axisDayLabels()
                    let markerComponents = waveField.components.filter {
                        displayInterval.contains($0.period.spike.date)
                    }
                    let markerEvents = markerComponents.map(\.period.spike)
                    let midpointDates = markerComponents.flatMap { [$0.leftBoundary, $0.rightBoundary] }
                        .filter { displayInterval.contains($0) }
                    let effectiveSelectedSegment = selectedSegment
                    let waveMaxEnergy = waveSamples.maxEnergy
                    let dotMarkers = eventDotMarkers(
                        components: markerComponents,
                        contentWidth: contentWidth,
                        height: height,
                        maxEnergy: waveMaxEnergy,
                        amplitudeScale: timelineWaveAmplitudeScale
                    )

                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            SarosSpikeWaveCanvas(
                                samples: waveSamples,
                                displayInterval: displayInterval,
                                maxEnergy: waveMaxEnergy,
                                amplitudeScale: timelineWaveAmplitudeScale
                            )
                            .frame(width: contentWidth, height: height)

                            if let selected = effectiveSelectedSegment {
                                SarosSpikeSegmentHighlight(
                                    segment: selected,
                                    displayInterval: displayInterval
                                )
                                .frame(width: contentWidth, height: height)
                            }

                            SarosSpikeMarkersCanvas(
                                events: markerEvents,
                                dots: dotMarkers,
                                midpoints: midpointDates,
                                displayInterval: displayInterval,
                                tickStartY: Self.lunarRulerBottomY,
                                tickEndY: Self.solarRulerTopY(in: height)
                            )
                            .frame(width: contentWidth, height: height)

                            SarosPulseRulerCanvas(
                                ticks: pulseTicks,
                                displayInterval: displayInterval,
                                tickStartY: Self.lunarRulerBottomY,
                                tickEndY: Self.solarRulerTopY(in: height)
                            )
                            .frame(width: contentWidth, height: height)

                            LunarRulerCanvas(
                                ticks: lunarTicks,
                                displayInterval: displayInterval,
                                topInset: Self.lunarRulerTopInset,
                                rowSpacing: Self.lunarRulerRowSpacing,
                                labelOffset: 15,
                                showSineWave: timelineUseSineWaveforms,
                                waveSumMode: timelineSineWaveSumMode,
                                wavelengthOption: timelineWavelengthOption,
                                waveColorMode: timelineWaveColorMode
                            )
                            .frame(width: contentWidth, height: height)

                            SolarYearRulerCanvas(
                                ticks: solarTicks,
                                displayInterval: displayInterval,
                                baselineRatio: Self.solarRulerBaselineRatio,
                                rowSpacing: Self.solarRulerRowSpacing,
                                showSineWave: timelineUseSineWaveforms,
                                waveSumMode: timelineSineWaveSumMode,
                                wavelengthOption: timelineWavelengthOption,
                                waveColorMode: timelineWaveColorMode
                            )
                            .frame(width: contentWidth, height: height)

                            if timelineShowEvents {
                                let waveBaseline = height * 0.54
                                let waveTop = height * 0.12
                                let waveHeight = (waveBaseline - waveTop) * timelineWaveAmplitudeScale
                                let waveMaxEnergy = max(waveMaxEnergy, 0.000_000_001)
                                
                                let markers = computeEmojiMarkers(
                                    entries: visibleEntries,
                                    contentWidth: contentWidth,
                                    height: height,
                                    waveBaseline: waveBaseline,
                                    waveHeight: waveHeight,
                                    waveMaxEnergy: waveMaxEnergy
                                )
                                
                                // 1. Arcs for continuous events
                                ForEach(markers.continuous) { marker in
                                    Path { path in
                                        path.move(to: CGPoint(x: marker.startX, y: waveBaseline))
                                        path.addQuadCurve(
                                            to: CGPoint(x: marker.endX, y: waveBaseline),
                                            control: CGPoint(x: marker.midX, y: marker.controlY)
                                        )
                                    }
                                    .stroke(Color.primary.opacity(0.24), lineWidth: 1.2)
                                }
                                
                                // 2. Emojis for continuous events (middle of the arc)
                                ForEach(markers.continuous) { marker in
                                    Text(marker.entry.emoji ?? "")
                                        .font(.system(size: 9))
                                        .padding(3)
                                        .background(Circle().fill(.ultraThinMaterial))
                                        .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 0.5)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
                                        )
                                        .contentShape(Circle())
                                        .onTapGesture {
                                            selectedDetailEntry = marker.entry
                                        }
                                        .simultaneousGesture(
                                            LongPressGesture(minimumDuration: 0.45)
                                                .onEnded { _ in
                                                    selectedEntry = marker.entry
                                                }
                                        )
                                        .position(x: marker.midX, y: marker.emojiY)
                                }
                                
                                // 3. Emojis for one-time events (on top of the waveform)
                                ForEach(markers.oneTime) { marker in
                                    Text(marker.entry.emoji ?? "")
                                        .font(.system(size: 9))
                                        .padding(3)
                                        .background(Circle().fill(.ultraThinMaterial))
                                        .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 0.5)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
                                        )
                                        .contentShape(Circle())
                                        .onTapGesture {
                                            selectedDetailEntry = marker.entry
                                        }
                                        .simultaneousGesture(
                                            LongPressGesture(minimumDuration: 0.45)
                                                .onEnded { _ in
                                                    selectedEntry = marker.entry
                                                }
                                        )
                                        .position(x: marker.x, y: marker.y)
                                }
                            }

                            TickingReferenceScrollAnchor(
                                probeDate: probeDate,
                                displayInterval: displayInterval,
                                contentWidth: contentWidth,
                                height: height,
                                scrollID: Self.referenceScrollID
                            )

                            TickingProbeHandle(
                                probeDate: probeDate,
                                displayInterval: displayInterval,
                                contentWidth: contentWidth,
                                height: height,
                                onDrag: { x in
                                    moveProbe(toX: x, contentWidth: contentWidth)
                                }
                            )

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
                                        y: height - 22
                                    )
                            }

                            ForEach(hourTicks) { tick in
                                SarosSpikeWaveHourTickView(tick: tick)
                                    .position(
                                        x: xPosition(for: tick.date, width: contentWidth),
                                        y: height - 22
                                    )
                            }

                            ForEach(dayLabels) { label in
                                SarosSpikeWaveDayLabelView(label: label)
                                    .position(
                                        x: xPosition(for: label.date, width: contentWidth),
                                        y: height - 12
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
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    if zoomAnchorDate == nil {
                                        let candidate = probeDate ?? Date()
                                        let anchorDate = displayInterval.contains(candidate)
                                            ? candidate
                                            : centerDate(
                                                contentWidth: contentWidth,
                                                viewportWidth: geometry.size.width
                                            )
                                        zoomAnchorDate = anchorDate
                                        scrollAnchorDate = anchorDate
                                    }
                                    gestureScale = value
                                }
                                .onEnded { value in
                                    zoom = min(max(zoom * value, Self.minimumZoom), maximumZoom)
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
                        if abs(contentMinX - value) > Self.scrollOffsetUpdateThreshold {
                            contentMinX = value
                        }
                        handleEdgeProximity(
                            contentMinX: value,
                            contentWidth: contentWidth,
                            viewportWidth: geometry.size.width,
                            proxy: scrollProxy
                        )
                    }
                    .onAppear {
                        ensureLoadedPagesInitialized()
                        applyInitialZoomIfNeeded()
                        applyInitialScrollIfNeeded(proxy: scrollProxy)
                    }
                    .onChange(of: events.count) { _, _ in
                        applyPendingScrollIfNeeded(proxy: scrollProxy)
                    }
                    .onChange(of: Int(displayInterval.start.timeIntervalSince1970)) { _, _ in
                        applyPendingScrollIfNeeded(proxy: scrollProxy, layoutDelay: 0.10)
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
            .navigationTitle("Waveform")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Menu {
                            Section("Waveform Settings") {
                                Picker("Spike Density", selection: $timelineMinimumWaveRarityRaw) {
                                    ForEach(densityOptions, id: \.rawValue) { rarity in
                                        Text(rarity.title).tag(rarity.rawValue)
                                    }
                                }
                            }

                            Section("Ruler Style") {
                                Picker("Wave Color", selection: $timelineWaveColorModeRaw) {
                                    ForEach(TimelineWaveColorMode.allCases) { mode in
                                        Text(mode.title).tag(mode.rawValue)
                                    }
                                }
                                .pickerStyle(.menu)

                                timelineWaveColorLegend

                                Toggle(isOn: $timelineUseSineWaveforms) {
                                    Label("Sine Waveforms", systemImage: "waveform.path")
                                }

                                Picker("Sine Wave Mode", selection: $timelineSineWaveSumMode) {
                                    Text("Wave Overlap").tag(false)
                                    Text("Wave Sum").tag(true)
                                }
                                .pickerStyle(.menu)
                                .disabled(!timelineUseSineWaveforms)

                                Picker("Wavelength", selection: $timelineWavelengthOption) {
                                    Text("0.5 Wavelength (Half)").tag(0.5)
                                    Text("1 Wavelength").tag(1.0)
                                    Text("2 Wavelengths").tag(2.0)
                                    Text("3 Wavelengths").tag(3.0)
                                    Text("4 Wavelengths").tag(4.0)
                                }
                                .pickerStyle(.menu)
                                .disabled(!timelineUseSineWaveforms)
                            }

                            Section("Events") {
                                Toggle(isOn: $timelineShowEvents) {
                                    Label("Show Events", systemImage: "flag.fill")
                                }
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel("Configure timeline settings")

                        Button {
                            selectedCalendarReference = SarosSpikeCalendarReference(date: Date())
                        } label: {
                            Image(systemName: "calendar")
                        }
                        .accessibilityLabel("Open Saros calendar")
                    }
                }
            }
            .task(id: waveformTaskID) {
                loadEvents(force: true)
            }
            .task(id: solarRulerTaskID) {
                await loadSolarTicks()
            }
            .task(id: lunarTaskID) {
                await loadLunarTicks()
            }
            .task(id: pulseTaskID) {
                await loadPulseTicks()
            }
            .sheet(item: $dateJump) { request in
                SarosSpikeDateJumpSheet(initialDate: request.date) { selectedDate in
                    jump(to: selectedDate, proxy: scrollProxy)
                }
            }
        }
        .navigationDestination(item: $selectedCalendarReference) { reference in
            SarosGlobalFlipTimelineView(
                referenceDate: reference.date,
                referenceEvent: nil
            )
        }
        .navigationDestination(item: $selectedDetailEntry) { entry in
            JournalEntryDetailView(entry: entry, tags: tags)
        }
        .sheet(item: $showingSegmentEvents) { segment in
            let segmentEntries = allEntries.filter { segment.interval.contains($0.eventDate) }
            SegmentEventsSheet(segment: segment, entries: segmentEntries, tags: tags)
        }
    }

    private static let tetrasarosDuration = SarosPulseCalculator.averageDuration(for: .giga) * 8
    private static let loadPaddingDuration: TimeInterval = SarosPulseCalculator.averageDuration(for: .giga)
    private static let minimumZoom: CGFloat = 1
    private static let initialZoom: CGFloat = 1
    private static let defaultVisibleDuration = SarosPulseCalculator.averageDuration(for: .mega) * 2
    private static let minimumVisibleDuration = SarosPulseCalculator.averageDuration(for: .mega)
    private static let waveSampleCount = 8_192
    private static let minimumWaveRarity = FlipRarity.epic
    private static let scrollOffsetUpdateThreshold: CGFloat = 28
    private static let edgeAutoLoadThreshold: CGFloat = 96
    private static let referenceScrollID = "saros-spike-reference"
    private static let scrollCoordinateSpace = "saros-spike-scroll"
    private static let lunarRulerTopInset: CGFloat = 28
    private static let lunarRulerRowSpacing: CGFloat = 15
    private static let lunarRulerBottomY = lunarRulerTopInset + lunarRulerRowSpacing * 2 + LunarRulerTickLevel.major.height
    private static let solarRulerBaselineRatio: CGFloat = 0.84
    private static let solarRulerRowSpacing: CGFloat = 15
    fileprivate static let baseWaveAmplitudeScale: CGFloat = 0.5

    private static func solarRulerTopY(in height: CGFloat) -> CGFloat {
        max(
            lunarRulerBottomY + 8,
            height * solarRulerBaselineRatio - solarRulerRowSpacing * 2 - LunarRulerTickLevel.major.height
        )
    }

    private var timelineWaveAmplitudeScale: CGFloat {
        let normalized = CGFloat(clampedAmplitudeMultiplier / JournalWaveformSettings.defaultAmplitudeMultiplier)
        return min(max(Self.baseWaveAmplitudeScale * normalized, 0.16), 0.92)
    }

    private var solarRulerTaskID: String {
        "\(Int(displayInterval.start.timeIntervalSince1970))-\(Int(displayInterval.end.timeIntervalSince1970))-\(Int(solarSiderealReferenceTimestamp))"
    }

    private var lunarTaskID: String {
        "\(Int(displayInterval.start.timeIntervalSince1970))-\(Int(displayInterval.end.timeIntervalSince1970))"
    }

    private var pulseTaskID: String {
        [
            "\(Int(displayInterval.start.timeIntervalSince1970))",
            "\(Int(displayInterval.end.timeIntervalSince1970))",
            "\(pulseSaros > 0 ? pulseSaros : flip.saros)",
            "\(flip.harmonicDepth)"
        ].joined(separator: "-")
    }

    private var waveformTaskID: String {
        [
            "\(Self.parabolaCacheKey(JournalWaveformSettings.currentParabolaA))",
            waveformMergeCloseSpikes ? "merged" : "raw",
            waveformNormalizedAmplitude ? "norm" : "weighted",
            "\(clampedSubdivisionDepth)",
            "\(Self.amplitudeCacheKey(clampedAmplitudeMultiplier))",
            "\(Int(displayInterval.start.timeIntervalSince1970))",
            "\(Int(displayInterval.end.timeIntervalSince1970))",
            "\(timelineMinimumWaveRarityRaw)"
        ].joined(separator: "-")
    }

    private var maximumZoom: CGFloat {
        max(Self.minimumZoom, CGFloat(displayInterval.duration / Self.minimumVisibleDuration))
    }

    private var defaultZoom: CGFloat {
        min(
            max(Self.minimumZoom, CGFloat(displayInterval.duration / Self.defaultVisibleDuration)),
            maximumZoom
        )
    }

    private var currentWaveformOptions: JournalWaveformOptions {
        JournalWaveformOptions(
            ignorePartialEclipses: false,
            mergeCloseSpikes: waveformMergeCloseSpikes,
            normalizedAmplitude: waveformNormalizedAmplitude,
            subdivisionDepth: clampedSubdivisionDepth,
            mergeThreshold: JournalWaveformSettings.mergeCloseSpikeThreshold,
            amplitudeMultiplier: clampedAmplitudeMultiplier
        )
    }

    private var clampedSubdivisionDepth: Int {
        min(
            max(waveformSubdivisionDepth, JournalWaveformSettings.subdivisionDepthRange.lowerBound),
            JournalWaveformSettings.subdivisionDepthRange.upperBound
        )
    }

    private var clampedAmplitudeMultiplier: Double {
        min(
            max(waveformAmplitudeMultiplier, JournalWaveformSettings.amplitudeMultiplierRange.lowerBound),
            JournalWaveformSettings.amplitudeMultiplierRange.upperBound
        )
    }


    private var visibleWaveSegments: [SarosSpikeWaveSegment] {
        waveField.components.flatMap { component in
            [
                SarosSpikeWaveSegment(
                    id: "\(component.id)-ascent",
                    kind: .ascent,
                    startDate: component.leftBoundary,
                    endDate: component.period.spike.date,
                    fromSaros: component.period.previousSpike.saros,
                    toSaros: component.period.spike.saros,
                    accelerates: component.parabolaAscentAccelerates
                ),
                SarosSpikeWaveSegment(
                    id: "\(component.id)-descent",
                    kind: .descent,
                    startDate: component.period.spike.date,
                    endDate: component.rightBoundary,
                    fromSaros: component.period.spike.saros,
                    toSaros: component.period.nextSpike.saros,
                    accelerates: component.parabolaDescentAccelerates
                )
            ]
        }
        .filter { displayInterval.intersects($0.interval) }
    }

    private var selectedSegment: SarosSpikeWaveSegment? {
        if let selectedSegmentID,
           let selected = visibleWaveSegments.first(where: { $0.id == selectedSegmentID })
        {
            return selected
        }

        let date = probeDate ?? Date()
        if let containing = visibleWaveSegments.first(where: { $0.interval.contains(date) }) {
            return containing
        }

        return visibleWaveSegments.min { lhs, rhs in
            lhs.distance(to: date) < rhs.distance(to: date)
        }
    }

    private func pulseReading(at date: Date) -> SarosPulseReading? {
        let resolvedSaros = pulseSaros > 0 ? pulseSaros : flip.saros
        guard resolvedSaros > 0 else { return nil }
        return try? SarosPulseCalculator.reading(
            saros: resolvedSaros,
            date: date,
            harmonicDepth: flip.harmonicDepth,
            eclipseService: services.eclipseService
        )
    }

    private func sarosReading(for state: SarosSpikeWaveState) -> SarosClockReading? {
        guard let interval = try? services.eclipseService.previousAndNextEclipse(
            saros: state.period.spike.saros,
            around: state.date
        ) else {
            return nil
        }

        return try? SarosClockCalculator.reading(
            saros: state.period.spike.saros,
            previous: interval.previous,
            next: interval.next,
            now: state.date,
            harmonicDepth: state.period.spike.harmonicDepth
        )
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

    private var periodRangeTitle: String {
        "\(Self.dayTickFormatter.string(from: displayInterval.start)) - \(Self.dayTickFormatter.string(from: displayInterval.end))"
    }

    private var defaultJumpDate: Date {
        if let probeDate, displayInterval.contains(probeDate) {
            return probeDate
        }

        let now = Date()
        if displayInterval.contains(now) {
            return now
        }

        return displayInterval.start.addingTimeInterval(displayInterval.duration / 2)
    }

    private func pageStart(containing date: Date) -> Date {
        let origin = flip.observedAt.addingTimeInterval(-Self.tetrasarosDuration / 2)
        let offset = date.timeIntervalSince(origin)
        let pageIndex = floor(offset / Self.tetrasarosDuration)
        return origin.addingTimeInterval(pageIndex * Self.tetrasarosDuration)
    }

    @MainActor
    private func ensureLoadedPagesInitialized() {
        guard loadedPageStarts.isEmpty else { return }
        loadedPageStarts = [pageStart(containing: flip.observedAt)]
    }

    @MainActor
    private func appendAdjacentPage(
        _ direction: Int,
        proxy: ScrollViewProxy
    ) {
        let sign = direction.signum()
        guard sign != 0 else { return }

        let currentInterval = displayInterval
        let newStart = sign < 0
            ? currentInterval.start.addingTimeInterval(-Self.tetrasarosDuration)
            : currentInterval.start.addingTimeInterval(Self.tetrasarosDuration)
        let scrollFraction = sign < 0 ? 0.92 : 0.08

        let targetDate = newStart.addingTimeInterval(Self.tetrasarosDuration * scrollFraction)

        loadedPageStarts = [newStart]
        probeDate = targetDate
        selectedSegmentID = nil
        pendingPageScrollDate = targetDate

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isEdgeLoading = false
        }
    }

    @MainActor
    private func handleEdgeProximity(
        contentMinX: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat,
        proxy: ScrollViewProxy
    ) {
        guard didApplyInitialScroll, !isEdgeLoading else { return }

        let scrollableWidth = max(contentWidth - viewportWidth, 0)
        guard scrollableWidth > Self.edgeAutoLoadThreshold else { return }

        let leftOffset = min(max(-contentMinX, 0), scrollableWidth)
        let rightRemaining = max(scrollableWidth - leftOffset, 0)
        let triggerDistance = max(Self.edgeAutoLoadThreshold, viewportWidth * 0.65)

        if leftOffset <= triggerDistance {
            isEdgeLoading = true
            appendAdjacentPage(-1, proxy: proxy)
        } else if rightRemaining <= triggerDistance {
            isEdgeLoading = true
            appendAdjacentPage(1, proxy: proxy)
        }
    }

    @MainActor
    private func loadEvents(force: Bool = false) {
        guard force || events.isEmpty else { return }

        let eclipseService = services.eclipseService
        let harmonicDepth = flip.harmonicDepth
        let waveformModel = JournalWaveformModel.parabola
        let parabolaA = JournalWaveformSettings.currentParabolaA
        let waveformOptions = currentWaveformOptions
        let loadInterval = loadInterval
        let displayInterval = displayInterval
        let waveSampleCount = Self.waveSampleCount
        let minimumRarity = timelineMinimumWaveRarity
        let cacheKey = Self.cacheKey(
            harmonicDepth: harmonicDepth,
            displayInterval: displayInterval,
            loadInterval: loadInterval,
            sampleCount: waveSampleCount,
            minimumRarity: minimumRarity,
            waveformModel: waveformModel,
            parabolaA: parabolaA,
            options: waveformOptions
        )

        if let cached = SarosSpikeWaveTimelineCache.entry(for: cacheKey) {
            events = cached.events
            waveField = cached.field
            waveSamples = cached.samples
            isLoading = false
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil

        Task.detached(priority: .userInitiated) {
            let result: Result<(events: [SarosGlobalFlipEvent], field: SarosSpikeWaveField, samples: SarosSpikeWaveSamples), Error> = Result {
                let summaries = try eclipseService.allSarosSeries()

                let loadedEvents = SarosGlobalTimelineBuilder.events(
                    in: loadInterval,
                    summaries: summaries,
                    eclipseService: eclipseService,
                    harmonicDepth: harmonicDepth,
                    minimumRarity: minimumRarity,
                    includeSeriesEclipseMetrics: true
                )
                let field = SarosSpikeWaveCalculator.field(
                    events: loadedEvents,
                    model: waveformModel,
                    parabolaA: parabolaA,
                    options: waveformOptions
                )
                let samples = field.samples(
                    in: displayInterval,
                    sampleCount: waveSampleCount,
                    events: loadedEvents
                )

                return (
                    events: loadedEvents,
                    field: field,
                    samples: samples
                )
            }

            await MainActor.run {
                isLoading = false
                switch result {
                case .success(let loaded):
                    events = loaded.events
                    waveField = loaded.field
                    waveSamples = loaded.samples
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
        minimumRarity: FlipRarity,
        waveformModel: JournalWaveformModel,
        parabolaA: Double,
        options: JournalWaveformOptions
    ) -> SarosSpikeWaveCacheKey {
        SarosSpikeWaveCacheKey(
            harmonicDepth: harmonicDepth,
            waveformModelID: waveformModel.id,
            parabolaAKey: parabolaCacheKey(parabolaA),
            mergesCloseSpikes: options.mergeCloseSpikes,
            normalizesAmplitude: options.normalizedAmplitude,
            amplitudeMultiplierKey: amplitudeCacheKey(options.amplitudeMultiplier),
            subdivisionDepth: options.subdivisionDepth,
            displayStart: Int(displayInterval.start.timeIntervalSince1970),
            displayEnd: Int(displayInterval.end.timeIntervalSince1970),
            loadStart: Int(loadInterval.start.timeIntervalSince1970),
            loadEnd: Int(loadInterval.end.timeIntervalSince1970),
            sampleCount: sampleCount,
            minimumRarityID: minimumRarity.id,
            includesSeriesEclipseMetrics: true
        )
    }

    private static func clampedParabolaA(_ value: Double) -> Double {
        min(
            max(value, JournalWaveformSettings.parabolaARange.lowerBound),
            JournalWaveformSettings.parabolaARange.upperBound
        )
    }

    private static func parabolaCacheKey(_ value: Double) -> Int {
        Int((clampedParabolaA(value) * 100).rounded())
    }

    private static func amplitudeCacheKey(_ value: Double) -> Int {
        Int((min(max(value, JournalWaveformSettings.amplitudeMultiplierRange.lowerBound), JournalWaveformSettings.amplitudeMultiplierRange.upperBound) * 100).rounded())
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
        probeDate = nil
        selectedSegmentID = nil
        if !displayInterval.contains(now) {
            loadedPageStarts = [pageStart(containing: now)]
            pendingPageScrollDate = now
            applyPendingScrollIfNeeded(proxy: proxy, layoutDelay: 0.08)
            return
        }
        scroll(to: now, proxy: proxy, animated: animated)
    }

    @MainActor
    private func jump(
        to date: Date,
        proxy: ScrollViewProxy
    ) {
        probeDate = date
        selectedSegmentID = nil
        if displayInterval.contains(date) {
            scroll(to: date, proxy: proxy, animated: true)
            return
        }

        loadedPageStarts = [pageStart(containing: date)]
        pendingPageScrollDate = date
        applyPendingScrollIfNeeded(proxy: proxy, layoutDelay: 0.10)
    }

    @MainActor
    private func applyInitialZoomIfNeeded() {
        guard !didApplyInitialZoom else { return }
        zoom = defaultZoom
        didApplyInitialZoom = true
    }

    @MainActor
    private func applyInitialScrollIfNeeded(proxy: ScrollViewProxy) {
        guard !didApplyInitialScroll else { return }
        didApplyInitialScroll = true
        scrollToPresent(proxy: proxy, animated: false)
    }

    @MainActor
    private func applyPendingScrollIfNeeded(
        proxy: ScrollViewProxy,
        layoutDelay: TimeInterval = 0.04
    ) {
        guard let pendingPageScrollDate else { return }
        self.pendingPageScrollDate = nil
        scroll(to: pendingPageScrollDate, proxy: proxy, animated: false, layoutDelay: layoutDelay)
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
        components: [SarosSpikeWaveComponent],
        contentWidth: CGFloat,
        height: CGFloat,
        maxEnergy: Double,
        amplitudeScale: CGFloat
    ) -> [SarosSpikeDotMarker] {
        var placed: [(x: CGFloat, y: CGFloat)] = []
        var placedLabelBoxes: [LabelBoundingBox] = []
        var placedDotsCount = 0

        return components.sorted {
            if $0.period.spike.date != $1.period.spike.date {
                return $0.period.spike.date < $1.period.spike.date
            }
            return $0.period.spike.rarity > $1.period.spike.rarity
        }
        .map { component in
            let event = component.period.spike
            var x = xPosition(for: event.date, width: contentWidth)
            let size = dotSize(for: event.rarity)
            let baseY = dotBaseY(
                for: event,
                samples: waveSamples,
                maxEnergy: maxEnergy,
                height: height,
                amplitudeScale: amplitudeScale
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

            let contributorsCount = component.contributors.isEmpty ? 1 : component.contributors.count
            let leftBoxes = labelBoxes(forX: x, y: y, size: size, contributorsCount: contributorsCount, labelOnLeadingSide: true)
            let rightBoxes = labelBoxes(forX: x, y: y, size: size, contributorsCount: contributorsCount, labelOnLeadingSide: false)

            let leftOverlaps = leftBoxes.contains { box in
                placedLabelBoxes.contains { $0.intersects(box) }
            }
            let rightOverlaps = rightBoxes.contains { box in
                placedLabelBoxes.contains { $0.intersects(box) }
            }

            let labelOnLeadingSide: Bool
            if leftOverlaps && !rightOverlaps {
                labelOnLeadingSide = false
            } else if !leftOverlaps && rightOverlaps {
                labelOnLeadingSide = true
            } else {
                labelOnLeadingSide = placedDotsCount.isMultiple(of: 2)
            }

            let chosenBoxes = labelOnLeadingSide ? leftBoxes : rightBoxes
            placedLabelBoxes.append(contentsOf: chosenBoxes)

            let dotGap = size + 7
            let startOffset = -CGFloat(contributorsCount - 1) * dotGap / 2
            for index in 0..<contributorsCount {
                let contributorY = y + startOffset + CGFloat(index) * dotGap
                placedLabelBoxes.append(LabelBoundingBox(
                    xRange: (x - size / 2)...(x + size / 2),
                    yRange: (contributorY - size / 2)...(contributorY + size / 2)
                ))
            }

            placed.append((x, y))
            placedDotsCount += 1

            return SarosSpikeDotMarker(
                event: event,
                contributors: component.contributors,
                x: x,
                y: y,
                size: size,
                labelOnLeadingSide: labelOnLeadingSide
            )
        }
    }

    private func labelBoxes(
        forX x: CGFloat,
        y: CGFloat,
        size: CGFloat,
        contributorsCount: Int,
        labelOnLeadingSide: Bool
    ) -> [LabelBoundingBox] {
        let dotGap = size + 7
        let startOffset = -CGFloat(contributorsCount - 1) * dotGap / 2
        let labelWidth: CGFloat = 24
        let labelHeight: CGFloat = 10

        var boxes: [LabelBoundingBox] = []
        for index in 0..<contributorsCount {
            let contributorY = y + startOffset + CGFloat(index) * dotGap
            let labelX: CGFloat
            if labelOnLeadingSide {
                labelX = x - size / 2 - 5 - labelWidth
            } else {
                labelX = x + size / 2 + 5
            }

            boxes.append(LabelBoundingBox(
                xRange: labelX...(labelX + labelWidth),
                yRange: (contributorY - labelHeight / 2)...(contributorY + labelHeight / 2)
            ))
        }
        return boxes
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
        maxEnergy: Double,
        amplitudeScale: CGFloat
    ) -> CGFloat {
        let baseline = height * 0.54
        let top = height * 0.12
        let waveHeight = (baseline - top) * amplitudeScale
        let ratio = min(max(state.energy / maxEnergy, 0), 1)
        return baseline - CGFloat(ratio) * waveHeight
    }

    private func dotBaseY(
        for event: SarosGlobalFlipEvent,
        samples: SarosSpikeWaveSamples,
        maxEnergy: Double,
        height: CGFloat,
        amplitudeScale: CGFloat
    ) -> CGFloat {
        let baseline = height * 0.54
        let top = height * 0.12
        let waveHeight = (baseline - top) * amplitudeScale
        let maxEnergy = max(maxEnergy, 0.000_000_001)
        let eventEnergy = samples.energy(for: event)
        let peakY = baseline - CGFloat(eventEnergy / maxEnergy) * waveHeight

        return max(18, peakY - 48)
    }

    private func dotSize(for rarity: FlipRarity) -> CGFloat {
        switch rarity.baseRarity {
        case .mythic: 8
        case .legendary: 7
        case .epic: 6
        default: 5
        }
    }

    @MainActor
    private func loadSolarTicks() async {
        let displayInterval = displayInterval
        let siderealReferenceDate = Date(timeIntervalSince1970: solarSiderealReferenceTimestamp)
        let loaded = await Task.detached(priority: .utility) {
            SolarYearRuler.ticks(in: displayInterval, siderealReferenceDate: siderealReferenceDate)
        }.value
        solarTicks = loaded
    }

    @MainActor
    private func loadLunarTicks() async {
        let displayInterval = displayInterval
        let moonService = services.moonPhaseService
        let loaded = await Task.detached(priority: .utility) {
            LunarRulerTickBuilder.ticks(in: displayInterval, moonService: moonService)
        }.value
        lunarTicks = loaded
    }

    @MainActor
    private func loadPulseTicks() async {
        let displayInterval = displayInterval
        let resolvedSaros = pulseSaros > 0 ? pulseSaros : flip.saros
        let harmonicDepth = flip.harmonicDepth
        let eclipseService = services.eclipseService
        let loaded = await Task.detached(priority: .utility) {
            (try? SarosPulseCalculator.ticks(
                in: displayInterval,
                saros: resolvedSaros,
                harmonicDepth: harmonicDepth,
                eclipseService: eclipseService,
                units: [.rollover, .giga, .mega, .kilo]
            )) ?? []
        }.value
        pulseTicks = loaded
    }

    private var timelineWaveColorLegend: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.blue)
                .frame(width: 8, height: 8)
            Circle()
                .fill(.yellow)
                .frame(width: 8, height: 8)
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
        }
        .accessibilityHidden(true)
    }
}
private struct LabelBoundingBox {
    let xRange: ClosedRange<CGFloat>
    let yRange: ClosedRange<CGFloat>

    func intersects(_ other: LabelBoundingBox) -> Bool {
        return xRange.overlaps(other.xRange) && yRange.overlaps(other.yRange)
    }
}

private struct SarosSpikeDotMarker: Identifiable {
    let event: SarosGlobalFlipEvent
    let contributors: [SarosGlobalFlipEvent]
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let labelOnLeadingSide: Bool

    var id: String {
        contributors.map(\.id).joined(separator: "|")
    }
}

private struct SarosSpikeSegmentHighlight: View {
    let segment: SarosSpikeWaveSegment
    let displayInterval: DateInterval

    var body: some View {
        Canvas { context, size in
            guard displayInterval.duration > 0 else { return }
            let startX = xPosition(for: segment.startDate, width: size.width)
            let endX = xPosition(for: segment.endDate, width: size.width)
            let minX = min(startX, endX)
            let width = max(abs(endX - startX), 1)
            let rect = CGRect(x: minX, y: 0, width: width, height: size.height)

            context.fill(Path(rect), with: .color(.green.opacity(0.18)))

            var top = Path()
            top.move(to: CGPoint(x: minX, y: 0))
            top.addLine(to: CGPoint(x: minX + width, y: 0))
            context.stroke(top, with: .color(.green.opacity(0.75)), lineWidth: 1.8)

            var bottom = Path()
            bottom.move(to: CGPoint(x: minX, y: size.height))
            bottom.addLine(to: CGPoint(x: minX + width, y: size.height))
            context.stroke(bottom, with: .color(.green.opacity(0.62)), lineWidth: 1.8)
        }
        .allowsHitTesting(false)
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let ratio = min(
            max(date.timeIntervalSince(displayInterval.start) / displayInterval.duration, 0),
            1
        )
        return CGFloat(ratio) * width
    }
}

private enum SarosSpikeWaveSegmentKind: Hashable {
    case ascent
    case descent

    var title: String {
        switch self {
        case .ascent: "ascent"
        case .descent: "descent"
        }
    }
}

private struct SarosSpikeWaveSegment: Identifiable, Hashable {
    let id: String
    let kind: SarosSpikeWaveSegmentKind
    let startDate: Date
    let endDate: Date
    let fromSaros: Int
    let toSaros: Int
    let accelerates: Bool

    var interval: DateInterval {
        let start = min(startDate, endDate)
        let end = max(startDate, endDate)
        return DateInterval(start: start, end: end)
    }

    var duration: TimeInterval {
        abs(endDate.timeIntervalSince(startDate))
    }

    var title: String {
        switch kind {
        case .descent:
            "From \(fromSaros) peak to \(toSaros) valley"
        case .ascent:
            "From \(fromSaros) valley towards \(toSaros) peak"
        }
    }

    var durationText: String {
        SarosDurationUnitFormatter.verboseDuration(duration)
    }

    var civilDurationText: String {
        Self.civilDurationFormatter.string(from: duration) ?? "0m"
    }

    func distance(to date: Date) -> TimeInterval {
        if interval.contains(date) {
            return 0
        }
        return min(
            abs(date.timeIntervalSince(interval.start)),
            abs(date.timeIntervalSince(interval.end))
        )
    }

    private static let civilDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 3
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

}



private struct SegmentEventsSheet: View {
    let segment: SarosSpikeWaveSegment
    let entries: [JournalEntry]
    let tags: [JournalTag]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Events",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("There are no journal entries recorded in this waveform segment.")
                    )
                } else {
                    ForEach(entries) { entry in
                        NavigationLink {
                            JournalEntryDetailView(entry: entry, tags: tags)
                        } label: {
                            JournalEntryRow(entry: entry, tags: tags)
                        }
                    }
                }
            }
            .navigationTitle("Events in Segment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SarosSpikeDateJumpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draftDate: Date
    let onApply: (Date) -> Void

    init(initialDate: Date, onApply: @escaping (Date) -> Void) {
        _draftDate = State(initialValue: initialDate)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $draftDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)

                Button {
                    draftDate = Date()
                } label: {
                    Label("Today", systemImage: "clock.arrow.circlepath")
                }
            }
            .navigationTitle("Jump to Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onApply(draftDate)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct TickingStatePanel: View {
    @StateObject private var timeTicker = TimelineCurrentTimeTicker()
    let probeDate: Date?
    let waveField: SarosSpikeWaveField
    let events: [SarosGlobalFlipEvent]
    let segment: SarosSpikeWaveSegment?
    let pulseReadingAt: (Date) -> SarosPulseReading?
    let sarosReadingFor: (SarosSpikeWaveState) -> SarosClockReading?
    let onHeaderTap: () -> Void
    let onShowEvents: () -> Void

    var body: some View {
        let date = probeDate ?? timeTicker.date
        if let state = waveField.sample(at: date) {
            SarosSpikeWaveStatePanel(
                state: state,
                adjacentSpikes: adjacentSpikes,
                closestSpike: closestSpike,
                segment: segment,
                sarosReading: sarosReadingFor(state),
                pulseReading: pulseReadingAt(state.date),
                onHeaderTap: onHeaderTap,
                onShowEvents: onShowEvents
            )
            .padding(.horizontal)
            .padding(.top, 12)
        }
    }

    private var adjacentSpikes: [SarosGlobalFlipEvent] {
        let date = probeDate ?? timeTicker.date
        let past = events.filter { $0.date <= date }.sorted { $0.date > $1.date }.prefix(2)
        let future = events.filter { $0.date > date }.sorted { $0.date < $1.date }.prefix(2)
        var selected = Array(past).reversed() + Array(future)
        if selected.count < 4 {
            selected = Array(events.sorted {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            }.prefix(4)).sorted { $0.date < $1.date }
        }
        return selected
    }

    private var closestSpike: SarosGlobalFlipEvent? {
        let date = probeDate ?? timeTicker.date
        return adjacentSpikes.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }
}

private struct TickingProbeHandle: View {
    @StateObject private var timeTicker = TimelineCurrentTimeTicker()
    let probeDate: Date?
    let displayInterval: DateInterval
    let contentWidth: CGFloat
    let height: CGFloat
    let onDrag: (CGFloat) -> Void

    var body: some View {
        let markerDate = probeDate ?? timeTicker.date
        if displayInterval.contains(markerDate) {
            let markerX = xPosition(for: markerDate, width: contentWidth)
            SarosSpikeWaveProbeHandle(
                x: markerX,
                date: markerDate,
                onDrag: onDrag
            )
            .frame(width: 44, height: height)
            .position(x: markerX, y: height / 2)
        }
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let ratio = min(max(date.timeIntervalSince(displayInterval.start) / displayInterval.duration, 0), 1)
        return CGFloat(ratio) * width
    }
}

private struct TickingReferenceScrollAnchor: View {
    @StateObject private var timeTicker = TimelineCurrentTimeTicker()
    let probeDate: Date?
    let displayInterval: DateInterval
    let contentWidth: CGFloat
    let height: CGFloat
    let scrollID: String

    var body: some View {
        let markerDate = probeDate ?? timeTicker.date
        if displayInterval.contains(markerDate) {
            Color.clear
                .frame(width: 1, height: height)
                .position(
                    x: xPosition(for: markerDate, width: contentWidth),
                    y: height / 2
                )
                .id(scrollID)
        }
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let ratio = min(max(date.timeIntervalSince(displayInterval.start) / displayInterval.duration, 0), 1)
        return CGFloat(ratio) * width
    }
}

private struct SarosSpikeEdgeLoadHint: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.62))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.34), in: Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SarosSpikeContentMinXPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TimelineSpikeGlyphStrip: View {
    let spikes: [SarosGlobalFlipEvent]
    let highlightedSpikeID: String?
    let size: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            ForEach(spikes) { spike in
                VStack(spacing: 3) {
                    OctalGlyph(
                        value: spike.octalAddress,
                        depth: spike.harmonicDepth,
                        style: spike.rarity.glyphStyle
                    )
                    .frame(width: size, height: size)
                    .padding(size * 0.10)
                    .background(
                        spike.id == highlightedSpikeID ? spike.rarity.color.opacity(0.18) : .clear,
                        in: Circle()
                    )
                    .overlay {
                        if spike.id == highlightedSpikeID {
                            Circle()
                                .stroke(spike.rarity.color.opacity(0.52), lineWidth: 1)
                        }
                    }
                    Text("\(spike.saros)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(spike.id == highlightedSpikeID ? spike.rarity.color : .secondary)
                }
                .frame(minWidth: size + 8)
            }
        }
    }
}

private struct SarosSpikeWaveStatePanel: View {
    let state: SarosSpikeWaveState
    let adjacentSpikes: [SarosGlobalFlipEvent]
    let closestSpike: SarosGlobalFlipEvent?
    let segment: SarosSpikeWaveSegment?
    var sarosReading: SarosClockReading? = nil
    var pulseReading: SarosPulseReading? = nil
    var onHeaderTap: (() -> Void)? = nil
    var onShowEvents: (() -> Void)? = nil

    private var displayedSarosGlyph: String {
        sarosReading?.octalAddress ?? state.period.spike.octalAddress
    }

    private var displayedSarosDepth: Int {
        sarosReading?.harmonicDepth ?? state.period.spike.harmonicDepth
    }

    private var displayedSarosColor: Color {
        guard let sarosReading else { return state.period.spike.rarity.color }
        return FlipRarity.rarity(
            forOctalAddress: sarosReading.octalAddress,
            harmonicDepth: sarosReading.harmonicDepth
        ).color
    }

    private var waveSignature: JournalWaveSignature {
        JournalWaveEventDescriptorFormatter.signature(
            energyPercent: state.normalizedEnergy,
            momentumEnergyPerSaros: state.momentumEnergyPerSaros,
            valleySpacing: state.width * 2
        )
    }

    private var eventDescription: String {
        waveSignature.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top Row
            HStack(spacing: 12) {
                // Left: 4 adjacent glyphs strip
                TimelineSpikeGlyphStrip(
                    spikes: adjacentSpikes,
                    highlightedSpikeID: closestSpike?.id,
                    size: 22
                )

                Spacer(minLength: 8)

                // Right side: Pulse & Wave Signature
                HStack(spacing: 10) {
                    if let pulseReading {
                        SarosPulseGlyph(reading: pulseReading, size: 40)
                    }

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(waveSignature.type.emoji)
                            .font(.caption2)
                        Text(waveSignature.energyText)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                        Text(waveSignature.momentumText)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onHeaderTap?()
            }

            if let segment = segment {
                Divider()
                    .background(.white.opacity(0.12))

                HStack(spacing: 10) {
                    // Info text
                    VStack(alignment: .leading, spacing: 3) {
                        if let closest = closestSpike {
                            Text("\(closest.saros) Saros \(closest.rarity.title)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(closest.rarity.color)
                        } else {
                            Text("\(state.period.spike.saros) Saros \(state.period.spike.rarity.title)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(state.period.spike.rarity.color)
                        }

                        HStack(spacing: 6) {
                            Image(systemName: segment.kind == .ascent ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)

                            Text("\(eventDescription)  •  \(segment.durationText) (\(segment.civilDurationText))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onHeaderTap?()
                    }

                    Spacer(minLength: 8)

                    if let onShowEvents = onShowEvents {
                        Button(action: onShowEvents) {
                            HStack(spacing: 4) {
                                Image(systemName: "list.bullet")
                                Text("Events")
                            }
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke((closestSpike?.rarity.color ?? state.period.spike.rarity.color).opacity(0.2), lineWidth: 1)
        }
    }
}

private struct SarosSpikeWaveCanvas: View {
    let samples: SarosSpikeWaveSamples
    let displayInterval: DateInterval
    let maxEnergy: Double
    let amplitudeScale: CGFloat

    var body: some View {
        Canvas { context, size in
            let baseline = size.height * 0.54
            let top = size.height * 0.12
            let waveHeight = (baseline - top) * amplitudeScale
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
    var midpoints: [Date] = []
    let displayInterval: DateInterval
    var tickStartY: CGFloat = 52
    var tickEndY: CGFloat? = nil

    var body: some View {
        Canvas { context, size in
            let resolvedTickEndY = min(max(tickEndY ?? size.height * 0.9, tickStartY), size.height)
            for midpoint in midpoints {
                let x = xPosition(for: midpoint, width: size.width)
                let lineStartY = min(max(tickStartY + 1, 0), size.height)
                var line = Path()
                line.move(to: CGPoint(x: x, y: lineStartY))
                line.addLine(to: CGPoint(x: x, y: resolvedTickEndY))
                context.stroke(
                    line,
                    with: .color(.gray.opacity(0.5)),
                    style: StrokeStyle(lineWidth: 1.0, dash: [3, 4])
                )
            }

            for event in events {
                let x = xPosition(for: event.date, width: size.width)
                let lineWidth: CGFloat = event.rarity.baseRarity == .mythic ? 2.0 : 1.2
                let lineStartY = min(max(tickStartY + 1, 0), size.height)
                var line = Path()
                line.move(to: CGPoint(x: x, y: lineStartY))
                line.addLine(to: CGPoint(x: x, y: resolvedTickEndY))
                context.stroke(
                    line,
                    with: .color(event.rarity.color.opacity(0.58)),
                    lineWidth: lineWidth
                )
            }

            for marker in dots {
                let contributors = marker.contributors.isEmpty ? [marker.event] : marker.contributors
            let dotGap = marker.size + 7
                let startOffset = -CGFloat(contributors.count - 1) * dotGap / 2

                for (index, contributor) in contributors.enumerated() {
                    let y = marker.y + startOffset + CGFloat(index) * dotGap
                    let rect = CGRect(
                        x: marker.x - marker.size / 2,
                        y: y - marker.size / 2,
                        width: marker.size,
                        height: marker.size
                    )
                    let dot = Path(ellipseIn: rect)
                    context.fill(dot, with: .color(contributor.rarity.color))
                    context.stroke(dot, with: .color(.black.opacity(0.38)), lineWidth: 0.8)
                    context.draw(
                        Text("\(contributor.saros)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(contributor.rarity.color.opacity(0.95)),
                        at: CGPoint(
                            x: marker.labelOnLeadingSide
                                ? marker.x - marker.size / 2 - 5
                                : marker.x + marker.size / 2 + 5,
                            y: y
                        ),
                        anchor: marker.labelOnLeadingSide ? .trailing : .leading
                    )
                }
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

struct SarosPulseRulerCanvas: View {
    let ticks: [SarosPulseTick]
    let displayInterval: DateInterval
    var tickStartY: CGFloat? = nil
    var tickEndY: CGFloat? = nil

    var body: some View {
        Canvas { context, size in
            guard !ticks.isEmpty else { return }

            let baseline = size.height * 0.94
            let resolvedTickStartY = min(max(tickStartY ?? baseline - SarosPulseUnit.rollover.tickHeight, 0), size.height)
            let resolvedTickEndY = min(max(tickEndY ?? baseline, resolvedTickStartY), size.height)
            var lastXByUnit: [SarosPulseUnit: CGFloat] = [:]

            for tick in ticks {
                guard tick.unit.isTimelineOverlayTick else { continue }

                let x = xPosition(for: tick.date, width: size.width)
                if tick.unit != .rollover,
                   let lastX = lastXByUnit[tick.unit],
                   abs(lastX - x) < 1.6
                {
                    continue
                }
                lastXByUnit[tick.unit] = x

                var line = Path()
                line.move(to: CGPoint(x: x, y: resolvedTickStartY))
                line.addLine(to: CGPoint(x: x, y: resolvedTickEndY))
                context.stroke(
                    line,
                    with: .color(color(for: tick.unit).opacity(opacity(for: tick.unit) * 0.46)),
                    lineWidth: lineWidth(for: tick.unit)
                )

                if tick.unit.showsTickLabel {
                    context.draw(
                        Text("\(tick.digit)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(color(for: tick.unit).opacity(0.56)),
                        at: CGPoint(x: x, y: max(8, resolvedTickStartY - 10))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func color(for unit: SarosPulseUnit) -> Color {
        unit.color
    }

    private func opacity(for unit: SarosPulseUnit) -> Double {
        switch unit {
        case .rollover: 0.95
        case .giga: 0.9
        case .mega: 0.72
        case .kilo: 0.42
        case .saros, .mili, .nano: 0
        }
    }

    private func lineWidth(for unit: SarosPulseUnit) -> CGFloat {
        switch unit {
        case .rollover: 1.6
        case .giga: 1.3
        case .mega: 1.0
        case .kilo: 0.55
        case .saros, .mili, .nano: 0
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

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .shadow(color: color.opacity(0.7), radius: 8)
            Text(state.map { Self.formatter.string(from: $0.date) } ?? "now")
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
    let x: CGFloat
    let date: Date
    let onDrag: (CGFloat) -> Void

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.green)
                .frame(width: 1.3)
                .frame(maxHeight: .infinity)
                .shadow(color: .green.opacity(0.72), radius: 8)

            Text(Self.formatter.string(from: date))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .offset(y: 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onDrag(x + value.translation.width)
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wave probe")
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
    let primeTint: Color?

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
        highlightRarity?.color ?? primeTint ?? upcomingRarity?.color ?? .white
    }

    private var isHighlighted: Bool {
        highlightRarity != nil || upcomingRarity != nil || primeTint != nil
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
    @Query(sort: \JournalEntry.eventDate, order: .reverse) private var entries: [JournalEntry]
    @Query(sort: \JournalTag.createdAt, order: .forward) private var tags: [JournalTag]

    let series: ActiveSarosPhaseSeries

    @State private var selectedTab: SarosPhaseDetailTab = .records
    @State private var selectedEntry: JournalEntry?
    @State private var selectedGlobalTimelineEvent: SarosPhaseFlipEvent?
    @State private var seriesEclipses: [Eclipse] = []
    @State private var isRecordFilterPresented = false
    @State private var selectedRecordRarity: FlipRarity?
    @State private var selectedRecordDirection: JournalWaveDirection?
    @State private var selectedRecordExtremum: JournalWaveExtremum?
    @State private var recordDateFilterMode: JournalRecordDateFilterMode = .all
    @State private var selectedRecordDate = Date()
    @State private var selectedSynodicBin: Int?
    @State private var selectedAnomalisticBin: Int?
    @State private var selectedDraconicBin: Int?
    @State private var spikesOnly = true

    private var seriesEntries: [JournalEntry] {
        entries.filter { $0.context.sarosNumbers.contains(series.saros) }
    }

    private var filteredSeriesEntries: [JournalEntry] {
        seriesEntries.filter { entry in
            let context = entry.context
            let closestRarity = context.closestSpike?.rarity.baseRarity ?? .common
            let matchesRarity = selectedRecordRarity.map { closestRarity == $0.baseRarity } ?? true
            let matchesDirection = selectedRecordDirection.map { context.waveSignature.direction == $0 } ?? true
            let matchesExtremum = selectedRecordExtremum.map { context.extremum == $0 } ?? true
            let matchesMoon = matchesMoonFilters(entry.eventDate)
            let matchesSpikesOnly = !spikesOnly || context.closestSpike?.saros == series.saros
            let matchesDate = switch recordDateFilterMode {
            case .all:
                true
            case .day:
                Calendar.current.isDate(entry.eventDate, inSameDayAs: selectedRecordDate)
            }
            return matchesRarity && matchesDirection && matchesExtremum && matchesMoon && matchesSpikesOnly && matchesDate
        }
    }

    private var hasActiveRecordFilters: Bool {
        selectedRecordRarity != nil
            || selectedRecordDirection != nil
            || selectedRecordExtremum != nil
            || selectedSynodicBin != nil
            || selectedAnomalisticBin != nil
            || selectedDraconicBin != nil
            || spikesOnly
            || recordDateFilterMode != .all
    }

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

                    Picker("Saros view", selection: $selectedTab) {
                        ForEach(SarosPhaseDetailTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 10)

                    Divider()

                    switch selectedTab {
                    case .records:
                        SarosPhaseRecordsList(
                            entries: filteredSeriesEntries,
                            tags: tags,
                            selectEntry: { selectedEntry = $0 }
                        )
                    case .timeline:
                        SarosFlipEventTimelineView(
                            series: series,
                            seriesEclipses: seriesEclipses,
                            reference: reference,
                            now: context.date,
                            onSelectEvent: { event in
                                selectedGlobalTimelineEvent = event
                            }
                        )
                    case .maps:
                        SarosEclipseMapSequenceView(series: series)
                    }
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
                    isRecordFilterPresented = true
                } label: {
                    Image(systemName: hasActiveRecordFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter records")
            }
        }
        .sheet(isPresented: $isRecordFilterPresented) {
            NavigationStack {
                JournalScopedRecordFilterView(
                    selectedRarity: $selectedRecordRarity,
                    selectedDirection: $selectedRecordDirection,
                    selectedExtremum: $selectedRecordExtremum,
                    dateFilterMode: $recordDateFilterMode,
                    selectedDate: $selectedRecordDate,
                    selectedSynodicBin: $selectedSynodicBin,
                    selectedAnomalisticBin: $selectedAnomalisticBin,
                    selectedDraconicBin: $selectedDraconicBin,
                    spikesOnly: $spikesOnly
                )
            }
        }
        .navigationDestination(item: $selectedEntry) { entry in
            JournalEntryDetailView(entry: entry, tags: tags)
        }
        .navigationDestination(item: $selectedGlobalTimelineEvent) { event in
            SarosGlobalFlipTimelineView(
                referenceDate: event.date,
                referenceEvent: event
            )
        }
        .task(id: series.saros) {
            await loadSeriesEclipses()
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

private enum SarosPhaseDetailTab: String, CaseIterable, Identifiable {
    case records
    case timeline
    case maps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .records: "Records"
        case .timeline: "Timeline"
        case .maps: "Maps"
        }
    }
}

enum JournalRecordDateFilterMode: String, CaseIterable, Identifiable {
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

struct JournalScopedRecordFilterView: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedRarity: FlipRarity?
    @Binding var selectedDirection: JournalWaveDirection?
    @Binding var selectedExtremum: JournalWaveExtremum?
    @Binding var dateFilterMode: JournalRecordDateFilterMode
    @Binding var selectedDate: Date
    @Binding var selectedSynodicBin: Int?
    @Binding var selectedAnomalisticBin: Int?
    @Binding var selectedDraconicBin: Int?
    @Binding var spikesOnly: Bool

    var body: some View {
        Form {
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

                Toggle("Spikes only", isOn: $spikesOnly)
            }

            Section("Moon") {
                MoonBinPicker(title: "Synodic", selection: $selectedSynodicBin)
                MoonBinPicker(title: "Anomalistic", selection: $selectedAnomalisticBin)
                MoonBinPicker(title: "Draconic", selection: $selectedDraconicBin)
            }

            Section("Date") {
                Picker("Date", selection: $dateFilterMode) {
                    ForEach(JournalRecordDateFilterMode.allCases) { mode in
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
        .navigationTitle("Record Filters")
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
        selectedSynodicBin = nil
        selectedAnomalisticBin = nil
        selectedDraconicBin = nil
        spikesOnly = false
        dateFilterMode = .all
    }
}

private struct SarosPhaseRecordsList: View {
    let entries: [JournalEntry]
    let tags: [JournalTag]
    let selectEntry: (JournalEntry) -> Void

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView("No records in this Saros", systemImage: "rectangle.stack")
            } else {
                ForEach(entries) { entry in
                    Button {
                        selectEntry(entry)
                    } label: {
                        JournalEntryRow(entry: entry, tags: tags)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
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
            HStack(spacing: 12) {
                VStack(spacing: 8) {
                    OctalGlyph(
                        value: reading.octalAddress,
                        depth: reading.harmonicDepth,
                        color: tint
                    )
                    .frame(width: 76, height: 76)
                    .padding(8)
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
                    .frame(width: 24, height: 24)
                    .padding(5)
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
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Text(countdownText)
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text(reference.map { JournalFormatters.dateTime.string(from: $0.event.date) } ?? "No upcoming event")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                SarosEclipseCubeMapPreview(
                    eclipse: reading.nextEclipse,
                    color: tint,
                    compact: true
                )
                .frame(width: 108, height: 108)
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
    let seriesEclipses: [Eclipse]
    let reference: SarosPhaseTimelineReference?
    let now: Date
    let onSelectEvent: (SarosPhaseFlipEvent) -> Void

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @State private var didScrollToReference = false
    @State private var periodOffset = 0

    private var sortedEclipses: [Eclipse] {
        seriesEclipses.sorted { $0.date < $1.date }
    }

    private var activeRangeIndex: Int? {
        guard let reference,
              let baseIndex = Self.periodIndex(containing: reference.event.date, in: sortedEclipses)
        else {
            return nil
        }
        return min(max(baseIndex + periodOffset, 0), max(sortedEclipses.count - 2, 0))
    }

    private var activeRange: SarosEclipsePeriodRange? {
        guard let index = activeRangeIndex,
              sortedEclipses.indices.contains(index),
              sortedEclipses.indices.contains(index + 1)
        else {
            return nil
        }
        return SarosEclipsePeriodRange(
            start: sortedEclipses[index],
            end: sortedEclipses[index + 1]
        )
    }

    private var canLoadPreviousRange: Bool {
        (activeRangeIndex ?? 0) > 0
    }

    private var canLoadNextRange: Bool {
        guard let activeRangeIndex else { return false }
        return activeRangeIndex < sortedEclipses.count - 2
    }

    private var model: SarosPhaseTimelineModel? {
        guard let reference,
              let range = activeRange,
              let reading = series.reading(at: range.midpoint, harmonicDepth: harmonicDepth)
        else {
            return nil
        }

        return SarosPhaseTimelineModel(
            reading: reading,
            reference: reference,
            range: range
        )
    }

    var body: some View {
        if let model {
            VStack(spacing: 0) {
                rangeControls(model: model)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            Color.clear
                                .frame(height: 120)

                            if model.events.isEmpty {
                                ContentUnavailableView("No Duplex+ flips in this eclipse range", systemImage: "timeline.selection")
                                    .padding(.vertical, 40)
                            }

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
                                .frame(height: 120)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .onAppear {
                        scrollToReference(with: proxy, model: model)
                    }
                    .onChange(of: model.scrollTargetID) { _, _ in
                        didScrollToReference = false
                        scrollToReference(with: proxy, model: model)
                    }
                }
            }
        } else {
            ContentUnavailableView("Timeline unavailable", systemImage: "timeline.selection")
        }
    }

    private func rangeControls(model: SarosPhaseTimelineModel) -> some View {
        HStack(spacing: 10) {
            Button {
                periodOffset -= 1
                didScrollToReference = false
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.bordered)
            .disabled(!canLoadPreviousRange)
            .accessibilityLabel("Load previous eclipse range")

            VStack(alignment: .leading, spacing: 3) {
                Text(model.range.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(model.range.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                periodOffset += 1
                didScrollToReference = false
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.bordered)
            .disabled(!canLoadNextRange)
            .accessibilityLabel("Load next eclipse range")
        }
    }

    private func scrollToReference(with proxy: ScrollViewProxy, model: SarosPhaseTimelineModel) {
        guard !didScrollToReference else { return }
        guard let targetID = model.scrollTargetID else { return }
        didScrollToReference = true
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.35)) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
    }

    private static func periodIndex(containing date: Date, in eclipses: [Eclipse]) -> Int? {
        guard eclipses.count >= 2 else { return nil }
        let previousIndex = eclipses.lastIndex { $0.date <= date } ?? eclipses.startIndex
        return min(max(previousIndex, eclipses.startIndex), eclipses.count - 2)
    }
}

private struct SarosPhaseTimelineModel {
    let reading: SarosClockReading
    let reference: SarosPhaseTimelineReference
    let range: SarosEclipsePeriodRange
    let events: [SarosPhaseFlipEvent]

    var referenceID: String {
        reference.event.id
    }

    var scrollTargetID: String? {
        if events.contains(where: { $0.id == referenceID }) {
            return referenceID
        }
        return events.first(where: { $0.date >= reference.event.date })?.id ?? events.last?.id
    }

    init(
        reading: SarosClockReading,
        reference: SarosPhaseTimelineReference,
        range: SarosEclipsePeriodRange
    ) {
        self.reading = reading
        self.reference = reference
        self.range = range

        events = Self.events(
            reading: reading,
            range: range
        )
    }

    static func upcomingReference(reading: SarosClockReading, now: Date) -> SarosPhaseTimelineReference? {
        nearbyEvents(
            reading: reading,
            startIndex: reading.binIndex,
            limit: 1
        )
        .first
        .map(SarosPhaseTimelineReference.init(event:))
    }

    private static func events(
        reading: SarosClockReading,
        range: SarosEclipsePeriodRange
    ) -> [SarosPhaseFlipEvent] {
        var eventsByBin: [Int: SarosPhaseFlipEvent] = [:]

        for rarity in FlipRarity.eventRarities(for: reading.harmonicDepth) where rarity >= .epic {
            var bin = reading.nextQualifiedFlipBin(after: 0, rarity: rarity, exact: true)

            while let currentBin = bin,
                  currentBin > 0,
                  currentBin < reading.binCount
            {
                let date = reading.date(forBinIndex: currentBin)
                if date >= range.start.date && date <= range.end.date {
                    let event = SarosPhaseFlipEvent(
                        saros: reading.saros,
                        binIndex: currentBin,
                        date: date,
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
                }

                guard let nextBin = reading.nextQualifiedFlipBin(after: currentBin, rarity: rarity, exact: true),
                      nextBin > currentBin
                else {
                    bin = nil
                    continue
                }
                bin = nextBin
            }
        }

        return eventsByBin.values.sorted {
            if $0.date != $1.date {
                return $0.date < $1.date
            }
            return $0.rarity > $1.rarity
        }
    }

    private static func nearbyEvents(
        reading: SarosClockReading,
        startIndex: Int,
        limit: Int
    ) -> [SarosPhaseFlipEvent] {
        var eventsByBin: [Int: SarosPhaseFlipEvent] = [:]

        for rarity in FlipRarity.eventRarities(for: reading.harmonicDepth) where rarity >= .epic {
            var bin = reading.nextQualifiedFlipBin(after: startIndex, rarity: rarity, exact: true)
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

                guard let nextBin = reading.nextQualifiedFlipBin(after: currentBin, rarity: rarity, exact: true),
                      nextBin > currentBin
                else {
                    bin = nil
                    continue
                }
                bin = nextBin
            }
        }

        let sorted = eventsByBin.values.sorted {
            if $0.date != $1.date {
                return $0.date < $1.date
            }
            return $0.rarity > $1.rarity
        }

        return Array(sorted.prefix(limit))
    }
}

private struct SarosEclipsePeriodRange: Hashable {
    let start: Eclipse
    let end: Eclipse

    var midpoint: Date {
        start.date.addingTimeInterval(max(end.date.timeIntervalSince(start.date), 1) / 2)
    }

    var title: String {
        "\(JournalFormatters.date.string(from: start.date)) → \(JournalFormatters.date.string(from: end.date))"
    }

    var subtitle: String {
        "Eclipse range · \(end.date.timeIntervalSince(start.date).compactDuration)"
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

    @State private var activeReferenceDate: Date
    @State private var activeReferenceEvent: SarosPhaseFlipEvent?
    @State private var selectedMonth: SarosGlobalTimelineMonth?
    @State private var monthDistributions: [String: SarosFlipMonthDistribution] = [:]
    @State private var didScrollToReferenceMonth = false
    @State private var didOpenReferenceMonth = false
    @State private var pastMonthRadius = 120
    @State private var futureMonthRadius = 120
    @State private var isReferencePickerPresented = false

    private var months: [SarosGlobalTimelineMonth] {
        SarosGlobalTimelineMonth.months(
            around: activeReferenceDate,
            pastMonths: pastMonthRadius,
            futureMonths: futureMonthRadius
        )
    }

    private var referenceMonthID: String {
        SarosGlobalTimelineMonth.containing(activeReferenceDate).id
    }

    private var firstMonthID: String? {
        months.first?.id
    }

    init(referenceDate: Date, referenceEvent: SarosPhaseFlipEvent?) {
        self.referenceDate = referenceDate
        self.referenceEvent = referenceEvent
        _activeReferenceDate = State(initialValue: referenceDate)
        _activeReferenceEvent = State(initialValue: referenceEvent)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    Button {
                        pastMonthRadius += 60
                        didScrollToReferenceMonth = false
                    } label: {
                        Label("Load previous 5 years", systemImage: "chevron.up")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 8)

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

                    Button {
                        futureMonthRadius += 60
                    } label: {
                        Label("Load next 5 years", systemImage: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .navigationTitle("Saros calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isReferencePickerPresented = true
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .accessibilityLabel("Choose reference date")
                }
            }
            .sheet(isPresented: $isReferencePickerPresented) {
                NavigationStack {
                    SarosCalendarReferencePicker(date: $activeReferenceDate) {
                        activeReferenceEvent = nil
                        didScrollToReferenceMonth = false
                        didOpenReferenceMonth = false
                    }
                }
            }
            .task(id: "\(harmonicDepth)-\(activeReferenceDate.timeIntervalSince1970)-\(pastMonthRadius)-\(futureMonthRadius)") {
                loadMonthDistributions()
                scrollToReferenceMonth(with: proxy)
                openReferenceMonth()
            }
        }
        .navigationDestination(item: $selectedMonth) { month in
            SarosGlobalMonthTimelineView(
                month: month,
                referenceDate: activeReferenceDate,
                referenceEvent: activeReferenceEvent
            )
        }
    }

    private func openReferenceMonth() {
        guard !didOpenReferenceMonth else { return }
        didOpenReferenceMonth = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            selectedMonth = SarosGlobalTimelineMonth.containing(activeReferenceDate)
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

private struct SarosCalendarReferencePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var date: Date
    @State private var draftDate: Date
    let onApply: () -> Void

    init(date: Binding<Date>, onApply: @escaping () -> Void) {
        _date = date
        _draftDate = State(initialValue: date.wrappedValue)
        self.onApply = onApply
    }

    var body: some View {
        Form {
            Section("Reference") {
                DatePicker("Date", selection: $draftDate)
                    .datePickerStyle(.compact)

                Button {
                    draftDate = Date()
                } label: {
                    Label("Now", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .navigationTitle("Reference Date")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    date = draftDate
                    onApply()
                    dismiss()
                }
            }
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

    static func months(
        around date: Date,
        pastMonths: Int = 120,
        futureMonths: Int = 120
    ) -> [SarosGlobalTimelineMonth] {
        let reference = containing(date).startDate
        return (-max(pastMonths, 0)...max(futureMonths, 0)).compactMap { offset in
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
    let seriesEclipseGamma: Double?
    let seriesEclipseMagnitude: Double?
    let seriesEclipseType: EclipseType?
    let seriesEclipseSequence: Int?
    let seriesEclipseCount: Int?
    let seriesProgressesSouthToNorth: Bool?

    var id: String {
        "\(saros)-\(binIndex)-\(Int(date.timeIntervalSince1970))-\(rarity.id)"
    }

    var isPartialEclipse: Bool {
        seriesEclipseType?.isPartialSolar == true
    }

    var isPastSeriesMidpoint: Bool? {
        guard let seriesEclipseSequence, let seriesEclipseCount, seriesEclipseCount > 0 else {
            return nil
        }
        return Double(seriesEclipseSequence) >= Double(seriesEclipseCount) / 2
    }

    init(
        saros: Int,
        binIndex: Int,
        date: Date,
        octalAddress: String,
        harmonicDepth: Int,
        rarity: FlipRarity,
        seriesEclipseGamma: Double? = nil,
        seriesEclipseMagnitude: Double? = nil,
        seriesEclipseType: EclipseType? = nil,
        seriesEclipseSequence: Int? = nil,
        seriesEclipseCount: Int? = nil,
        seriesProgressesSouthToNorth: Bool? = nil
    ) {
        self.saros = saros
        self.binIndex = binIndex
        self.date = date
        self.octalAddress = octalAddress
        self.harmonicDepth = harmonicDepth
        self.rarity = rarity
        self.seriesEclipseGamma = seriesEclipseGamma
        self.seriesEclipseMagnitude = seriesEclipseMagnitude
        self.seriesEclipseType = seriesEclipseType
        self.seriesEclipseSequence = seriesEclipseSequence
        self.seriesEclipseCount = seriesEclipseCount
        self.seriesProgressesSouthToNorth = seriesProgressesSouthToNorth
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
        minimumRarity: FlipRarity = .epic,
        includeSeriesEclipseMetrics: Bool = false
    ) -> [SarosGlobalFlipEvent] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return events(
            in: DateInterval(start: start, end: end),
            summaries: summaries,
            eclipseService: eclipseService,
            harmonicDepth: rawHarmonicDepth,
            minimumRarity: minimumRarity,
            includeSeriesEclipseMetrics: includeSeriesEclipseMetrics
        )
    }

    static func eventsByDay(
        in interval: DateInterval,
        summaries: [SarosSeriesSummary],
        eclipseService: any EclipseService,
        harmonicDepth rawHarmonicDepth: Int,
        minimumRarity: FlipRarity = .epic,
        includeSeriesEclipseMetrics: Bool = false
    ) -> [Int: [SarosGlobalFlipEvent]] {
        Dictionary(grouping: events(
            in: interval,
            summaries: summaries,
            eclipseService: eclipseService,
            harmonicDepth: rawHarmonicDepth,
            minimumRarity: minimumRarity,
            includeSeriesEclipseMetrics: includeSeriesEclipseMetrics
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
        minimumRarity: FlipRarity = .epic,
        includeSeriesEclipseMetrics: Bool = false
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
                let weightingInterval = includeSeriesEclipseMetrics
                    ? intervalWithDetailedEclipseMetrics(interval, eclipseService: eclipseService)
                    : interval

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
                    eclipse: weightingInterval.previous,
                    reading: reading,
                    seriesProgressesSouthToNorth: seriesProgressesSouthToNorth(in: weightingInterval),
                    start: start,
                    end: end,
                    eventsByBin: &eventsByBin
                )
                appendBoundaryEventIfNeeded(
                    date: interval.next.date,
                    eclipse: weightingInterval.next,
                    reading: reading,
                    seriesProgressesSouthToNorth: seriesProgressesSouthToNorth(in: weightingInterval),
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
                            let seriesEclipse = seriesWeightingEclipse(for: date, in: weightingInterval)
                            let event = SarosGlobalFlipEvent(
                                saros: reading.saros,
                                binIndex: currentBin,
                                date: date,
                                octalAddress: reading.octalAddress(forBinIndex: currentBin),
                                harmonicDepth: harmonicDepth,
                                rarity: rarity,
                                seriesEclipseGamma: seriesEclipse.gamma,
                                seriesEclipseMagnitude: seriesEclipse.magnitude,
                                seriesEclipseType: seriesEclipse.type,
                                seriesEclipseSequence: seriesEclipse.sarosSequence,
                                seriesEclipseCount: seriesEclipse.sarosSeriesCount,
                                seriesProgressesSouthToNorth: seriesProgressesSouthToNorth(in: weightingInterval)
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
        eclipse: Eclipse,
        reading: SarosClockReading,
        seriesProgressesSouthToNorth: Bool?,
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
            rarity: .mythicDigit(7),
            seriesEclipseGamma: eclipse.gamma,
            seriesEclipseMagnitude: eclipse.magnitude,
            seriesEclipseType: eclipse.type,
            seriesEclipseSequence: eclipse.sarosSequence,
            seriesEclipseCount: eclipse.sarosSeriesCount,
            seriesProgressesSouthToNorth: seriesProgressesSouthToNorth
        )
        upsert(event, into: &eventsByBin)
    }

    private static func seriesProgressesSouthToNorth(in interval: SarosInterval) -> Bool? {
        guard
            let previousGamma = interval.previous.gamma,
            let nextGamma = interval.next.gamma,
            previousGamma.isFinite,
            nextGamma.isFinite,
            previousGamma != nextGamma
        else {
            return nil
        }
        return nextGamma > previousGamma
    }

    private static func seriesWeightingEclipse(
        for date: Date,
        in interval: SarosInterval
    ) -> Eclipse {
        if abs(date.timeIntervalSince(interval.previous.date)) < 1 {
            return interval.previous
        }

        if abs(date.timeIntervalSince(interval.next.date)) < 1 {
            return interval.next
        }

        return interval.next
    }

    private static func eclipseWithMetrics(
        _ eclipse: Eclipse,
        eclipseService: any EclipseService
    ) -> Eclipse {
        guard eclipse.gamma == nil || eclipse.magnitude == nil else { return eclipse }
        return (try? eclipseService.eclipse(withID: eclipse.id)) ?? eclipse
    }

    private static func intervalWithDetailedEclipseMetrics(
        _ interval: SarosInterval,
        eclipseService: any EclipseService
    ) -> SarosInterval {
        SarosInterval(
            saros: interval.saros,
            previous: eclipseWithMetrics(interval.previous, eclipseService: eclipseService),
            next: eclipseWithMetrics(interval.next, eclipseService: eclipseService),
            normalizedPhase: interval.normalizedPhase
        )
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

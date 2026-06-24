import Foundation

enum SarosEventContextError: LocalizedError {
    case noSpikes(Date)

    var errorDescription: String? {
        switch self {
        case .noSpikes(let date):
            "Could not derive Saros spikes around \(JournalFormatters.dateTime.string(from: date))."
        }
    }
}

final class SarosEventContextService {
    private let eclipseService: any EclipseService

    init(eclipseService: any EclipseService) {
        self.eclipseService = eclipseService
    }

    func context(
        for date: Date,
        harmonicDepth rawHarmonicDepth: Int = JournalSettings.supportedHarmonicDepth.upperBound
    ) throws -> JournalEventContext {
        let harmonicDepth = JournalSettings.clampedHarmonicDepth(rawHarmonicDepth)
        let allSpikes = try candidateSpikes(around: date, harmonicDepth: harmonicDepth)
        let past = allSpikes
            .filter { $0.date <= date }
            .sorted { $0.date > $1.date }
            .prefix(2)
        let future = allSpikes
            .filter { $0.date > date }
            .sorted { $0.date < $1.date }
            .prefix(2)
        var selectedSpikes = Array(past).reversed() + Array(future)

        if selectedSpikes.count < 4 {
            selectedSpikes = Array(allSpikes.sorted {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            }.prefix(4))
            .sorted { $0.date < $1.date }
        }

        guard !selectedSpikes.isEmpty else {
            throw SarosEventContextError.noSpikes(date)
        }

        let metrics = Self.waveMetrics(at: date, spikes: selectedSpikes)
        return JournalEventContext(
            unixTimestamp: Int64(date.timeIntervalSince1970.rounded(.towardZero)),
            spikes: selectedSpikes,
            energy: metrics.energy,
            energyPercent: metrics.energyPercent,
            slope: metrics.slope,
            momentum: metrics.momentum,
            directionRawValue: metrics.direction.rawValue,
            extremumRawValue: metrics.extremum.rawValue,
            majorPeriodSeconds: metrics.majorPeriodSeconds
        )
    }

    func closestEclipse(to date: Date) throws -> Eclipse {
        let candidates = try eclipseService.allSarosSeries()
            .filter { $0.firstEclipseDate <= date && $0.lastEclipseDate >= date }
            .flatMap { summary -> [Eclipse] in
                guard let interval = try? eclipseService.previousAndNextEclipse(
                    saros: summary.saros,
                    around: date
                ) else {
                    return []
                }
                return [eclipseWithMetrics(interval.previous), eclipseWithMetrics(interval.next)]
            }

        if let closest = candidates.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }) {
            return closest
        }

        throw SarosEventContextError.noSpikes(date)
    }

    func waveformSpikes(
        around date: Date,
        harmonicDepth rawHarmonicDepth: Int = JournalSettings.supportedHarmonicDepth.upperBound,
        displayDuration: TimeInterval = JournalEventWaveform.defaultDisplayDuration,
        paddingDuration: TimeInterval = 172_800
    ) throws -> [JournalSpikeReference] {
        let harmonicDepth = JournalSettings.clampedHarmonicDepth(rawHarmonicDepth)
        let anchorOffsets: [TimeInterval] = [
            -paddingDuration,
            -displayDuration,
            0,
            displayDuration,
            paddingDuration
        ]
        var spikesByKey: [String: JournalSpikeReference] = [:]
        var lastError: Error?

        for offset in anchorOffsets {
            do {
                let anchorDate = date.addingTimeInterval(offset)
                for spike in try candidateSpikes(around: anchorDate, harmonicDepth: harmonicDepth) {
                    upsert(spike, into: &spikesByKey)
                }
            } catch {
                lastError = error
            }
        }

        let spikes = spikesByKey.values.sorted {
            if $0.date != $1.date {
                return $0.date < $1.date
            }
            if $0.saros != $1.saros {
                return $0.saros < $1.saros
            }
            return $0.rarity > $1.rarity
        }

        if !spikes.isEmpty {
            return spikes
        }

        if let lastError {
            throw lastError
        }

        throw SarosEventContextError.noSpikes(date)
    }

    private func candidateSpikes(
        around date: Date,
        harmonicDepth: Int
    ) throws -> [JournalSpikeReference] {
        let summaries = try eclipseService.allSarosSeries()
            .filter { $0.firstEclipseDate < date && $0.lastEclipseDate > date }
            .sorted { $0.saros < $1.saros }
        let rarities = FlipRarity.eventRarities(for: harmonicDepth)
            .filter { $0 >= .epic }
        var spikesByKey: [String: JournalSpikeReference] = [:]

        for summary in summaries {
            guard let interval = try eclipseService.previousAndNextEclipse(saros: summary.saros, around: date),
                  let reading = try? SarosClockCalculator.reading(
                    saros: summary.saros,
                    previous: interval.previous,
                    next: interval.next,
                    now: date,
                    harmonicDepth: harmonicDepth
                  )
            else {
                continue
            }

            let detailedNext = eclipseWithMetrics(interval.next)
            let detailedPrevious = eclipseWithMetrics(interval.previous)
            appendBoundarySpike(
                eclipse: detailedPrevious,
                reading: reading,
                into: &spikesByKey
            )
            appendBoundarySpike(
                eclipse: detailedNext,
                reading: reading,
                into: &spikesByKey
            )

            for rarity in rarities {
                if let previousBin = reading.previousQualifiedFlipBin(
                    atOrBefore: reading.binIndex,
                    rarity: rarity,
                    exact: true
                ) {
                    appendSpike(
                        binIndex: previousBin,
                        rarity: rarity,
                        reading: reading,
                        eclipse: detailedNext,
                        into: &spikesByKey
                    )
                }

                if let nextBin = reading.nextQualifiedFlipBin(
                    after: max(reading.binIndex - 1, -1),
                    rarity: rarity,
                    exact: true
                ) {
                    appendSpike(
                        binIndex: nextBin,
                        rarity: rarity,
                        reading: reading,
                        eclipse: detailedNext,
                        into: &spikesByKey
                    )
                }
            }
        }

        return spikesByKey.values.sorted {
            if $0.date != $1.date {
                return $0.date < $1.date
            }
            if $0.saros != $1.saros {
                return $0.saros < $1.saros
            }
            return $0.rarity > $1.rarity
        }
    }

    private func appendSpike(
        binIndex: Int,
        rarity: FlipRarity,
        reading: SarosClockReading,
        eclipse: Eclipse,
        into spikesByKey: inout [String: JournalSpikeReference]
    ) {
        guard binIndex > 0, binIndex < reading.binCount else { return }
        let date = reading.date(forBinIndex: binIndex)
        let spike = JournalSpikeReference(
            saros: reading.saros,
            unixTimestamp: Int64(date.timeIntervalSince1970.rounded(.towardZero)),
            octalAddress: reading.octalAddress(forBinIndex: binIndex),
            harmonicDepth: reading.harmonicDepth,
            rarityRawValue: rarity.rawValue,
            gamma: eclipse.gamma,
            magnitude: eclipse.magnitude
        )
        upsert(spike, into: &spikesByKey)
    }

    private func appendBoundarySpike(
        eclipse: Eclipse,
        reading: SarosClockReading,
        into spikesByKey: inout [String: JournalSpikeReference]
    ) {
        let spike = JournalSpikeReference(
            saros: eclipse.saros,
            unixTimestamp: Int64(eclipse.date.timeIntervalSince1970.rounded(.towardZero)),
            octalAddress: String(repeating: "7", count: reading.harmonicDepth),
            harmonicDepth: reading.harmonicDepth,
            rarityRawValue: FlipRarity.mythicDigit(7).rawValue,
            gamma: eclipse.gamma,
            magnitude: eclipse.magnitude
        )
        upsert(spike, into: &spikesByKey)
    }

    private func upsert(
        _ spike: JournalSpikeReference,
        into spikesByKey: inout [String: JournalSpikeReference]
    ) {
        let key = "\(spike.saros)-\(spike.unixTimestamp)"
        if let existing = spikesByKey[key] {
            if spike.rarity > existing.rarity {
                spikesByKey[key] = spike
            }
        } else {
            spikesByKey[key] = spike
        }
    }

    private func eclipseWithMetrics(_ eclipse: Eclipse) -> Eclipse {
        guard eclipse.gamma == nil || eclipse.magnitude == nil else { return eclipse }
        return (try? eclipseService.eclipse(withID: eclipse.id)) ?? eclipse
    }
}

struct JournalWaveMetricsSnapshot {
    let energy: Double
    let energyPercent: Double
    let slope: Double
    let momentum: Double
    let direction: JournalWaveDirection
    let extremum: JournalWaveExtremum
    let majorPeriodSeconds: TimeInterval
}

struct JournalWaveDynamicsSnapshot {
    let slope: Double
    let momentum: Double
    let direction: JournalWaveDirection
}

struct JournalSplineWaveformSample: Equatable {
    let date: Date
    let energy: Double
}

struct JournalSplineWaveformPoint: Equatable {
    let date: Date
    let height: Double
}

enum JournalEventSplineWaveform {
    static func displayInterval(
        centeredOn date: Date,
        duration: TimeInterval = 86_400
    ) -> DateInterval {
        DateInterval(
            start: date.addingTimeInterval(-duration / 2),
            end: date.addingTimeInterval(duration / 2)
        )
    }

    static func visibleSpikes(
        in interval: DateInterval,
        spikes: [JournalSpikeReference]
    ) -> [JournalSpikeReference] {
        spikes
            .filter { interval.contains($0.date) }
            .sorted {
                if $0.date != $1.date {
                    return $0.date < $1.date
                }
                return $0.rarity > $1.rarity
            }
    }

    static func controlPoints(
        in interval: DateInterval,
        spikes: [JournalSpikeReference]
    ) -> [JournalSplineWaveformPoint] {
        var pointHeightsBySecond: [Int64: Double] = [
            Int64(interval.start.timeIntervalSince1970.rounded(.towardZero)): 0,
            Int64(interval.end.timeIntervalSince1970.rounded(.towardZero)): 0
        ]

        for spike in visibleSpikes(in: interval, spikes: spikes) {
            let key = Int64(spike.date.timeIntervalSince1970.rounded(.towardZero))
            pointHeightsBySecond[key] = max(pointHeightsBySecond[key] ?? 0, height(for: spike))
        }

        return pointHeightsBySecond
            .map { second, height in
                JournalSplineWaveformPoint(
                    date: Date(timeIntervalSince1970: TimeInterval(second)),
                    height: height
                )
            }
            .sorted { $0.date < $1.date }
    }

    static func samples(
        in interval: DateInterval,
        count: Int,
        controlPoints points: [JournalSplineWaveformPoint]
    ) -> [JournalSplineWaveformSample] {
        guard !points.isEmpty, interval.duration > 0 else { return [] }
        let sampleCount = max(count, 1)

        return (0...sampleCount).map { index in
            let date = interval.start.addingTimeInterval(interval.duration * Double(index) / Double(sampleCount))
            return JournalSplineWaveformSample(date: date, energy: energy(at: date, controlPoints: points))
        }
    }

    static func energy(
        at date: Date,
        in interval: DateInterval,
        spikes: [JournalSpikeReference]
    ) -> Double {
        energy(at: date, controlPoints: controlPoints(in: interval, spikes: spikes))
    }

    static func energy(
        at date: Date,
        controlPoints points: [JournalSplineWaveformPoint]
    ) -> Double {
        guard !points.isEmpty else { return 0 }
        guard points.count > 1 else { return points[0].height }

        if date <= points[0].date {
            return points[0].height
        }

        if date >= points[points.count - 1].date {
            return points[points.count - 1].height
        }

        let segmentIndex = segmentIndex(for: date, points: points)
        let previous = points[max(segmentIndex - 1, points.startIndex)]
        let start = points[segmentIndex]
        let end = points[segmentIndex + 1]
        let next = points[min(segmentIndex + 2, points.index(before: points.endIndex))]
        let segmentDuration = max(end.date.timeIntervalSince(start.date), 1)
        let t = min(max(date.timeIntervalSince(start.date) / segmentDuration, 0), 1)
        let value = catmullRom(
            previous.height,
            start.height,
            end.height,
            next.height,
            t: t
        )
        let maxHeight = max(points.map(\.height).max() ?? 1, 1)
        return min(max(value, 0), maxHeight * 1.15)
    }

    static func height(for spike: JournalSpikeReference) -> Double {
        baseHeight(for: spike.rarity)
            * 2.5
            * magnitudeAmplitudeMultiplier(for: spike.magnitude)
            * gammaAmplitudeMultiplier(for: spike.gamma)
    }

    private static func segmentIndex(
        for date: Date,
        points: [JournalSplineWaveformPoint]
    ) -> Int {
        var low = 0
        var high = points.count - 2

        while low <= high {
            let middle = (low + high) / 2
            if date < points[middle].date {
                high = middle - 1
            } else if date > points[middle + 1].date {
                low = middle + 1
            } else {
                return middle
            }
        }

        return min(max(low, 0), points.count - 2)
    }

    private static func catmullRom(
        _ p0: Double,
        _ p1: Double,
        _ p2: Double,
        _ p3: Double,
        t: Double
    ) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1)
            + (-p0 + p2) * t
            + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
            + (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    private static func baseHeight(for rarity: FlipRarity) -> Double {
        switch rarity.baseRarity {
        case .mythic: 4
        case .legendary: 2
        case .epic: 1
        case .rare: 0.5
        default: 0.25
        }
    }

    private static func magnitudeAmplitudeMultiplier(for magnitude: Double?) -> Double {
        guard let magnitude, magnitude.isFinite else { return 1 }
        return min(max(magnitude, 0.18), 1.8)
    }

    private static func gammaAmplitudeMultiplier(for gamma: Double?) -> Double {
        guard let gamma, gamma.isFinite else { return 1 }
        return min(max(1 / max(abs(gamma), 0.35), 0.65), 2.0)
    }
}

struct JournalEventWaveSample: Equatable {
    let date: Date
    let position: Double
    let energy: Double
}

struct JournalEventWaveSamples {
    static let empty = JournalEventWaveSamples(
        interval: DateInterval(start: .distantPast, duration: 1),
        points: [],
        maxEnergy: 1,
        eventEnergyByID: [:]
    )

    let interval: DateInterval
    let points: [JournalEventWaveSample]
    let maxEnergy: Double
    let eventEnergyByID: [String: Double]
}

struct JournalEventWavePeriod {
    let spike: JournalSpikeReference
    let previousSpike: JournalSpikeReference?
    let nextSpike: JournalSpikeReference?
    let leftBoundary: Date
    let rightBoundary: Date

    var duration: TimeInterval {
        max(rightBoundary.timeIntervalSince(leftBoundary), 1)
    }
}

struct JournalEventWaveComponent {
    static let defaultGaussianExtent = 3.2

    let id: String
    let sourceSpikeID: String
    let period: JournalEventWavePeriod
    let peakHeight: Double
    let gaussianExtent: Double

    var spike: JournalSpikeReference {
        period.spike
    }

    var periodInterval: DateInterval {
        DateInterval(start: period.leftBoundary, end: period.rightBoundary)
    }

    func contains(_ date: Date) -> Bool {
        date >= period.leftBoundary && date <= period.rightBoundary
    }

    func energy(at date: Date) -> Double {
        guard contains(date) else { return 0 }

        let x = gaussianCoordinate(at: date)
        let boundaryValue = exp(-0.5 * gaussianExtent * gaussianExtent)
        let raw = exp(-0.5 * x * x)
        let normalized = max((raw - boundaryValue) / max(1 - boundaryValue, 0.000_000_001), 0)

        return peakHeight * normalized
    }

    func derivative(at date: Date) -> Double {
        guard contains(date) else { return 0 }
        let step = min(max(width(for: date.timeIntervalSince(spike.date)) / 600, 60), 1_800)
        let before = max(period.leftBoundary, date.addingTimeInterval(-step))
        let after = min(period.rightBoundary, date.addingTimeInterval(step))
        let duration = max(after.timeIntervalSince(before), 1)

        return (energy(at: after) - energy(at: before)) / duration
    }

    private func width(for offset: TimeInterval) -> TimeInterval {
        offset < 0
            ? max(spike.date.timeIntervalSince(period.leftBoundary), 1)
            : max(period.rightBoundary.timeIntervalSince(spike.date), 1)
    }

    private func gaussianCoordinate(at date: Date) -> Double {
        let offset = date.timeIntervalSince(spike.date)
        let normalized = min(max(offset / width(for: offset), -1), 1)
        return normalized * gaussianExtent
    }
}

struct JournalEventWaveField {
    static let empty = JournalEventWaveField(components: [])

    let components: [JournalEventWaveComponent]
    let maxPeakHeight: Double

    init(components: [JournalEventWaveComponent]) {
        self.components = components
        self.maxPeakHeight = components.map(\.peakHeight).max() ?? 0
    }

    var coveredInterval: DateInterval? {
        guard
            let start = components.map(\.period.leftBoundary).min(),
            let end = components.map(\.period.rightBoundary).max(),
            end > start
        else {
            return nil
        }

        return DateInterval(start: start, end: end)
    }

    func energy(at date: Date) -> Double {
        energy(at: date, in: components)
    }

    func derivative(at date: Date) -> Double {
        components.reduce(0) { total, component in
            guard component.contains(date) else { return total }
            return total + component.derivative(at: date)
        }
    }

    func samples(
        in interval: DateInterval,
        sampleCount: Int,
        spikes: [JournalSpikeReference]
    ) -> JournalEventWaveSamples {
        let visibleComponents = components.filter { interval.intersects($0.periodInterval) }
        guard !visibleComponents.isEmpty, sampleCount > 1, interval.duration > 0 else {
            return JournalEventWaveSamples(
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

            return JournalEventWaveSample(
                date: date,
                position: position,
                energy: energy
            )
        }

        var eventEnergyByID: [String: Double] = [:]
        for spike in spikes {
            eventEnergyByID[spike.id] = energy(at: spike.date, in: visibleComponents)
        }

        return JournalEventWaveSamples(
            interval: interval,
            points: points,
            maxEnergy: max(maxEnergy, maxPeakHeight, 0.000_000_001),
            eventEnergyByID: eventEnergyByID
        )
    }

    func maxEnergy(in interval: DateInterval, sampleCount: Int = 768) -> Double {
        let visibleComponents = components.filter { interval.intersects($0.periodInterval) }
        guard !visibleComponents.isEmpty, interval.duration > 0 else {
            return max(maxPeakHeight, 0.000_000_001)
        }

        var maximum = 0.0
        for index in 0...max(sampleCount, 1) {
            let ratio = Double(index) / Double(max(sampleCount, 1))
            let date = interval.start.addingTimeInterval(interval.duration * ratio)
            maximum = max(maximum, energy(at: date, in: visibleComponents))
        }

        return max(maximum, maxPeakHeight, 0.000_000_001)
    }

    func energyRange(in interval: DateInterval, sampleCount: Int = 384) -> Double {
        let visibleComponents = components.filter { interval.intersects($0.periodInterval) }
        guard !visibleComponents.isEmpty, interval.duration > 0 else { return 0 }

        var minimum = Double.greatestFiniteMagnitude
        var maximum = 0.0
        for index in 0...max(sampleCount, 1) {
            let ratio = Double(index) / Double(max(sampleCount, 1))
            let date = interval.start.addingTimeInterval(interval.duration * ratio)
            let energy = energy(at: date, in: visibleComponents)
            minimum = min(minimum, energy)
            maximum = max(maximum, energy)
        }

        guard minimum.isFinite else { return 0 }
        return max(maximum - minimum, 0)
    }

    private func energy(
        at date: Date,
        in candidateComponents: [JournalEventWaveComponent]
    ) -> Double {
        candidateComponents.reduce(0) { total, component in
            guard component.contains(date) else { return total }
            return total + component.energy(at: date)
        }
    }
}

enum JournalEventWaveform {
    static let defaultDisplayDuration: TimeInterval = 43_200

    private static let baseAmplitudeMultiplier = 2.5

    static func displayInterval(
        centeredOn date: Date,
        duration: TimeInterval = defaultDisplayDuration
    ) -> DateInterval {
        DateInterval(
            start: date.addingTimeInterval(-duration / 2),
            end: date.addingTimeInterval(duration / 2)
        )
    }

    static func visibleSpikes(
        in interval: DateInterval,
        spikes: [JournalSpikeReference]
    ) -> [JournalSpikeReference] {
        spikes
            .filter { interval.contains($0.date) }
            .sorted {
                if $0.date != $1.date {
                    return $0.date < $1.date
                }
                return $0.rarity > $1.rarity
            }
    }

    static func field(spikes: [JournalSpikeReference]) -> JournalEventWaveField {
        let sortedSpikes = spikes.sorted { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date < rhs.date
            }
            return lhs.rarity > rhs.rarity
        }

        let components = sortedSpikes.indices.compactMap { index -> JournalEventWaveComponent? in
            let spike = sortedSpikes[index]
            let previous = previousDistinctSpike(in: sortedSpikes, before: index)
            let next = nextDistinctSpike(in: sortedSpikes, after: index)
            let leftGap = max(
                previous.map { spike.date.timeIntervalSince($0.date) }
                    ?? next.map { $0.date.timeIntervalSince(spike.date) }
                    ?? 86_400,
                1
            )
            let rightGap = max(
                next.map { $0.date.timeIntervalSince(spike.date) }
                    ?? leftGap,
                1
            )
            let leftBoundary = previous.map { midpoint($0.date, spike.date) }
                ?? spike.date.addingTimeInterval(-leftGap / 2)
            let rightBoundary = next.map { midpoint(spike.date, $0.date) }
                ?? spike.date.addingTimeInterval(rightGap / 2)

            return component(
                spike: spike,
                previous: previous,
                next: next,
                leftBoundary: leftBoundary,
                rightBoundary: rightBoundary,
                index: index
            )
        }

        return JournalEventWaveField(components: components)
    }

    static func peakHeight(for spike: JournalSpikeReference) -> Double {
        basePeakHeight(for: spike.rarity)
            * baseAmplitudeMultiplier
            * magnitudeAmplitudeMultiplier(for: spike.magnitude)
    }

    private static func component(
        spike: JournalSpikeReference,
        previous: JournalSpikeReference?,
        next: JournalSpikeReference?,
        leftBoundary: Date,
        rightBoundary: Date,
        index: Int
    ) -> JournalEventWaveComponent? {
        guard rightBoundary.timeIntervalSince(leftBoundary) > 1 else { return nil }

        return JournalEventWaveComponent(
            id: "\(spike.id)-field-\(index)",
            sourceSpikeID: spike.id,
            period: JournalEventWavePeriod(
                spike: spike,
                previousSpike: previous,
                nextSpike: next,
                leftBoundary: leftBoundary,
                rightBoundary: rightBoundary
            ),
            peakHeight: peakHeight(for: spike),
            gaussianExtent: gaussianExtent(forGamma: spike.gamma)
        )
    }

    private static func basePeakHeight(for rarity: FlipRarity) -> Double {
        switch rarity.baseRarity {
        case .mythic: 4
        case .legendary: 2
        case .epic: 1
        case .rare: 0.5
        default: 0.25
        }
    }

    private static func magnitudeAmplitudeMultiplier(for magnitude: Double?) -> Double {
        guard let magnitude, magnitude.isFinite else { return 1 }
        return min(max(magnitude, 0.18), 1.8)
    }

    private static func gaussianExtent(forGamma gamma: Double?) -> Double {
        guard let gamma, gamma.isFinite else {
            return JournalEventWaveComponent.defaultGaussianExtent
        }

        let gammaScale = min(max(sqrt(max(abs(gamma), 0.02)), 0.45), 1.45)
        return JournalEventWaveComponent.defaultGaussianExtent * gammaScale
    }

    private static func previousDistinctSpike(
        in spikes: [JournalSpikeReference],
        before index: Int
    ) -> JournalSpikeReference? {
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

    private static func nextDistinctSpike(
        in spikes: [JournalSpikeReference],
        after index: Int
    ) -> JournalSpikeReference? {
        var cursor = index + 1

        while cursor < spikes.endIndex {
            if spikes[cursor].date != spikes[index].date {
                return spikes[cursor]
            }
            cursor += 1
        }

        return nil
    }

    private static func midpoint(_ lhs: Date, _ rhs: Date) -> Date {
        lhs.addingTimeInterval(rhs.timeIntervalSince(lhs) / 2)
    }
}

enum JournalWaveMetricsCalculator {
    private static let flatAngleThreshold = 5.0 * Double.pi / 180.0
    private static let verticalAngleReference = 80.0 * Double.pi / 180.0
    private static let visualWindow: TimeInterval = 86_400
    private static let visualStep: TimeInterval = 900
    static let flatMomentumThreshold = tan(flatAngleThreshold) / tan(verticalAngleReference)

    static func metrics(
        at date: Date,
        spikes: [JournalSpikeReference]
    ) -> JournalWaveMetricsSnapshot {
        let sorted = spikes.sorted { $0.date < $1.date }
        let majorPeriod: TimeInterval
        if let first = sorted.first?.date, let last = sorted.last?.date {
            majorPeriod = Swift.max(last.timeIntervalSince(first), 0.0)
        } else {
            majorPeriod = 0.0
        }

        let field = JournalEventWaveform.field(spikes: sorted)
        let energy = field.energy(at: date)
        let maxEnergy = field.coveredInterval.map { field.maxEnergy(in: $0) } ?? 0
        let normalizedEnergy = Swift.max(energy / Swift.max(maxEnergy, 1.0), 0.0)
        let energyPercent = maxEnergy > 0 ? Swift.min(normalizedEnergy, 1.0) : 0.0
        let dynamics = dynamics(at: date, spikes: sorted)

        let extremum: JournalWaveExtremum
        if energyPercent >= 0.99 {
            extremum = .localMaximum
        } else if energyPercent <= 0.01 {
            extremum = .localMinimum
        } else {
            extremum = .none
        }

        return JournalWaveMetricsSnapshot(
            energy: energy,
            energyPercent: energyPercent,
            slope: dynamics.slope,
            momentum: dynamics.momentum,
            direction: dynamics.direction,
            extremum: extremum,
            majorPeriodSeconds: majorPeriod
        )
    }

    static func dynamics(
        at date: Date,
        spikes: [JournalSpikeReference]
    ) -> JournalWaveDynamicsSnapshot {
        let sorted = spikes.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else {
            return JournalWaveDynamicsSnapshot(slope: 0, momentum: 0, direction: .flat)
        }

        let interval = JournalEventWaveform.displayInterval(centeredOn: date)
        let field = JournalEventWaveform.field(spikes: sorted)
        let before = date.addingTimeInterval(-visualStep)
        let after = date.addingTimeInterval(visualStep)
        let beforeEnergy = field.energy(at: before)
        let afterEnergy = field.energy(at: after)
        let slope = (afterEnergy - beforeEnergy) / Swift.max(after.timeIntervalSince(before), 1.0)
        let range = field.energyRange(in: interval)
        guard range > 0.000_000_001 else {
            return JournalWaveDynamicsSnapshot(slope: slope, momentum: 0, direction: .flat)
        }

        let rise = (afterEnergy - beforeEnergy) / range
        let run = after.timeIntervalSince(before) / visualWindow
        let gradient = rise / Swift.max(run, 0.000_000_001)
        let angle = atan(abs(gradient))
        let direction: JournalWaveDirection
        if angle <= flatAngleThreshold {
            direction = .flat
        } else {
            direction = gradient > 0 ? .ascending : .descending
        }
        let normalized = Swift.min(abs(gradient) / tan(verticalAngleReference), 1.0)
        let momentum = direction == .flat ? 0.0 : normalized * (gradient > 0 ? 1.0 : -1.0)
        return JournalWaveDynamicsSnapshot(
            slope: slope,
            momentum: momentum,
            direction: direction
        )
    }

    private static func mixtureEnergy(
        at date: Date,
        spikes: [JournalSpikeReference]
    ) -> Double {
        spikes.enumerated().reduce(0) { energy, item in
            let (index, spike) = item
            let left = boundaryBefore(index: index, spikes: spikes)
            let right = boundaryAfter(index: index, spikes: spikes)
            return energy + gaussianEnergy(at: date, spike: spike, leftBoundary: left, rightBoundary: right)
        }
    }

    private static func sampledMaxEnergy(spikes: [JournalSpikeReference]) -> Double {
        guard let first = spikes.first?.date, let last = spikes.last?.date else { return 0 }
        let duration = max(last.timeIntervalSince(first), 1)
        let sampleCount = 256

        return (0...sampleCount).reduce(0) { maximum, index in
            let date = first.addingTimeInterval(duration * Double(index) / Double(sampleCount))
            return max(maximum, mixtureEnergy(at: date, spikes: spikes))
        }
    }

    private static func sampledMaxSlope(spikes: [JournalSpikeReference]) -> Double {
        guard let first = spikes.first?.date, let last = spikes.last?.date else { return 0 }
        let duration = max(last.timeIntervalSince(first), 1)
        let sampleCount = 256
        let step = max(duration / Double(sampleCount), 1)
        var maximum = 0.0

        for index in 0...sampleCount {
            let date = first.addingTimeInterval(duration * Double(index) / Double(sampleCount))
            let before = date.addingTimeInterval(-step)
            let after = date.addingTimeInterval(step)
            let slope = (mixtureEnergy(at: after, spikes: spikes) - mixtureEnergy(at: before, spikes: spikes)) / (step * 2)
            maximum = max(maximum, abs(slope))
        }

        return maximum
    }

    private static func sampledEnergyRange(
        in interval: DateInterval,
        spikes: [JournalSpikeReference]
    ) -> Double {
        let sampleCount = 192
        var minimum = Double.greatestFiniteMagnitude
        var maximum = 0.0

        for index in 0...sampleCount {
            let date = interval.start.addingTimeInterval(interval.duration * Double(index) / Double(sampleCount))
            let energy = mixtureEnergy(at: date, spikes: spikes)
            minimum = min(minimum, energy)
            maximum = max(maximum, energy)
        }

        guard minimum.isFinite else { return 0 }
        return max(maximum - minimum, 0)
    }

    private static func sampledSplineEnergyRange(
        in interval: DateInterval,
        controlPoints: [JournalSplineWaveformPoint]
    ) -> Double {
        let sampleCount = 192
        var minimum = Double.greatestFiniteMagnitude
        var maximum = 0.0

        for index in 0...sampleCount {
            let date = interval.start.addingTimeInterval(interval.duration * Double(index) / Double(sampleCount))
            let energy = JournalEventSplineWaveform.energy(at: date, controlPoints: controlPoints)
            minimum = min(minimum, energy)
            maximum = max(maximum, energy)
        }

        guard minimum.isFinite else { return 0 }
        return max(maximum - minimum, 0)
    }

    private static func boundaryBefore(index: Int, spikes: [JournalSpikeReference]) -> Date {
        let spike = spikes[index]
        guard index > spikes.startIndex else {
            let next = spikes.dropFirst().first?.date ?? spike.date.addingTimeInterval(86_400)
            return spike.date.addingTimeInterval(-max(next.timeIntervalSince(spike.date), 1) / 2)
        }
        return midpoint(spikes[index - 1].date, spike.date)
    }

    private static func boundaryAfter(index: Int, spikes: [JournalSpikeReference]) -> Date {
        let spike = spikes[index]
        guard index < spikes.index(before: spikes.endIndex) else {
            let previous = index > spikes.startIndex ? spikes[index - 1].date : spike.date.addingTimeInterval(-86_400)
            return spike.date.addingTimeInterval(max(spike.date.timeIntervalSince(previous), 1) / 2)
        }
        return midpoint(spike.date, spikes[index + 1].date)
    }

    private static func gaussianEnergy(
        at date: Date,
        spike: JournalSpikeReference,
        leftBoundary: Date,
        rightBoundary: Date
    ) -> Double {
        guard date >= leftBoundary, date <= rightBoundary else { return 0 }
        let offset = date.timeIntervalSince(spike.date)
        let span = max(offset < 0 ? spike.date.timeIntervalSince(leftBoundary) : rightBoundary.timeIntervalSince(spike.date), 1)
        let extent = gaussianExtent(forGamma: spike.gamma)
        let x = min(max(offset / span, -1), 1) * extent
        let boundaryValue = exp(-0.5 * extent * extent)
        let raw = exp(-0.5 * x * x)
        let normalized = max((raw - boundaryValue) / max(1 - boundaryValue, 0.000_000_001), 0)
        return peakHeight(for: spike) * normalized
    }

    private static func peakHeight(for spike: JournalSpikeReference) -> Double {
        basePeakHeight(for: spike.rarity) * 2.5 * magnitudeAmplitudeMultiplier(for: spike.magnitude)
    }

    private static func basePeakHeight(for rarity: FlipRarity) -> Double {
        switch rarity.baseRarity {
        case .mythic: 4
        case .legendary: 2
        case .epic: 1
        case .rare: 0.5
        default: 0.25
        }
    }

    private static func magnitudeAmplitudeMultiplier(for magnitude: Double?) -> Double {
        guard let magnitude, magnitude.isFinite else { return 1 }
        return min(max(magnitude, 0.18), 1.8)
    }

    private static func gaussianExtent(forGamma gamma: Double?) -> Double {
        guard let gamma, gamma.isFinite else { return 3.2 }
        return 3.2 * min(max(sqrt(max(abs(gamma), 0.02)), 0.45), 1.45)
    }

    private static func midpoint(_ lhs: Date, _ rhs: Date) -> Date {
        lhs.addingTimeInterval(rhs.timeIntervalSince(lhs) / 2)
    }
}

extension SarosEventContextService {
    fileprivate struct WaveMetrics {
        let energy: Double
        let energyPercent: Double
        let slope: Double
        let momentum: Double
        let direction: JournalWaveDirection
        let extremum: JournalWaveExtremum
        let majorPeriodSeconds: TimeInterval
    }

    fileprivate static func waveMetrics(
        at date: Date,
        spikes: [JournalSpikeReference]
    ) -> WaveMetrics {
        let metrics = JournalWaveMetricsCalculator.metrics(at: date, spikes: spikes)
        return WaveMetrics(
            energy: metrics.energy,
            energyPercent: metrics.energyPercent,
            slope: metrics.slope,
            momentum: metrics.momentum,
            direction: metrics.direction,
            extremum: metrics.extremum,
            majorPeriodSeconds: metrics.majorPeriodSeconds
        )
    }

    fileprivate static func mixtureEnergy(
        at date: Date,
        spikes: [JournalSpikeReference]
    ) -> Double {
        spikes.enumerated().reduce(0) { energy, item in
            let (index, spike) = item
            let left = boundaryBefore(index: index, spikes: spikes)
            let right = boundaryAfter(index: index, spikes: spikes)
            return energy + gaussianEnergy(at: date, spike: spike, leftBoundary: left, rightBoundary: right)
        }
    }

    private static func sampledMaxEnergy(spikes: [JournalSpikeReference]) -> Double {
        guard let first = spikes.first?.date, let last = spikes.last?.date else { return 0 }
        let duration = max(last.timeIntervalSince(first), 1)
        let sampleCount = 256

        return (0...sampleCount).reduce(0) { maximum, index in
            let date = first.addingTimeInterval(duration * Double(index) / Double(sampleCount))
            return max(maximum, mixtureEnergy(at: date, spikes: spikes))
        }
    }

    private static func sampledMaxSlope(spikes: [JournalSpikeReference]) -> Double {
        guard let first = spikes.first?.date, let last = spikes.last?.date else { return 0 }
        let duration = max(last.timeIntervalSince(first), 1)
        let sampleCount = 256
        let step = max(duration / Double(sampleCount), 1)
        var maximum = 0.0

        for index in 0...sampleCount {
            let date = first.addingTimeInterval(duration * Double(index) / Double(sampleCount))
            let before = date.addingTimeInterval(-step)
            let after = date.addingTimeInterval(step)
            let slope = (mixtureEnergy(at: after, spikes: spikes) - mixtureEnergy(at: before, spikes: spikes)) / (step * 2)
            maximum = max(maximum, abs(slope))
        }

        return maximum
    }

    private static func boundaryBefore(index: Int, spikes: [JournalSpikeReference]) -> Date {
        let spike = spikes[index]
        guard index > spikes.startIndex else {
            let next = spikes.dropFirst().first?.date ?? spike.date.addingTimeInterval(86_400)
            return spike.date.addingTimeInterval(-max(next.timeIntervalSince(spike.date), 1) / 2)
        }
        return midpoint(spikes[index - 1].date, spike.date)
    }

    private static func boundaryAfter(index: Int, spikes: [JournalSpikeReference]) -> Date {
        let spike = spikes[index]
        guard index < spikes.index(before: spikes.endIndex) else {
            let previous = index > spikes.startIndex ? spikes[index - 1].date : spike.date.addingTimeInterval(-86_400)
            return spike.date.addingTimeInterval(max(spike.date.timeIntervalSince(previous), 1) / 2)
        }
        return midpoint(spike.date, spikes[index + 1].date)
    }

    private static func gaussianEnergy(
        at date: Date,
        spike: JournalSpikeReference,
        leftBoundary: Date,
        rightBoundary: Date
    ) -> Double {
        guard date >= leftBoundary, date <= rightBoundary else { return 0 }
        let offset = date.timeIntervalSince(spike.date)
        let span = max(offset < 0 ? spike.date.timeIntervalSince(leftBoundary) : rightBoundary.timeIntervalSince(spike.date), 1)
        let extent = gaussianExtent(forGamma: spike.gamma)
        let x = min(max(offset / span, -1), 1) * extent
        let boundaryValue = exp(-0.5 * extent * extent)
        let raw = exp(-0.5 * x * x)
        let normalized = max((raw - boundaryValue) / max(1 - boundaryValue, 0.000_000_001), 0)
        return peakHeight(for: spike) * normalized
    }

    private static func peakHeight(for spike: JournalSpikeReference) -> Double {
        basePeakHeight(for: spike.rarity) * 2.5 * magnitudeAmplitudeMultiplier(for: spike.magnitude)
    }

    private static func basePeakHeight(for rarity: FlipRarity) -> Double {
        switch rarity.baseRarity {
        case .mythic: 4
        case .legendary: 2
        case .epic: 1
        case .rare: 0.5
        default: 0.25
        }
    }

    private static func magnitudeAmplitudeMultiplier(for magnitude: Double?) -> Double {
        guard let magnitude, magnitude.isFinite else { return 1 }
        return min(max(magnitude, 0.18), 1.8)
    }

    private static func gaussianExtent(forGamma gamma: Double?) -> Double {
        guard let gamma, gamma.isFinite else { return 3.2 }
        return 3.2 * min(max(sqrt(max(abs(gamma), 0.02)), 0.45), 1.45)
    }

    private static func midpoint(_ lhs: Date, _ rhs: Date) -> Date {
        lhs.addingTimeInterval(rhs.timeIntervalSince(lhs) / 2)
    }
}

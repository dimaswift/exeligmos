import Foundation

struct JournalTemporalSegment: Hashable {
    enum BoundaryKind: String, Hashable {
        case peak
        case valley
    }

    let startTimestamp: Int64
    let endTimestamp: Int64
    let startSarosNumber: Int
    let endSarosNumber: Int
    let startKind: BoundaryKind
    let endKind: BoundaryKind

    var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(startTimestamp))
    }

    var endDate: Date {
        Date(timeIntervalSince1970: TimeInterval(endTimestamp))
    }

    var duration: TimeInterval {
        max(endDate.timeIntervalSince(startDate), 1)
    }

    func contains(_ date: Date) -> Bool {
        date >= startDate && date <= endDate
    }

    func normalizedPosition(for date: Date) -> Double {
        min(max(date.timeIntervalSince(startDate) / duration, 0), 1)
    }
}

struct JournalTemporalSample: Hashable {
    let date: Date
    let segment: JournalTemporalSegment
    let energy: Double
    let energyPercent: Double
    let momentum: Double
    let normalizedPosition: Double
    let type: JournalWaveEventType
    let momentumBin: Int
    let signature: JournalWaveSignature

    var direction: JournalWaveDirection {
        signature.direction
    }

    var extremum: JournalWaveExtremum {
        switch type {
        case .peak:
            .localMaximum
        case .valley:
            .localMinimum
        case .ascent, .descent, .flat:
            .none
        }
    }
}

struct JournalTemporalWavePoint: Hashable {
    let date: Date
    let position: Double
    let energy: Double
}

struct JournalTemporalSeries {
    static let empty = JournalTemporalSeries(components: [])

    let components: [JournalTemporalComponent]
    let maxPeakHeight: Double
    let subdivisionDepth: Int

    private let componentsBySpikeID: [String: JournalTemporalComponent]

    init(
        components: [JournalTemporalComponent],
        subdivisionDepth: Int = JournalWaveformSettings.defaultSubdivisionDepth
    ) {
        self.components = components
        self.maxPeakHeight = components.map(\.peakHeight).max() ?? 0
        self.subdivisionDepth = min(
            max(subdivisionDepth, JournalWaveformSettings.subdivisionDepthRange.lowerBound),
            JournalWaveformSettings.subdivisionDepthRange.upperBound
        )
        self.componentsBySpikeID = components.reduce(into: [:]) { lookup, component in
            for spike in component.contributorSpikes {
                lookup[spike.id] = component
            }
        }
    }

    var coveredInterval: DateInterval? {
        guard
            let start = components.map(\.leftBoundary).min(),
            let end = components.map(\.rightBoundary).max(),
            end > start
        else {
            return nil
        }

        return DateInterval(start: start, end: end)
    }

    func component(for spike: JournalSpikeReference) -> JournalTemporalComponent? {
        componentsBySpikeID[spike.id]
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

    func sample(at date: Date) -> JournalTemporalSample? {
        guard let component = dominantComponent(at: date) ?? nearestComponent(to: date) else {
            return nil
        }

        let energy = self.energy(at: date)
        let peakHeight = max(component.peakHeight, 0.000_000_001)
        let energyPercent = min(max(energy / peakHeight, 0), 1)
        let momentum = momentumEnergyPerSaros(at: date, normalizingBy: peakHeight)
        let segment = component.segment(containing: date)
        let signature = JournalWaveEventDescriptorFormatter.signature(
            energyPercent: energyPercent,
            momentumEnergyPerSaros: momentum,
            valleySpacing: component.periodDuration
        )

        return JournalTemporalSample(
            date: date,
            segment: segment,
            energy: energy,
            energyPercent: energyPercent,
            momentum: momentum,
            normalizedPosition: segment.normalizedPosition(for: date),
            type: signature.type,
            momentumBin: signature.momentumBin,
            signature: signature
        )
    }

    func samples(
        in interval: DateInterval,
        sampleCount: Int
    ) -> [JournalTemporalWavePoint] {
        let visibleComponents = components.filter { interval.intersects($0.periodInterval) }
        guard !visibleComponents.isEmpty, sampleCount > 1, interval.duration > 0 else {
            return []
        }

        return adaptiveSampleDates(
            in: interval,
            components: visibleComponents,
            preferredSampleCount: sampleCount
        )
        .map { date in
            JournalTemporalWavePoint(
                date: date,
                position: min(max(date.timeIntervalSince(interval.start) / interval.duration, 0), 1),
                energy: energy(at: date, in: visibleComponents)
            )
        }
    }

    func maxEnergy(in interval: DateInterval, sampleCount: Int = 768) -> Double {
        let visibleComponents = components.filter { interval.intersects($0.periodInterval) }
        guard !visibleComponents.isEmpty, interval.duration > 0 else {
            return max(maxPeakHeight, 0.000_000_001)
        }

        let maximum = adaptiveSampleDates(
            in: interval,
            components: visibleComponents,
            preferredSampleCount: sampleCount
        )
        .reduce(0.0) { currentMax, date in
            max(currentMax, energy(at: date, in: visibleComponents))
        }

        return max(maximum, maxPeakHeight, 0.000_000_001)
    }

    func energyForSpike(_ spike: JournalSpikeReference) -> Double {
        if let component = component(for: spike) {
            return component.energy(at: component.spike.date)
        }
        return energy(at: spike.date)
    }

    private func energy(
        at date: Date,
        in candidateComponents: [JournalTemporalComponent]
    ) -> Double {
        candidateComponents.reduce(0) { total, component in
            guard component.contains(date) else { return total }
            return total + component.energy(at: date)
        }
    }

    private func dominantComponent(at date: Date) -> JournalTemporalComponent? {
        var dominant: JournalTemporalComponent?
        var dominantEnergy = 0.0

        for component in components where component.contains(date) {
            let energy = component.energy(at: date)
            if energy > dominantEnergy {
                dominantEnergy = energy
                dominant = component
            }
        }

        return dominant
    }

    private func nearestComponent(to date: Date) -> JournalTemporalComponent? {
        components.min {
            $0.distance(to: date) < $1.distance(to: date)
        }
    }

    private func momentumEnergyPerSaros(
        at date: Date,
        normalizingBy peakHeight: Double
    ) -> Double {
        let sarosDuration = SarosPulseCalculator.averageDuration(for: .saros)
        let beforeEnergy = energy(at: date.addingTimeInterval(-sarosDuration))
        let afterEnergy = energy(at: date.addingTimeInterval(sarosDuration))
        return (afterEnergy - beforeEnergy) / max(peakHeight, 0.000_000_001)
    }

    private func adaptiveSampleDates(
        in interval: DateInterval,
        components visibleComponents: [JournalTemporalComponent],
        preferredSampleCount: Int
    ) -> [Date] {
        guard interval.duration > 0 else { return [] }

        let anchors = ([interval.start, interval.end] + visibleComponents.flatMap { $0.controlDates(in: interval) })
            .filter { interval.contains($0) || $0 == interval.end }
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

struct JournalTemporalComponent: Hashable {
    let id: String
    let sourceSpikeID: String
    let contributorSpikes: [JournalSpikeReference]
    let spike: JournalSpikeReference
    let previousSpike: JournalSpikeReference?
    let nextSpike: JournalSpikeReference?
    let leftBoundary: Date
    let rightBoundary: Date
    let peakHeight: Double
    let parabolaA: Double
    let ascentAccelerates: Bool
    let descentAccelerates: Bool

    var periodInterval: DateInterval {
        DateInterval(start: leftBoundary, end: rightBoundary)
    }

    var periodDuration: TimeInterval {
        max(rightBoundary.timeIntervalSince(leftBoundary), 1)
    }

    func contains(_ date: Date) -> Bool {
        date >= leftBoundary && date <= rightBoundary
    }

    func distance(to date: Date) -> TimeInterval {
        if contains(date) { return 0 }
        if date < leftBoundary { return leftBoundary.timeIntervalSince(date) }
        return date.timeIntervalSince(rightBoundary)
    }

    func controlDates(in interval: DateInterval) -> [Date] {
        [
            interval.start,
            leftBoundary,
            spike.date,
            rightBoundary,
            interval.end
        ]
        .filter { interval.contains($0) || $0 == interval.end }
    }

    func segment(containing date: Date) -> JournalTemporalSegment {
        if date <= spike.date {
            return JournalTemporalSegment(
                startTimestamp: Int64(leftBoundary.timeIntervalSince1970.rounded(.towardZero)),
                endTimestamp: spike.unixTimestamp,
                startSarosNumber: previousSpike?.saros ?? spike.saros,
                endSarosNumber: spike.saros,
                startKind: .valley,
                endKind: .peak
            )
        }

        return JournalTemporalSegment(
            startTimestamp: spike.unixTimestamp,
            endTimestamp: Int64(rightBoundary.timeIntervalSince1970.rounded(.towardZero)),
            startSarosNumber: spike.saros,
            endSarosNumber: nextSpike?.saros ?? spike.saros,
            startKind: .peak,
            endKind: .valley
        )
    }

    func energy(at date: Date) -> Double {
        guard contains(date) else { return 0 }
        return peakHeight * min(max(parabolaValue(at: date), 0), 1)
    }

    func derivative(at date: Date) -> Double {
        guard contains(date) else { return 0 }
        let step = min(max(width(for: date.timeIntervalSince(spike.date)) / 600, 60), 1_800)
        let before = max(leftBoundary, date.addingTimeInterval(-step))
        let after = min(rightBoundary, date.addingTimeInterval(step))
        let duration = max(after.timeIntervalSince(before), 1)
        return (energy(at: after) - energy(at: before)) / duration
    }

    private func parabolaValue(at date: Date) -> Double {
        let a = min(max(parabolaA, JournalWaveformSettings.parabolaARange.lowerBound), JournalWaveformSettings.parabolaARange.upperBound)

        if date <= spike.date {
            let duration = max(spike.date.timeIntervalSince(leftBoundary), 1)
            let t = min(max(date.timeIntervalSince(leftBoundary) / duration, 0), 1)
            return ascentAccelerates
                ? pow(t, a)
                : 1 - pow(1 - t, a)
        }

        let duration = max(rightBoundary.timeIntervalSince(spike.date), 1)
        let t = min(max(date.timeIntervalSince(spike.date) / duration, 0), 1)
        return descentAccelerates
            ? 1 - pow(t, a)
            : pow(1 - t, a)
    }

    private func width(for offset: TimeInterval) -> TimeInterval {
        offset < 0
            ? max(spike.date.timeIntervalSince(leftBoundary), 1)
            : max(rightBoundary.timeIntervalSince(spike.date), 1)
    }
}

enum JournalTemporalEngine {
    private static let baseAmplitudeMultiplier = 2.5

    private struct SpikeCluster {
        let primary: JournalSpikeReference
        let contributors: [JournalSpikeReference]

        var date: Date {
            primary.date
        }
    }

    static func series(
        spikes: [JournalSpikeReference],
        parabolaA: Double = JournalWaveformSettings.currentParabolaA,
        options: JournalWaveformOptions = .current
    ) -> JournalTemporalSeries {
        let clusters = preprocessedClusters(spikes: spikes, options: options)
        let components = clusters.indices.compactMap { index -> JournalTemporalComponent? in
            let cluster = clusters[index]
            let spike = cluster.primary
            let previous = previousDistinctCluster(in: clusters, before: index)?.primary
            let next = nextDistinctCluster(in: clusters, after: index)?.primary
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
                cluster: cluster,
                previous: previous,
                next: next,
                leftBoundary: leftBoundary,
                rightBoundary: rightBoundary,
                index: index,
                parabolaA: parabolaA,
                options: options
            )
        }

        return JournalTemporalSeries(
            components: components,
            subdivisionDepth: options.subdivisionDepth
        )
    }

    static func sample(
        at date: Date,
        spikes: [JournalSpikeReference],
        parabolaA: Double = JournalWaveformSettings.currentParabolaA,
        options: JournalWaveformOptions = .current
    ) -> JournalTemporalSample? {
        series(spikes: spikes, parabolaA: parabolaA, options: options)
            .sample(at: date)
    }

    static func metrics(
        at date: Date,
        spikes: [JournalSpikeReference],
        parabolaA: Double = JournalWaveformSettings.currentParabolaA,
        options: JournalWaveformOptions = .current
    ) -> JournalWaveMetricsSnapshot {
        let sorted = spikes.sorted { $0.date < $1.date }
        let majorPeriod: TimeInterval
        if let first = sorted.first?.date, let last = sorted.last?.date {
            majorPeriod = max(last.timeIntervalSince(first), 0)
        } else {
            majorPeriod = 0
        }

        guard let sample = sample(at: date, spikes: sorted, parabolaA: parabolaA, options: options) else {
            return JournalWaveMetricsSnapshot(
                energy: 0,
                energyPercent: 0,
                slope: 0,
                momentum: 0,
                direction: .flat,
                extremum: .none,
                majorPeriodSeconds: majorPeriod
            )
        }

        return JournalWaveMetricsSnapshot(
            energy: sample.energy,
            energyPercent: sample.energyPercent,
            slope: slope(at: date, spikes: sorted, parabolaA: parabolaA, options: options),
            momentum: sample.momentum,
            direction: sample.direction,
            extremum: sample.extremum,
            majorPeriodSeconds: majorPeriod
        )
    }

    private static func slope(
        at date: Date,
        spikes: [JournalSpikeReference],
        parabolaA: Double,
        options: JournalWaveformOptions
    ) -> Double {
        let field = series(spikes: spikes, parabolaA: parabolaA, options: options)
        let sarosDuration = SarosPulseCalculator.averageDuration(for: .saros)
        let before = date.addingTimeInterval(-sarosDuration)
        let after = date.addingTimeInterval(sarosDuration)
        return (field.energy(at: after) - field.energy(at: before)) / max(after.timeIntervalSince(before), 1)
    }

    private static func preprocessedClusters(
        spikes: [JournalSpikeReference],
        options: JournalWaveformOptions
    ) -> [SpikeCluster] {
        let sortedSpikes = spikes.sorted { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date < rhs.date
            }
            if lhs.rarity != rhs.rarity {
                return lhs.rarity > rhs.rarity
            }
            return lhs.saros < rhs.saros
        }

        guard options.mergeCloseSpikes else {
            return sortedSpikes.map { SpikeCluster(primary: $0, contributors: [$0]) }
        }

        var clusters: [SpikeCluster] = []
        var current: [JournalSpikeReference] = []

        for spike in sortedSpikes {
            if let last = current.last,
               spike.date.timeIntervalSince(last.date) > options.mergeThreshold
            {
                clusters.append(makeCluster(from: current))
                current = []
            }
            current.append(spike)
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

    private static func makeCluster(from spikes: [JournalSpikeReference]) -> SpikeCluster {
        let primary = spikes.max {
            if $0.rarity != $1.rarity {
                return $0.rarity < $1.rarity
            }
            if $0.magnitude ?? 0 != $1.magnitude ?? 0 {
                return ($0.magnitude ?? 0) < ($1.magnitude ?? 0)
            }
            return $0.date > $1.date
        } ?? spikes[0]
        return SpikeCluster(primary: primary, contributors: spikes)
    }

    private static func component(
        cluster: SpikeCluster,
        previous: JournalSpikeReference?,
        next: JournalSpikeReference?,
        leftBoundary: Date,
        rightBoundary: Date,
        index: Int,
        parabolaA: Double,
        options: JournalWaveformOptions
    ) -> JournalTemporalComponent? {
        let spike = cluster.primary
        guard rightBoundary.timeIntervalSince(leftBoundary) > 1 else { return nil }

        return JournalTemporalComponent(
            id: "\(spike.id)-temporal-\(index)",
            sourceSpikeID: spike.id,
            contributorSpikes: cluster.contributors,
            spike: spike,
            previousSpike: previous,
            nextSpike: next,
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
            parabolaA: parabolaA,
            ascentAccelerates: ascentAccelerates(spike: spike, fallbackSeed: spike.saros + index),
            descentAccelerates: descentAccelerates(spike: spike, fallbackSeed: spike.saros + index)
        )
    }

    static func peakHeight(
        for spike: JournalSpikeReference,
        normalizedAmplitude: Bool = JournalWaveformOptions.current.normalizedAmplitude,
        amplitudeMultiplier: Double = JournalWaveformOptions.current.amplitudeMultiplier
    ) -> Double {
        (normalizedAmplitude ? 1 : basePeakHeight(for: spike.rarity))
            * baseAmplitudeMultiplier
            * amplitudeMultiplier
            * magnitudeAmplitudeMultiplier(for: spike.magnitude)
    }

    private static func ascentAccelerates(
        spike: JournalSpikeReference,
        fallbackSeed: Int
    ) -> Bool {
        if let seriesProgressesSouthToNorth = spike.seriesProgressesSouthToNorth {
            return seriesProgressesSouthToNorth
        }

        guard let gamma = spike.gamma, gamma.isFinite, gamma != 0 else {
            return fallbackSeed.isMultiple(of: 2)
        }
        return gamma > 0
    }

    private static func descentAccelerates(
        spike: JournalSpikeReference,
        fallbackSeed: Int
    ) -> Bool {
        if let isPastSeriesMidpoint = spike.isPastSeriesMidpoint {
            return isPastSeriesMidpoint
        }
        return !fallbackSeed.isMultiple(of: 2)
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

    private static func previousDistinctCluster(
        in clusters: [SpikeCluster],
        before index: Int
    ) -> SpikeCluster? {
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

    private static func nextDistinctCluster(
        in clusters: [SpikeCluster],
        after index: Int
    ) -> SpikeCluster? {
        var cursor = index + 1

        while cursor < clusters.endIndex {
            if clusters[cursor].date != clusters[index].date {
                return clusters[cursor]
            }
            cursor += 1
        }

        return nil
    }

    private static func midpoint(_ lhs: Date, _ rhs: Date) -> Date {
        lhs.addingTimeInterval(rhs.timeIntervalSince(lhs) / 2)
    }
}

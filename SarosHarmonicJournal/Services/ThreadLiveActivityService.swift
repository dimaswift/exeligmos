import Foundation
import SwiftUI
import WidgetKit
import UserNotifications

#if canImport(ActivityKit)
import ActivityKit
#endif

enum ThreadLiveActivityError: LocalizedError {
    case unavailable
    case disabled

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Live Activities are not available on this device."
        case .disabled:
            "Live Activities are disabled for Exeligmos."
        }
    }
}

enum ThreadLiveActivityService {
    private static let alarmIdentifierPrefix = "saros-journal.live-tracking."
    private static let liveWaveformPayloadSampleCount = 96
    private static let liveWaveformPayloadMarkerLimit = 10

    private static var widgetWaveformKilosarosRange: Int {
        JournalWaveformSettings.currentWidgetWaveformKilosarosRange
    }

    private static var waveformDisplayDuration: TimeInterval {
        SarosPulseCalculator.averageDuration(for: .kilo)
            * Double(widgetWaveformKilosarosRange)
    }

    static func snapshot(
        entity: TrackedEntity,
        reading: SarosClockReading,
        trackingRarity: FlipRarity = .rare
    ) -> ThreadTrackingSnapshot {
        let currentPayload = trackingPayload(for: trackingRarity, reading: reading)
            ?? trackingPayload(for: .rare, reading: reading)
            ?? flipPayload(for: reading.binCount, reading: reading)
        let nextPayload = nextTrackingPayload(
            after: currentPayload.targetBinIndex,
            trackingRarity: currentPayload.rarity,
            reading: reading
        )

        return ThreadTrackingSnapshot(
            threadID: entity.id.uuidString,
            threadTitle: entity.displayTitle,
            saros: entity.saros,
            harmonicDepth: reading.harmonicDepth,
            eventName: currentPayload.rarity.title,
            energyPercent: nil,
            momentum: nil,
            waveDirectionRawValue: nil,
            waveformSamples: nil,
            waveformSamplePositions: nil,
            waveformSpikeMarkers: nil,
            waveformStartDate: nil,
            waveformEndDate: nil,
            widgetRangeKilosaros: widgetWaveformKilosarosRange,
            glyph: currentPayload.glyph,
            rarityRawValue: currentPayload.rarity.rawValue,
            rarityTitle: currentPayload.rarity.title,
            rarityOrderLabel: currentPayload.orderLabel,
            raritySymbolName: currentPayload.rarity.symbolName,
            rarityColorHex: trackingPrimaryColorHex(for: currentPayload.rarity),
            raritySecondaryColorHex: trackingSecondaryColorHex(for: currentPayload.rarity),
            flipDate: currentPayload.flipDate,
            createdAt: Date(),
            nextGlyph: nextPayload?.glyph,
            nextRarityRawValue: nextPayload?.rarity.rawValue,
            nextRarityTitle: nextPayload?.rarity.title,
            nextRarityOrderLabel: nextPayload?.orderLabel,
            nextRaritySymbolName: nextPayload?.rarity.symbolName,
            nextRarityColorHex: nextPayload.map { trackingPrimaryColorHex(for: $0.rarity) },
            nextRaritySecondaryColorHex: nextPayload.map { trackingSecondaryColorHex(for: $0.rarity) },
            nextFlipDate: nextPayload?.flipDate,
            pulseSaros: nil,
            pulseCycleStartDate: nil,
            pulseCycleEndDate: nil,
            moonSynodicStartDate: nil,
            moonSynodicEndDate: nil,
            moonAnomalisticStartDate: nil,
            moonAnomalisticEndDate: nil,
            moonDraconicStartDate: nil,
            moonDraconicEndDate: nil
        )
    }

    static func journalSnapshot(
        contextService: SarosEventContextService,
        eclipseService: any EclipseService,
        moonService: any MoonPhaseService,
        date: Date = Date(),
        harmonicDepth rawHarmonicDepth: Int
    ) throws -> ThreadTrackingSnapshot {
        let harmonicDepth = JournalSettings.clampedHarmonicDepth(rawHarmonicDepth)
        let pulseBounds = livePulseBounds(
            at: date,
            eclipseService: eclipseService
        )
        let waveformInterval = liveWaveformInterval(at: date, pulseBounds: pulseBounds)
        let context = try contextService.context(for: date, harmonicDepth: harmonicDepth)
        let waveformSpikes = try contextService.waveformSpikes(
            around: date,
            harmonicDepth: harmonicDepth,
            displayDuration: waveformInterval.duration,
            paddingDuration: 172_800
        )
        let upcomingSpike = nextSpike(after: date, in: waveformSpikes)
            ?? context.spikes.filter { $0.date > date }.min { $0.date < $1.date }
            ?? context.closestSpike
        let followingSpike = upcomingSpike.flatMap { nextSpike(after: $0.date.addingTimeInterval(0.5), in: waveformSpikes) }
        let rarity = upcomingSpike?.rarity ?? context.rarity
        let eventName = upcomingSpike.map { "\($0.saros) \($0.rarity.title)" }
            ?? (context.rarity == .common ? "Common" : context.rarity.title)
        let phaseGlyph = context.closestSarosPhase?.octalAddress
            ?? context.closestSpike?.octalAddress
            ?? upcomingSpike?.octalAddress
            ?? String(repeating: "0", count: harmonicDepth)
        let metrics = journalMetrics(
            at: date,
            spikes: waveformSpikes,
            interval: waveformInterval
        )
        let moonBounds = liveMoonBounds(at: date, moonService: moonService)

        return ThreadTrackingSnapshot(
            threadID: ThreadTrackingSharedStore.journalTrackingID,
            threadTitle: "Live tracking",
            saros: upcomingSpike?.saros ?? context.closestSpike?.saros ?? 0,
            harmonicDepth: harmonicDepth,
            eventName: eventName,
            energyPercent: metrics.energyPercent,
            momentum: metrics.momentum,
            waveDirectionRawValue: metrics.waveDirectionRawValue,
            waveformSamples: metrics.waveformSamples,
            waveformSamplePositions: metrics.waveformSamplePositions,
            waveformSpikeMarkers: metrics.spikeMarkers,
            waveformStartDate: metrics.waveformStartDate,
            waveformEndDate: metrics.waveformEndDate,
            widgetRangeKilosaros: widgetWaveformKilosarosRange,
            glyph: phaseGlyph,
            rarityRawValue: rarity.rawValue,
            rarityTitle: rarity.title,
            rarityOrderLabel: rarity.patternLabel(harmonicDepth: harmonicDepth),
            raritySymbolName: rarity.symbolName,
            rarityColorHex: trackingPrimaryColorHex(for: rarity),
            raritySecondaryColorHex: trackingSecondaryColorHex(for: rarity),
            flipDate: upcomingSpike?.date ?? date,
            createdAt: Date(),
            nextGlyph: followingSpike?.octalAddress,
            nextRarityRawValue: followingSpike?.rarity.rawValue,
            nextRarityTitle: followingSpike?.rarity.title,
            nextRarityOrderLabel: followingSpike?.rarity.patternLabel(harmonicDepth: harmonicDepth),
            nextRaritySymbolName: followingSpike?.rarity.symbolName,
            nextRarityColorHex: followingSpike.map { trackingPrimaryColorHex(for: $0.rarity) },
            nextRaritySecondaryColorHex: followingSpike.map { trackingSecondaryColorHex(for: $0.rarity) },
            nextFlipDate: followingSpike?.date,
            pulseSaros: pulseBounds?.saros,
            pulseCycleStartDate: pulseBounds?.startDate,
            pulseCycleEndDate: pulseBounds?.endDate,
            moonSynodicStartDate: moonBounds?.synodic.startDate,
            moonSynodicEndDate: moonBounds?.synodic.endDate,
            moonAnomalisticStartDate: moonBounds?.anomalistic.startDate,
            moonAnomalisticEndDate: moonBounds?.anomalistic.endDate,
            moonDraconicStartDate: moonBounds?.draconic.startDate,
            moonDraconicEndDate: moonBounds?.draconic.endDate
        )
    }

    @MainActor
    static func start(snapshot: ThreadTrackingSnapshot) async throws {
        ThreadTrackingSharedStore.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: ThreadTrackingSharedStore.widgetKind)
        await scheduleFlipAlarm(for: snapshot)

        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw ThreadLiveActivityError.disabled
        }

        let attributes = ThreadTrackingAttributes(
            threadID: snapshot.threadID,
            threadTitle: snapshot.threadTitle,
            saros: snapshot.saros,
            harmonicDepth: snapshot.harmonicDepth
        )
        let state = ThreadTrackingAttributes.ContentState(
            saros: snapshot.saros,
            eventName: snapshot.eventName,
            energyPercent: snapshot.energyPercent,
            momentum: snapshot.momentum,
            waveDirectionRawValue: snapshot.waveDirectionRawValue,
            waveformSamples: snapshot.waveformSamples,
            waveformSamplePositions: snapshot.waveformSamplePositions,
            waveformSpikeMarkers: snapshot.waveformSpikeMarkers,
            waveformStartDate: snapshot.waveformStartDate,
            waveformEndDate: snapshot.waveformEndDate,
            widgetRangeKilosaros: snapshot.widgetRangeKilosaros,
            glyph: snapshot.glyph,
            rarityRawValue: snapshot.rarityRawValue,
            rarityTitle: snapshot.rarityTitle,
            rarityOrderLabel: snapshot.rarityOrderLabel,
            raritySymbolName: snapshot.raritySymbolName,
            rarityColorHex: snapshot.rarityColorHex,
            raritySecondaryColorHex: snapshot.raritySecondaryColorHex,
            flipDate: snapshot.flipDate,
            updatedAt: Date(),
            nextGlyph: snapshot.nextGlyph,
            nextRarityRawValue: snapshot.nextRarityRawValue,
            nextRarityTitle: snapshot.nextRarityTitle,
            nextRarityOrderLabel: snapshot.nextRarityOrderLabel,
            nextRaritySymbolName: snapshot.nextRaritySymbolName,
            nextRarityColorHex: snapshot.nextRarityColorHex,
            nextRaritySecondaryColorHex: snapshot.nextRaritySecondaryColorHex,
            nextFlipDate: snapshot.nextFlipDate,
            pulseSaros: snapshot.pulseSaros,
            pulseCycleStartDate: snapshot.pulseCycleStartDate,
            pulseCycleEndDate: snapshot.pulseCycleEndDate,
            moonSynodicStartDate: snapshot.moonSynodicStartDate,
            moonSynodicEndDate: snapshot.moonSynodicEndDate,
            moonAnomalisticStartDate: snapshot.moonAnomalisticStartDate,
            moonAnomalisticEndDate: snapshot.moonAnomalisticEndDate,
            moonDraconicStartDate: snapshot.moonDraconicStartDate,
            moonDraconicEndDate: snapshot.moonDraconicEndDate
        )
        let content = ActivityContent(
            state: state,
            staleDate: liveActivityStaleDate(for: snapshot, after: Date())
        )

        for activity in Activity<ThreadTrackingAttributes>.activities where activity.attributes.threadID != snapshot.threadID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        if let existing = Activity<ThreadTrackingAttributes>.activities.first(where: { $0.attributes.threadID == snapshot.threadID }) {
            await existing.update(content)
        } else {
            _ = try Activity<ThreadTrackingAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        }
        #else
        throw ThreadLiveActivityError.unavailable
        #endif
    }

    private static func liveActivityStaleDate(for snapshot: ThreadTrackingSnapshot, after date: Date) -> Date {
        if let pulseCycleStartDate = snapshot.pulseCycleStartDate,
           let pulseCycleEndDate = snapshot.pulseCycleEndDate,
           pulseCycleEndDate > pulseCycleStartDate {
            let cycleDuration = pulseCycleEndDate.timeIntervalSince(pulseCycleStartDate)
            let megaDuration = cycleDuration / 512
            let miliDuration = max(megaDuration / 512, 1)
            let elapsed = max(date.timeIntervalSince(pulseCycleStartDate), 0)
            let nextIndex = floor(elapsed / miliDuration) + 1
            return pulseCycleStartDate.addingTimeInterval(nextIndex * miliDuration)
        }

        return date.addingTimeInterval(33)
    }

    private static func flipPayload(
        for targetBinIndex: Int,
        reading: SarosClockReading
    ) -> (targetBinIndex: Int, glyph: String, rarity: FlipRarity, orderLabel: String, flipDate: Date) {
        let glyph = reading.octalAddress(forBinIndex: targetBinIndex)
        let rarity = reading.flipRarity(forBinIndex: targetBinIndex)
        return (
            targetBinIndex: targetBinIndex,
            glyph: glyph,
            rarity: rarity,
            orderLabel: rarity.patternLabel(harmonicDepth: reading.harmonicDepth),
            flipDate: reading.date(forBinIndex: targetBinIndex)
        )
    }

    private static func trackingPayload(
        for rarity: FlipRarity,
        reading: SarosClockReading
    ) -> (targetBinIndex: Int, glyph: String, rarity: FlipRarity, orderLabel: String, flipDate: Date)? {
        guard let countdown = reading.countdown(rarity: rarity, now: Date()) else { return nil }
        return flipPayload(for: countdown.targetBinIndex, reading: reading)
    }

    private static func nextTrackingPayload(
        after targetBinIndex: Int,
        trackingRarity rarity: FlipRarity,
        reading: SarosClockReading
    ) -> (targetBinIndex: Int, glyph: String, rarity: FlipRarity, orderLabel: String, flipDate: Date)? {
        guard let nextBinIndex = reading.nextQualifiedFlipBin(after: targetBinIndex, rarity: rarity, exact: true)
        else {
            return nil
        }
        return flipPayload(for: nextBinIndex, reading: reading)
    }

    private static func trackingPrimaryColorHex(for rarity: FlipRarity) -> String {
        rarity.primaryColor.hexRGBString
    }

    private static func trackingSecondaryColorHex(for rarity: FlipRarity) -> String {
        rarity.secondaryColor.hexRGBString
    }

    private struct LiveCycleBounds {
        let startDate: Date
        let endDate: Date
    }

    private struct LivePulseBounds {
        let saros: Int
        let startDate: Date
        let endDate: Date
    }

    private struct LiveMoonBounds {
        let synodic: LiveCycleBounds
        let anomalistic: LiveCycleBounds
        let draconic: LiveCycleBounds
    }

    private static func livePulseBounds(
        at date: Date,
        eclipseService: any EclipseService
    ) -> LivePulseBounds? {
        let configuredSaros = UserDefaults.standard.integer(forKey: JournalSettings.pulseSarosKey)
        let saros: Int?
        if configuredSaros > 0 {
            saros = configuredSaros
        } else {
            saros = try? SarosPulseCalculator.defaultActiveSaros(
                at: date,
                eclipseService: eclipseService
            )
        }

        guard let saros,
              let interval = try? eclipseService.previousAndNextEclipse(saros: saros, around: date)
        else {
            return nil
        }

        return LivePulseBounds(
            saros: saros,
            startDate: interval.previous.date,
            endDate: interval.next.date
        )
    }

    private static func liveWaveformInterval(
        at date: Date,
        pulseBounds: LivePulseBounds?
    ) -> DateInterval {
        guard let pulseBounds,
              pulseBounds.endDate > pulseBounds.startDate
        else {
            return JournalEventWaveform.displayInterval(
                centeredOn: date,
                duration: waveformDisplayDuration
            )
        }

        let cycleDuration = pulseBounds.endDate.timeIntervalSince(pulseBounds.startDate)
        let kiloDuration = cycleDuration / pow(8, 6)
        guard kiloDuration > 0 else {
            return JournalEventWaveform.displayInterval(
                centeredOn: date,
                duration: waveformDisplayDuration
            )
        }

        let range = widgetWaveformKilosarosRange
        let windowDuration = kiloDuration * Double(range)
        let elapsed = date.timeIntervalSince(pulseBounds.startDate)
        let kiloIndex = floor(elapsed / kiloDuration)
        let windowIndex = floor(kiloIndex / Double(range))
        let start = pulseBounds.startDate.addingTimeInterval(windowIndex * windowDuration)
        return DateInterval(start: start, duration: windowDuration)
    }

    private static func liveMoonBounds(
        at date: Date,
        moonService: any MoonPhaseService
    ) -> LiveMoonBounds? {
        guard let reading = try? moonService.reading(for: date) else { return nil }
        return LiveMoonBounds(
            synodic: LiveCycleBounds(
                startDate: reading.synodicCycle.previousEvent.date,
                endDate: reading.synodicCycle.nextEvent.date
            ),
            anomalistic: LiveCycleBounds(
                startDate: reading.anomalisticCycle.previousEvent.date,
                endDate: reading.anomalisticCycle.nextEvent.date
            ),
            draconic: LiveCycleBounds(
                startDate: reading.draconicCycle.previousEvent.date,
                endDate: reading.draconicCycle.nextEvent.date
            )
        )
    }

    private static func scheduleFlipAlarm(for snapshot: ThreadTrackingSnapshot) async {
        let notifyDate = snapshot.flipDate.addingTimeInterval(-SarosPulseCalculator.averageDuration(for: .mili))
        guard notifyDate > Date(),
              await NotificationScheduler.shared.requestAuthorization()
        else {
            return
        }

        let center = UNUserNotificationCenter.current()
        let threadPrefix = "\(alarmIdentifierPrefix)\(snapshot.threadID)."
        let pending = await pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending
                .map(\.identifier)
                .filter { $0.hasPrefix(threadPrefix) }
        )

        let content = UNMutableNotificationContent()
        content.title = "Approaching \(snapshot.eventName ?? snapshot.rarityTitle) peak"
        content.subtitle = "T-minus 1 milisaros"
        let energy = snapshot.energyPercent.map { "Energy \(JournalWaveEventDescriptorFormatter.energyText($0).replacingOccurrences(of: "E ", with: ""))" }
        let momentum = snapshot.momentum.map { value in
            "Momentum \(JournalWaveEventDescriptorFormatter.momentumText(value).replacingOccurrences(of: "M ", with: ""))"
        }
        content.body = [energy, momentum]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfBlank ?? "Tap to record."
        content.sound = UNNotificationSound(named: UNNotificationSoundName("LiveTrackingFlip.wav"))
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "live-tracking-\(snapshot.threadID)"
        content.relevanceScore = min(Double(snapshot.harmonicDepth) / 7.0, 1.0)
        content.userInfo = [
            "entityID": snapshot.threadID,
            "trigger": "liveTrackingFlip",
            "flipDate": snapshot.flipDate.timeIntervalSince1970,
            "saros": snapshot.saros,
            "octalAddress": snapshot.glyph,
            "rarity": snapshot.rarityRawValue
        ]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: notifyDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let identifier = "\(threadPrefix)\(Int(snapshot.flipDate.timeIntervalSince1970))"
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    private static func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }

    private static func nextSpike(
        after date: Date,
        in spikes: [JournalSpikeReference]
    ) -> JournalSpikeReference? {
        let futureSpikes = spikes.filter { $0.date > date }
        guard let nextDate = futureSpikes.map(\.date).min() else { return nil }
        return futureSpikes
            .filter { abs($0.date.timeIntervalSince(nextDate)) < 0.5 }
            .max { $0.rarity < $1.rarity }
    }

    private static func journalMetrics(
        at date: Date,
        spikes: [JournalSpikeReference],
        interval: DateInterval? = nil
    ) -> (
        energyPercent: Double,
        momentum: Double,
        waveDirectionRawValue: String,
        waveformSamples: [Double],
        waveformSamplePositions: [Double],
        spikeMarkers: [TrackingWaveformSpikeMarker],
        waveformStartDate: Date,
        waveformEndDate: Date
    ) {
        let interval = interval ?? JournalEventWaveform.displayInterval(
            centeredOn: date,
            duration: waveformDisplayDuration
        )
        let field = JournalEventWaveform.field(spikes: spikes)
        let metrics = JournalWaveMetricsCalculator.metrics(at: date, spikes: spikes)
        let samples = field.samples(in: interval, sampleCount: liveWaveformPayloadSampleCount, spikes: spikes)
        let payloadPoints = compactWaveformPoints(samples.points, maxCount: liveWaveformPayloadSampleCount)
        let maxEnergy = max(
            metrics.energyPercent > 0 ? metrics.energy / metrics.energyPercent : 0,
            metrics.energy,
            field.maxPeakHeight,
            0.000_000_001
        )
        let normalizedSamples = payloadPoints.map { point in
            min(max(point.energy / maxEnergy, 0), 1)
        }
        let samplePositions = payloadPoints.map { point in
            (point.position * 10_000).rounded() / 10_000
        }
        let visibleSpikes = JournalEventWaveform.visibleSpikes(in: interval, spikes: spikes)
        let spikeMarkers = visibleSpikes
            .sorted {
                if $0.rarity != $1.rarity {
                    return $0.rarity > $1.rarity
                }
                return abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            }
            .prefix(liveWaveformPayloadMarkerLimit)
            .map { spike in
            TrackingWaveformSpikeMarker(
                position: (min(max(spike.date.timeIntervalSince(interval.start) / interval.duration, 0), 1) * 10_000).rounded() / 10_000,
                energy: (min(max((samples.eventEnergyByID[spike.id] ?? field.energy(at: spike.date)) / maxEnergy, 0), 1) * 10_000).rounded() / 10_000,
                colorHex: trackingPrimaryColorHex(for: spike.rarity)
            )
        }
        return (
            energyPercent: metrics.energyPercent,
            momentum: metrics.momentum,
            waveDirectionRawValue: metrics.direction.rawValue,
            waveformSamples: normalizedSamples,
            waveformSamplePositions: samplePositions,
            spikeMarkers: spikeMarkers,
            waveformStartDate: interval.start,
            waveformEndDate: interval.end
        )
    }

    private static func compactWaveformPoints(
        _ points: [JournalEventWaveSample],
        maxCount: Int
    ) -> [JournalEventWaveSample] {
        guard points.count > maxCount, maxCount > 1 else { return points }
        let sorted = points.sorted { $0.position < $1.position }
        let interval = sorted.first.map { DateInterval(start: $0.date, end: sorted.last?.date ?? $0.date) }
            ?? DateInterval(start: Date(), duration: 1)

        return (0..<maxCount).map { index in
            let position = Double(index) / Double(maxCount - 1)
            let energy = interpolatedEnergy(in: sorted, at: position)
            let date = interval.start.addingTimeInterval(interval.duration * position)
            return JournalEventWaveSample(date: date, position: position, energy: energy)
        }
    }

    private static func interpolatedEnergy(
        in points: [JournalEventWaveSample],
        at position: Double
    ) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        let clamped = min(max(position, first.position), last.position)
        if clamped <= first.position { return first.energy }

        for index in 0..<(points.count - 1) {
            let left = points[index]
            let right = points[index + 1]
            guard clamped <= right.position || index == points.count - 2 else { continue }
            let fraction = (clamped - left.position) / max(right.position - left.position, 0.000_001)
            return left.energy + (right.energy - left.energy) * min(max(fraction, 0), 1)
        }

        return last.energy
    }
}

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
            waveformSpikeMarkers: nil,
            waveformStartDate: nil,
            waveformEndDate: nil,
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
            nextFlipDate: nextPayload?.flipDate
        )
    }

    static func journalSnapshot(
        contextService: SarosEventContextService,
        date: Date = Date(),
        harmonicDepth rawHarmonicDepth: Int
    ) throws -> ThreadTrackingSnapshot {
        let harmonicDepth = JournalSettings.clampedHarmonicDepth(rawHarmonicDepth)
        let context = try contextService.context(for: date, harmonicDepth: harmonicDepth)
        let waveformSpikes = try contextService.waveformSpikes(
            around: date,
            harmonicDepth: harmonicDepth,
            displayDuration: JournalEventWaveform.defaultDisplayDuration,
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
        let metrics = journalMetrics(at: date, spikes: waveformSpikes)

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
            waveformSpikeMarkers: metrics.spikeMarkers,
            waveformStartDate: metrics.waveformStartDate,
            waveformEndDate: metrics.waveformEndDate,
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
            nextFlipDate: followingSpike?.date
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
            waveformSpikeMarkers: snapshot.waveformSpikeMarkers,
            waveformStartDate: snapshot.waveformStartDate,
            waveformEndDate: snapshot.waveformEndDate,
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
            nextFlipDate: snapshot.nextFlipDate
        )
        let content = ActivityContent(
            state: state,
            staleDate: snapshot.waveformEndDate ?? snapshot.flipDate.addingTimeInterval(5 * 60)
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

    private static func scheduleFlipAlarm(for snapshot: ThreadTrackingSnapshot) async {
        guard snapshot.flipDate > Date(),
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
        content.title = snapshot.eventName ?? "\(snapshot.rarityTitle): \(snapshot.threadTitle)"
        content.subtitle = "Peak reached"
        let energy = snapshot.energyPercent.map { "Energy \(Int((min(max($0, 0), 1) * 100).rounded()))%" }
        let momentum = snapshot.momentum.map { value in
            let percent = Int((min(max(value, -1), 1) * 100).rounded())
            return percent > 0 ? "Momentum +\(percent)%" : "Momentum \(percent)%"
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
            from: snapshot.flipDate
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
        spikes: [JournalSpikeReference]
    ) -> (
        energyPercent: Double,
        momentum: Double,
        waveDirectionRawValue: String,
        waveformSamples: [Double],
        spikeMarkers: [TrackingWaveformSpikeMarker],
        waveformStartDate: Date,
        waveformEndDate: Date
    ) {
        let interval = JournalEventWaveform.displayInterval(centeredOn: date)
        let field = JournalEventWaveform.field(spikes: spikes)
        let samples = field.samples(in: interval, sampleCount: 42, spikes: spikes)
        let currentEnergy = field.energy(at: date)
        let visibleMaxEnergy = samples.points.map(\.energy).max() ?? 0
        let maxEnergy = max(visibleMaxEnergy, currentEnergy, 0.000_000_001)
        let normalizedSamples = samples.points.map { point in
            min(max(point.energy / maxEnergy, 0), 1)
        }
        let visibleSpikes = JournalEventWaveform.visibleSpikes(in: interval, spikes: spikes)
        let spikeMarkers = visibleSpikes.map { spike in
            TrackingWaveformSpikeMarker(
                position: min(max(spike.date.timeIntervalSince(interval.start) / interval.duration, 0), 1),
                energy: min(max((samples.eventEnergyByID[spike.id] ?? field.energy(at: spike.date)) / maxEnergy, 0), 1),
                colorHex: trackingPrimaryColorHex(for: spike.rarity)
            )
        }
        let energyPercent = min(max(currentEnergy / maxEnergy, 0), 1)
        let dynamics = JournalWaveMetricsCalculator.dynamics(at: date, spikes: spikes)
        return (
            energyPercent: energyPercent,
            momentum: dynamics.momentum,
            waveDirectionRawValue: dynamics.direction.rawValue,
            waveformSamples: normalizedSamples,
            spikeMarkers: spikeMarkers,
            waveformStartDate: interval.start,
            waveformEndDate: interval.end
        )
    }
}

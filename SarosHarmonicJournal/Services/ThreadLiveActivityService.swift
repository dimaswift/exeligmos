import Foundation
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
    private static let minimumTrackingOrder = 2

    static func snapshot(entity: TrackedEntity, reading: SarosClockReading) -> ThreadTrackingSnapshot {
        let currentTargetBinIndex = nextTrackedFlipBin(after: reading.binIndex, reading: reading) ?? reading.binCount
        let currentPayload = flipPayload(for: currentTargetBinIndex, reading: reading)
        let nextPayload = nextTrackedFlipBin(after: currentTargetBinIndex, reading: reading)
            .map { flipPayload(for: $0, reading: reading) }

        return ThreadTrackingSnapshot(
            threadID: entity.id.uuidString,
            threadTitle: entity.displayTitle,
            saros: entity.saros,
            harmonicDepth: reading.harmonicDepth,
            glyph: currentPayload.glyph,
            rarityRawValue: currentPayload.rarity.rawValue,
            rarityTitle: currentPayload.rarity.title,
            rarityOrderLabel: currentPayload.orderLabel,
            raritySymbolName: currentPayload.rarity.symbolName,
            rarityColorHex: trackingColorHex(for: currentPayload.rarity),
            flipDate: currentPayload.flipDate,
            createdAt: Date(),
            nextGlyph: nextPayload?.glyph,
            nextRarityRawValue: nextPayload?.rarity.rawValue,
            nextRarityTitle: nextPayload?.rarity.title,
            nextRarityOrderLabel: nextPayload?.orderLabel,
            nextRaritySymbolName: nextPayload?.rarity.symbolName,
            nextRarityColorHex: nextPayload.map { trackingColorHex(for: $0.rarity) },
            nextFlipDate: nextPayload?.flipDate
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
            glyph: snapshot.glyph,
            rarityRawValue: snapshot.rarityRawValue,
            rarityTitle: snapshot.rarityTitle,
            rarityOrderLabel: snapshot.rarityOrderLabel,
            raritySymbolName: snapshot.raritySymbolName,
            rarityColorHex: snapshot.rarityColorHex,
            flipDate: snapshot.flipDate,
            updatedAt: Date(),
            nextGlyph: snapshot.nextGlyph,
            nextRarityRawValue: snapshot.nextRarityRawValue,
            nextRarityTitle: snapshot.nextRarityTitle,
            nextRarityOrderLabel: snapshot.nextRarityOrderLabel,
            nextRaritySymbolName: snapshot.nextRaritySymbolName,
            nextRarityColorHex: snapshot.nextRarityColorHex,
            nextFlipDate: snapshot.nextFlipDate
        )
        let content = ActivityContent(
            state: state,
            staleDate: snapshot.flipDate.addingTimeInterval(5 * 60)
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
    ) -> (glyph: String, rarity: FlipRarity, orderLabel: String, flipDate: Date) {
        let glyph = reading.octalAddress(forBinIndex: targetBinIndex)
        let rarity = reading.flipRarity(forBinIndex: targetBinIndex)
        let order = targetBinIndex >= reading.binCount
            ? max(7, reading.harmonicDepth)
            : max(1, FlipRarity.order(forOctalAddress: glyph, harmonicDepth: reading.harmonicDepth))
        return (
            glyph: glyph,
            rarity: rarity,
            orderLabel: rarity == .saros ? "Order 7+" : "Order \(order)",
            flipDate: reading.date(forBinIndex: targetBinIndex)
        )
    }

    private static func trackingColorHex(for rarity: FlipRarity) -> String {
        switch rarity {
        case .common: "#8E8E93"
        case .rare: "#3D9BFF"
        case .epic: "#BF5AF2"
        case .legendary: "#FFD60A"
        case .mythic: "#FF453A"
        case .saros: "#32D74B"
        }
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
        content.title = "\(snapshot.rarityTitle): \(snapshot.threadTitle)"
        content.subtitle = snapshot.rarityOrderLabel
        content.body = "Flip reached. Tap to record."
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

    private static func nextTrackedFlipBin(after binIndex: Int, reading: SarosClockReading) -> Int? {
        reading.nextQualifiedFlipBin(
            after: binIndex,
            order: minimumTrackingOrder,
            exact: false
        )
    }

    private static func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }
}

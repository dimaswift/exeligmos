import Foundation
import SwiftUI
import UIKit
import UserNotifications

final class NotificationScheduler {
    static let shared = NotificationScheduler()

    private let identifierPrefix = "saros-journal."

    private init() {}

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func refreshSchedules(
        for entities: [TrackedEntity],
        clockService: any SarosClockService,
        harmonicDepth: Int,
        resonanceWindow: TimeInterval = 60 * 60
    ) async {
        guard await requestAuthorization() else { return }

        let center = UNUserNotificationCenter.current()
        let pending = await pendingRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        )

        let now = Date()
        var flips: [EntityFlip] = []
        let depth = JournalSettings.clampedHarmonicDepth(harmonicDepth)
        let preferences = FlipNotificationPreferences.load(for: depth)
        let preferencesByTier = Dictionary(uniqueKeysWithValues: preferences.map { ($0.tier, $0) })

        for entity in entities where entity.notificationsEnabled {
            guard let reading = try? clockService.reading(
                saros: entity.saros,
                date: now,
                harmonicDepth: depth
            ) else {
                continue
            }

            let nextIndex = min(reading.binIndex + 1, reading.binCount - 1)
            let nextAddress = String(nextIndex, radix: 8)
                .leftPadded(toLength: depth, withPad: "0")
            let tier = FlipNotificationPreferences.tier(
                forOctalAddress: nextAddress,
                harmonicDepth: depth
            )

            flips.append(
                EntityFlip(
                    entityID: entity.id,
                    entityTitle: entity.displayTitle,
                    date: reading.nextFlipDate,
                    saros: entity.saros,
                    octalAddress: nextAddress
                )
            )

            let preference = preferencesByTier[tier] ?? FlipNotificationPreferences.defaults(for: depth)[max(tier - 1, 0)]
            guard preference.mode != .silent else { continue }

            let notifyDate = notifyDate(
                for: preference,
                flipDate: reading.nextFlipDate,
                now: now
            )
            guard notifyDate > now else { continue }

            await scheduleBinFlipNotification(
                entity: entity,
                octalAddress: nextAddress,
                tier: tier,
                mode: preference.mode,
                notifyDate: notifyDate,
                flipDate: reading.nextFlipDate,
                timeUntilFlip: reading.nextFlipDate.timeIntervalSince(notifyDate),
                harmonicDepth: depth
            )
        }

        let resonances = ResonanceDetector.detectResonances(flips: flips, window: resonanceWindow)
        for event in resonances.prefix(12) where event.startDate > now {
            await scheduleResonanceNotification(event: event)
        }
    }

    private func notifyDate(
        for preference: FlipNotificationTierPreference,
        flipDate: Date,
        now: Date
    ) -> Date {
        switch preference.mode {
        case .silent:
            return flipDate
        case .event:
            return flipDate
        case .live, .alarm:
            let requested = flipDate.addingTimeInterval(TimeInterval(-preference.advanceMinutes * 60))
            if requested <= now, flipDate > now {
                return now.addingTimeInterval(5)
            }
            return requested
        }
    }

    private func pendingRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }

    private func scheduleBinFlipNotification(
        entity: TrackedEntity,
        octalAddress: String,
        tier: Int,
        mode: FlipNotificationMode,
        notifyDate: Date,
        flipDate: Date,
        timeUntilFlip: TimeInterval,
        harmonicDepth: Int
    ) async {
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(
            entity: entity,
            mode: mode,
            timeUntilFlip: timeUntilFlip
        )
        content.subtitle = "Saros \(entity.saros) · \(octalAddress)"
        content.body = "Tier \(tier) flip to \(octalAddress) at \(JournalFormatters.dateTime.string(from: flipDate))."
        content.sound = notificationSound(for: mode)
        content.interruptionLevel = interruptionLevel(for: mode)
        content.userInfo = [
            "entityID": entity.id.uuidString,
            "trigger": JournalTriggerType.binFlip.rawValue,
            "flipDate": flipDate.timeIntervalSince1970,
            "saros": entity.saros,
            "octalAddress": octalAddress,
            "tier": tier,
            "mode": mode.rawValue
        ]
        if let attachment = await glyphAttachment(octalAddress: octalAddress, harmonicDepth: harmonicDepth) {
            content.attachments = [attachment]
        }

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notifyDate),
            repeats: false
        )
        let identifier = "\(identifierPrefix)bin.\(entity.id.uuidString).\(Int(flipDate.timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func notificationTitle(
        entity: TrackedEntity,
        mode: FlipNotificationMode,
        timeUntilFlip: TimeInterval
    ) -> String {
        switch mode {
        case .silent:
            entity.displayTitle
        case .event:
            "\(entity.displayTitle) flipped"
        case .live:
            "\(entity.displayTitle) flips in \(timeUntilFlip.compactDuration)"
        case .alarm:
            "Flip alarm: \(entity.displayTitle)"
        }
    }

    private func notificationSound(for mode: FlipNotificationMode) -> UNNotificationSound? {
        switch mode {
        case .silent, .live:
            nil
        case .event, .alarm:
            .default
        }
    }

    private func interruptionLevel(for mode: FlipNotificationMode) -> UNNotificationInterruptionLevel {
        switch mode {
        case .silent, .event:
            .active
        case .live, .alarm:
            .timeSensitive
        }
    }

    @MainActor
    private func glyphAttachment(octalAddress: String, harmonicDepth: Int) -> UNNotificationAttachment? {
        let renderer = ImageRenderer(
            content: OctalGlyph(value: octalAddress, depth: harmonicDepth)
                .frame(width: 180, height: 180)
                .padding(18)
                .background(Color(.systemBackground))
        )
        renderer.scale = UIScreen.main.scale

        guard let image = renderer.uiImage, let data = image.pngData() else {
            return nil
        }

        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SarosNotificationGlyphs", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(octalAddress)-\(harmonicDepth).png")
            try data.write(to: url, options: .atomic)
            return try UNNotificationAttachment(identifier: "glyph", url: url)
        } catch {
            return nil
        }
    }

    private func scheduleResonanceNotification(event: ResonanceEvent) async {
        let content = UNMutableNotificationContent()
        content.title = "Resonance window opening"
        content.body = "\(event.entityIDs.count) Saros threads flip close together. Record the overlap."
        content.sound = .default
        content.userInfo = [
            "trigger": JournalTriggerType.resonance.rawValue,
            "resonanceID": event.id.uuidString
        ]

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: event.startDate),
            repeats: false
        )
        let identifier = "\(identifierPrefix)resonance.\(event.id.uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

import Foundation
import SwiftUI
import UIKit
import UserNotifications

final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationScheduler()

    private let identifierPrefix = "saros-journal."

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo
        guard userInfo["trigger"] as? String == "liveTrackingFlip",
              let entityIDString = userInfo["entityID"] as? String,
              let entityID = UUID(uuidString: entityIDString) else {
            return
        }

        AppDeepLinkStore.storePendingRecordCapture(entityID: entityID)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .recordCaptureRequested, object: entityID)
        }
    }

    func refreshSchedules(
        for entities: [TrackedEntity],
        clockService: any SarosClockService,
        harmonicDepth: Int,
        customFlips: [CustomFlipEvent] = [],
        resonanceWindow: TimeInterval = 60 * 60
    ) async {
        guard await requestAuthorization() else { return }

        let center = UNUserNotificationCenter.current()
        let pending = await pendingRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        )

        let now = Date()
        let depth = JournalSettings.clampedHarmonicDepth(harmonicDepth)
        let preferences = FlipNotificationPreferences.load(for: depth)
        let defaultPreferences = FlipNotificationPreferences.defaults(for: depth)
        let preferencesByRarity = Dictionary(uniqueKeysWithValues: preferences.map { ($0.rarity, $0) })
        let entitiesByID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })

        for entity in entities where entity.notificationsEnabled {
            guard let reading = try? clockService.reading(
                saros: entity.saros,
                date: now,
                harmonicDepth: depth
            ) else {
                continue
            }

            for countdown in reading.rarityCountdowns(now: now) where countdown.rarity.notificationEligible {
                let fallback = FlipNotificationPreferences.defaults(for: depth)
                    .first { $0.rarity == countdown.rarity }
                guard let preference = preferencesByRarity[countdown.rarity] ?? fallback,
                      preference.mode != .silent,
                      countdown.flipDate > now else {
                    continue
                }

                let notifyDate = notifyDate(
                    for: preference,
                    flipDate: countdown.flipDate,
                    now: now
                )
                guard notifyDate > now else { continue }

                await scheduleBinFlipNotification(
                    entity: entity,
                    countdown: countdown,
                    mode: preference.mode,
                    notifyDate: notifyDate,
                    timeUntilFlip: countdown.flipDate.timeIntervalSince(notifyDate),
                    harmonicDepth: depth
                )
            }
        }

        let customPreference = preferencesByRarity[.saros]
            ?? defaultPreferences.first { $0.rarity == .saros }
        if let customPreference, customPreference.mode != .silent {
            for customFlip in customFlips {
                guard
                    let entity = entitiesByID[customFlip.entityID],
                    entity.notificationsEnabled,
                    customFlip.date > now
                else {
                    continue
                }

                let notifyDate = notifyDate(
                    for: customPreference,
                    flipDate: customFlip.date,
                    now: now
                )
                guard notifyDate > now else { continue }

                await scheduleCustomFlipNotification(
                    entity: entity,
                    customFlip: customFlip,
                    mode: customPreference.mode,
                    notifyDate: notifyDate,
                    timeUntilFlip: customFlip.date.timeIntervalSince(notifyDate),
                    harmonicDepth: depth
                )
            }
        }
    }

    private func notifyDate(
        for preference: FlipNotificationRarityPreference,
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
        countdown: SarosFlipCountdown,
        mode: FlipNotificationMode,
        notifyDate: Date,
        timeUntilFlip: TimeInterval,
        harmonicDepth: Int
    ) async {
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(
            entity: entity,
            rarity: countdown.rarity,
            mode: mode,
            timeUntilFlip: timeUntilFlip
        )
        content.subtitle = "Saros \(entity.saros) · \(countdown.targetOctalAddress)"
        content.body = "\(countdown.rarity.title) \(countdown.rarity.orderLabel) flip to \(countdown.targetOctalAddress) at \(JournalFormatters.dateTime.string(from: countdown.flipDate))."
        content.sound = notificationSound(for: mode)
        content.interruptionLevel = interruptionLevel(for: mode)
        content.threadIdentifier = "saros-\(entity.saros)-\(countdown.rarity.id)"
        content.relevanceScore = min(Double(countdown.rarity.order) / 7.0, 1.0)
        content.userInfo = [
            "entityID": entity.id.uuidString,
            "trigger": JournalTriggerType.binFlip.rawValue,
            "flipDate": countdown.flipDate.timeIntervalSince1970,
            "saros": entity.saros,
            "octalAddress": countdown.targetOctalAddress,
            "order": countdown.order,
            "rarity": countdown.rarity.rawValue,
            "mode": mode.rawValue
        ]
        if let attachment = await glyphAttachment(
            octalAddress: countdown.targetOctalAddress,
            harmonicDepth: harmonicDepth,
            color: countdown.rarity.color
        ) {
            content.attachments = [attachment]
        }

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notifyDate),
            repeats: false
        )
        let identifier = "\(identifierPrefix)bin.\(entity.id.uuidString).\(countdown.rarity.id).\(Int(countdown.flipDate.timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func scheduleCustomFlipNotification(
        entity: TrackedEntity,
        customFlip: CustomFlipEvent,
        mode: FlipNotificationMode,
        notifyDate: Date,
        timeUntilFlip: TimeInterval,
        harmonicDepth: Int
    ) async {
        let customColor = Color(hex: customFlip.colorHex, fallback: .green)
        let content = UNMutableNotificationContent()
        content.title = customNotificationTitle(
            entity: entity,
            customFlip: customFlip,
            mode: mode,
            timeUntilFlip: timeUntilFlip
        )
        content.subtitle = "Saros \(entity.saros) · \(customFlip.octalAddress)"
        content.body = "\(customFlip.displayName) at \(JournalFormatters.dateTime.string(from: customFlip.date))."
        content.sound = notificationSound(for: mode)
        content.interruptionLevel = interruptionLevel(for: mode)
        content.threadIdentifier = "saros-\(entity.saros)-custom"
        content.relevanceScore = 1.0
        content.userInfo = [
            "entityID": entity.id.uuidString,
            "customFlipID": customFlip.id.uuidString,
            "trigger": JournalTriggerType.binFlip.rawValue,
            "flipDate": customFlip.date.timeIntervalSince1970,
            "saros": entity.saros,
            "octalAddress": customFlip.octalAddress,
            "order": 8,
            "rarity": "custom",
            "mode": mode.rawValue
        ]
        if let attachment = await glyphAttachment(
            octalAddress: customFlip.octalAddress,
            harmonicDepth: harmonicDepth,
            color: customColor
        ) {
            content.attachments = [attachment]
        }

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notifyDate),
            repeats: false
        )
        let identifier = "\(identifierPrefix)custom.\(entity.id.uuidString).\(customFlip.id.uuidString).\(Int(customFlip.date.timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func notificationTitle(
        entity: TrackedEntity,
        rarity: FlipRarity,
        mode: FlipNotificationMode,
        timeUntilFlip: TimeInterval
    ) -> String {
        switch mode {
        case .silent:
            entity.displayTitle
        case .event:
            "\(rarity.title): \(entity.displayTitle) flipped"
        case .live:
            "\(rarity.title): \(entity.displayTitle) flips in \(timeUntilFlip.compactDuration)"
        case .alarm:
            "\(rarity.title) alarm: \(entity.displayTitle)"
        }
    }

    private func customNotificationTitle(
        entity: TrackedEntity,
        customFlip: CustomFlipEvent,
        mode: FlipNotificationMode,
        timeUntilFlip: TimeInterval
    ) -> String {
        switch mode {
        case .silent:
            customFlip.displayName
        case .event:
            "\(customFlip.displayName): \(entity.displayTitle)"
        case .live:
            "\(customFlip.displayName) in \(timeUntilFlip.compactDuration)"
        case .alarm:
            "\(customFlip.displayName) alarm: \(entity.displayTitle)"
        }
    }

    private func notificationSound(for mode: FlipNotificationMode) -> UNNotificationSound? {
        switch mode {
        case .silent:
            nil
        case .event, .live, .alarm:
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
    private func glyphAttachment(octalAddress: String, harmonicDepth: Int, color: Color) -> UNNotificationAttachment? {
        let renderer = ImageRenderer(
            content: OctalGlyph(value: octalAddress, depth: harmonicDepth, color: color)
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

}

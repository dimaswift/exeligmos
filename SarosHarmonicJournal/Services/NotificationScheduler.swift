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

        let customFallbackRarity = FlipRarity.mythicDigit(7)
        let customPreference = preferencesByRarity[customFallbackRarity]
            ?? defaultPreferences.first { $0.rarity == customFallbackRarity }
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

    func refreshGlobalSarosEventSchedules(
        eclipseService: any EclipseService,
        harmonicDepth rawHarmonicDepth: Int,
        horizon: TimeInterval = 14 * 86_400,
        peakLimit: Int = 32,
        boundaryLimit: Int = 24
    ) async {
        guard await requestAuthorization() else { return }

        let center = UNUserNotificationCenter.current()
        let pending = await pendingRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        )

        let now = Date()
        let depth = JournalSettings.clampedHarmonicDepth(rawHarmonicDepth)
        let interval = DateInterval(
            start: now.addingTimeInterval(-horizon),
            end: now.addingTimeInterval(horizon)
        )

        guard
            let summaries = try? eclipseService.allSarosSeries().sorted(by: { $0.saros < $1.saros })
        else {
            return
        }

        let events = Self.globalEvents(
            in: interval,
            summaries: summaries,
            eclipseService: eclipseService,
            harmonicDepth: depth
        )
        let futureEvents = events
            .filter { $0.date > now }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                if lhs.rarity != rhs.rarity { return lhs.rarity > rhs.rarity }
                return lhs.saros < rhs.saros
            }

        for event in futureEvents.prefix(peakLimit) {
            await schedulePeakNotification(event: event, notifyDate: event.date)
        }

        let boundaryEvents = Self.distinctTimelineEvents(events)
        let boundaryCandidates = zip(boundaryEvents, boundaryEvents.dropFirst())
            .compactMap { previous, next -> SarosBoundaryNotification? in
                let boundaryDate = Date(
                    timeIntervalSince1970: (previous.date.timeIntervalSince1970 + next.date.timeIntervalSince1970) / 2
                )
                guard boundaryDate > now, boundaryDate < interval.end else { return nil }
                return SarosBoundaryNotification(previous: previous, next: next, date: boundaryDate)
            }

        for boundary in boundaryCandidates.prefix(boundaryLimit) {
            await scheduleBoundaryNotification(boundary)
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
        let displayOctalAddress = JournalSettings.rarityOctalAddress(
            countdown.targetOctalAddress,
            storedDepth: harmonicDepth,
            rarity: countdown.rarity
        )
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(
            entity: entity,
            rarity: countdown.rarity,
            mode: mode,
            timeUntilFlip: timeUntilFlip
        )
        content.subtitle = "Saros \(entity.saros) · \(displayOctalAddress)"
        content.body = "\(countdown.rarity.title) flip to \(displayOctalAddress) at \(JournalFormatters.dateTime.string(from: countdown.flipDate))."
        content.sound = notificationSound(for: mode)
        content.interruptionLevel = interruptionLevel(for: mode)
        content.threadIdentifier = "saros-\(entity.saros)-\(countdown.rarity.id)"
        content.relevanceScore = min(Double(countdown.rarity.rank) / Double(FlipRarity.mythicDigit(7).rank), 1.0)
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
            style: countdown.rarity.glyphStyle
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
            style: .single(customColor)
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

    private func schedulePeakNotification(
        event: ScheduledSarosEvent,
        notifyDate: Date
    ) async {
        let content = UNMutableNotificationContent()
        content.title = "Peak reached"
        content.subtitle = event.shortTitle
        content.body = "\(event.shortTitle) peaked at \(JournalFormatters.dateTime.string(from: event.date))."
        content.sound = .default
        content.interruptionLevel = event.rarity.baseRarity == .mythic ? .timeSensitive : .active
        content.threadIdentifier = "saros-global-peak-\(event.saros)"
        content.relevanceScore = event.relevanceScore
        content.userInfo = [
            "trigger": "sarosPeak",
            "saros": event.saros,
            "date": event.date.timeIntervalSince1970,
            "octalAddress": event.octalAddress,
            "rarity": event.rarity.rawValue
        ]

        if let attachment = await glyphAttachment(
            octalAddress: event.octalAddress,
            harmonicDepth: event.harmonicDepth,
            style: event.rarity.glyphStyle
        ) {
            content.attachments = [attachment]
        }

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notifyDate),
            repeats: false
        )
        let identifier = "\(identifierPrefix)global.peak.\(event.saros).\(Int(event.date.timeIntervalSince1970))"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
    }

    private func scheduleBoundaryNotification(_ boundary: SarosBoundaryNotification) async {
        let peakWait = max(boundary.next.date.timeIntervalSince(boundary.date), 0)
        let content = UNMutableNotificationContent()
        content.title = "Saros boundary crossed"
        content.subtitle = "Beginning ascent into \(boundary.next.shortTitle)"
        content.body = "Descent from \(boundary.previous.shortTitle) completed. Peak in \(peakWait.compactDuration)."
        content.sound = .default
        content.interruptionLevel = boundary.next.rarity.baseRarity == .mythic ? .timeSensitive : .active
        content.threadIdentifier = "saros-global-boundary"
        content.relevanceScore = boundary.next.relevanceScore
        content.userInfo = [
            "trigger": "sarosBoundary",
            "previousSaros": boundary.previous.saros,
            "nextSaros": boundary.next.saros,
            "date": boundary.date.timeIntervalSince1970,
            "nextPeakDate": boundary.next.date.timeIntervalSince1970,
            "nextOctalAddress": boundary.next.octalAddress,
            "nextRarity": boundary.next.rarity.rawValue
        ]

        if let attachment = await glyphAttachment(
            octalAddress: boundary.next.octalAddress,
            harmonicDepth: boundary.next.harmonicDepth,
            style: boundary.next.rarity.glyphStyle
        ) {
            content.attachments = [attachment]
        }

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: boundary.date),
            repeats: false
        )
        let identifier = "\(identifierPrefix)global.boundary.\(Int(boundary.previous.date.timeIntervalSince1970)).\(Int(boundary.next.date.timeIntervalSince1970))"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
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
    private func glyphAttachment(octalAddress: String, harmonicDepth: Int, style: OctalGlyphStyle) -> UNNotificationAttachment? {
        let renderer = ImageRenderer(
            content: OctalGlyph(value: octalAddress, depth: harmonicDepth, style: style)
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

private struct ScheduledSarosEvent: Hashable, Identifiable {
    let saros: Int
    let binIndex: Int
    let date: Date
    let octalAddress: String
    let harmonicDepth: Int
    let rarity: FlipRarity

    var id: String {
        "\(saros)-\(binIndex)-\(Int(date.timeIntervalSince1970))-\(rarity.id)"
    }

    var shortTitle: String {
        "Saros \(saros) \(rarity.title)"
    }

    var relevanceScore: Double {
        min(max(Double(rarity.rank) / Double(FlipRarity.mythicDigit(7).rank), 0.2), 1.0)
    }
}

private struct SarosBoundaryNotification: Hashable {
    let previous: ScheduledSarosEvent
    let next: ScheduledSarosEvent
    let date: Date
}

private extension NotificationScheduler {
    static func globalEvents(
        in interval: DateInterval,
        summaries: [SarosSeriesSummary],
        eclipseService: any EclipseService,
        harmonicDepth rawHarmonicDepth: Int
    ) -> [ScheduledSarosEvent] {
        let harmonicDepth = JournalSettings.clampedHarmonicDepth(rawHarmonicDepth)
        let start = interval.start
        let end = interval.end
        var eventsByKey: [String: ScheduledSarosEvent] = [:]

        for summary in summaries where summary.firstEclipseDate < end && summary.lastEclipseDate > start {
            for sarosInterval in candidateIntervals(
                summary: summary,
                start: start,
                end: end,
                eclipseService: eclipseService
            ) {
                guard let reading = try? SarosClockCalculator.reading(
                    saros: summary.saros,
                    previous: sarosInterval.previous,
                    next: sarosInterval.next,
                    now: max(start, sarosInterval.previous.date),
                    harmonicDepth: harmonicDepth
                ) else {
                    continue
                }

                appendBoundaryEventIfNeeded(
                    date: sarosInterval.previous.date,
                    reading: reading,
                    start: start,
                    end: end,
                    into: &eventsByKey
                )
                appendBoundaryEventIfNeeded(
                    date: sarosInterval.next.date,
                    reading: reading,
                    start: start,
                    end: end,
                    into: &eventsByKey
                )

                for rarity in FlipRarity.eventRarities(for: harmonicDepth) where rarity >= .epic {
                    var bin = reading.nextQualifiedFlipBin(
                        after: max(reading.binIndex - 1, -1),
                        rarity: rarity,
                        exact: true
                    )

                    while let currentBin = bin,
                          currentBin > 0,
                          currentBin < reading.binCount
                    {
                        let date = reading.date(forBinIndex: currentBin)
                        if date >= end { break }

                        if date >= start && !isBoundaryDuplicate(bin: currentBin, rarity: rarity, reading: reading) {
                            upsert(
                                ScheduledSarosEvent(
                                    saros: reading.saros,
                                    binIndex: currentBin,
                                    date: date,
                                    octalAddress: reading.octalAddress(forBinIndex: currentBin),
                                    harmonicDepth: harmonicDepth,
                                    rarity: rarity
                                ),
                                into: &eventsByKey
                            )
                        }

                        let nextBin = reading.nextQualifiedFlipBin(after: currentBin, rarity: rarity, exact: true)
                        guard let nextBin, nextBin > currentBin else { break }
                        bin = nextBin
                    }
                }
            }
        }

        return eventsByKey.values.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.saros != $1.saros { return $0.saros < $1.saros }
            return $0.rarity > $1.rarity
        }
    }

    static func distinctTimelineEvents(_ events: [ScheduledSarosEvent]) -> [ScheduledSarosEvent] {
        var eventsBySecond: [Int64: ScheduledSarosEvent] = [:]
        for event in events {
            let key = Int64(event.date.timeIntervalSince1970.rounded(.towardZero))
            if let existing = eventsBySecond[key] {
                if event.rarity > existing.rarity {
                    eventsBySecond[key] = event
                }
            } else {
                eventsBySecond[key] = event
            }
        }
        return eventsBySecond.values.sorted { $0.date < $1.date }
    }

    static func candidateIntervals(
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

    static func appendBoundaryEventIfNeeded(
        date: Date,
        reading: SarosClockReading,
        start: Date,
        end: Date,
        into eventsByKey: inout [String: ScheduledSarosEvent]
    ) {
        guard date >= start, date < end else { return }
        upsert(
            ScheduledSarosEvent(
                saros: reading.saros,
                binIndex: reading.binCount,
                date: date,
                octalAddress: String(repeating: "7", count: reading.harmonicDepth),
                harmonicDepth: reading.harmonicDepth,
                rarity: .mythicDigit(7)
            ),
            into: &eventsByKey
        )
    }

    static func isBoundaryDuplicate(
        bin: Int,
        rarity: FlipRarity,
        reading: SarosClockReading
    ) -> Bool {
        rarity == .mythicDigit(7) && bin == reading.binCount - 1
    }

    static func upsert(
        _ event: ScheduledSarosEvent,
        into eventsByKey: inout [String: ScheduledSarosEvent]
    ) {
        let key = "\(event.saros)-\(Int(event.date.timeIntervalSince1970))"
        if let existing = eventsByKey[key] {
            if event.rarity > existing.rarity {
                eventsByKey[key] = event
            }
        } else {
            eventsByKey[key] = event
        }
    }
}

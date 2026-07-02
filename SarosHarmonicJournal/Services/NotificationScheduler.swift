import Foundation
import SwiftUI
import UIKit
import UserNotifications

final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationScheduler()

    private let identifierPrefix = "saros-journal."
    private static let waveformNotificationLeadTime = SarosPulseCalculator.averageDuration(for: .mili)
    private static let waveformNotificationLeadLabel = "1 milisaros"

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

    func scheduleActivityCountdownCompletion(for session: ContinuousActivitySession) async {
        guard session.kind == .countdown,
              let endDate = session.endDate,
              endDate > Date(),
              await requestAuthorization() else { return }

        await cancelActivityCountdown()

        let content = UNMutableNotificationContent()
        content.title = "Countdown complete"
        content.body = "\(session.template.resolvedStaticEmoji) \(session.template.previewTitle) is ready to record."
        content.sound = .default
        content.interruptionLevel = .active
        content.threadIdentifier = "journal-activity-countdown"
        content.userInfo = [
            "trigger": "activityCountdownComplete",
            "sessionID": session.id.uuidString,
            "startDate": session.startDate.timeIntervalSince1970,
            "endDate": endDate.timeIntervalSince1970
        ]

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: endDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: "\(identifierPrefix)activity.countdown.\(session.id.uuidString)",
            content: content,
            trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func cancelActivityCountdown() async {
        let pending = await pendingRequests()
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("\(identifierPrefix)activity.countdown.") }
        )
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
        moonPhaseService: any MoonPhaseService,
        harmonicDepth rawHarmonicDepth: Int,
        recentEntries: [JournalEntry] = [],
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
        let timelineEvents = Self.distinctTimelineEvents(events)
        let peakCandidates = timelineEvents.enumerated()
            .filter { _, event in
                event.date.addingTimeInterval(-Self.waveformNotificationLeadTime) > now
            }

        for (index, event) in peakCandidates.prefix(peakLimit) {
            await schedulePeakNotification(
                event: event,
                previous: index > timelineEvents.startIndex ? timelineEvents[index - 1] : nil,
                next: index < timelineEvents.index(before: timelineEvents.endIndex) ? timelineEvents[index + 1] : nil,
                notifyDate: event.date.addingTimeInterval(-Self.waveformNotificationLeadTime)
            )
        }

        let boundaryCandidates = zip(timelineEvents, timelineEvents.dropFirst())
            .compactMap { previous, next -> SarosBoundaryNotification? in
                let boundaryDate = Date(
                    timeIntervalSince1970: (previous.date.timeIntervalSince1970 + next.date.timeIntervalSince1970) / 2
                )
                let notifyDate = boundaryDate.addingTimeInterval(-Self.waveformNotificationLeadTime)
                guard notifyDate > now, boundaryDate < interval.end else { return nil }
                return SarosBoundaryNotification(
                    previous: previous,
                    next: next,
                    date: boundaryDate,
                    notifyDate: notifyDate
                )
            }

        for boundary in boundaryCandidates.prefix(boundaryLimit) {
            await scheduleMidpointNotification(boundary)
        }

        let configuredPulseSaros = UserDefaults.standard.integer(forKey: JournalSettings.pulseSarosKey)
        let pulseSaros = configuredPulseSaros > 0
            ? configuredPulseSaros
            : summaries
                .filter { $0.firstEclipseDate < now && $0.lastEclipseDate > now }
                .map(\.saros)
                .sorted()
                .first
        if let pulseSaros {
            await scheduleGigaPulseNotifications(
                saros: pulseSaros,
                eclipseService: eclipseService,
                harmonicDepth: depth,
                now: now,
                horizon: horizon
            )
        }

        await scheduleLunarTickNotifications(
            moonPhaseService: moonPhaseService,
            now: now,
            horizon: horizon
        )

        await scheduleEntryEndNotifications(
            entries: Array(recentEntries.prefix(10)),
            now: now
        )
    }

    private func scheduleEntryEndNotifications(
        entries: [JournalEntry],
        now: Date
    ) async {
        for entry in entries {
            let endDate = entry.effectiveEndDate
            guard entry.isPeriodEntry, endDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Record ended"
            content.body = "\(JournalRecordMarkers.marker(from: entry.emoji)) \(entry.firstTextLine) has ended."
            content.sound = .default
            content.interruptionLevel = .active
            content.threadIdentifier = "journal-entry-end"
            content.userInfo = [
                "trigger": "journalEntryEnd",
                "entryID": entry.id.uuidString,
                "endDate": endDate.timeIntervalSince1970
            ]

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: endDate),
                repeats: false
            )
            let identifier = "\(identifierPrefix)entry.end.\(entry.id.uuidString).\(Int(endDate.timeIntervalSince1970))"
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            )
        }
    }

    private func scheduleGigaPulseNotifications(
        saros: Int,
        eclipseService: any EclipseService,
        harmonicDepth: Int,
        now: Date,
        horizon: TimeInterval,
        limit: Int = 24
    ) async {
        let displayInterval = DateInterval(
            start: now,
            end: now.addingTimeInterval(horizon)
        )
        guard let ticks = try? SarosPulseCalculator.ticks(
            in: displayInterval,
            saros: saros,
            harmonicDepth: harmonicDepth,
            eclipseService: eclipseService
        ) else {
            return
        }

        let gigaTicks = ticks
            .filter { $0.unit == .giga && $0.date.addingTimeInterval(-Self.waveformNotificationLeadTime) > now }
            .prefix(limit)

        for tick in gigaTicks {
            await scheduleGigaPulseNotification(
                tick: tick,
                eclipseService: eclipseService,
                harmonicDepth: harmonicDepth
            )
        }
    }

    private func scheduleGigaPulseNotification(
        tick: SarosPulseTick,
        eclipseService: any EclipseService,
        harmonicDepth: Int
    ) async {
        let notifyDate = tick.date.addingTimeInterval(-Self.waveformNotificationLeadTime)
        let pulseReading = try? SarosPulseCalculator.reading(
            saros: tick.saros,
            date: tick.date.addingTimeInterval(0.001),
            harmonicDepth: harmonicDepth,
            eclipseService: eclipseService
        )

        let content = UNMutableNotificationContent()
        content.title = "Giga pulse \(tick.digit)"
        content.subtitle = "T-minus \(Self.waveformNotificationLeadLabel)"
        if let pulseReading {
            content.body = "Saros \(tick.saros) pulse \(pulseReading.octalAddress) begins at \(JournalFormatters.dateTime.string(from: tick.date))."
        } else {
            content.body = "Saros \(tick.saros) Giga \(tick.digit) begins at \(JournalFormatters.dateTime.string(from: tick.date))."
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "saros-pulse-\(tick.saros)"
        content.relevanceScore = 0.72
        content.userInfo = [
            "trigger": "sarosPulseGiga",
            "saros": tick.saros,
            "date": tick.date.timeIntervalSince1970,
            "digit": tick.digit,
            "octalAddress": pulseReading?.octalAddress ?? ""
        ]

        if let pulseReading,
           let attachment = await glyphAttachment(
            octalAddress: pulseReading.octalAddress,
            harmonicDepth: pulseReading.glyphDepth,
            style: pulseReading.glyphStyle
           )
        {
            content.attachments = [attachment]
        }

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notifyDate),
            repeats: false
        )
        let identifier = "\(identifierPrefix)pulse.giga.\(tick.saros).\(Int(tick.date.timeIntervalSince1970))"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
    }

    private func scheduleLunarTickNotifications(
        moonPhaseService: any MoonPhaseService,
        now: Date,
        horizon: TimeInterval,
        limit: Int = 64
    ) async {
        let interval = DateInterval(
            start: now,
            end: now.addingTimeInterval(horizon)
        )
        let ticks = LunarRulerTickBuilder.ticks(in: interval, moonService: moonPhaseService)
            .filter {
                ($0.level == .major || $0.level == .eighth)
                    && $0.date.addingTimeInterval(-Self.waveformNotificationLeadTime) > now
            }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                if lhs.level != rhs.level { return lhs.level.rawValue < rhs.level.rawValue }
                return lhs.cycle.rawValue < rhs.cycle.rawValue
            }
            .prefix(limit)

        for tick in ticks {
            await scheduleLunarTickNotification(tick)
        }
    }

    private func scheduleLunarTickNotification(_ tick: LunarRulerTick) async {
        let notifyDate = tick.date.addingTimeInterval(-Self.waveformNotificationLeadTime)
        let content = UNMutableNotificationContent()
        content.title = tick.label ?? "\(tick.cycle.displayName) lunar tick"
        content.subtitle = "T-minus \(Self.waveformNotificationLeadLabel)"
        content.body = "\(tick.cycle.displayName) \(tick.level.notificationName) at \(JournalFormatters.dateTime.string(from: tick.date))."
        content.sound = .default
        content.interruptionLevel = tick.level == .major ? .timeSensitive : .active
        content.threadIdentifier = "lunar-\(tick.cycle.rawValue)"
        content.relevanceScore = tick.level == .major ? 0.78 : 0.56
        content.userInfo = [
            "trigger": "lunarTick",
            "cycle": tick.cycle.rawValue,
            "level": tick.level.rawValue,
            "date": tick.date.timeIntervalSince1970,
            "label": tick.label ?? ""
        ]

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notifyDate),
            repeats: false
        )
        let identifier = "\(identifierPrefix)lunar.\(tick.cycle.rawValue).\(tick.level.rawValue).\(Int(tick.date.timeIntervalSince1970))"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
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
        previous: ScheduledSarosEvent?,
        next: ScheduledSarosEvent?,
        notifyDate: Date
    ) async {
        let durationText = SarosDurationUnitFormatter.verboseDuration(
            Self.peakWindowDuration(event: event, previous: previous, next: next),
            maxUnits: 2
        )
        let content = UNMutableNotificationContent()
        content.title = "Approaching \(event.shortTitle) peak"
        content.subtitle = "T-minus \(Self.waveformNotificationLeadLabel)"
        content.body = "Approaching \(event.shortTitle) peak that will last \(durationText)."
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

    private func scheduleMidpointNotification(_ boundary: SarosBoundaryNotification) async {
        let waitText = SarosDurationUnitFormatter.verboseDuration(
            max(boundary.next.date.timeIntervalSince(boundary.date), 0),
            maxUnits: 2
        )
        let ascentSpeed = Self.ascentSpeedLabel(previous: boundary.previous, boundary: boundary.date, next: boundary.next)
        let content = UNMutableNotificationContent()
        content.title = "Beginning \(ascentSpeed) ascent"
        content.subtitle = "T-minus \(Self.waveformNotificationLeadLabel)"
        content.body = "Beginning \(ascentSpeed) ascent towards \(boundary.next.shortTitle). T-minus \(waitText)."
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
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: boundary.notifyDate),
            repeats: false
        )
        let identifier = "\(identifierPrefix)global.midpoint.\(Int(boundary.previous.date.timeIntervalSince1970)).\(Int(boundary.next.date.timeIntervalSince1970))"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
    }

    private static func peakWindowDuration(
        event: ScheduledSarosEvent,
        previous: ScheduledSarosEvent?,
        next: ScheduledSarosEvent?
    ) -> TimeInterval {
        let fallback = SarosPulseCalculator.averageDuration(for: .mega)
        guard let previous, let next else {
            return fallback
        }

        let start = midpoint(previous.date, event.date)
        let end = midpoint(event.date, next.date)
        return max(end.timeIntervalSince(start), fallback)
    }

    private static func ascentSpeedLabel(
        previous: ScheduledSarosEvent,
        boundary: Date,
        next: ScheduledSarosEvent
    ) -> String {
        let descentDuration = max(boundary.timeIntervalSince(previous.date), 0.001)
        let ascentDuration = max(next.date.timeIntervalSince(boundary), 0.001)
        return ascentDuration < descentDuration ? "rapid" : "slow"
    }

    private static func midpoint(_ lhs: Date, _ rhs: Date) -> Date {
        Date(timeIntervalSince1970: (lhs.timeIntervalSince1970 + rhs.timeIntervalSince1970) / 2)
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
    let notifyDate: Date
}

private extension LunarRulerTickLevel {
    var notificationName: String {
        switch self {
        case .major:
            "event"
        case .eighth:
            "1/8"
        case .sixtyFourth:
            "1/64"
        case .fiveHundredTwelfth:
            "1/512"
        }
    }
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

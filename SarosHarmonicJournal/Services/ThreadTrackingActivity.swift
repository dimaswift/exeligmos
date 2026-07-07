import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

struct ThreadTrackingSnapshot: Codable, Hashable {
    let threadID: String
    let threadTitle: String
    let saros: Int
    let harmonicDepth: Int
    let eventName: String?
    let energyPercent: Double?
    let momentum: Double?
    let waveDirectionRawValue: String?
    let waveformSamples: [Double]?
    let waveformSamplePositions: [Double]?
    let waveformSpikeMarkers: [TrackingWaveformSpikeMarker]?
    let waveformStartDate: Date?
    let waveformEndDate: Date?
    let widgetRangeKilosaros: Int?
    let glyph: String
    let rarityRawValue: String
    let rarityTitle: String
    let rarityOrderLabel: String
    let raritySymbolName: String
    let rarityColorHex: String
    let raritySecondaryColorHex: String?
    let flipDate: Date
    let createdAt: Date
    let nextGlyph: String?
    let nextRarityRawValue: String?
    let nextRarityTitle: String?
    let nextRarityOrderLabel: String?
    let nextRaritySymbolName: String?
    let nextRarityColorHex: String?
    let nextRaritySecondaryColorHex: String?
    let nextFlipDate: Date?
    let pulseSaros: Int?
    let pulseCycleStartDate: Date?
    let pulseCycleEndDate: Date?
    let moonSynodicStartDate: Date?
    let moonSynodicEndDate: Date?
    let moonAnomalisticStartDate: Date?
    let moonAnomalisticEndDate: Date?
    let moonDraconicStartDate: Date?
    let moonDraconicEndDate: Date?
    let isActivityLogging: Bool?
    let activityStartDate: Date?
    let activityEndDate: Date?

    var deepLinkURL: URL? {
        if isActivityLogging == true || ThreadTrackingSharedStore.isActivityLoggingID(threadID) {
            return URL(string: "exeligmos://record")
        }
        if threadID == ThreadTrackingSharedStore.journalTrackingID {
            return URL(string: "exeligmos://saros")
        }
        return URL(string: "exeligmos://thread/\(threadID)")
    }

    var recordURL: URL? {
        if isActivityLogging == true || ThreadTrackingSharedStore.isActivityLoggingID(threadID) {
            return URL(string: "exeligmos://record")
        }
        if threadID == ThreadTrackingSharedStore.journalTrackingID {
            return URL(string: "exeligmos://record")
        }
        return URL(string: "exeligmos://record/\(threadID)")
    }
}

struct TrackingWaveformSpikeMarker: Codable, Hashable {
    let position: Double
    let energy: Double
    let colorHex: String
}

enum ThreadTrackingSharedStore {
    static let appGroupIdentifier = "group.fractonica.exeligmos"
    static let journalTrackingID = "journal-live"
    static let activityLoggingID = "journal-activity-logging"
    static let activityLoggingIDPrefix = "journal-activity-logging."
    static let snapshotKey = "trackedThread.snapshot"
    static let widgetKind = "TrackedThreadWidget"
    static let flipRolloverDelay: TimeInterval = 8

    static func activityLoggingID(for sessionID: UUID) -> String {
        "\(activityLoggingIDPrefix)\(sessionID.uuidString)"
    }

    static func isActivityLoggingID(_ threadID: String) -> Bool {
        threadID == activityLoggingID || threadID.hasPrefix(activityLoggingIDPrefix)
    }

    static func activitySessionID(from threadID: String) -> UUID? {
        guard threadID.hasPrefix(activityLoggingIDPrefix) else { return nil }
        return UUID(uuidString: String(threadID.dropFirst(activityLoggingIDPrefix.count)))
    }

    static func save(_ snapshot: ThreadTrackingSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
        defaults.synchronize()
    }

    static func load() -> ThreadTrackingSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(ThreadTrackingSnapshot.self, from: data)
    }

    static func clear() {
        defaults.removeObject(forKey: snapshotKey)
        defaults.synchronize()
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}

#if canImport(ActivityKit)
struct ThreadTrackingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let saros: Int?
        let eventName: String?
        let energyPercent: Double?
        let momentum: Double?
        let waveDirectionRawValue: String?
        let waveformSamples: [Double]?
        let waveformSamplePositions: [Double]?
        let waveformSpikeMarkers: [TrackingWaveformSpikeMarker]?
        let waveformStartDate: Date?
        let waveformEndDate: Date?
        let widgetRangeKilosaros: Int?
        let glyph: String
        let rarityRawValue: String
        let rarityTitle: String
        let rarityOrderLabel: String
        let raritySymbolName: String
        let rarityColorHex: String
        let raritySecondaryColorHex: String?
        let flipDate: Date
        let updatedAt: Date
        let nextGlyph: String?
        let nextRarityRawValue: String?
        let nextRarityTitle: String?
        let nextRarityOrderLabel: String?
        let nextRaritySymbolName: String?
        let nextRarityColorHex: String?
        let nextRaritySecondaryColorHex: String?
        let nextFlipDate: Date?
        let pulseSaros: Int?
        let pulseCycleStartDate: Date?
        let pulseCycleEndDate: Date?
        let moonSynodicStartDate: Date?
        let moonSynodicEndDate: Date?
        let moonAnomalisticStartDate: Date?
        let moonAnomalisticEndDate: Date?
        let moonDraconicStartDate: Date?
        let moonDraconicEndDate: Date?
        let isActivityLogging: Bool?
        let activityStartDate: Date?
        let activityEndDate: Date?
    }

    let threadID: String
    let threadTitle: String
    let saros: Int
    let harmonicDepth: Int
}
#endif

enum ActivityLoggingGlyph {
    static let depth = 6
    static let defaultColorHex = "#FFFFFF"
    static let blueColorHex = "#0A84FF"
    static let purpleColorHex = "#BF5AF2"
    static let yellowColorHex = "#FFD60A"
    static let redColorHex = "#FF3B30"

    static func glyph(startDate: Date, at date: Date) -> String {
        let elapsed = max(date.timeIntervalSince(startDate), 0)
        let nanosarosDuration = averageSarosPeriod / pow(8, 9)
        let binCount = Int(pow(8, Double(depth)))
        let rawIndex = Int(floor(elapsed / max(nanosarosDuration, 0.000_001)))
        let index = ((rawIndex % binCount) + binCount) % binCount
        return leftPadded(String(index, radix: 8), toLength: depth, withPad: "0")
    }

    static func colorHex(for glyph: String) -> String {
        switch intensity(for: glyph) {
        case 4...:
            return redColorHex
        case 3:
            return yellowColorHex
        case 2:
            return purpleColorHex
        case 1:
            return blueColorHex
        default:
            return defaultColorHex
        }
    }

    static func title(for glyph: String) -> String {
        switch intensity(for: glyph) {
        case 4...:
            return "Red activity"
        case 3:
            return "Yellow activity"
        case 2:
            return "Purple activity"
        case 1:
            return "Blue activity"
        default:
            return "Activity"
        }
    }

    private static func intensity(for glyph: String) -> Int {
        let digits = glyph.filter { "01234567".contains($0) }
        guard !digits.isEmpty else { return 0 }
        let trailingZeroes = digits.reversed().prefix { $0 == "0" }.count
        let repeatingSuffix = repeatingSuffixLength(in: digits)

        if trailingZeroes >= 5 || repeatingSuffix >= 6 { return 4 }
        if trailingZeroes >= 4 || repeatingSuffix >= 5 { return 3 }
        if trailingZeroes >= 3 || repeatingSuffix >= 4 { return 2 }
        if trailingZeroes >= 2 || repeatingSuffix >= 3 { return 1 }
        return 0
    }

    private static func repeatingSuffixLength(in digits: String) -> Int {
        guard let last = digits.last else { return 0 }
        return digits.reversed().prefix { $0 == last }.count
    }

    private static func leftPadded(_ value: String, toLength length: Int, withPad pad: Character) -> String {
        guard value.count < length else { return String(value.suffix(length)) }
        return String(repeating: String(pad), count: length - value.count) + value
    }

    private static let averageSarosPeriod: TimeInterval = 6_585.3211 * 24 * 60 * 60
}

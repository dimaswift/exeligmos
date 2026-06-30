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

    var deepLinkURL: URL? {
        if threadID == ThreadTrackingSharedStore.journalTrackingID {
            return URL(string: "exeligmos://saros")
        }
        return URL(string: "exeligmos://thread/\(threadID)")
    }

    var recordURL: URL? {
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
    static let appGroupIdentifier = "group.com.exeligmos.sarosjournal"
    static let journalTrackingID = "journal-live"
    static let snapshotKey = "trackedThread.snapshot"
    static let widgetKind = "TrackedThreadWidget"
    static let flipRolloverDelay: TimeInterval = 8

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
    }

    let threadID: String
    let threadTitle: String
    let saros: Int
    let harmonicDepth: Int
}
#endif

import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

struct ThreadTrackingSnapshot: Codable, Hashable {
    let threadID: String
    let threadTitle: String
    let saros: Int
    let harmonicDepth: Int
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

    var deepLinkURL: URL? {
        URL(string: "exeligmos://thread/\(threadID)")
    }

    var recordURL: URL? {
        URL(string: "exeligmos://record/\(threadID)")
    }
}

enum ThreadTrackingSharedStore {
    static let appGroupIdentifier = "group.com.exeligmos.sarosjournal"
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
    }

    let threadID: String
    let threadTitle: String
    let saros: Int
    let harmonicDepth: Int
}
#endif

import Foundation
import SwiftData

enum JournalWaveDirection: String, Codable, CaseIterable, Identifiable {
    case ascending
    case descending
    case flat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ascending: "Ascending"
        case .descending: "Descending"
        case .flat: "Flat"
        }
    }
}

enum JournalWaveExtremum: String, Codable, CaseIterable, Identifiable {
    case none
    case localMaximum
    case localMinimum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .localMaximum: "Maximum"
        case .localMinimum: "Minimum"
        }
    }
}

struct JournalSpikeReference: Codable, Hashable, Identifiable {
    let saros: Int
    let unixTimestamp: Int64
    let octalAddress: String
    let harmonicDepth: Int
    let rarityRawValue: String
    let gamma: Double?
    let magnitude: Double?

    var id: String {
        "\(saros)-\(unixTimestamp)-\(octalAddress)-\(rarityRawValue)"
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(unixTimestamp))
    }

    var rarity: FlipRarity {
        FlipRarity(rawValue: rarityRawValue) ?? .common
    }

    var displayLine: String {
        "\(saros):\(octalAddress)"
    }
}

struct JournalEventContext: Codable, Hashable {
    let unixTimestamp: Int64
    let spikes: [JournalSpikeReference]
    let energy: Double
    let energyPercent: Double
    let slope: Double
    let momentum: Double
    let directionRawValue: String
    let extremumRawValue: String
    let majorPeriodSeconds: TimeInterval

    var eventDate: Date {
        Date(timeIntervalSince1970: TimeInterval(unixTimestamp))
    }

    var direction: JournalWaveDirection {
        JournalWaveDirection(rawValue: directionRawValue) ?? .flat
    }

    var extremum: JournalWaveExtremum {
        guard !spikes.isEmpty else {
            return JournalWaveExtremum(rawValue: extremumRawValue) ?? .none
        }
        if energyPercent >= 0.99 {
            return .localMaximum
        }
        if energyPercent <= 0.01 {
            return .localMinimum
        }
        return .none
    }

    var effectiveMomentum: Double {
        if abs(momentum) > 0.000_1 {
            return min(max(momentum, -1), 1)
        }
        let slopePerDay = slope * 86_400
        guard slopePerDay.isFinite else { return 0 }
        return min(max(tanh(slopePerDay / 4.0), -1), 1)
    }

    var rarity: FlipRarity {
        spikes.map(\.rarity).max() ?? .common
    }

    var closestSpike: JournalSpikeReference? {
        spikes.min {
            abs($0.date.timeIntervalSince(eventDate)) < abs($1.date.timeIntervalSince(eventDate))
        }
    }

    var sarosNumbers: [Int] {
        Array(Set(spikes.map(\.saros))).sorted()
    }

    var derivedName: String {
        guard let closestSpike else {
            return "\(direction.title) \(rarity.title)"
        }
        return "\(closestSpike.saros) \(direction.title) \(rarity.title)"
    }
}

@Model
final class JournalEntry {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var eventDate: Date
    var unixTimestamp: Int64

    var text: String?
    var emoji: String?
    var mediaItemsJSON: Data
    var contextJSON: Data

    var latitude: Double?
    var longitude: Double?
    var sourceRecordID: UUID?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        eventDate: Date,
        text: String? = nil,
        emoji: String? = nil,
        mediaItems: [JournalMediaItem] = [],
        context: JournalEventContext,
        latitude: Double? = nil,
        longitude: Double? = nil,
        sourceRecordID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.eventDate = eventDate
        self.unixTimestamp = Int64(eventDate.timeIntervalSince1970.rounded(.towardZero))
        self.text = text
        self.emoji = emoji
        self.mediaItemsJSON = (try? JSONEncoder().encode(mediaItems)) ?? Data()
        self.contextJSON = (try? JSONEncoder().encode(context)) ?? Data()
        self.latitude = latitude
        self.longitude = longitude
        self.sourceRecordID = sourceRecordID
    }

    var mediaItems: [JournalMediaItem] {
        get { (try? JSONDecoder().decode([JournalMediaItem].self, from: mediaItemsJSON)) ?? [] }
        set {
            mediaItemsJSON = (try? JSONEncoder().encode(newValue)) ?? Data()
            updatedAt = Date()
        }
    }

    var context: JournalEventContext {
        get {
            (try? JSONDecoder().decode(JournalEventContext.self, from: contextJSON))
                ?? JournalEventContext.empty(date: eventDate)
        }
        set {
            contextJSON = (try? JSONEncoder().encode(newValue)) ?? Data()
            eventDate = newValue.eventDate
            unixTimestamp = newValue.unixTimestamp
            updatedAt = Date()
        }
    }
}

extension JournalEventContext {
    static func empty(date: Date) -> JournalEventContext {
        JournalEventContext(
            unixTimestamp: Int64(date.timeIntervalSince1970.rounded(.towardZero)),
            spikes: [],
            energy: 0,
            energyPercent: 0,
            slope: 0,
            momentum: 0,
            directionRawValue: JournalWaveDirection.flat.rawValue,
            extremumRawValue: JournalWaveExtremum.none.rawValue,
            majorPeriodSeconds: 0
        )
    }
}

@Model
final class JournalTag {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var name: String
    var emoji: String
    var anchorDate: Date
    var saros: Int
    var notes: String?
    var sourceEntityID: UUID?
    var isPrimeRawValue: Bool?
    var colorHex: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        name: String,
        emoji: String,
        anchorDate: Date,
        saros: Int,
        notes: String? = nil,
        sourceEntityID: UUID? = nil,
        isPrime: Bool = false,
        colorHex: String = "#FFFFFF"
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.name = name
        self.emoji = emoji
        self.anchorDate = anchorDate
        self.saros = saros
        self.notes = notes
        self.sourceEntityID = sourceEntityID
        self.isPrimeRawValue = isPrime
        self.colorHex = colorHex
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "Saros \(saros)"
    }

    var displayEmoji: String {
        emoji.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "◇"
    }

    var isPrime: Bool {
        get { isPrimeRawValue ?? false }
        set { isPrimeRawValue = newValue }
    }

    var tintHex: String {
        colorHex?.nilIfBlank ?? "#FFFFFF"
    }

    func touch() {
        updatedAt = Date()
    }
}

@Model
final class JournalTemplate {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var name: String
    var emoji: String
    var text: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        name: String,
        emoji: String,
        text: String = ""
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.name = name
        self.emoji = emoji
        self.text = text
    }

    var displayName: String {
        name.nilIfBlank ?? "Template"
    }

    var displayEmoji: String {
        emoji.nilIfBlank ?? JournalRecordMarkers.random()
    }

    func touch() {
        updatedAt = Date()
    }
}

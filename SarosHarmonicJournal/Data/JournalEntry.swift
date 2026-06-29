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

enum JournalWaveMomentumMapper {
    private static let flatAngle = 5.0 * Double.pi / 180.0
    private static let verticalAngle = 88.0 * Double.pi / 180.0

    static func momentum(forGradient gradient: Double) -> Double {
        guard gradient.isFinite else { return 0 }

        let angle = atan(abs(gradient))
        let normalized = min(max((angle - flatAngle) / (verticalAngle - flatAngle), 0), 1)
        guard normalized > 0 else { return 0 }
        return normalized * (gradient >= 0 ? 1 : -1)
    }

    static func direction(forGradient gradient: Double) -> JournalWaveDirection {
        let momentum = momentum(forGradient: gradient)
        guard abs(momentum) > 0 else { return .flat }
        return gradient > 0 ? .ascending : .descending
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
    let eclipseTypeRawValue: String?
    let sarosSequence: Int?
    let sarosSeriesCount: Int?
    let seriesProgressesSouthToNorth: Bool?

    var id: String {
        "\(saros)-\(unixTimestamp)-\(octalAddress)-\(rarityRawValue)"
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(unixTimestamp))
    }

    var rarity: FlipRarity {
        FlipRarity(rawValue: rarityRawValue) ?? .common
    }

    var eclipseType: EclipseType? {
        eclipseTypeRawValue.flatMap(EclipseType.init(rawValue:))
    }

    var isPartialEclipse: Bool {
        eclipseType?.isPartialSolar == true
    }

    var isPastSeriesMidpoint: Bool? {
        guard let sarosSequence, let sarosSeriesCount, sarosSeriesCount > 0 else {
            return nil
        }
        return Double(sarosSequence) >= Double(sarosSeriesCount) / 2
    }

    var displayLine: String {
        "\(saros):\(octalAddress)"
    }
}

struct JournalEventContext: Codable, Hashable {
    let unixTimestamp: Int64
    let spikes: [JournalSpikeReference]
    let closestSarosPhase: JournalSarosPhaseReference?
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
        closestSpike?.rarity ?? .common
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
    var endDate: Date?
    var unixTimestamp: Int64
    var version: Int = 1

    var text: String?
    var emoji: String?
    var mediaItemsJSON: Data
    var contextJSON: Data
    var tagIDsRawValue: String?
    var tagIDsJSON: Data?

    var latitude: Double?
    var longitude: Double?
    var sourceRecordID: UUID?
    var sourceDeviceID: String?
    var sourceDeviceEmoji: String?
    var sourceDeviceName: String?
    var weatherCode: Int?
    var weatherEmoji: String?
    var temperatureC: Int?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        eventDate: Date,
        endDate: Date? = nil,
        version: Int = 1,
        text: String? = nil,
        emoji: String? = nil,
        mediaItems: [JournalMediaItem] = [],
        context: JournalEventContext,
        tagIDs: [String] = [],
        latitude: Double? = nil,
        longitude: Double? = nil,
        sourceRecordID: UUID? = nil,
        sourceDeviceID: String? = nil,
        sourceDeviceEmoji: String? = nil,
        sourceDeviceName: String? = nil,
        weatherCode: Int? = nil,
        weatherEmoji: String? = nil,
        temperatureC: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.eventDate = eventDate
        self.endDate = endDate
        self.unixTimestamp = Int64(eventDate.timeIntervalSince1970.rounded(.towardZero))
        self.version = max(version, 1)
        self.text = text
        self.emoji = emoji
        self.mediaItemsJSON = (try? JSONEncoder().encode(mediaItems)) ?? Data()
        self.contextJSON = (try? JSONEncoder().encode(context)) ?? Data()
        self.tagIDsRawValue = Self.encodeTagIDs(tagIDs)
        self.tagIDsJSON = nil
        self.latitude = latitude
        self.longitude = longitude
        self.sourceRecordID = sourceRecordID
        self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceEmoji = sourceDeviceEmoji
        self.sourceDeviceName = sourceDeviceName
        self.weatherCode = weatherCode
        self.weatherEmoji = weatherEmoji
        self.temperatureC = temperatureC
    }

    var mediaItems: [JournalMediaItem] {
        get { (try? JSONDecoder().decode([JournalMediaItem].self, from: mediaItemsJSON)) ?? [] }
        set {
            mediaItemsJSON = (try? JSONEncoder().encode(newValue)) ?? Data()
            updatedAt = Date()
        }
    }

    var effectiveEndDate: Date {
        guard let endDate, endDate > eventDate else { return eventDate }
        return endDate
    }

    var eventDuration: TimeInterval {
        max(effectiveEndDate.timeIntervalSince(eventDate), 0)
    }

    var isPeriodEntry: Bool {
        eventDuration > 0.5
    }

    func isOngoing(at date: Date = Date()) -> Bool {
        isPeriodEntry && eventDate <= date && effectiveEndDate > date
    }

    var firstTextLine: String {
        text?
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank ?? "Record"
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
            if let endDate, endDate < eventDate {
                self.endDate = eventDate
            }
            updatedAt = Date()
        }
    }

    var tagIDs: [String] {
        get {
            if let tagIDsRawValue {
                return Self.decodeTagIDs(tagIDsRawValue)
            }
            guard let tagIDsJSON,
                  let decoded = try? JSONDecoder().decode([String].self, from: tagIDsJSON)
            else { return [] }
            return Self.normalizedTagIDs(decoded)
        }
        set {
            tagIDsRawValue = Self.encodeTagIDs(newValue)
            updatedAt = Date()
        }
    }

    private static func encodeTagIDs(_ tagIDs: [String]) -> String {
        normalizedTagIDs(tagIDs).joined(separator: ",")
    }

    private static func decodeTagIDs(_ rawValue: String) -> [String] {
        normalizedTagIDs(rawValue.split(separator: ",").map(String.init))
    }

    private static func normalizedTagIDs(_ tagIDs: [String]) -> [String] {
        var seen = Set<String>()
        return tagIDs.compactMap { JournalTag.normalizedOctalID($0) }.filter { seen.insert($0).inserted }
    }
}

extension JournalEventContext {
    static func empty(date: Date) -> JournalEventContext {
        JournalEventContext(
            unixTimestamp: Int64(date.timeIntervalSince1970.rounded(.towardZero)),
            spikes: [],
            closestSarosPhase: nil,
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
    var octalID: String?

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
        colorHex: String = "#FFFFFF",
        octalID: String? = nil
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
        self.octalID = Self.normalizedOctalID(octalID)
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

    var compactID: String {
        Self.normalizedOctalID(octalID) ?? Self.fallbackOctalID(for: id)
    }

    var displayCompactID: String {
        compactID
    }

    func ensureCompactID(existing tags: [JournalTag]) {
        let normalized = Self.normalizedOctalID(octalID)
        let candidate = normalized ?? compactID
        let duplicatesExistingID = tags.contains { tag in
            tag.id != id && tag.compactID == candidate
        }
        if !duplicatesExistingID {
            octalID = candidate
        } else {
            let used = Set(tags.filter { $0.id != id }.map(\.compactID))
            octalID = Self.nextAvailableOctalID(used: used)
        }
    }

    @discardableResult
    static func ensureUniqueCompactIDs(in tags: [JournalTag]) -> Bool {
        var used = Set<String>()
        var changed = false

        for tag in tags.sorted(by: stableSort) {
            let candidate = normalizedOctalID(tag.octalID) ?? fallbackOctalID(for: tag.id)
            if !used.contains(candidate) {
                if tag.octalID != candidate {
                    tag.octalID = candidate
                    changed = true
                }
                used.insert(candidate)
                continue
            }

            let replacement = nextAvailableOctalID(used: used)
            if tag.octalID != replacement {
                tag.octalID = replacement
                changed = true
            }
            used.insert(replacement)
        }

        return changed
    }

    static func compactIDOrderMap(for tags: [JournalTag]) -> [String: Int] {
        var order: [String: Int] = [:]
        for (index, tag) in tags.enumerated() where order[tag.compactID] == nil {
            order[tag.compactID] = index
        }
        return order
    }

    func touch() {
        updatedAt = Date()
    }

    static func normalizedOctalID(_ rawValue: String?) -> String? {
        let digits = (rawValue ?? "").filter { "01234567".contains($0) }
        guard !digits.isEmpty, let value = Int(digits, radix: 8), (0..<512).contains(value) else {
            return nil
        }
        return String(value, radix: 8).leftPadded(toLength: 3, withPad: "0")
    }

    static func nextAvailableOctalID(used: Set<String>) -> String {
        for value in 0..<512 {
            let candidate = String(value, radix: 8).leftPadded(toLength: 3, withPad: "0")
            if !used.contains(candidate) {
                return candidate
            }
        }
        return "777"
    }

    private static func fallbackOctalID(for id: UUID) -> String {
        let sum = id.uuidString.unicodeScalars.reduce(0) { value, scalar in
            (value &* 31 &+ Int(scalar.value)) % 512
        }
        return String(sum, radix: 8).leftPadded(toLength: 3, withPad: "0")
    }

    private static func stableSort(_ lhs: JournalTag, _ rhs: JournalTag) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
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

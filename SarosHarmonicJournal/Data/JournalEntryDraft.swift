import Foundation
import SwiftData

@Model
final class JournalEntryDraft {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var recordStartedAt: Date
    var eventDate: Date
    var text: String?
    var emoji: String?
    var mediaItemsJSON: Data
    var tagIDsRawValue: String?
    var tagIDsJSON: Data?
    var latitude: Double?
    var longitude: Double?
    var weatherCode: Int?
    var weatherEmoji: String?
    var temperatureC: Int?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        recordStartedAt: Date,
        eventDate: Date,
        text: String? = nil,
        emoji: String? = nil,
        mediaItems: [JournalMediaItem] = [],
        tagIDs: [String] = [],
        latitude: Double? = nil,
        longitude: Double? = nil,
        weatherCode: Int? = nil,
        weatherEmoji: String? = nil,
        temperatureC: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recordStartedAt = recordStartedAt
        self.eventDate = eventDate
        self.text = text
        self.emoji = emoji
        self.mediaItemsJSON = (try? JSONEncoder().encode(mediaItems)) ?? Data()
        self.tagIDsRawValue = Self.encodeTagIDs(tagIDs)
        self.tagIDsJSON = nil
        self.latitude = latitude
        self.longitude = longitude
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

    func update(
        recordStartedAt: Date,
        eventDate: Date,
        text: String?,
        emoji: String?,
        mediaItems: [JournalMediaItem],
        tagIDs: [String],
        latitude: Double?,
        longitude: Double?,
        weatherCode: Int?,
        weatherEmoji: String?,
        temperatureC: Int?
    ) {
        self.recordStartedAt = recordStartedAt
        self.eventDate = eventDate
        self.text = text
        self.emoji = emoji
        self.mediaItems = mediaItems
        self.tagIDs = tagIDs
        self.latitude = latitude
        self.longitude = longitude
        self.weatherCode = weatherCode
        self.weatherEmoji = weatherEmoji
        self.temperatureC = temperatureC
        self.updatedAt = Date()
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

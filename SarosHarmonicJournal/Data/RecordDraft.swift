import Foundation
import SwiftData

@Model
final class RecordDraft {
    @Attribute(.unique) var id: UUID
    var entityID: UUID
    var createdAt: Date
    var updatedAt: Date
    var eventDate: Date

    var text: String?
    var emoji: String?
    var mediaItemsJSON: Data

    var saros: Int
    var harmonicDepth: Int
    var octalAddress: String
    var binIndex: Int
    var phase: Double

    var latitude: Double?
    var longitude: Double?

    init(
        id: UUID = UUID(),
        entityID: UUID,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        eventDate: Date,
        text: String? = nil,
        emoji: String? = nil,
        mediaItems: [JournalMediaItem] = [],
        saros: Int,
        harmonicDepth: Int,
        octalAddress: String,
        binIndex: Int,
        phase: Double,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.id = id
        self.entityID = entityID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.eventDate = eventDate
        self.text = text
        self.emoji = emoji
        self.mediaItemsJSON = (try? JSONEncoder().encode(mediaItems)) ?? Data()
        self.saros = saros
        self.harmonicDepth = harmonicDepth
        self.octalAddress = octalAddress
        self.binIndex = binIndex
        self.phase = phase
        self.latitude = latitude
        self.longitude = longitude
    }

    var mediaItems: [JournalMediaItem] {
        get { (try? JSONDecoder().decode([JournalMediaItem].self, from: mediaItemsJSON)) ?? [] }
        set { mediaItemsJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    func apply(reading: SarosClockReading) {
        saros = reading.saros
        harmonicDepth = reading.harmonicDepth
        octalAddress = reading.octalAddress
        binIndex = reading.binIndex
        phase = reading.phase
    }
}

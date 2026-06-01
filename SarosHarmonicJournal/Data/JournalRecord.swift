import Foundation
import SwiftData

enum MediaType: String, Codable, CaseIterable {
    case photo
    case symbolicPhoto
    case video
    case audio

    var isImage: Bool {
        switch self {
        case .photo, .symbolicPhoto:
            true
        case .video, .audio:
            false
        }
    }
}

struct JournalMediaItem: Codable, Hashable, Identifiable {
    let id: UUID
    let type: MediaType
    let localPath: String
    let createdAt: Date

    init(id: UUID = UUID(), type: MediaType, localPath: String, createdAt: Date = Date()) {
        self.id = id
        self.type = type
        self.localPath = localPath
        self.createdAt = createdAt
    }
}

enum JournalTriggerType: String, Codable, CaseIterable {
    case manual
    case binFlip
    case resonance
    case eclipse

    var displayName: String {
        switch self {
        case .manual: "Manual"
        case .binFlip: "Bin flip"
        case .resonance: "Resonance"
        case .eclipse: "Eclipse"
        }
    }
}

@Model
final class JournalRecord {
    @Attribute(.unique) var id: UUID
    var entityID: UUID
    var createdAt: Date
    var eventDate: Date

    var text: String?
    var emoji: String?
    var mediaItemsJSON: Data

    var saros: Int
    var harmonicDepth: Int
    var octalAddress: String
    var binIndex: Int
    var phase: Double

    var triggerTypeRawValue: String
    var resonanceGroupID: UUID?

    var latitude: Double?
    var longitude: Double?

    init(
        id: UUID = UUID(),
        entityID: UUID,
        createdAt: Date = Date(),
        eventDate: Date = Date(),
        text: String? = nil,
        emoji: String? = nil,
        mediaItems: [JournalMediaItem] = [],
        saros: Int,
        harmonicDepth: Int,
        octalAddress: String,
        binIndex: Int,
        phase: Double,
        triggerType: JournalTriggerType,
        resonanceGroupID: UUID? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.id = id
        self.entityID = entityID
        self.createdAt = createdAt
        self.eventDate = eventDate
        self.text = text
        self.emoji = emoji
        self.mediaItemsJSON = (try? JSONEncoder().encode(mediaItems)) ?? Data()
        self.saros = saros
        self.harmonicDepth = harmonicDepth
        self.octalAddress = octalAddress
        self.binIndex = binIndex
        self.phase = phase
        self.triggerTypeRawValue = triggerType.rawValue
        self.resonanceGroupID = resonanceGroupID
        self.latitude = latitude
        self.longitude = longitude
    }

    var triggerType: JournalTriggerType {
        get { JournalTriggerType(rawValue: triggerTypeRawValue) ?? .manual }
        set { triggerTypeRawValue = newValue.rawValue }
    }

    var mediaItems: [JournalMediaItem] {
        get { (try? JSONDecoder().decode([JournalMediaItem].self, from: mediaItemsJSON)) ?? [] }
        set { mediaItemsJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

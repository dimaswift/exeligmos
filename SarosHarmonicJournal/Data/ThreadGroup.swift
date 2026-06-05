import Foundation
import SwiftData

@Model
final class ThreadGroup {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date

    var name: String
    var emoji: String
    var rarityRawValue: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        name: String,
        emoji: String,
        rarity: FlipRarity = .common
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.name = name
        self.emoji = emoji
        self.rarityRawValue = rarity.rawValue
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.commonName : name
    }

    var displayEmoji: String {
        emoji.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? Self.commonEmoji
    }

    var rarity: FlipRarity {
        get { FlipRarity(rawValue: rarityRawValue) ?? .common }
        set { rarityRawValue = newValue.rawValue }
    }

    func touch() {
        updatedAt = Date()
    }

    static let commonName = "Common"
    static let commonEmoji = "○"
    static let commonRarity = FlipRarity.common
}

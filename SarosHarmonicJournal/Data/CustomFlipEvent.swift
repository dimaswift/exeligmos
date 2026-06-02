import Foundation
import SwiftData

@Model
final class CustomFlipEvent {
    @Attribute(.unique) var id: UUID
    var entityID: UUID
    var createdAt: Date
    var updatedAt: Date
    var name: String
    var date: Date
    var octalAddress: String
    var binIndex: Int
    var colorHex: String

    init(
        id: UUID = UUID(),
        entityID: UUID,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        name: String,
        date: Date,
        octalAddress: String,
        binIndex: Int,
        colorHex: String
    ) {
        self.id = id
        self.entityID = entityID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.name = name
        self.date = date
        self.octalAddress = octalAddress
        self.binIndex = binIndex
        self.colorHex = colorHex
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom flip" : name
    }
}

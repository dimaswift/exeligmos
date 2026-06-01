import Foundation
import SwiftData

@Model
final class TrackedEntity {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date

    var title: String
    var anchorDate: Date
    var saros: Int
    var harmonicDepth: Int

    var emoji: String?
    var photoLocalPath: String?
    var notes: String?

    var nearestEclipseID: String?
    var birthOrAnchorEclipseDate: Date?

    var notificationsEnabled: Bool
    var notifyBeforeFlipMinutes: Int

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        title: String,
        anchorDate: Date,
        saros: Int,
        harmonicDepth: Int = JournalSettings.defaultHarmonicDepth,
        emoji: String? = nil,
        photoLocalPath: String? = nil,
        notes: String? = nil,
        nearestEclipseID: String? = nil,
        birthOrAnchorEclipseDate: Date? = nil,
        notificationsEnabled: Bool = true,
        notifyBeforeFlipMinutes: Int = 30
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.anchorDate = anchorDate
        self.saros = saros
        self.harmonicDepth = harmonicDepth
        self.emoji = emoji
        self.photoLocalPath = photoLocalPath
        self.notes = notes
        self.nearestEclipseID = nearestEclipseID
        self.birthOrAnchorEclipseDate = birthOrAnchorEclipseDate
        self.notificationsEnabled = notificationsEnabled
        self.notifyBeforeFlipMinutes = notifyBeforeFlipMinutes
    }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled thread" : title
    }

    func touch() {
        updatedAt = Date()
    }
}

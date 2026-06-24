import Foundation
import SwiftData

struct JournalMigrationSummary: Hashable {
    let insertedTags: Int
    let insertedEntries: Int
    let skippedEntries: Int
}

final class JournalMigrationService {
    private let contextService: SarosEventContextService

    init(contextService: SarosEventContextService) {
        self.contextService = contextService
    }

    @MainActor
    func migrate(
        entities: [TrackedEntity],
        records: [JournalRecord],
        existingEntries: [JournalEntry],
        existingTags: [JournalTag],
        modelContext: ModelContext
    ) throws -> JournalMigrationSummary {
        var insertedTags = 0
        var insertedEntries = 0
        var skippedEntries = 0
        let migratedEntityIDs = Set(existingTags.compactMap(\.sourceEntityID))
        let migratedRecordIDs = Set(existingEntries.compactMap(\.sourceRecordID))

        for entity in entities where !migratedEntityIDs.contains(entity.id) {
            let tag = JournalTag(
                createdAt: entity.createdAt,
                updatedAt: entity.updatedAt,
                name: entity.displayTitle,
                emoji: entity.emoji ?? "◇",
                anchorDate: entity.anchorDate,
                saros: entity.saros,
                notes: entity.notes,
                sourceEntityID: entity.id
            )
            modelContext.insert(tag)
            insertedTags += 1
        }

        for record in records {
            guard !migratedRecordIDs.contains(record.id) else {
                skippedEntries += 1
                continue
            }

            let context = try contextService.context(
                for: record.eventDate,
                harmonicDepth: JournalSettings.supportedHarmonicDepth.upperBound
            )
            let entry = JournalEntry(
                id: record.id,
                createdAt: record.createdAt,
                updatedAt: record.createdAt,
                eventDate: record.eventDate,
                text: record.text,
                emoji: record.emoji,
                mediaItems: record.mediaItems,
                context: context,
                latitude: record.latitude,
                longitude: record.longitude,
                sourceRecordID: record.id
            )
            modelContext.insert(entry)
            insertedEntries += 1
        }

        try modelContext.save()
        return JournalMigrationSummary(
            insertedTags: insertedTags,
            insertedEntries: insertedEntries,
            skippedEntries: skippedEntries
        )
    }
}

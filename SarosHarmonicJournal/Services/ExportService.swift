import Foundation

struct JournalExportArchive: Codable {
    let appVersion: String
    let exportTimestamp: Date
    let entities: [TrackedEntitySnapshot]
    let records: [JournalRecordSnapshot]
}

struct TrackedEntitySnapshot: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let title: String
    let anchorDate: Date
    let saros: Int
    let harmonicDepth: Int
    let emoji: String?
    let photoLocalPath: String?
    let notes: String?
    let nearestEclipseID: String?
    let birthOrAnchorEclipseDate: Date?
    let notificationsEnabled: Bool
    let notifyBeforeFlipMinutes: Int
}

struct JournalRecordSnapshot: Codable, Identifiable {
    let id: UUID
    let entityID: UUID
    let createdAt: Date
    let eventDate: Date
    let text: String?
    let emoji: String?
    let mediaItems: [JournalMediaItem]
    let saros: Int
    let harmonicDepth: Int
    let octalAddress: String
    let binIndex: Int
    let phase: Double
    let triggerType: JournalTriggerType
    let resonanceGroupID: UUID?
    let latitude: Double?
    let longitude: Double?
}

final class ExportService {
    func makeArchive(entities: [TrackedEntity], records: [JournalRecord]) -> JournalExportArchive {
        JournalExportArchive(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            exportTimestamp: Date(),
            entities: entities.map(TrackedEntitySnapshot.init(entity:)),
            records: records.map(JournalRecordSnapshot.init(record:))
        )
    }

    func exportJSON(entities: [TrackedEntity], records: [JournalRecord]) throws -> URL {
        let archive = makeArchive(entities: entities, records: records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let root = try exportRootDirectory()
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        try encoder.encode(archive).write(to: root.appendingPathComponent("archive.json"), options: [.atomic])
        try encoder.encode(archive.entities).write(to: root.appendingPathComponent("entities.json"), options: [.atomic])
        try encoder.encode(archive.records).write(to: root.appendingPathComponent("records.json"), options: [.atomic])

        try copyMedia(records: archive.records, to: mediaDirectory)
        return root
    }

    private func exportRootDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let root = documents.appendingPathComponent("SarosExport-\(formatter.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func copyMedia(records: [JournalRecordSnapshot], to mediaDirectory: URL) throws {
        for item in records.flatMap(\.mediaItems) {
            let source = URL(fileURLWithPath: item.localPath)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = mediaDirectory.appendingPathComponent(source.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }
    }
}

private extension TrackedEntitySnapshot {
    init(entity: TrackedEntity) {
        self.init(
            id: entity.id,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt,
            title: entity.title,
            anchorDate: entity.anchorDate,
            saros: entity.saros,
            harmonicDepth: entity.harmonicDepth,
            emoji: entity.emoji,
            photoLocalPath: entity.photoLocalPath,
            notes: entity.notes,
            nearestEclipseID: entity.nearestEclipseID,
            birthOrAnchorEclipseDate: entity.birthOrAnchorEclipseDate,
            notificationsEnabled: entity.notificationsEnabled,
            notifyBeforeFlipMinutes: entity.notifyBeforeFlipMinutes
        )
    }
}

private extension JournalRecordSnapshot {
    init(record: JournalRecord) {
        self.init(
            id: record.id,
            entityID: record.entityID,
            createdAt: record.createdAt,
            eventDate: record.eventDate,
            text: record.text,
            emoji: record.emoji,
            mediaItems: record.mediaItems,
            saros: record.saros,
            harmonicDepth: record.harmonicDepth,
            octalAddress: record.octalAddress,
            binIndex: record.binIndex,
            phase: record.phase,
            triggerType: record.triggerType,
            resonanceGroupID: record.resonanceGroupID,
            latitude: record.latitude,
            longitude: record.longitude
        )
    }
}


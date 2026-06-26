import Foundation

struct JournalExportArchive: Codable {
    let appVersion: String
    let exportTimestamp: Date
    let threadGroups: [ThreadGroupSnapshot]
    let entities: [TrackedEntitySnapshot]
    let records: [JournalRecordSnapshot]
    let tags: [JournalTagSnapshot]
    let entries: [JournalEntrySnapshot]

    init(
        appVersion: String,
        exportTimestamp: Date,
        threadGroups: [ThreadGroupSnapshot] = [],
        entities: [TrackedEntitySnapshot],
        records: [JournalRecordSnapshot],
        tags: [JournalTagSnapshot] = [],
        entries: [JournalEntrySnapshot] = []
    ) {
        self.appVersion = appVersion
        self.exportTimestamp = exportTimestamp
        self.threadGroups = threadGroups
        self.entities = entities
        self.records = records
        self.tags = tags
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case appVersion
        case exportTimestamp
        case threadGroups
        case entities
        case records
        case tags
        case entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.appVersion = try container.decode(String.self, forKey: .appVersion)
        self.exportTimestamp = try container.decode(Date.self, forKey: .exportTimestamp)
        self.threadGroups = try container.decodeIfPresent([ThreadGroupSnapshot].self, forKey: .threadGroups) ?? []
        self.entities = try container.decode([TrackedEntitySnapshot].self, forKey: .entities)
        self.records = try container.decode([JournalRecordSnapshot].self, forKey: .records)
        self.tags = try container.decodeIfPresent([JournalTagSnapshot].self, forKey: .tags) ?? []
        self.entries = try container.decodeIfPresent([JournalEntrySnapshot].self, forKey: .entries) ?? []
    }
}

struct RecordExportArchive: Codable {
    let appVersion: String
    let exportTimestamp: Date
    let entityTitle: String
    let record: JournalRecordSnapshot
    let media: [RecordExportMediaSnapshot]
}

struct RecordExportMediaSnapshot: Codable, Identifiable {
    let id: UUID
    let type: MediaType
    let createdAt: Date
    let originalLocalPath: String
    let exportedPath: String?
    let included: Bool
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
    let groupID: UUID?
    let nearestEclipseID: String?
    let birthOrAnchorEclipseDate: Date?
    let notificationsEnabled: Bool
    let notifyBeforeFlipMinutes: Int
}

struct ThreadGroupSnapshot: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let name: String
    let emoji: String
    let rarityRawValue: String
}

struct JournalTagSnapshot: Codable, Identifiable {
    let id: UUID
    let octalID: String?
    let createdAt: Date
    let updatedAt: Date
    let name: String
    let emoji: String
    let anchorDate: Date
    let saros: Int
    let notes: String?
    let sourceEntityID: UUID?
    let isPrime: Bool
    let colorHex: String
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

struct JournalEntrySnapshot: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let eventDate: Date
    let unixTimestamp: Int64
    let version: Int?
    let text: String?
    let emoji: String?
    let mediaItems: [JournalMediaItem]
    let tagIDs: [String]?
    let context: JournalEventContext
    let latitude: Double?
    let longitude: Double?
    let sourceRecordID: UUID?
    let sourceDeviceID: String?
    let sourceDeviceEmoji: String?
    let sourceDeviceName: String?
    let weatherCode: Int?
    let weatherEmoji: String?
    let temperatureC: Int?
}

final class ExportService {
    func makeArchive(entities: [TrackedEntity], records: [JournalRecord], groups: [ThreadGroup] = []) -> JournalExportArchive {
        JournalExportArchive(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            exportTimestamp: Date(),
            threadGroups: groups.map(ThreadGroupSnapshot.init(group:)),
            entities: entities.map(TrackedEntitySnapshot.init(entity:)),
            records: records.map(JournalRecordSnapshot.init(record:))
        )
    }

    func makeEntryArchive(tags: [JournalTag], entries: [JournalEntry]) -> JournalExportArchive {
        JournalExportArchive(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            exportTimestamp: Date(),
            entities: [],
            records: [],
            tags: tags.map(JournalTagSnapshot.init(tag:)),
            entries: entries.map(JournalEntrySnapshot.init(entry:))
        )
    }

    func exportJSON(entities: [TrackedEntity], records: [JournalRecord], groups: [ThreadGroup] = []) throws -> URL {
        let archive = makeArchive(entities: entities, records: records, groups: groups)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let root = try exportRootDirectory()
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        try encoder.encode(archive).write(to: root.appendingPathComponent("archive.json"), options: [.atomic])
        try encoder.encode(archive.threadGroups).write(to: root.appendingPathComponent("thread_groups.json"), options: [.atomic])
        try encoder.encode(archive.entities).write(to: root.appendingPathComponent("entities.json"), options: [.atomic])
        try encoder.encode(archive.records).write(to: root.appendingPathComponent("records.json"), options: [.atomic])

        try copyMedia(records: archive.records, to: mediaDirectory)
        return root
    }

    func exportRecordZIP(record: JournalRecord, entityTitle: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var entries: [StoredZipEntry] = []
        var mediaSnapshots: [RecordExportMediaSnapshot] = []

        for item in record.mediaItems {
            let source = MediaStorage.url(for: item)
            let fileName = exportedMediaFileName(for: item, source: source)
            let exportedPath = "media/\(fileName)"

            if FileManager.default.fileExists(atPath: source.path) {
                entries.append(StoredZipEntry(path: exportedPath, data: try Data(contentsOf: source)))
                mediaSnapshots.append(RecordExportMediaSnapshot(
                    id: item.id,
                    type: item.type,
                    createdAt: item.createdAt,
                    originalLocalPath: item.localPath,
                    exportedPath: exportedPath,
                    included: true
                ))
            } else {
                mediaSnapshots.append(RecordExportMediaSnapshot(
                    id: item.id,
                    type: item.type,
                    createdAt: item.createdAt,
                    originalLocalPath: item.localPath,
                    exportedPath: nil,
                    included: false
                ))
            }
        }

        let archive = RecordExportArchive(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            exportTimestamp: Date(),
            entityTitle: entityTitle,
            record: JournalRecordSnapshot(record: record),
            media: mediaSnapshots
        )
        entries.insert(StoredZipEntry(path: "record.json", data: try encoder.encode(archive)), at: 0)

        let destination = try recordExportURL(entityTitle: entityTitle, record: record)
        try StoredZipArchive.write(entries: entries, to: destination)
        return destination
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
            let source = MediaStorage.url(for: item)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = mediaDirectory.appendingPathComponent(source.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }
    }

    private func recordExportURL(entityTitle: String, record: JournalRecord) throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let title = sanitizedFilenameComponent(entityTitle)
        let stamp = formatter.string(from: Date())
        return documents.appendingPathComponent("SarosRecord-\(title)-\(stamp)-\(record.id.uuidString.prefix(8)).zip")
    }

    private func exportedMediaFileName(for item: JournalMediaItem, source: URL) -> String {
        let pathExtension = source.pathExtension
        if pathExtension.isEmpty {
            return item.id.uuidString
        }
        return "\(item.id.uuidString).\(pathExtension)"
    }

    private func sanitizedFilenameComponent(_ value: String) -> String {
        let cleaned = String(value.map { character in
            character.isLetter || character.isNumber ? character : "-"
        })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((trimmed.isEmpty ? "Record" : trimmed).prefix(48))
    }
}

private struct StoredZipEntry {
    let path: String
    let data: Data
}

private enum StoredZipArchive {
    private struct CentralDirectoryRecord {
        let nameData: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    enum ArchiveError: LocalizedError {
        case entryTooLarge(String)
        case archiveTooLarge
        case invalidPath(String)

        var errorDescription: String? {
            switch self {
            case .entryTooLarge(let path):
                "The file \(path) is too large for this ZIP exporter."
            case .archiveTooLarge:
                "The record archive is too large for this ZIP exporter."
            case .invalidPath(let path):
                "The archive path \(path) could not be encoded."
            }
        }
    }

    static func write(entries: [StoredZipEntry], to url: URL) throws {
        var archive = Data()
        var centralDirectory: [CentralDirectoryRecord] = []

        for entry in entries {
            guard let nameData = entry.path.data(using: .utf8), nameData.count <= Int(UInt16.max) else {
                throw ArchiveError.invalidPath(entry.path)
            }
            guard entry.data.count <= Int(UInt32.max) else {
                throw ArchiveError.entryTooLarge(entry.path)
            }
            guard archive.count <= Int(UInt32.max) else {
                throw ArchiveError.archiveTooLarge
            }

            let crc32 = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let localHeaderOffset = UInt32(archive.count)

            archive.appendUInt32(0x0403_4B50)
            archive.appendUInt16(20)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(crc32)
            archive.appendUInt32(size)
            archive.appendUInt32(size)
            archive.appendUInt16(UInt16(nameData.count))
            archive.appendUInt16(0)
            archive.append(nameData)
            archive.append(entry.data)

            centralDirectory.append(CentralDirectoryRecord(
                nameData: nameData,
                crc32: crc32,
                size: size,
                localHeaderOffset: localHeaderOffset
            ))
        }

        guard archive.count <= Int(UInt32.max), centralDirectory.count <= Int(UInt16.max) else {
            throw ArchiveError.archiveTooLarge
        }
        let centralDirectoryOffset = UInt32(archive.count)

        for record in centralDirectory {
            archive.appendUInt32(0x0201_4B50)
            archive.appendUInt16(20)
            archive.appendUInt16(20)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(record.crc32)
            archive.appendUInt32(record.size)
            archive.appendUInt32(record.size)
            archive.appendUInt16(UInt16(record.nameData.count))
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(0)
            archive.appendUInt32(record.localHeaderOffset)
            archive.append(record.nameData)
        }

        guard archive.count <= Int(UInt32.max) else {
            throw ArchiveError.archiveTooLarge
        }
        let centralDirectorySize = UInt32(archive.count) - centralDirectoryOffset
        let entryCount = UInt16(centralDirectory.count)

        archive.appendUInt32(0x0605_4B50)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(entryCount)
        archive.appendUInt16(entryCount)
        archive.appendUInt32(centralDirectorySize)
        archive.appendUInt32(centralDirectoryOffset)
        archive.appendUInt16(0)

        try archive.write(to: url, options: [.atomic])
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(contentsOf: buffer)
        }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(contentsOf: buffer)
        }
    }
}

extension TrackedEntitySnapshot {
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
            groupID: entity.groupID,
            nearestEclipseID: entity.nearestEclipseID,
            birthOrAnchorEclipseDate: entity.birthOrAnchorEclipseDate,
            notificationsEnabled: entity.notificationsEnabled,
            notifyBeforeFlipMinutes: entity.notifyBeforeFlipMinutes
        )
    }
}

extension ThreadGroupSnapshot {
    init(group: ThreadGroup) {
        self.init(
            id: group.id,
            createdAt: group.createdAt,
            updatedAt: group.updatedAt,
            name: group.name,
            emoji: group.emoji,
            rarityRawValue: group.rarityRawValue
        )
    }
}

extension JournalTagSnapshot {
    init(tag: JournalTag) {
        self.init(
            id: tag.id,
            octalID: tag.compactID,
            createdAt: tag.createdAt,
            updatedAt: tag.updatedAt,
            name: tag.name,
            emoji: tag.emoji,
            anchorDate: tag.anchorDate,
            saros: tag.saros,
            notes: tag.notes,
            sourceEntityID: tag.sourceEntityID,
            isPrime: tag.isPrime,
            colorHex: tag.tintHex
        )
    }
}

extension JournalRecordSnapshot {
    init(record: JournalRecord) {
        let portableMediaItems = record.mediaItems.map { item in
            JournalMediaItem(
                id: item.id,
                type: item.type,
                localPath: MediaStorage.portablePath(for: item),
                createdAt: item.createdAt
            )
        }

        self.init(
            id: record.id,
            entityID: record.entityID,
            createdAt: record.createdAt,
            eventDate: record.eventDate,
            text: record.text,
            emoji: record.emoji,
            mediaItems: portableMediaItems,
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

extension JournalEntrySnapshot {
    init(entry: JournalEntry) {
        let portableMediaItems = entry.mediaItems.map { item in
            JournalMediaItem(
                id: item.id,
                type: item.type,
                localPath: MediaStorage.portablePath(for: item),
                createdAt: item.createdAt
            )
        }

        self.init(
            id: entry.id,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            eventDate: entry.eventDate,
            unixTimestamp: entry.unixTimestamp,
            version: entry.version,
            text: entry.text,
            emoji: entry.emoji,
            mediaItems: portableMediaItems,
            tagIDs: entry.tagIDs,
            context: entry.context,
            latitude: entry.latitude,
            longitude: entry.longitude,
            sourceRecordID: entry.sourceRecordID,
            sourceDeviceID: entry.sourceDeviceID,
            sourceDeviceEmoji: entry.sourceDeviceEmoji,
            sourceDeviceName: entry.sourceDeviceName,
            weatherCode: entry.weatherCode,
            weatherEmoji: entry.weatherEmoji,
            temperatureC: entry.temperatureC
        )
    }
}

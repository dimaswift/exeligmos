import Foundation
import SwiftData

struct SyncBackupPayload: Codable {
    let schemaVersion: Int
    let appVersion: String
    let exportTimestamp: Date
    let archive: JournalExportArchive
    let media: [SyncMediaBlob]
}

struct SyncMediaBlob: Codable, Identifiable {
    let id: UUID
    let type: MediaType
    let createdAt: Date
    let relativePath: String
    let fileName: String
    let contentType: String
    let dataBase64: String
}

struct SyncPushSummary: Hashable {
    let entityCount: Int
    let recordCount: Int
    let mediaCount: Int
}

struct SyncRestoreSummary: Hashable {
    let entityCount: Int
    let recordCount: Int
    let mediaCount: Int
}

struct SyncServerStatus: Codable, Hashable {
    let ok: Bool
    let hasBackup: Bool
    let exportTimestamp: Date?
    let entityCount: Int
    let recordCount: Int
    let mediaCount: Int
}

struct SyncServerManifest: Codable, Hashable {
    let ok: Bool
    let hasBackup: Bool
    let exportTimestamp: Date?
    let entityIDs: [UUID]
    let recordIDs: [UUID]
    let mediaIDs: [UUID]
}

final class SyncService {
    enum SyncError: LocalizedError {
        case invalidServerURL
        case invalidResponse(statusCode: Int?, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidServerURL:
                "Enter a sync server URL such as http://192.168.1.10:8787."
            case .invalidResponse(let statusCode, let body):
                if let statusCode {
                    "Sync server returned HTTP \(statusCode): \(body)"
                } else {
                    "The sync server returned an invalid response: \(body)"
                }
            }
        }
    }

    func push(to serverURLString: String, entities: [TrackedEntity], records: [JournalRecord]) async throws -> SyncPushSummary {
        let payload = try makePayload(entities: entities, records: records)
        let url = try endpoint(serverURLString, path: "/api/backups")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        return SyncPushSummary(
            entityCount: payload.archive.entities.count,
            recordCount: payload.archive.records.count,
            mediaCount: payload.media.count
        )
    }

    func pushMissingRecords(
        to serverURLString: String,
        entities: [TrackedEntity],
        records: [JournalRecord]
    ) async throws -> SyncPushSummary {
        let manifest = try await fetchManifest(from: serverURLString)
        let uploadedRecordIDs = Set(manifest.recordIDs)
        let missingRecords = records.filter { !uploadedRecordIDs.contains($0.id) }

        guard !missingRecords.isEmpty else {
            return SyncPushSummary(entityCount: 0, recordCount: 0, mediaCount: 0)
        }

        let neededEntityIDs = Set(missingRecords.map(\.entityID))
        let entitiesForRecords = entities.filter { neededEntityIDs.contains($0.id) }
        let payload = try makePayload(entities: entitiesForRecords, records: missingRecords)
        let url = try endpoint(serverURLString, path: "/api/backups/delta")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        return SyncPushSummary(
            entityCount: payload.archive.entities.count,
            recordCount: payload.archive.records.count,
            mediaCount: payload.media.count
        )
    }

    @MainActor
    func restoreLatest(
        from serverURLString: String,
        modelContext: ModelContext,
        entities: [TrackedEntity],
        records: [JournalRecord]
    ) async throws -> SyncRestoreSummary {
        let payload = try await fetchLatest(from: serverURLString)
        return try restore(payload: payload, modelContext: modelContext, entities: entities, records: records)
    }

    func fetchLatest(from serverURLString: String) async throws -> SyncBackupPayload {
        let url = try endpoint(serverURLString, path: "/api/backups/latest")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try decoder.decode(SyncBackupPayload.self, from: data)
    }

    func checkStatus(from serverURLString: String) async throws -> SyncServerStatus {
        let url = try endpoint(serverURLString, path: "/api/status")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try decoder.decode(SyncServerStatus.self, from: data)
    }

    func fetchManifest(from serverURLString: String) async throws -> SyncServerManifest {
        let url = try endpoint(serverURLString, path: "/api/manifest")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try decoder.decode(SyncServerManifest.self, from: data)
    }

    private func makePayload(entities: [TrackedEntity], records: [JournalRecord]) throws -> SyncBackupPayload {
        let archive = ExportService().makeArchive(entities: entities, records: records)
        var seenMediaIDs = Set<UUID>()
        let media = try records.flatMap(\.mediaItems).compactMap { item -> SyncMediaBlob? in
            guard seenMediaIDs.insert(item.id).inserted else { return nil }

            let url = MediaStorage.url(for: item)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            let relativePath = MediaStorage.portablePath(for: item)

            return SyncMediaBlob(
                id: item.id,
                type: item.type,
                createdAt: item.createdAt,
                relativePath: relativePath,
                fileName: url.lastPathComponent,
                contentType: contentType(for: url),
                dataBase64: data.base64EncodedString()
            )
        }

        return SyncBackupPayload(
            schemaVersion: 1,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            exportTimestamp: Date(),
            archive: archive,
            media: media
        )
    }

    private func restore(
        payload: SyncBackupPayload,
        modelContext: ModelContext,
        entities: [TrackedEntity],
        records: [JournalRecord]
    ) throws -> SyncRestoreSummary {
        let existingEntities = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
        let existingRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let restoredMedia = try restoreMedia(payload.media)

        for snapshot in payload.archive.entities {
            if let entity = existingEntities[snapshot.id] {
                apply(snapshot, to: entity)
            } else {
                modelContext.insert(TrackedEntity(snapshot: snapshot))
            }
        }

        for snapshot in payload.archive.records {
            let mediaItems = snapshot.mediaItems.compactMap { item in
                restoredMedia[item.id]
            }

            if let record = existingRecords[snapshot.id] {
                apply(snapshot, mediaItems: mediaItems, to: record)
            } else {
                modelContext.insert(JournalRecord(snapshot: snapshot, mediaItems: mediaItems))
            }
        }

        try modelContext.save()
        return SyncRestoreSummary(
            entityCount: payload.archive.entities.count,
            recordCount: payload.archive.records.count,
            mediaCount: restoredMedia.count
        )
    }

    private func restoreMedia(_ media: [SyncMediaBlob]) throws -> [UUID: JournalMediaItem] {
        var restored: [UUID: JournalMediaItem] = [:]

        for blob in media {
            guard let data = Data(base64Encoded: blob.dataBase64) else {
                continue
            }

            let relativePath = sanitizedRelativePath(blob.relativePath, fallbackFileName: blob.fileName)
            let url = documentsDirectory().appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])

            restored[blob.id] = JournalMediaItem(
                id: blob.id,
                type: blob.type,
                localPath: relativePath,
                createdAt: blob.createdAt
            )
        }

        return restored
    }

    private func apply(_ snapshot: TrackedEntitySnapshot, to entity: TrackedEntity) {
        entity.createdAt = snapshot.createdAt
        entity.updatedAt = snapshot.updatedAt
        entity.title = snapshot.title
        entity.anchorDate = snapshot.anchorDate
        entity.saros = snapshot.saros
        entity.harmonicDepth = snapshot.harmonicDepth
        entity.emoji = snapshot.emoji
        entity.photoLocalPath = snapshot.photoLocalPath
        entity.notes = snapshot.notes
        entity.nearestEclipseID = snapshot.nearestEclipseID
        entity.birthOrAnchorEclipseDate = snapshot.birthOrAnchorEclipseDate
        entity.notificationsEnabled = snapshot.notificationsEnabled
        entity.notifyBeforeFlipMinutes = snapshot.notifyBeforeFlipMinutes
    }

    private func apply(_ snapshot: JournalRecordSnapshot, mediaItems: [JournalMediaItem], to record: JournalRecord) {
        record.entityID = snapshot.entityID
        record.createdAt = snapshot.createdAt
        record.eventDate = snapshot.eventDate
        record.text = snapshot.text
        record.emoji = snapshot.emoji
        record.mediaItems = mediaItems
        record.saros = snapshot.saros
        record.harmonicDepth = snapshot.harmonicDepth
        record.octalAddress = snapshot.octalAddress
        record.binIndex = snapshot.binIndex
        record.phase = snapshot.phase
        record.triggerType = snapshot.triggerType
        record.resonanceGroupID = snapshot.resonanceGroupID
        record.latitude = snapshot.latitude
        record.longitude = snapshot.longitude
    }

    private func endpoint(_ serverURLString: String, path: String) throws -> URL {
        guard var components = URLComponents(string: serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil,
              components.host != nil else {
            throw SyncError.invalidServerURL
        }
        components.path = path
        components.query = nil
        guard let url = components.url else {
            throw SyncError.invalidServerURL
        }
        return url
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse(statusCode: nil, body: response.description)
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw SyncError.invalidResponse(statusCode: httpResponse.statusCode, body: body)
        }
    }

    private func sanitizedRelativePath(_ relativePath: String, fallbackFileName: String) -> String {
        let normalized = relativePath
            .split(separator: "/")
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")

        if normalized.hasPrefix(MediaStorage.mediaDirectoryName + "/") {
            return normalized
        }

        let fileName = fallbackFileName.isEmpty ? UUID().uuidString : URL(fileURLWithPath: fallbackFileName).lastPathComponent
        return "\(MediaStorage.mediaDirectoryName)/\(fileName)"
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            "image/jpeg"
        case "png":
            "image/png"
        case "m4a":
            "audio/mp4"
        case "mov":
            "video/quicktime"
        case "mp4":
            "video/mp4"
        default:
            "application/octet-stream"
        }
    }

    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension TrackedEntity {
    convenience init(snapshot: TrackedEntitySnapshot) {
        self.init(
            id: snapshot.id,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            title: snapshot.title,
            anchorDate: snapshot.anchorDate,
            saros: snapshot.saros,
            harmonicDepth: snapshot.harmonicDepth,
            emoji: snapshot.emoji,
            photoLocalPath: snapshot.photoLocalPath,
            notes: snapshot.notes,
            nearestEclipseID: snapshot.nearestEclipseID,
            birthOrAnchorEclipseDate: snapshot.birthOrAnchorEclipseDate,
            notificationsEnabled: snapshot.notificationsEnabled,
            notifyBeforeFlipMinutes: snapshot.notifyBeforeFlipMinutes
        )
    }
}

private extension JournalRecord {
    convenience init(snapshot: JournalRecordSnapshot, mediaItems: [JournalMediaItem]) {
        self.init(
            id: snapshot.id,
            entityID: snapshot.entityID,
            createdAt: snapshot.createdAt,
            eventDate: snapshot.eventDate,
            text: snapshot.text,
            emoji: snapshot.emoji,
            mediaItems: mediaItems,
            saros: snapshot.saros,
            harmonicDepth: snapshot.harmonicDepth,
            octalAddress: snapshot.octalAddress,
            binIndex: snapshot.binIndex,
            phase: snapshot.phase,
            triggerType: snapshot.triggerType,
            resonanceGroupID: snapshot.resonanceGroupID,
            latitude: snapshot.latitude,
            longitude: snapshot.longitude
        )
    }
}

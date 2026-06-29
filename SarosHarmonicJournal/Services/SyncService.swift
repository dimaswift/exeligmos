import Foundation
import SwiftData

enum SyncLocalCommandType: String, Codable, CaseIterable {
    case entryUpsert = "entry-upsert"
    case entryDelete = "entry-delete"
    case tagUpsert = "tag-upsert"
    case tagDelete = "tag-delete"
}

@Model
final class SyncLocalCommand {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var typeRawValue: String
    var subjectID: String
    var sentAt: Date?
    var attemptCount: Int
    var lastError: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        type: SyncLocalCommandType,
        subjectID: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.typeRawValue = type.rawValue
        self.subjectID = subjectID
        self.sentAt = nil
        self.attemptCount = 0
        self.lastError = nil
    }

    var type: SyncLocalCommandType? {
        SyncLocalCommandType(rawValue: typeRawValue)
    }

    var isPending: Bool {
        sentAt == nil
    }

    func markFailed(_ error: Error) {
        attemptCount += 1
        lastError = error.localizedDescription
        updatedAt = Date()
    }

    func markSent(at date: Date = Date()) {
        sentAt = date
        lastError = nil
        updatedAt = date
    }

    @MainActor
    static func enqueue(
        _ type: SyncLocalCommandType,
        subjectID: String,
        existing commands: [SyncLocalCommand],
        modelContext: ModelContext
    ) {
        let subjectID = subjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subjectID.isEmpty else { return }

        let pendingForSubject = commands.filter { $0.isPending && $0.subjectID == subjectID }
        switch type {
        case .entryDelete:
            for command in pendingForSubject where command.type == .entryUpsert {
                modelContext.delete(command)
            }
        case .tagDelete:
            for command in pendingForSubject where command.type == .tagUpsert {
                modelContext.delete(command)
            }
        case .entryUpsert, .tagUpsert:
            break
        }

        if let existing = pendingForSubject.first(where: { $0.type == type }) {
            existing.updatedAt = Date()
            existing.lastError = nil
            return
        }

        modelContext.insert(SyncLocalCommand(type: type, subjectID: subjectID))
    }
}

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

struct SyncStatePayload: Codable {
    let schemaVersion: Int
    let appVersion: String
    let uploadedAt: Date
    let tags: [JournalTagSnapshot]
    let entryIDs: [UUID]
}

struct SyncEntryUploadPayload: Codable {
    let schemaVersion: Int
    let appVersion: String
    let uploadedAt: Date
    let entry: JournalEntrySnapshot
    let media: [SyncMediaBlob]
}

struct SyncRestoreStatePayload: Codable {
    let schemaVersion: Int
    let appVersion: String
    let exportTimestamp: Date?
    let tags: [JournalTagSnapshot]
    let entryIDs: [UUID]
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

struct SyncReconcileSummary: Hashable {
    let uploadedRecordCount: Int
    let uploadedMediaCount: Int
    let restoredEntityCount: Int
    let restoredRecordCount: Int
    let restoredMediaCount: Int

    var changedRecordCount: Int {
        uploadedRecordCount + restoredRecordCount
    }
}

struct SyncDeviceEvent: Codable, Identifiable, Hashable {
    let id: Int64
    let type: String
    let entryID: UUID?
    let sourceDeviceID: String?
    let sourceDeviceEmoji: String?
    let createdAt: Date
}

struct SyncPendingEventsPayload: Codable {
    let events: [SyncDeviceEvent]
}

struct SyncEventAckPayload: Codable {
    let schemaVersion: Int
    let eventIDs: [Int64]
}

struct SyncDeleteEntryPayload: Codable {
    let schemaVersion: Int
    let entryID: UUID
    let deletedAt: Date
}

struct SyncRelayCommandPayload: Codable {
    let entryUpload: SyncEntryUploadPayload?
    let entryID: UUID?
    let entryVersion: Int?
    let tag: JournalTagSnapshot?
    let tagID: UUID?

    init(
        entryUpload: SyncEntryUploadPayload? = nil,
        entryID: UUID? = nil,
        entryVersion: Int? = nil,
        tag: JournalTagSnapshot? = nil,
        tagID: UUID? = nil
    ) {
        self.entryUpload = entryUpload
        self.entryID = entryID
        self.entryVersion = entryVersion
        self.tag = tag
        self.tagID = tagID
    }
}

struct SyncRelayCommand: Codable, Identifiable {
    let id: UUID
    let schemaVersion: Int
    let type: String
    let subjectID: String
    let sourceChannelID: String?
    let sourceChannelEmoji: String?
    let createdAt: Date
    let payload: SyncRelayCommandPayload
}

struct SyncRelayCommandBatch: Codable {
    let schemaVersion: Int
    let commands: [SyncRelayCommand]
}

struct SyncRelayCommandBatchResponse: Codable {
    let ok: Bool
    let processedCommandIDs: [UUID]
}

struct SyncPendingCommandsPayload: Codable {
    let commands: [SyncRelayCommand]
}

struct SyncCommandAckPayload: Codable {
    let schemaVersion: Int
    let commandIDs: [UUID]
}

private struct SyncEventProcessingResult {
    let summary: SyncRestoreSummary
    let deletedEntryIDs: Set<UUID>
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
    let tagIDs: [UUID]
    let entryIDs: [UUID]
    let mediaIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case ok
        case hasBackup
        case exportTimestamp
        case entityIDs
        case recordIDs
        case tagIDs
        case entryIDs
        case mediaIDs
    }

    init(
        ok: Bool,
        hasBackup: Bool,
        exportTimestamp: Date?,
        entityIDs: [UUID],
        recordIDs: [UUID],
        tagIDs: [UUID] = [],
        entryIDs: [UUID] = [],
        mediaIDs: [UUID]
    ) {
        self.ok = ok
        self.hasBackup = hasBackup
        self.exportTimestamp = exportTimestamp
        self.entityIDs = entityIDs
        self.recordIDs = recordIDs
        self.tagIDs = tagIDs
        self.entryIDs = entryIDs
        self.mediaIDs = mediaIDs
    }

    init(restoreState: SyncRestoreStatePayload) {
        self.init(
            ok: true,
            hasBackup: true,
            exportTimestamp: restoreState.exportTimestamp,
            entityIDs: [],
            recordIDs: [],
            tagIDs: restoreState.tags.map(\.id),
            entryIDs: restoreState.entryIDs,
            mediaIDs: []
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ok = (try? container.decode(Bool.self, forKey: .ok)) ?? true
        self.hasBackup = (try? container.decode(Bool.self, forKey: .hasBackup)) ?? false
        self.exportTimestamp = try? container.decodeIfPresent(Date.self, forKey: .exportTimestamp)
        self.entityIDs = Self.decodeUUIDs(from: container, forKey: .entityIDs)
        self.recordIDs = Self.decodeUUIDs(from: container, forKey: .recordIDs)
        self.tagIDs = Self.decodeUUIDs(from: container, forKey: .tagIDs)
        self.entryIDs = Self.decodeUUIDs(from: container, forKey: .entryIDs)
        self.mediaIDs = Self.decodeUUIDs(from: container, forKey: .mediaIDs)
    }

    private static func decodeUUIDs(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [UUID] {
        if let uuids = try? container.decode([UUID].self, forKey: key) {
            return uuids
        }
        if let strings = try? container.decode([String].self, forKey: key) {
            return strings.compactMap(UUID.init(uuidString:))
        }
        return []
    }
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

    func pushEntries(
        to serverURLString: String,
        tags: [JournalTag],
        entries: [JournalEntry]
    ) async throws -> SyncPushSummary {
        let manifest = (try? await fetchManifest(from: serverURLString))
        return try await pushMirrorState(
            to: serverURLString,
            tags: tags,
            entries: entries,
            manifest: manifest
        )
    }

    func pushMissingEntries(
        to serverURLString: String,
        tags: [JournalTag],
        entries: [JournalEntry]
    ) async throws -> SyncPushSummary {
        try await pushEntries(
            to: serverURLString,
            tags: tags,
            entries: entries
        )
    }

    @MainActor
    func restoreLatestEntries(
        from serverURLString: String,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry]
    ) async throws -> SyncRestoreSummary {
        let eventResult = try await processPendingEvents(
            from: serverURLString,
            modelContext: modelContext,
            entries: entries
        )
        let state = try await fetchRestoreState(from: serverURLString)
        let restoreSummary = try await restoreEntries(
            state: state,
            from: serverURLString,
            modelContext: modelContext,
            tags: tags,
            entries: entries.filter { !eventResult.deletedEntryIDs.contains($0.id) }
        )
        return SyncRestoreSummary(
            entityCount: restoreSummary.entityCount,
            recordCount: restoreSummary.recordCount + eventResult.summary.recordCount,
            mediaCount: restoreSummary.mediaCount + eventResult.summary.mediaCount
        )
    }

    @MainActor
    func synchronizeEntries(
        with serverURLString: String,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry],
        commands: [SyncLocalCommand]
    ) async throws -> SyncReconcileSummary {
        try await registerChannel(to: serverURLString)
        let commandResult = try await processPendingCommands(
            from: serverURLString,
            modelContext: modelContext,
            tags: tags,
            entries: entries
        )
        let pushSummary = try await pushPendingCommands(
            to: serverURLString,
            modelContext: modelContext,
            tags: tags,
            entries: entries,
            commands: commands
        )

        let summary = SyncReconcileSummary(
            uploadedRecordCount: pushSummary.recordCount,
            uploadedMediaCount: pushSummary.mediaCount,
            restoredEntityCount: commandResult.summary.entityCount,
            restoredRecordCount: commandResult.summary.recordCount,
            restoredMediaCount: commandResult.summary.mediaCount
        )
        markLastSync()
        return summary
    }

    @MainActor
    func pushPendingLocalCommands(
        with serverURLString: String,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry],
        commands: [SyncLocalCommand]
    ) async throws -> SyncPushSummary {
        try await registerChannel(to: serverURLString)
        let summary = try await pushPendingCommands(
            to: serverURLString,
            modelContext: modelContext,
            tags: tags,
            entries: entries,
            commands: commands
        )
        markLastSync()
        return summary
    }

    func fetchLatest(from serverURLString: String) async throws -> SyncBackupPayload {
        let url = try endpoint(serverURLString, path: "/api/backups/latest")
        let request = request(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decode(SyncBackupPayload.self, from: data, context: "latest backup")
    }

    func checkStatus(from serverURLString: String) async throws -> SyncServerStatus {
        let url = try endpoint(serverURLString, path: "/api/status")
        let request = request(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decode(SyncServerStatus.self, from: data, context: "server status")
    }

    func fetchManifest(from serverURLString: String) async throws -> SyncServerManifest {
        let url = try endpoint(serverURLString, path: "/api/manifest")
        let request = request(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decode(SyncServerManifest.self, from: data, context: "server manifest")
    }

    func registerDevice(to serverURLString: String) async throws {
        try await registerChannel(to: serverURLString)
    }

    func registerChannel(to serverURLString: String) async throws {
        try await post(
            ["schemaVersion": 1],
            to: serverURLString,
            path: "/api/channels/register"
        )
    }

    func fetchRestoreState(from serverURLString: String) async throws -> SyncRestoreStatePayload {
        let url = try endpoint(serverURLString, path: "/api/sync/state")
        let request = request(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decode(SyncRestoreStatePayload.self, from: data, context: "restore state")
    }

    func fetchRestoreStateIfPresent(from serverURLString: String) async throws -> SyncRestoreStatePayload? {
        do {
            return try await fetchRestoreState(from: serverURLString)
        } catch SyncError.invalidResponse(let statusCode, _) where statusCode == 404 {
            return nil
        }
    }

    func fetchPendingEvents(from serverURLString: String) async throws -> [SyncDeviceEvent] {
        let url = try endpoint(serverURLString, path: "/api/events/pending")
        let request = request(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decode(SyncPendingEventsPayload.self, from: data, context: "pending events").events
    }

    func fetchPendingCommands(from serverURLString: String) async throws -> [SyncRelayCommand] {
        let url = try endpoint(serverURLString, path: "/api/commands/pending")
        let request = request(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decode(SyncPendingCommandsPayload.self, from: data, context: "pending commands").commands
    }

    func acknowledgeCommands(_ commandIDs: [UUID], to serverURLString: String) async throws {
        guard !commandIDs.isEmpty else { return }
        try await post(
            SyncCommandAckPayload(schemaVersion: 1, commandIDs: commandIDs),
            to: serverURLString,
            path: "/api/commands/ack"
        )
    }

    func acknowledgeEvents(_ eventIDs: [Int64], to serverURLString: String) async throws {
        guard !eventIDs.isEmpty else { return }
        try await post(
            SyncEventAckPayload(schemaVersion: 1, eventIDs: eventIDs),
            to: serverURLString,
            path: "/api/events/ack"
        )
    }

    @MainActor
    func deleteEntry(
        id: UUID,
        on serverURLString: String
    ) async throws {
        try await post(
            SyncDeleteEntryPayload(schemaVersion: 1, entryID: id, deletedAt: Date()),
            to: serverURLString,
            path: "/api/sync/entry/\(id.uuidString)/delete"
        )
    }

    func fetchEntryUploadPayload(id: UUID, from serverURLString: String) async throws -> SyncEntryUploadPayload {
        let url = try endpoint(serverURLString, path: "/api/sync/entry/\(id.uuidString)")
        let request = request(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decode(SyncEntryUploadPayload.self, from: data, context: "entry \(id.uuidString)")
    }

    @MainActor
    private func pushPendingCommands(
        to serverURLString: String,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry],
        commands: [SyncLocalCommand]
    ) async throws -> SyncPushSummary {
        let pendingCommands = commands
            .filter(\.isPending)
            .sorted { $0.createdAt < $1.createdAt }
        guard !pendingCommands.isEmpty else {
            return SyncPushSummary(entityCount: 0, recordCount: 0, mediaCount: 0)
        }

        let tagByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id.uuidString, $0) })
        let entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id.uuidString, $0) })
        var acceptedRelayCommands: [SyncRelayCommand] = []
        var mediaCount = 0

        for command in pendingCommands {
            do {
                guard let relayCommand = try relayCommand(
                    for: command,
                    tags: tagByID,
                    entries: entryByID
                ) else {
                    command.markSent()
                    continue
                }

                let response: SyncRelayCommandBatchResponse = try await postReturning(
                    SyncRelayCommandBatch(schemaVersion: 1, commands: [relayCommand]),
                    to: serverURLString,
                    path: "/api/commands/batch",
                    responseType: SyncRelayCommandBatchResponse.self,
                    context: "command batch"
                )

                if response.processedCommandIDs.contains(command.id) {
                    command.markSent()
                    acceptedRelayCommands.append(relayCommand)
                    if relayCommand.type == SyncLocalCommandType.entryUpsert.rawValue {
                        mediaCount += relayCommand.payload.entryUpload?.media.count ?? 0
                    }
                } else {
                    command.markFailed(SyncError.invalidResponse(
                        statusCode: nil,
                        body: "Relay did not acknowledge command \(command.id.uuidString)."
                    ))
                }
            } catch {
                command.markFailed(error)
            }
        }

        try modelContext.save()

        let tagCount = acceptedRelayCommands.filter { $0.type == SyncLocalCommandType.tagUpsert.rawValue || $0.type == SyncLocalCommandType.tagDelete.rawValue }.count
        let recordCount = acceptedRelayCommands.count - tagCount
        return SyncPushSummary(entityCount: tagCount, recordCount: recordCount, mediaCount: mediaCount)
    }

    private func relayCommand(
        for command: SyncLocalCommand,
        tags: [String: JournalTag],
        entries: [String: JournalEntry]
    ) throws -> SyncRelayCommand? {
        guard let type = command.type else { return nil }
        let channel = JournalDevice.current()
        let payload: SyncRelayCommandPayload

        switch type {
        case .entryUpsert:
            guard let entry = entries[command.subjectID] else { return nil }
            let media = try mediaBlobs(for: entry)
            payload = SyncRelayCommandPayload(entryUpload: SyncEntryUploadPayload(
                schemaVersion: 1,
                appVersion: appVersion,
                uploadedAt: Date(),
                entry: JournalEntrySnapshot(entry: entry),
                media: media
            ), entryID: entry.id, entryVersion: entry.version)
        case .entryDelete:
            guard let entryID = UUID(uuidString: command.subjectID) else { return nil }
            payload = SyncRelayCommandPayload(entryID: entryID)
        case .tagUpsert:
            guard let tag = tags[command.subjectID] else { return nil }
            payload = SyncRelayCommandPayload(tag: JournalTagSnapshot(tag: tag))
        case .tagDelete:
            guard let tagID = UUID(uuidString: command.subjectID) else { return nil }
            payload = SyncRelayCommandPayload(tagID: tagID)
        }

        return SyncRelayCommand(
            id: command.id,
            schemaVersion: 1,
            type: type.rawValue,
            subjectID: command.subjectID,
            sourceChannelID: channel.id,
            sourceChannelEmoji: channel.emoji,
            createdAt: command.createdAt,
            payload: payload
        )
    }

    private func pushMirrorState(
        to serverURLString: String,
        tags: [JournalTag],
        entries: [JournalEntry],
        manifest: SyncServerManifest?
    ) async throws -> SyncPushSummary {
        let uploadedEntryIDs = Set(manifest?.entryIDs ?? [])
        let uploadedMediaIDs = Set(manifest?.mediaIDs ?? [])
        let tagSnapshots = tags.map(JournalTagSnapshot.init(tag:))
        let entryIDs = entries.map(\.id)

        let statePayload = SyncStatePayload(
            schemaVersion: 1,
            appVersion: appVersion,
            uploadedAt: Date(),
            tags: tagSnapshots,
            entryIDs: entryIDs
        )
        try await post(statePayload, to: serverURLString, path: "/api/sync/state")

        var changedEntryIDs = Set<UUID>()
        for entry in entries {
            let mediaIDs = entry.mediaItems.map(\.id)
            let hasMissingMedia = mediaIDs.contains { !uploadedMediaIDs.contains($0) }
            if !uploadedEntryIDs.contains(entry.id) || hasMissingMedia {
                changedEntryIDs.insert(entry.id)
            }
        }

        let changedEntries = entries.filter { changedEntryIDs.contains($0.id) }
        var uploadedMediaCount = 0
        for entry in changedEntries {
            let media = try mediaBlobs(for: entry)
            uploadedMediaCount += media.count
            let entryPayload = SyncEntryUploadPayload(
                schemaVersion: 1,
                appVersion: appVersion,
                uploadedAt: Date(),
                entry: JournalEntrySnapshot(entry: entry),
                media: media
            )
            try await post(entryPayload, to: serverURLString, path: "/api/sync/entry")
        }

        return SyncPushSummary(
            entityCount: tags.count,
            recordCount: changedEntries.count,
            mediaCount: uploadedMediaCount
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank ?? "\(data.count) bytes"
            throw SyncError.invalidResponse(
                statusCode: nil,
                body: "Could not decode \(context): \(error.localizedDescription). Body: \(body.prefix(500))"
            )
        }
    }

    private func post<T: Encodable>(_ payload: T, to serverURLString: String, path: String) async throws {
        let url = try endpoint(serverURLString, path: path)

        var request = request(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    private func postReturning<T: Encodable, U: Decodable>(
        _ payload: T,
        to serverURLString: String,
        path: String,
        responseType: U.Type,
        context: String
    ) async throws -> U {
        let url = try endpoint(serverURLString, path: path)

        var request = request(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decode(responseType, from: data, context: context)
    }

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let device = JournalDevice.current()
        request.setValue(device.id, forHTTPHeaderField: "X-Exeligmos-Device-ID")
        request.setValue(percentEncodedHeader(device.name), forHTTPHeaderField: "X-Exeligmos-Device-Name")
        request.setValue(percentEncodedHeader(device.emoji), forHTTPHeaderField: "X-Exeligmos-Device-Emoji")
        return request
    }

    private func percentEncodedHeader(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func mediaBlobs(for entry: JournalEntry) throws -> [SyncMediaBlob] {
        var seenMediaIDs = Set<UUID>()
        return try entry.mediaItems.compactMap { item -> SyncMediaBlob? in
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
    }

    @MainActor
    private func restoreEntries(
        state: SyncRestoreStatePayload,
        from serverURLString: String,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry]
    ) async throws -> SyncRestoreSummary {
        var existingTags = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        var existingEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var restoredMediaCount = 0
        var restoredEntryCount = 0

        for snapshot in state.tags {
            if let tag = existingTags[snapshot.id] {
                apply(snapshot, to: tag)
            } else {
                let tag = JournalTag(snapshot: snapshot)
                modelContext.insert(tag)
                existingTags[snapshot.id] = tag
            }
        }
        _ = JournalTag.ensureUniqueCompactIDs(in: Array(existingTags.values))

        let entryIDsToFetch = state.entryIDs.filter { entryID in
            entryNeedsRestore(existingEntries[entryID])
        }

        for (index, entryID) in entryIDsToFetch.enumerated() {
            let payload: SyncEntryUploadPayload
            do {
                payload = try await fetchEntryUploadPayload(id: entryID, from: serverURLString)
            } catch SyncError.invalidResponse(let statusCode, _) where statusCode == 404 {
                continue
            }
            let restoredMedia = try restoreMedia(payload.media)
            let snapshot = payload.entry
            let mediaItems = snapshot.mediaItems.compactMap { item in
                restoredMedia[item.id]
            }

            if let entry = existingEntries[snapshot.id] {
                apply(snapshot, mediaItems: mediaItems, to: entry)
            } else {
                let entry = JournalEntry(snapshot: snapshot, mediaItems: mediaItems)
                modelContext.insert(entry)
                existingEntries[snapshot.id] = entry
            }

            restoredEntryCount += 1
            restoredMediaCount += restoredMedia.count

            if index % 10 == 9 {
                try modelContext.save()
            }
        }

        try modelContext.save()
        return SyncRestoreSummary(
            entityCount: state.tags.count,
            recordCount: restoredEntryCount,
            mediaCount: restoredMediaCount
        )
    }

    @MainActor
    private func processPendingEvents(
        from serverURLString: String,
        modelContext: ModelContext,
        entries: [JournalEntry]
    ) async throws -> SyncEventProcessingResult {
        let events = try await fetchPendingEvents(from: serverURLString)
        guard !events.isEmpty else {
            return SyncEventProcessingResult(
                summary: SyncRestoreSummary(entityCount: 0, recordCount: 0, mediaCount: 0),
                deletedEntryIDs: []
            )
        }

        var existingEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var processedEventIDs: [Int64] = []
        var deletedEntryIDs = Set<UUID>()
        var restoredEntryCount = 0
        var restoredMediaCount = 0

        for event in events {
            switch event.type {
            case "record-posted":
                guard let entryID = event.entryID, entryNeedsRestore(existingEntries[entryID]) else {
                    processedEventIDs.append(event.id)
                    continue
                }
                let payload: SyncEntryUploadPayload
                do {
                    payload = try await fetchEntryUploadPayload(id: entryID, from: serverURLString)
                } catch SyncError.invalidResponse(let statusCode, _) where statusCode == 404 {
                    processedEventIDs.append(event.id)
                    continue
                }
                let restoredMedia = try restoreMedia(payload.media)
                let snapshot = payload.entry
                let mediaItems = snapshot.mediaItems.compactMap { item in restoredMedia[item.id] }
                if let entry = existingEntries[snapshot.id] {
                    apply(snapshot, mediaItems: mediaItems, to: entry)
                } else {
                    let entry = JournalEntry(snapshot: snapshot, mediaItems: mediaItems)
                    modelContext.insert(entry)
                    existingEntries[snapshot.id] = entry
                    restoredEntryCount += 1
                }
                restoredMediaCount += restoredMedia.count
                processedEventIDs.append(event.id)

            case "record-deleted":
                if let entryID = event.entryID, let entry = existingEntries[entryID] {
                    let mediaItems = entry.mediaItems
                    modelContext.delete(entry)
                    mediaItems.forEach(MediaStorage.delete)
                    existingEntries.removeValue(forKey: entryID)
                    deletedEntryIDs.insert(entryID)
                }
                processedEventIDs.append(event.id)

            default:
                processedEventIDs.append(event.id)
            }
        }

        try modelContext.save()
        try await acknowledgeEvents(processedEventIDs, to: serverURLString)
        return SyncEventProcessingResult(
            summary: SyncRestoreSummary(entityCount: 0, recordCount: restoredEntryCount, mediaCount: restoredMediaCount),
            deletedEntryIDs: deletedEntryIDs
        )
    }

    @MainActor
    private func processPendingCommands(
        from serverURLString: String,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry]
    ) async throws -> SyncEventProcessingResult {
        let commands = try await fetchPendingCommands(from: serverURLString)
        guard !commands.isEmpty else {
            return SyncEventProcessingResult(
                summary: SyncRestoreSummary(entityCount: 0, recordCount: 0, mediaCount: 0),
                deletedEntryIDs: []
            )
        }

        var existingTags = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        var existingEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var processedCommandIDs: [UUID] = []
        var deletedEntryIDs = Set<UUID>()
        var changedTagCount = 0
        var changedEntryCount = 0
        var restoredMediaCount = 0
        let currentChannelID = JournalDevice.current().id

        for command in commands {
            switch SyncLocalCommandType(rawValue: command.type) {
            case .entryUpsert:
                let commandEntryID = command.payload.entryID ?? UUID(uuidString: command.subjectID)
                if let commandEntryID,
                   let existingEntry = existingEntries[commandEntryID],
                   !entryNeedsRestore(existingEntry) {
                    let localVersionIsCurrent = command.payload.entryVersion.map { existingEntry.version >= $0 } ?? true
                    if command.sourceChannelID == currentChannelID || localVersionIsCurrent {
                        processedCommandIDs.append(command.id)
                        continue
                    }
                }

                let payload: SyncEntryUploadPayload
                do {
                    payload = try await resolvedEntryUploadPayload(
                        command: command,
                        from: serverURLString
                    )
                } catch SyncError.invalidResponse(let statusCode, _) where statusCode == 404 {
                    processedCommandIDs.append(command.id)
                    continue
                }
                let restoredMedia = try restoreMedia(payload.media)
                let snapshot = payload.entry
                let mediaItems = snapshot.mediaItems.compactMap { item in restoredMedia[item.id] }
                if let entry = existingEntries[snapshot.id] {
                    apply(snapshot, mediaItems: mediaItems, to: entry)
                } else {
                    let entry = JournalEntry(snapshot: snapshot, mediaItems: mediaItems)
                    modelContext.insert(entry)
                    existingEntries[snapshot.id] = entry
                }
                changedEntryCount += 1
                restoredMediaCount += restoredMedia.count
                processedCommandIDs.append(command.id)

            case .entryDelete:
                let entryID = command.payload.entryID ?? UUID(uuidString: command.subjectID)
                if let entryID, let entry = existingEntries[entryID] {
                    let mediaItems = entry.mediaItems
                    modelContext.delete(entry)
                    mediaItems.forEach(MediaStorage.delete)
                    existingEntries.removeValue(forKey: entryID)
                    deletedEntryIDs.insert(entryID)
                }
                changedEntryCount += 1
                processedCommandIDs.append(command.id)

            case .tagUpsert:
                if let snapshot = command.payload.tag {
                    if let tag = existingTags[snapshot.id] {
                        apply(snapshot, to: tag)
                    } else {
                        let tag = JournalTag(snapshot: snapshot)
                        modelContext.insert(tag)
                        existingTags[snapshot.id] = tag
                    }
                    _ = JournalTag.ensureUniqueCompactIDs(in: Array(existingTags.values))
                    changedTagCount += 1
                }
                processedCommandIDs.append(command.id)

            case .tagDelete:
                let tagID = command.payload.tagID ?? UUID(uuidString: command.subjectID)
                if let tagID, let tag = existingTags[tagID] {
                    let compactID = tag.compactID
                    modelContext.delete(tag)
                    existingTags.removeValue(forKey: tagID)
                    for entry in existingEntries.values where entry.tagIDs.contains(compactID) {
                        entry.tagIDs = entry.tagIDs.filter { $0 != compactID }
                    }
                    changedTagCount += 1
                }
                processedCommandIDs.append(command.id)

            case .none:
                processedCommandIDs.append(command.id)
            }
        }

        try modelContext.save()
        try await acknowledgeCommands(processedCommandIDs, to: serverURLString)
        return SyncEventProcessingResult(
            summary: SyncRestoreSummary(entityCount: changedTagCount, recordCount: changedEntryCount, mediaCount: restoredMediaCount),
            deletedEntryIDs: deletedEntryIDs
        )
    }

    private func resolvedEntryUploadPayload(
        command: SyncRelayCommand,
        from serverURLString: String
    ) async throws -> SyncEntryUploadPayload {
        if let payload = command.payload.entryUpload {
            return payload
        }
        if let entryID = command.payload.entryID ?? UUID(uuidString: command.subjectID) {
            return try await fetchEntryUploadPayload(id: entryID, from: serverURLString)
        }
        throw SyncError.invalidResponse(statusCode: nil, body: "Entry command \(command.id) is missing an entry id.")
    }

    private func entryNeedsRestore(_ entry: JournalEntry?) -> Bool {
        guard let entry else { return true }
        return entry.mediaItems.contains { item in
            !FileManager.default.fileExists(atPath: MediaStorage.url(for: item).path)
        }
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

    private func apply(_ snapshot: JournalTagSnapshot, to tag: JournalTag) {
        tag.createdAt = snapshot.createdAt
        tag.updatedAt = snapshot.updatedAt
        tag.name = snapshot.name
        tag.emoji = snapshot.emoji
        tag.anchorDate = snapshot.anchorDate
        tag.saros = snapshot.saros
        tag.notes = snapshot.notes
        tag.sourceEntityID = snapshot.sourceEntityID
        tag.isPrime = snapshot.isPrime
        tag.colorHex = snapshot.colorHex
        tag.octalID = JournalTag.normalizedOctalID(snapshot.octalID) ?? tag.octalID
    }

    private func apply(_ snapshot: JournalEntrySnapshot, mediaItems: [JournalMediaItem], to entry: JournalEntry) {
        entry.createdAt = snapshot.createdAt
        entry.eventDate = snapshot.eventDate
        entry.unixTimestamp = snapshot.unixTimestamp
        entry.version = max(snapshot.version ?? entry.version, 1)
        entry.text = snapshot.text
        entry.emoji = snapshot.emoji
        entry.mediaItems = mediaItems
        entry.tagIDs = snapshot.tagIDs ?? []
        entry.context = snapshot.context
        entry.latitude = snapshot.latitude
        entry.longitude = snapshot.longitude
        entry.sourceRecordID = snapshot.sourceRecordID
        entry.sourceDeviceID = snapshot.sourceDeviceID
        entry.sourceDeviceEmoji = snapshot.sourceDeviceEmoji
        entry.sourceDeviceName = snapshot.sourceDeviceName
        entry.weatherCode = snapshot.weatherCode
        entry.weatherEmoji = snapshot.weatherEmoji
        entry.temperatureC = snapshot.temperatureC
        entry.updatedAt = snapshot.updatedAt
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
        case "caf":
            "audio/x-caf"
        case "mov":
            "video/quicktime"
        case "mp4":
            "video/mp4"
        default:
            "application/octet-stream"
        }
    }

    private func markLastSync() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: JournalSettings.lastSyncAtKey)
    }

    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                if let date = Self.iso8601WithFractionalSeconds.date(from: string)
                    ?? Self.iso8601.date(from: string) {
                    return date
                }
            }
            if let value = try? container.decode(Double.self) {
                let seconds = value > 10_000_000_000 ? value / 1_000 : value
                return Date(timeIntervalSince1970: seconds)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 date string or numeric timestamp."
            )
        }
        return decoder
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension JournalTag {
    convenience init(snapshot: JournalTagSnapshot) {
        self.init(
            id: snapshot.id,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            name: snapshot.name,
            emoji: snapshot.emoji,
            anchorDate: snapshot.anchorDate,
            saros: snapshot.saros,
            notes: snapshot.notes,
            sourceEntityID: snapshot.sourceEntityID,
            isPrime: snapshot.isPrime,
            colorHex: snapshot.colorHex,
            octalID: snapshot.octalID
        )
    }
}

private extension JournalEntry {
    convenience init(snapshot: JournalEntrySnapshot, mediaItems: [JournalMediaItem]) {
        self.init(
            id: snapshot.id,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            eventDate: snapshot.eventDate,
            version: snapshot.version ?? 1,
            text: snapshot.text,
            emoji: snapshot.emoji,
            mediaItems: mediaItems,
            context: snapshot.context,
            tagIDs: snapshot.tagIDs ?? [],
            latitude: snapshot.latitude,
            longitude: snapshot.longitude,
            sourceRecordID: snapshot.sourceRecordID,
            sourceDeviceID: snapshot.sourceDeviceID,
            sourceDeviceEmoji: snapshot.sourceDeviceEmoji,
            sourceDeviceName: snapshot.sourceDeviceName,
            weatherCode: snapshot.weatherCode,
            weatherEmoji: snapshot.weatherEmoji,
            temperatureC: snapshot.temperatureC
        )
        unixTimestamp = snapshot.unixTimestamp
    }
}

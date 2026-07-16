import CryptoKit
import Foundation
import Security
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

    /// Automatic delivery gets one attempt per local mutation body. A failed
    /// command remains pending for manual retry, but cannot spin the app in a
    /// tight rejection loop.
    var isEligibleForAutomaticSync: Bool {
        isPending && attemptCount == 0
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

    /// A server acknowledgement with `status: failed` is a completed logical
    /// mutation, so its receipt must not be reused for a corrected retry.
    func prepareRetry(afterServerRejection error: Error) {
        id = UUID()
        markFailed(error)
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
            // Saving the subject again changes the mutation body. Give that new
            // logical mutation its own receipt while retaining an ID across
            // transport retries where no newer local edit was queued.
            existing.id = UUID()
            existing.updatedAt = Date()
            existing.attemptCount = 0
            existing.lastError = nil
            return
        }

        modelContext.insert(SyncLocalCommand(type: type, subjectID: subjectID))
    }

    static func pendingInPushOrder(_ commands: [SyncLocalCommand]) -> [SyncLocalCommand] {
        commands.filter(\.isPending).sorted { lhs, rhs in
            let lhsPriority = lhs.type == .tagUpsert ? 0 : 1
            let rhsPriority = rhs.type == .tagUpsert ? 0 : 1
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

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

struct SyncServerStatus: Codable, Hashable {
    let ok: Bool
    let hasBackup: Bool
    let exportTimestamp: Date?
    let entityCount: Int
    let recordCount: Int
    let mediaCount: Int
}

struct SyncAuthenticatedUser: Codable, Hashable, Sendable {
    let id: UUID
    let login: String
    let displayName: String
    let createdAt: Date
    let updatedAt: Date
}

enum SyncAuthenticationState: Hashable {
    case signedOut
    case signedIn(SyncAuthenticatedUser)
}

/// The offline-first iOS client for the Exeligmos relay.
///
/// Passwords are exchanged only by `login`/`register`. Access and rotating refresh
/// tokens live in the Keychain. Local CRUD is recorded before network delivery.
/// Sync replays the ordered command feed and persists its opaque cursor only after
/// the complete page has committed to SwiftData.
final class SyncService {
    enum SyncError: LocalizedError {
        case invalidServerURL
        case authenticationRequired
        case invalidAccountInput(String)
        case credentialStorage(status: OSStatus)
        case invalidResponse(statusCode: Int?, body: String)
        case unsupportedPrivateRecord(UUID)
        case missingResourceETag(String)
        case mediaFileMissing(String)
        case mediaDigestMismatch(UUID)
        case crossOriginCredentialURL(URL)
        case localStoreOwnerMismatch(
            boundServer: String,
            boundUserID: UUID,
            authenticatedServer: String,
            authenticatedUserID: UUID
        )
        case invalidLocalStoreOwnerBinding

        var errorDescription: String? {
            switch self {
            case .invalidServerURL:
                "Enter an Exeligmos server URL such as https://journal.example.com."
            case .authenticationRequired:
                "Sign in to this Exeligmos server before syncing."
            case .invalidAccountInput(let detail):
                detail
            case .credentialStorage(let status):
                "Secure credential storage failed with status \(status)."
            case .invalidResponse(let statusCode, let body):
                if let statusCode {
                    "Exeligmos returned HTTP \(statusCode): \(body)"
                } else {
                    "Exeligmos returned an invalid response: \(body)"
                }
            case .unsupportedPrivateRecord(let id):
                "Private record \(id.uuidString) requires a configured journal encryption key."
            case .missingResourceETag(let resource):
                "Cannot safely update \(resource) because its server ETag is unavailable."
            case .mediaFileMissing(let path):
                "A record references a missing media file at \(path)."
            case .mediaDigestMismatch(let id):
                "Downloaded media \(id.uuidString) failed SHA-256 verification."
            case .crossOriginCredentialURL(let url):
                "Refusing to send Exeligmos credentials to a different origin: \(url.absoluteString)"
            case .localStoreOwnerMismatch(
                let boundServer,
                let boundUserID,
                let authenticatedServer,
                let authenticatedUserID
            ):
                "This local journal is bound to \(boundUserID.uuidString) at \(boundServer), not " +
                    "\(authenticatedUserID.uuidString) at \(authenticatedServer). Reset or migrate the local " +
                    "journal before syncing another account."
            case .invalidLocalStoreOwnerBinding:
                "The local journal owner binding is damaged. Reset or migrate local data before syncing."
            }
        }
    }

    private let urlSession: URLSession
    private let credentials: SyncCredentialVault
    private let stateStore: SyncV2StateStore

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        self.credentials = SyncCredentialVault()
        self.stateStore = SyncV2StateStore()
    }

    // MARK: - Authentication

    @discardableResult
    func login(
        to serverURLString: String,
        login: String,
        password: String
    ) async throws -> SyncAuthenticatedUser {
        let server = try serverBaseURL(serverURLString)
        let response: SyncAuthSessionResponse = try await sendJSON(
            SyncLoginRequest(
                login: login.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            ),
            to: server,
            path: "/v1/auth/login",
            method: "POST",
            expectedStatus: [200]
        )
        try await credentials.save(response, for: server.absoluteString)
        try await ensureCurrentDevice(on: server, user: response.user)
        return response.user
    }

    @discardableResult
    func register(
        on serverURLString: String,
        login: String,
        password: String,
        displayName: String? = nil,
        inviteCode: String? = nil
    ) async throws -> SyncAuthenticatedUser {
        let server = try serverBaseURL(serverURLString)
        let input = try SyncRegistrationInput.validated(
            login: login,
            password: password,
            displayName: displayName,
            inviteCode: inviteCode
        )
        let response: SyncAuthSessionResponse = try await sendJSON(
            input,
            to: server,
            path: "/v1/auth/register",
            method: "POST",
            expectedStatus: [201]
        )
        try await credentials.save(response, for: server.absoluteString)
        try await ensureCurrentDevice(on: server, user: response.user)
        return response.user
    }

    func logout(from serverURLString: String) async throws {
        let server = try serverBaseURL(serverURLString)
        let serverKey = server.absoluteString
        guard try await credentials.storedSession(for: serverKey) != nil else { return }

        do {
            // Refresh first when necessary, then reload the rotating refresh
            // token so the bearer and body always describe the same family.
            let accessToken = try await accessToken(for: server)
            guard let current = try await credentials.storedSession(for: serverKey) else { return }
            let request = try jsonRequest(
                SyncRefreshRequest(refreshToken: current.refreshToken),
                server: server,
                path: "/v1/auth/logout",
                method: "POST"
            )
            var authorizedRequest = request
            authorizedRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            try requireSameOrigin(authorizedRequest.url, as: server)
            let (data, response) = try await urlSession.data(for: authorizedRequest)
            try require(response, data: data, expectedStatus: [204])
        } catch {
            try await credentials.clear(for: serverKey)
            throw error
        }
        try await credentials.clear(for: serverKey)
    }

    func authenticationState(for serverURLString: String) async throws -> SyncAuthenticationState {
        let server = try serverBaseURL(serverURLString)
        guard let stored = try await credentials.storedSession(for: server.absoluteString) else {
            return .signedOut
        }
        return .signedIn(stored.user)
    }

    // MARK: - Existing application integration

    func checkStatus(from serverURLString: String) async throws -> SyncServerStatus {
        let server = try serverBaseURL(serverURLString)
        var request = URLRequest(url: try endpoint(server, path: "/health/ready"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await urlSession.data(for: request)
        try require(response, data: data, expectedStatus: [200])
        return SyncServerStatus(
            ok: true,
            hasBackup: false,
            exportTimestamp: nil,
            entityCount: 0,
            recordCount: 0,
            mediaCount: 0
        )
    }

    func registerDevice(to serverURLString: String) async throws {
        try await registerChannel(to: serverURLString)
    }

    func registerChannel(to serverURLString: String) async throws {
        let server = try serverBaseURL(serverURLString)
        let stored = try await requireStoredSession(for: server)
        try await ensureCurrentDevice(on: server, user: stored.user)
    }

    @MainActor
    func synchronizeEntries(
        with serverURLString: String,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry],
        commands: [SyncLocalCommand]
    ) async throws -> SyncReconcileSummary {
        let server = try serverBaseURL(serverURLString)
        let stored = try await requireStoredSession(for: server)
        let deviceID = try await ensureCurrentDevice(on: server, user: stored.user)
        try stateStore.bindLocalStoreIfNeeded(server: server, userID: stored.user.id)

        var tagByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        var entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let firstPull = try await pullChanges(
            from: server,
            user: stored.user,
            modelContext: modelContext,
            tagByID: &tagByID,
            entryByID: &entryByID,
            commands: commands
        )
        let pushed = try await pushPendingCommands(
            to: server,
            user: stored.user,
            deviceID: deviceID,
            modelContext: modelContext,
            tags: Array(tagByID.values),
            entries: Array(entryByID.values),
            commands: commands
        )
        let secondPull = try await pullChanges(
            from: server,
            user: stored.user,
            modelContext: modelContext,
            tagByID: &tagByID,
            entryByID: &entryByID,
            commands: commands
        )

        markLastSync()
        return SyncReconcileSummary(
            uploadedRecordCount: pushed.recordCount,
            uploadedMediaCount: pushed.mediaCount,
            restoredEntityCount: firstPull.entityCount + secondPull.entityCount,
            restoredRecordCount: firstPull.recordCount + secondPull.recordCount,
            restoredMediaCount: firstPull.mediaCount + secondPull.mediaCount
        )
    }

    @MainActor
    func pushPendingLocalCommands(
        with serverURLString: String,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry],
        commands: [SyncLocalCommand]
    ) async throws -> SyncPushSummary {
        let server = try serverBaseURL(serverURLString)
        let stored = try await requireStoredSession(for: server)
        let deviceID = try await ensureCurrentDevice(on: server, user: stored.user)
        try stateStore.bindLocalStoreIfNeeded(server: server, userID: stored.user.id)
        let result = try await pushPendingCommands(
            to: server,
            user: stored.user,
            deviceID: deviceID,
            modelContext: modelContext,
            tags: tags,
            entries: entries,
            commands: commands
        )
        markLastSync()
        return result
    }

    // MARK: - Change feed

    @MainActor
    private func pullChanges(
        from server: URL,
        user: SyncAuthenticatedUser,
        modelContext: ModelContext,
        tagByID: inout [UUID: JournalTag],
        entryByID: inout [UUID: JournalEntry],
        commands: [SyncLocalCommand]
    ) async throws -> SyncRestoreSummary {
        var cursor = stateStore.cursor(server: server, userID: user.id)
        var didReconcileExpiredCursor = false
        var entityCount = 0
        var recordCount = 0
        var mediaCount = 0
        let pending = SyncPendingMutationIDs(commands: commands)

        if cursor == nil {
            let restored = try await reconcileFullCollections(
                from: server,
                user: user,
                modelContext: modelContext,
                tagByID: &tagByID,
                entryByID: &entryByID,
                commands: commands,
                pending: pending
            )
            entityCount += restored.entityCount
            recordCount += restored.recordCount
            mediaCount += restored.mediaCount
        }

        while true {
            var components = URLComponents(url: try endpoint(server, path: "/v1/sync/changes"), resolvingAgainstBaseURL: false)
            var queryItems = [URLQueryItem(name: "limit", value: "200")]
            if let cursor {
                queryItems.append(URLQueryItem(name: "cursor", value: cursor))
            }
            components?.queryItems = queryItems
            guard let url = components?.url else { throw SyncError.invalidServerURL }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await authorizedData(request, server: server)
            if response.statusCode == 410, !didReconcileExpiredCursor {
                // Do not silently restart at the retained prefix. Reconcile the
                // complete owner collections first, and only clear the durable
                // cursor once that snapshot has committed successfully.
                let restored = try await reconcileFullCollections(
                    from: server,
                    user: user,
                    modelContext: modelContext,
                    tagByID: &tagByID,
                    entryByID: &entryByID,
                    commands: commands,
                    pending: pending
                )
                entityCount += restored.entityCount
                recordCount += restored.recordCount
                mediaCount += restored.mediaCount
                stateStore.setCursor(nil, server: server, userID: user.id)
                cursor = nil
                didReconcileExpiredCursor = true
                continue
            }
            try require(response, data: data, expectedStatus: [200])
            let page = try decode(SyncChangePage.self, from: data, context: "sync change page")

            for change in page.data {
                if change.operation == "delete" {
                    stateStore.removeETag(
                        resourceType: change.resourceType,
                        resourceID: change.resourceID,
                        server: server,
                        userID: user.id
                    )
                } else {
                    stateStore.setETag(
                        change.etag,
                        resourceType: change.resourceType,
                        resourceID: change.resourceID,
                        server: server,
                        userID: user.id
                    )
                }

                switch (change.resourceType, change.operation) {
                case ("tag", "upsert"):
                    guard let resource = change.resource else { continue }
                    if pending.tagDeletes.contains(change.resourceID) {
                        removeLocalTag(
                            change.resourceID,
                            modelContext: modelContext,
                            tagByID: &tagByID,
                            entryByID: &entryByID
                        )
                        continue
                    }
                    if pending.tagUpserts.contains(change.resourceID), tagByID[change.resourceID] != nil {
                        continue
                    }
                    let remote = try decodeValue(SyncTagResource.self, from: resource, context: "tag change")
                    if let existing = tagByID[remote.id] {
                        apply(remote, to: existing)
                    } else {
                        let tag = makeTag(from: remote, existing: Array(tagByID.values))
                        modelContext.insert(tag)
                        tagByID[tag.id] = tag
                    }
                    entityCount += 1

                case ("tag", "delete"):
                    if pending.tagUpserts.contains(change.resourceID) {
                        continue
                    }
                    removeLocalTag(
                        change.resourceID,
                        modelContext: modelContext,
                        tagByID: &tagByID,
                        entryByID: &entryByID
                    )
                    markCommandsSuperseded(commands, type: .tagDelete, subjectID: change.resourceID)
                    entityCount += 1

                case ("record", "upsert"):
                    guard let resource = change.resource else { continue }
                    if pending.entryDeletes.contains(change.resourceID) {
                        removeLocalEntry(change.resourceID, modelContext: modelContext, entryByID: &entryByID)
                        continue
                    }
                    if pending.entryUpserts.contains(change.resourceID), entryByID[change.resourceID] != nil {
                        continue
                    }
                    let remote = try decodeValue(SyncRecordResource.self, from: resource, context: "record change")
                    guard remote.visibility == "public" else {
                        // Keep the cursor moving, but never destroy a local projection in
                        // response to an upsert the client cannot decrypt.
                        continue
                    }
                    let downloaded = try await restoreMedia(
                        remote.media,
                        existing: entryByID[remote.id]?.mediaItems ?? [],
                        preferredTypes: SyncV2PayloadMapper.mediaTypes(from: remote),
                        server: server
                    )
                    mediaCount += downloaded.downloadCount
                    let snapshot = try SyncV2PayloadMapper.entrySnapshot(
                        from: remote,
                        localMedia: downloaded.items,
                        tags: tagByID
                    )
                    if let existing = entryByID[remote.id] {
                        apply(snapshot, to: existing)
                    } else {
                        let entry = JournalEntry(syncSnapshot: snapshot)
                        modelContext.insert(entry)
                        entryByID[entry.id] = entry
                    }
                    recordCount += 1

                case ("record", "delete"):
                    if pending.entryUpserts.contains(change.resourceID) {
                        continue
                    }
                    removeLocalEntry(change.resourceID, modelContext: modelContext, entryByID: &entryByID)
                    markCommandsSuperseded(commands, type: .entryDelete, subjectID: change.resourceID)
                    recordCount += 1

                default:
                    // Events, templates, devices, media, and user changes have no local
                    // SwiftData projection yet. They are still consumed in strict order.
                    continue
                }
            }

            try modelContext.save()
            stateStore.setCursor(page.nextCursor, server: server, userID: user.id)
            cursor = page.nextCursor
            guard page.hasMore else { break }
        }

        return SyncRestoreSummary(
            entityCount: entityCount,
            recordCount: recordCount,
            mediaCount: mediaCount
        )
    }

    /// Merges relay snapshots into the local SwiftData collections. A missing
    /// server row never means deletion: only an explicit delete command from
    /// the ordered feed may remove local data.
    @MainActor
    private func reconcileFullCollections(
        from server: URL,
        user: SyncAuthenticatedUser,
        modelContext: ModelContext,
        tagByID: inout [UUID: JournalTag],
        entryByID: inout [UUID: JournalEntry],
        commands: [SyncLocalCommand],
        pending: SyncPendingMutationIDs
    ) async throws -> SyncRestoreSummary {
        var entityCount = 0
        var recordCount = 0
        var mediaCount = 0
        var tagCursor: String?

        while true {
            let url = try collectionPageURL(
                server: server,
                path: "/v1/tags",
                limit: 200,
                cursor: tagCursor
            )
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await authorizedData(request, server: server)
            try require(response, data: data, expectedStatus: [200])
            let page = try decode(
                SyncCollectionPage<SyncTagResource>.self,
                from: data,
                context: "tag collection snapshot"
            )

            for remote in page.data {
                stateStore.setETag(
                    resourceETag(type: "tag", id: remote.id, revision: remote.revision),
                    resourceType: "tag",
                    resourceID: remote.id,
                    server: server,
                    userID: user.id
                )
                if pending.tagDeletes.contains(remote.id) {
                    removeLocalTag(
                        remote.id,
                        modelContext: modelContext,
                        tagByID: &tagByID,
                        entryByID: &entryByID
                    )
                    continue
                }
                if pending.tagUpserts.contains(remote.id), tagByID[remote.id] != nil {
                    continue
                }
                if let existing = tagByID[remote.id] {
                    apply(remote, to: existing)
                } else {
                    let tag = makeTag(from: remote, existing: Array(tagByID.values))
                    modelContext.insert(tag)
                    tagByID[tag.id] = tag
                }
                entityCount += 1
            }

            guard page.hasMore else { break }
            guard let next = page.nextCursor?.nilIfBlank, next != tagCursor else {
                throw SyncError.invalidResponse(
                    statusCode: nil,
                    body: "Tag collection has more data but no advancing cursor."
                )
            }
            tagCursor = next
        }

        var recordCursor: String?
        while true {
            let url = try collectionPageURL(
                server: server,
                path: "/v1/records",
                limit: 25,
                cursor: recordCursor
            )
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await authorizedData(request, server: server)
            try require(response, data: data, expectedStatus: [200])
            let page = try decode(
                SyncCollectionPage<SyncRecordResource>.self,
                from: data,
                context: "record collection snapshot"
            )

            for remote in page.data {
                stateStore.setETag(
                    resourceETag(type: "record", id: remote.id, revision: remote.revision),
                    resourceType: "record",
                    resourceID: remote.id,
                    server: server,
                    userID: user.id
                )
                if pending.entryDeletes.contains(remote.id) {
                    removeLocalEntry(remote.id, modelContext: modelContext, entryByID: &entryByID)
                    continue
                }
                if pending.entryUpserts.contains(remote.id), entryByID[remote.id] != nil {
                    continue
                }
                guard remote.visibility == "public" else {
                    // The iOS client has no local key model yet. A snapshot
                    // upsert it cannot decrypt is not a delete command.
                    continue
                }
                let downloaded = try await restoreMedia(
                    remote.media,
                    existing: entryByID[remote.id]?.mediaItems ?? [],
                    preferredTypes: SyncV2PayloadMapper.mediaTypes(from: remote),
                    server: server
                )
                mediaCount += downloaded.downloadCount
                let snapshot = try SyncV2PayloadMapper.entrySnapshot(
                    from: remote,
                    localMedia: downloaded.items,
                    tags: tagByID
                )
                if let existing = entryByID[remote.id] {
                    apply(snapshot, to: existing)
                } else {
                    let entry = JournalEntry(syncSnapshot: snapshot)
                    modelContext.insert(entry)
                    entryByID[entry.id] = entry
                }
                recordCount += 1
            }

            guard page.hasMore else { break }
            guard let next = page.nextCursor?.nilIfBlank, next != recordCursor else {
                throw SyncError.invalidResponse(
                    statusCode: nil,
                    body: "Record collection has more data but no advancing cursor."
                )
            }
            recordCursor = next
        }

        try modelContext.save()
        return SyncRestoreSummary(
            entityCount: entityCount,
            recordCount: recordCount,
            mediaCount: mediaCount
        )
    }

    @MainActor
    private func removeLocalTag(
        _ id: UUID,
        modelContext: ModelContext,
        tagByID: inout [UUID: JournalTag],
        entryByID: inout [UUID: JournalEntry]
    ) {
        guard let tag = tagByID.removeValue(forKey: id) else { return }
        let compactID = tag.compactID
        for entry in entryByID.values where entry.tagIDs.contains(compactID) {
            entry.tagIDs = entry.tagIDs.filter { $0 != compactID }
        }
        modelContext.delete(tag)
    }

    @MainActor
    private func removeLocalEntry(
        _ id: UUID,
        modelContext: ModelContext,
        entryByID: inout [UUID: JournalEntry]
    ) {
        guard let entry = entryByID.removeValue(forKey: id) else { return }
        modelContext.delete(entry)
    }

    // MARK: - Mutation batches

    @MainActor
    private func pushPendingCommands(
        to server: URL,
        user: SyncAuthenticatedUser,
        deviceID: UUID,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry],
        commands: [SyncLocalCommand]
    ) async throws -> SyncPushSummary {
        let pending = SyncLocalCommand.pendingInPushOrder(commands)
        guard !pending.isEmpty else {
            return SyncPushSummary(entityCount: 0, recordCount: 0, mediaCount: 0)
        }

        let tagByStringID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id.uuidString, $0) })
        let entryByStringID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id.uuidString, $0) })
        let tagIDByCompactID = Dictionary(uniqueKeysWithValues: tags.map { ($0.compactID, $0.id) })
        var entityCount = 0
        var recordCount = 0
        var mediaCount = 0

        for command in pending {
            do {
                let prepared: SyncPreparedMutation?
                switch command.type {
                case .entryUpsert:
                    guard let entry = entryByStringID[command.subjectID] else {
                        command.markSent()
                        continue
                    }
                    var mediaIDs: [UUID] = []
                    for item in entry.mediaItems {
                        let uploaded = try await ensureMediaUploaded(
                            item,
                            deviceID: deviceID,
                            server: server
                        )
                        mediaIDs.append(uploaded.id)
                        if uploaded.didUpload { mediaCount += 1 }
                    }
                    let payload = try jsonValue(from: JournalEntrySnapshot(entry: entry))
                    let record = SyncRecordInput(
                        id: entry.id,
                        deviceID: deviceID,
                        visibility: "public",
                        occurredAt: entry.eventDate,
                        endedAt: entry.endDate,
                        payload: payload,
                        tagIDs: entry.tagIDs.compactMap { tagIDByCompactID[$0] },
                        mediaIDs: mediaIDs,
                        metadata: .object([
                            "payloadSchema": .string("journal-entry-v1"),
                            "clientVersion": .string(appVersion)
                        ]),
                        source: SyncSourceInput(
                            kind: "client",
                            provider: "saros-harmonic-journal",
                            externalID: entry.id.uuidString,
                            url: nil,
                            metadata: .object([:])
                        )
                    )
                    prepared = SyncPreparedMutation(
                        request: SyncMutationRequest(
                            kind: "upsertRecord",
                            clientMutationID: command.id.uuidString,
                            // Record sync is client-authoritative. The relay
                            // creates or replaces this ID atomically.
                            ifMatch: nil,
                            record: record,
                            tag: nil,
                            resourceType: nil,
                            resourceID: nil
                        ),
                        resourceType: "record",
                        resourceID: entry.id
                    )

                case .entryDelete:
                    guard let id = UUID(uuidString: command.subjectID) else {
                        command.markSent()
                        continue
                    }
                    guard let etag = try await currentETag(
                        resourceType: "record",
                        resourceID: id,
                        path: "/v1/records/\(id.uuidString)",
                        server: server,
                        userID: user.id
                    ) else {
                        command.markSent()
                        continue
                    }
                    prepared = SyncPreparedMutation(
                        request: SyncMutationRequest(
                            kind: "delete",
                            clientMutationID: command.id.uuidString,
                            ifMatch: etag,
                            record: nil,
                            tag: nil,
                            resourceType: "record",
                            resourceID: id
                        ),
                        resourceType: "record",
                        resourceID: id
                    )

                case .tagUpsert:
                    guard let tag = tagByStringID[command.subjectID] else {
                        command.markSent()
                        continue
                    }
                    let etag = try await currentETag(
                        resourceType: "tag",
                        resourceID: tag.id,
                        path: "/v1/tags/\(tag.id.uuidString)",
                        server: server,
                        userID: user.id
                    )
                    let snapshot = try jsonValue(from: JournalTagSnapshot(tag: tag))
                    let input = SyncTagInput(
                        id: tag.id,
                        name: tag.name.nilIfBlank ?? "Saros \(tag.saros)",
                        color: normalizedColor(tag.colorHex),
                        emoji: tag.emoji.nilIfBlank,
                        sortOrder: Int(tag.compactID, radix: 8) ?? 0,
                        metadata: .object([
                            "journalTag": snapshot,
                            "payloadSchema": .string("journal-tag-v1")
                        ])
                    )
                    prepared = SyncPreparedMutation(
                        request: SyncMutationRequest(
                            kind: "upsertTag",
                            clientMutationID: command.id.uuidString,
                            ifMatch: etag,
                            record: nil,
                            tag: input,
                            resourceType: nil,
                            resourceID: nil
                        ),
                        resourceType: "tag",
                        resourceID: tag.id
                    )

                case .tagDelete:
                    guard let id = UUID(uuidString: command.subjectID) else {
                        command.markSent()
                        continue
                    }
                    guard let etag = try await currentETag(
                        resourceType: "tag",
                        resourceID: id,
                        path: "/v1/tags/\(id.uuidString)",
                        server: server,
                        userID: user.id
                    ) else {
                        command.markSent()
                        continue
                    }
                    prepared = SyncPreparedMutation(
                        request: SyncMutationRequest(
                            kind: "delete",
                            clientMutationID: command.id.uuidString,
                            ifMatch: etag,
                            record: nil,
                            tag: nil,
                            resourceType: "tag",
                            resourceID: id
                        ),
                        resourceType: "tag",
                        resourceID: id
                    )

                case nil:
                    command.markSent()
                    continue
                }

                guard let prepared else { continue }
                let batch = SyncBatchRequest(deviceID: deviceID, atomic: false, mutations: [prepared.request])
                var request = try jsonRequest(batch, server: server, path: "/v1/sync/batches", method: "POST")
                request.setValue("sync-\(command.id.uuidString)", forHTTPHeaderField: "Idempotency-Key")
                let (data, response) = try await authorizedData(request, server: server)
                try require(response, data: data, expectedStatus: [200])
                let result = try decode(SyncBatchResponse.self, from: data, context: "sync mutation result")
                guard let mutation = result.results.first,
                      mutation.clientMutationID == command.id.uuidString else {
                    throw SyncError.invalidResponse(statusCode: nil, body: "Mutation acknowledgement is missing.")
                }
                guard mutation.status == "succeeded" else {
                    let rejection = SyncError.invalidResponse(
                        statusCode: mutation.problem?.status,
                        body: mutation.problem?.detail ?? mutation.problem?.code ?? "Mutation failed."
                    )
                    stateStore.removeETag(
                        resourceType: prepared.resourceType,
                        resourceID: prepared.resourceID,
                        server: server,
                        userID: user.id
                    )
                    command.prepareRetry(afterServerRejection: rejection)
                    continue
                }
                if let etag = mutation.etag {
                    stateStore.setETag(
                        etag,
                        resourceType: prepared.resourceType,
                        resourceID: prepared.resourceID,
                        server: server,
                        userID: user.id
                    )
                }
                command.markSent()
                if prepared.resourceType == "record" { recordCount += 1 } else { entityCount += 1 }
            } catch {
                command.markFailed(error)
            }
        }

        try modelContext.save()
        return SyncPushSummary(
            entityCount: entityCount,
            recordCount: recordCount,
            mediaCount: mediaCount
        )
    }

    // MARK: - Devices

    @discardableResult
    private func ensureCurrentDevice(
        on server: URL,
        user: SyncAuthenticatedUser
    ) async throws -> UUID {
        let deviceID = stateStore.deviceID(server: server, userID: user.id)
        let local = JournalDevice.current()
        let body = SyncDeviceInput(
            id: deviceID,
            name: local.name.nilIfBlank ?? "iOS device",
            kind: "ios",
            platform: "iOS",
            appVersion: appVersion,
            metadata: .object([
                "journalDeviceId": .string(local.id),
                "emoji": .string(local.emoji)
            ])
        )
        var create = try jsonRequest(body, server: server, path: "/v1/devices", method: "POST")
        create.setValue("ios-device-\(deviceID.uuidString)", forHTTPHeaderField: "Idempotency-Key")
        let (createData, createResponse) = try await authorizedData(create, server: server)
        if createResponse.statusCode != 201 && createResponse.statusCode != 200 && createResponse.statusCode != 409 {
            try require(createResponse, data: createData, expectedStatus: [201])
        }
        if createResponse.statusCode == 409 {
            var get = URLRequest(url: try endpoint(server, path: "/v1/devices/\(deviceID.uuidString)"))
            get.httpMethod = "GET"
            let (data, response) = try await authorizedData(get, server: server)
            try require(response, data: data, expectedStatus: [200])
        }

        var bind = URLRequest(url: try endpoint(server, path: "/v1/devices/\(deviceID.uuidString)/current-session"))
        bind.httpMethod = "PUT"
        let (bindData, bindResponse) = try await authorizedData(bind, server: server)
        try require(bindResponse, data: bindData, expectedStatus: [204])
        return deviceID
    }

    // MARK: - Media

    private func ensureMediaUploaded(
        _ item: JournalMediaItem,
        deviceID: UUID,
        server: URL
    ) async throws -> (id: UUID, didUpload: Bool) {
        var existingRequest = URLRequest(url: try endpoint(server, path: "/v1/media/\(item.id.uuidString)"))
        existingRequest.httpMethod = "GET"
        let (existingData, existingResponse) = try await authorizedData(existingRequest, server: server)
        if existingResponse.statusCode == 200 {
            return (item.id, false)
        }
        if existingResponse.statusCode != 404 {
            try require(existingResponse, data: existingData, expectedStatus: [200, 404])
        }

        let fileURL = MediaStorage.url(for: item)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SyncError.mediaFileMissing(fileURL.path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteLength = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteLength > 0 else { throw SyncError.mediaFileMissing(fileURL.path) }
        let digest = try await Self.sha256Hex(of: fileURL)
        let createBody = SyncMediaUploadInput(
            mediaID: item.id,
            deviceID: deviceID,
            fileName: fileURL.lastPathComponent,
            contentType: contentType(for: fileURL, mediaType: item.type),
            byteLength: byteLength,
            sha256: digest
        )
        var create = try jsonRequest(
            createBody,
            server: server,
            path: "/v1/media-upload-sessions",
            method: "POST"
        )
        create.setValue("media-\(item.id.uuidString)", forHTTPHeaderField: "Idempotency-Key")
        let (createData, createResponse) = try await authorizedData(create, server: server)
        try require(createResponse, data: createData, expectedStatus: [201])
        let upload = try decode(SyncMediaUpload.self, from: createData, context: "media upload session")

        var uploadRequest = URLRequest(url: try resolve(upload.uploadURL, against: server))
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue(String(byteLength), forHTTPHeaderField: "Content-Length")
        uploadRequest.setValue(digest, forHTTPHeaderField: "X-Content-SHA256")
        let (uploadData, uploadResponse) = try await authorizedUpload(
            uploadRequest,
            fileURL: fileURL,
            server: server
        )
        try require(uploadResponse, data: uploadData, expectedStatus: [204])

        var complete = URLRequest(
            url: try endpoint(server, path: "/v1/media-upload-sessions/\(upload.id.uuidString)/complete")
        )
        complete.httpMethod = "POST"
        complete.setValue("media-complete-\(item.id.uuidString)", forHTTPHeaderField: "Idempotency-Key")
        let (completeData, completeResponse) = try await authorizedData(complete, server: server)
        try require(completeResponse, data: completeData, expectedStatus: [201, 200])
        let media = try decode(SyncMediaResource.self, from: completeData, context: "completed media")
        guard media.id == item.id else {
            throw SyncError.invalidResponse(statusCode: nil, body: "Server completed a different media ID.")
        }
        return (media.id, true)
    }

    private func restoreMedia(
        _ media: [SyncMediaResource],
        existing: [JournalMediaItem],
        preferredTypes: [UUID: MediaType],
        server: URL
    ) async throws -> (items: [JournalMediaItem], downloadCount: Int) {
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var items: [JournalMediaItem] = []
        var downloadCount = 0

        for remote in media {
            if let local = existingByID[remote.id],
               FileManager.default.fileExists(atPath: MediaStorage.url(for: local).path),
               (try? await Self.sha256Hex(of: MediaStorage.url(for: local))) == remote.sha256 {
                items.append(local)
                continue
            }

            var request = URLRequest(url: try resolve(remote.contentURL, against: server))
            request.httpMethod = "GET"
            let (temporaryURL, response) = try await authorizedDownload(request, server: server)
            try require(response, data: Data(), expectedStatus: [200])
            guard try await Self.sha256Hex(of: temporaryURL) == remote.sha256 else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw SyncError.mediaDigestMismatch(remote.id)
            }

            let cleanExtension = URL(fileURLWithPath: remote.fileName).pathExtension.nilIfBlank
                ?? fileExtension(for: remote.contentType)
            let destination = try MediaStorage.mediaDirectory()
                .appendingPathComponent(remote.id.uuidString)
                .appendingPathExtension(cleanExtension)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            items.append(JournalMediaItem(
                id: remote.id,
                type: existingByID[remote.id]?.type
                    ?? preferredTypes[remote.id]
                    ?? mediaType(for: remote.contentType),
                localPath: MediaStorage.relativePath(for: destination),
                createdAt: remote.createdAt
            ))
            downloadCount += 1
        }
        return (items, downloadCount)
    }

    // MARK: - Resource mapping

    private func makeTag(from remote: SyncTagResource, existing: [JournalTag]) -> JournalTag {
        if let snapshot = SyncV2PayloadMapper.tagSnapshot(from: remote) {
            return JournalTag(syncSnapshot: snapshot)
        }
        let compact = String(min(max(remote.sortOrder, 0), 511), radix: 8)
            .leftPadded(toLength: 3, withPad: "0")
        let tag = JournalTag(
            id: remote.id,
            createdAt: remote.createdAt,
            updatedAt: remote.updatedAt,
            name: remote.name,
            emoji: remote.emoji ?? "◇",
            anchorDate: remote.createdAt,
            saros: 0,
            notes: nil,
            isPrime: false,
            colorHex: remote.color ?? "#FFFFFF",
            octalID: compact
        )
        tag.ensureCompactID(existing: existing)
        return tag
    }

    private func apply(_ remote: SyncTagResource, to tag: JournalTag) {
        if let snapshot = SyncV2PayloadMapper.tagSnapshot(from: remote) {
            apply(snapshot, to: tag)
            return
        }
        tag.createdAt = remote.createdAt
        tag.updatedAt = remote.updatedAt
        tag.name = remote.name
        tag.emoji = remote.emoji ?? "◇"
        tag.colorHex = remote.color ?? "#FFFFFF"
        if (0..<512).contains(remote.sortOrder) {
            tag.octalID = String(remote.sortOrder, radix: 8).leftPadded(toLength: 3, withPad: "0")
        }
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

    private func apply(_ snapshot: JournalEntrySnapshot, to entry: JournalEntry) {
        entry.createdAt = snapshot.createdAt
        entry.eventDate = snapshot.eventDate
        entry.endDate = snapshot.endDate
        entry.unixTimestamp = snapshot.unixTimestamp
        entry.version = max(snapshot.version ?? entry.version, 1)
        entry.text = snapshot.text
        entry.emoji = snapshot.emoji
        entry.mediaItems = snapshot.mediaItems
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

    private func markCommandsSuperseded(
        _ commands: [SyncLocalCommand],
        type: SyncLocalCommandType,
        subjectID: UUID
    ) {
        for command in commands where command.isPending && command.subjectID == subjectID.uuidString {
            if command.type == type || type == .entryDelete || type == .tagDelete {
                command.markSent()
            }
        }
    }

    // MARK: - HTTP and token rotation

    private func requireStoredSession(for server: URL) async throws -> SyncStoredSession {
        guard let session = try await credentials.storedSession(for: server.absoluteString) else {
            throw SyncError.authenticationRequired
        }
        return session
    }

    private func authorizedData(
        _ request: URLRequest,
        server: URL
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        try requireSameOrigin(request.url, as: server)
        var didRefreshAuthentication = false
        var rateLimitRetries = 0
        while true {
            let token = try await accessToken(for: server)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncError.invalidResponse(statusCode: nil, body: response.description)
            }
            if http.statusCode == 401, !didRefreshAuthentication {
                try await credentials.invalidateAccessToken(for: server.absoluteString)
                didRefreshAuthentication = true
                continue
            }
            if let delay = rateLimitDelay(for: http), rateLimitRetries < 3 {
                rateLimitRetries += 1
                try await sleepForRateLimit(delay)
                continue
            }
            return (data, http)
        }
    }

    private func authorizedUpload(
        _ request: URLRequest,
        fileURL: URL,
        server: URL
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        try requireSameOrigin(request.url, as: server)
        var didRefreshAuthentication = false
        var rateLimitRetries = 0
        while true {
            let token = try await accessToken(for: server)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await urlSession.upload(for: request, fromFile: fileURL)
            guard let http = response as? HTTPURLResponse else {
                throw SyncError.invalidResponse(statusCode: nil, body: response.description)
            }
            if http.statusCode == 401, !didRefreshAuthentication {
                try await credentials.invalidateAccessToken(for: server.absoluteString)
                didRefreshAuthentication = true
                continue
            }
            if let delay = rateLimitDelay(for: http), rateLimitRetries < 3 {
                rateLimitRetries += 1
                try await sleepForRateLimit(delay)
                continue
            }
            return (data, http)
        }
    }

    private func authorizedDownload(
        _ request: URLRequest,
        server: URL
    ) async throws -> (URL, HTTPURLResponse) {
        var request = request
        try requireSameOrigin(request.url, as: server)
        var didRefreshAuthentication = false
        var rateLimitRetries = 0
        while true {
            let token = try await accessToken(for: server)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (url, response) = try await urlSession.download(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncError.invalidResponse(statusCode: nil, body: response.description)
            }
            if http.statusCode == 401, !didRefreshAuthentication {
                try? FileManager.default.removeItem(at: url)
                try await credentials.invalidateAccessToken(for: server.absoluteString)
                didRefreshAuthentication = true
                continue
            }
            if let delay = rateLimitDelay(for: http), rateLimitRetries < 3 {
                try? FileManager.default.removeItem(at: url)
                rateLimitRetries += 1
                try await sleepForRateLimit(delay)
                continue
            }
            return (url, http)
        }
    }

    private func rateLimitDelay(for response: HTTPURLResponse) -> TimeInterval? {
        guard response.statusCode == 429,
              let rawValue = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(rawValue),
              seconds >= 0 else { return nil }
        return min(max(seconds, 0.25), 65)
    }

    private func sleepForRateLimit(_ delay: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func accessToken(for server: URL) async throws -> String {
        do {
            return try await credentials.accessToken(for: server.absoluteString) { [weak self] refreshToken in
                guard let self else { throw SyncError.authenticationRequired }
                return try await self.refreshSession(refreshToken, on: server)
            }
        } catch SyncError.invalidResponse(let statusCode, _) where statusCode == 401 {
            try await credentials.clear(for: server.absoluteString)
            throw SyncError.authenticationRequired
        }
    }

    private func refreshSession(_ refreshToken: String, on server: URL) async throws -> SyncAuthSessionResponse {
        try await sendJSON(
            SyncRefreshRequest(refreshToken: refreshToken),
            to: server,
            path: "/v1/auth/refresh",
            method: "POST",
            expectedStatus: [200]
        )
    }

    private func currentETag(
        resourceType: String,
        resourceID: UUID,
        path: String,
        server: URL,
        userID: UUID
    ) async throws -> String? {
        if let stored = stateStore.etag(
            resourceType: resourceType,
            resourceID: resourceID,
            server: server,
            userID: userID
        ) {
            return stored
        }
        var request = URLRequest(url: try endpoint(server, path: path))
        request.httpMethod = "GET"
        let (data, response) = try await authorizedData(request, server: server)
        if response.statusCode == 404 { return nil }
        try require(response, data: data, expectedStatus: [200])
        guard let etag = response.value(forHTTPHeaderField: "ETag")?.nilIfBlank else {
            throw SyncError.missingResourceETag("\(resourceType) \(resourceID.uuidString)")
        }
        stateStore.setETag(
            etag,
            resourceType: resourceType,
            resourceID: resourceID,
            server: server,
            userID: userID
        )
        return etag
    }

    private func sendJSON<Request: Encodable, Response: Decodable>(
        _ body: Request,
        to server: URL,
        path: String,
        method: String,
        expectedStatus: Set<Int>
    ) async throws -> Response {
        let request = try jsonRequest(body, server: server, path: path, method: method)
        let (data, response) = try await urlSession.data(for: request)
        try require(response, data: data, expectedStatus: expectedStatus)
        return try decode(Response.self, from: data, context: path)
    }

    private func jsonRequest<T: Encodable>(
        _ body: T,
        server: URL,
        path: String,
        method: String
    ) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(server, path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func require(
        _ response: URLResponse,
        data: Data,
        expectedStatus: Set<Int>
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse(statusCode: nil, body: response.description)
        }
        guard expectedStatus.contains(http.statusCode) else {
            let problem = try? decoder.decode(SyncProblem.self, from: data)
            let fallback = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw SyncError.invalidResponse(
                statusCode: http.statusCode,
                body: problem?.userFacingDetail ?? problem?.code ?? fallback
            )
        }
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

    private func decodeValue<T: Decodable>(
        _ type: T.Type,
        from value: SyncJSONValue,
        context: String
    ) throws -> T {
        try decode(type, from: encoder.encode(value), context: context)
    }

    private func jsonValue<T: Encodable>(from value: T) throws -> SyncJSONValue {
        try decoder.decode(SyncJSONValue.self, from: encoder.encode(value))
    }

    private func serverBaseURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else {
            throw SyncError.invalidServerURL
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        components.path = ""
        guard let url = components.url else { throw SyncError.invalidServerURL }
        return url
    }

    func collectionPageURL(
        server: URL,
        path: String,
        limit: Int,
        cursor: String?
    ) throws -> URL {
        var components = URLComponents(
            url: try endpoint(server, path: path),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw SyncError.invalidServerURL }
        return url
    }

    private func endpoint(_ server: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            throw SyncError.invalidServerURL
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw SyncError.invalidServerURL }
        return url
    }

    private func resolve(_ reference: String, against server: URL) throws -> URL {
        guard let url = URL(string: reference, relativeTo: server)?.absoluteURL else {
            throw SyncError.invalidServerURL
        }
        try requireSameOrigin(url, as: server)
        return url
    }

    private func requireSameOrigin(_ url: URL?, as server: URL) throws {
        guard let url, Self.isSameOrigin(url, as: server) else {
            throw SyncError.crossOriginCredentialURL(url ?? server)
        }
    }

    static func isSameOrigin(_ url: URL, as server: URL) -> Bool {
        guard let urlScheme = url.scheme?.lowercased(),
              let serverScheme = server.scheme?.lowercased(),
              let urlHost = url.host?.lowercased(),
              let serverHost = server.host?.lowercased(),
              (urlScheme == "http" || urlScheme == "https"),
              url.user == nil,
              url.password == nil else {
            return false
        }
        return urlScheme == serverScheme
            && urlHost == serverHost
            && effectivePort(for: url) == effectivePort(for: server)
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private func resourceETag(type: String, id: UUID, revision: Int64) -> String {
        "\"\(type)-\(id.uuidString.lowercased())-r\(revision)\""
    }

    private func normalizedColor(_ value: String?) -> String? {
        guard let value = value?.nilIfBlank else { return nil }
        guard value.first == "#" else { return nil }
        let hex = value.dropFirst()
        guard hex.count == 6 || hex.count == 8,
              hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return value.uppercased()
    }

    private func contentType(for url: URL, mediaType: MediaType) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "m4a": return "audio/mp4"
        case "caf": return "audio/x-caf"
        case "wav": return "audio/wav"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        case "pdf": return "application/pdf"
        default:
            switch mediaType {
            case .photo, .symbolicPhoto: return "image/jpeg"
            case .video: return "video/mp4"
            case .audio: return "audio/mp4"
            case .document: return "application/octet-stream"
            }
        }
    }

    private func mediaType(for contentType: String) -> MediaType {
        if contentType.hasPrefix("image/") { return .photo }
        if contentType.hasPrefix("video/") { return .video }
        if contentType.hasPrefix("audio/") { return .audio }
        return .document
    }

    private func fileExtension(for contentType: String) -> String {
        switch contentType.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic": return "heic"
        case "video/quicktime": return "mov"
        case "video/mp4": return "mp4"
        case "audio/mp4": return "m4a"
        case "audio/wav": return "wav"
        case "application/pdf": return "pdf"
        default: return "bin"
        }
    }

    private func markLastSync() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: JournalSettings.lastSyncAtKey)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.iso8601WithFractionalSeconds.string(from: date))
        }
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self),
               let date = Self.iso8601WithFractionalSeconds.date(from: string)
                    ?? Self.iso8601.date(from: string) {
                return date
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

    private static func sha256Hex(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            while true {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { break }
                digest.update(data: data)
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
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

// MARK: - Legacy payload preservation and server/agent payload projection

enum SyncV2PayloadMapper {
    static func entrySnapshot(
        from remote: SyncRecordResource,
        localMedia: [JournalMediaItem],
        tags: [UUID: JournalTag]
    ) throws -> JournalEntrySnapshot {
        guard remote.visibility == "public",
              let payload = remote.payload,
              let occurredAt = remote.occurredAt else {
            throw SyncService.SyncError.invalidResponse(
                statusCode: nil,
                body: "Public record \(remote.id.uuidString) is missing its payload or occurrence time."
            )
        }
        let remoteTagIDs = remote.tagIDs ?? []
        if let imported = try? decode(JournalEntrySnapshot.self, from: payload) {
            guard imported.id == remote.id else {
                throw SyncService.SyncError.invalidResponse(
                    statusCode: nil,
                    body: "Record \(remote.id.uuidString) contains a different payload ID."
                )
            }
            return JournalEntrySnapshot(
                id: imported.id,
                createdAt: imported.createdAt,
                updatedAt: imported.updatedAt,
                eventDate: imported.eventDate,
                endDate: imported.endDate,
                unixTimestamp: imported.unixTimestamp,
                version: imported.version,
                text: imported.text,
                emoji: imported.emoji,
                mediaItems: localMedia,
                tagIDs: imported.tagIDs ?? remoteTagIDs.compactMap { tags[$0]?.compactID },
                context: imported.context,
                latitude: imported.latitude,
                longitude: imported.longitude,
                sourceRecordID: imported.sourceRecordID,
                sourceDeviceID: imported.sourceDeviceID ?? remote.deviceID.uuidString,
                sourceDeviceEmoji: imported.sourceDeviceEmoji,
                sourceDeviceName: imported.sourceDeviceName,
                weatherCode: imported.weatherCode,
                weatherEmoji: imported.weatherEmoji,
                temperatureC: imported.temperatureC
            )
        }

        let object = payload.objectValue ?? [:]
        let context = object["context"].flatMap { try? decode(JournalEventContext.self, from: $0) }
            ?? JournalEventContext.empty(date: occurredAt)
        let location = object["location"]?.objectValue
        let weather = object["weather"]?.objectValue
        return JournalEntrySnapshot(
            id: remote.id,
            createdAt: remote.createdAt,
            updatedAt: remote.updatedAt,
            eventDate: occurredAt,
            endDate: remote.endedAt,
            unixTimestamp: Int64(occurredAt.timeIntervalSince1970.rounded(.towardZero)),
            version: max(Int(remote.revision), 1),
            text: object["text"]?.stringValue,
            emoji: object["emoji"]?.stringValue,
            mediaItems: localMedia,
            tagIDs: remoteTagIDs.compactMap { tags[$0]?.compactID },
            context: context,
            latitude: location?["latitude"]?.doubleValue,
            longitude: location?["longitude"]?.doubleValue,
            sourceRecordID: nil,
            sourceDeviceID: remote.deviceID.uuidString,
            sourceDeviceEmoji: nil,
            sourceDeviceName: nil,
            weatherCode: weather?["code"]?.intValue,
            weatherEmoji: weather?["emoji"]?.stringValue,
            temperatureC: weather?["temperatureC"]?.intValue
        )
    }

    static func mediaTypes(from remote: SyncRecordResource) -> [UUID: MediaType] {
        guard let payload = remote.payload,
              let imported = try? decode(JournalEntrySnapshot.self, from: payload) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: imported.mediaItems.map { ($0.id, $0.type) })
    }

    static func tagSnapshot(from remote: SyncTagResource) -> JournalTagSnapshot? {
        if let value = remote.metadata.objectValue?["journalTag"],
           let snapshot = try? decode(JournalTagSnapshot.self, from: value),
           snapshot.id == remote.id {
            return snapshot
        }
        if let legacy = remote.metadata.objectValue?["legacyImport"]?.objectValue?["document"],
           let snapshot = try? decode(JournalTagSnapshot.self, from: legacy),
           snapshot.id == remote.id {
            return snapshot
        }
        return nil
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: SyncJSONValue) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = ISO8601DateFormatter.syncFractional.date(from: string)
                ?? ISO8601DateFormatter.syncStandard.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date.")
        }
        return try decoder.decode(type, from: encoder.encode(value))
    }
}

// MARK: - Keychain-backed rotating session

private actor SyncCredentialVault {
    private let keychain = SyncKeychainStore()
    private var refreshTasks: [String: Task<SyncAuthSessionResponse, Error>] = [:]

    func save(_ response: SyncAuthSessionResponse, for serverKey: String) throws {
        try keychain.save(SyncStoredSession(response: response), account: serverKey)
    }

    func storedSession(for serverKey: String) throws -> SyncStoredSession? {
        try keychain.load(account: serverKey)
    }

    func clear(for serverKey: String) throws {
        refreshTasks[serverKey]?.cancel()
        refreshTasks[serverKey] = nil
        try keychain.delete(account: serverKey)
    }

    func invalidateAccessToken(for serverKey: String) throws {
        guard var stored = try keychain.load(account: serverKey) else { return }
        stored.accessExpiresAt = .distantPast
        try keychain.save(stored, account: serverKey)
    }

    func accessToken(
        for serverKey: String,
        refresh: @escaping (String) async throws -> SyncAuthSessionResponse
    ) async throws -> String {
        guard let stored = try keychain.load(account: serverKey) else {
            throw SyncService.SyncError.authenticationRequired
        }
        if stored.accessExpiresAt.timeIntervalSinceNow > 30 {
            return stored.accessToken
        }

        if let existing = refreshTasks[serverKey] {
            return try await existing.value.accessToken
        }
        let refreshToken = stored.refreshToken
        let task = Task { try await refresh(refreshToken) }
        refreshTasks[serverKey] = task
        do {
            let response = try await task.value
            try keychain.save(SyncStoredSession(response: response), account: serverKey)
            refreshTasks[serverKey] = nil
            return response.accessToken
        } catch {
            refreshTasks[serverKey] = nil
            throw error
        }
    }
}

private struct SyncKeychainStore {
    private let service = "app.exeligmos.sync.v2"

    func save(_ session: SyncStoredSession, account: String) throws {
        let data = try JSONEncoder().encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SyncService.SyncError.credentialStorage(status: updateStatus)
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SyncService.SyncError.credentialStorage(status: addStatus)
        }
    }

    func load(account: String) throws -> SyncStoredSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SyncService.SyncError.credentialStorage(status: status)
        }
        return try JSONDecoder().decode(SyncStoredSession.self, from: data)
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncService.SyncError.credentialStorage(status: status)
        }
    }
}

final class SyncV2StateStore {
    private let defaults: UserDefaults
    private let localStoreServerKey = "exeligmos.v2.local-store-owner.server"
    private let localStoreUserKey = "exeligmos.v2.local-store-owner.user-id"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The current SwiftData schema is a single-owner store. Bind it once and
    /// fail closed for every other account so a login switch cannot upload one
    /// user's local journal into another tenant. Logout intentionally leaves
    /// this binding intact.
    func bindLocalStoreIfNeeded(server: URL, userID: UUID) throws {
        let storedServer = defaults.string(forKey: localStoreServerKey)
        let storedUserValue = defaults.string(forKey: localStoreUserKey)
        if storedServer == nil, storedUserValue == nil {
            defaults.set(server.absoluteString, forKey: localStoreServerKey)
            defaults.set(userID.uuidString, forKey: localStoreUserKey)
            return
        }
        guard let storedServer,
              let storedUserValue,
              let storedUserID = UUID(uuidString: storedUserValue) else {
            throw SyncService.SyncError.invalidLocalStoreOwnerBinding
        }
        guard storedServer == server.absoluteString, storedUserID == userID else {
            throw SyncService.SyncError.localStoreOwnerMismatch(
                boundServer: storedServer,
                boundUserID: storedUserID,
                authenticatedServer: server.absoluteString,
                authenticatedUserID: userID
            )
        }
    }

    func deviceID(server: URL, userID: UUID) -> UUID {
        let key = "exeligmos.v2.device.\(namespace(server: server, userID: userID))"
        if let value = defaults.string(forKey: key), let id = UUID(uuidString: value) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: key)
        return id
    }

    func cursor(server: URL, userID: UUID) -> String? {
        defaults.string(forKey: "exeligmos.v2.cursor.\(namespace(server: server, userID: userID))")
    }

    func setCursor(_ cursor: String?, server: URL, userID: UUID) {
        let key = "exeligmos.v2.cursor.\(namespace(server: server, userID: userID))"
        if let cursor {
            defaults.set(cursor, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func etag(
        resourceType: String,
        resourceID: UUID,
        server: URL,
        userID: UUID
    ) -> String? {
        defaults.string(forKey: etagKey(
            resourceType: resourceType,
            resourceID: resourceID,
            server: server,
            userID: userID
        ))
    }

    func setETag(
        _ etag: String,
        resourceType: String,
        resourceID: UUID,
        server: URL,
        userID: UUID
    ) {
        defaults.set(etag, forKey: etagKey(
            resourceType: resourceType,
            resourceID: resourceID,
            server: server,
            userID: userID
        ))
    }

    func removeETag(
        resourceType: String,
        resourceID: UUID,
        server: URL,
        userID: UUID
    ) {
        defaults.removeObject(forKey: etagKey(
            resourceType: resourceType,
            resourceID: resourceID,
            server: server,
            userID: userID
        ))
    }

    private func etagKey(
        resourceType: String,
        resourceID: UUID,
        server: URL,
        userID: UUID
    ) -> String {
        "exeligmos.v2.etag.\(namespace(server: server, userID: userID)).\(resourceType).\(resourceID.uuidString)"
    }

    private func namespace(server: URL, userID: UUID) -> String {
        let digest = SHA256.hash(data: Data("\(server.absoluteString)|\(userID.uuidString)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Wire types

struct SyncRecordResource: Decodable {
    let id: UUID
    let userID: UUID
    let deviceID: UUID
    let visibility: String
    let revision: Int64
    let createdAt: Date
    let updatedAt: Date
    let occurredAt: Date?
    let endedAt: Date?
    let payload: SyncJSONValue?
    let tagIDs: [UUID]?
    let media: [SyncMediaResource]

    enum CodingKeys: String, CodingKey {
        case id, visibility, revision, createdAt, updatedAt, occurredAt, endedAt, payload, media
        case userID = "userId"
        case deviceID = "deviceId"
        case tagIDs = "tagIds"
    }
}

struct SyncTagResource: Decodable {
    let id: UUID
    let userID: UUID
    let name: String
    let color: String?
    let emoji: String?
    let sortOrder: Int
    let metadata: SyncJSONValue
    let revision: Int64
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, color, emoji, sortOrder, metadata, revision, createdAt, updatedAt
        case userID = "userId"
    }
}

struct SyncMediaResource: Codable {
    let id: UUID
    let userID: UUID
    let deviceID: UUID
    let fileName: String
    let contentType: String
    let byteLength: Int64
    let sha256: String
    let revision: Int64
    let createdAt: Date
    let contentURL: String

    enum CodingKeys: String, CodingKey {
        case id, fileName, contentType, byteLength, sha256, revision, createdAt
        case userID = "userId"
        case deviceID = "deviceId"
        case contentURL = "contentUrl"
    }
}

enum SyncJSONValue: Codable, Hashable {
    case object([String: SyncJSONValue])
    case array([SyncJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: SyncJSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([SyncJSONValue].self) { self = .array(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: SyncJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let value): return Int(exactly: value)
        case .number(let value) where value.rounded() == value: return Int(exactly: value)
        default: return nil
        }
    }
}

private struct SyncAuthSessionResponse: Codable, Sendable {
    let tokenType: String
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String
    let refreshExpiresIn: TimeInterval
    let user: SyncAuthenticatedUser
}

private struct SyncStoredSession: Codable, Sendable {
    let accessToken: String
    var accessExpiresAt: Date
    let refreshToken: String
    let refreshExpiresAt: Date
    let user: SyncAuthenticatedUser

    init(response: SyncAuthSessionResponse, now: Date = Date()) {
        self.accessToken = response.accessToken
        self.accessExpiresAt = now.addingTimeInterval(response.expiresIn)
        self.refreshToken = response.refreshToken
        self.refreshExpiresAt = now.addingTimeInterval(response.refreshExpiresIn)
        self.user = response.user
    }
}

private struct SyncLoginRequest: Encodable {
    let login: String
    let password: String
}

struct SyncRegistrationInput: Encodable, Equatable {
    let login: String
    let password: String
    let displayName: String?
    let inviteCode: String?

    static func validated(
        login: String,
        password: String,
        displayName: String?,
        inviteCode: String?
    ) throws -> SyncRegistrationInput {
        let login = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let loginRange = login.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]*$",
            options: .regularExpression
        )
        guard (3...64).contains(login.count), loginRange != nil else {
            throw SyncService.SyncError.invalidAccountInput(
                "Login must contain 3 to 64 characters, start with a letter or number, " +
                    "and use only letters, numbers, periods, underscores, or hyphens."
            )
        }

        guard (12...1_024).contains(password.unicodeScalars.count) else {
            throw SyncService.SyncError.invalidAccountInput(
                "Password must contain 12 to 1024 characters."
            )
        }

        let displayName = displayName?.nilIfBlank
        if let displayName, !(1...120).contains(displayName.unicodeScalars.count) {
            throw SyncService.SyncError.invalidAccountInput(
                "Display name must contain at most 120 characters."
            )
        }

        let inviteCode = inviteCode?.nilIfBlank
        if let inviteCode, !(1...200).contains(inviteCode.unicodeScalars.count) {
            throw SyncService.SyncError.invalidAccountInput(
                "Invite code must contain at most 200 characters."
            )
        }

        return SyncRegistrationInput(
            login: login,
            password: password,
            displayName: displayName,
            inviteCode: inviteCode
        )
    }
}

private struct SyncRefreshRequest: Encodable {
    let refreshToken: String
}

private struct SyncDeviceInput: Encodable {
    let id: UUID
    let name: String
    let kind: String
    let platform: String
    let appVersion: String
    let metadata: SyncJSONValue
}

private struct SyncChangePage: Decodable {
    let data: [SyncChange]
    let nextCursor: String
    let hasMore: Bool
}

private struct SyncCollectionPage<Resource: Decodable>: Decodable {
    let data: [Resource]
    let nextCursor: String?
    let hasMore: Bool
}

private struct SyncPendingMutationIDs {
    let entryUpserts: Set<UUID>
    let entryDeletes: Set<UUID>
    let tagUpserts: Set<UUID>
    let tagDeletes: Set<UUID>

    init(commands: [SyncLocalCommand]) {
        func ids(for type: SyncLocalCommandType) -> Set<UUID> {
            Set(commands.compactMap { command in
                guard command.isPending,
                      command.type == type else { return nil }
                return UUID(uuidString: command.subjectID)
            })
        }
        entryUpserts = ids(for: .entryUpsert)
        entryDeletes = ids(for: .entryDelete)
        tagUpserts = ids(for: .tagUpsert)
        tagDeletes = ids(for: .tagDelete)
    }
}

private struct SyncChange: Decodable {
    let sequence: Int64
    let changedAt: Date
    let resourceType: String
    let operation: String
    let resourceID: UUID
    let revision: Int64
    let etag: String
    let resource: SyncJSONValue?

    enum CodingKeys: String, CodingKey {
        case sequence, changedAt, resourceType, operation, revision, etag, resource
        case resourceID = "resourceId"
    }
}

private struct SyncSourceInput: Encodable {
    let kind: String
    let provider: String
    let externalID: String?
    let url: String?
    let metadata: SyncJSONValue

    enum CodingKeys: String, CodingKey {
        case kind, provider, url, metadata
        case externalID = "externalId"
    }
}

private struct SyncRecordInput: Encodable {
    let id: UUID
    let deviceID: UUID
    let visibility: String
    let occurredAt: Date
    let endedAt: Date?
    let payload: SyncJSONValue
    let tagIDs: [UUID]
    let mediaIDs: [UUID]
    let metadata: SyncJSONValue
    let source: SyncSourceInput

    enum CodingKeys: String, CodingKey {
        case id, visibility, occurredAt, endedAt, payload, metadata, source
        case deviceID = "deviceId"
        case tagIDs = "tagIds"
        case mediaIDs = "mediaIds"
    }
}

private struct SyncTagInput: Encodable {
    let id: UUID
    let name: String
    let color: String?
    let emoji: String?
    let sortOrder: Int
    let metadata: SyncJSONValue
}

private struct SyncMutationRequest: Encodable {
    let kind: String
    let clientMutationID: String
    let ifMatch: String?
    let record: SyncRecordInput?
    let tag: SyncTagInput?
    let resourceType: String?
    let resourceID: UUID?

    enum CodingKeys: String, CodingKey {
        case kind, ifMatch, record, tag, resourceType
        case clientMutationID = "clientMutationId"
        case resourceID = "resourceId"
    }
}

private struct SyncPreparedMutation {
    let request: SyncMutationRequest
    let resourceType: String
    let resourceID: UUID
}

private struct SyncBatchRequest: Encodable {
    let deviceID: UUID
    let atomic: Bool
    let mutations: [SyncMutationRequest]

    enum CodingKeys: String, CodingKey {
        case atomic, mutations
        case deviceID = "deviceId"
    }
}

private struct SyncBatchResponse: Decodable {
    let results: [SyncMutationResult]
}

private struct SyncMutationResult: Decodable {
    let clientMutationID: String
    let status: String
    let resourceType: String?
    let resourceID: UUID?
    let revision: Int64?
    let etag: String?
    let problem: SyncProblem?

    enum CodingKeys: String, CodingKey {
        case status, resourceType, revision, etag, problem
        case clientMutationID = "clientMutationId"
        case resourceID = "resourceId"
    }
}

private struct SyncProblem: Codable {
    let status: Int?
    let detail: String?
    let code: String?
    let errors: [SyncProblemField]?

    var userFacingDetail: String? {
        guard let first = errors?.first else { return detail }
        let field = first.path
            .split(separator: "/")
            .last
            .map(String.init)
            .map { $0.replacingOccurrences(of: "~1", with: "/") }
            .map { $0.replacingOccurrences(of: "~0", with: "~") }
        guard let field, !field.isEmpty else { return first.message }
        return "\(field): \(first.message)"
    }
}

private struct SyncProblemField: Codable {
    let path: String
    let code: String
    let message: String
}

private struct SyncMediaUploadInput: Encodable {
    let mediaID: UUID
    let deviceID: UUID
    let fileName: String
    let contentType: String
    let byteLength: Int64
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case fileName, contentType, byteLength, sha256
        case mediaID = "mediaId"
        case deviceID = "deviceId"
    }
}

private struct SyncMediaUpload: Decodable {
    let id: UUID
    let uploadURL: String

    enum CodingKeys: String, CodingKey {
        case id
        case uploadURL = "uploadUrl"
    }
}

private extension JournalTag {
    convenience init(syncSnapshot snapshot: JournalTagSnapshot) {
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
    convenience init(syncSnapshot snapshot: JournalEntrySnapshot) {
        self.init(
            id: snapshot.id,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            eventDate: snapshot.eventDate,
            endDate: snapshot.endDate,
            version: snapshot.version ?? 1,
            text: snapshot.text,
            emoji: snapshot.emoji,
            mediaItems: snapshot.mediaItems,
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

private extension ISO8601DateFormatter {
    static let syncStandard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let syncFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

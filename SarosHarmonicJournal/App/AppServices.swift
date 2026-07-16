import Combine
import Foundation
import SwiftData

struct SyncProgressPresentation: Equatable {
    enum Phase: String {
        case preparing = "Preparing local journal"
        case downloading = "Restoring from server"
        case uploading = "Uploading local records"
        case complete = "Sync complete"
        case failed = "Sync paused"
    }

    var phase: Phase
    var restoredTags = 0
    var restoredRecords = 0
    var restoredMedia = 0
    var totalTags = 0
    var totalRecords = 0
    var totalMedia = 0
    var uploadedRecords = 0
    var uploadedMedia = 0
    var totalUploadRecords = 0
    var totalUploadMedia = 0
    var skippedPrivateRecords = 0
    var detail: String?
    var isInitialRestore: Bool

    var canDismiss: Bool { true }
}

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var authenticatedUser: SyncAuthenticatedUser?
    @Published private(set) var progress: SyncProgressPresentation?
    @Published var isProgressPresented = false

    private let service: SyncService
    private let defaults: UserDefaults
    private var syncTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var progressFlushTask: Task<Void, Never>?
    private var pendingProgress = SyncProgressDelta()
    private var resyncRequested = false
    private var syncGeneration = 0
    private var transientSyncFailureCount = 0
    private let initialRestoreKey = "exeligmos.sync.initial-restore-completed.v1"
    private let lastUserKey = "exeligmos.sync.last-user-id.v1"
    private let authenticationEnabledKey = "exeligmos.sync.authentication-enabled.v1"

    init(service: SyncService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    var isAuthenticated: Bool { authenticatedUser != nil }
    var isSyncing: Bool { syncTask != nil }
    var isInitialRestoreActive: Bool {
        guard progress?.isInitialRestore == true else { return false }
        return progress?.phase != .complete && progress?.phase != .failed
    }

    func restoreAuthentication(for serverURL: String) async {
        guard defaults.bool(forKey: authenticationEnabledKey),
              serverURL.nilIfBlank != nil else {
            authenticatedUser = nil
            return
        }
        if case .signedIn(let user) = try? await service.authenticationState(for: serverURL) {
            authenticatedUser = user
        } else {
            authenticatedUser = nil
        }
    }

    func loginAndMerge(
        serverURL: String,
        login: String,
        password: String,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry],
        commands: [SyncLocalCommand]
    ) async throws {
        let user = try await service.login(to: serverURL, login: login, password: password)
        resetRetryState()
        defaults.set(true, forKey: authenticationEnabledKey)
        authenticatedUser = user
        beginMerge(
            serverURL: serverURL,
            user: user,
            modelContext: modelContext,
            tags: tags,
            entries: entries,
            commands: commands
        )
    }

    func registerAndMerge(
        serverURL: String,
        login: String,
        password: String,
        displayName: String?,
        inviteCode: String?,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry],
        commands: [SyncLocalCommand]
    ) async throws {
        let user = try await service.register(
            on: serverURL,
            login: login,
            password: password,
            displayName: displayName,
            inviteCode: inviteCode
        )
        resetRetryState()
        defaults.set(true, forKey: authenticationEnabledKey)
        authenticatedUser = user
        beginMerge(
            serverURL: serverURL,
            user: user,
            modelContext: modelContext,
            tags: tags,
            entries: entries,
            commands: commands
        )
    }

    func signOut(serverURL: String) async throws {
        syncTask?.cancel()
        retryTask?.cancel()
        progressFlushTask?.cancel()
        syncTask = nil
        retryTask = nil
        syncGeneration &+= 1
        transientSyncFailureCount = 0
        resyncRequested = false
        defer {
            defaults.set(false, forKey: authenticationEnabledKey)
            authenticatedUser = nil
            progress = nil
            isProgressPresented = false
        }
        try await service.logout(from: serverURL)
    }

    func dismissProgress() {
        guard progress?.canDismiss != false else { return }
        isProgressPresented = false
    }

    func scheduleAutomaticSync(
        serverURL: String,
        modelContext: ModelContext
    ) {
        guard let user = authenticatedUser else { return }
        guard syncTask == nil else {
            // A command/query update that arrives while synchronization is
            // active must get another pass after the current snapshot ends.
            resyncRequested = true
            return
        }
        let inputs = automaticSyncInputs(modelContext: modelContext, userID: user.id)
        beginMerge(
            serverURL: serverURL,
            user: user,
            modelContext: modelContext,
            tags: inputs.tags,
            entries: inputs.entries,
            commands: inputs.commands,
            presentsProgress: false,
            presentsInitialProgress: progress == nil
        )
    }

    private func beginMerge(
        serverURL: String,
        user: SyncAuthenticatedUser,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry],
        commands: [SyncLocalCommand],
        presentsProgress: Bool = true,
        presentsInitialProgress: Bool = true
    ) {
        syncTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        syncGeneration &+= 1
        let generation = syncGeneration
        progressFlushTask?.cancel()
        progressFlushTask = nil
        pendingProgress = .zero
        resyncRequested = false
        let isInitial = !defaults.bool(forKey: initialRestoreKey)
        let reportsProgress = presentsProgress || (isInitial && presentsInitialProgress)
        if reportsProgress {
            progress = SyncProgressPresentation(phase: .preparing, isInitialRestore: isInitial)
            isProgressPresented = true
        }

        let retained: (tags: [JournalTag], entries: [JournalEntry])
        do {
            retained = try prepareAccountScope(
                for: user,
                modelContext: modelContext,
                tags: tags,
                entries: entries,
                commands: commands
            )
            try seedLocalCommands(
                user: user,
                modelContext: modelContext,
                tags: retained.tags,
                entries: retained.entries,
                commands: commands
            )
        } catch {
            progress?.phase = .failed
            progress?.detail = "Could not prepare the local journal for this account: \(error.localizedDescription)"
            isProgressPresented = true
            return
        }
        // Capture the authenticated account before any network merge begins so
        // a rapid A -> B switch cannot bypass scope cleanup.
        defaults.set(user.id.uuidString, forKey: lastUserKey)
        let scopedCommands = (try? modelContext.fetch(FetchDescriptor<SyncLocalCommand>(
            sortBy: [SortDescriptor(\SyncLocalCommand.createdAt)]
        ))) ?? commands

        syncTask = Task { [weak self] in
            guard let self else { return }
            do {
                let progressHandler: ((SyncTransferEvent) -> Void)? = reportsProgress
                    ? { [weak self] event in self?.consume(event) }
                    : nil
                _ = try await service.synchronizeEntries(
                    with: serverURL,
                    modelContext: modelContext,
                    tags: retained.tags,
                    entries: retained.entries,
                    commands: scopedCommands,
                    progress: progressHandler
                )
                guard !Task.isCancelled else { return }
                transientSyncFailureCount = 0
                let hasNewEligibleWork = currentCommands(
                    modelContext: modelContext,
                    fallback: scopedCommands
                ).contains {
                    $0.isEligibleForAutomaticSync
                        && ($0.ownerUserID == nil || $0.ownerUserID == user.id)
                }
                let shouldRunAgain = resyncRequested || hasNewEligibleWork
                resyncRequested = false
                if shouldRunAgain {
                    syncTask = nil
                    restartMerge(
                        serverURL: serverURL,
                        user: user,
                        modelContext: modelContext
                    )
                    return
                }
                defaults.set(true, forKey: initialRestoreKey)
                if reportsProgress {
                    flushProgressDeltas()
                    progress?.phase = .complete
                    progress?.detail = progress?.skippedPrivateRecords == 0
                        ? "Your local journal and server are merged."
                        : "Public records were restored. Private records remain encrypted on the server."
                }
            } catch {
                guard !Task.isCancelled else { return }
                if reportsProgress {
                    flushProgressDeltas()
                    progress?.phase = .failed
                    progress?.detail = error.localizedDescription
                }
                let shouldRunAgain = resyncRequested
                resyncRequested = false
                if SyncService.isRetryableFailure(error) {
                    let delay = nextTransientRetryDelay()
                    if reportsProgress {
                        progress?.detail = "\(error.localizedDescription) Retrying in \(Int(delay)) seconds."
                    }
                    syncTask = nil
                    scheduleTransientRetry(
                        after: delay,
                        generation: generation,
                        serverURL: serverURL,
                        user: user,
                        modelContext: modelContext
                    )
                    return
                }
                if shouldRunAgain {
                    syncTask = nil
                    restartMerge(
                        serverURL: serverURL,
                        user: user,
                        modelContext: modelContext
                    )
                    return
                }
            }
            syncTask = nil
        }
    }

    private func restartMerge(
        serverURL: String,
        user: SyncAuthenticatedUser,
        modelContext: ModelContext
    ) {
        guard authenticatedUser?.id == user.id else { return }
        let inputs = automaticSyncInputs(modelContext: modelContext, userID: user.id)
        beginMerge(
            serverURL: serverURL,
            user: user,
            modelContext: modelContext,
            tags: inputs.tags,
            entries: inputs.entries,
            commands: inputs.commands,
            presentsProgress: false,
            presentsInitialProgress: false
        )
    }

    private func scheduleTransientRetry(
        after delay: TimeInterval,
        generation: Int,
        serverURL: String,
        user: SyncAuthenticatedUser,
        modelContext: ModelContext
    ) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self,
                  self.syncGeneration == generation,
                  self.authenticatedUser?.id == user.id else { return }
            self.retryTask = nil
            self.restartMerge(
                serverURL: serverURL,
                user: user,
                modelContext: modelContext
            )
        }
    }

    private func nextTransientRetryDelay() -> TimeInterval {
        transientSyncFailureCount += 1
        let exponent = min(max(transientSyncFailureCount - 1, 0), 6)
        return min(TimeInterval(5 * (1 << exponent)), 300)
    }

    private func resetRetryState() {
        retryTask?.cancel()
        retryTask = nil
        transientSyncFailureCount = 0
        syncGeneration &+= 1
    }

    private func currentCommands(
        modelContext: ModelContext,
        fallback: [SyncLocalCommand]
    ) -> [SyncLocalCommand] {
        (try? modelContext.fetch(FetchDescriptor<SyncLocalCommand>(
            sortBy: [SortDescriptor(\SyncLocalCommand.createdAt)]
        ))) ?? fallback
    }

    /// Routine relay passes must scale with the outbox, not with the journal.
    /// Remote changes that are not represented here are resolved by indexed
    /// SwiftData lookups inside `SyncService`.
    private func automaticSyncInputs(
        modelContext: ModelContext,
        userID: UUID
    ) -> (tags: [JournalTag], entries: [JournalEntry], commands: [SyncLocalCommand]) {
        let commands = (try? modelContext.fetch(FetchDescriptor<SyncLocalCommand>(
            predicate: #Predicate { $0.sentAt == nil },
            sortBy: [SortDescriptor(\SyncLocalCommand.createdAt)]
        ))) ?? []
        let tags = (try? modelContext.fetch(FetchDescriptor<JournalTag>(
            sortBy: [SortDescriptor(\JournalTag.createdAt)]
        ))) ?? []
        let entryIDs = Set(commands.compactMap { command -> UUID? in
            guard command.type == .entryUpsert,
                  command.ownerUserID == nil || command.ownerUserID == userID else { return nil }
            return UUID(uuidString: command.subjectID)
        })
        let entries = entryIDs.compactMap { id -> JournalEntry? in
            var descriptor = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try? modelContext.fetch(descriptor).first
        }
        return (tags, entries, commands)
    }

    private func consume(_ event: SyncTransferEvent) {
        switch event {
        case .restoreTotals(let records, let media, let tags):
            flushProgressDeltas()
            progress?.totalRecords = records
            progress?.totalMedia = media
            progress?.totalTags = tags
        case .localRestoreBaseline(let records, let media, let tags):
            flushProgressDeltas()
            progress?.restoredRecords = min(records, progress?.totalRecords ?? records)
            progress?.restoredMedia = min(media, progress?.totalMedia ?? media)
            progress?.restoredTags = min(tags, progress?.totalTags ?? tags)
        case .uploadTotals(let records, let media):
            progress?.totalUploadRecords = records
            progress?.totalUploadMedia = media
        case .downloading: progress?.phase = .downloading
        case .uploading: progress?.phase = .uploading
        case .restoredTag: pendingProgress.restoredTags += 1; scheduleProgressFlush()
        case .restoredRecord: pendingProgress.restoredRecords += 1; scheduleProgressFlush()
        case .restoredMedia: pendingProgress.restoredMedia += 1; scheduleProgressFlush()
        case .uploadedRecord: pendingProgress.uploadedRecords += 1; scheduleProgressFlush()
        case .uploadedMedia: pendingProgress.uploadedMedia += 1; scheduleProgressFlush()
        case .skippedPrivateRecord: pendingProgress.skippedPrivateRecords += 1; scheduleProgressFlush()
        }
    }

    private func scheduleProgressFlush() {
        guard progressFlushTask == nil else { return }
        progressFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self else { return }
            flushProgressDeltas()
            progressFlushTask = nil
        }
    }

    private func flushProgressDeltas() {
        progressFlushTask?.cancel()
        progressFlushTask = nil
        guard pendingProgress != .zero else { return }
        progress?.restoredTags += pendingProgress.restoredTags
        progress?.restoredRecords += pendingProgress.restoredRecords
        progress?.restoredMedia += pendingProgress.restoredMedia
        progress?.uploadedRecords += pendingProgress.uploadedRecords
        progress?.uploadedMedia += pendingProgress.uploadedMedia
        progress?.skippedPrivateRecords += pendingProgress.skippedPrivateRecords
        pendingProgress = .zero
    }

    private func prepareAccountScope(
        for user: SyncAuthenticatedUser,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry],
        commands: [SyncLocalCommand]
    ) throws -> (tags: [JournalTag], entries: [JournalEntry]) {
        guard let previousValue = defaults.string(forKey: lastUserKey),
              let previousID = UUID(uuidString: previousValue),
              previousID != user.id else { return (tags, entries) }

        let dirtyIDs = Set(commands.filter { $0.isPending && $0.ownerUserID == previousID }.map(\.subjectID))
        let removableEntries = entries.filter {
            $0.syncOwnerUserID == previousID
                && $0.acknowledgedServerRevision != nil
                && !dirtyIDs.contains($0.id.uuidString)
        }
        let removableEntryIDs = Set(removableEntries.map(\.id))
        let retainedEntries = entries.filter { !removableEntryIDs.contains($0.id) }
        let retainedMediaIDs = Set(retainedEntries.flatMap(\.mediaItems).map(\.id))
        let removableMedia = removableEntries
            .flatMap(\.mediaItems)
            .filter { !retainedMediaIDs.contains($0.id) }
        for entry in removableEntries {
            modelContext.delete(entry)
        }

        let retainedTagCompactIDs = Set(retainedEntries.flatMap(\.tagIDs))
        let removableTags = tags.filter {
            $0.syncOwnerUserID == previousID
                && $0.acknowledgedServerRevision != nil
                && !dirtyIDs.contains($0.id.uuidString)
                && !retainedTagCompactIDs.contains($0.compactID)
        }
        let removableTagIDs = Set(removableTags.map(\.id))
        removableTags.forEach(modelContext.delete)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        // Files are external to SwiftData. Remove them only after the projection
        // deletion has committed, so a failed save cannot strand live records.
        removableMedia.forEach(MediaStorage.delete)
        return (tags.filter { !removableTagIDs.contains($0.id) }, retainedEntries)
    }

    private func seedLocalCommands(
        user: SyncAuthenticatedUser,
        modelContext: ModelContext,
        tags: [JournalTag],
        entries: [JournalEntry],
        commands: [SyncLocalCommand]
    ) throws {
        let commandsBySubject = Dictionary(
            grouping: commands.filter(\.isPending),
            by: \.subjectID
        )
        for tag in tags where tag.syncOwnerUserID == nil {
            tag.syncOwnerUserID = user.id
            SyncLocalCommand.enqueue(
                .tagUpsert,
                subjectID: tag.id.uuidString,
                ownerUserID: user.id,
                existing: commandsBySubject[tag.id.uuidString] ?? [],
                modelContext: modelContext
            )
        }
        for entry in entries where entry.syncOwnerUserID == nil {
            entry.syncOwnerUserID = user.id
            SyncLocalCommand.enqueue(
                .entryUpsert,
                subjectID: entry.id.uuidString,
                ownerUserID: user.id,
                remoteResourceID: entry.publicID,
                existing: commandsBySubject[entry.id.uuidString] ?? [],
                modelContext: modelContext
            )
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}

private struct SyncProgressDelta: Equatable {
    var restoredTags = 0
    var restoredRecords = 0
    var restoredMedia = 0
    var uploadedRecords = 0
    var uploadedMedia = 0
    var skippedPrivateRecords = 0

    static let zero = SyncProgressDelta()
}

@MainActor
final class AppServices: ObservableObject {
    let eclipseService: any EclipseService
    let clockService: any SarosClockService
    let moonPhaseService: any MoonPhaseService
    let notificationScheduler: NotificationScheduler
    let exportService: ExportService
    let syncService: SyncService
    let syncCoordinator: SyncCoordinator
    let weatherService: any WeatherService
    let sarosFlipDistributionStore: SarosFlipDistributionStore
    let sarosEventContextService: SarosEventContextService

    init(
        eclipseService: any EclipseService = CPlusPlusEclipseService(),
        moonPhaseService: any MoonPhaseService = BundledMoonPhaseService()
    ) {
        self.eclipseService = eclipseService
        self.clockService = DefaultSarosClockService(eclipseService: eclipseService)
        self.moonPhaseService = moonPhaseService
        self.notificationScheduler = .shared
        self.exportService = ExportService()
        let syncService = SyncService()
        self.syncService = syncService
        self.syncCoordinator = SyncCoordinator(service: syncService)
        self.weatherService = OpenMeteoWeatherService()
        self.sarosFlipDistributionStore = SarosFlipDistributionStore()
        self.sarosEventContextService = SarosEventContextService(eclipseService: eclipseService)
    }
}

import SwiftData
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \ThreadGroup.createdAt, order: .forward) private var threadGroups: [ThreadGroup]
    @Query(sort: \JournalRecord.createdAt, order: .reverse) private var records: [JournalRecord]
    @Query(sort: \CustomFlipEvent.date, order: .forward) private var customFlips: [CustomFlipEvent]

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""
    @AppStorage(JournalSettings.autoSyncEnabledKey) private var autoSyncEnabled = false
    @StateObject private var server = LocalExportServer()
    @State private var exportURL: URL?
    @State private var diagnosticMessage = ""
    @State private var syncMessage = ""
    @State private var errorMessage: String?
    @State private var isSyncing = false
    @State private var datasetSummary = AnimacyDatasetQueueSummary.empty
    @State private var datasetMessage = ""
    @State private var isUploadingDataset = false

    var body: some View {
        Form {
            Section("Saros clock") {
                Stepper(
                    "Glyph depth \(harmonicDepth)",
                    value: $harmonicDepth,
                    in: JournalSettings.supportedHarmonicDepth
                )

                Text("Depth controls glyph shape, flip timing, and which rarity orders exist.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    RarityPeriodsSettingsView()
                } label: {
                    Label("Periods", systemImage: "clock.arrow.circlepath")
                }
            }

            Section("Threads") {
                NavigationLink {
                    ThreadGroupSettingsView()
                } label: {
                    Label("Groups", systemImage: "circle.grid.2x2")
                }
            }

            Section("Notifications") {
                NavigationLink {
                    FlipNotificationSettingsView()
                } label: {
                    Label("Flip rarities", systemImage: "slider.horizontal.3")
                }

                Button {
                    Task {
                        await services.notificationScheduler.refreshSchedules(
                            for: entities,
                            clockService: services.clockService,
                            harmonicDepth: harmonicDepth,
                            customFlips: customFlips
                        )
                        diagnosticMessage = "Notification schedule refreshed."
                    }
                } label: {
                    Label("Refresh schedules", systemImage: "bell.badge")
                }
            }

            Section("Export") {
                Button {
                    exportArchive()
                } label: {
                    Label("Write JSON export", systemImage: "square.and.arrow.down")
                }

                if let exportURL {
                    Text(exportURL.path)
                        .font(.footnote)
                        .textSelection(.enabled)
                }

                Button {
                    toggleServer()
                } label: {
                    Label(server.isRunning ? "Stop local server" : "Start local server", systemImage: server.isRunning ? "stop.circle" : "network")
                }

                if let urlString = server.urlString {
                    Text(urlString)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }

            Section("LAN Sync") {
                TextField("http://192.168.1.10:8787", text: $syncServerURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Button {
                    Task { await testSyncServer() }
                } label: {
                    Label("Test server connection", systemImage: "network.badge.shield.half.filled")
                }
                .disabled(isSyncing)

                Button {
                    Task { await pushSyncBackup() }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Label("Upload all records", systemImage: "arrow.up.doc")
                    }
                }
                .disabled(isSyncing)

                Button {
                    Task { await pushSyncDelta() }
                } label: {
                    Label("Sync new records now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing)

                Toggle(isOn: $autoSyncEnabled) {
                    Label("Auto sync new records", systemImage: autoSyncEnabled ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                }

                Button {
                    Task { await restoreSyncBackup() }
                } label: {
                    Label("Restore from server folders", systemImage: "arrow.down.doc")
                }
                .disabled(isSyncing)

                if !syncMessage.isEmpty {
                    Text(syncMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Animacy Dataset") {
                MetadataRow(title: "Pending captures", value: "\(datasetSummary.pendingCaptureCount)")
                MetadataRow(title: "Failed captures", value: "\(datasetSummary.failedCaptureCount)")
                MetadataRow(title: "Completed captures", value: "\(datasetSummary.completedCaptureCount)")
                MetadataRow(title: "Queued samples", value: "\(datasetSummary.pendingTransformationCount)")
                MetadataRow(title: "Uploaded samples", value: "\(datasetSummary.completedTransformationCount)")

                Button {
                    Task { await uploadPendingDatasetCaptures() }
                } label: {
                    if isUploadingDataset {
                        ProgressView()
                    } else {
                        Label("Upload pending captures", systemImage: "arrow.up.circle")
                    }
                }
                .disabled(isUploadingDataset || !datasetSummary.hasPendingUploads)

                Button(role: .destructive) {
                    clearCompletedDatasetCaptures()
                } label: {
                    Label("Clear completed uploads", systemImage: "trash")
                }
                .disabled(datasetSummary.completedCaptureCount == 0)

                if !datasetMessage.isEmpty {
                    Text(datasetMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostics") {
                Button {
                    runDiagnostics()
                } label: {
                    Label("Check eclipse data", systemImage: "stethoscope")
                }

                if !diagnosticMessage.isEmpty {
                    Text(diagnosticMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .task {
            refreshDatasetSummary()
        }
        .onChange(of: harmonicDepth) { _, newDepth in
            Task {
                await services.notificationScheduler.refreshSchedules(
                    for: entities,
                    clockService: services.clockService,
                    harmonicDepth: newDepth,
                    customFlips: customFlips
                )
                diagnosticMessage = "Glyph depth updated and notification schedule refreshed."
            }
        }
        .alert("Settings error", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func exportArchive() {
        do {
            exportURL = try services.exportService.exportJSON(entities: entities, records: records, groups: threadGroups)
            diagnosticMessage = "Export written."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleServer() {
        do {
            if server.isRunning {
                server.stop()
            } else {
                let url = try services.exportService.exportJSON(entities: entities, records: records, groups: threadGroups)
                exportURL = url
                try server.start(exportDirectory: url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func testSyncServer() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let status = try await services.syncService.checkStatus(from: syncServerURL)
            if let exportTimestamp = status.exportTimestamp, status.hasBackup {
                syncMessage = "Server OK. Folder state \(exportTimestamp.formatted(date: .abbreviated, time: .shortened)): \(status.entityCount) threads, \(status.recordCount) records, \(status.mediaCount) media files."
            } else {
                syncMessage = "Server OK. No records have been uploaded yet."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func pushSyncBackup() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let summary = try await services.syncService.push(
                to: syncServerURL,
                entities: entities,
                records: records,
                groups: threadGroups
            )
            syncMessage = "Uploaded \(summary.entityCount) threads, \(summary.recordCount) records, \(summary.mediaCount) media files."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func pushSyncDelta() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let summary = try await services.syncService.pushMissingRecords(
                to: syncServerURL,
                entities: entities,
                records: records,
                groups: threadGroups
            )
            if summary.recordCount == 0 {
                syncMessage = "No new records to upload."
            } else {
                syncMessage = "Uploaded \(summary.recordCount) new records with \(summary.mediaCount) media files."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func restoreSyncBackup() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let summary = try await services.syncService.restoreLatest(
                from: syncServerURL,
                modelContext: modelContext,
                entities: entities,
                records: records,
                groups: threadGroups
            )
            syncMessage = "Restored \(summary.entityCount) threads, \(summary.recordCount) records, \(summary.mediaCount) media files from server folders."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runDiagnostics() {
        do {
            let allSeries = try services.eclipseService.allSarosSeries()
            let nearest = try services.eclipseService.nearestEclipse(to: Date())
            diagnosticMessage = "\(allSeries.count) Saros series loaded. Nearest eclipse: Saros \(nearest?.saros ?? 0)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshDatasetSummary() {
        do {
            datasetSummary = try services.animacyDatasetQueue.summary()
        } catch {
            datasetMessage = error.localizedDescription
        }
    }

    @MainActor
    private func uploadPendingDatasetCaptures() async {
        isUploadingDataset = true
        defer {
            isUploadingDataset = false
            refreshDatasetSummary()
        }

        do {
            let summary = try await services.animacyDatasetQueue.uploadPending(to: syncServerURL)
            if summary.attemptedCount == 0 {
                datasetMessage = "No pending animacy captures."
            } else if summary.failedCount > 0 {
                datasetMessage = "Uploaded \(summary.uploadedCount), failed \(summary.failedCount). \(summary.lastError ?? "")"
            } else {
                datasetMessage = "Uploaded \(summary.uploadedCount) animacy captures."
            }
        } catch {
            datasetMessage = error.localizedDescription
        }
    }

    private func clearCompletedDatasetCaptures() {
        do {
            datasetSummary = try services.animacyDatasetQueue.clearCompleted()
            datasetMessage = "Cleared completed animacy uploads."
        } catch {
            datasetMessage = error.localizedDescription
        }
    }
}

private struct ThreadGroupSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \ThreadGroup.createdAt, order: .forward) private var threadGroups: [ThreadGroup]

    @State private var groupDraft: ThreadGroupDraft?

    private var commonMembers: [TrackedEntity] {
        entities.filter { $0.groupID == nil }
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ThreadGroupMembersView(
                        title: ThreadGroup.commonName,
                        emoji: ThreadGroup.commonEmoji,
                        rarity: ThreadGroup.commonRarity,
                        groupID: nil
                    )
                } label: {
                    ThreadGroupSettingsRow(
                        title: ThreadGroup.commonName,
                        emoji: ThreadGroup.commonEmoji,
                        rarity: ThreadGroup.commonRarity,
                        memberCount: commonMembers.count
                    )
                }
            }

            Section("Custom groups") {
                if threadGroups.isEmpty {
                    ContentUnavailableView("No custom groups", systemImage: "circle.grid.2x2")
                } else {
                    ForEach(threadGroups) { group in
                        NavigationLink {
                            ThreadGroupDetailView(group: group)
                        } label: {
                            ThreadGroupSettingsRow(
                                title: group.displayName,
                                emoji: group.displayEmoji,
                                rarity: group.rarity,
                                memberCount: memberCount(for: group)
                            )
                        }
                    }
                    .onDelete(perform: deleteGroups)
                }
            }
        }
        .navigationTitle("Groups")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    groupDraft = ThreadGroupDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add group")
            }
        }
        .sheet(item: $groupDraft) { draft in
            NavigationStack {
                ThreadGroupEditorView(draft: draft) { savedDraft in
                    addGroup(savedDraft)
                }
            }
        }
    }

    private func memberCount(for group: ThreadGroup) -> Int {
        entities.filter { $0.groupID == group.id }.count
    }

    private func addGroup(_ draft: ThreadGroupDraft) {
        modelContext.insert(ThreadGroup(
            name: draft.name,
            emoji: draft.emoji,
            rarity: draft.rarity
        ))
        try? modelContext.save()
    }

    private func deleteGroups(at offsets: IndexSet) {
        let groupsToDelete = offsets.map { threadGroups[$0] }
        for group in groupsToDelete {
            deleteGroup(group)
        }
        try? modelContext.save()
    }

    private func deleteGroup(_ group: ThreadGroup) {
        for entity in entities where entity.groupID == group.id {
            entity.groupID = nil
            entity.touch()
        }
        modelContext.delete(group)
    }
}

private struct ThreadGroupDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]

    let group: ThreadGroup
    @State private var groupDraft: ThreadGroupDraft?
    @State private var isConfirmingDelete = false

    private var members: [TrackedEntity] {
        entities.filter { $0.groupID == group.id }
    }

    var body: some View {
        List {
            Section {
                ThreadGroupSettingsRow(
                    title: group.displayName,
                    emoji: group.displayEmoji,
                    rarity: group.rarity,
                    memberCount: members.count
                )

                Button {
                    groupDraft = ThreadGroupDraft(group: group)
                } label: {
                    Label("Edit group", systemImage: "pencil")
                }
            }

            Section("Members") {
                if members.isEmpty {
                    ContentUnavailableView("No members", systemImage: "person.2.slash")
                } else {
                    ForEach(members) { entity in
                        ThreadGroupMemberRow(entity: entity)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete group", systemImage: "trash")
                }
            }
        }
        .navigationTitle(group.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $groupDraft) { draft in
            NavigationStack {
                ThreadGroupEditorView(draft: draft) { savedDraft in
                    updateGroup(savedDraft)
                }
            }
        }
        .confirmationDialog(
            "Delete \(group.displayName)?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) {
                deleteGroup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Threads in this group will move back to Common.")
        }
    }

    private func updateGroup(_ draft: ThreadGroupDraft) {
        group.name = draft.name
        group.emoji = draft.emoji
        group.rarity = draft.rarity
        group.touch()
        try? modelContext.save()
    }

    private func deleteGroup() {
        for entity in members {
            entity.groupID = nil
            entity.touch()
        }
        modelContext.delete(group)
        try? modelContext.save()
        dismiss()
    }
}

private struct ThreadGroupMembersView: View {
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]

    let title: String
    let emoji: String
    let rarity: FlipRarity
    let groupID: UUID?

    private var members: [TrackedEntity] {
        entities.filter { entity in
            switch groupID {
            case .none:
                entity.groupID == nil
            case .some(let groupID):
                entity.groupID == groupID
            }
        }
    }

    var body: some View {
        List {
            Section {
                ThreadGroupSettingsRow(
                    title: title,
                    emoji: emoji,
                    rarity: rarity,
                    memberCount: members.count
                )
            }

            Section("Members") {
                if members.isEmpty {
                    ContentUnavailableView("No members", systemImage: "person.2.slash")
                } else {
                    ForEach(members) { entity in
                        ThreadGroupMemberRow(entity: entity)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ThreadGroupSettingsRow: View {
    let title: String
    let emoji: String
    let rarity: FlipRarity
    let memberCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(emoji)
                .font(.title2)
                .frame(width: 42, height: 42)
                .background(rarity.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(rarity.color.opacity(0.25), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    FlipRarityBadge(rarity: rarity, compact: true)
                    Text("\(memberCount) \(memberCount == 1 ? "thread" : "threads")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ThreadGroupMemberRow: View {
    let entity: TrackedEntity

    var body: some View {
        HStack(spacing: 12) {
            if let emoji = entity.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.title3)
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "moonphase.new.moon")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(entity.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("Saros \(entity.saros)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RarityPeriodsSettingsView: View {
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    var body: some View {
        List {
            Section {
                MetadataRow(title: "Glyph depth", value: "\(JournalSettings.clampedHarmonicDepth(harmonicDepth))")
                MetadataRow(title: "Average Saros", value: Self.durationFormatter.string(from: JournalSettings.averageSarosPeriod) ?? JournalSettings.averageSarosPeriod.compactDuration)
                Text("Periods use repeated suffix patterns over the average Saros interval, so rarity spacing stays stable as glyph depth changes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Average periods") {
                ForEach(FlipRarity.rarityGroups(for: harmonicDepth)) { group in
                    DisclosureGroup {
                        ForEach(group.subrarities) { rarity in
                            RarityPeriodRow(rarity: rarity, harmonicDepth: harmonicDepth)
                        }
                    } label: {
                        RarityPeriodRow(rarity: group.header, harmonicDepth: harmonicDepth)
                    }
                }
            }
        }
        .navigationTitle("Periods")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.year, .month, .day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 3
        return formatter
    }()
}

private struct RarityPeriodRow: View {
    let rarity: FlipRarity
    let harmonicDepth: Int

    private var divisions: Int {
        rarity.basePeriodDivisions
    }

    private var periodDuration: TimeInterval {
        let basePeriod = JournalSettings.averageSarosPeriod / Double(divisions)
        guard !rarity.isHeaderRarity else { return basePeriod }
        return basePeriod * Double(max(rarity.repeatedDigit, 1)) / 7
    }

    private var detailText: String {
        if rarity.isHeaderRarity {
            return "\(String(divisions, radix: 8)) divisions"
        }
        return "\(rarity.repeatedDigit)/7 into \(rarity.baseRarity.title.lowercased()) range"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    FlipRarityGlyphIcon(rarity: rarity, harmonicDepth: harmonicDepth, size: 24)
                    Text(rarity.title)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(rarity.color)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.durationFormatter.string(from: periodDuration) ?? periodDuration.compactDuration)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.year, .month, .day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 3
        return formatter
    }()
}

private struct FlipNotificationSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \CustomFlipEvent.date, order: .forward) private var customFlips: [CustomFlipEvent]

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @State private var preferences: [FlipNotificationRarityPreference] = []
    @State private var didLoad = false
    @State private var statusMessage = ""

    var body: some View {
        Form {
            Section {
                ForEach(FlipRarity.rarityGroups(for: harmonicDepth)) { group in
                    if let index = preferenceIndex(for: group.header) {
                        RarityPreferenceRow(preference: $preferences[index])
                    }

                    DisclosureGroup {
                        ForEach(group.subrarities) { rarity in
                            if let index = preferenceIndex(for: rarity) {
                                RarityPreferenceRow(preference: $preferences[index])
                            }
                        }
                    } label: {
                        Label("Sub-rarities", systemImage: "square.stack.3d.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(group.header.color)
                    }
                }
            } footer: {
                Text("Notifications use repeated suffixes. The visible row is the trailing-zero header; expand it to tune trailing 1...7 sub-rarities.")
            }

            Section {
                Button {
                    resetDefaults()
                } label: {
                    Label("Reset rarity defaults", systemImage: "arrow.counterclockwise")
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Flip Rarities")
        .onAppear {
            load()
        }
        .onChange(of: harmonicDepth) { _, _ in
            load(force: true)
        }
        .onChange(of: preferences) { _, newPreferences in
            guard didLoad else { return }
            FlipNotificationPreferences.save(newPreferences)
            Task {
                await services.notificationScheduler.refreshSchedules(
                    for: entities,
                    clockService: services.clockService,
                    harmonicDepth: harmonicDepth,
                    customFlips: customFlips
                )
                statusMessage = "Notification schedule refreshed."
            }
        }
    }

    private func load(force: Bool = false) {
        guard force || !didLoad else { return }
        preferences = FlipNotificationPreferences.load(for: harmonicDepth)
        didLoad = true
    }

    private func resetDefaults() {
        preferences = FlipNotificationPreferences.defaults(for: harmonicDepth)
    }

    private func preferenceIndex(for rarity: FlipRarity) -> Int? {
        preferences.firstIndex { $0.rarity == rarity }
    }
}

private struct RarityPreferenceRow: View {
    @Binding var preference: FlipNotificationRarityPreference
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    FlipRarityGlyphIcon(rarity: preference.rarity, harmonicDepth: harmonicDepth, size: 26)
                    Text(preference.rarity.title)
                        .font(.headline)
                }
                .foregroundStyle(preference.rarity.color)
                Spacer()
                Picker("Mode", selection: $preference.mode) {
                    ForEach(FlipNotificationMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbolName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            if preference.mode.usesAdvanceTime {
                Stepper(
                    "Show \(preference.advanceMinutes)m before",
                    value: $preference.advanceMinutes,
                    in: 1...1_440,
                    step: 5
                )
            } else {
                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(preference.rarity.patternLabel(harmonicDepth: harmonicDepth))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var modeDescription: String {
        switch preference.mode {
        case .silent:
            "No notification for this rarity."
        case .event:
            "Regular notification at the flip moment."
        case .live:
            "Countdown-style notification before the flip."
        case .alarm:
            "Alarm-like time-sensitive notification before the flip."
        }
    }
}

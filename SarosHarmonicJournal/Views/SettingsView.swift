import SwiftData
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \JournalTag.createdAt, order: .forward) private var tags: [JournalTag]
    @Query(sort: \JournalEntry.eventDate, order: .reverse) private var entries: [JournalEntry]

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""
    @AppStorage(JournalSettings.autoSyncEnabledKey) private var autoSyncEnabled = false
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

            Section("Camera") {
                NavigationLink {
                    MirrorCameraView()
                } label: {
                    Label("Open camera", systemImage: "camera.viewfinder")
                }
            }

            Section("Notifications") {
                Button {
                    Task {
                        await services.notificationScheduler.refreshGlobalSarosEventSchedules(
                            eclipseService: services.eclipseService,
                            harmonicDepth: harmonicDepth
                        )
                        diagnosticMessage = "Notification schedule refreshed."
                    }
                } label: {
                    Label("Refresh peak schedule", systemImage: "bell.badge")
                }

                if !diagnosticMessage.isEmpty {
                    Text(diagnosticMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                        Label("Sync phone state", systemImage: "arrow.up.doc")
                    }
                }
                .disabled(isSyncing)

                Button {
                    Task { await pushSyncDelta() }
                } label: {
                    Label("Sync phone state now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing)

                Toggle(isOn: $autoSyncEnabled) {
                    Label("Auto sync phone state", systemImage: autoSyncEnabled ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
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

        }
        .navigationTitle("Settings")
        .task {
            refreshDatasetSummary()
        }
        .onChange(of: harmonicDepth) { _, newDepth in
            Task {
                await services.notificationScheduler.refreshGlobalSarosEventSchedules(
                    eclipseService: services.eclipseService,
                    harmonicDepth: newDepth
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

    @MainActor
    private func testSyncServer() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let status = try await services.syncService.checkStatus(from: syncServerURL)
            if let exportTimestamp = status.exportTimestamp, status.hasBackup {
                syncMessage = "Server OK. Folder state \(exportTimestamp.formatted(date: .abbreviated, time: .shortened)): \(status.entityCount) tags, \(status.recordCount) records, \(status.mediaCount) media files."
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
            let summary = try await services.syncService.pushEntries(
                to: syncServerURL,
                tags: tags,
                entries: entries
            )
            syncMessage = "Synced \(summary.entityCount) tags, \(summary.recordCount) records, \(summary.mediaCount) media files."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func pushSyncDelta() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let summary = try await services.syncService.pushMissingEntries(
                to: syncServerURL,
                tags: tags,
                entries: entries
            )
            syncMessage = "Synced \(summary.entityCount) tags, \(summary.recordCount) records, \(summary.mediaCount) media files."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func restoreSyncBackup() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let summary = try await services.syncService.restoreLatestEntries(
                from: syncServerURL,
                modelContext: modelContext,
                tags: tags,
                entries: entries
            )
            syncMessage = "Restored \(summary.entityCount) tags, \(summary.recordCount) records, \(summary.mediaCount) media files from server folders."
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

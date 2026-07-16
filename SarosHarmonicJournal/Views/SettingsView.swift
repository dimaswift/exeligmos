import SwiftData
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \JournalTag.createdAt, order: .forward) private var tags: [JournalTag]
    @Query(sort: \JournalEntry.eventDate, order: .reverse) private var entries: [JournalEntry]
    @Query(sort: \SyncLocalCommand.createdAt, order: .forward) private var syncCommands: [SyncLocalCommand]

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @AppStorage(JournalSettings.syncServerURLKey) private var syncServerURL = ""
    @AppStorage(JournalSettings.deviceIDKey) private var deviceID = ""
    @AppStorage(JournalSettings.deviceNameKey) private var deviceName = ""
    @AppStorage(JournalSettings.deviceEmojiKey) private var deviceEmoji = ""
    @AppStorage(JournalSettings.lastSyncAtKey) private var lastSyncAt = 0.0
    @State private var diagnosticMessage = ""
    @State private var syncMessage = ""
    @State private var errorMessage: String?
    @State private var isSyncing = false
    @State private var deviceUpdateTask: Task<Void, Never>?
    @State private var isStartingLiveTracking = false
    @State private var liveTrackingMessage = ""
    @State private var syncLogin = ""
    @State private var syncPassword = ""
    @State private var syncDisplayName = ""
    @State private var syncInviteCode = ""
    @State private var syncAuthMode = SyncAuthMode.signIn
    @State private var authenticatedUser: SyncAuthenticatedUser?
    @State private var serverConnectionState = SyncServerConnectionState.idle

    var body: some View {
        Form {
            Section("Saros clock") {
                NavigationLink {
                    RarityPeriodsSettingsView()
                } label: {
                    Label("Periods", systemImage: "clock.arrow.circlepath")
                }

                NavigationLink {
                    SarosTimeUnitsSettingsView()
                } label: {
                    Label("Time Units", systemImage: "timer")
                }

                NavigationLink {
                    SarosSpaceUnitsSettingsView()
                } label: {
                    Label("Space Units", systemImage: "ruler")
                }

                NavigationLink {
                    WaveformSettingsView()
                } label: {
                    Label("Waveform", systemImage: "waveform.path.ecg")
                }

                NavigationLink {
                    EarthAnomalisticIntervalsSettingsView()
                } label: {
                    Label("Solar ruler", systemImage: "sun.max")
                }

                NavigationLink {
                    CatalogView()
                } label: {
                    Label("Catalog", systemImage: "globe.europe.africa")
                }

                NavigationLink {
                    TagsView()
                } label: {
                    Label("Tags", systemImage: "tag")
                }
            }

            Section("Pulse") {
                NavigationLink {
                    PulseSettingsView()
                } label: {
                    Label("Pulse reference", systemImage: "ruler")
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
                    Task { await startLiveTracking() }
                } label: {
                    if isStartingLiveTracking {
                        ProgressView()
                    } else {
                        Label("Live tracking", systemImage: "waveform.path.ecg")
                    }
                }
                .disabled(isStartingLiveTracking)

                Button {
                    Task {
                        await services.notificationScheduler.refreshGlobalSarosEventSchedules(
                            eclipseService: services.eclipseService,
                            moonPhaseService: services.moonPhaseService,
                            harmonicDepth: harmonicDepth,
                            recentEntries: entries
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

                if !liveTrackingMessage.isEmpty {
                    Text(liveTrackingMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Exeligmos Server") {
                HStack {
                    Text("Device")
                    Spacer()
                    Text(deviceID)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                TextField("Channel name", text: $deviceName)
                    .textInputAutocapitalization(.words)

                TextField("Emoji", text: $deviceEmoji)
                    .frame(maxWidth: 90)

                TextField("https://journal.example.com", text: $syncServerURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Label(serverConnectionState.title, systemImage: serverConnectionState.icon)
                    .foregroundStyle(serverConnectionState.color)

                if let authenticatedUser {
                    HStack {
                        Label("Signed in", systemImage: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(.green)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(authenticatedUser.displayName)
                            Text("@\(authenticatedUser.login)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Sign out", role: .destructive) {
                        Task { await signOut() }
                    }
                    .disabled(isSyncing)
                } else {
                    Picker("Account action", selection: $syncAuthMode) {
                        ForEach(SyncAuthMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Login", text: $syncLogin)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $syncPassword)
                        .textContentType(syncAuthMode == .signIn ? .password : .newPassword)

                    if syncAuthMode == .register {
                        TextField("Display name (optional)", text: $syncDisplayName)
                            .textContentType(.name)
                        TextField("Invite code (if required)", text: $syncInviteCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()

                        Text(
                            "Login: 3–64 characters using letters, numbers, periods, underscores, or hyphens. " +
                                "Password: at least 12 characters."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await authenticate() }
                    } label: {
                        if isSyncing {
                            ProgressView()
                        } else {
                            Label(syncAuthMode.buttonTitle, systemImage: syncAuthMode.icon)
                        }
                    }
                    .disabled(
                        isSyncing
                            || syncServerURL.nilIfBlank == nil
                            || syncLogin.nilIfBlank == nil
                            || syncPassword.isEmpty
                    )
                }

                Button {
                    Task { await testSyncServer() }
                } label: {
                    Label("Test server", systemImage: "network.badge.shield.half.filled")
                }
                .disabled(isSyncing)

                Button {
                    Task { await syncWithServer() }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isSyncing || authenticatedUser == nil)

                if !syncMessage.isEmpty {
                    Text(syncMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text(lastSyncText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        }
        .navigationTitle("Settings")
        .task {
            let device = JournalDevice.ensureIdentity()
            deviceID = device.id
            deviceName = device.name
            deviceEmoji = device.emoji
        }
        .task(id: syncServerURL) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await refreshAuthenticationState()
        }
        .onChange(of: harmonicDepth) { _, newDepth in
            Task {
                await services.notificationScheduler.refreshGlobalSarosEventSchedules(
                    eclipseService: services.eclipseService,
                    moonPhaseService: services.moonPhaseService,
                    harmonicDepth: newDepth,
                    recentEntries: entries
                )
                diagnosticMessage = "Glyph depth updated and notification schedule refreshed."
            }
        }
        .onChange(of: deviceName) { _, _ in
            scheduleDeviceProfileUpdate()
        }
        .onChange(of: deviceEmoji) { _, _ in
            scheduleDeviceProfileUpdate()
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
            _ = try await services.syncService.checkStatus(from: syncServerURL)
            serverConnectionState = .ready
            await refreshAuthenticationState()
            syncMessage = authenticatedUser == nil
                ? "Server is ready. Sign in before syncing."
                : "Server is ready and this device is authenticated."
        } catch {
            setServerFailure(error)
        }
    }

    @MainActor
    private func authenticate() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let user: SyncAuthenticatedUser
            switch syncAuthMode {
            case .signIn:
                user = try await services.syncService.login(
                    to: syncServerURL,
                    login: syncLogin,
                    password: syncPassword
                )
            case .register:
                user = try await services.syncService.register(
                    on: syncServerURL,
                    login: syncLogin,
                    password: syncPassword,
                    displayName: syncDisplayName,
                    inviteCode: syncInviteCode
                )
            }
            authenticatedUser = user
            syncPassword = ""
            serverConnectionState = .ready
            syncMessage = "Signed in as @\(user.login). The session is securely bound to this device."
        } catch {
            setServerFailure(error)
        }
    }

    @MainActor
    private func signOut() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            try await services.syncService.logout(from: syncServerURL)
            authenticatedUser = nil
            serverConnectionState = .ready
            syncMessage = "Signed out. Local journal data remains on this device."
        } catch {
            authenticatedUser = nil
            setServerFailure(error)
        }
    }

    @MainActor
    private func refreshAuthenticationState() async {
        guard syncServerURL.nilIfBlank != nil else {
            authenticatedUser = nil
            serverConnectionState = .idle
            return
        }
        do {
            switch try await services.syncService.authenticationState(for: syncServerURL) {
            case .signedOut:
                authenticatedUser = nil
            case .signedIn(let user):
                authenticatedUser = user
                syncLogin = user.login
            }
        } catch {
            authenticatedUser = nil
            serverConnectionState = .error(error.localizedDescription)
        }
    }

    @MainActor
    private func syncWithServer() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let summary = try await services.syncService.synchronizeEntries(
                with: syncServerURL,
                modelContext: modelContext,
                tags: tags,
                entries: entries,
                commands: syncCommands
            )
            serverConnectionState = .ready
            syncMessage = "Synced \(summary.uploadedRecordCount) local and \(summary.restoredRecordCount) server records, \(summary.restoredEntityCount) tags, and \(summary.uploadedMediaCount + summary.restoredMediaCount) media files."
        } catch {
            setServerFailure(error)
        }
    }

    @MainActor
    private func setServerFailure(_ error: Error) {
        if error is URLError {
            serverConnectionState = .offline(error.localizedDescription)
            syncMessage = "Server is offline. Local changes remain queued safely on this device."
        } else if case SyncService.SyncError.authenticationRequired = error {
            authenticatedUser = nil
            serverConnectionState = .ready
            syncMessage = "The server is reachable, but this device is not signed in."
        } else {
            serverConnectionState = .error(error.localizedDescription)
            syncMessage = error.localizedDescription
        }
    }

    private var lastSyncText: String {
        guard lastSyncAt > 0 else {
            return "Last sync: never"
        }
        let elapsed = max(Date().timeIntervalSince1970 - lastSyncAt, 0)
        return "Last sync: \(elapsed.compactDuration) ago"
    }

    private func scheduleDeviceProfileUpdate() {
        deviceUpdateTask?.cancel()
        deviceUpdateTask = Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled,
                  syncServerURL.nilIfBlank != nil,
                  authenticatedUser != nil else { return }
            try? await services.syncService.registerChannel(to: syncServerURL)
        }
    }

    @MainActor
    private func startLiveTracking() async {
        isStartingLiveTracking = true
        defer { isStartingLiveTracking = false }

        let contextService = services.sarosEventContextService
        let eclipseService = services.eclipseService
        let moonPhaseService = services.moonPhaseService
        let depth = harmonicDepth

        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try ThreadLiveActivityService.journalSnapshot(
                    contextService: contextService,
                    eclipseService: eclipseService,
                    moonService: moonPhaseService,
                    date: Date(),
                    harmonicDepth: depth
                )
            }.value
            try await ThreadLiveActivityService.start(snapshot: snapshot)
            liveTrackingMessage = "Live tracking active: \(snapshot.eventName ?? snapshot.rarityTitle)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

private enum SyncAuthMode: String, CaseIterable, Identifiable {
    case signIn
    case register

    var id: String { rawValue }

    var title: String {
        switch self {
        case .signIn: "Sign In"
        case .register: "Create Account"
        }
    }

    var buttonTitle: String {
        switch self {
        case .signIn: "Sign in"
        case .register: "Create account"
        }
    }

    var icon: String {
        switch self {
        case .signIn: "person.crop.circle.badge.checkmark"
        case .register: "person.crop.circle.badge.plus"
        }
    }
}

private enum SyncServerConnectionState {
    case idle
    case ready
    case offline(String)
    case error(String)

    var title: String {
        switch self {
        case .idle: "Server not checked"
        case .ready: "Server ready"
        case .offline: "Server offline"
        case .error(let message): message
        }
    }

    var icon: String {
        switch self {
        case .idle: "network"
        case .ready: "checkmark.circle.fill"
        case .offline: "wifi.slash"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .ready: .green
        case .offline: .orange
        case .error: .red
        }
    }
}

private struct WaveformSettingsView: View {
    @AppStorage(JournalSettings.waveformMergeCloseSpikesKey) private var mergeCloseSpikes = false
    @AppStorage(JournalSettings.waveformNormalizedAmplitudeKey) private var normalizedAmplitude = false
    @AppStorage(JournalSettings.waveformSubdivisionDepthKey) private var subdivisionDepth = JournalWaveformSettings.defaultSubdivisionDepth
    @AppStorage(JournalSettings.waveformAmplitudeMultiplierKey) private var amplitudeMultiplier = JournalWaveformSettings.defaultAmplitudeMultiplier
    @AppStorage(JournalSettings.widgetWaveformKilosarosRangeKey) private var widgetKilosarosRange = JournalWaveformSettings.defaultWidgetWaveformKilosarosRange

    var body: some View {
        List {
            Section {
                Text(JournalWaveformModel.current.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Parabola") {
                MetadataRow(
                    title: "A",
                    value: JournalWaveformSettings.defaultParabolaA.formatted(.number.precision(.fractionLength(1)))
                )

                Text("Parabola sharpness is shared by the app, widget, and Live Activity so energy and momentum stay synchronized.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Spikes") {
                Toggle("Merge close spikes", isOn: $mergeCloseSpikes)
                Toggle("Normalized amplitude", isOn: $normalizedAmplitude)

                HStack {
                    Text("Amplitude")
                    Slider(
                        value: $amplitudeMultiplier,
                        in: JournalWaveformSettings.amplitudeMultiplierRange,
                        step: 0.05
                    )
                    Text("\(clampedAmplitudeMultiplier, format: .number.precision(.fractionLength(2)))x")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Stepper(
                    "Subdivision depth \(clampedSubdivisionDepth)",
                    value: $subdivisionDepth,
                    in: JournalWaveformSettings.subdivisionDepthRange
                )

                Text("Merged spikes use a 1 kilosaros window (36m 10s). Sampling always includes spike and midpoint anchors, then subdivides each segment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Widget") {
                Stepper(
                    "Widget range \(clampedWidgetKilosarosRange) Ks",
                    value: $widgetKilosarosRange,
                    in: JournalWaveformSettings.widgetWaveformKilosarosRange
                )

                Text("Controls how many Kilosaros the widget waveform spans. 8 Ks matches the previous one-Megasaros window.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                MetadataRow(title: "Current model", value: JournalWaveformModel.current.title)
                MetadataRow(title: "Energy", value: "Parabolic segment")
                MetadataRow(title: "Momentum", value: "Energy delta per Saros")
            }
        }
        .navigationTitle("Waveform")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var clampedSubdivisionDepth: Int {
        min(
            max(subdivisionDepth, JournalWaveformSettings.subdivisionDepthRange.lowerBound),
            JournalWaveformSettings.subdivisionDepthRange.upperBound
        )
    }

    private var clampedAmplitudeMultiplier: Double {
        min(
            max(amplitudeMultiplier, JournalWaveformSettings.amplitudeMultiplierRange.lowerBound),
            JournalWaveformSettings.amplitudeMultiplierRange.upperBound
        )
    }

    private var clampedWidgetKilosarosRange: Int {
        JournalWaveformSettings.clampedWidgetWaveformKilosarosRange(widgetKilosarosRange)
    }
}

private struct EarthAnomalisticIntervalsSettingsView: View {
    var body: some View {
        List {
            Section {
                if let reading = EarthAnomalisticRuler.reading(for: Date()) {
                    MetadataRow(title: "Anomalistic", value: reading.octalAddress)
                }
                if let coverage = EarthAnomalisticRuler.coverage {
                    MetadataRow(
                        title: "Coverage",
                        value: "\(Self.yearFormatter.string(from: coverage.start))-\(Self.yearFormatter.string(from: coverage.end))"
                    )
                }
                Text("The waveform ruler stacks anomalistic, solstice, and equinox half-cycles. Red ticks are exact landmarks, yellow ticks mark 1/8, blue ticks mark 1/64, and gray ticks mark 1/512.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Solstice / equinox half-cycle") {
                intervalRows(period: SolarYearRuler.averageTropicalYearDuration() / 2)
            }

            Section("Anomalistic half-cycle") {
                intervalRows(period: EarthAnomalisticRuler.averageYearPeriod() / 2)
            }
        }
        .navigationTitle("Solar Ruler")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func intervalRows(period: TimeInterval) -> some View {
        ForEach(0...6, id: \.self) { exponent in
            MetadataRow(
                title: exponent == 0 ? "Year" : "Year / 8^\(exponent)",
                value: SarosFractalUnitModel.formatTemporalPeriod(period / pow(8.0, Double(exponent)))
            )
        }
    }

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy"
        return formatter
    }()
}

private struct PulseSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @AppStorage(JournalSettings.pulseSarosKey) private var pulseSaros = 0

    @State private var preview: SarosPulseReading?
    @State private var errorMessage: String?

    private var selectedSaros: Binding<Int?> {
        Binding(
            get: { pulseSaros > 0 ? pulseSaros : nil },
            set: { pulseSaros = $0 ?? 0 }
        )
    }

    var body: some View {
        List {
            Section("Reference Saros") {
                SarosGlyphGridPicker(selectedSaros: selectedSaros)

                if let preview, !preview.octalAddress.isEmpty {
                    HStack(spacing: 12) {
                        SarosPulseGlyph(reading: preview, size: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Current pulse")
                                .font(.subheadline.weight(.semibold))
                            Text("Saros \(preview.saros)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("Pulse uses one selected Saros as a six-digit fine ruler.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Ruler") {
                ForEach(SarosPulseUnit.referenceUnits) { unit in
                    HStack {
                        Rectangle()
                            .fill(unit.color)
                            .frame(width: 28, height: 3)
                            .clipShape(Capsule())
                        Text(unit.title)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(pattern(for: unit))
                                .font(.caption.monospaced())
                            Text(Self.durationFormatter.string(from: SarosPulseCalculator.averageDuration(for: unit)) ?? SarosPulseCalculator.averageDuration(for: unit).compactDuration)
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Pulse")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await ensureDefaultSaros()
            updatePreview()
        }
        .onChange(of: pulseSaros) { _, _ in
            updatePreview()
        }
        .onChange(of: harmonicDepth) { _, _ in
            updatePreview()
        }
    }

    @MainActor
    private func ensureDefaultSaros() async {
        guard pulseSaros <= 0 else { return }
        let eclipseService = services.eclipseService
        let result = await Task.detached(priority: .utility) {
            Result {
                try SarosPulseCalculator.defaultActiveSaros(
                    at: Date(),
                    eclipseService: eclipseService
                )
            }
        }.value

        if case .success(let saros?) = result {
            pulseSaros = saros
        }
    }

    private func updatePreview() {
        guard pulseSaros > 0 else {
            preview = nil
            return
        }

        do {
            preview = try SarosPulseCalculator.reading(
                saros: pulseSaros,
                date: Date(),
                harmonicDepth: harmonicDepth,
                eclipseService: services.eclipseService
            )
            errorMessage = nil
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func pattern(for unit: SarosPulseUnit) -> String {
        unit.pattern
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 3
        return formatter
    }()
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
        let suffixLength = max(rarity.repeatedSuffixLength(harmonicDepth: harmonicDepth), 1)
        let carrierDigits = JournalSettings.clampedHarmonicDepth(harmonicDepth)
        let repunitPeriod = SarosFractalUnitModel.landmarkPeriod(
            suffixLength: suffixLength,
            carrierDigits: carrierDigits
        )
        guard !rarity.isHeaderRarity else { return repunitPeriod }
        return repunitPeriod * Double(max(rarity.repeatedDigit, 1))
    }

    private var detailText: String {
        let suffixLength = max(rarity.repeatedSuffixLength(harmonicDepth: harmonicDepth), 1)
        if rarity.isHeaderRarity {
            return "Adjacent repunit interval R\(suffixLength)"
        }
        return "\(rarity.repeatedDigit) x R\(suffixLength)"
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

private struct SarosTimeUnitsSettingsView: View {
    @AppStorage(JournalSettings.unitSpectrumBaseKey) private var baseRawValue = SarosFractalUnitBase.averageSaros.rawValue

    private var base: SarosFractalUnitBase {
        SarosFractalUnitBase(rawValue: baseRawValue) ?? .averageSaros
    }

    private var rows: [SarosFractalTimeUnit] {
        SarosFractalUnitModel.timeRows(basePeriod: base.period)
    }

    var body: some View {
        List {
            Section {
                Picker("Base", selection: $baseRawValue) {
                    ForEach(SarosFractalUnitBase.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                MetadataRow(title: "Period", value: SarosFractalUnitModel.formatTemporalPeriod(base.period))
                MetadataRow(title: "Depth", value: "\(SarosFractalUnitModel.carrierDigitCount)")
                MetadataRow(title: "Rule", value: "Recursive /8")
                Text("Time units use the octal carrier directly: each row is the selected base interval recursively subdivided by 8.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Time Units (fractal subdivision by 8)") {
                ForEach(rows) { row in
                    SarosFractalTimeUnitRow(row: row)
                }
            }
        }
        .navigationTitle("Time Units")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SarosSpaceUnitsSettingsView: View {
    @AppStorage(JournalSettings.unitSpectrumBaseKey) private var baseRawValue = SarosFractalUnitBase.averageSaros.rawValue

    private var base: SarosFractalUnitBase {
        SarosFractalUnitBase(rawValue: baseRawValue) ?? .averageSaros
    }

    private var rows: [SarosFractalSpaceUnit] {
        SarosFractalUnitModel.spaceRows(basePeriod: base.period)
    }

    var body: some View {
        List {
            Section {
                Picker("Base", selection: $baseRawValue) {
                    ForEach(SarosFractalUnitBase.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                MetadataRow(title: "Period", value: SarosFractalUnitModel.formatTemporalPeriod(base.period))
                MetadataRow(title: "Carrier", value: "\(SarosFractalUnitModel.carrierDigitCount) octal digits")
                MetadataRow(title: "Rule", value: "Repunit ones")
                Text("Spatial units use repunit-one landmark intervals over the selected base: how far light and sound travel while one repunit interval elapses.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Space Units (repunit travel distances)") {
                ForEach(rows) { row in
                    SarosFractalSpaceUnitRow(row: row)
                }
            }
        }
        .navigationTitle("Space Units")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SarosFractalTimeUnitRow: View {
    let row: SarosFractalTimeUnit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.indexLabel)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.primaryValue)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                Text("light length \(row.lightDistance)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("sound length \(row.soundDistance)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("/8^\(row.depth)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

private struct SarosFractalSpaceUnitRow: View {
    let row: SarosFractalSpaceUnit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.indexLabel)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.lightDistance)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                Text(row.addressLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("light time \(row.lightTime)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("sound length \(row.soundDistance)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("R\(row.suffixLength)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

private struct SarosFractalTimeUnit: Identifiable {
    let depth: Int
    let primaryValue: String
    let lightDistance: String
    let soundDistance: String

    var id: Int { depth }
    var indexLabel: String { "T\(depth)" }
}

private struct SarosFractalSpaceUnit: Identifiable {
    let order: Int
    let suffixLength: Int
    let addressLabel: String
    let lightDistance: String
    let lightTime: String
    let soundDistance: String

    var id: Int { order }
    var indexLabel: String { "O\(order)" }
}

private enum SarosFractalUnitBase: String, CaseIterable, Identifiable {
    case anomalisticYear
    case averageSaros
    case day

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anomalisticYear: "Anomalistic year"
        case .averageSaros: "Average Saros"
        case .day: "1 day"
        }
    }

    var period: TimeInterval {
        switch self {
        case .anomalisticYear:
            365.259636 * 24 * 60 * 60
        case .averageSaros:
            JournalSettings.averageSarosPeriod
        case .day:
            24 * 60 * 60
        }
    }
}

private enum SarosFractalUnitModel {
    static let carrierDigitCount = 64
    private static let lightSpeedMetersPerSecond = 299_792_458.0
    private static let soundSpeedMetersPerSecond = 343.0

    static func timeRows(basePeriod: TimeInterval) -> [SarosFractalTimeUnit] {
        (0...carrierDigitCount).map { depth in
            let period = basePeriod / pow(8.0, Double(depth))
            return SarosFractalTimeUnit(
                depth: depth,
                primaryValue: formatTemporalPeriod(period),
                lightDistance: formatLength(lightSpeedMetersPerSecond * period),
                soundDistance: formatLength(soundSpeedMetersPerSecond * period)
            )
        }
    }

    static func spaceRows(basePeriod: TimeInterval) -> [SarosFractalSpaceUnit] {
        (1...carrierDigitCount).map { order in
            let suffixLength = carrierDigitCount - order + 1
            let period = landmarkPeriod(
                suffixLength: suffixLength,
                carrierDigits: carrierDigitCount,
                basePeriod: basePeriod
            )
            return SarosFractalSpaceUnit(
                order: order,
                suffixLength: suffixLength,
                addressLabel: addressLabel(prefixZeros: order - 1, suffixOnes: suffixLength),
                lightDistance: formatLength(lightSpeedMetersPerSecond * period),
                lightTime: formatTemporalPeriod(period),
                soundDistance: formatLength(soundSpeedMetersPerSecond * period)
            )
        }
    }

    static func landmarkPeriod(
        suffixLength: Int,
        carrierDigits: Int,
        basePeriod: TimeInterval = JournalSettings.averageSarosPeriod
    ) -> TimeInterval {
        basePeriod * landmarkRatio(
            suffixLength: suffixLength,
            carrierDigits: carrierDigits
        )
    }

    private static func landmarkRatio(suffixLength rawSuffixLength: Int, carrierDigits rawCarrierDigits: Int) -> Double {
        let carrierDigits = max(rawCarrierDigits, 1)
        let suffixLength = min(max(rawSuffixLength, 1), carrierDigits)
        let prefixZeros = carrierDigits - suffixLength
        let repunitNormalizedWithinSuffix = (1 - pow(8, -Double(suffixLength))) / 7
        return repunitNormalizedWithinSuffix / pow(8, Double(prefixZeros))
    }

    private static func addressLabel(prefixZeros: Int, suffixOnes: Int) -> String {
        if prefixZeros <= 0 {
            return "1 x\(suffixOnes)"
        }
        return "0 x\(prefixZeros) + 1 x\(suffixOnes)"
    }

    static func formatTemporalPeriod(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 Hz" }
        if seconds < 1 {
            return formatFrequency(1 / seconds)
        }
        if seconds < 60 {
            return "\(formatNumber(seconds)) s"
        }
        return durationFormatter.string(from: seconds) ?? "\(formatNumber(seconds)) s"
    }

    private static func formatFrequency(_ hertz: Double) -> String {
        let units: [(String, Double)] = [
            ("YHz", 1e24),
            ("ZHz", 1e21),
            ("EHz", 1e18),
            ("PHz", 1e15),
            ("THz", 1e12),
            ("GHz", 1e9),
            ("MHz", 1e6),
            ("kHz", 1e3),
            ("Hz", 1)
        ]

        for unit in units where hertz >= unit.1 {
            return "\(formatNumber(hertz / unit.1)) \(unit.0)"
        }
        return "\(formatNumber(hertz)) Hz"
    }

    private static func formatLength(_ meters: Double) -> String {
        guard meters.isFinite, meters > 0 else { return "0 m" }

        let units: [(String, Double)] = [
            ("ly", 9_460_730_472_580_800),
            ("AU", 149_597_870_700),
            ("km", 1_000),
            ("m", 1),
            ("cm", 0.01),
            ("mm", 0.001),
            ("um", 0.000_001),
            ("nm", 0.000_000_001),
            ("pm", 0.000_000_000_001),
            ("Planck", 1.616_255e-35)
        ]

        for unit in units where meters >= unit.1 {
            return "\(formatNumber(meters / unit.1)) \(unit.0)"
        }

        return String(format: "%.2e m", meters)
    }

    private static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return "n/a" }
        if value >= 100 {
            return String(format: "%.0f", value)
        }
        if value >= 10 {
            return String(format: "%.1f", value)
        }
        if value >= 1 {
            return String(format: "%.2f", value)
        }
        return String(format: "%.2e", value)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.year, .month, .day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 3
        return formatter
    }()
}

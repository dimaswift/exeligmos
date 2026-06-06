import MapKit
import SwiftData
import SwiftUI

struct CatalogView: View {
    @EnvironmentObject private var services: AppServices
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var activeEntities: [TrackedEntity]

    @State private var selectedSection: CatalogSection = .saros
    @State private var eclipses: [Eclipse] = []
    @State private var eclipseSearchText = ""
    @State private var resonanceRarity: FlipRarity = .epic
    @State private var resonanceDisplayMode: CatalogResonanceDisplayMode = .phase
    @State private var resonanceSelectedFamilyIDs: Set<Int> = []
    @State private var resonanceSelectedRarities: Set<FlipRarity> = [.epic, .legendary, .mythic]
    @State private var resonanceTimelineCycles = 1.0
    @State private var resonanceTimelineZoom = 2.0
    @State private var resonanceWaveSampleDensity = 8.0
    @State private var mapLatitudeOffset = 0.0
    @State private var mapLongitudeOffset = 0.0
    @State private var mapRollOffset = 0.0
    @State private var isShowingCatalogSettings = false
    @State private var errorMessage: String?
    @AppStorage(JournalSettings.catalogStartCenturyKey) private var catalogStartCentury = JournalSettings.defaultCatalogStartCentury
    @AppStorage(JournalSettings.catalogEndCenturyKey) private var catalogEndCentury = JournalSettings.defaultCatalogEndCentury

    private var catalogBounds: CatalogCenturyBounds {
        CatalogCenturyBounds(startCentury: catalogStartCentury, endCentury: catalogEndCentury)
    }

    private var boundedEclipses: [Eclipse] {
        let bounds = catalogBounds
        return eclipses.filter { bounds.contains($0.date) }
    }

    private var boundedSeries: [SarosSeriesSummary] {
        Dictionary(grouping: boundedEclipses, by: \.saros)
            .compactMap { saros, eclipses in
                let ordered = eclipses.sorted { $0.date < $1.date }
                guard let first = ordered.first, let last = ordered.last else { return nil }
                return SarosSeriesSummary(
                    saros: saros,
                    eclipseCount: ordered.count,
                    firstEclipseDate: first.date,
                    lastEclipseDate: last.date
                )
            }
            .sorted { $0.saros < $1.saros }
    }

    private var activeSarosFamilies: [CatalogActiveSarosFamily] {
        Dictionary(grouping: activeEntities, by: \.saros)
            .map { saros, entities in
                CatalogActiveSarosFamily(
                    saros: saros,
                    title: entities.first?.displayTitle ?? "Saros \(saros)"
                )
            }
            .sorted { $0.saros < $1.saros }
    }

    private var primaryResonanceRarity: FlipRarity {
        resonanceSelectedRarities.sorted().last ?? resonanceRarity
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Catalog")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 10)

            Picker("Catalog", selection: $selectedSection) {
                ForEach(CatalogSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])

            if selectedSection == .eclipses {
                TextField("Search by date", text: $eclipseSearchText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            switch selectedSection {
            case .saros:
                SarosCatalogList(
                    series: boundedSeries,
                    bounds: catalogBounds,
                    errorMessage: errorMessage
                )
            case .eclipses:
                EclipseCatalogList(
                    eclipses: boundedEclipses,
                    searchText: $eclipseSearchText,
                    errorMessage: errorMessage
                )
            case .resonances:
                CatalogResonanceView(
                    families: activeSarosFamilies,
                    rarity: $resonanceRarity,
                    displayMode: $resonanceDisplayMode,
                    selectedFamilyIDs: $resonanceSelectedFamilyIDs,
                    selectedRarities: $resonanceSelectedRarities,
                    timelineCycles: $resonanceTimelineCycles,
                    timelineZoom: $resonanceTimelineZoom,
                    waveSampleDensity: $resonanceWaveSampleDensity,
                    mapLatitudeOffset: $mapLatitudeOffset,
                    mapLongitudeOffset: $mapLongitudeOffset,
                    mapRollOffset: $mapRollOffset
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingCatalogSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Catalog settings")
            }
        }
        .sheet(isPresented: $isShowingCatalogSettings) {
            NavigationStack {
                List {
                    Section("Catalog") {
                        Stepper(
                            "From \(JournalSettings.centuryLabel(catalogStartCentury)) century",
                            value: $catalogStartCentury,
                            in: JournalSettings.supportedCatalogCenturies
                        )

                        Stepper(
                            "Through \(JournalSettings.centuryLabel(catalogEndCentury)) century",
                            value: $catalogEndCentury,
                            in: JournalSettings.supportedCatalogCenturies
                        )

                        Text("Current bounds: \(catalogBounds.displayTitle).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("Resonance") {
                        CatalogResonanceSettingSlider(
                            title: resonanceDisplayMode == .trace ? "Periods" : "Timeline",
                            value: $resonanceTimelineCycles,
                            range: 0.25...4,
                            step: 0.25,
                            tint: primaryResonanceRarity.color
                        ) { value in
                            "\(value.formatted(.number.precision(.fractionLength(2)))) cycles"
                        }
                        CatalogResonanceSettingSlider(
                            title: resonanceDisplayMode == .phasor ? "Speed" : "Zoom",
                            value: $resonanceTimelineZoom,
                            range: 0.5...8,
                            step: 0.5,
                            tint: primaryResonanceRarity.color
                        ) { value in
                            "\(value.formatted(.number.precision(.fractionLength(1))))x"
                        }
                        CatalogResonanceSettingSlider(
                            title: "Sampling",
                            value: $resonanceWaveSampleDensity,
                            range: 1...8,
                            step: 0.5,
                            tint: primaryResonanceRarity.color
                        ) { value in
                            "\(value.formatted(.number.precision(.fractionLength(1))))x"
                        }
                    }

                    Section("Projection") {
                        CatalogResonanceSettingSlider(
                            title: "Latitude",
                            value: $mapLatitudeOffset,
                            range: -90...90,
                            step: 1,
                            tint: primaryResonanceRarity.color
                        ) { value in
                            "\(Int(value.rounded()))°"
                        }
                        CatalogResonanceSettingSlider(
                            title: "Longitude",
                            value: $mapLongitudeOffset,
                            range: -180...180,
                            step: 1,
                            tint: primaryResonanceRarity.color
                        ) { value in
                            "\(Int(value.rounded()))°"
                        }
                        CatalogResonanceSettingSlider(
                            title: "Roll",
                            value: $mapRollOffset,
                            range: -180...180,
                            step: 1,
                            tint: primaryResonanceRarity.color
                        ) { value in
                            "\(Int(value.rounded()))°"
                        }
                    }
                }
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            isShowingCatalogSettings = false
                        }
                    }
                }
            }
        }
        .task {
            do {
                eclipses = try services.eclipseService.allEclipses()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: catalogStartCentury) { _, newCentury in
            catalogStartCentury = JournalSettings.clampedCatalogCentury(newCentury)
            if catalogStartCentury > catalogEndCentury {
                catalogEndCentury = catalogStartCentury
            }
        }
        .onChange(of: catalogEndCentury) { _, newCentury in
            catalogEndCentury = JournalSettings.clampedCatalogCentury(newCentury)
            if catalogEndCentury < catalogStartCentury {
                catalogStartCentury = catalogEndCentury
            }
        }
    }
}

private enum CatalogSection: String, CaseIterable, Identifiable {
    case saros
    case eclipses
    case resonances

    var id: String { rawValue }

    var title: String {
        switch self {
        case .saros: "Saros"
        case .eclipses: "Eclipses"
        case .resonances: "Resonance"
        }
    }
}

private struct CatalogActiveSarosFamily: Identifiable, Hashable {
    let saros: Int
    let title: String

    var id: Int { saros }
}

private enum CatalogResonanceDisplayMode: String, CaseIterable, Identifiable {
    case overlap
    case trace
    case phase
    case phasor
    case map

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overlap: "Overlap"
        case .trace: "Trace"
        case .phase: "XY"
        case .phasor: "Phasor"
        case .map: "Map"
        }
    }

    var usesFixedCanvas: Bool {
        switch self {
        case .trace, .phase, .phasor, .map: true
        case .overlap: false
        }
    }
}

private struct CatalogResonanceView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    let families: [CatalogActiveSarosFamily]
    @Binding var rarity: FlipRarity
    @Binding var displayMode: CatalogResonanceDisplayMode
    @Binding var selectedFamilyIDs: Set<Int>
    @Binding var selectedRarities: Set<FlipRarity>
    @Binding var timelineCycles: Double
    @Binding var timelineZoom: Double
    @Binding var waveSampleDensity: Double
    @Binding var mapLatitudeOffset: Double
    @Binding var mapLongitudeOffset: Double
    @Binding var mapRollOffset: Double
    @State private var mapDisplayMode: CubeMapDisplayMode = .singleFace
    @State private var hasEditedFamilySelection = false
    @State private var hasEditedRaritySelection = false

    private var selectableRarities: [FlipRarity] {
        FlipRarity.visibleRarities(for: harmonicDepth, includeSaros: false).filter { $0 >= .rare }
    }

    private var referenceFamily: CatalogActiveSarosFamily? {
        families.first
    }

    private var mapProjectionOffsets: CubeMapProjectionOffsets {
        CubeMapProjectionOffsets(
            latitude: mapLatitudeOffset,
            longitude: mapLongitudeOffset,
            roll: mapRollOffset
        )
    }

    private var model: CatalogResonanceModel? {
        guard let referenceFamily,
              let referenceReading = try? services.clockService.reading(
                saros: referenceFamily.saros,
                date: Date(),
                harmonicDepth: harmonicDepth
              )
        else {
            return nil
        }

        let referenceStart = referenceReading.previousEclipse.date
        let referenceInterval = max(referenceReading.nextEclipse.date.timeIntervalSince(referenceStart), 1)
        let referenceEnd = referenceStart.addingTimeInterval(referenceInterval * timelineCycles)
        let bands = selectableRarities.map { option in
            CatalogResonanceBand(
                rarity: option,
                frequency: waveFrequency(for: option, reading: referenceReading)
            )
        }
        let series = families.compactMap { family -> CatalogResonanceSeries? in
            guard let reading = try? services.clockService.reading(
                saros: family.saros,
                date: Date(),
                harmonicDepth: harmonicDepth
            ) else {
                return nil
            }

            let interval = max(reading.nextEclipse.date.timeIntervalSince(reading.previousEclipse.date), 1)
            let phaseOffset = normalizedPhase(referenceStart.timeIntervalSince(reading.previousEclipse.date) / interval)

            return CatalogResonanceSeries(
                saros: family.saros,
                title: family.title,
                previousEclipseDate: reading.previousEclipse.date,
                nextEclipseDate: reading.nextEclipse.date,
                nextEclipseID: reading.nextEclipse.id,
                cycleDuration: interval,
                phaseOffset: phaseOffset
            )
        }

        return CatalogResonanceModel(
            referenceStartDate: referenceStart,
            referenceEndDate: referenceEnd,
            referenceCycleDuration: referenceInterval,
            bands: bands,
            series: series
        )
    }

    var body: some View {
        List {
            Section {
                if families.isEmpty {
                    ContentUnavailableView("No active Saros families", systemImage: "dot.radiowaves.left.and.right")
                } else {
                    HStack(spacing: 8) {
                        ForEach(selectableRarities) { option in
                            CatalogResonanceRarityChip(
                                rarity: option,
                                isSelected: selectedRarities.contains(option)
                            ) {
                                toggleRarity(option)
                            }
                        }
                    }

                    Picker("Mode", selection: $displayMode) {
                        ForEach(CatalogResonanceDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if displayMode == .map {
                        Picker("Map display", selection: $mapDisplayMode) {
                            ForEach(CubeMapDisplayMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }

            if let model {
                let selectedSeries = model.series.filter { selectedFamilyIDs.contains($0.saros) }
                let selectedBands = model.bands.filter { selectedRarities.contains($0.rarity) }
                Section {
                    if displayMode == .map {
                        CatalogResonanceCubeMapView(
                            model: model,
                            selectedSeries: selectedSeries,
                            displayMode: mapDisplayMode,
                            projectionOffsets: mapProjectionOffsets
                        )
                        .frame(height: mapDisplayMode == .isometric ? 460 : 360)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                    } else {
                        CatalogResonanceWaveScrollView(
                            model: model,
                            rarity: rarity,
                            displayMode: displayMode,
                            selectedSeries: selectedSeries,
                            selectedBands: selectedBands,
                            timelineZoom: timelineZoom,
                            sampleDensity: waveSampleDensity
                        )
                            .frame(height: 320)
                            .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                    }
                }

                Section {
                    ForEach(Array(model.series.enumerated()), id: \.element.id) { index, series in
                        Toggle(isOn: familySelectionBinding(for: series.saros)) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(CatalogResonancePalette.color(at: index))
                                    .frame(width: 10, height: 10)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(series.title)
                                        .font(.headline)
                                    Text("Saros \(series.saros)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    MetadataRow(title: "Cycle start", value: JournalFormatters.date.string(from: model.referenceStartDate))
                    MetadataRow(title: "Timeline end", value: JournalFormatters.date.string(from: model.referenceEndDate))
                    MetadataRow(title: "Max frequency", value: "\(Int((selectedBands.map(\.frequency).max() ?? model.maxFrequency).rounded())) waves/cycle")
                    MetadataRow(title: displayMode == .phasor ? "Speed" : "Zoom", value: "\(timelineZoom.formatted(.number.precision(.fractionLength(1))))x")
                    MetadataRow(title: "Sampling", value: "\(waveSampleDensity.formatted(.number.precision(.fractionLength(1))))x")
                    MetadataRow(title: "Selected", value: "\(selectedSeries.count) of \(model.series.count)")
                    if displayMode == .phase {
                        MetadataRow(title: "XY pair", value: phasePairSummary(for: selectedSeries))
                    } else if displayMode == .trace {
                        MetadataRow(title: "Trace length", value: "\(timelineCycles.formatted(.number.precision(.fractionLength(2)))) cycles")
                    } else if displayMode == .phasor {
                        MetadataRow(title: "Phasors", value: "\(selectedSeries.count * selectedBands.count)")
                    } else if displayMode == .map {
                        MetadataRow(title: "Map display", value: mapDisplayMode.title)
                        MetadataRow(title: "Future paths", value: "\(selectedSeries.count)")
                    }
                }
            }
        }
        .onAppear {
            normalizeSelection()
        }
        .onChange(of: families) { _, _ in
            normalizeSelection()
        }
        .onChange(of: selectableRarities) { _, rarities in
            normalizeRaritySelection(rarities)
        }
    }

    private func familySelectionBinding(for saros: Int) -> Binding<Bool> {
        Binding {
            selectedFamilyIDs.contains(saros)
        } set: { isSelected in
            hasEditedFamilySelection = true
            if isSelected {
                selectedFamilyIDs.insert(saros)
            } else {
                selectedFamilyIDs.remove(saros)
            }
        }
    }

    private func toggleRarity(_ option: FlipRarity) {
        hasEditedRaritySelection = true
        if selectedRarities.contains(option) {
            selectedRarities.remove(option)
        } else {
            selectedRarities.insert(option)
            rarity = option
        }

        if !selectedRarities.contains(rarity) {
            rarity = selectedRarities.sorted().last ?? selectableRarities.first ?? rarity
        }
    }

    private func normalizeSelection() {
        let familyIDs = Set(families.map(\.saros))
        if hasEditedFamilySelection {
            selectedFamilyIDs.formIntersection(familyIDs)
        } else {
            selectedFamilyIDs = defaultSelectedFamilyIDs()
        }
        normalizeRaritySelection(selectableRarities)
    }

    private func normalizeRaritySelection(_ rarities: [FlipRarity]) {
        let rarityIDs = Set(rarities.filter { $0 != .rare })
        if hasEditedRaritySelection {
            selectedRarities.formIntersection(Set(rarities))
        } else {
            selectedRarities = rarityIDs
        }

        if !rarities.contains(rarity), let fallback = rarities.first {
            rarity = fallback
        }

        if !selectedRarities.isEmpty, !selectedRarities.contains(rarity) {
            rarity = selectedRarities.sorted().last ?? rarity
        }
    }

    private func defaultSelectedFamilyIDs() -> Set<Int> {
        let familyIDs = Set(families.map(\.saros))
        let now = Date()
        let candidates = families.compactMap { family -> (saros: Int, interval: TimeInterval)? in
            guard let reading = try? services.clockService.reading(
                saros: family.saros,
                date: now,
                harmonicDepth: harmonicDepth
            ) else {
                return nil
            }

            let interval = FlipRarity.visibleRarities(for: harmonicDepth, includeSaros: false)
                .filter { $0 > .common }
                .compactMap { reading.countdown(rarity: $0, now: now)?.timeUntilFlip }
                .filter { $0 >= 0 }
                .min()

            guard let interval else { return nil }
            return (family.saros, interval)
        }
        .sorted { lhs, rhs in
            lhs.interval == rhs.interval ? lhs.saros < rhs.saros : lhs.interval < rhs.interval
        }
        .prefix(2)
        .map(\.saros)

        return candidates.isEmpty
            ? Set(families.prefix(2).map(\.saros))
            : Set(candidates).intersection(familyIDs)
    }

    private func waveFrequency(for rarity: FlipRarity, reading: SarosClockReading) -> Double {
        if rarity.isSarosPattern {
            return 1
        }
        let stride = reading.qualifiedFlipStride(forOrder: rarity.order)
        return max(Double(reading.binCount) / Double(max(stride, 1)), 1)
    }

    private func normalizedPhase(_ phase: Double) -> Double {
        var value = phase.truncatingRemainder(dividingBy: 1)
        if value < 0 {
            value += 1
        }
        return value
    }

    private func phasePairSummary(for series: [CatalogResonanceSeries]) -> String {
        guard series.count >= 2 else { return "Select 2 families" }
        return "\(series[0].title) × \(series[1].title)"
    }
}

private struct CatalogResonanceCubeMapView: View {
    @EnvironmentObject private var services: AppServices

    let model: CatalogResonanceModel
    let selectedSeries: [CatalogResonanceSeries]
    let displayMode: CubeMapDisplayMode
    let projectionOffsets: CubeMapProjectionOffsets

    @State private var overlays: [CubeMapEclipseOverlay] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            CubeMapView(
                overlays: overlays,
                displayMode: displayMode,
                projectionOffsets: projectionOffsets
            )

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: selectedSeries.map(\.saros)) {
            await loadOverlays()
        }
    }

    @MainActor
    private func loadOverlays() async {
        isLoading = true
        errorMessage = nil

        var loaded: [CubeMapEclipseOverlay] = []
        for (index, series) in selectedSeries.enumerated() {
            guard let geometry = try? services.eclipseService.pathGeometry(for: series.nextEclipseID),
                  !geometry.polygons.isEmpty
            else {
                continue
            }

            loaded.append(CubeMapEclipseOverlay(
                id: series.nextEclipseID,
                saros: series.saros,
                title: series.title,
                date: series.nextEclipseDate,
                color: CatalogResonancePalette.color(
                    at: model.series.firstIndex(where: { $0.saros == series.saros }) ?? index
                ),
                polygons: geometry.polygons
            ))
        }

        overlays = loaded
        isLoading = false
    }
}

private struct CatalogResonanceRarityChip: View {
    let rarity: FlipRarity
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: rarity.symbolName)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .foregroundStyle(foregroundColor)
                .background(backgroundColor, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(rarity.color.opacity(isSelected ? 0.0 : 0.45), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rarity.title)
    }

    private var backgroundColor: Color {
        isSelected ? rarity.color.opacity(0.86) : rarity.color.opacity(0.12)
    }

    private var foregroundColor: Color {
        if isSelected, rarity == .legendary {
            return .black
        }
        return isSelected ? .white : rarity.color
    }
}

private struct CatalogResonanceSettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color
    let valueText: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .tint(tint)
        }
    }
}

private struct CatalogResonanceWaveScrollView: View {
    let model: CatalogResonanceModel
    let rarity: FlipRarity
    let displayMode: CatalogResonanceDisplayMode
    let selectedSeries: [CatalogResonanceSeries]
    let selectedBands: [CatalogResonanceBand]
    let timelineZoom: Double
    let sampleDensity: Double

    var body: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height, 1)
            let width = canvasWidth(containerWidth: proxy.size.width)
            if displayMode.usesFixedCanvas {
                CatalogResonanceCanvas(
                    model: model,
                    rarity: rarity,
                    displayMode: displayMode,
                    selectedSeries: selectedSeries,
                    selectedBands: selectedBands,
                    timelineZoom: timelineZoom,
                    sampleDensity: sampleDensity
                )
                .frame(width: width, height: height)
            } else {
                ScrollView(.horizontal) {
                    CatalogResonanceCanvas(
                        model: model,
                        rarity: rarity,
                        displayMode: displayMode,
                        selectedSeries: selectedSeries,
                        selectedBands: selectedBands,
                        timelineZoom: timelineZoom,
                        sampleDensity: sampleDensity
                    )
                    .frame(width: width, height: height)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private func canvasWidth(containerWidth: CGFloat) -> CGFloat {
        guard !displayMode.usesFixedCanvas else {
            return containerWidth
        }
        let cycleCount = max(model.referenceEndDate.timeIntervalSince(model.referenceStartDate) / model.referenceCycleDuration, 0.25)
        let frequency = selectedBands.map(\.frequency).max() ?? model.maxFrequency
        let idealWidth = (frequency * cycleCount * 18 * timelineZoom) + 140
        return min(max(containerWidth, idealWidth), 120_000)
    }
}

private struct CatalogResonanceCanvas: View {
    let model: CatalogResonanceModel
    let rarity: FlipRarity
    let displayMode: CatalogResonanceDisplayMode
    let selectedSeries: [CatalogResonanceSeries]
    let selectedBands: [CatalogResonanceBand]
    let timelineZoom: Double
    let sampleDensity: Double
    @State private var isRecordingPhasorTrail = false
    @State private var phasorProgress = 0.0
    @State private var phasorHoldStartTime: TimeInterval?
    @State private var phasorTrailBaseProgress = 0.0
    @State private var phasorTrailSpeed = 0.0
    @State private var phasorTrailStartTime: TimeInterval?
    @State private var phasorTrailEndTime: TimeInterval?

    var body: some View {
        Group {
            if displayMode == .phasor {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    drawingCanvas(animationDate: timeline.date)
                }
            } else {
                drawingCanvas(animationDate: nil)
            }
        }
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal)
        .simultaneousGesture(phasorTrailGesture)
    }

    private func drawingCanvas(animationDate: Date?) -> some View {
        Canvas { context, size in
            let leftInset: CGFloat = 70
            let rightInset: CGFloat = 18
            let topInset: CGFloat = 42
            let bottomInset: CGFloat = 34
            let duration = max(model.referenceEndDate.timeIntervalSince(model.referenceStartDate), 1)

            if displayMode == .phase {
                drawPhasePortrait(context: &context, size: size, duration: duration)
            } else if displayMode == .trace {
                drawResultantTrace(
                    context: &context,
                    size: size,
                    duration: duration
                )
            } else if displayMode == .phasor {
                drawPhasorDiagram(
                    context: &context,
                    size: size,
                    animationTime: animationDate?.timeIntervalSinceReferenceDate ?? 0,
                    duration: max(model.referenceCycleDuration, 1)
                )
            } else {
                drawTimelineMarks(
                    context: &context,
                    size: size,
                    leftInset: leftInset,
                    rightInset: rightInset,
                    topInset: topInset,
                    duration: duration
                )

                drawSharedLane(
                    context: &context,
                    size: size,
                    leftInset: leftInset,
                    rightInset: rightInset,
                    topInset: topInset,
                    bottomInset: bottomInset,
                    duration: duration
                )
            }
        }
    }

    private var phasorTrailGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard displayMode == .phasor else { return }
                let now = Date().timeIntervalSinceReferenceDate
                if !isRecordingPhasorTrail {
                    phasorHoldStartTime = now
                    phasorTrailBaseProgress = phasorProgress
                    phasorTrailSpeed = phasorSpeedFactor
                    phasorTrailStartTime = now
                }
                phasorTrailEndTime = nil
                isRecordingPhasorTrail = true
            }
            .onEnded { _ in
                guard displayMode == .phasor else { return }
                let now = Date().timeIntervalSinceReferenceDate
                phasorProgress = currentPhasorProgress(at: now)
                phasorTrailEndTime = now
                phasorHoldStartTime = nil
                isRecordingPhasorTrail = false
            }
    }

    private func drawTimelineMarks(
        context: inout GraphicsContext,
        size: CGSize,
        leftInset: CGFloat,
        rightInset: CGFloat,
        topInset: CGFloat,
        duration: TimeInterval
    ) {
        let drawableWidth = max(size.width - leftInset - rightInset, 1)
        let markerCount = max(4, min(Int(drawableWidth / 260), 24))
        let minorCount = max(markerCount * 4, 8)

        for marker in 0...minorCount {
            let progress = Double(marker) / Double(max(minorCount, 1))
            let x = leftInset + CGFloat(progress) * drawableWidth
            var markerPath = Path()
            markerPath.move(to: CGPoint(x: x, y: topInset - 18))
            markerPath.addLine(to: CGPoint(x: x, y: size.height - 16))
            context.stroke(
                markerPath,
                with: .color(.secondary.opacity(0.07)),
                lineWidth: 1
            )
        }

        for marker in 0...markerCount {
            let progress = Double(marker) / Double(max(markerCount, 1))
            let x = leftInset + CGFloat(progress) * drawableWidth
            let date = model.referenceStartDate.addingTimeInterval(duration * progress)

            var markerPath = Path()
            markerPath.move(to: CGPoint(x: x, y: topInset - 14))
            markerPath.addLine(to: CGPoint(x: x, y: size.height - 10))
            context.stroke(
                markerPath,
                with: .color(.secondary.opacity(marker == 0 ? 0.34 : 0.18)),
                style: StrokeStyle(lineWidth: 1, dash: marker == 0 ? [] : [3, 8])
            )

            context.draw(
                Text(JournalFormatters.date.string(from: date))
                    .font(.caption2)
                    .foregroundStyle(.secondary),
                at: CGPoint(x: x + 4, y: 10),
                anchor: .topLeading
            )
        }
    }

    private func drawSharedLane(
        context: inout GraphicsContext,
        size: CGSize,
        leftInset: CGFloat,
        rightInset: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        duration: TimeInterval
    ) {
        let y = topInset + max(size.height - topInset - bottomInset, 1) / 2
        let amplitude = max(min((size.height - topInset - bottomInset) * 0.42, 102), 8)
        let drawableWidth = max(size.width - leftInset - rightInset, 1)
        let selectedCount = selectedSeries.count
        let selectedBandCount = selectedBands.count

        var baseline = Path()
        baseline.move(to: CGPoint(x: leftInset, y: y))
        baseline.addLine(to: CGPoint(x: size.width - rightInset, y: y))
        context.stroke(
            baseline,
            with: .color(.secondary.opacity(0.24)),
            style: StrokeStyle(lineWidth: 1, dash: [2, 7])
        )

        context.draw(
            Text("≈")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary),
            at: CGPoint(x: leftInset - 32, y: y)
        )

        context.draw(
            Text("\(selectedCount) \(selectedCount == 1 ? "family" : "families") · \(selectedBandCount) \(selectedBandCount == 1 ? "rarity" : "rarities")")
                .font(.caption2)
                .foregroundStyle(.secondary),
            at: CGPoint(x: leftInset, y: size.height - 18),
            anchor: .leading
        )

        guard !selectedSeries.isEmpty else {
            context.draw(
                Text("Select families")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary),
                at: CGPoint(x: leftInset + drawableWidth / 2, y: y)
            )
            return
        }

        guard !selectedBands.isEmpty else {
            context.draw(
                Text("Select rarities")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary),
                at: CGPoint(x: leftInset + drawableWidth / 2, y: y)
            )
            return
        }

        switch displayMode {
        case .overlap:
            for band in selectedBands {
                for series in selectedSeries {
                    let color = waveColor(for: series, band: band)
                    strokeWave(
                        context: &context,
                        size: size,
                        leftInset: leftInset,
                        rightInset: rightInset,
                        baselineY: y,
                        amplitude: amplitude,
                        color: color,
                        lineWidth: lineWidth(for: band, series: series),
                        cyclesAcrossCanvas: band.frequency * duration / series.cycleDuration
                    ) { progress in
                        waveValue(for: series, band: band, progress: progress, duration: duration)
                    }
                }
            }
        case .trace:
            break
        case .phase:
            break
        case .phasor:
            break
        case .map:
            break
        }
    }

    private func drawPhasePortrait(
        context: inout GraphicsContext,
        size: CGSize,
        duration: TimeInterval
    ) {
        let selectedCount = selectedSeries.count
        let selectedBandCount = selectedBands.count
        let horizontalInset: CGFloat = 28
        let topInset: CGFloat = 34
        let bottomInset: CGFloat = 34
        let availableWidth = max(size.width - horizontalInset * 2, 1)
        let availableHeight = max(size.height - topInset - bottomInset, 1)
        let side = min(availableWidth, availableHeight)
        let rect = CGRect(
            x: (size.width - side) / 2,
            y: topInset + (availableHeight - side) / 2,
            width: side,
            height: side
        )
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = side * 0.46

        drawPhaseAxes(context: &context, rect: rect, center: center)

        context.draw(
            Text("\(selectedCount) \(selectedCount == 1 ? "family" : "families") · \(selectedBandCount) \(selectedBandCount == 1 ? "rarity" : "rarities")")
                .font(.caption2)
                .foregroundStyle(.secondary),
            at: CGPoint(x: rect.minX, y: size.height - 18),
            anchor: .leading
        )

        guard selectedSeries.count >= 2 else {
            context.draw(
                Text("Select 2 families")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary),
                at: center
            )
            return
        }

        guard !selectedBands.isEmpty else {
            context.draw(
                Text("Select rarities")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary),
                at: center
            )
            return
        }

        let xSeries = selectedSeries[0]
        let ySeries = selectedSeries[1]

        context.draw(
            Text("X \(xSeries.title)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary),
            at: CGPoint(x: rect.minX, y: 10),
            anchor: .topLeading
        )
        context.draw(
            Text("Y \(ySeries.title)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary),
            at: CGPoint(x: rect.maxX, y: 10),
            anchor: .topTrailing
        )

        for band in selectedBands {
            strokePhaseTrace(
                context: &context,
                rect: rect,
                center: center,
                radius: radius,
                xSeries: xSeries,
                ySeries: ySeries,
                band: band,
                duration: duration
            )
        }
    }

    private func drawPhaseAxes(
        context: inout GraphicsContext,
        rect: CGRect,
        center: CGPoint
    ) {
        var border = Path()
        border.addRoundedRect(in: rect, cornerSize: CGSize(width: 8, height: 8))
        context.stroke(border, with: .color(.secondary.opacity(0.12)), lineWidth: 1)

        var axes = Path()
        axes.move(to: CGPoint(x: rect.minX, y: center.y))
        axes.addLine(to: CGPoint(x: rect.maxX, y: center.y))
        axes.move(to: CGPoint(x: center.x, y: rect.minY))
        axes.addLine(to: CGPoint(x: center.x, y: rect.maxY))
        context.stroke(
            axes,
            with: .color(.secondary.opacity(0.2)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 7])
        )

        for fraction in [0.25, 0.5, 0.75] {
            let x = rect.minX + rect.width * fraction
            let y = rect.minY + rect.height * fraction
            var grid = Path()
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.addLine(to: CGPoint(x: x, y: rect.maxY))
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(grid, with: .color(.secondary.opacity(0.06)), lineWidth: 1)
        }
    }

    private func strokePhaseTrace(
        context: inout GraphicsContext,
        rect: CGRect,
        center: CGPoint,
        radius: CGFloat,
        xSeries: CatalogResonanceSeries,
        ySeries: CatalogResonanceSeries,
        band: CatalogResonanceBand,
        duration: TimeInterval
    ) {
        let maxCycles = max(
            band.frequency * duration / xSeries.cycleDuration,
            band.frequency * duration / ySeries.cycleDuration
        )
        let sampleBudget = max(maxCycles * (10 + sampleDensity * 4), 720)
        let sampleCount = min(max(Int(sampleBudget.rounded()), 180), 24_000)
        var path = Path()
        var firstPoint = true

        for index in 0...sampleCount {
            let progress = Double(index) / Double(max(sampleCount, 1))
            let xValue = waveValue(for: xSeries, band: band, progress: progress, duration: duration)
            let yValue = waveValue(for: ySeries, band: band, progress: progress, duration: duration)
            let point = CGPoint(
                x: center.x + CGFloat(xValue) * radius,
                y: center.y - CGFloat(yValue) * radius
            )

            if firstPoint {
                path.move(to: point)
                firstPoint = false
            } else {
                path.addLine(to: point)
            }
        }

        context.stroke(
            path,
            with: .color(band.rarity.color.opacity(0.78)),
            lineWidth: CGFloat(0.74 + Double(max(band.rarity.order - 3, 0)) * 0.12)
        )

        let startPoint = phasePoint(
            xSeries: xSeries,
            ySeries: ySeries,
            band: band,
            progress: 0,
            duration: duration,
            center: center,
            radius: radius
        )
        var startDot = Path()
        startDot.addEllipse(in: CGRect(x: startPoint.x - 2.5, y: startPoint.y - 2.5, width: 5, height: 5))
        context.fill(startDot, with: .color(band.rarity.color.opacity(0.92)))
    }

    private func phasePoint(
        xSeries: CatalogResonanceSeries,
        ySeries: CatalogResonanceSeries,
        band: CatalogResonanceBand,
        progress: Double,
        duration: TimeInterval,
        center: CGPoint,
        radius: CGFloat
    ) -> CGPoint {
        let xValue = waveValue(for: xSeries, band: band, progress: progress, duration: duration)
        let yValue = waveValue(for: ySeries, band: band, progress: progress, duration: duration)
        return CGPoint(
            x: center.x + CGFloat(xValue) * radius,
            y: center.y - CGFloat(yValue) * radius
        )
    }

    private func drawResultantTrace(
        context: inout GraphicsContext,
        size: CGSize,
        duration: TimeInterval
    ) {
        let horizontalInset: CGFloat = 28
        let topInset: CGFloat = 32
        let bottomInset: CGFloat = 34
        let availableWidth = max(size.width - horizontalInset * 2, 1)
        let availableHeight = max(size.height - topInset - bottomInset, 1)
        let side = min(availableWidth, availableHeight)
        let rect = CGRect(
            x: (size.width - side) / 2,
            y: topInset + (availableHeight - side) / 2,
            width: side,
            height: side
        )
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let axisRadius = side * 0.43
        let traceRadius = axisRadius * CGFloat(max(timelineZoom, 0.1))
        let selectedCount = selectedSeries.count
        let selectedBandCount = selectedBands.count

        drawPhasorAxes(context: &context, rect: rect, center: center, radius: axisRadius)

        context.draw(
            Text("\(selectedCount) \(selectedCount == 1 ? "family" : "families") · \(selectedBandCount) \(selectedBandCount == 1 ? "rarity" : "rarities")")
                .font(.caption2)
                .foregroundStyle(.secondary),
            at: CGPoint(x: rect.minX, y: size.height - 18),
            anchor: .leading
        )

        guard !selectedSeries.isEmpty else {
            context.draw(
                Text("Select families")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary),
                at: center
            )
            return
        }

        guard !selectedBands.isEmpty else {
            context.draw(
                Text("Select rarities")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary),
                at: center
            )
            return
        }

        let sampleCount = resultantTraceSampleCount(duration: duration)
        var trace = Path()
        var firstPoint = true
        var startPoint: CGPoint?
        var endPoint: CGPoint?

        for index in 0...sampleCount {
            let progress = Double(index) / Double(max(sampleCount, 1))
            let vector = normalizedResultantVector(progress: progress, duration: duration)
            let point = CGPoint(
                x: center.x + vector.dx * traceRadius,
                y: center.y - vector.dy * traceRadius
            )

            if firstPoint {
                trace.move(to: point)
                startPoint = point
                firstPoint = false
            } else {
                trace.addLine(to: point)
            }
            endPoint = point
        }

        var clippedContext = context
        var clip = Path()
        clip.addRect(rect.insetBy(dx: -1, dy: -1))
        clippedContext.clip(to: clip)

        clippedContext.stroke(
            trace,
            with: .color(.white.opacity(0.92)),
            style: StrokeStyle(lineWidth: 0.72, lineCap: .round, lineJoin: .round)
        )

        if let startPoint {
            drawTraceDot(
                context: &clippedContext,
                point: startPoint,
                color: .green.opacity(0.92),
                radius: 3.5
            )
        }
        if let endPoint {
            drawTraceDot(
                context: &clippedContext,
                point: endPoint,
                color: .white.opacity(0.72),
                radius: 2.7
            )
        }
    }

    private func drawTraceDot(
        context: inout GraphicsContext,
        point: CGPoint,
        color: Color,
        radius: CGFloat
    ) {
        var dot = Path()
        dot.addEllipse(in: CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.fill(dot, with: .color(color))
    }

    private func drawPhasorDiagram(
        context: inout GraphicsContext,
        size: CGSize,
        animationTime: TimeInterval,
        duration: TimeInterval
    ) {
        let horizontalInset: CGFloat = 28
        let topInset: CGFloat = 32
        let bottomInset: CGFloat = 34
        let availableWidth = max(size.width - horizontalInset * 2, 1)
        let availableHeight = max(size.height - topInset - bottomInset, 1)
        let side = min(availableWidth, availableHeight)
        let rect = CGRect(
            x: (size.width - side) / 2,
            y: topInset + (availableHeight - side) / 2,
            width: side,
            height: side
        )
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = side * 0.43
        let selectedCount = selectedSeries.count
        let selectedBandCount = selectedBands.count

        drawPhasorAxes(context: &context, rect: rect, center: center, radius: radius)

        context.draw(
            Text("\(selectedCount) \(selectedCount == 1 ? "family" : "families") · \(selectedBandCount) \(selectedBandCount == 1 ? "rarity" : "rarities")")
                .font(.caption2)
                .foregroundStyle(.secondary),
            at: CGPoint(x: rect.minX, y: size.height - 18),
            anchor: .leading
        )

        guard !selectedSeries.isEmpty else {
            context.draw(
                Text("Select families")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary),
                at: center
            )
            return
        }

        guard !selectedBands.isEmpty else {
            context.draw(
                Text("Select rarities")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary),
                at: center
            )
            return
        }

        let animationProgress = currentPhasorProgress(at: animationTime)
        var resultant = CGVector(dx: 0, dy: 0)
        var totalAmplitude = 0.0

        drawPhasorTrail(
            context: &context,
            center: center,
            radius: radius,
            animationTime: animationTime,
            duration: duration
        )

        for band in selectedBands {
            for series in selectedSeries {
                let vector = phasorVector(
                    for: series,
                    band: band,
                    progress: animationProgress,
                    duration: duration
                )
                let amplitude = phasorAmplitude(for: band.rarity)
                resultant.dx += vector.dx
                resultant.dy += vector.dy
                totalAmplitude += amplitude

                drawPhasorArrow(
                    context: &context,
                    center: center,
                    vector: vector,
                    radius: radius,
                    color: phasorColor(for: series, band: band),
                    lineWidth: phasorLineWidth(for: band.rarity)
                )
            }
        }

        if totalAmplitude > 0 {
            let normalizedResult = CGVector(
                dx: resultant.dx / totalAmplitude,
                dy: resultant.dy / totalAmplitude
            )
            drawPhasorArrow(
                context: &context,
                center: center,
                vector: normalizedResult,
                radius: radius,
                color: .white.opacity(0.94),
                lineWidth: 2.2
            )
        }

        var centerDot = Path()
        centerDot.addEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
        context.fill(centerDot, with: .color(.white.opacity(0.82)))
    }

    private func drawPhasorTrail(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        animationTime: TimeInterval,
        duration: TimeInterval
    ) {
        let opacity = phasorTrailOpacity(at: animationTime)
        guard opacity > 0,
              let recordedStart = phasorTrailStartTime
        else {
            return
        }

        let recordedEnd = isRecordingPhasorTrail ? animationTime : (phasorTrailEndTime ?? animationTime)
        let trailStart = max(recordedStart, recordedEnd - 24)
        let trailDuration = max(recordedEnd - trailStart, 0)
        guard trailDuration > 0.05 else { return }

        let sampleCount = min(max(Int((trailDuration * 45).rounded()), 12), 1_600)
        var path = Path()
        var isFirstPoint = true

        for index in 0...sampleCount {
            let fraction = Double(index) / Double(max(sampleCount, 1))
            let sampleTime = trailStart + trailDuration * fraction
            let progress = recordedPhasorProgress(at: sampleTime, startTime: recordedStart)
            let vector = normalizedResultantVector(progress: progress, duration: duration)
            let point = CGPoint(
                x: center.x + vector.dx * radius,
                y: center.y - vector.dy * radius
            )

            if isFirstPoint {
                path.move(to: point)
                isFirstPoint = false
            } else {
                path.addLine(to: point)
            }
        }

        context.stroke(
            path,
            with: .color(.white.opacity(opacity)),
            style: StrokeStyle(lineWidth: 0.82, lineCap: .round, lineJoin: .round)
        )
    }

    private func phasorTrailOpacity(at animationTime: TimeInterval) -> Double {
        guard phasorTrailStartTime != nil else { return 0 }
        if isRecordingPhasorTrail {
            return 0.74
        }
        guard let endTime = phasorTrailEndTime else { return 0 }

        let fadeDuration = 6.0
        let age = max(animationTime - endTime, 0)
        guard age < fadeDuration else { return 0 }
        return 0.74 * (1 - age / fadeDuration)
    }

    private func drawPhasorAxes(
        context: inout GraphicsContext,
        rect: CGRect,
        center: CGPoint,
        radius: CGFloat
    ) {
        for fraction in [0.33, 0.66, 1.0] {
            var ring = Path()
            let ringRadius = radius * CGFloat(fraction)
            ring.addEllipse(in: CGRect(
                x: center.x - ringRadius,
                y: center.y - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            ))
            context.stroke(ring, with: .color(.secondary.opacity(fraction == 1.0 ? 0.18 : 0.08)), lineWidth: 1)
        }

        var axes = Path()
        axes.move(to: CGPoint(x: rect.minX, y: center.y))
        axes.addLine(to: CGPoint(x: rect.maxX, y: center.y))
        axes.move(to: CGPoint(x: center.x, y: rect.minY))
        axes.addLine(to: CGPoint(x: center.x, y: rect.maxY))
        context.stroke(
            axes,
            with: .color(.secondary.opacity(0.18)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 7])
        )
    }

    private func drawPhasorArrow(
        context: inout GraphicsContext,
        center: CGPoint,
        vector: CGVector,
        radius: CGFloat,
        color: Color,
        lineWidth: CGFloat
    ) {
        let end = CGPoint(
            x: center.x + vector.dx * radius,
            y: center.y - vector.dy * radius
        )
        var line = Path()
        line.move(to: center)
        line.addLine(to: end)
        context.stroke(line, with: .color(color), lineWidth: lineWidth)

        let angle = atan2(-vector.dy, vector.dx)
        let headLength = max(lineWidth * 4.2, 7)
        let spread = 0.58
        let left = CGPoint(
            x: end.x - cos(angle - spread) * headLength,
            y: end.y - sin(angle - spread) * headLength
        )
        let right = CGPoint(
            x: end.x - cos(angle + spread) * headLength,
            y: end.y - sin(angle + spread) * headLength
        )
        var head = Path()
        head.move(to: end)
        head.addLine(to: left)
        head.move(to: end)
        head.addLine(to: right)
        context.stroke(head, with: .color(color), lineWidth: lineWidth)
    }

    private func phasorAmplitude(for rarity: FlipRarity) -> Double {
        let normalized = min(max(Double(rarity.order - 3) / 4.0, 0), 1)
        return 0.34 + normalized * 0.62
    }

    private func phasorVector(
        for series: CatalogResonanceSeries,
        band: CatalogResonanceBand,
        progress: Double,
        duration: TimeInterval
    ) -> CGVector {
        let amplitude = phasorAmplitude(for: band.rarity)
        let elapsed = duration * progress
        let familyPhase = series.phaseOffset + elapsed / max(series.cycleDuration, 1)
        let angle = 2 * .pi * band.frequency * familyPhase
        return CGVector(dx: cos(angle) * amplitude, dy: sin(angle) * amplitude)
    }

    private func normalizedResultantVector(progress: Double, duration: TimeInterval) -> CGVector {
        var resultant = CGVector(dx: 0, dy: 0)
        var totalAmplitude = 0.0

        for band in selectedBands {
            for series in selectedSeries {
                let vector = phasorVector(
                    for: series,
                    band: band,
                    progress: progress,
                    duration: duration
                )
                resultant.dx += vector.dx
                resultant.dy += vector.dy
                totalAmplitude += phasorAmplitude(for: band.rarity)
            }
        }

        guard totalAmplitude > 0 else { return .zero }
        return CGVector(
            dx: resultant.dx / totalAmplitude,
            dy: resultant.dy / totalAmplitude
        )
    }

    private func resultantTraceSampleCount(duration: TimeInterval) -> Int {
        let maxCycles = maxCyclesAcrossCanvas(duration: duration)
        let samplesPerCycle = 4 + sampleDensity * 2
        return min(max(Int((maxCycles * samplesPerCycle).rounded()), 720), 48_000)
    }

    private func normalizedProgress(_ value: Double) -> Double {
        var progress = value.truncatingRemainder(dividingBy: 1)
        if progress < 0 {
            progress += 1
        }
        return progress
    }

    private var phasorSpeedFactor: Double {
        0.00045 * max(timelineZoom, 0.05)
    }

    private func currentPhasorProgress(at animationTime: TimeInterval) -> Double {
        guard isRecordingPhasorTrail, let holdStart = phasorHoldStartTime else {
            return phasorProgress
        }

        let elapsed = max(animationTime - holdStart, 0)
        return normalizedProgress(phasorProgress + elapsed * phasorSpeedFactor)
    }

    private func recordedPhasorProgress(at animationTime: TimeInterval, startTime: TimeInterval) -> Double {
        let elapsed = max(animationTime - startTime, 0)
        return normalizedProgress(phasorTrailBaseProgress + elapsed * phasorTrailSpeed)
    }

    private func phasorLineWidth(for rarity: FlipRarity) -> CGFloat {
        CGFloat(0.85 + max(Double(rarity.order - 3), 0) * 0.18)
    }

    private func phasorColor(for series: CatalogResonanceSeries, band: CatalogResonanceBand) -> Color {
        if selectedBands.count == 1 {
            let color = CatalogResonancePalette.color(
                at: model.series.firstIndex(where: { $0.saros == series.saros }) ?? 0
            )
            return color.opacity(0.78)
        }

        return band.rarity.color.opacity(0.56)
    }

    private func strokeWave(
        context: inout GraphicsContext,
        size: CGSize,
        leftInset: CGFloat,
        rightInset: CGFloat,
        baselineY: CGFloat,
        amplitude: CGFloat,
        color: Color,
        lineWidth: CGFloat,
        cyclesAcrossCanvas: Double,
        value: (Double) -> Double
    ) {
        let drawableWidth = max(size.width - leftInset - rightInset, 1)
        let samplesPerCycle = 6 + sampleDensity * 2
        let sampleBudget = max(cyclesAcrossCanvas * samplesPerCycle, 512)
        let sampleStep = min(max(drawableWidth / sampleBudget, 0.75), 8)
        var x = leftInset
        var path = Path()
        var isFirstPoint = true
        while x <= size.width - rightInset {
            let progress = Double((x - leftInset) / drawableWidth)
            let yValue = baselineY - CGFloat(value(progress)) * amplitude
            let point = CGPoint(x: x, y: yValue)
            if isFirstPoint {
                path.move(to: point)
                isFirstPoint = false
            } else {
                path.addLine(to: point)
            }
            x += sampleStep
        }

        context.stroke(path, with: .color(color), lineWidth: lineWidth)
    }

    private func waveValue(
        for series: CatalogResonanceSeries,
        band: CatalogResonanceBand,
        progress: Double,
        duration: TimeInterval
    ) -> Double {
        let elapsed = duration * progress
        let familyPhase = series.phaseOffset + elapsed / series.cycleDuration
        return cos(2 * .pi * band.frequency * familyPhase)
    }

    private func waveColor(for series: CatalogResonanceSeries, band: CatalogResonanceBand) -> Color {
        if selectedBands.count == 1 {
            let color = CatalogResonancePalette.color(
                at: model.series.firstIndex(where: { $0.saros == series.saros }) ?? 0
            )
            return color.opacity(0.82)
        }

        return band.rarity.color.opacity(0.52)
    }

    private func lineWidth(for band: CatalogResonanceBand, series: CatalogResonanceSeries) -> CGFloat {
        let orderOffset = max(Double(band.rarity.order - 3), 0)
        let base = 0.52 + orderOffset * 0.16
        return CGFloat(base)
    }

    private func maxCyclesAcrossCanvas(duration: TimeInterval) -> Double {
        var maxCycles = 1.0
        for band in selectedBands {
            for series in selectedSeries {
                maxCycles = max(maxCycles, band.frequency * duration / series.cycleDuration)
            }
        }
        return maxCycles
    }
}

private enum CatalogMapDisplayMode: String, CaseIterable, Identifiable {
    case singleFace
    case cross
    case isometric

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleFace: "Single"
        case .cross: "Cross"
        case .isometric: "Iso"
        }
    }
}

private struct CatalogMapProjectionOffsets: Equatable {
    static let zero = CatalogMapProjectionOffsets(latitude: 0, longitude: 0, roll: 0)

    let latitude: Double
    let longitude: Double
    let roll: Double

    var latitudeRadians: Double { latitude * .pi / 180 }
    var longitudeRadians: Double { longitude * .pi / 180 }
    var rollRadians: Double { roll * .pi / 180 }
}

private struct CatalogResonanceMapView: View {
    @EnvironmentObject private var services: AppServices

    let model: CatalogResonanceModel
    let selectedSeries: [CatalogResonanceSeries]
    let displayMode: CatalogMapDisplayMode
    let projectionOffsets: CatalogMapProjectionOffsets

    @State private var cubeFace: CatalogCubeFace = .front
    @State private var previousSingleFace: CatalogCubeFace?
    @State private var singleFaceReturnEdge: CatalogMapEdge?
    @State private var isometricYawQuarter = 0
    @State private var isometricShowsTop = true
    @State private var landPolygons: [[Coordinate]] = []
    @State private var eclipseOverlays: [CatalogMapEclipseOverlay] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in
                Canvas { context, size in
                    drawMap(context: &context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(edgeTapGesture(in: proxy.size))
            }
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: selectedSeries.map(\.saros)) {
            await loadMapData()
        }
    }

    private func edgeTapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                switch displayMode {
                case .singleFace:
                    switchFace(for: value.location, in: size)
                case .cross:
                    selectCrossFace(for: value.location, in: size)
                case .isometric:
                    rotateIsometric(for: value.location, in: size)
                }
            }
    }

    @MainActor
    private func loadMapData() async {
        isLoading = true
        errorMessage = nil

        do {
            let land = try CatalogNaturalEarthStore.shared.landPolygons()
            var overlays: [CatalogMapEclipseOverlay] = []
            for (index, series) in selectedSeries.enumerated() {
                guard let geometry = try? services.eclipseService.pathGeometry(for: series.nextEclipseID),
                      !geometry.polygons.isEmpty
                else {
                    continue
                }

                overlays.append(CatalogMapEclipseOverlay(
                    id: series.nextEclipseID,
                    saros: series.saros,
                    title: series.title,
                    date: series.nextEclipseDate,
                    color: CatalogResonancePalette.color(
                        at: model.series.firstIndex(where: { $0.saros == series.saros }) ?? index
                    ),
                    polygons: geometry.polygons
                ))
            }

            landPolygons = land
            eclipseOverlays = overlays
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func drawMap(context: inout GraphicsContext, size: CGSize) {
        switch displayMode {
        case .singleFace:
            drawSingleFaceMap(context: &context, size: size)
        case .cross:
            drawCrossMap(context: &context, size: size)
        case .isometric:
            drawIsometricMap(context: &context, size: size)
        }
    }

    private func drawSingleFaceMap(context: inout GraphicsContext, size: CGSize) {
        let rect = mapRect(in: size)
        drawFace(context: &context, rect: rect, face: cubeFace, isHighlighted: true)
    }

    private func drawCrossMap(context: inout GraphicsContext, size: CGSize) {
        for face in CatalogCubeFace.crossOrder {
            guard let rect = crossFaceRects(in: size)[face] else { continue }
            drawFace(
                context: &context,
                rect: rect,
                face: face,
                isHighlighted: face == cubeFace,
                cornerRadius: 0,
                unitTransform: face == .bottom ? { CGPoint(x: -$0.x, y: -$0.y) } : { $0 }
            )
        }
    }

    private func drawFace(
        context: inout GraphicsContext,
        rect: CGRect,
        face: CatalogCubeFace,
        isHighlighted: Bool,
        cornerRadius: CGFloat = 8,
        unitTransform: (CGPoint) -> CGPoint = { $0 }
    ) {
        var ocean = Path()
        if cornerRadius > 0 {
            ocean.addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        } else {
            ocean.addRect(rect)
        }
        context.fill(ocean, with: .color(.cyan.opacity(isHighlighted ? 0.10 : 0.06)))

        var mapContext = context
        var clip = Path()
        clip.addRect(rect)
        mapContext.clip(to: clip)

        drawGraticule(context: &mapContext, rect: rect, face: face, unitTransform: unitTransform)
        let scale = min(rect.width, rect.height) / 2
        func projectUnitPoint(_ point: CGPoint) -> CGPoint {
            let transformed = unitTransform(point)
            return CGPoint(
                x: rect.midX + transformed.x * scale,
                y: rect.midY - transformed.y * scale
            )
        }

        drawProjectedMapContent(
            context: &mapContext,
            face: face,
            landFillPath: CatalogCubeGnomonicProjection.transformedFilledPath(
                for: landPolygons,
                face: face,
                offsets: projectionOffsets
            ) { unitPoint in
                projectUnitPoint(unitPoint)
            },
            landStrokePath: CatalogCubeGnomonicProjection.transformedSegmentedPath(
                for: landPolygons,
                face: face,
                closeRings: true,
                offsets: projectionOffsets
            ) { unitPoint in
                projectUnitPoint(unitPoint)
            },
            overlayFillPath: { overlay in
                CatalogCubeGnomonicProjection.transformedFilledPath(
                    for: overlay.polygons,
                    face: face,
                    offsets: projectionOffsets
                ) { unitPoint in
                    projectUnitPoint(unitPoint)
                }
            }
        )

        var border = Path()
        if cornerRadius > 0 {
            border.addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        } else {
            border.addRect(rect)
        }
        context.stroke(border, with: .color(.white.opacity(isHighlighted ? 0.42 : 0.16)), lineWidth: isHighlighted ? 1.2 : 0.8)
    }

    private func drawProjectedMapContent(
        context: inout GraphicsContext,
        face: CatalogCubeFace,
        landFillPath: Path,
        landStrokePath: Path,
        overlayFillPath: (CatalogMapEclipseOverlay) -> Path
    ) {
        context.fill(landFillPath, with: .color(.green.opacity(0.16)))
        context.stroke(landStrokePath, with: .color(.white.opacity(0.24)), lineWidth: 0.65)

        for overlay in eclipseOverlays {
            let path = overlayFillPath(overlay)
            context.fill(path, with: .color(overlay.color.opacity(0.17)))
            context.stroke(
                path,
                with: .color(overlay.color.opacity(0.22)),
                style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                path,
                with: .color(overlay.color.opacity(0.92)),
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func drawGraticule(
        context: inout GraphicsContext,
        rect: CGRect,
        face: CatalogCubeFace,
        unitTransform: (CGPoint) -> CGPoint = { $0 }
    ) {
        let scale = min(rect.width, rect.height) / 2
        func projectUnitPoint(_ point: CGPoint) -> CGPoint {
            let transformed = unitTransform(point)
            return CGPoint(
                x: rect.midX + transformed.x * scale,
                y: rect.midY - transformed.y * scale
            )
        }

        for longitude in stride(from: -180.0, through: 180.0, by: 30.0) {
            let coordinates = stride(from: -85.0, through: 85.0, by: 5.0).map {
                Coordinate(latitude: $0, longitude: longitude)
            }
            let path = CatalogCubeGnomonicProjection.transformedLinePath(
                for: coordinates,
                face: face,
                offsets: projectionOffsets
            ) { unitPoint in
                projectUnitPoint(unitPoint)
            }
            context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 0.7)
        }

        for latitude in stride(from: -60.0, through: 60.0, by: 30.0) {
            let coordinates = stride(from: -180.0, through: 180.0, by: 5.0).map {
                Coordinate(latitude: latitude, longitude: $0)
            }
            let path = CatalogCubeGnomonicProjection.transformedLinePath(
                for: coordinates,
                face: face,
                offsets: projectionOffsets
            ) { unitPoint in
                projectUnitPoint(unitPoint)
            }
            context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 0.7)
        }
    }

    private func mapRect(in size: CGSize) -> CGRect {
        let inset: CGFloat = 16
        let side = max(min(size.width, size.height) - inset * 2, 1)
        return CGRect(
            x: (size.width - side) / 2,
            y: (size.height - side) / 2,
            width: side,
            height: side
        )
    }

    private func crossFaceRects(in size: CGSize) -> [CatalogCubeFace: CGRect] {
        let inset: CGFloat = 12
        let availableWidth = max(size.width - inset * 2, 1)
        let availableHeight = max(size.height - inset * 2, 1)
        let spacing: CGFloat = 0
        let cellSize = max(min(
            (availableWidth - spacing * 3) / 4,
            (availableHeight - spacing * 2) / 3
        ), 1)
        let totalWidth = cellSize * 4 + spacing * 3
        let totalHeight = cellSize * 3 + spacing * 2
        let origin = CGPoint(
            x: (size.width - totalWidth) / 2,
            y: (size.height - totalHeight) / 2
        )

        func rect(column: Int, row: Int) -> CGRect {
            CGRect(
                x: origin.x + CGFloat(column) * (cellSize + spacing),
                y: origin.y + CGFloat(row) * (cellSize + spacing),
                width: cellSize,
                height: cellSize
            )
        }

        return [
            .left: rect(column: 0, row: 1),
            .front: rect(column: 1, row: 1),
            .right: rect(column: 2, row: 1),
            .back: rect(column: 3, row: 1),
            .top: rect(column: 1, row: 0),
            .bottom: rect(column: 1, row: 2)
        ]
    }

    private func switchFace(for location: CGPoint, in size: CGSize) {
        let rect = mapRect(in: size)
        guard rect.contains(location) else { return }

        let edgeDistances: [(CatalogMapEdge, CGFloat)] = [
            (.left, abs(location.x - rect.minX)),
            (.right, abs(location.x - rect.maxX)),
            (.top, abs(location.y - rect.minY)),
            (.bottom, abs(location.y - rect.maxY))
        ]
        guard let edge = edgeDistances.min(by: { $0.1 < $1.1 })?.0 else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            if let previousSingleFace, edge == singleFaceReturnEdge {
                cubeFace = previousSingleFace
                self.previousSingleFace = nil
                singleFaceReturnEdge = nil
            } else {
                let currentFace = cubeFace
                cubeFace = cubeFace.neighbor(toward: edge)
                previousSingleFace = currentFace
                singleFaceReturnEdge = edge.opposite
            }
        }
    }

    private func selectCrossFace(for location: CGPoint, in size: CGSize) {
        guard let face = crossFaceRects(in: size).first(where: { $0.value.contains(location) })?.key else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            cubeFace = face
        }
    }

    private func rotateIsometric(for location: CGPoint, in size: CGSize) {
        let rect = mapRect(in: size)
        guard rect.contains(location) else { return }

        let normalizedX = ((location.x - rect.midX) / max(rect.width / 2, 1))
        let normalizedY = ((location.y - rect.midY) / max(rect.height / 2, 1))

        withAnimation(.easeInOut(duration: 0.2)) {
            if abs(normalizedX) > abs(normalizedY) {
                isometricYawQuarter += normalizedX < 0 ? 1 : -1
            } else {
                isometricShowsTop = normalizedY < 0
            }
        }
    }

    private func drawIsometricMap(context: inout GraphicsContext, size: CGSize) {
        let rect = mapRect(in: size)
        let projection = CatalogIsometricCubeProjection(
            rect: rect,
            yawQuarter: isometricYawQuarter,
            showsTop: isometricShowsTop
        )

        for face in projection.visibleFaces {
            drawIsometricFace(
                context: &context,
                face: face,
                projection: projection
            )
        }
    }

    private func drawIsometricFace(
        context: inout GraphicsContext,
        face: CatalogCubeFace,
        projection: CatalogIsometricCubeProjection
    ) {
        let facePath = projection.facePath(face)
        context.fill(facePath, with: .color(.cyan.opacity(face == .top || face == .bottom ? 0.10 : 0.07)))

        drawIsometricGraticule(context: &context, face: face, projection: projection)

        let landFillPath = CatalogCubeGnomonicProjection.transformedFilledPath(
            for: landPolygons,
            face: face,
            offsets: projectionOffsets
        ) { unitPoint in
            projection.project(face: face, unitPoint: unitPoint)
        }
        context.fill(landFillPath, with: .color(.green.opacity(0.14)))

        let landPath = CatalogCubeGnomonicProjection.transformedSegmentedPath(
            for: landPolygons,
            face: face,
            closeRings: true,
            offsets: projectionOffsets
        ) { unitPoint in
            projection.project(face: face, unitPoint: unitPoint)
        }
        context.stroke(landPath, with: .color(.white.opacity(0.25)), lineWidth: 0.65)

        for overlay in eclipseOverlays {
            let path = CatalogCubeGnomonicProjection.transformedFilledPath(
                for: overlay.polygons,
                face: face,
                offsets: projectionOffsets
            ) { unitPoint in
                projection.project(face: face, unitPoint: unitPoint)
            }
            context.fill(path, with: .color(overlay.color.opacity(0.16)))
            context.stroke(
                path,
                with: .color(overlay.color.opacity(0.20)),
                style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                path,
                with: .color(overlay.color.opacity(0.92)),
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
            )
        }

        context.stroke(facePath, with: .color(.white.opacity(0.24)), lineWidth: 0.9)
    }

    private func drawIsometricGraticule(
        context: inout GraphicsContext,
        face: CatalogCubeFace,
        projection: CatalogIsometricCubeProjection
    ) {
        for longitude in stride(from: -180.0, through: 180.0, by: 30.0) {
            let coordinates = stride(from: -85.0, through: 85.0, by: 5.0).map {
                Coordinate(latitude: $0, longitude: longitude)
            }
            let path = CatalogCubeGnomonicProjection.transformedLinePath(
                for: coordinates,
                face: face,
                offsets: projectionOffsets
            ) { unitPoint in
                projection.project(face: face, unitPoint: unitPoint)
            }
            context.stroke(path, with: .color(.white.opacity(0.07)), lineWidth: 0.6)
        }

        for latitude in stride(from: -60.0, through: 60.0, by: 30.0) {
            let coordinates = stride(from: -180.0, through: 180.0, by: 5.0).map {
                Coordinate(latitude: latitude, longitude: $0)
            }
            let path = CatalogCubeGnomonicProjection.transformedLinePath(
                for: coordinates,
                face: face,
                offsets: projectionOffsets
            ) { unitPoint in
                projection.project(face: face, unitPoint: unitPoint)
            }
            context.stroke(path, with: .color(.white.opacity(0.07)), lineWidth: 0.6)
        }
    }
}

private struct CatalogMapEclipseOverlay: Identifiable {
    let id: String
    let saros: Int
    let title: String
    let date: Date
    let color: Color
    let polygons: [[Coordinate]]
}

private enum CatalogMapEdge {
    case left
    case right
    case top
    case bottom

    var opposite: CatalogMapEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }
}

private enum CatalogCubeFace: String, CaseIterable, Identifiable {
    case front
    case right
    case back
    case left
    case top
    case bottom

    var id: String { rawValue }

    static let crossOrder: [CatalogCubeFace] = [.left, .front, .right, .back, .top, .bottom]
    static let verticalRing: [CatalogCubeFace] = [.front, .right, .back, .left]

    var title: String {
        switch self {
        case .front: "Front"
        case .right: "East"
        case .back: "Back"
        case .left: "West"
        case .top: "North"
        case .bottom: "South"
        }
    }

    var center: CatalogVector3 {
        switch self {
        case .front: CatalogVector3(1, 0, 0)
        case .right: CatalogVector3(0, 1, 0)
        case .back: CatalogVector3(-1, 0, 0)
        case .left: CatalogVector3(0, -1, 0)
        case .top: CatalogVector3(0, 0, 1)
        case .bottom: CatalogVector3(0, 0, -1)
        }
    }

    var horizontalAxis: CatalogVector3 {
        switch self {
        case .front: CatalogVector3(0, 1, 0)
        case .right: CatalogVector3(-1, 0, 0)
        case .back: CatalogVector3(0, -1, 0)
        case .left: CatalogVector3(1, 0, 0)
        case .top: CatalogVector3(0, 1, 0)
        case .bottom: CatalogVector3(0, -1, 0)
        }
    }

    var verticalAxis: CatalogVector3 {
        switch self {
        case .front, .right, .back, .left: CatalogVector3(0, 0, 1)
        case .top: CatalogVector3(-1, 0, 0)
        case .bottom: CatalogVector3(-1, 0, 0)
        }
    }

    func neighbor(toward edge: CatalogMapEdge) -> CatalogCubeFace {
        switch edge {
        case .left:
            Self.nearest(to: -horizontalAxis)
        case .right:
            Self.nearest(to: horizontalAxis)
        case .top:
            Self.nearest(to: verticalAxis)
        case .bottom:
            Self.nearest(to: -verticalAxis)
        }
    }

    private static func nearest(to vector: CatalogVector3) -> CatalogCubeFace {
        allCases.max { lhs, rhs in
            lhs.center.dot(vector) < rhs.center.dot(vector)
        } ?? .front
    }
}

private struct CatalogVector3: Equatable {
    let x: Double
    let y: Double
    let z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    static prefix func - (vector: CatalogVector3) -> CatalogVector3 {
        CatalogVector3(-vector.x, -vector.y, -vector.z)
    }

    static func + (lhs: CatalogVector3, rhs: CatalogVector3) -> CatalogVector3 {
        CatalogVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    static func * (lhs: CatalogVector3, rhs: Double) -> CatalogVector3 {
        CatalogVector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    func dot(_ other: CatalogVector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: CatalogVector3) -> CatalogVector3 {
        CatalogVector3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    func normalized() -> CatalogVector3 {
        let length = max(sqrt(x * x + y * y + z * z), 0.000001)
        return CatalogVector3(x / length, y / length, z / length)
    }
}

private struct CatalogIsometricCubeProjection {
    let rect: CGRect
    let yawQuarter: Int
    let showsTop: Bool

    private var corner: CatalogVector3 {
        let z = showsTop ? 1.0 : -1.0
        switch ((yawQuarter % 4) + 4) % 4 {
        case 1:
            return CatalogVector3(-1, 1, z)
        case 2:
            return CatalogVector3(-1, -1, z)
        case 3:
            return CatalogVector3(1, -1, z)
        default:
            return CatalogVector3(1, 1, z)
        }
    }

    var visibleFaces: [CatalogCubeFace] {
        let faces = CatalogCubeFace.allCases.filter {
            $0.center.dot(corner) > 0.01
        }
        let capFace: CatalogCubeFace = showsTop ? .top : .bottom
        return faces.filter { $0 != capFace } + [capFace]
    }

    private var scale: CGFloat {
        min(rect.width / 3.35, rect.height / 3.55)
    }

    private var viewDirection: CatalogVector3 {
        corner.normalized()
    }

    private var screenUp: CatalogVector3 {
        let north = CatalogVector3(0, 0, 1)
        let view = viewDirection
        return (north + view * -north.dot(view)).normalized()
    }

    private var screenRight: CatalogVector3 {
        screenUp.cross(viewDirection).normalized()
    }

    func project(face: CatalogCubeFace, unitPoint: CGPoint) -> CGPoint {
        let vector = face.center
            + face.horizontalAxis * Double(unitPoint.x)
            + face.verticalAxis * Double(unitPoint.y)
        return project(vector)
    }

    func facePath(_ face: CatalogCubeFace) -> Path {
        let corners = [
            CGPoint(x: -1, y: -1),
            CGPoint(x: 1, y: -1),
            CGPoint(x: 1, y: 1),
            CGPoint(x: -1, y: 1)
        ]
        var path = Path()
        for (index, corner) in corners.enumerated() {
            let point = project(face: face, unitPoint: corner)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    private func project(_ vector: CatalogVector3) -> CGPoint {
        let screenX = vector.dot(screenRight)
        let screenY = -vector.dot(screenUp)
        return CGPoint(
            x: rect.midX + CGFloat(screenX) * scale,
            y: rect.midY + CGFloat(screenY) * scale
        )
    }
}

private enum CatalogCubeGnomonicProjection {
    static func segmentedPath(
        for rings: [[Coordinate]],
        face: CatalogCubeFace,
        rect: CGRect,
        closeRings: Bool,
        offsets: CatalogMapProjectionOffsets = .zero
    ) -> Path {
        transformedSegmentedPath(for: rings, face: face, closeRings: closeRings, offsets: offsets) { unitPoint in
            let scale = min(rect.width, rect.height) / 2
            return CGPoint(
                x: rect.midX + unitPoint.x * scale,
                y: rect.midY - unitPoint.y * scale
            )
        }
    }

    static func linePath(
        for coordinates: [Coordinate],
        face: CatalogCubeFace,
        rect: CGRect,
        offsets: CatalogMapProjectionOffsets = .zero
    ) -> Path {
        segmentedPath(for: [coordinates], face: face, rect: rect, closeRings: false, offsets: offsets)
    }

    static func transformedSegmentedPath(
        for rings: [[Coordinate]],
        face: CatalogCubeFace,
        closeRings: Bool,
        offsets: CatalogMapProjectionOffsets = .zero,
        transform: (CGPoint) -> CGPoint
    ) -> Path {
        var path = Path()
        for ring in rings where ring.count >= (closeRings ? 3 : 2) {
            appendSegmentedRing(
                ring,
                to: &path,
                face: face,
                closeRing: closeRings,
                offsets: offsets,
                transform: transform
            )
        }
        return path
    }

    static func transformedLinePath(
        for coordinates: [Coordinate],
        face: CatalogCubeFace,
        offsets: CatalogMapProjectionOffsets = .zero,
        transform: (CGPoint) -> CGPoint
    ) -> Path {
        transformedSegmentedPath(
            for: [coordinates],
            face: face,
            closeRings: false,
            offsets: offsets,
            transform: transform
        )
    }

    static func filledPath(
        for rings: [[Coordinate]],
        face: CatalogCubeFace,
        rect: CGRect,
        offsets: CatalogMapProjectionOffsets = .zero
    ) -> Path {
        transformedFilledPath(for: rings, face: face, offsets: offsets) { unitPoint in
            let scale = min(rect.width, rect.height) / 2
            return CGPoint(
                x: rect.midX + unitPoint.x * scale,
                y: rect.midY - unitPoint.y * scale
            )
        }
    }

    static func transformedFilledPath(
        for rings: [[Coordinate]],
        face: CatalogCubeFace,
        offsets: CatalogMapProjectionOffsets = .zero,
        transform: (CGPoint) -> CGPoint
    ) -> Path {
        var path = Path()
        for ring in rings where ring.count >= 3 {
            let polygons = clippedProjectedPolygons(for: ring, face: face, offsets: offsets)
            for polygon in polygons where polygon.count >= 3 {
                appendPolygon(polygon, to: &path, transform: transform)
            }
        }
        return path
    }

    private static func appendSegmentedRing(
        _ coordinates: [Coordinate],
        to path: inout Path,
        face: CatalogCubeFace,
        closeRing: Bool,
        offsets: CatalogMapProjectionOffsets,
        transform: (CGPoint) -> CGPoint
    ) {
        let vectors = coordinates.map { unitVector(for: $0, offsets: offsets) }
        let edgeCount = closeRing ? vectors.count : max(vectors.count - 1, 0)
        var hasActiveSegment = false

        for edgeIndex in 0..<edgeCount {
            let start = vectors[edgeIndex]
            let end = vectors[(edgeIndex + 1) % vectors.count]
            let sampleCount = sampleCount(from: start, to: end)

            for sampleIndex in 0...sampleCount {
                if edgeIndex > 0, sampleIndex == 0 {
                    continue
                }

                let progress = Double(sampleIndex) / Double(max(sampleCount, 1))
                let vector = interpolatedVector(from: start, to: end, progress: progress)
                if let unitPoint = project(vector, face: face) {
                    let point = transform(unitPoint)
                    if hasActiveSegment {
                        path.addLine(to: point)
                    } else {
                        path.move(to: point)
                        hasActiveSegment = true
                    }
                } else {
                    hasActiveSegment = false
                }
            }
        }
    }

    private static func sampleCount(from start: CatalogVector3, to end: CatalogVector3) -> Int {
        let dot = min(max(start.dot(end), -1), 1)
        let angle = acos(dot)
        let twoDegrees = Double.pi / 90
        return min(max(Int((angle / twoDegrees).rounded(.up)), 1), 48)
    }

    private static func interpolatedVector(
        from start: CatalogVector3,
        to end: CatalogVector3,
        progress: Double
    ) -> CatalogVector3 {
        CatalogVector3(
            start.x + (end.x - start.x) * progress,
            start.y + (end.y - start.y) * progress,
            start.z + (end.z - start.z) * progress
        )
        .normalized()
    }

    private static func project(_ vector: CatalogVector3, face: CatalogCubeFace) -> CGPoint? {
        guard let point = projectOnPlane(vector, face: face) else { return nil }
        guard abs(point.x) <= 1.0001, abs(point.y) <= 1.0001 else { return nil }
        return point
    }

    private static func projectOnPlane(_ vector: CatalogVector3, face: CatalogCubeFace) -> CGPoint? {
        let denominator = vector.dot(face.center)
        guard denominator > 0.0001 else { return nil }

        let x = vector.dot(face.horizontalAxis) / denominator
        let y = vector.dot(face.verticalAxis) / denominator

        return CGPoint(x: x, y: y)
    }

    private static func clippedProjectedPolygons(
        for ring: [Coordinate],
        face: CatalogCubeFace,
        offsets: CatalogMapProjectionOffsets
    ) -> [[CGPoint]] {
        let vectors = ring.map { unitVector(for: $0, offsets: offsets) }
        let edgeCount = vectors.count
        guard edgeCount >= 3 else { return [] }

        var points: [CGPoint] = []
        for edgeIndex in 0..<edgeCount {
            let start = vectors[edgeIndex]
            let end = vectors[(edgeIndex + 1) % edgeCount]
            let sampleCount = sampleCount(from: start, to: end)

            for sampleIndex in 0...sampleCount {
                if edgeIndex > 0, sampleIndex == 0 {
                    continue
                }

                let progress = Double(sampleIndex) / Double(max(sampleCount, 1))
                let vector = interpolatedVector(from: start, to: end, progress: progress)
                guard let point = projectOnPlane(vector, face: face),
                      point.x.isFinite,
                      point.y.isFinite
                else {
                    continue
                }
                points.append(point)
            }
        }

        let clipped = clipPolygonToUnitSquare(points)
        return clipped.count >= 3 ? [clipped] : []
    }

    private static func appendPolygon(
        _ polygon: [CGPoint],
        to path: inout Path,
        transform: (CGPoint) -> CGPoint
    ) {
        for (index, point) in polygon.enumerated() {
            let transformed = transform(point)
            if index == 0 {
                path.move(to: transformed)
            } else {
                path.addLine(to: transformed)
            }
        }
        path.closeSubpath()
    }

    private static func clipPolygonToUnitSquare(_ polygon: [CGPoint]) -> [CGPoint] {
        ClipBoundary.allCases.reduce(polygon) { clipped, boundary in
            clip(clipped, to: boundary)
        }
    }

    private static func clip(_ polygon: [CGPoint], to boundary: ClipBoundary) -> [CGPoint] {
        guard polygon.count >= 3 else { return [] }

        var output: [CGPoint] = []
        var previous = polygon[polygon.count - 1]
        var previousInside = boundary.contains(previous)

        for current in polygon {
            let currentInside = boundary.contains(current)
            if currentInside {
                if !previousInside, let intersection = boundary.intersection(from: previous, to: current) {
                    output.append(intersection)
                }
                output.append(current)
            } else if previousInside, let intersection = boundary.intersection(from: previous, to: current) {
                output.append(intersection)
            }

            previous = current
            previousInside = currentInside
        }

        return output
    }

    private static func unitVector(
        for coordinate: Coordinate,
        offsets: CatalogMapProjectionOffsets
    ) -> CatalogVector3 {
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        let latitudeCosine = cos(latitude)
        let vector = CatalogVector3(
            latitudeCosine * cos(longitude),
            latitudeCosine * sin(longitude),
            sin(latitude)
        )
        return rotateX(
            rotateY(
                rotateZ(vector, by: offsets.longitudeRadians),
                by: offsets.latitudeRadians
            ),
            by: offsets.rollRadians
        )
    }

    private static func rotateX(_ vector: CatalogVector3, by angle: Double) -> CatalogVector3 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return CatalogVector3(
            vector.x,
            vector.y * cosine - vector.z * sine,
            vector.y * sine + vector.z * cosine
        )
    }

    private static func rotateY(_ vector: CatalogVector3, by angle: Double) -> CatalogVector3 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return CatalogVector3(
            vector.x * cosine + vector.z * sine,
            vector.y,
            -vector.x * sine + vector.z * cosine
        )
    }

    private static func rotateZ(_ vector: CatalogVector3, by angle: Double) -> CatalogVector3 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return CatalogVector3(
            vector.x * cosine - vector.y * sine,
            vector.x * sine + vector.y * cosine,
            vector.z
        )
    }
}

private enum ClipBoundary: CaseIterable {
    case left
    case right
    case bottom
    case top

    func contains(_ point: CGPoint) -> Bool {
        switch self {
        case .left:
            point.x >= -1
        case .right:
            point.x <= 1
        case .bottom:
            point.y >= -1
        case .top:
            point.y <= 1
        }
    }

    func intersection(from start: CGPoint, to end: CGPoint) -> CGPoint? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let t: CGFloat

        switch self {
        case .left:
            guard abs(dx) > 0.000001 else { return nil }
            t = (-1 - start.x) / dx
        case .right:
            guard abs(dx) > 0.000001 else { return nil }
            t = (1 - start.x) / dx
        case .bottom:
            guard abs(dy) > 0.000001 else { return nil }
            t = (-1 - start.y) / dy
        case .top:
            guard abs(dy) > 0.000001 else { return nil }
            t = (1 - start.y) / dy
        }

        guard t.isFinite else { return nil }
        let clampedT = min(max(t, 0), 1)
        return CGPoint(
            x: start.x + dx * clampedT,
            y: start.y + dy * clampedT
        )
    }
}

private final class CatalogNaturalEarthStore {
    static let shared = CatalogNaturalEarthStore()

    private var cachedLandPolygons: [[Coordinate]]?

    private init() {}

    func landPolygons(bundle: Bundle = .main) throws -> [[Coordinate]] {
        if let cachedLandPolygons {
            return cachedLandPolygons
        }

        let url = bundle.url(forResource: "land", withExtension: "json", subdirectory: "NaturalEarth")
            ?? bundle.url(forResource: "land", withExtension: "json")

        guard let url else {
            throw CatalogNaturalEarthError.missingLandData
        }

        let data = try Data(contentsOf: url)
        let collection = try JSONDecoder().decode(CatalogNaturalEarthFeatureCollection.self, from: data)
        let polygons = collection.features.flatMap(\.geometry.polygons).filter { $0.count >= 3 }
        cachedLandPolygons = polygons
        return polygons
    }
}

private enum CatalogNaturalEarthError: LocalizedError {
    case missingLandData

    var errorDescription: String? {
        switch self {
        case .missingLandData:
            "Missing Natural Earth land data."
        }
    }
}

private struct CatalogNaturalEarthFeatureCollection: Decodable {
    let features: [CatalogNaturalEarthFeature]
}

private struct CatalogNaturalEarthFeature: Decodable {
    let geometry: CatalogNaturalEarthGeometry
}

private struct CatalogNaturalEarthGeometry: Decodable {
    let polygons: [[Coordinate]]

    private enum CodingKeys: String, CodingKey {
        case type
        case coordinates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "Polygon":
            let rings = try container.decode([[[Double]]].self, forKey: .coordinates)
            polygons = rings.first.map { [Self.coordinates(from: $0)] } ?? []
        case "MultiPolygon":
            let multiPolygons = try container.decode([[[[Double]]]].self, forKey: .coordinates)
            polygons = multiPolygons.compactMap { polygon in
                polygon.first.map(Self.coordinates(from:))
            }
        default:
            polygons = []
        }
    }

    private static func coordinates(from ring: [[Double]]) -> [Coordinate] {
        ring.compactMap { point in
            guard point.count >= 2 else { return nil }
            return Coordinate(latitude: point[1], longitude: point[0])
        }
    }
}

private enum CatalogResonancePalette {
    static func color(at index: Int) -> Color {
        let hue = Double((index * 47) % 360) / 360.0
        return Color(hue: hue, saturation: 0.72, brightness: 1.0)
    }
}

private struct CatalogResonanceModel {
    let referenceStartDate: Date
    let referenceEndDate: Date
    let referenceCycleDuration: TimeInterval
    let bands: [CatalogResonanceBand]
    let series: [CatalogResonanceSeries]

    var maxFrequency: Double {
        bands.map(\.frequency).max() ?? 1
    }
}

private struct CatalogResonanceBand: Identifiable {
    let rarity: FlipRarity
    let frequency: Double

    var id: String { rarity.id }
}

private struct CatalogResonanceSeries: Identifiable {
    let saros: Int
    let title: String
    let previousEclipseDate: Date
    let nextEclipseDate: Date
    let nextEclipseID: String
    let cycleDuration: TimeInterval
    let phaseOffset: Double

    var id: Int { saros }
}

private struct SarosCatalogList: View {
    let series: [SarosSeriesSummary]
    let bounds: CatalogCenturyBounds
    let errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            if series.isEmpty && errorMessage == nil {
                ContentUnavailableView("No series", systemImage: "calendar")
            }

            ForEach(series) { summary in
                NavigationLink {
                    SarosDetailView(summary: summary, bounds: bounds)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Saros \(summary.saros)")
                            .font(.headline)
                        Text("\(summary.eclipseCount) eclipses · \(JournalFormatters.date.string(from: summary.firstEclipseDate)) - \(JournalFormatters.date.string(from: summary.lastEclipseDate))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct EclipseCatalogList: View {
    let eclipses: [Eclipse]
    @Binding var searchText: String
    let errorMessage: String?

    private var searchedDate: Date? {
        CatalogDateSearch.date(from: searchText)
    }

    private var rows: [EclipseSearchRow] {
        guard let searchedDate else {
            return eclipses.map { EclipseSearchRow(eclipse: $0, searchedDate: nil) }
        }

        return eclipses
            .map { EclipseSearchRow(eclipse: $0, searchedDate: searchedDate) }
            .sorted { abs($0.delta ?? 0) < abs($1.delta ?? 0) }
    }

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            if searchedDate == nil && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Use dates like 2026, 2026-08, or 2026-08-12.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if rows.isEmpty && errorMessage == nil {
                ContentUnavailableView("No eclipses", systemImage: "calendar")
            }

            ForEach(rows) { row in
                NavigationLink {
                    EclipseDetailView(eclipse: row.eclipse)
                } label: {
                    EclipseSearchRowView(row: row)
                }
            }
        }
    }
}

private struct SarosDetailView: View {
    @EnvironmentObject private var services: AppServices
    let summary: SarosSeriesSummary
    let bounds: CatalogCenturyBounds

    @State private var eclipses: [Eclipse] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                MetadataRow(title: "Eclipses", value: "\(summary.eclipseCount)")
                MetadataRow(title: "First", value: JournalFormatters.date.string(from: summary.firstEclipseDate))
                MetadataRow(title: "Last", value: JournalFormatters.date.string(from: summary.lastEclipseDate))
            }

            Section("Eclipses") {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                ForEach(eclipses) { eclipse in
                    NavigationLink {
                        EclipseDetailView(eclipse: eclipse)
                    } label: {
                        SarosEclipseRow(eclipse: eclipse)
                    }
                }
            }
        }
        .navigationTitle("Saros \(summary.saros)")
        .task(id: bounds) {
            do {
                eclipses = try services.eclipseService
                    .eclipses(forSaros: summary.saros)
                    .filter { bounds.contains($0.date) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct EclipseDetailView: View {
    @EnvironmentObject private var services: AppServices
    let eclipse: Eclipse

    @State private var detailedEclipse: Eclipse?
    @State private var geometry: EclipsePathGeometry?

    var body: some View {
        let displayEclipse = detailedEclipse ?? eclipse

        List {
            Section {
                EclipseMapView(eclipse: displayEclipse, geometry: geometry)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 12) {
                    EclipseSequenceGlyph(eclipse: displayEclipse)
                        .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayEclipse.displayTypeLabel)
                            .font(.title3.weight(.semibold))
                        Text(JournalFormatters.dateTime.string(from: displayEclipse.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                MetadataRow(title: "Date", value: JournalFormatters.dateTime.string(from: displayEclipse.date))
                MetadataRow(title: "Type", value: displayEclipse.displayTypeLabel)
                MetadataRow(title: "Saros", value: "\(displayEclipse.saros)")

                if let sequence = displayEclipse.sarosSequence {
                    if let total = displayEclipse.sarosSeriesCount {
                        MetadataRow(title: "Series eclipse", value: "\(sequence) of \(total)")
                    } else {
                        MetadataRow(title: "Series eclipse", value: "\(sequence)")
                    }
                }
                if let globalSequence = displayEclipse.globalSequence {
                    MetadataRow(title: "Catalog #", value: "\(globalSequence)")
                }
                if let point = displayEclipse.maximumPoint {
                    MetadataRow(title: "Maximum", value: String(format: "%.1f, %.1f", point.latitude, point.longitude))
                }
                if let gamma = displayEclipse.gamma {
                    MetadataRow(title: "Gamma", value: String(format: "%.4f", gamma))
                }
                if let magnitude = displayEclipse.magnitude {
                    MetadataRow(title: "Magnitude", value: String(format: "%.4f", magnitude))
                }
                if let sunAltitude = displayEclipse.sunAltitude {
                    MetadataRow(title: "Sun altitude", value: "\(sunAltitude) deg")
                }
                if let duration = displayEclipse.durationSeconds {
                    MetadataRow(title: "Central duration", value: CatalogDateSearch.durationString(seconds: duration))
                }
                if let pathWidthKm = displayEclipse.pathWidthKm {
                    MetadataRow(title: "Path width", value: "\(Int(pathWidthKm)) km")
                }
                if let visibilitySummary = displayEclipse.visibilitySummary {
                    Text(visibilitySummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(displayEclipse.displayTypeLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: eclipse.id) {
            detailedEclipse = (try? services.eclipseService.eclipse(withID: eclipse.id)) ?? eclipse
            geometry = try? services.eclipseService.pathGeometry(for: eclipse.id)
        }
    }
}

private struct EclipseMapView: View {
    let eclipse: Eclipse
    let geometry: EclipsePathGeometry?

    private var mapRegion: MKCoordinateRegion? {
        if let geometry, let region = region(for: geometry.polygons.flatMap { $0 }) {
            return region
        }

        if let center = eclipse.maximumPoint {
            return region(center: center)
        }

        return nil
    }

    var body: some View {
        if let mapRegion {
            Map(initialPosition: .region(mapRegion)) {
                if let geometry {
                    ForEach(Array(geometry.polygons.enumerated()), id: \.offset) { _, polygon in
                        if polygon.count >= 3 {
                            MapPolygon(coordinates: polygon.map(\.clLocationCoordinate))
                                .foregroundStyle(.cyan.opacity(0.22))
                                .stroke(.cyan, lineWidth: 1)
                        }
                    }

                    if !geometry.centerline.isEmpty {
                        MapPolyline(coordinates: geometry.centerline.map(\.clLocationCoordinate))
                            .stroke(.orange, lineWidth: 2)
                    }
                }

                if let center = eclipse.maximumPoint {
                    Marker("Maximum", coordinate: center.clLocationCoordinate)
                }
            }
        } else {
            ContentUnavailableView("No map point", systemImage: "map")
        }
    }

    private func region(center: Coordinate) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center.clLocationCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 45, longitudeDelta: 90)
        )
    }

    private func region(for coordinates: [Coordinate]) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }

        let minLatitude = coordinates.map(\.latitude).min() ?? 0
        let maxLatitude = coordinates.map(\.latitude).max() ?? 0
        let minLongitude = coordinates.map(\.longitude).min() ?? 0
        let maxLongitude = coordinates.map(\.longitude).max() ?? 0
        let latitudeDelta = max(maxLatitude - minLatitude, 12)
        let longitudeDelta = max(maxLongitude - minLongitude, 18)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: min(latitudeDelta * 1.25, 140),
                longitudeDelta: min(longitudeDelta * 1.25, 320)
            )
        )
    }
}

private struct SarosEclipseRow: View {
    let eclipse: Eclipse

    var body: some View {
        HStack(spacing: 12) {
            EclipseTypeBadge(label: eclipse.displayTypeLabel)

            VStack(alignment: .leading, spacing: 4) {
                Text(JournalFormatters.date.string(from: eclipse.date))
                    .font(.headline)
                Text(seriesLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var seriesLine: String {
        guard let sequence = eclipse.sarosSequence else {
            return "Saros \(eclipse.saros)"
        }
        if let total = eclipse.sarosSeriesCount {
            return "Eclipse \(sequence) of \(total)"
        }
        return "Eclipse \(sequence)"
    }
}

private struct EclipseSearchRow: Identifiable {
    let eclipse: Eclipse
    let searchedDate: Date?
    let delta: TimeInterval?

    var id: String { eclipse.id }

    init(eclipse: Eclipse, searchedDate: Date?) {
        self.eclipse = eclipse
        self.searchedDate = searchedDate
        self.delta = searchedDate.map { eclipse.date.timeIntervalSince($0) }
    }
}

private struct EclipseSearchRowView: View {
    let row: EclipseSearchRow

    var body: some View {
        HStack(spacing: 12) {
            EclipseSequenceGlyph(eclipse: row.eclipse)
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    EclipseTypeBadge(label: row.eclipse.displayTypeLabel)
                    Text(JournalFormatters.date.string(from: row.eclipse.date))
                        .font(.headline)
                }

                Text(metadataLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let delta = row.delta {
                    Label(deltaLine(delta), systemImage: delta >= 0 ? "arrow.forward.circle" : "arrow.backward.circle")
                        .font(.caption)
                        .foregroundStyle(delta >= 0 ? .green : .orange)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var metadataLine: String {
        var parts = ["Saros \(row.eclipse.saros)"]
        if let sequence = row.eclipse.sarosSequence {
            parts.append("series #\(sequence)")
        }
        if let globalSequence = row.eclipse.globalSequence {
            parts.append("catalog #\(globalSequence)")
        }
        return parts.joined(separator: " · ")
    }

    private func deltaLine(_ delta: TimeInterval) -> String {
        if abs(delta) < 60 {
            return "Same time"
        }
        let relation = delta >= 0 ? "After" : "Before"
        return "\(relation) · \(CatalogDateSearch.deltaString(seconds: abs(delta)))"
    }
}

private struct EclipseTypeBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.bold).monospaced())
            .foregroundStyle(.primary)
            .frame(minWidth: 34, minHeight: 28)
            .padding(.horizontal, 6)
            .background(.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.cyan.opacity(0.3), lineWidth: 1)
            }
    }
}

private struct EclipseSequenceGlyph: View {
    let eclipse: Eclipse

    var body: some View {
        OctalGlyph(value: octalValue, depth: 5, color: .cyan)
            .padding(7)
            .background(.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Eclipse sequence glyph")
    }

    private var octalValue: String {
        String(max(eclipse.globalSequence ?? 0, 0), radix: 8)
    }
}

private enum CatalogDateSearch {
    private static let searchFormats = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy-MM", "yyyy"]

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let deltaFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.year, .month, .day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for format in searchFormats {
            dateFormatter.dateFormat = format
            if let date = dateFormatter.date(from: trimmed) {
                return calendar.startOfDay(for: date)
            }
        }

        return nil
    }

    static func deltaString(seconds: TimeInterval) -> String {
        deltaFormatter.string(from: seconds) ?? "\(Int(seconds))s"
    }

    static func durationString(seconds: TimeInterval) -> String {
        durationFormatter.string(from: seconds) ?? "\(Int(seconds))s"
    }
}

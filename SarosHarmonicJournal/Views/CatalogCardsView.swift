import SwiftUI

struct CatalogCardsView: View {
    @EnvironmentObject private var services: AppServices

    let eclipses: [Eclipse]
    let bounds: CatalogCenturyBounds
    let errorMessage: String?

    @State private var selectedMode: CatalogCardsGameMode = .closestSaros
    @State private var round: CatalogCardsRound?
    @State private var details: CatalogCardsTargetDetails?
    @State private var stage: CatalogCardsStage = .saros
    @State private var sarosGuess = ""
    @State private var sequenceGuess = ""
    @State private var selectedContinents: Set<CatalogCardsContinent> = []
    @State private var score = 0
    @State private var mistakes = 0
    @State private var completedRounds = 0
    @State private var feedback: CatalogCardsFeedback?
    @State private var isLoadingDetails = false

    private var resetKey: CatalogCardsResetKey {
        CatalogCardsResetKey(
            mode: selectedMode,
            startCentury: bounds.startCentury,
            endCentury: bounds.endCentury,
            eclipseIDs: eclipses.map(\.id)
        )
    }

    var body: some View {
        List {
            Section {
                Picker("Mode", selection: $selectedMode) {
                    ForEach(CatalogCardsGameMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Label("\(score)", systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                    Spacer()
                    Label("\(mistakes)", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                    Spacer()
                    Label("\(completedRounds)", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                .font(.headline.monospacedDigit())
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if eclipses.isEmpty && errorMessage == nil {
                ContentUnavailableView("No cards", systemImage: "rectangle.on.rectangle")
            } else if let round {
                promptSection(round)
                sarosTimelineSection(round)
                answerSection(round)
                progressSection(round)
            }
        }
        .task(id: resetKey) {
            await MainActor.run {
                dealNextRound()
            }
        }
    }

    private func promptSection(_ round: CatalogCardsRound) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Closest eclipse to")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(JournalFormatters.dateTime.string(from: round.promptDate))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                Text(bounds.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
    }

    private func sarosTimelineSection(_ round: CatalogCardsRound) -> some View {
        Section("Saros sequence") {
            CatalogCardsSarosTimelineView(
                bins: CatalogCardsYearBin.make(eclipses: eclipses, bounds: bounds),
                promptDate: round.promptDate,
                target: details?.eclipse ?? round.target,
                targetRevealed: stage != .saros
            )
            .frame(height: 132)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        }
    }

    @ViewBuilder
    private func answerSection(_ round: CatalogCardsRound) -> some View {
        switch selectedMode {
        case .closestSaros:
            switch stage {
            case .saros:
                sarosGuessSection(round)
            case .type:
                typeGuessSection(round)
            case .direction:
                directionGuessSection
            case .sequence:
                sequenceGuessSection(round)
            case .continents:
                continentsGuessSection
            case .complete:
                completionSection(round)
            }
        }
    }

    private func sarosGuessSection(_ round: CatalogCardsRound) -> some View {
        Section("Saros") {
            TextField("Saros number", text: $sarosGuess)
                .keyboardType(.numberPad)

            Button {
                submitSaros(round)
            } label: {
                Label("Check Saros", systemImage: "number")
            }
            .disabled(Int(sarosGuess.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
        }
    }

    private func typeGuessSection(_ round: CatalogCardsRound) -> some View {
        let target = details?.eclipse ?? round.target
        let options = typeOptions(including: target.displayTypeLabel)

        return Section("Eclipse type") {
            CatalogCardsChipGrid(options) { label in
                Button {
                    submitType(label, round: round)
                } label: {
                    Text(label)
                        .font(.headline.monospaced())
                        .frame(minWidth: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var directionGuessSection: some View {
        Section("Series direction") {
            if isLoadingDetails {
                ProgressView("Loading series")
            }

            HStack {
                ForEach(CatalogCardsSeriesDirection.playableCases) { direction in
                    Button {
                        submitDirection(direction)
                    } label: {
                        Label(direction.title, systemImage: direction.symbolName)
                    }
                    .buttonStyle(.bordered)
                    .disabled(details?.direction == nil)
                }
            }
        }
    }

    private func sequenceGuessSection(_ round: CatalogCardsRound) -> some View {
        Section("Series position") {
            TextField("Position number", text: $sequenceGuess)
                .keyboardType(.numberPad)

            if let total = (details?.eclipse ?? round.target).sarosSeriesCount {
                Text("Enter the eclipse number within this Saros series, from 1 to \(total).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                submitSequence(round)
            } label: {
                Label("Check position", systemImage: "list.number")
            }
            .disabled(Int(sequenceGuess.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
        }
    }

    private var continentsGuessSection: some View {
        Section("Continents") {
            if isLoadingDetails {
                ProgressView("Loading path")
            }

            CatalogCardsChipGrid(CatalogCardsContinent.allCases) { continent in
                Button {
                    if selectedContinents.contains(continent) {
                        selectedContinents.remove(continent)
                    } else {
                        selectedContinents.insert(continent)
                    }
                } label: {
                    Label(continent.title, systemImage: selectedContinents.contains(continent) ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.bordered)
                .tint(selectedContinents.contains(continent) ? .green : .secondary)
            }

            Button {
                submitContinents()
            } label: {
                Label("Check continents", systemImage: "globe")
            }
            .disabled(details?.continents == nil)
        }
    }

    private func completionSection(_ round: CatalogCardsRound) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Card complete")
                    .font(.title3.weight(.semibold))
                answerSummary(round)
            }

            Button {
                dealNextRound()
            } label: {
                Label("Next card", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func progressSection(_ round: CatalogCardsRound) -> some View {
        Section {
            if let feedback {
                Label(feedback.message, systemImage: feedback.symbolName)
                    .foregroundStyle(feedback.color)
            }

            if stage != .saros {
                answerSummary(round, compact: true)
            }
        }
    }

    private func answerSummary(_ round: CatalogCardsRound, compact: Bool = false) -> some View {
        let target = details?.eclipse ?? round.target

        return VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            MetadataRow(title: "Date", value: JournalFormatters.dateTime.string(from: target.date))
            MetadataRow(title: "Delta", value: CatalogCardsFormat.delta(target.date.timeIntervalSince(round.promptDate)))
            MetadataRow(title: "Saros", value: "\(target.saros)")

            if stage.rawValue > CatalogCardsStage.type.rawValue || stage == .complete {
                MetadataRow(title: "Type", value: target.displayTypeLabel)
            }
            if stage.rawValue > CatalogCardsStage.direction.rawValue || stage == .complete {
                MetadataRow(title: "Direction", value: details?.direction.title ?? "Unknown")
            }
            if stage.rawValue > CatalogCardsStage.sequence.rawValue || stage == .complete {
                MetadataRow(title: "Series #", value: sequenceSummary(for: target))
            }
            if stage == .complete {
                MetadataRow(title: "Continents", value: continentSummary(details?.continents))
            }
        }
        .font(compact ? .caption : .body)
    }

    @MainActor
    private func dealNextRound() {
        guard let promptDate = randomDate(in: bounds),
              let target = nearestEclipse(to: promptDate) else {
            round = nil
            return
        }

        let nextRound = CatalogCardsRound(promptDate: promptDate, target: target)
        round = nextRound
        details = nil
        stage = .saros
        sarosGuess = ""
        sequenceGuess = ""
        selectedContinents = []
        feedback = CatalogCardsFeedback(message: "New card dealt.", isCorrect: nil)
        isLoadingDetails = true

        Task {
            await loadDetails(for: nextRound)
        }
    }

    @MainActor
    private func loadDetails(for round: CatalogCardsRound) async {
        let detailed = (try? services.eclipseService.eclipse(withID: round.target.id)) ?? round.target
        let series = (try? services.eclipseService.eclipses(forSaros: round.target.saros)) ?? []
        let geometry = try? services.eclipseService.pathGeometry(for: round.target.id)
        let loadedDetails = CatalogCardsTargetDetails(
            eclipse: detailed,
            direction: CatalogCardsSeriesDirection.direction(for: detailed, series: series),
            continents: CatalogCardsContinentDetector.continents(for: detailed, geometry: geometry)
        )

        guard self.round?.id == round.id else { return }
        details = loadedDetails
        isLoadingDetails = false
    }

    private func submitSaros(_ round: CatalogCardsRound) {
        guard let guess = Int(sarosGuess.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        guard guess == round.target.saros else {
            markWrong("Not Saros \(guess). Keep the date in your head.")
            return
        }

        markCorrect("Saros \(round.target.saros) locked.")
        stage = .type
    }

    private func submitType(_ label: String, round: CatalogCardsRound) {
        let target = details?.eclipse ?? round.target
        guard label == target.displayTypeLabel else {
            markWrong("\(label) is not the type.")
            return
        }

        markCorrect("\(label) locked.")
        stage = .direction
    }

    private func submitDirection(_ direction: CatalogCardsSeriesDirection) {
        guard let targetDirection = details?.direction else { return }
        guard direction == targetDirection else {
            markWrong("\(direction.title) is not the direction.")
            return
        }

        markCorrect("\(direction.title) locked.")
        stage = .sequence
    }

    private func submitSequence(_ round: CatalogCardsRound) {
        guard let guess = Int(sequenceGuess.trimmingCharacters(in: .whitespacesAndNewlines)),
              let targetSequence = (details?.eclipse ?? round.target).sarosSequence else { return }
        guard guess == targetSequence else {
            markWrong("Not position \(guess).")
            return
        }

        markCorrect("Position \(targetSequence) locked.")
        stage = .continents
    }

    private func submitContinents() {
        guard let targetContinents = details?.continents else { return }
        guard selectedContinents == targetContinents else {
            markWrong("The path does not match that continent set.")
            return
        }

        markCorrect("Path locked.")
        completedRounds += 1
        stage = .complete
    }

    private func markCorrect(_ message: String) {
        score += 1
        feedback = CatalogCardsFeedback(message: message, isCorrect: true)
    }

    private func markWrong(_ message: String) {
        mistakes += 1
        feedback = CatalogCardsFeedback(message: message, isCorrect: false)
    }

    private func randomDate(in bounds: CatalogCenturyBounds) -> Date? {
        let start = bounds.startDate.timeIntervalSince1970
        let end = bounds.endDate.timeIntervalSince1970
        guard end > start else { return nil }
        return Date(timeIntervalSince1970: Double.random(in: start..<end))
    }

    private func nearestEclipse(to date: Date) -> Eclipse? {
        eclipses.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    private func typeOptions(including target: String) -> [String] {
        let labels = Set(eclipses.map(\.displayTypeLabel)).union([target])
        return labels.sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count < rhs.count
            }
            return lhs < rhs
        }
    }

    private func sequenceSummary(for eclipse: Eclipse) -> String {
        guard let sequence = eclipse.sarosSequence else { return "Unknown" }
        if let total = eclipse.sarosSeriesCount {
            return "\(sequence) of \(total)"
        }
        return "\(sequence)"
    }

    private func continentSummary(_ continents: Set<CatalogCardsContinent>?) -> String {
        guard let continents else { return "Loading" }
        return continents.sorted().map(\.title).joined(separator: ", ")
    }
}

private enum CatalogCardsGameMode: String, CaseIterable, Identifiable, Hashable {
    case closestSaros

    var id: String { rawValue }

    var title: String {
        switch self {
        case .closestSaros: "Closest Saros"
        }
    }
}

private struct CatalogCardsResetKey: Hashable {
    let mode: CatalogCardsGameMode
    let startCentury: Int
    let endCentury: Int
    let eclipseIDs: [String]
}

private struct CatalogCardsRound: Identifiable {
    let id = UUID()
    let promptDate: Date
    let target: Eclipse
}

private struct CatalogCardsTargetDetails {
    let eclipse: Eclipse
    let direction: CatalogCardsSeriesDirection
    let continents: Set<CatalogCardsContinent>
}

private struct CatalogCardsYearBin: Identifiable, Hashable {
    let year: Int
    let eclipses: [Eclipse]

    var id: Int { year }

    static func make(eclipses: [Eclipse], bounds: CatalogCenturyBounds) -> [CatalogCardsYearBin] {
        let grouped = Dictionary(grouping: eclipses) { eclipse in
            CatalogCardsCalendar.year(for: eclipse.date)
        }
        let startYear = (bounds.startCentury - 1) * 100 + 1
        let endYear = bounds.endCentury * 100

        return (startYear...endYear).map { year in
            CatalogCardsYearBin(
                year: year,
                eclipses: (grouped[year] ?? []).sorted { $0.date < $1.date }
            )
        }
    }
}

private struct CatalogCardsSarosTimelineView: View {
    let bins: [CatalogCardsYearBin]
    let promptDate: Date
    let target: Eclipse
    let targetRevealed: Bool

    private var promptYear: Int {
        CatalogCardsCalendar.year(for: promptDate)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(bins) { bin in
                        CatalogCardsYearBinView(
                            bin: bin,
                            isPromptYear: bin.year == promptYear,
                            targetID: target.id,
                            targetRevealed: targetRevealed
                        )
                        .id(bin.year)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
            .onAppear {
                proxy.scrollTo(promptYear, anchor: .center)
            }
            .onChange(of: promptYear) { _, year in
                withAnimation(.snappy(duration: 0.35)) {
                    proxy.scrollTo(year, anchor: .center)
                }
            }
        }
    }
}

private struct CatalogCardsYearBinView: View {
    let bin: CatalogCardsYearBin
    let isPromptYear: Bool
    let targetID: String
    let targetRevealed: Bool

    var body: some View {
        VStack(spacing: 7) {
            Text(String(bin.year))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(isPromptYear ? .primary : .secondary)
                .frame(height: 18)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 4),
                    GridItem(.flexible(), spacing: 4)
                ],
                spacing: 5
            ) {
                ForEach(bin.eclipses) { eclipse in
                    CatalogCardsSarosTimelineChip(
                        eclipse: eclipse,
                        isTarget: targetRevealed && eclipse.id == targetID
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: 94, height: 116)
        .padding(8)
        .background(isPromptYear ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPromptYear ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18), lineWidth: isPromptYear ? 1.5 : 1)
        }
    }
}

private struct CatalogCardsSarosTimelineChip: View {
    let eclipse: Eclipse
    let isTarget: Bool

    var body: some View {
        Text("\(eclipse.saros)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(isTarget ? .black : .primary)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(isTarget ? Color.green : Color.cyan.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isTarget ? Color.green.opacity(0.8) : Color.cyan.opacity(0.32), lineWidth: 1)
            }
            .accessibilityLabel("Saros \(eclipse.saros), \(JournalFormatters.date.string(from: eclipse.date))")
    }
}

private enum CatalogCardsCalendar {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    static func year(for date: Date) -> Int {
        calendar.component(.year, from: date)
    }
}

private enum CatalogCardsStage: Int {
    case saros
    case type
    case direction
    case sequence
    case continents
    case complete
}

private struct CatalogCardsFeedback {
    let message: String
    let isCorrect: Bool?

    var color: Color {
        switch isCorrect {
        case .some(true): .green
        case .some(false): .red
        case nil: .secondary
        }
    }

    var symbolName: String {
        switch isCorrect {
        case .some(true): "checkmark.circle.fill"
        case .some(false): "xmark.circle.fill"
        case nil: "rectangle.on.rectangle"
        }
    }
}

private enum CatalogCardsSeriesDirection: String, CaseIterable, Identifiable {
    case ascending
    case descending
    case unknown

    static let playableCases: [CatalogCardsSeriesDirection] = [.ascending, .descending]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ascending: "Ascending"
        case .descending: "Descending"
        case .unknown: "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .ascending: "arrow.up.right"
        case .descending: "arrow.down.right"
        case .unknown: "questionmark.circle"
        }
    }

    static func direction(for target: Eclipse, series: [Eclipse]) -> CatalogCardsSeriesDirection {
        let ordered = series.sorted { $0.date < $1.date }
        guard let firstLatitude = ordered.first?.maximumPoint?.latitude,
              let lastLatitude = ordered.last?.maximumPoint?.latitude else {
            return .unknown
        }

        let delta = lastLatitude - firstLatitude
        if abs(delta) < 0.1 {
            return .unknown
        }
        return delta > 0 ? .ascending : .descending
    }
}

private enum CatalogCardsContinent: String, CaseIterable, Identifiable, Comparable {
    case northAmerica
    case southAmerica
    case europe
    case africa
    case asia
    case oceania
    case antarctica
    case oceanOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .northAmerica: "N. America"
        case .southAmerica: "S. America"
        case .europe: "Europe"
        case .africa: "Africa"
        case .asia: "Asia"
        case .oceania: "Oceania"
        case .antarctica: "Antarctica"
        case .oceanOnly: "Ocean only"
        }
    }

    static func < (lhs: CatalogCardsContinent, rhs: CatalogCardsContinent) -> Bool {
        guard let lhsIndex = allCases.firstIndex(of: lhs),
              let rhsIndex = allCases.firstIndex(of: rhs) else {
            return lhs.rawValue < rhs.rawValue
        }
        return lhsIndex < rhsIndex
    }
}

private enum CatalogCardsContinentDetector {
    static func continents(for eclipse: Eclipse, geometry: EclipsePathGeometry?) -> Set<CatalogCardsContinent> {
        let coordinates: [Coordinate]
        if let geometry {
            coordinates = geometry.polygons.flatMap { $0 } + geometry.centerline
        } else if let maximumPoint = eclipse.maximumPoint {
            coordinates = [maximumPoint]
        } else {
            coordinates = []
        }

        let detected = coordinates.reduce(into: Set<CatalogCardsContinent>()) { result, coordinate in
            for region in regions where region.contains(coordinate) {
                result.insert(region.continent)
            }
        }

        return detected.isEmpty ? [.oceanOnly] : detected
    }

    private static let regions: [CatalogCardsContinentRegion] = [
        CatalogCardsContinentRegion(.northAmerica, latitude: 5...84, longitude: -170 ... -50),
        CatalogCardsContinentRegion(.southAmerica, latitude: -57...14, longitude: -84 ... -32),
        CatalogCardsContinentRegion(.europe, latitude: 35...72, longitude: -25 ... 60),
        CatalogCardsContinentRegion(.africa, latitude: -36...38, longitude: -20 ... 56),
        CatalogCardsContinentRegion(.asia, latitude: -12...82, longitude: 25 ... 180),
        CatalogCardsContinentRegion(.asia, latitude: 55...82, longitude: -180 ... -155),
        CatalogCardsContinentRegion(.oceania, latitude: -50...8, longitude: 105 ... 180),
        CatalogCardsContinentRegion(.oceania, latitude: -50...0, longitude: -180 ... -125),
        CatalogCardsContinentRegion(.antarctica, latitude: -90 ... -60, longitude: -180 ... 180)
    ]
}

private struct CatalogCardsContinentRegion {
    let continent: CatalogCardsContinent
    let latitude: ClosedRange<Double>
    let longitude: ClosedRange<Double>

    init(_ continent: CatalogCardsContinent, latitude: ClosedRange<Double>, longitude: ClosedRange<Double>) {
        self.continent = continent
        self.latitude = latitude
        self.longitude = longitude
    }

    func contains(_ coordinate: Coordinate) -> Bool {
        latitude.contains(coordinate.latitude) && longitude.contains(normalizedLongitude(coordinate.longitude))
    }

    private func normalizedLongitude(_ longitude: Double) -> Double {
        var value = longitude
        while value > 180 {
            value -= 360
        }
        while value < -180 {
            value += 360
        }
        return value
    }
}

private struct CatalogCardsChipGrid<Options: RandomAccessCollection, Content: View>: View where Options.Element: Hashable {
    let options: Options
    let content: (Options.Element) -> Content

    init(_ options: Options, @ViewBuilder content: @escaping (Options.Element) -> Content) {
        self.options = options
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(Array(options), id: \.self) { option in
                content(option)
            }
        }
        .padding(.vertical, 4)
    }
}

private enum CatalogCardsFormat {
    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.year, .month, .day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func delta(_ interval: TimeInterval) -> String {
        let relation = interval >= 0 ? "after prompt" : "before prompt"
        let value = formatter.string(from: abs(interval)) ?? "\(Int(abs(interval)))s"
        return "\(value) \(relation)"
    }
}

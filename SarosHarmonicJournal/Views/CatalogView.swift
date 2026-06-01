import MapKit
import SwiftUI

struct CatalogView: View {
    @EnvironmentObject private var services: AppServices

    @State private var selectedSection: CatalogSection = .saros
    @State private var eclipses: [Eclipse] = []
    @State private var eclipseSearchText = ""
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

    var body: some View {
        VStack(spacing: 0) {
            Picker("Catalog", selection: $selectedSection) {
                ForEach(CatalogSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])

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
                    bounds: catalogBounds,
                    searchText: $eclipseSearchText,
                    errorMessage: errorMessage
                )
            }
        }
        .navigationTitle("Catalog")
        .task {
            do {
                eclipses = try services.eclipseService.allEclipses()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum CatalogSection: String, CaseIterable, Identifiable {
    case saros
    case eclipses

    var id: String { rawValue }

    var title: String {
        switch self {
        case .saros: "Saros"
        case .eclipses: "Eclipses"
        }
    }
}

private struct SarosCatalogList: View {
    let series: [SarosSeriesSummary]
    let bounds: CatalogCenturyBounds
    let errorMessage: String?

    var body: some View {
        List {
            Section {
                MetadataRow(title: "Bounds", value: bounds.displayTitle)
                MetadataRow(title: "Saros series", value: "\(series.count)")
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            if series.isEmpty && errorMessage == nil {
                ContentUnavailableView("No Saros series", systemImage: "calendar")
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
    let bounds: CatalogCenturyBounds
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
            Section {
                MetadataRow(title: "Bounds", value: bounds.displayTitle)
                MetadataRow(title: "Eclipses", value: "\(eclipses.count)")
            }

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
        .searchable(text: $searchText, prompt: "Search by date")
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

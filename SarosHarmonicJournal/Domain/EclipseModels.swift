import CoreLocation
import Foundation

struct Coordinate: Codable, Hashable {
    var latitude: Double
    var longitude: Double

    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum EclipseType: String, Codable, CaseIterable {
    case totalSolar
    case annularSolar
    case partialSolar
    case hybridSolar
    case totalLunar
    case partialLunar
    case penumbralLunar
    case unknown

    var displayName: String {
        switch self {
        case .totalSolar: "Total solar"
        case .annularSolar: "Annular solar"
        case .partialSolar: "Partial solar"
        case .hybridSolar: "Hybrid solar"
        case .totalLunar: "Total lunar"
        case .partialLunar: "Partial lunar"
        case .penumbralLunar: "Penumbral lunar"
        case .unknown: "Unknown"
        }
    }

    var shortLabel: String {
        switch self {
        case .totalSolar, .totalLunar: "T"
        case .annularSolar: "A"
        case .partialSolar, .partialLunar, .penumbralLunar: "P"
        case .hybridSolar: "H"
        case .unknown: "?"
        }
    }

    var isPartialSolar: Bool {
        self == .partialSolar
    }
}

struct Eclipse: Identifiable, Codable, Hashable {
    let id: String
    let saros: Int
    let date: Date
    let type: EclipseType
    let maximumPoint: Coordinate?
    let gamma: Double?
    let magnitude: Double?
    let durationSeconds: Double?
    let pathWidthKm: Double?
    let visibilitySummary: String?
    var typeLabel: String? = nil
    var sarosSequence: Int? = nil
    var sarosSeriesCount: Int? = nil
    var globalIndex: Int? = nil
    var sunAltitude: Int? = nil

    var displayTypeLabel: String {
        typeLabel ?? type.shortLabel
    }

    var globalSequence: Int? {
        globalIndex.map { $0 + 1 }
    }
}

struct SarosSeriesSummary: Identifiable, Codable, Hashable {
    var id: Int { saros }

    let saros: Int
    let eclipseCount: Int
    let firstEclipseDate: Date
    let lastEclipseDate: Date
}

struct SarosInterval: Codable, Hashable {
    let saros: Int
    let previous: Eclipse
    let next: Eclipse
    let normalizedPhase: Double
}

struct EclipseBracket: Codable, Hashable {
    let previous: Eclipse
    let next: Eclipse
    let normalizedPhase: Double

    var gapDuration: TimeInterval {
        next.date.timeIntervalSince(previous.date)
    }

    func closest(to date: Date) -> Eclipse {
        abs(date.timeIntervalSince(previous.date)) <= abs(next.date.timeIntervalSince(date))
            ? previous
            : next
    }
}

struct EclipsePathGeometry: Codable, Hashable {
    var centerline: [Coordinate]
    var polygons: [[Coordinate]]
}

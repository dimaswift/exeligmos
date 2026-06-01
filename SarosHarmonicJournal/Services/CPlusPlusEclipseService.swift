import Foundation

final class CPlusPlusEclipseService: EclipseService {
    private let fallback: any EclipseService

    init(fallback: any EclipseService = BundledSolarEclipseService()) {
        self.fallback = fallback
    }

    func allSarosSeries() throws -> [SarosSeriesSummary] {
        try fallback.allSarosSeries()
    }

    func allEclipses() throws -> [Eclipse] {
        try fallback.allEclipses()
    }

    func eclipses(forSaros saros: Int) throws -> [Eclipse] {
        try fallback.eclipses(forSaros: saros)
    }

    func eclipse(withID eclipseID: String) throws -> Eclipse? {
        try fallback.eclipse(withID: eclipseID)
    }

    func previousAndNextEclipse(saros: Int, around date: Date) throws -> SarosInterval? {
        try fallback.previousAndNextEclipse(saros: saros, around: date)
    }

    func nearestEclipse(to date: Date) throws -> Eclipse? {
        try fallback.nearestEclipse(to: date)
    }

    func pathGeometry(for eclipseID: String) throws -> EclipsePathGeometry? {
        try fallback.pathGeometry(for: eclipseID)
    }
}

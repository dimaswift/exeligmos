import Foundation

protocol EclipseService {
    func allSarosSeries() throws -> [SarosSeriesSummary]
    func allEclipses() throws -> [Eclipse]
    func eclipses(forSaros saros: Int) throws -> [Eclipse]
    func eclipse(withID eclipseID: String) throws -> Eclipse?
    func previousAndNextEclipse(saros: Int, around date: Date) throws -> SarosInterval?
    func nearestEclipse(to date: Date) throws -> Eclipse?
    func pathGeometry(for eclipseID: String) throws -> EclipsePathGeometry?
}

enum EclipseServiceError: LocalizedError {
    case missingBundledData(String)
    case corruptBundledData(String)
    case sarosNotFound(Int)

    var errorDescription: String? {
        switch self {
        case .missingBundledData(let name):
            "Missing bundled eclipse data: \(name)"
        case .corruptBundledData(let detail):
            "Corrupt bundled eclipse data: \(detail)"
        case .sarosNotFound(let saros):
            "No eclipses found for Saros \(saros)."
        }
    }
}

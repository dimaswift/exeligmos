import Foundation

protocol EclipseService {
    func allSarosSeries() throws -> [SarosSeriesSummary]
    func allEclipses() throws -> [Eclipse]
    func eclipses(forSaros saros: Int) throws -> [Eclipse]
    func eclipse(withID eclipseID: String) throws -> Eclipse?
    func previousAndNextEclipse(saros: Int, around date: Date) throws -> SarosInterval?
    func eclipseBracket(around date: Date) throws -> EclipseBracket?
    func nearestEclipse(to date: Date) throws -> Eclipse?
    func pathGeometry(for eclipseID: String) throws -> EclipsePathGeometry?
}

struct SarosActivityPolicy: Hashable, Sendable {
    let nonPartialOnly: Bool

    static let allEclipses = SarosActivityPolicy(nonPartialOnly: false)
    static let nonPartialOnly = SarosActivityPolicy(nonPartialOnly: true)

    func includes(_ eclipse: Eclipse) -> Bool {
        !nonPartialOnly || eclipse.type.isNonPartialSolar
    }
}

struct ActiveSarosInterval: Hashable {
    let summary: SarosSeriesSummary
    let interval: SarosInterval
}

extension EclipseService {
    func activeSarosIntervals(
        at date: Date,
        policy: SarosActivityPolicy = .allEclipses
    ) throws -> [ActiveSarosInterval] {
        try allSarosSeries()
            .filter {
                $0.firstEclipseDate < date &&
                    $0.lastEclipseDate > date
            }
            .compactMap { summary in
                try activeSarosInterval(summary: summary, at: date, policy: policy)
            }
            .sorted { $0.summary.saros < $1.summary.saros }
    }

    func activeSarosInterval(
        saros: Int,
        at date: Date,
        policy: SarosActivityPolicy = .allEclipses
    ) throws -> ActiveSarosInterval? {
        guard let summary = try allSarosSeries().first(where: { $0.saros == saros }) else {
            return nil
        }
        return try activeSarosInterval(summary: summary, at: date, policy: policy)
    }

    private func activeSarosInterval(
        summary: SarosSeriesSummary,
        at date: Date,
        policy: SarosActivityPolicy
    ) throws -> ActiveSarosInterval? {
        guard
            summary.firstEclipseDate < date,
            summary.lastEclipseDate > date
        else {
            return nil
        }

        let eligibleEclipses = try eclipses(forSaros: summary.saros)
            .filter(policy.includes)
            .sorted { $0.date < $1.date }

        guard
            eligibleEclipses.count >= 2,
            let first = eligibleEclipses.first,
            let last = eligibleEclipses.last,
            first.date < date,
            last.date > date,
            let interval = Self.interval(
                saros: summary.saros,
                around: date,
                eclipses: eligibleEclipses
            )
        else {
            return nil
        }

        return ActiveSarosInterval(summary: summary, interval: interval)
    }

    private static func interval(
        saros: Int,
        around date: Date,
        eclipses: [Eclipse]
    ) -> SarosInterval? {
        guard eclipses.count >= 2 else { return nil }

        let previous: Eclipse
        let next: Eclipse

        if date <= eclipses[0].date {
            previous = eclipses[0]
            next = eclipses[1]
        } else if date >= eclipses[eclipses.count - 1].date {
            previous = eclipses[eclipses.count - 2]
            next = eclipses[eclipses.count - 1]
        } else {
            guard let nextIndex = eclipses.firstIndex(where: { $0.date > date }), nextIndex > 0 else {
                return nil
            }
            previous = eclipses[nextIndex - 1]
            next = eclipses[nextIndex]
        }

        let total = next.date.timeIntervalSince(previous.date)
        guard total > 0 else { return nil }
        let phase = min(
            max(date.timeIntervalSince(previous.date) / total, 0),
            1 - Double.ulpOfOne
        )

        return SarosInterval(
            saros: saros,
            previous: previous,
            next: next,
            normalizedPhase: phase
        )
    }
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

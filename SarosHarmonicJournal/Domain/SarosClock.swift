import Foundation

struct SarosClockReading: Codable, Hashable {
    let saros: Int
    let previousEclipse: Eclipse
    let nextEclipse: Eclipse
    let phase: Double
    let harmonicDepth: Int
    let binCount: Int
    let binIndex: Int
    let octalAddress: String
    let progressWithinBin: Double
    let nextFlipDate: Date
    let timeUntilNextFlip: TimeInterval
}

protocol SarosClockService {
    func reading(saros: Int, date: Date, harmonicDepth: Int) throws -> SarosClockReading
    func nextFlipDate(saros: Int, date: Date, harmonicDepth: Int) throws -> Date
    func binIndex(saros: Int, date: Date, harmonicDepth: Int) throws -> Int
}

enum SarosClockError: LocalizedError, Equatable {
    case invalidHarmonicDepth(Int)
    case missingSarosInterval(Int)
    case invalidEclipseInterval

    var errorDescription: String? {
        switch self {
        case .invalidHarmonicDepth(let depth):
            "Harmonic depth \(depth) is outside the supported range 1...8."
        case .missingSarosInterval(let saros):
            "Could not find a previous/next eclipse interval for Saros \(saros)."
        case .invalidEclipseInterval:
            "The eclipse interval must have a positive duration."
        }
    }
}

enum SarosClockCalculator {
    static func reading(
        saros: Int,
        previous: Eclipse,
        next: Eclipse,
        now: Date,
        harmonicDepth depth: Int
    ) throws -> SarosClockReading {
        guard (1...8).contains(depth) else {
            throw SarosClockError.invalidHarmonicDepth(depth)
        }

        let total = next.date.timeIntervalSince(previous.date)
        guard total > 0 else {
            throw SarosClockError.invalidEclipseInterval
        }

        let rawPhase = now.timeIntervalSince(previous.date) / total
        let phase = min(max(rawPhase, 0.0), 1.0 - Double.ulpOfOne)
        let binCount = try safeOctalBinCount(depth: depth)
        let scaled = phase * Double(binCount)
        let binIndex = min(Int(floor(scaled)), binCount - 1)
        let progressWithinBin = min(max(scaled - Double(binIndex), 0.0), 1.0)
        let nextBinIndex = min(binIndex + 1, binCount)
        let nextFlipPhase = Double(nextBinIndex) / Double(binCount)
        let nextFlipDate = previous.date.addingTimeInterval(nextFlipPhase * total)
        let octalAddress = String(binIndex, radix: 8).leftPadded(toLength: depth, withPad: "0")

        return SarosClockReading(
            saros: saros,
            previousEclipse: previous,
            nextEclipse: next,
            phase: phase,
            harmonicDepth: depth,
            binCount: binCount,
            binIndex: binIndex,
            octalAddress: octalAddress,
            progressWithinBin: progressWithinBin,
            nextFlipDate: nextFlipDate,
            timeUntilNextFlip: nextFlipDate.timeIntervalSince(now)
        )
    }

    private static func safeOctalBinCount(depth: Int) throws -> Int {
        var value = 1
        for _ in 0..<depth {
            guard value <= Int.max / 8 else {
                throw SarosClockError.invalidHarmonicDepth(depth)
            }
            value *= 8
        }
        return value
    }
}

final class DefaultSarosClockService: SarosClockService {
    private let eclipseService: any EclipseService

    init(eclipseService: any EclipseService) {
        self.eclipseService = eclipseService
    }

    func reading(saros: Int, date: Date, harmonicDepth: Int) throws -> SarosClockReading {
        guard let interval = try eclipseService.previousAndNextEclipse(saros: saros, around: date) else {
            throw SarosClockError.missingSarosInterval(saros)
        }
        return try SarosClockCalculator.reading(
            saros: saros,
            previous: interval.previous,
            next: interval.next,
            now: date,
            harmonicDepth: harmonicDepth
        )
    }

    func nextFlipDate(saros: Int, date: Date, harmonicDepth: Int) throws -> Date {
        try reading(saros: saros, date: date, harmonicDepth: harmonicDepth).nextFlipDate
    }

    func binIndex(saros: Int, date: Date, harmonicDepth: Int) throws -> Int {
        try reading(saros: saros, date: date, harmonicDepth: harmonicDepth).binIndex
    }
}

extension String {
    func leftPadded(toLength length: Int, withPad character: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(character), count: length - count) + self
    }
}


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

struct SarosFlipCountdown: Codable, Hashable {
    let minimumTier: Int
    let flipTier: Int
    let binStride: Int
    let targetBinIndex: Int
    let targetOctalAddress: String
    let periodStartDate: Date
    let flipDate: Date
    let timeUntilFlip: TimeInterval
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

extension SarosClockReading {
    var intervalDuration: TimeInterval {
        nextEclipse.date.timeIntervalSince(previousEclipse.date)
    }

    var binDuration: TimeInterval {
        intervalDuration / Double(binCount)
    }

    func date(forBinIndex index: Int) -> Date {
        let clampedIndex = min(max(index, 0), binCount)
        return previousEclipse.date.addingTimeInterval(Double(clampedIndex) / Double(binCount) * intervalDuration)
    }

    func octalAddress(forBinIndex index: Int) -> String {
        guard index < binCount else {
            return String(repeating: "0", count: harmonicDepth)
        }

        return String(max(index, 0), radix: 8).leftPadded(toLength: harmonicDepth, withPad: "0")
    }

    func binIndex(forOctalAddress address: String) -> Int {
        let value = Int(address, radix: 8) ?? 0
        return min(max(value, 0), binCount - 1)
    }

    func qualifiedFlipStride(forTier rawTier: Int) -> Int {
        let tier = JournalSettings.clampedCountdownMinimumTier(rawTier, harmonicDepth: harmonicDepth)
        let requiredTrailingZeros = max(harmonicDepth - tier - 1, 0)
        return Self.octalPower(requiredTrailingZeros)
    }

    func nextQualifiedFlipBin(after index: Int, tier: Int) -> Int? {
        let stride = qualifiedFlipStride(forTier: tier)
        let bin = Self.roundUp(index + 1, toMultipleOf: stride)
        return bin <= binCount ? bin : nil
    }

    func previousQualifiedFlipBin(atOrBefore index: Int, tier: Int) -> Int? {
        let stride = qualifiedFlipStride(forTier: tier)
        let clampedIndex = min(max(index, 0), binCount)
        let bin = (clampedIndex / stride) * stride
        return bin >= 0 ? bin : nil
    }

    func countdown(minimumTier rawMinimumTier: Int) -> SarosFlipCountdown {
        countdown(
            minimumTier: rawMinimumTier,
            now: nextFlipDate.addingTimeInterval(-timeUntilNextFlip)
        )
    }

    func countdown(minimumTier rawMinimumTier: Int, now: Date) -> SarosFlipCountdown {
        let minimumTier = JournalSettings.clampedCountdownMinimumTier(
            rawMinimumTier,
            harmonicDepth: harmonicDepth
        )
        let binStride = qualifiedFlipStride(forTier: minimumTier)
        let nextTargetBin = Self.roundUp(binIndex + 1, toMultipleOf: binStride)
        let targetBinIndex = min(nextTargetBin, binCount)
        let previousTargetBin = max(targetBinIndex - binStride, 0)
        let totalDuration = nextEclipse.date.timeIntervalSince(previousEclipse.date)
        let periodStartDate = previousEclipse.date.addingTimeInterval(
            Double(previousTargetBin) / Double(binCount) * totalDuration
        )
        let flipDate = previousEclipse.date.addingTimeInterval(
            Double(targetBinIndex) / Double(binCount) * totalDuration
        )
        let targetOctalAddress = targetBinIndex >= binCount
            ? String(repeating: "0", count: harmonicDepth)
            : String(targetBinIndex, radix: 8).leftPadded(toLength: harmonicDepth, withPad: "0")
        let flipTier = FlipNotificationPreferences.tier(
            forOctalAddress: targetOctalAddress,
            harmonicDepth: harmonicDepth
        )

        return SarosFlipCountdown(
            minimumTier: minimumTier,
            flipTier: flipTier,
            binStride: binStride,
            targetBinIndex: targetBinIndex,
            targetOctalAddress: targetOctalAddress,
            periodStartDate: periodStartDate,
            flipDate: flipDate,
            timeUntilFlip: flipDate.timeIntervalSince(now)
        )
    }

    private static func roundUp(_ value: Int, toMultipleOf stride: Int) -> Int {
        guard stride > 1 else { return value }
        return ((value + stride - 1) / stride) * stride
    }

    private static func octalPower(_ exponent: Int) -> Int {
        guard exponent > 0 else { return 1 }
        return (0..<exponent).reduce(1) { value, _ in value * 8 }
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

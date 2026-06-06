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
    let order: Int
    let rarity: FlipRarity
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

    func qualifiedFlipStride(forOrder rawOrder: Int) -> Int {
        let order = clampedFlipOrder(rawOrder)
        return Self.octalPower(order)
    }

    func nextQualifiedFlipBin(after index: Int, order: Int, exact: Bool = false) -> Int? {
        let order = clampedFlipOrder(order)
        let stride = qualifiedFlipStride(forOrder: order)
        let bin = Self.roundUp(index + 1, toMultipleOf: stride)
        guard exact else {
            return bin <= binCount ? bin : nil
        }

        return firstExactFlipBin(startingAt: bin, order: order, stride: stride, direction: .forward)
    }

    func previousQualifiedFlipBin(atOrBefore index: Int, order: Int, exact: Bool = false) -> Int? {
        let order = clampedFlipOrder(order)
        let stride = qualifiedFlipStride(forOrder: order)
        let clampedIndex = min(max(index, 0), binCount)
        let bin = (clampedIndex / stride) * stride
        guard exact else {
            return bin >= 0 ? bin : nil
        }

        return firstExactFlipBin(startingAt: bin, order: order, stride: stride, direction: .backward)
    }

    func countdown(order rawOrder: Int) -> SarosFlipCountdown? {
        countdown(
            order: rawOrder,
            now: nextFlipDate.addingTimeInterval(-timeUntilNextFlip)
        )
    }

    func countdown(order rawOrder: Int, now: Date) -> SarosFlipCountdown? {
        let order = clampedFlipOrder(rawOrder)
        guard let targetBinIndex = nextQualifiedFlipBin(after: binIndex, order: order, exact: true) else {
            return nil
        }
        return countdown(targetBinIndex: targetBinIndex, order: order, now: now)
    }

    func countdown(rarity: FlipRarity, now: Date) -> SarosFlipCountdown? {
        if rarity.isSarosPattern {
            return countdown(sarosPatternRarity: rarity, now: now)
        }

        guard rarity.order <= min(harmonicDepth, 6) else { return nil }
        return countdown(order: rarity.order, now: now)
    }

    func rarityCountdowns(now: Date) -> [SarosFlipCountdown] {
        FlipRarity.visibleRarities(for: harmonicDepth)
            .compactMap { countdown(rarity: $0, now: now) }
    }

    func flipOrder(forBinIndex index: Int) -> Int {
        FlipRarity.order(forOctalAddress: octalAddress(forBinIndex: index), harmonicDepth: harmonicDepth)
    }

    func flipRarity(forBinIndex index: Int) -> FlipRarity {
        FlipRarity.rarity(
            forOctalAddress: octalAddress(forBinIndex: index),
            harmonicDepth: harmonicDepth,
            isEclipse: index >= binCount
        )
    }

    private func countdown(sarosPatternRarity rarity: FlipRarity, now: Date) -> SarosFlipCountdown? {
        guard let targetAddress = rarity.sarosPatternAddress(depth: harmonicDepth),
              let patternBinIndex = Int(targetAddress, radix: 8)
        else {
            return nil
        }

        let targetBinIndex: Int
        if rarity == .saros7, binIndex >= patternBinIndex {
            targetBinIndex = binCount
        } else {
            targetBinIndex = patternBinIndex
        }

        guard targetBinIndex > binIndex, targetBinIndex <= binCount else {
            return nil
        }

        return countdown(
            targetBinIndex: targetBinIndex,
            order: harmonicDepth,
            now: now,
            explicitRarity: rarity,
            periodStartBinIndex: 0
        )
    }

    private func countdown(
        targetBinIndex: Int,
        order rawOrder: Int,
        now: Date,
        explicitRarity: FlipRarity? = nil,
        periodStartBinIndex: Int? = nil
    ) -> SarosFlipCountdown {
        let order = clampedFlipOrder(rawOrder)
        let targetOctalAddress = explicitRarity?.sarosPatternAddress(depth: harmonicDepth)
            ?? octalAddress(forBinIndex: targetBinIndex)
        let rarity = explicitRarity ?? FlipRarity.rarity(
            forOctalAddress: targetOctalAddress,
            harmonicDepth: harmonicDepth,
            isEclipse: targetBinIndex >= binCount
        )
        let defaultStride = targetBinIndex >= binCount ? binCount : qualifiedFlipStride(forOrder: order)
        let defaultPreviousTargetBin = targetBinIndex >= binCount
            ? 0
            : max(targetBinIndex - defaultStride, 0)
        let previousTargetBin = min(max(periodStartBinIndex ?? defaultPreviousTargetBin, 0), binCount)
        let binStride = max(targetBinIndex - previousTargetBin, 1)
        let periodStartDate = date(forBinIndex: previousTargetBin)
        let flipDate = date(forBinIndex: targetBinIndex)

        return SarosFlipCountdown(
            order: rarity.isSarosPattern ? max(order, 7) : order,
            rarity: rarity,
            binStride: binStride,
            targetBinIndex: targetBinIndex,
            targetOctalAddress: targetOctalAddress,
            periodStartDate: periodStartDate,
            flipDate: flipDate,
            timeUntilFlip: flipDate.timeIntervalSince(now)
        )
    }

    private enum FlipSearchDirection {
        case forward
        case backward
    }

    private func firstExactFlipBin(
        startingAt startBin: Int,
        order: Int,
        stride: Int,
        direction: FlipSearchDirection
    ) -> Int? {
        guard stride > 0 else { return nil }
        var bin = startBin

        while bin >= 0 && bin <= binCount {
            if bin < binCount, flipOrder(forBinIndex: bin) == order {
                return bin
            }

            switch direction {
            case .forward:
                bin += stride
            case .backward:
                bin -= stride
            }
        }

        return nil
    }

    private func clampedFlipOrder(_ order: Int) -> Int {
        min(max(order, 1), harmonicDepth)
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

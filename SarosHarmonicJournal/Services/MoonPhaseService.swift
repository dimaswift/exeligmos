import Foundation

enum MoonPhaseKind: UInt8, Codable, Hashable, Sendable {
    case new = 0
    case full = 2

    var displayName: String {
        switch self {
        case .new: "New moon"
        case .full: "Full moon"
        }
    }
}

enum MoonPhaseName: String, Codable, Hashable, Sendable {
    case new
    case waxingCrescent
    case firstQuarter
    case waxingGibbous
    case full
    case waningGibbous
    case lastQuarter
    case waningCrescent

    var displayName: String {
        switch self {
        case .new: "New moon"
        case .waxingCrescent: "Waxing crescent"
        case .firstQuarter: "First quarter"
        case .waxingGibbous: "Waxing gibbous"
        case .full: "Full moon"
        case .waningGibbous: "Waning gibbous"
        case .lastQuarter: "Last quarter"
        case .waningCrescent: "Waning crescent"
        }
    }
}

struct MoonPhaseEvent: Codable, Hashable, Sendable {
    let kind: MoonPhaseKind
    let date: Date
    let lunationIndex: Int
}

struct MoonPhaseReading: Codable, Hashable, Sendable {
    let date: Date
    let phase: MoonPhaseName
    let normalizedPhase: Double
    let illuminatedFraction: Double
    let previousNewMoon: MoonPhaseEvent
    let nextNewMoon: MoonPhaseEvent
    let previousEvent: MoonPhaseEvent
    let nextEvent: MoonPhaseEvent
    let nearestEvent: MoonPhaseEvent
}

struct MoonPhaseOctalReading: Codable, Hashable, Sendable {
    let date: Date
    let phaseReading: MoonPhaseReading
    let depth: Int
    let binCount: Int
    let binIndex: Int
    let octalAddress: String
    let rarity: FlipRarity

    var binDuration: TimeInterval {
        let duration = phaseReading.nextNewMoon.date.timeIntervalSince(phaseReading.previousNewMoon.date)
        return max(duration / Double(binCount), 1)
    }
}

struct MoonPhaseDatabaseSummary: Codable, Hashable, Sendable {
    let coverageStart: Date
    let coverageEnd: Date
    let referenceNewMoon: Date
    let synodicMonthSeconds: Double
    let newMoonCount: Int
    let fullMoonCount: Int
    let byteCount: Int
}

protocol MoonPhaseService {
    func reading(for date: Date) throws -> MoonPhaseReading
    func octalReading(for date: Date, depth: Int) throws -> MoonPhaseOctalReading
    func databaseSummary() throws -> MoonPhaseDatabaseSummary
}

enum MoonPhaseServiceError: LocalizedError, Equatable {
    case missingBundledData(String)
    case corruptBundledData(String)
    case dateOutOfRange(Date)

    var errorDescription: String? {
        switch self {
        case .missingBundledData(let name):
            "Missing bundled moon phase data: \(name)"
        case .corruptBundledData(let detail):
            "Moon phase data is corrupt: \(detail)"
        case .dateOutOfRange(let date):
            "Moon phase data does not cover \(date.formatted())."
        }
    }
}

final class BundledMoonPhaseService: MoonPhaseService {
    private let storeResult: Result<MoonPhaseStore, Error>

    init(bundle: Bundle = .main) {
        storeResult = Result { try MoonPhaseStore(bundle: bundle) }
    }

    func reading(for date: Date) throws -> MoonPhaseReading {
        try store().reading(for: date)
    }

    func octalReading(for date: Date, depth: Int) throws -> MoonPhaseOctalReading {
        try MoonPhaseOctalCalculator.reading(from: reading(for: date), date: date, depth: depth)
    }

    func databaseSummary() throws -> MoonPhaseDatabaseSummary {
        try store().databaseSummary()
    }

    private func store() throws -> MoonPhaseStore {
        try storeResult.get()
    }
}

private struct MoonPhaseStore {
    private static let magic = Data([0x4D, 0x4F, 0x4F, 0x4E, 0x50, 0x30, 0x31, 0x00])
    private static let currentVersion: UInt16 = 1
    private static let correctionByteCount = 3

    private let data: Data
    private let headerSize: Int
    private let coverageStartUnix: Int64
    private let coverageEndUnix: Int64
    private let referenceUnix: Int64
    private let synodicMonthMicros: Int64
    private let firstNewIndex: Int
    private let newCount: Int
    private let firstFullIndex: Int
    private let fullCount: Int
    private let fullCorrectionsOffset: Int

    init(bundle: Bundle) throws {
        data = try Self.loadData(named: "moon_phases", extension: "db", bundle: bundle)
        guard data.count >= 56 else {
            throw MoonPhaseServiceError.corruptBundledData("moon_phases.db is shorter than its header")
        }
        guard data.prefix(Self.magic.count) == Self.magic else {
            throw MoonPhaseServiceError.corruptBundledData("moon_phases.db has the wrong magic header")
        }
        let version = readUInt16LE(from: data, at: 8)
        guard version == Self.currentVersion else {
            throw MoonPhaseServiceError.corruptBundledData("Unsupported moon phase DB version \(version)")
        }

        headerSize = Int(readUInt16LE(from: data, at: 10))
        coverageStartUnix = readInt64LE(from: data, at: 12)
        coverageEndUnix = readInt64LE(from: data, at: 20)
        referenceUnix = readInt64LE(from: data, at: 28)
        synodicMonthMicros = readInt64LE(from: data, at: 36)
        firstNewIndex = Int(readInt32LE(from: data, at: 44))
        newCount = Int(readUInt16LE(from: data, at: 48))
        firstFullIndex = Int(readInt32LE(from: data, at: 50))
        fullCount = Int(readUInt16LE(from: data, at: 54))
        fullCorrectionsOffset = headerSize + newCount * Self.correctionByteCount

        guard headerSize >= 56 else {
            throw MoonPhaseServiceError.corruptBundledData("Header size \(headerSize) is too small")
        }
        let expectedSize = headerSize + (newCount + fullCount) * Self.correctionByteCount
        guard data.count == expectedSize else {
            throw MoonPhaseServiceError.corruptBundledData("Expected \(expectedSize) bytes, found \(data.count)")
        }
        guard newCount >= 2, fullCount >= 2, coverageStartUnix < coverageEndUnix else {
            throw MoonPhaseServiceError.corruptBundledData("Invalid event counts or coverage")
        }
    }

    func databaseSummary() -> MoonPhaseDatabaseSummary {
        MoonPhaseDatabaseSummary(
            coverageStart: Date(timeIntervalSince1970: TimeInterval(coverageStartUnix)),
            coverageEnd: Date(timeIntervalSince1970: TimeInterval(coverageEndUnix)),
            referenceNewMoon: Date(timeIntervalSince1970: TimeInterval(referenceUnix)),
            synodicMonthSeconds: Double(synodicMonthMicros) / 1_000_000,
            newMoonCount: newCount,
            fullMoonCount: fullCount,
            byteCount: data.count
        )
    }

    func reading(for date: Date) throws -> MoonPhaseReading {
        let key = Int64(date.timeIntervalSince1970.rounded())
        guard key >= coverageStartUnix, key < coverageEndUnix else {
            throw MoonPhaseServiceError.dateOutOfRange(date)
        }

        let newBracket = try bracket(kind: .new, key: key)
        let previousNew = try event(kind: .new, storageIndex: newBracket.previous)
        let nextNew = try event(kind: .new, storageIndex: newBracket.next)
        let total = max(nextNew.date.timeIntervalSince(previousNew.date), 1)
        let age = min(max(date.timeIntervalSince(previousNew.date) / total, 0), 1)
        let phase = Self.phaseName(for: age)

        let previousEvent = try mostRecentEvent(atOrBefore: key)
        let nextEvent = try nextEvent(atOrAfter: key)
        let nearestEvent = abs(previousEvent.date.timeIntervalSince(date)) <= abs(nextEvent.date.timeIntervalSince(date))
            ? previousEvent
            : nextEvent

        return MoonPhaseReading(
            date: date,
            phase: phase,
            normalizedPhase: age,
            illuminatedFraction: Self.illumination(for: age),
            previousNewMoon: previousNew,
            nextNewMoon: nextNew,
            previousEvent: previousEvent,
            nextEvent: nextEvent,
            nearestEvent: nearestEvent
        )
    }

    private func bracket(kind: MoonPhaseKind, key: Int64) throws -> (previous: Int, next: Int) {
        let count = eventCount(kind: kind)
        let insertion = lowerBound(kind: kind, key: key)
        if insertion < count, try eventUnix(kind: kind, storageIndex: insertion) == key {
            guard insertion + 1 < count else {
                throw MoonPhaseServiceError.corruptBundledData("Exact event at end of \(kind.displayName) table")
            }
            return (insertion, insertion + 1)
        }

        guard insertion > 0, insertion < count else {
            throw MoonPhaseServiceError.corruptBundledData("Could not bracket \(key) in \(kind.displayName) table")
        }
        return (insertion - 1, insertion)
    }

    private func mostRecentEvent(atOrBefore key: Int64) throws -> MoonPhaseEvent {
        let candidates = try MoonPhaseKind.allSearchKinds.compactMap { kind -> MoonPhaseEvent? in
            let insertion = lowerBound(kind: kind, key: key)
            let index: Int
            if insertion < eventCount(kind: kind), try eventUnix(kind: kind, storageIndex: insertion) == key {
                index = insertion
            } else {
                index = insertion - 1
            }
            guard index >= 0 else { return nil }
            return try event(kind: kind, storageIndex: index)
        }

        guard let event = candidates.max(by: { $0.date < $1.date }) else {
            throw MoonPhaseServiceError.corruptBundledData("No previous moon phase event for \(key)")
        }
        return event
    }

    private func nextEvent(atOrAfter key: Int64) throws -> MoonPhaseEvent {
        let candidates = try MoonPhaseKind.allSearchKinds.compactMap { kind -> MoonPhaseEvent? in
            let insertion = lowerBound(kind: kind, key: key)
            guard insertion < eventCount(kind: kind) else { return nil }
            return try event(kind: kind, storageIndex: insertion)
        }

        guard let event = candidates.min(by: { $0.date < $1.date }) else {
            throw MoonPhaseServiceError.corruptBundledData("No next moon phase event for \(key)")
        }
        return event
    }

    private func lowerBound(kind: MoonPhaseKind, key: Int64) -> Int {
        var low = 0
        var high = eventCount(kind: kind)
        while low < high {
            let middle = (low + high) >> 1
            let unixTime = eventUnixUnchecked(kind: kind, storageIndex: middle)
            if unixTime < key {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private func event(kind: MoonPhaseKind, storageIndex: Int) throws -> MoonPhaseEvent {
        let unixTime = try eventUnix(kind: kind, storageIndex: storageIndex)
        return MoonPhaseEvent(
            kind: kind,
            date: Date(timeIntervalSince1970: TimeInterval(unixTime)),
            lunationIndex: lunationIndex(kind: kind, storageIndex: storageIndex)
        )
    }

    private func eventUnix(kind: MoonPhaseKind, storageIndex: Int) throws -> Int64 {
        guard (0..<eventCount(kind: kind)).contains(storageIndex) else {
            throw MoonPhaseServiceError.corruptBundledData("\(kind.displayName) event index \(storageIndex) is out of range")
        }
        return eventUnixUnchecked(kind: kind, storageIndex: storageIndex)
    }

    private func eventUnixUnchecked(kind: MoonPhaseKind, storageIndex: Int) -> Int64 {
        let lunationIndex = lunationIndex(kind: kind, storageIndex: storageIndex)
        let predicted = predictedSeconds(lunationIndex: lunationIndex, isFull: kind == .full)
        return predicted + Int64(correction(kind: kind, storageIndex: storageIndex))
    }

    private func predictedSeconds(lunationIndex: Int, isFull: Bool) -> Int64 {
        var predictedMicros = referenceUnix * 1_000_000 + Int64(lunationIndex) * synodicMonthMicros
        if isFull {
            predictedMicros += synodicMonthMicros / 2
        }
        return roundDiv(predictedMicros, by: 1_000_000)
    }

    private func correction(kind: MoonPhaseKind, storageIndex: Int) -> Int32 {
        let offset: Int
        switch kind {
        case .new:
            offset = headerSize + storageIndex * Self.correctionByteCount
        case .full:
            offset = fullCorrectionsOffset + storageIndex * Self.correctionByteCount
        }
        return readInt24LE(from: data, at: offset)
    }

    private func lunationIndex(kind: MoonPhaseKind, storageIndex: Int) -> Int {
        switch kind {
        case .new:
            firstNewIndex + storageIndex
        case .full:
            firstFullIndex + storageIndex
        }
    }

    private func eventCount(kind: MoonPhaseKind) -> Int {
        switch kind {
        case .new:
            newCount
        case .full:
            fullCount
        }
    }

    private static func phaseName(for phase: Double) -> MoonPhaseName {
        switch Int((phase * 8).rounded()) & 7 {
        case 0: .new
        case 1: .waxingCrescent
        case 2: .firstQuarter
        case 3: .waxingGibbous
        case 4: .full
        case 5: .waningGibbous
        case 6: .lastQuarter
        default: .waningCrescent
        }
    }

    private static func illumination(for phase: Double) -> Double {
        min(max((1 - cos(phase * 2 * .pi)) / 2, 0), 1)
    }

    private static func loadData(named name: String, extension fileExtension: String, bundle: Bundle) throws -> Data {
        let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "MoonData")
            ?? bundle.url(forResource: name, withExtension: fileExtension)

        guard let url else {
            throw MoonPhaseServiceError.missingBundledData("\(name).\(fileExtension)")
        }
        return try Data(contentsOf: url)
    }
}

private extension MoonPhaseKind {
    static let allSearchKinds: [MoonPhaseKind] = [.new, .full]
}

enum MoonPhaseOctalCalculator {
    static func reading(from phaseReading: MoonPhaseReading, date: Date, depth rawDepth: Int) throws -> MoonPhaseOctalReading {
        let depth = JournalSettings.clampedHarmonicDepth(rawDepth)
        let binCount = try octalBinCount(depth: depth)
        let scaled = phaseReading.normalizedPhase * Double(binCount)
        let binIndex = min(max(Int(floor(scaled)), 0), binCount - 1)
        let octalAddress = String(binIndex, radix: 8).leftPadded(toLength: depth, withPad: "0")

        return MoonPhaseOctalReading(
            date: date,
            phaseReading: phaseReading,
            depth: depth,
            binCount: binCount,
            binIndex: binIndex,
            octalAddress: octalAddress,
            rarity: rarity(forOctalAddress: octalAddress, depth: depth)
        )
    }

    static func rarity(forOctalAddress octalAddress: String, depth rawDepth: Int) -> FlipRarity {
        let depth = JournalSettings.clampedHarmonicDepth(rawDepth)
        let padded = octalAddress.leftPadded(toLength: depth, withPad: "0")

        if padded == String(repeating: "0", count: depth) || padded == String(repeating: "7", count: depth) {
            return .legendary
        }

        let leadingZeroes = padded.prefix { $0 == "0" }.count
        let leadingSevens = padded.prefix { $0 == "7" }.count
        let edgeRun = max(leadingZeroes, leadingSevens)

        switch edgeRun {
        case 2...:
            return .epic
        case 1:
            return .rare
        default:
            return .common
        }
    }

    private static func octalBinCount(depth: Int) throws -> Int {
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

private func roundDiv(_ numerator: Int64, by denominator: Int64) -> Int64 {
    if numerator >= 0 {
        return (numerator + denominator / 2) / denominator
    }
    return -((-numerator + denominator / 2) / denominator)
}

private func readInt64LE(from data: Data, at offset: Int) -> Int64 {
    var value: Int64 = 0
    for byteIndex in 0..<8 {
        value |= Int64(data[offset + byteIndex]) << Int64(byteIndex * 8)
    }
    return value
}

private func readInt32LE(from data: Data, at offset: Int) -> Int32 {
    var value: UInt32 = 0
    for byteIndex in 0..<4 {
        value |= UInt32(data[offset + byteIndex]) << UInt32(byteIndex * 8)
    }
    return Int32(bitPattern: value)
}

private func readUInt16LE(from data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func readInt24LE(from data: Data, at offset: Int) -> Int32 {
    var value = Int32(data[offset])
        | (Int32(data[offset + 1]) << 8)
        | (Int32(data[offset + 2]) << 16)
    if (value & 0x0080_0000) != 0 {
        value |= ~0x00FF_FFFF
    }
    return value
}

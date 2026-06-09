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

enum MoonCycleKind: UInt8, CaseIterable, Codable, Hashable, Sendable {
    case synodic
    case anomalistic
    case draconic

    var displayName: String {
        switch self {
        case .synodic: "Synodic"
        case .anomalistic: "Anomalistic"
        case .draconic: "Draconic"
        }
    }

    var eventName: String {
        switch self {
        case .synodic: "New moon"
        case .anomalistic: "Apogee"
        case .draconic: "Ascending node"
        }
    }
}

enum MoonOrbitalEventKind: UInt8, CaseIterable, Codable, Hashable, Sendable {
    case apogee
    case perigee
    case ascendingNode
    case descendingNode

    var displayName: String {
        switch self {
        case .apogee: "Apogee"
        case .perigee: "Perigee"
        case .ascendingNode: "Ascending node"
        case .descendingNode: "Descending node"
        }
    }
}

struct MoonPhaseEvent: Codable, Hashable, Sendable {
    let kind: MoonPhaseKind
    let date: Date
    let lunationIndex: Int
}

struct MoonOrbitalEvent: Codable, Hashable, Sendable {
    let kind: MoonOrbitalEventKind
    let date: Date
    let cycleIndex: Int
}

struct MoonCycleEvent: Codable, Hashable, Sendable {
    let kind: MoonCycleKind
    let date: Date
    let cycleIndex: Int
}

struct MoonCycleReading: Codable, Hashable, Sendable {
    let kind: MoonCycleKind
    let normalizedPhase: Double
    let previousEvent: MoonCycleEvent
    let nextEvent: MoonCycleEvent

    var duration: TimeInterval {
        max(nextEvent.date.timeIntervalSince(previousEvent.date), 1)
    }
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
    let synodicCycle: MoonCycleReading
    let anomalisticCycle: MoonCycleReading
    let draconicCycle: MoonCycleReading
}

struct MoonPhaseOctalReading: Codable, Hashable, Sendable {
    let date: Date
    let phaseReading: MoonPhaseReading
    let depth: Int
    let detailDepth: Int
    let binCount: Int
    let binIndex: Int
    let octalAddress: String
    let rarity: FlipRarity
    let components: [MoonCycleOctalComponent]

    var binDuration: TimeInterval {
        max(phaseReading.synodicCycle.duration / Double(binCount), 1)
    }

    func component(_ kind: MoonCycleKind) -> MoonCycleOctalComponent? {
        components.first { $0.kind == kind }
    }
}

struct MoonCycleOctalComponent: Codable, Hashable, Sendable, Identifiable {
    let kind: MoonCycleKind
    let digit: Int
    let detailBinCount: Int
    let detailBinIndex: Int
    let detailOctalAddress: String
    let cycleReading: MoonCycleReading

    var id: MoonCycleKind { kind }
}

struct MoonPhaseDatabaseSummary: Codable, Hashable, Sendable {
    let coverageStart: Date
    let coverageEnd: Date
    let referenceNewMoon: Date
    let synodicMonthSeconds: Double
    let newMoonCount: Int
    let fullMoonCount: Int
    let referenceApogee: Date
    let anomalisticMonthSeconds: Double
    let apogeeCount: Int
    let perigeeCount: Int
    let referenceAscendingNode: Date
    let draconicMonthSeconds: Double
    let ascendingNodeCount: Int
    let descendingNodeCount: Int
    let byteCount: Int
}

protocol MoonPhaseService {
    func reading(for date: Date) throws -> MoonPhaseReading
    func octalReading(for date: Date, depth: Int) throws -> MoonPhaseOctalReading
    func orbitalEvents(from startDate: Date, through endDate: Date) throws -> [MoonOrbitalEvent]
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

    func orbitalEvents(from startDate: Date, through endDate: Date) throws -> [MoonOrbitalEvent] {
        try store().orbitalEvents(from: startDate, through: endDate)
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
    private static let currentVersion: UInt16 = 3
    private static let correctionByteCount = 3

    private let data: Data
    private let headerSize: Int
    private let coverageStartUnix: Int64
    private let coverageEndUnix: Int64
    private let referenceUnix: Int64
    private let synodicMonthMicros: Int64
    private let referenceApogeeUnix: Int64
    private let anomalisticMonthMicros: Int64
    private let referencePerigeeUnix: Int64
    private let referenceAscendingNodeUnix: Int64
    private let draconicMonthMicros: Int64
    private let referenceDescendingNodeUnix: Int64
    private let firstNewIndex: Int
    private let newCount: Int
    private let firstFullIndex: Int
    private let fullCount: Int
    private let firstApogeeIndex: Int
    private let apogeeCount: Int
    private let firstAscendingNodeIndex: Int
    private let ascendingNodeCount: Int
    private let firstPerigeeIndex: Int
    private let perigeeCount: Int
    private let firstDescendingNodeIndex: Int
    private let descendingNodeCount: Int
    private let fullCorrectionsOffset: Int
    private let apogeeCorrectionsOffset: Int
    private let ascendingNodeCorrectionsOffset: Int
    private let perigeeCorrectionsOffset: Int
    private let descendingNodeCorrectionsOffset: Int

    init(bundle: Bundle) throws {
        data = try Self.loadData(named: "moon_phases", extension: "db", bundle: bundle)
        guard data.count >= 132 else {
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
        referenceApogeeUnix = readInt64LE(from: data, at: 56)
        anomalisticMonthMicros = readInt64LE(from: data, at: 64)
        firstApogeeIndex = Int(readInt32LE(from: data, at: 72))
        apogeeCount = Int(readUInt16LE(from: data, at: 76))
        referenceAscendingNodeUnix = readInt64LE(from: data, at: 78)
        draconicMonthMicros = readInt64LE(from: data, at: 86)
        firstAscendingNodeIndex = Int(readInt32LE(from: data, at: 94))
        ascendingNodeCount = Int(readUInt16LE(from: data, at: 98))
        referencePerigeeUnix = readInt64LE(from: data, at: 100)
        firstPerigeeIndex = Int(readInt32LE(from: data, at: 108))
        perigeeCount = Int(readUInt16LE(from: data, at: 112))
        referenceDescendingNodeUnix = readInt64LE(from: data, at: 114)
        firstDescendingNodeIndex = Int(readInt32LE(from: data, at: 122))
        descendingNodeCount = Int(readUInt16LE(from: data, at: 126))
        fullCorrectionsOffset = headerSize + newCount * Self.correctionByteCount
        apogeeCorrectionsOffset = fullCorrectionsOffset + fullCount * Self.correctionByteCount
        ascendingNodeCorrectionsOffset = apogeeCorrectionsOffset + apogeeCount * Self.correctionByteCount
        perigeeCorrectionsOffset = ascendingNodeCorrectionsOffset + ascendingNodeCount * Self.correctionByteCount
        descendingNodeCorrectionsOffset = perigeeCorrectionsOffset + perigeeCount * Self.correctionByteCount

        guard headerSize >= 132 else {
            throw MoonPhaseServiceError.corruptBundledData("Header size \(headerSize) is too small")
        }
        let expectedSize = headerSize + (newCount + fullCount + apogeeCount + ascendingNodeCount + perigeeCount + descendingNodeCount) * Self.correctionByteCount
        guard data.count == expectedSize else {
            throw MoonPhaseServiceError.corruptBundledData("Expected \(expectedSize) bytes, found \(data.count)")
        }
        guard newCount >= 2,
              fullCount >= 2,
              apogeeCount >= 2,
              perigeeCount >= 2,
              ascendingNodeCount >= 2,
              descendingNodeCount >= 2,
              coverageStartUnix < coverageEndUnix
        else {
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
            referenceApogee: Date(timeIntervalSince1970: TimeInterval(referenceApogeeUnix)),
            anomalisticMonthSeconds: Double(anomalisticMonthMicros) / 1_000_000,
            apogeeCount: apogeeCount,
            perigeeCount: perigeeCount,
            referenceAscendingNode: Date(timeIntervalSince1970: TimeInterval(referenceAscendingNodeUnix)),
            draconicMonthSeconds: Double(draconicMonthMicros) / 1_000_000,
            ascendingNodeCount: ascendingNodeCount,
            descendingNodeCount: descendingNodeCount,
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
        let synodicCycle = MoonCycleReading(
            kind: .synodic,
            normalizedPhase: age,
            previousEvent: MoonCycleEvent(kind: .synodic, date: previousNew.date, cycleIndex: previousNew.lunationIndex),
            nextEvent: MoonCycleEvent(kind: .synodic, date: nextNew.date, cycleIndex: nextNew.lunationIndex)
        )

        return MoonPhaseReading(
            date: date,
            phase: phase,
            normalizedPhase: age,
            illuminatedFraction: Self.illumination(for: age),
            previousNewMoon: previousNew,
            nextNewMoon: nextNew,
            previousEvent: previousEvent,
            nextEvent: nextEvent,
            nearestEvent: nearestEvent,
            synodicCycle: synodicCycle,
            anomalisticCycle: try cycleReading(kind: .anomalistic, date: date, key: key),
            draconicCycle: try cycleReading(kind: .draconic, date: date, key: key)
        )
    }

    func orbitalEvents(from startDate: Date, through endDate: Date) throws -> [MoonOrbitalEvent] {
        guard startDate <= endDate else { return [] }

        let startKey = Int64(startDate.timeIntervalSince1970.rounded())
        let endKey = Int64(endDate.timeIntervalSince1970.rounded())
        guard startKey >= coverageStartUnix, endKey < coverageEndUnix else {
            throw MoonPhaseServiceError.dateOutOfRange(startKey < coverageStartUnix ? startDate : endDate)
        }

        var events: [MoonOrbitalEvent] = []
        for kind in MoonOrbitalEventKind.allCases {
            var index = orbitalLowerBound(kind: kind, key: startKey)
            while index < orbitalEventCount(kind: kind) {
                let unixTime = orbitalEventUnixUnchecked(kind: kind, storageIndex: index)
                guard unixTime <= endKey else { break }
                events.append(MoonOrbitalEvent(
                    kind: kind,
                    date: Date(timeIntervalSince1970: TimeInterval(unixTime)),
                    cycleIndex: orbitalCycleIndex(kind: kind, storageIndex: index)
                ))
                index += 1
            }
        }

        return events.sorted { $0.date < $1.date }
    }

    private func cycleReading(kind: MoonCycleKind, date: Date, key: Int64) throws -> MoonCycleReading {
        let bracket = try cycleBracket(kind: kind, key: key)
        let previous = try cycleEvent(kind: kind, storageIndex: bracket.previous)
        let next = try cycleEvent(kind: kind, storageIndex: bracket.next)
        let total = max(next.date.timeIntervalSince(previous.date), 1)
        let phase = min(max(date.timeIntervalSince(previous.date) / total, 0), 1)
        return MoonCycleReading(
            kind: kind,
            normalizedPhase: phase,
            previousEvent: previous,
            nextEvent: next
        )
    }

    private func cycleBracket(kind: MoonCycleKind, key: Int64) throws -> (previous: Int, next: Int) {
        let count = cycleEventCount(kind: kind)
        let insertion = cycleLowerBound(kind: kind, key: key)
        if insertion < count, try cycleEventUnix(kind: kind, storageIndex: insertion) == key {
            guard insertion + 1 < count else {
                throw MoonPhaseServiceError.corruptBundledData("Exact event at end of \(kind.eventName) table")
            }
            return (insertion, insertion + 1)
        }

        guard insertion > 0, insertion < count else {
            throw MoonPhaseServiceError.corruptBundledData("Could not bracket \(key) in \(kind.eventName) table")
        }
        return (insertion - 1, insertion)
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

    private func cycleLowerBound(kind: MoonCycleKind, key: Int64) -> Int {
        if kind == .synodic {
            return lowerBound(kind: .new, key: key)
        }

        var low = 0
        var high = cycleEventCount(kind: kind)
        while low < high {
            let middle = (low + high) >> 1
            let unixTime = cycleEventUnixUnchecked(kind: kind, storageIndex: middle)
            if unixTime < key {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private func orbitalLowerBound(kind: MoonOrbitalEventKind, key: Int64) -> Int {
        var low = 0
        var high = orbitalEventCount(kind: kind)
        while low < high {
            let middle = (low + high) >> 1
            let unixTime = orbitalEventUnixUnchecked(kind: kind, storageIndex: middle)
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

    private func cycleEvent(kind: MoonCycleKind, storageIndex: Int) throws -> MoonCycleEvent {
        if kind == .synodic {
            let event = try event(kind: .new, storageIndex: storageIndex)
            return MoonCycleEvent(kind: .synodic, date: event.date, cycleIndex: event.lunationIndex)
        }

        let unixTime = try cycleEventUnix(kind: kind, storageIndex: storageIndex)
        return MoonCycleEvent(
            kind: kind,
            date: Date(timeIntervalSince1970: TimeInterval(unixTime)),
            cycleIndex: cycleIndex(kind: kind, storageIndex: storageIndex)
        )
    }

    private func cycleEventUnix(kind: MoonCycleKind, storageIndex: Int) throws -> Int64 {
        if kind == .synodic {
            return try eventUnix(kind: .new, storageIndex: storageIndex)
        }

        guard (0..<cycleEventCount(kind: kind)).contains(storageIndex) else {
            throw MoonPhaseServiceError.corruptBundledData("\(kind.eventName) event index \(storageIndex) is out of range")
        }
        return cycleEventUnixUnchecked(kind: kind, storageIndex: storageIndex)
    }

    private func cycleEventUnixUnchecked(kind: MoonCycleKind, storageIndex: Int) -> Int64 {
        if kind == .synodic {
            return eventUnixUnchecked(kind: .new, storageIndex: storageIndex)
        }

        let cycleIndex = cycleIndex(kind: kind, storageIndex: storageIndex)
        let predicted = predictedCycleSeconds(kind: kind, cycleIndex: cycleIndex)
        return predicted + Int64(cycleCorrection(kind: kind, storageIndex: storageIndex))
    }

    private func orbitalEventUnixUnchecked(kind: MoonOrbitalEventKind, storageIndex: Int) -> Int64 {
        let cycleIndex = orbitalCycleIndex(kind: kind, storageIndex: storageIndex)
        let predicted = predictedOrbitalSeconds(kind: kind, cycleIndex: cycleIndex)
        return predicted + Int64(orbitalCorrection(kind: kind, storageIndex: storageIndex))
    }

    private func predictedSeconds(lunationIndex: Int, isFull: Bool) -> Int64 {
        var predictedMicros = referenceUnix * 1_000_000 + Int64(lunationIndex) * synodicMonthMicros
        if isFull {
            predictedMicros += synodicMonthMicros / 2
        }
        return roundDiv(predictedMicros, by: 1_000_000)
    }

    private func predictedCycleSeconds(kind: MoonCycleKind, cycleIndex: Int) -> Int64 {
        let reference: Int64
        let periodMicros: Int64
        switch kind {
        case .synodic:
            reference = referenceUnix
            periodMicros = synodicMonthMicros
        case .anomalistic:
            reference = referenceApogeeUnix
            periodMicros = anomalisticMonthMicros
        case .draconic:
            reference = referenceAscendingNodeUnix
            periodMicros = draconicMonthMicros
        }

        let predictedMicros = reference * 1_000_000 + Int64(cycleIndex) * periodMicros
        return roundDiv(predictedMicros, by: 1_000_000)
    }

    private func predictedOrbitalSeconds(kind: MoonOrbitalEventKind, cycleIndex: Int) -> Int64 {
        let reference: Int64
        let periodMicros: Int64
        let offsetMicros: Int64
        switch kind {
        case .apogee:
            reference = referenceApogeeUnix
            periodMicros = anomalisticMonthMicros
            offsetMicros = 0
        case .perigee:
            reference = referencePerigeeUnix
            periodMicros = anomalisticMonthMicros
            offsetMicros = 0
        case .ascendingNode:
            reference = referenceAscendingNodeUnix
            periodMicros = draconicMonthMicros
            offsetMicros = 0
        case .descendingNode:
            reference = referenceDescendingNodeUnix
            periodMicros = draconicMonthMicros
            offsetMicros = 0
        }

        let predictedMicros = reference * 1_000_000 + Int64(cycleIndex) * periodMicros + offsetMicros
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

    private func cycleCorrection(kind: MoonCycleKind, storageIndex: Int) -> Int32 {
        let offset: Int
        switch kind {
        case .synodic:
            offset = headerSize + storageIndex * Self.correctionByteCount
        case .anomalistic:
            offset = apogeeCorrectionsOffset + storageIndex * Self.correctionByteCount
        case .draconic:
            offset = ascendingNodeCorrectionsOffset + storageIndex * Self.correctionByteCount
        }
        return readInt24LE(from: data, at: offset)
    }

    private func orbitalCorrection(kind: MoonOrbitalEventKind, storageIndex: Int) -> Int32 {
        let offset: Int
        switch kind {
        case .apogee:
            offset = apogeeCorrectionsOffset + storageIndex * Self.correctionByteCount
        case .perigee:
            offset = perigeeCorrectionsOffset + storageIndex * Self.correctionByteCount
        case .ascendingNode:
            offset = ascendingNodeCorrectionsOffset + storageIndex * Self.correctionByteCount
        case .descendingNode:
            offset = descendingNodeCorrectionsOffset + storageIndex * Self.correctionByteCount
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

    private func cycleIndex(kind: MoonCycleKind, storageIndex: Int) -> Int {
        switch kind {
        case .synodic:
            firstNewIndex + storageIndex
        case .anomalistic:
            firstApogeeIndex + storageIndex
        case .draconic:
            firstAscendingNodeIndex + storageIndex
        }
    }

    private func orbitalCycleIndex(kind: MoonOrbitalEventKind, storageIndex: Int) -> Int {
        switch kind {
        case .apogee:
            firstApogeeIndex + storageIndex
        case .perigee:
            firstPerigeeIndex + storageIndex
        case .ascendingNode:
            firstAscendingNodeIndex + storageIndex
        case .descendingNode:
            firstDescendingNodeIndex + storageIndex
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

    private func cycleEventCount(kind: MoonCycleKind) -> Int {
        switch kind {
        case .synodic:
            newCount
        case .anomalistic:
            apogeeCount
        case .draconic:
            ascendingNodeCount
        }
    }

    private func orbitalEventCount(kind: MoonOrbitalEventKind) -> Int {
        switch kind {
        case .apogee:
            apogeeCount
        case .perigee:
            perigeeCount
        case .ascendingNode:
            ascendingNodeCount
        case .descendingNode:
            descendingNodeCount
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
    private static let rarityDepth = 3

    static func reading(from phaseReading: MoonPhaseReading, date: Date, depth rawDepth: Int) throws -> MoonPhaseOctalReading {
        let detailDepth = JournalSettings.clampedHarmonicDepth(rawDepth)
        let detailBinCount = try octalBinCount(depth: detailDepth)
        let components: [MoonCycleOctalComponent] = MoonCycleKind.allCases.map { kind in
            let cycleReading = cycleReading(for: kind, phaseReading: phaseReading)
            let digit = phaseDigit(for: cycleReading.normalizedPhase)
            let detailBinIndex = phaseBinIndex(for: cycleReading.normalizedPhase, binCount: detailBinCount)
            return MoonCycleOctalComponent(
                kind: kind,
                digit: digit,
                detailBinCount: detailBinCount,
                detailBinIndex: detailBinIndex,
                detailOctalAddress: String(detailBinIndex, radix: 8).leftPadded(toLength: detailDepth, withPad: "0"),
                cycleReading: cycleReading
            )
        }
        let octalAddress = components.map { String($0.digit) }.joined()
        let binIndex = Int(octalAddress, radix: 8) ?? 0
        let synodicRarityBinCount = try octalBinCount(depth: Self.rarityDepth)
        let synodicRarityBinIndex = phaseBinIndex(
            for: phaseReading.synodicCycle.normalizedPhase,
            binCount: synodicRarityBinCount
        )
        let synodicRarityAddress = String(synodicRarityBinIndex, radix: 8)
            .leftPadded(toLength: Self.rarityDepth, withPad: "0")

        return MoonPhaseOctalReading(
            date: date,
            phaseReading: phaseReading,
            depth: 3,
            detailDepth: detailDepth,
            binCount: 512,
            binIndex: binIndex,
            octalAddress: octalAddress,
            rarity: rarity(forOctalAddress: synodicRarityAddress, depth: Self.rarityDepth),
            components: components
        )
    }

    private static func cycleReading(for kind: MoonCycleKind, phaseReading: MoonPhaseReading) -> MoonCycleReading {
        switch kind {
        case .synodic:
            phaseReading.synodicCycle
        case .anomalistic:
            phaseReading.anomalisticCycle
        case .draconic:
            phaseReading.draconicCycle
        }
    }

    private static func phaseDigit(for normalizedPhase: Double) -> Int {
        phaseBinIndex(for: normalizedPhase, binCount: 8)
    }

    private static func phaseBinIndex(for normalizedPhase: Double, binCount: Int) -> Int {
        let scaled = min(max(normalizedPhase, 0), 1) * Double(binCount)
        return min(max(Int(floor(scaled)), 0), binCount - 1)
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

import Foundation

final class BundledSolarEclipseService: EclipseService {
    private let storeResult: Result<SolarEclipseStore, Error>

    init(bundle: Bundle = .main) {
        storeResult = Result { try SolarEclipseStore(bundle: bundle) }
    }

    func allSarosSeries() throws -> [SarosSeriesSummary] {
        try store().allSarosSeries()
    }

    func allEclipses() throws -> [Eclipse] {
        try store().allEclipses()
    }

    func eclipses(forSaros saros: Int) throws -> [Eclipse] {
        try store().eclipses(forSaros: saros)
    }

    func eclipse(withID eclipseID: String) throws -> Eclipse? {
        try store().eclipse(withID: eclipseID)
    }

    func previousAndNextEclipse(saros: Int, around date: Date) throws -> SarosInterval? {
        let eclipses = try eclipses(forSaros: saros).sorted { $0.date < $1.date }
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
        let phase = min(max(date.timeIntervalSince(previous.date) / total, 0.0), 1.0 - Double.ulpOfOne)

        return SarosInterval(saros: saros, previous: previous, next: next, normalizedPhase: phase)
    }

    func eclipseBracket(around date: Date) throws -> EclipseBracket? {
        try store().eclipseBracket(around: date)
    }

    func nearestEclipse(to date: Date) throws -> Eclipse? {
        try store().nearestEclipse(to: date)
    }

    func pathGeometry(for eclipseID: String) throws -> EclipsePathGeometry? {
        try store().pathGeometry(for: eclipseID)
    }

    private func store() throws -> SolarEclipseStore {
        try storeResult.get()
    }
}

private struct SolarEclipseStore {
    private let times: Data
    private let info: Data
    private let sarosIndex: Data
    private let geometryStore: SolarEclipseGeometryStore?
    private let count: Int

    init(bundle: Bundle) throws {
        times = try Self.loadData(named: "eclipse_times", extension: "db", bundle: bundle)
        info = try Self.loadData(named: "eclipse_info", extension: "db", bundle: bundle)
        sarosIndex = try Self.loadData(named: "saros", extension: "db", bundle: bundle)
        geometryStore = SolarEclipseGeometryStore(bundle: bundle)

        guard times.count % 8 == 0 else {
            throw EclipseServiceError.corruptBundledData("eclipse_times.db length is not divisible by 8")
        }
        count = times.count / 8

        guard info.count >= count * 10 else {
            throw EclipseServiceError.corruptBundledData("eclipse_info.db is shorter than expected")
        }
        guard sarosIndex.count >= 180 * 194 else {
            throw EclipseServiceError.corruptBundledData("saros.db is shorter than expected")
        }
    }

    func allSarosSeries() throws -> [SarosSeriesSummary] {
        try (1...180).compactMap { saros in
            let eclipses = try eclipses(forSaros: saros)
            guard let first = eclipses.first, let last = eclipses.last else { return nil }
            return SarosSeriesSummary(
                saros: saros,
                eclipseCount: eclipses.count,
                firstEclipseDate: first.date,
                lastEclipseDate: last.date
            )
        }
    }

    func allEclipses() throws -> [Eclipse] {
        try (0..<count).map { try makeEclipse(at: $0, includeGeometryMetadata: false) }
    }

    func eclipses(forSaros saros: Int) throws -> [Eclipse] {
        let indices = try indices(forSaros: saros)
        guard !indices.isEmpty else { return [] }
        return try indices.map { try makeEclipse(at: $0, includeGeometryMetadata: false) }.sorted { $0.date < $1.date }
    }

    func eclipse(withID eclipseID: String) throws -> Eclipse? {
        guard let index = index(from: eclipseID), (0..<count).contains(index) else {
            return nil
        }
        return try makeEclipse(at: index, includeGeometryMetadata: true)
    }

    func nearestEclipse(to date: Date) throws -> Eclipse? {
        guard count > 0 else { return nil }
        let key = Int64(date.timeIntervalSince1970.rounded(.towardZero))
        let insertion = lowerBound(key)

        let candidates = [insertion - 1, insertion].filter { (0..<count).contains($0) }
        let nearestIndex = candidates.min { lhs, rhs in
            abs(readTime(at: lhs) - key) < abs(readTime(at: rhs) - key)
        }

        guard let nearestIndex else { return nil }
        return try makeEclipse(at: nearestIndex, includeGeometryMetadata: false)
    }

    func eclipseBracket(around date: Date) throws -> EclipseBracket? {
        guard count >= 2 else { return nil }
        let key = Int64(date.timeIntervalSince1970.rounded(.towardZero))
        let insertion = lowerBound(key)

        let previousIndex: Int
        let nextIndex: Int
        if insertion <= 0 {
            previousIndex = 0
            nextIndex = 1
        } else if insertion >= count {
            previousIndex = count - 2
            nextIndex = count - 1
        } else {
            previousIndex = insertion - 1
            nextIndex = insertion
        }

        let previous = try makeEclipse(at: previousIndex, includeGeometryMetadata: false)
        let next = try makeEclipse(at: nextIndex, includeGeometryMetadata: false)
        let total = max(next.date.timeIntervalSince(previous.date), 1)
        let phase = min(max(date.timeIntervalSince(previous.date) / total, 0), 1)
        return EclipseBracket(previous: previous, next: next, normalizedPhase: phase)
    }

    func pathGeometry(for eclipseID: String) throws -> EclipsePathGeometry? {
        guard
            let index = index(from: eclipseID),
            (0..<count).contains(index),
            let geometryStore
        else {
            return nil
        }

        let offset = index * 10
        let saros = Int(info[offset + 6])
        let unixTime = readTime(at: index)
        guard let record = geometryStore.record(saros: saros, unixTime: unixTime) else {
            return nil
        }

        return EclipsePathGeometry(centerline: [], polygons: record.polygons)
    }

    private func lowerBound(_ key: Int64) -> Int {
        var low = 0
        var high = count

        while low < high {
            let middle = (low + high) >> 1
            if readTime(at: middle) < key {
                low = middle + 1
            } else {
                high = middle
            }
        }

        return low
    }

    private func indices(forSaros saros: Int) throws -> [Int] {
        guard (1...180).contains(saros) else {
            throw EclipseServiceError.sarosNotFound(saros)
        }

        let offset = (saros - 1) * 194
        let seriesCount = Int(sarosIndex[offset])
        guard seriesCount <= 96 else {
            throw EclipseServiceError.corruptBundledData("Saros \(saros) has an impossible count")
        }

        return (0..<seriesCount).map { position in
            Int(readUInt16LE(from: sarosIndex, at: offset + 2 + position * 2))
        }
    }

    private func makeEclipse(at index: Int, includeGeometryMetadata: Bool) throws -> Eclipse {
        guard (0..<count).contains(index) else {
            throw EclipseServiceError.corruptBundledData("Eclipse index \(index) is out of range")
        }

        let offset = index * 10
        let latitude = Double(readInt16LE(from: info, at: offset)) / 10.0
        let longitude = Double(readInt16LE(from: info, at: offset + 2)) / 10.0
        let duration = readUInt16LE(from: info, at: offset + 4)
        let saros = Int(info[offset + 6])
        let sarosPosition = Int(info[offset + 7])
        let typeCode = info[offset + 8]
        let sunAltitude = info[offset + 9]
        let unixTime = readTime(at: index)
        let eclipseType = solarType(from: typeCode)
        let geometryRecord = includeGeometryMetadata
            ? geometryStore?.record(saros: saros, unixTime: unixTime)
            : nil
        let durationSeconds = geometryRecord?.centralDuration.map(Double.init)
            ?? (duration == UInt16.max ? nil : Double(duration))
        let typeLabel = solarTypeLabel(typeCode)
        let seriesCount = seriesCount(forSaros: saros)

        return Eclipse(
            id: "solar-\(index)",
            saros: saros,
            date: Date(timeIntervalSince1970: TimeInterval(unixTime)),
            type: eclipseType,
            maximumPoint: Coordinate(
                latitude: geometryRecord?.latitude ?? latitude,
                longitude: geometryRecord?.longitude ?? longitude
            ),
            gamma: geometryRecord?.gamma,
            magnitude: geometryRecord?.magnitude,
            durationSeconds: durationSeconds,
            pathWidthKm: geometryRecord?.centralWidthKm.map(Double.init),
            visibilitySummary: "\(typeLabel) · Maximum Sun altitude \(geometryRecord?.sunAltitude ?? Int(sunAltitude)) degrees.",
            typeLabel: typeLabel,
            sarosSequence: sarosPosition + 1,
            sarosSeriesCount: seriesCount,
            globalIndex: index,
            sunAltitude: geometryRecord?.sunAltitude ?? Int(sunAltitude)
        )
    }

    private func index(from eclipseID: String) -> Int? {
        guard eclipseID.hasPrefix("solar-") else { return nil }
        return Int(eclipseID.dropFirst("solar-".count))
    }

    private func seriesCount(forSaros saros: Int) -> Int? {
        guard (1...180).contains(saros) else { return nil }
        return Int(sarosIndex[(saros - 1) * 194])
    }

    private func readTime(at index: Int) -> Int64 {
        readInt64LE(from: times, at: index * 8)
    }

    private static func loadData(named name: String, extension fileExtension: String, bundle: Bundle) throws -> Data {
        let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "SolarData")
            ?? bundle.url(forResource: name, withExtension: fileExtension)

        guard let url else {
            throw EclipseServiceError.missingBundledData("\(name).\(fileExtension)")
        }

        return try Data(contentsOf: url)
    }
}

private final class SolarEclipseGeometryStore: @unchecked Sendable {
    private let directoryURL: URL
    private var cache: [Int: [Int64: SolarEclipseGeometryRecord]] = [:]
    private let cacheLock = NSLock()

    init?(bundle: Bundle) {
        let url = bundle.url(forResource: "SolarGeoData", withExtension: nil)
            ?? bundle.resourceURL?.appendingPathComponent("SolarGeoData", isDirectory: true)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        directoryURL = url
    }

    func record(saros: Int, unixTime: Int64) -> SolarEclipseGeometryRecord? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let series = cache[saros] {
            return series[unixTime]
        }

        let series = loadSeries(saros: saros)
        cache[saros] = series
        return series[unixTime]
    }

    private func loadSeries(saros: Int) -> [Int64: SolarEclipseGeometryRecord] {
        let url = directoryURL.appendingPathComponent("\(saros).bin")
        guard
            let data = try? Data(contentsOf: url),
            data.count >= 8
        else {
            return [:]
        }

        let recordCount = Int(data[0])
        let headerSize = 4 + 4 * (recordCount + 1)
        guard data.count >= headerSize else { return [:] }

        var records: [Int64: SolarEclipseGeometryRecord] = [:]
        for index in 0..<recordCount {
            let bitOffset = Int(readUInt32LE(from: data, at: 4 + index * 4))
            var reader = SolarEclipseBitReader(data: data, bitOffset: headerSize * 8 + bitOffset)
            guard let record = try? Self.decodeRecord(reader: &reader) else {
                continue
            }
            records[record.unixTime] = record
        }
        return records
    }

    private static func decodeRecord(reader: inout SolarEclipseBitReader) throws -> SolarEclipseGeometryRecord {
        _ = try reader.readUnsigned(bits: 5)
        let unixTime = try reader.readSigned(bits: 35)
        let latitude = try decodeCoordinate(reader: &reader)
        let longitude = try decodeCoordinate(reader: &reader)
        let sunAltitude = Int(try reader.readUnsigned(bits: 7))
        let magnitude = Double(try reader.readUnsigned(bits: 14)) / 10_000
        let gammaSign = try reader.readUnsigned(bits: 1)
        let gammaMagnitude = try reader.readUnsigned(bits: 14)
        let gamma = Double(gammaMagnitude) / 10_000 * (gammaSign == 1 ? -1 : 1)

        let hasDuration = try reader.readUnsigned(bits: 1) == 1
        let centralDuration = hasDuration ? Int(try reader.readUnsigned(bits: 10)) : nil
        let hasWidth = try reader.readUnsigned(bits: 1) == 1
        let centralWidthKm = hasWidth ? Int(try reader.readUnsigned(bits: 11)) : nil

        let polygonCount = Int(try reader.readUnsigned(bits: 5))
        let polygons = try (0..<polygonCount).map { _ in
            let pointCount = Int(try reader.readUnsigned(bits: 13))
            return try (0..<pointCount).map { _ in
                let longitude = try decodeCoordinate(reader: &reader)
                let latitude = try decodeCoordinate(reader: &reader)
                return Coordinate(latitude: latitude, longitude: longitude)
            }
        }

        return SolarEclipseGeometryRecord(
            unixTime: unixTime,
            latitude: latitude,
            longitude: longitude,
            sunAltitude: sunAltitude,
            magnitude: magnitude,
            gamma: gamma,
            centralDuration: centralDuration,
            centralWidthKm: centralWidthKm,
            polygons: polygons
        )
    }

    private static func decodeCoordinate(reader: inout SolarEclipseBitReader) throws -> Double {
        let sign = try reader.readUnsigned(bits: 1)
        let magnitude = try reader.readUnsigned(bits: 28)
        let value = Double(magnitude) / 1_000_000
        return sign == 1 ? -value : value
    }
}

private struct SolarEclipseGeometryRecord {
    let unixTime: Int64
    let latitude: Double
    let longitude: Double
    let sunAltitude: Int
    let magnitude: Double
    let gamma: Double
    let centralDuration: Int?
    let centralWidthKm: Int?
    let polygons: [[Coordinate]]
}

private struct SolarEclipseBitReader {
    enum Error: Swift.Error {
        case readPastEnd
        case unsupportedWidth
    }

    let data: Data
    var bitOffset: Int

    mutating func readUnsigned(bits: Int) throws -> Int64 {
        guard bits <= 53 else { throw Error.unsupportedWidth }

        var value: Int64 = 0
        var remaining = bits
        while remaining > 0 {
            let byteIndex = bitOffset >> 3
            guard byteIndex < data.count else { throw Error.readPastEnd }

            let bitInByte = bitOffset & 7
            let available = 8 - bitInByte
            let take = min(available, remaining)
            let shift = available - take
            let mask = (1 << take) - 1
            let chunk = (Int(data[byteIndex]) >> shift) & mask
            value = value * Int64(1 << take) + Int64(chunk)
            bitOffset += take
            remaining -= take
        }

        return value
    }

    mutating func readSigned(bits: Int) throws -> Int64 {
        let unsigned = try readUnsigned(bits: bits)
        let top = Int64(1) << (bits - 1)
        return unsigned >= top ? unsigned - (Int64(1) << bits) : unsigned
    }
}

private func solarType(from code: UInt8) -> EclipseType {
    switch code {
    case 0...5:
        .annularSolar
    case 6...9:
        .hybridSolar
    case 10...12:
        .partialSolar
    case 13...18:
        .totalSolar
    default:
        .unknown
    }
}

private func solarTypeLabel(_ code: UInt8) -> String {
    switch code {
    case 0: "A"
    case 1: "A+"
    case 2: "A-"
    case 3: "Am"
    case 4: "An"
    case 5: "As"
    case 6: "H"
    case 7: "H2"
    case 8: "H3"
    case 9: "Hm"
    case 10: "P"
    case 11: "Pb"
    case 12: "Pe"
    case 13: "T"
    case 14: "T+"
    case 15: "T-"
    case 16: "Tm"
    case 17: "Tn"
    case 18: "Ts"
    default: "?"
    }
}

private func readInt64LE(from data: Data, at offset: Int) -> Int64 {
    Int64(bitPattern: readUInt64LE(from: data, at: offset))
}

private func readUInt64LE(from data: Data, at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for byteIndex in 0..<8 {
        value |= UInt64(data[offset + byteIndex]) << UInt64(byteIndex * 8)
    }
    return value
}

private func readUInt32LE(from data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

private func readInt16LE(from data: Data, at offset: Int) -> Int16 {
    Int16(bitPattern: readUInt16LE(from: data, at: offset))
}

private func readUInt16LE(from data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

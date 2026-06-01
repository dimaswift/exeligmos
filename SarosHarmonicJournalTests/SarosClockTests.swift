import XCTest
@testable import SarosHarmonicJournal

final class SarosClockTests: XCTestCase {
    func testCatalogCenturyBoundsDefaultWindow() throws {
        let bounds = CatalogCenturyBounds(
            startCentury: JournalSettings.defaultCatalogStartCentury,
            endCentury: JournalSettings.defaultCatalogEndCentury
        )

        XCTAssertTrue(bounds.contains(Self.date(year: 1901, month: 1, day: 1)))
        XCTAssertTrue(bounds.contains(Self.date(year: 2000, month: 12, day: 31)))
        XCTAssertTrue(bounds.contains(Self.date(year: 2100, month: 12, day: 31)))
        XCTAssertFalse(bounds.contains(Self.date(year: 1900, month: 12, day: 31)))
        XCTAssertFalse(bounds.contains(Self.date(year: 2101, month: 1, day: 1)))
    }

    func testBundledServiceLoadsSolarGeoMetadata() throws {
        let service = BundledSolarEclipseService()
        let eclipse = try XCTUnwrap(service.eclipse(withID: "solar-10073"))
        let geometry = try XCTUnwrap(service.pathGeometry(for: "solar-10073"))

        XCTAssertEqual(eclipse.saros, 139)
        XCTAssertEqual(eclipse.sarosSequence, 30)
        XCTAssertEqual(eclipse.displayTypeLabel, "T")
        XCTAssertNotNil(eclipse.gamma)
        XCTAssertNotNil(eclipse.magnitude)
        XCTAssertFalse(geometry.polygons.isEmpty)
    }

    func testPhaseAtPreviousEclipseStartsAtZero() throws {
        let reading = try SarosClockCalculator.reading(
            saros: 141,
            previous: Fixtures.previous,
            next: Fixtures.next,
            now: Fixtures.previous.date,
            harmonicDepth: 2
        )

        XCTAssertEqual(reading.phase, 0.0, accuracy: 0.000001)
        XCTAssertEqual(reading.binCount, 64)
        XCTAssertEqual(reading.binIndex, 0)
        XCTAssertEqual(reading.octalAddress, "00")
    }

    private static func date(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? .distantPast
    }

    func testHalfPhaseMapsToMiddleOctalBin() throws {
        let now = Fixtures.previous.date.addingTimeInterval(Fixtures.interval / 2)
        let reading = try SarosClockCalculator.reading(
            saros: 141,
            previous: Fixtures.previous,
            next: Fixtures.next,
            now: now,
            harmonicDepth: 1
        )

        XCTAssertEqual(reading.phase, 0.5, accuracy: 0.000001)
        XCTAssertEqual(reading.binIndex, 4)
        XCTAssertEqual(reading.octalAddress, "4")
        XCTAssertEqual(reading.progressWithinBin, 0.0, accuracy: 0.000001)
    }

    func testJustBeforeAndExactlyAtBinFlip() throws {
        let justBefore = Fixtures.previous.date.addingTimeInterval(Fixtures.interval * 0.125 - 0.01)
        let atFlip = Fixtures.previous.date.addingTimeInterval(Fixtures.interval * 0.125)

        let beforeReading = try SarosClockCalculator.reading(
            saros: 141,
            previous: Fixtures.previous,
            next: Fixtures.next,
            now: justBefore,
            harmonicDepth: 1
        )
        let flipReading = try SarosClockCalculator.reading(
            saros: 141,
            previous: Fixtures.previous,
            next: Fixtures.next,
            now: atFlip,
            harmonicDepth: 1
        )

        XCTAssertEqual(beforeReading.binIndex, 0)
        XCTAssertEqual(flipReading.binIndex, 1)
        XCTAssertEqual(flipReading.octalAddress, "1")
    }

    func testDateAtNextEclipseClampsInsideLastBin() throws {
        let reading = try SarosClockCalculator.reading(
            saros: 141,
            previous: Fixtures.previous,
            next: Fixtures.next,
            now: Fixtures.next.date,
            harmonicDepth: 3
        )

        XCTAssertLessThan(reading.phase, 1.0)
        XCTAssertEqual(reading.binIndex, 511)
        XCTAssertEqual(reading.octalAddress, "777")
    }

    func testNextFlipDate() throws {
        let now = Fixtures.previous.date.addingTimeInterval(Fixtures.interval * 0.2)
        let reading = try SarosClockCalculator.reading(
            saros: 141,
            previous: Fixtures.previous,
            next: Fixtures.next,
            now: now,
            harmonicDepth: 1
        )

        let expected = Fixtures.previous.date.addingTimeInterval(Fixtures.interval * 0.25)
        XCTAssertEqual(reading.nextFlipDate.timeIntervalSinceReferenceDate, expected.timeIntervalSinceReferenceDate, accuracy: 0.01)
    }

    func testInvalidDepthThrows() {
        XCTAssertThrowsError(
            try SarosClockCalculator.reading(
                saros: 141,
                previous: Fixtures.previous,
                next: Fixtures.next,
                now: Fixtures.previous.date,
                harmonicDepth: 9
            )
        )
    }
}

final class ResonanceDetectorTests: XCTestCase {
    func testGroupsFlipsWithinWindow() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let events = ResonanceDetector.detectResonances(
            flips: [
                EntityFlip(entityID: first, entityTitle: "A", date: base, saros: 141, octalAddress: "001"),
                EntityFlip(entityID: second, entityTitle: "B", date: base.addingTimeInterval(45 * 60), saros: 145, octalAddress: "002"),
                EntityFlip(entityID: third, entityTitle: "C", date: base.addingTimeInterval(3 * 60 * 60), saros: 136, octalAddress: "003")
            ],
            window: 60 * 60
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(Set(events[0].entityIDs), Set([first, second]))
        XCTAssertEqual(events[0].sarosValues, [141, 145])
    }

    func testIgnoresFlipsOutsideWindow() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)

        let events = ResonanceDetector.detectResonances(
            flips: [
                EntityFlip(entityID: UUID(), entityTitle: "A", date: base, saros: 141, octalAddress: "001"),
                EntityFlip(entityID: UUID(), entityTitle: "B", date: base.addingTimeInterval(2 * 60 * 60), saros: 145, octalAddress: "002")
            ],
            window: 60 * 60
        )

        XCTAssertTrue(events.isEmpty)
    }
}

final class FlipNotificationTierTests: XCTestCase {
    func testTierMatchesCarryDepthExamples() {
        XCTAssertEqual(
            FlipNotificationPreferences.tier(forOctalAddress: "7210222", harmonicDepth: 7),
            6
        )
        XCTAssertEqual(
            FlipNotificationPreferences.tier(forOctalAddress: "7210230", harmonicDepth: 7),
            5
        )
        XCTAssertEqual(
            FlipNotificationPreferences.tier(forOctalAddress: "7000000", harmonicDepth: 7),
            1
        )
    }
}

final class EntityAndExportTests: XCTestCase {
    func testEntityCreationUsesNearestEclipseWhenSarosNotProvided() throws {
        let service = FixtureEclipseService()
        let entity = try EntityFactory.makeTrackedEntity(
            title: "Anchor",
            anchorDate: Fixtures.previous.date.addingTimeInterval(5),
            emoji: "●",
            eclipseService: service
        )

        XCTAssertEqual(entity.saros, 141)
        XCTAssertEqual(entity.nearestEclipseID, Fixtures.previous.id)
        XCTAssertEqual(entity.harmonicDepth, JournalSettings.defaultHarmonicDepth)
    }

    func testJSONExportArchiveShape() {
        let entity = TrackedEntity(title: "Anchor", anchorDate: Fixtures.previous.date, saros: 141, harmonicDepth: 3)
        let record = JournalRecord(
            entityID: entity.id,
            text: "A note",
            emoji: "●",
            saros: 141,
            harmonicDepth: 3,
            octalAddress: "123",
            binIndex: 83,
            phase: 0.2,
            triggerType: .manual
        )

        let archive = ExportService().makeArchive(entities: [entity], records: [record])

        XCTAssertEqual(archive.entities.count, 1)
        XCTAssertEqual(archive.records.count, 1)
        XCTAssertEqual(archive.entities[0].saros, 141)
        XCTAssertEqual(archive.records[0].octalAddress, "123")
        XCTAssertEqual(archive.records[0].text, "A note")
    }
}

private enum Fixtures {
    static let previousDate = Date(timeIntervalSince1970: 1_700_000_000)
    static let interval: TimeInterval = 8_000

    static let previous = Eclipse(
        id: "previous",
        saros: 141,
        date: previousDate,
        type: .totalSolar,
        maximumPoint: Coordinate(latitude: 0, longitude: 0),
        gamma: nil,
        magnitude: nil,
        durationSeconds: nil,
        pathWidthKm: nil,
        visibilitySummary: nil
    )

    static let next = Eclipse(
        id: "next",
        saros: 141,
        date: previousDate.addingTimeInterval(interval),
        type: .totalSolar,
        maximumPoint: Coordinate(latitude: 10, longitude: 10),
        gamma: nil,
        magnitude: nil,
        durationSeconds: nil,
        pathWidthKm: nil,
        visibilitySummary: nil
    )
}

private final class FixtureEclipseService: EclipseService {
    func allSarosSeries() throws -> [SarosSeriesSummary] {
        [
            SarosSeriesSummary(
                saros: 141,
                eclipseCount: 2,
                firstEclipseDate: Fixtures.previous.date,
                lastEclipseDate: Fixtures.next.date
            )
        ]
    }

    func eclipses(forSaros saros: Int) throws -> [Eclipse] {
        saros == 141 ? [Fixtures.previous, Fixtures.next] : []
    }

    func allEclipses() throws -> [Eclipse] {
        [Fixtures.previous, Fixtures.next]
    }

    func eclipse(withID eclipseID: String) throws -> Eclipse? {
        [Fixtures.previous, Fixtures.next].first { $0.id == eclipseID }
    }

    func previousAndNextEclipse(saros: Int, around date: Date) throws -> SarosInterval? {
        SarosInterval(saros: saros, previous: Fixtures.previous, next: Fixtures.next, normalizedPhase: 0)
    }

    func nearestEclipse(to date: Date) throws -> Eclipse? {
        abs(date.timeIntervalSince(Fixtures.previous.date)) < abs(date.timeIntervalSince(Fixtures.next.date))
            ? Fixtures.previous
            : Fixtures.next
    }

    func pathGeometry(for eclipseID: String) throws -> EclipsePathGeometry? {
        nil
    }
}

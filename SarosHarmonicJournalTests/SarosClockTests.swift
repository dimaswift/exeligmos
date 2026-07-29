import UIKit
import XCTest
@testable import SarosHarmonicJournal

final class SarosClockTests: XCTestCase {
    func testSarosSpiralSelectsEarliestIncomingSpikeAndHighestRarityOnTie() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let later = SarosFlipCountdown(
            order: 6,
            rarity: .mythicDigit(7),
            binStride: 1,
            targetBinIndex: 30,
            targetOctalAddress: "777777",
            periodStartDate: now,
            flipDate: now.addingTimeInterval(30),
            timeUntilFlip: 30
        )
        let lowerRarity = SarosFlipCountdown(
            order: 3,
            rarity: .rareDigit(2),
            binStride: 1,
            targetBinIndex: 10,
            targetOctalAddress: "123222",
            periodStartDate: now,
            flipDate: now.addingTimeInterval(10),
            timeUntilFlip: 10
        )
        let higherRarity = SarosFlipCountdown(
            order: 5,
            rarity: .legendaryDigit(2),
            binStride: 1,
            targetBinIndex: 10,
            targetOctalAddress: "122222",
            periodStartDate: now,
            flipDate: now.addingTimeInterval(10),
            timeUntilFlip: 10
        )
        let elapsed = SarosFlipCountdown(
            order: 6,
            rarity: .mythicDigit(7),
            binStride: 1,
            targetBinIndex: 0,
            targetOctalAddress: "777777",
            periodStartDate: now.addingTimeInterval(-20),
            flipDate: now.addingTimeInterval(-1),
            timeUntilFlip: -1
        )

        let selected = try XCTUnwrap(
            SarosGridSpiralProjection.nextCountdown(
                from: [later, lowerRarity, elapsed, higherRarity]
            )
        )

        XCTAssertEqual(selected.timeUntilFlip, 10)
        XCTAssertEqual(selected.rarity, .legendaryDigit(2))
    }

    func testSquareSarosSpiralSharesCenterBetweenFirstAndLastGlyph() throws {
        let rect = CGRect(x: 0, y: 0, width: 350, height: 500)
        let positions = SarosSquareSpiralGeometry.positions(
            count: SarosSquareSpiralGeometry.capacity,
            in: rect,
            nodeSize: 60
        )

        XCTAssertEqual(positions.count, 26)
        XCTAssertEqual(positions.first, positions.last)
        XCTAssertEqual(positions.first, CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(Set(positions.dropFirst().dropLast()).count, 24)

        let guide = SarosSquareSpiralGeometry.guidePoints(in: rect, nodeSize: 60)
        XCTAssertEqual(guide.count, 25)
        XCTAssertEqual(guide.last, CGPoint(x: rect.midX, y: rect.midY))
    }

    func testSquareSpiralProjectionUsesSelectedWaveformFamilyAroundNow() throws {
        let now = Fixtures.previousDate.addingTimeInterval(Fixtures.interval * 0.47)
        let reading = try SarosClockCalculator.reading(
            saros: 141,
            previous: Fixtures.previous,
            next: Fixtures.next,
            now: now,
            harmonicDepth: 6
        )

        let triplex = try XCTUnwrap(
            SarosGridSpiralProjection.nearestSpike(
                reading: reading,
                family: .rare,
                now: now
            )
        )
        let nihil = try XCTUnwrap(
            SarosGridSpiralProjection.nearestSpike(
                reading: reading,
                family: .mythic,
                now: now
            )
        )

        XCTAssertTrue(triplex.rarity.contributes(toWaveformFamily: .rare))
        XCTAssertTrue(nihil.rarity.contributes(toWaveformFamily: .mythic))
        XCTAssertLessThanOrEqual(
            abs(triplex.date.timeIntervalSince(now)),
            abs(nihil.date.timeIntervalSince(now))
        )
    }

    func testPhotoBoothMirrorReflectsPositiveSide() throws {
        let image = Self.splitColorImage()
        let mirrored = try XCTUnwrap(
            MirrorReflectionProcessor.process(image, edges: MirrorReflectionPreset.photoBooth)
        )
        let rightPixel = try Self.pixelColor(in: mirrored, x: 3, y: 1)

        XCTAssertGreaterThan(rightPixel.red, 180)
        XCTAssertLessThan(rightPixel.blue, 80)
    }

    func testSymbolicCameraComposerBuildsFourMirroredTiles() throws {
        let frontImage = try XCTUnwrap(CIImage(image: Self.splitColorImage(left: .red, right: .blue)))
        let backImage = try XCTUnwrap(CIImage(image: Self.splitColorImage(left: .green, right: .yellow)))
        let composite = try XCTUnwrap(SymbolicCameraImageComposer.compose(
            frontImage: frontImage,
            backImage: backImage,
            frontAngle: .pi / 2,
            backAngle: .pi / 2,
            outputSize: 80
        ))

        let topLeft = try Self.pixelColor(in: composite, x: 10, y: 10)
        let topRight = try Self.pixelColor(in: composite, x: 70, y: 10)
        let bottomLeft = try Self.pixelColor(in: composite, x: 10, y: 70)
        let bottomRight = try Self.pixelColor(in: composite, x: 70, y: 70)

        XCTAssertGreaterThan(topLeft.red, 180)
        XCTAssertGreaterThan(topRight.blue, 180)
        XCTAssertGreaterThan(bottomLeft.green, 120)
        XCTAssertGreaterThan(bottomRight.red, 180)
        XCTAssertGreaterThan(bottomRight.green, 180)
    }

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

    func testNonPartialSolarTypeUsesExplicitCentralEclipseAllowList() {
        XCTAssertTrue(EclipseType.totalSolar.isNonPartialSolar)
        XCTAssertTrue(EclipseType.annularSolar.isNonPartialSolar)
        XCTAssertTrue(EclipseType.hybridSolar.isNonPartialSolar)

        XCTAssertFalse(EclipseType.partialSolar.isNonPartialSolar)
        XCTAssertFalse(EclipseType.totalLunar.isNonPartialSolar)
        XCTAssertFalse(EclipseType.partialLunar.isNonPartialSolar)
        XCTAssertFalse(EclipseType.penumbralLunar.isNonPartialSolar)
        XCTAssertFalse(EclipseType.unknown.isNonPartialSolar)

        let eclipses = EclipseType.allCases.map { type in
            Eclipse(
                id: type.rawValue,
                saros: 1,
                date: .distantPast,
                type: type,
                maximumPoint: nil,
                gamma: nil,
                magnitude: nil,
                durationSeconds: nil,
                pathWidthKm: nil,
                visibilitySummary: nil
            )
        }

        XCTAssertEqual(
            eclipses.filter(SarosActivityPolicy.nonPartialOnly.includes).map(\.type),
            [.totalSolar, .annularSolar, .hybridSolar]
        )
        XCTAssertEqual(
            eclipses.filter(SarosActivityPolicy.allEclipses.includes).count,
            EclipseType.allCases.count
        )
    }

    func testNonPartialActivityUsesEligibleLifespanAndEligibleBrackets() throws {
        let service = PolicyFixtureEclipseService()
        let beforeFirstCentral = Date(timeIntervalSince1970: 5)

        XCTAssertEqual(
            try service.activeSarosIntervals(at: beforeFirstCentral, policy: .allEclipses).map(\.summary.saros),
            [200]
        )
        XCTAssertTrue(
            try service.activeSarosIntervals(at: beforeFirstCentral, policy: .nonPartialOnly).isEmpty
        )

        let betweenCentralEclipses = Date(timeIntervalSince1970: 15)
        let active = try XCTUnwrap(
            service.activeSarosInterval(
                saros: 200,
                at: betweenCentralEclipses,
                policy: .nonPartialOnly
            )
        )

        XCTAssertEqual(active.interval.previous.type, .totalSolar)
        XCTAssertEqual(active.interval.next.type, .annularSolar)
        XCTAssertEqual(active.interval.normalizedPhase, 0.5, accuracy: 0.000001)

        let afterLastCentral = Date(timeIntervalSince1970: 25)
        XCTAssertTrue(
            try service.activeSarosIntervals(at: afterLastCentral, policy: .nonPartialOnly).isEmpty
        )
        XCTAssertEqual(
            try service.activeSarosIntervals(at: afterLastCentral, policy: .allEclipses).map(\.summary.saros),
            [200]
        )
    }

    func testBundledActiveSarosPolicyRegressionForJuly2026() throws {
        let service = BundledSolarEclipseService()
        let date = Self.date(year: 2026, month: 7, day: 29)

        let all = try service.activeSarosIntervals(at: date, policy: .allEclipses)
        let nonPartial = try service.activeSarosIntervals(at: date, policy: .nonPartialOnly)

        XCTAssertEqual(all.map(\.summary.saros), Array(117...156))
        XCTAssertEqual(
            nonPartial.map(\.summary.saros),
            [120, 121] + Array(126...148) + [152]
        )
        XCTAssertEqual(all.count, 40)
        XCTAssertEqual(nonPartial.count, 26)
        XCTAssertTrue(nonPartial.allSatisfy {
            $0.interval.previous.type.isNonPartialSolar &&
                $0.interval.next.type.isNonPartialSolar
        })
    }

    func testBundledMoonPhaseDatabaseSummary() throws {
        let service = BundledMoonPhaseService()
        let summary = try service.databaseSummary()

        XCTAssertEqual(summary.byteCount, 47_070)
        XCTAssertEqual(summary.newMoonCount, 2_478)
        XCTAssertEqual(summary.fullMoonCount, 2_478)
        XCTAssertEqual(summary.apogeeCount, 2_655)
        XCTAssertEqual(summary.perigeeCount, 2_657)
        XCTAssertEqual(summary.ascendingNodeCount, 2_689)
        XCTAssertEqual(summary.descendingNodeCount, 2_689)
        XCTAssertEqual(summary.coverageStart, Self.date(year: 1900, month: 1, day: 1))
        XCTAssertEqual(summary.coverageEnd, Self.date(year: 2100, month: 1, day: 1))
        XCTAssertEqual(summary.referenceNewMoon, Self.date("1992-01-04T23:09:35Z"))
        XCTAssertEqual(summary.synodicMonthSeconds, 2_551_442.876899, accuracy: 0.000001)
        XCTAssertEqual(summary.referenceApogee, Self.date("1992-01-06T11:55:22Z"))
        XCTAssertEqual(summary.anomalisticMonthSeconds, 2_380_713.109632, accuracy: 0.000001)
        XCTAssertEqual(summary.referenceAscendingNode, Self.date("1992-01-04T15:04:50Z"))
        XCTAssertEqual(summary.draconicMonthSeconds, 2_351_135.878589, accuracy: 0.000001)
    }

    func testMoonPhaseReadingUsesBakedNewAndFullEvents() throws {
        let service = BundledMoonPhaseService()

        let newMoonReading = try service.reading(for: Self.date("1992-01-04T23:09:35Z"))
        XCTAssertEqual(newMoonReading.phase, .new)
        XCTAssertEqual(newMoonReading.previousEvent.kind, .new)
        XCTAssertEqual(newMoonReading.previousEvent.date, Self.date("1992-01-04T23:09:35Z"))
        XCTAssertEqual(newMoonReading.normalizedPhase, 0, accuracy: 0.000001)

        let fullMoonReading = try service.reading(for: Self.date("1992-01-19T21:28:29Z"))
        XCTAssertEqual(fullMoonReading.phase, .full)
        XCTAssertEqual(fullMoonReading.nearestEvent.kind, .full)
        XCTAssertEqual(fullMoonReading.nearestEvent.date, Self.date("1992-01-19T21:28:29Z"))
        XCTAssertEqual(fullMoonReading.illuminatedFraction, 1, accuracy: 0.01)

        let apogee = try service.octalReading(for: Self.date("1992-01-06T11:55:22Z"), depth: 8)
        XCTAssertEqual(apogee.component(.anomalistic)?.detailOctalAddress, "00000000")

        let ascendingNode = try service.octalReading(for: Self.date("1992-01-04T15:04:50Z"), depth: 8)
        XCTAssertEqual(ascendingNode.component(.draconic)?.detailOctalAddress, "00000000")

        let orbitalEvents = try service.orbitalEvents(
            from: Self.date("1991-12-20T00:00:00Z"),
            through: Self.date("1992-01-08T00:00:00Z")
        )
        XCTAssertTrue(orbitalEvents.contains { $0.kind == .apogee && $0.date == Self.date("1992-01-06T11:55:22Z") })
        XCTAssertTrue(orbitalEvents.contains { $0.kind == .perigee })
        XCTAssertTrue(orbitalEvents.contains { $0.kind == .ascendingNode && $0.date == Self.date("1992-01-04T15:04:50Z") })
        XCTAssertTrue(orbitalEvents.contains { $0.kind == .descendingNode })
    }

    func testMoonOctalReadingUsesNewMoonnessRarity() throws {
        let service = BundledMoonPhaseService()
        let newMoonDate = Self.date("1992-01-04T23:09:35Z")
        let phase = try service.reading(for: newMoonDate)
        let binDuration = phase.nextNewMoon.date.timeIntervalSince(newMoonDate) / 512

        let newMoon = try service.octalReading(for: newMoonDate, depth: 3)
        XCTAssertEqual(newMoon.octalAddress, "070")
        XCTAssertEqual(newMoon.component(.synodic)?.detailOctalAddress, "000")
        XCTAssertEqual(newMoon.rarity, .legendary)

        let epic = try service.octalReading(for: newMoonDate.addingTimeInterval(binDuration * 1.1), depth: 3)
        XCTAssertEqual(epic.component(.synodic)?.detailOctalAddress, "001")
        XCTAssertEqual(epic.rarity, .epic)

        let rare = try service.octalReading(for: newMoonDate.addingTimeInterval(binDuration * 8.1), depth: 3)
        XCTAssertEqual(rare.component(.synodic)?.detailOctalAddress, "010")
        XCTAssertEqual(rare.rarity, .rare)

        let floor = try service.octalReading(for: newMoonDate.addingTimeInterval(binDuration * 64.1), depth: 3)
        XCTAssertEqual(floor.component(.synodic)?.detailOctalAddress, "100")
        XCTAssertEqual(floor.rarity, .rare)

        let nextNewMoonEdge = try service.octalReading(for: phase.nextNewMoon.date.addingTimeInterval(-1), depth: 3)
        XCTAssertEqual(nextNewMoonEdge.octalAddress, "700")
        XCTAssertEqual(nextNewMoonEdge.component(.synodic)?.detailOctalAddress, "777")
        XCTAssertEqual(nextNewMoonEdge.rarity, .legendary)

        let detailedNextNewMoonEdge = try service.octalReading(for: phase.nextNewMoon.date.addingTimeInterval(-1), depth: 8)
        XCTAssertEqual(detailedNextNewMoonEdge.component(.synodic)?.detailOctalAddress.hasPrefix("777"), true)
        XCTAssertEqual(detailedNextNewMoonEdge.rarity, .legendary)
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

    private static func date(_ iso8601: String) -> Date {
        ISO8601DateFormatter().date(from: iso8601) ?? .distantPast
    }

    private static func splitColorImage() -> UIImage {
        splitColorImage(left: .red, right: .blue)
    }

    private static func splitColorImage(left: UIColor, right: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 2), format: format).image { context in
            left.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            right.setFill()
            context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
        }
    }

    private static func pixelColor(in image: UIImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = image.cgImage else {
            throw XCTSkip("Could not read test image pixels.")
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
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

    func testOrderCountdownTargetsNextExactCarry() throws {
        let binCount = 512.0
        let now = Fixtures.previous.date.addingTimeInterval(Fixtures.interval * 9.2 / binCount)
        let reading = try SarosClockCalculator.reading(
            saros: 141,
            previous: Fixtures.previous,
            next: Fixtures.next,
            now: now,
            harmonicDepth: 3
        )

        let countdown = try XCTUnwrap(reading.countdown(order: 1, now: now))

        XCTAssertEqual(reading.binIndex, 9)
        XCTAssertEqual(countdown.targetBinIndex, 64)
        XCTAssertEqual(countdown.targetOctalAddress, "100")
        XCTAssertEqual(countdown.order, 1)
        XCTAssertEqual(countdown.rarity, .legendaryDigit(7))
    }

    func testOctalAddressDateMapping() throws {
        let reading = try SarosClockCalculator.reading(
            saros: 141,
            previous: Fixtures.previous,
            next: Fixtures.next,
            now: Fixtures.previous.date,
            harmonicDepth: 2
        )

        let index = reading.binIndex(forOctalAddress: "10")
        let date = reading.date(forBinIndex: index)

        XCTAssertEqual(index, 8)
        XCTAssertEqual(
            date.timeIntervalSinceReferenceDate,
            Fixtures.previous.date.addingTimeInterval(Fixtures.interval / 8).timeIntervalSinceReferenceDate,
            accuracy: 0.01
        )
        XCTAssertEqual(reading.octalAddress(forBinIndex: index), "10")
    }

    func testQualifiedFlipStrideUsesRepeatedSuffixLogic() throws {
        let now = Fixtures.previous.date.addingTimeInterval(Fixtures.interval * 0.2)
        let reading = try SarosClockCalculator.reading(
            saros: 141,
            previous: Fixtures.previous,
            next: Fixtures.next,
            now: now,
            harmonicDepth: 7
        )

        XCTAssertEqual(reading.qualifiedFlipStride(forOrder: 3), 4_096)
        XCTAssertEqual(FlipRarity.rareDigit(1).binStride(harmonicDepth: 7), 4_096)
        XCTAssertEqual(reading.nextQualifiedFlipBin(after: 9, rarity: .rareDigit(1), exact: true), 585)
        XCTAssertEqual(reading.previousQualifiedFlipBin(atOrBefore: 1_100, rarity: .rareDigit(1), exact: true), 585)
        XCTAssertEqual(FlipRarity.epicDigit(1).binStride(harmonicDepth: 7), 32_768)
        XCTAssertEqual(reading.nextQualifiedFlipBin(after: 9, rarity: .epicDigit(1), exact: true), 4_681)
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

final class JournalWaveformSpikeSemanticsTests: XCTestCase {
    func testOddSarosIsPositiveAndEvenSarosIsNegative() {
        XCTAssertEqual(JournalWaveformSpikeSemantics.polarity(forSaros: 141), 1)
        XCTAssertEqual(JournalWaveformSpikeSemantics.polarity(forSaros: 142), -1)
    }

    func testPhaseMSBUsesNonZeroLogarithmicAmplitudeThroughOmega() {
        XCTAssertEqual(JournalWaveformSpikeSemantics.phaseMostSignificantDigit("012345"), 0)
        XCTAssertEqual(JournalWaveformSpikeSemantics.phaseMostSignificantDigit("712345"), 7)
        XCTAssertEqual(JournalWaveformSpikeSemantics.phaseAmplitudeScale("012345"), 0.25, accuracy: 0.000_001)
        XCTAssertEqual(JournalWaveformSpikeSemantics.phaseAmplitudeScale("112345"), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(JournalWaveformSpikeSemantics.phaseAmplitudeScale("312345"), 0.75, accuracy: 0.000_001)
        XCTAssertEqual(JournalWaveformSpikeSemantics.phaseAmplitudeScale("712345"), 1, accuracy: 0.000_001)
    }

    func testHigherOrderSpikesContributeToEveryLowerOrderWaveformFamily() {
        XCTAssertTrue(FlipRarity.mythicDigit(7).contributes(toWaveformFamily: .mythic))
        XCTAssertTrue(FlipRarity.mythicDigit(7).contributes(toWaveformFamily: .legendary))
        XCTAssertTrue(FlipRarity.mythicDigit(7).contributes(toWaveformFamily: .epic))
        XCTAssertTrue(FlipRarity.mythicDigit(7).contributes(toWaveformFamily: .rare))

        XCTAssertFalse(FlipRarity.legendaryDigit(4).contributes(toWaveformFamily: .mythic))
        XCTAssertTrue(FlipRarity.legendaryDigit(4).contributes(toWaveformFamily: .legendary))
        XCTAssertTrue(FlipRarity.legendaryDigit(4).contributes(toWaveformFamily: .epic))
        XCTAssertTrue(FlipRarity.legendaryDigit(4).contributes(toWaveformFamily: .rare))
    }

    func testTemporalWaveAlternatesAcrossBaselineAndIgnoresMagnitudeAndRarityForHeight() throws {
        let odd = Self.spike(
            saros: 141,
            timestamp: 1_700_000_000,
            address: "700000",
            rarity: .rareDigit(1),
            magnitude: 0.2
        )
        let even = Self.spike(
            saros: 142,
            timestamp: 1_700_010_000,
            address: "700000",
            rarity: .mythicDigit(7),
            magnitude: 1.8
        )
        let series = JournalTemporalEngine.series(spikes: [odd, even], options: .default)

        XCTAssertGreaterThan(series.energy(at: odd.date), 0)
        XCTAssertLessThan(series.energy(at: even.date), 0)
        XCTAssertEqual(
            JournalTemporalEngine.peakHeight(for: odd, amplitudeMultiplier: 1),
            JournalTemporalEngine.peakHeight(for: even, amplitudeMultiplier: 1),
            accuracy: 0.000_001
        )
    }

    func testIgnoringPartialEclipsesRemovesThemFromTemporalComponents() {
        let first = Self.spike(
            saros: 141,
            timestamp: 1_700_000_000,
            address: "700000",
            rarity: .rareDigit(1),
            magnitude: 1,
            type: .totalSolar
        )
        let partial = Self.spike(
            saros: 142,
            timestamp: 1_700_010_000,
            address: "700000",
            rarity: .rareDigit(1),
            magnitude: 1,
            type: .partialSolar
        )
        let last = Self.spike(
            saros: 143,
            timestamp: 1_700_020_000,
            address: "700000",
            rarity: .rareDigit(1),
            magnitude: 1,
            type: .annularSolar
        )

        var allOptions = JournalWaveformOptions.default
        allOptions.ignorePartialEclipses = false
        let allSeries = JournalTemporalEngine.series(
            spikes: [first, partial, last],
            options: allOptions
        )

        XCTAssertEqual(allSeries.components.count, 3)
        XCTAssertNotNil(allSeries.component(for: partial))

        var nonPartialOptions = allOptions
        nonPartialOptions.ignorePartialEclipses = true
        let nonPartialSeries = JournalTemporalEngine.series(
            spikes: [first, partial, last],
            options: nonPartialOptions
        )

        XCTAssertEqual(nonPartialSeries.components.count, 2)
        XCTAssertNil(nonPartialSeries.component(for: partial))
        XCTAssertTrue(nonPartialSeries.components.allSatisfy {
            $0.contributorSpikes.allSatisfy { !$0.isPartialEclipse }
        })
    }

    private static func spike(
        saros: Int,
        timestamp: Int64,
        address: String,
        rarity: FlipRarity,
        magnitude: Double?,
        type: EclipseType = .totalSolar
    ) -> JournalSpikeReference {
        JournalSpikeReference(
            saros: saros,
            unixTimestamp: timestamp,
            octalAddress: address,
            harmonicDepth: 6,
            rarityRawValue: rarity.rawValue,
            gamma: saros.isMultiple(of: 2) ? -0.4 : 0.4,
            magnitude: magnitude,
            eclipseTypeRawValue: type.rawValue,
            sarosSequence: 10,
            sarosSeriesCount: 20,
            seriesProgressesSouthToNorth: nil
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

final class FlipNotificationOrderTests: XCTestCase {
    func testSubrarityTitlesUseGreekPrefixes() {
        XCTAssertEqual(FlipRarity.rareDigit(1).title, "Alpha Triplex")
        XCTAssertEqual(FlipRarity.epicDigit(2).title, "Beta Duplex")
        XCTAssertEqual(FlipRarity.mythicDigit(4).title, "Delta Nihil")
        XCTAssertEqual(FlipRarity.legendaryDigit(6).title, "Digamma Simplex")
        XCTAssertEqual(FlipRarity.mythicDigit(7).title, "Omega Nihil")
    }

    func testRarityGlyphAddressesConveySuffixType() {
        XCTAssertEqual(FlipRarity.rare.glyphAddress(harmonicDepth: 7), "0007777")
        XCTAssertEqual(FlipRarity.epicDigit(2).glyphAddress(harmonicDepth: 7), "0022222")
        XCTAssertEqual(FlipRarity.legendaryDigit(6).glyphAddress(harmonicDepth: 7), "0666666")
        XCTAssertEqual(FlipRarity.mythicDigit(4).glyphAddress(harmonicDepth: 7), "4444444")
    }

    func testEightDigitRarityDisplayPadsWithRepeatedDigit() {
        XCTAssertEqual(
            JournalSettings.rarityOctalAddress("32111", storedDepth: 5, rarity: .epicDigit(1)),
            "32111111"
        )
        XCTAssertEqual(
            JournalSettings.rarityOctalAddress("142222", storedDepth: 6, rarity: .epicDigit(2)),
            "14222222"
        )
    }

    func testOrderMatchesRepeatedSuffixExamples() {
        XCTAssertEqual(
            FlipNotificationPreferences.order(forOctalAddress: "123456", harmonicDepth: 6),
            0
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "123456", harmonicDepth: 6),
            .common
        )
        XCTAssertEqual(
            FlipNotificationPreferences.order(forOctalAddress: "123111", harmonicDepth: 6),
            3
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "123111", harmonicDepth: 6),
            .rareDigit(1)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "123222", harmonicDepth: 6),
            .rareDigit(2)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "121111", harmonicDepth: 6),
            .epicDigit(1)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "211111", harmonicDepth: 6),
            .legendaryDigit(1)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "111111", harmonicDepth: 6),
            .mythicDigit(1)
        )
    }

    func testRepeatedSuffixExamplesAcrossDepths() {
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "1231111", harmonicDepth: 7),
            .rareDigit(1)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "1422222", harmonicDepth: 7),
            .epicDigit(2)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "1333333", harmonicDepth: 7),
            .legendaryDigit(3)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "1111111", harmonicDepth: 7),
            .mythicDigit(1)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "12311", harmonicDepth: 5),
            .rareDigit(1)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "14222", harmonicDepth: 5),
            .epicDigit(2)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "13333", harmonicDepth: 5),
            .legendaryDigit(3)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "33333", harmonicDepth: 5),
            .mythicDigit(3)
        )
    }

    func testZeroBoundariesResolveToPreviousSevenSuffix() {
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "1230000", harmonicDepth: 7),
            .rareDigit(7)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "1227777", harmonicDepth: 7),
            .rareDigit(7)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "1200000", harmonicDepth: 7),
            .epicDigit(7)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "1000000", harmonicDepth: 7),
            .legendaryDigit(7)
        )
        XCTAssertEqual(
            FlipNotificationPreferences.rarity(forOctalAddress: "0000000", harmonicDepth: 7, isEclipse: true),
            .mythicDigit(7)
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
            triggerType: .manual,
            latitude: 12.34,
            longitude: 56.78
        )

        let archive = ExportService().makeArchive(entities: [entity], records: [record])

        XCTAssertEqual(archive.entities.count, 1)
        XCTAssertEqual(archive.records.count, 1)
        XCTAssertEqual(archive.entities[0].saros, 141)
        XCTAssertEqual(archive.records[0].octalAddress, "123")
        XCTAssertEqual(archive.records[0].text, "A note")
        XCTAssertEqual(archive.records[0].latitude, 12.34)
        XCTAssertEqual(archive.records[0].longitude, 56.78)
    }

    func testRecordZIPExportContainsMetadataAndMediaEntries() throws {
        let mediaID = UUID()
        let mediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(mediaID.uuidString)
            .appendingPathExtension("txt")
        try Data("payload".utf8).write(to: mediaURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        let record = JournalRecord(
            entityID: UUID(),
            text: "A note",
            mediaItems: [
                JournalMediaItem(id: mediaID, type: .audio, localPath: mediaURL.path)
            ],
            saros: 141,
            harmonicDepth: 3,
            octalAddress: "123",
            binIndex: 83,
            phase: 0.2,
            triggerType: .manual
        )

        let exportURL = try ExportService().exportRecordZIP(record: record, entityTitle: "Anchor")
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let data = try Data(contentsOf: exportURL)
        XCTAssertEqual(data.prefix(2), Data([0x50, 0x4B]))
        XCTAssertNotNil(data.range(of: Data("record.json".utf8)))
        XCTAssertNotNil(data.range(of: Data("media/\(mediaID.uuidString).txt".utf8)))
    }
}

final class SyncServiceV2Tests: XCTestCase {
    func testRegistrationInputMatchesServerSchemaAndNormalizesOptionalFields() throws {
        let input = try SyncRegistrationInput.validated(
            login: "  Aurora.User  ",
            password: "correct-horse-battery-staple",
            displayName: "  Aurora User  ",
            inviteCode: "  EXELIGMOS-2026  "
        )

        XCTAssertEqual(input.login, "aurora.user")
        XCTAssertEqual(input.password, "correct-horse-battery-staple")
        XCTAssertEqual(input.displayName, "Aurora User")
        XCTAssertEqual(input.inviteCode, "EXELIGMOS-2026")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: String]
        )
        XCTAssertEqual(request, [
            "login": "aurora.user",
            "password": "correct-horse-battery-staple",
            "displayName": "Aurora User",
            "inviteCode": "EXELIGMOS-2026",
        ])
    }

    func testRegistrationRequestOmitsBlankOptionalFields() throws {
        let input = try SyncRegistrationInput.validated(
            login: "aurora",
            password: "correct-horse-battery-staple",
            displayName: "   ",
            inviteCode: ""
        )

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: String]
        )
        XCTAssertEqual(Set(request.keys), ["login", "password"])
    }

    func testRegistrationInputExplainsInvalidLoginAndPassword() {
        XCTAssertThrowsError(try SyncRegistrationInput.validated(
            login: "aurora@example.com",
            password: "correct-horse-battery-staple",
            displayName: nil,
            inviteCode: nil
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("periods, underscores, or hyphens"))
        }

        XCTAssertThrowsError(try SyncRegistrationInput.validated(
            login: "aurora",
            password: "too-short",
            displayName: nil,
            inviteCode: nil
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("12 to 1024"))
        }
    }

    func testCredentialBearingURLsRequireTheConfiguredOrigin() throws {
        let server = try XCTUnwrap(URL(string: "https://journal.example.com"))

        XCTAssertTrue(SyncService.isSameOrigin(
            try XCTUnwrap(URL(string: "https://journal.example.com:443/media/1/content")),
            as: server
        ))
        XCTAssertFalse(SyncService.isSameOrigin(
            try XCTUnwrap(URL(string: "https://cdn.example.com/media/1/content")),
            as: server
        ))
        XCTAssertFalse(SyncService.isSameOrigin(
            try XCTUnwrap(URL(string: "http://journal.example.com/media/1/content")),
            as: server
        ))
        XCTAssertFalse(SyncService.isSameOrigin(
            try XCTUnwrap(URL(string: "https://journal.example.com:8443/media/1/content")),
            as: server
        ))
    }

    func testSnapshotCollectionURLsUseEachEndpointsSupportedLimit() throws {
        let server = try XCTUnwrap(URL(string: "https://journal.example.com"))
        let service = SyncService()
        let tagsURL = try service.collectionPageURL(
            server: server,
            path: "/tags",
            limit: 200,
            cursor: nil
        )
        let recordsURL = try service.collectionPageURL(
            server: server,
            path: "/records",
            limit: 25,
            cursor: "next page"
        )
        let tagItems = try XCTUnwrap(URLComponents(url: tagsURL, resolvingAgainstBaseURL: false)?.queryItems)
        let recordItems = try XCTUnwrap(URLComponents(url: recordsURL, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertEqual(tagItems.first(where: { $0.name == "limit" })?.value, "200")
        XCTAssertEqual(recordItems.first(where: { $0.name == "limit" })?.value, "25")
        XCTAssertEqual(recordItems.first(where: { $0.name == "cursor" })?.value, "next page")
    }

    func testPrivateRecordEnvelopeDecodesWithoutPublicFields() throws {
        let data = Data("""
        {
          "id": "f91d97ab-f28d-4fb8-991a-2c1c75e96532",
          "userId": "ca040b4a-90fa-4099-bf46-fc5fd5f7ba66",
          "deviceId": "87824812-dc22-47c6-bb4e-1b69adac916f",
          "visibility": "private",
          "revision": 4,
          "createdAt": "2026-07-15T00:00:00Z",
          "updatedAt": "2026-07-15T00:01:00Z",
          "encryption": {
            "algorithm": "A256GCM",
            "nonce": "AAAAAAAAAAAAAAAA",
            "ciphertext": "AAAAAAAAAAAAAAAAAAAAAA==",
            "contentType": "application/vnd.exeligmos.record+json"
          },
          "media": []
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = try decoder.decode(SyncRecordResource.self, from: data)

        XCTAssertEqual(record.visibility, "private")
        XCTAssertNil(record.occurredAt)
        XCTAssertNil(record.payload)
        XCTAssertNil(record.tagIDs)
    }

    func testLocalStoreOwnerBindingCannotSilentlySwitchAccounts() throws {
        let suite = "SyncServiceV2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncStateStore(defaults: defaults)
        let server = try XCTUnwrap(URL(string: "https://journal.example.com"))
        let firstUser = UUID()

        XCTAssertNoThrow(try store.bindLocalStoreIfNeeded(server: server, userID: firstUser))
        XCTAssertNoThrow(try store.bindLocalStoreIfNeeded(server: server, userID: firstUser))
        XCTAssertThrowsError(try store.bindLocalStoreIfNeeded(server: server, userID: UUID())) { error in
            guard case SyncService.SyncError.localStoreOwnerMismatch = error else {
                return XCTFail("Expected an owner mismatch, got \(error)")
            }
        }
    }

    func testServerRejectedMutationGetsANewReceiptID() {
        let command = SyncLocalCommand(type: .entryUpsert, subjectID: UUID().uuidString)
        let originalID = command.id

        command.prepareRetry(afterServerRejection: SyncService.SyncError.invalidResponse(
            statusCode: 412,
            body: "ETag changed"
        ))

        XCTAssertNotEqual(command.id, originalID)
        XCTAssertEqual(command.attemptCount, 1)
        XCTAssertNil(command.sentAt)
        XCTAssertTrue(command.requiresManualRetry)
    }

    func testPendingCommandsUploadTagsBeforeRecords() {
        let record = SyncLocalCommand(
            createdAt: Date(timeIntervalSince1970: 1),
            type: .entryUpsert,
            subjectID: UUID().uuidString
        )
        let tag = SyncLocalCommand(
            createdAt: Date(timeIntervalSince1970: 2),
            type: .tagUpsert,
            subjectID: UUID().uuidString
        )
        let sent = SyncLocalCommand(
            createdAt: Date(timeIntervalSince1970: 0),
            type: .tagUpsert,
            subjectID: UUID().uuidString
        )
        sent.markSent()

        let ordered = SyncLocalCommand.pendingInPushOrder([record, sent, tag], userID: UUID())

        XCTAssertEqual(ordered.map(\.type), [.tagUpsert, .entryUpsert])
    }

    func testFailedCommandsWaitForExplicitRetry() {
        let userID = UUID()
        let command = SyncLocalCommand(
            type: .entryUpsert,
            subjectID: UUID().uuidString,
            ownerUserID: userID
        )
        command.prepareRetry(afterServerRejection: SyncService.SyncError.invalidResponse(
            statusCode: 422,
            body: "Rejected"
        ))

        XCTAssertTrue(SyncLocalCommand.pendingInPushOrder([command], userID: userID).isEmpty)

        SyncLocalCommand.retryFailed([command], userID: userID)

        XCTAssertEqual(command.attemptCount, 0)
        XCTAssertNil(command.lastError)
        XCTAssertEqual(
            SyncLocalCommand.pendingInPushOrder([command], userID: userID).map(\.id),
            [command.id]
        )
    }

    func testTransientFailuresUseBoundedAutomaticBackoff() {
        let command = SyncLocalCommand(type: .entryUpsert, subjectID: UUID().uuidString)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        command.markTransientFailure(URLError(.notConnectedToInternet), now: now)

        XCTAssertFalse(command.requiresManualRetry)
        XCTAssertFalse(command.isEligibleForAutomaticSync(at: now.addingTimeInterval(4.9)))
        XCTAssertTrue(command.isEligibleForAutomaticSync(at: now.addingTimeInterval(5)))

        command.markTransientFailure(URLError(.timedOut), now: now.addingTimeInterval(5))

        XCTAssertFalse(command.isEligibleForAutomaticSync(at: now.addingTimeInterval(14.9)))
        XCTAssertTrue(command.isEligibleForAutomaticSync(at: now.addingTimeInterval(15)))
    }

    func testOnlyTransientSyncFailuresRetryAutomatically() {
        XCTAssertTrue(SyncService.isRetryableFailure(URLError(.notConnectedToInternet)))
        XCTAssertTrue(SyncService.isRetryableFailure(SyncService.SyncError.invalidResponse(
            statusCode: 503,
            body: "Unavailable"
        )))
        XCTAssertTrue(SyncService.isRetryableFailure(SyncService.SyncError.invalidResponse(
            statusCode: 429,
            body: "Rate limited"
        )))
        XCTAssertFalse(SyncService.isRetryableFailure(SyncService.SyncError.invalidResponse(
            statusCode: 422,
            body: "Invalid record"
        )))
        XCTAssertFalse(SyncService.isRetryableFailure(URLError(.cancelled)))
    }

    func testRecordPublicIDsUseFiveBase64URLCharacters() {
        let generated = (0..<256).map { _ in JournalRecordPublicID.generate() }

        XCTAssertTrue(generated.allSatisfy { $0.count == JournalRecordPublicID.length })
        XCTAssertTrue(generated.allSatisfy { id in
            id.allSatisfy { JournalRecordPublicID.alphabet.contains($0) }
        })
        XCTAssertTrue(generated.allSatisfy { JournalRecordPublicID.normalized($0) == $0 })
        XCTAssertNil(JournalRecordPublicID.normalized("too-long"))
        XCTAssertNil(JournalRecordPublicID.normalized("abc+="))
    }

    func testPendingCommandsAreScopedToTheAuthenticatedOwner() {
        let currentUser = UUID()
        let anotherUser = UUID()
        let current = SyncLocalCommand(
            type: .entryUpsert,
            subjectID: UUID().uuidString,
            ownerUserID: currentUser
        )
        let unclaimed = SyncLocalCommand(type: .tagUpsert, subjectID: UUID().uuidString)
        let foreign = SyncLocalCommand(
            type: .entryUpsert,
            subjectID: UUID().uuidString,
            ownerUserID: anotherUser
        )

        let ordered = SyncLocalCommand.pendingInPushOrder(
            [foreign, current, unclaimed],
            userID: currentUser
        )

        XCTAssertEqual(Set(ordered.map(\.id)), Set([current.id, unclaimed.id]))
    }

    func testOwnerPayloadWithoutEmbeddedIDRestoresIdentityAndTimestamps() throws {
        let recordID = UUID()
        let deviceID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000.123)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_120.456)
        let eventDate = Date(timeIntervalSince1970: 1_699_900_000.789)
        let endDate = eventDate.addingTimeInterval(900)
        let original = JournalEntrySnapshot(
            id: recordID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            eventDate: eventDate,
            endDate: endDate,
            unixTimestamp: Int64(eventDate.timeIntervalSince1970),
            version: 7,
            text: "Imported observation",
            emoji: "☀️",
            mediaItems: [],
            tagIDs: ["007"],
            context: .empty(date: eventDate),
            latitude: 55.75,
            longitude: 37.62,
            sourceRecordID: UUID(),
            sourceDeviceID: "SOURCE-PHONE",
            sourceDeviceEmoji: "◇",
            sourceDeviceName: "Source phone",
            weatherCode: 1,
            weatherEmoji: "☀️",
            temperatureC: 21
        )
        var ownerPayload = try XCTUnwrap(try jsonValue(original).objectValue)
        XCTAssertNotNil(ownerPayload.removeValue(forKey: "id"))
        let remote = SyncRecordResource(
            id: "Ab-_1",
            originID: recordID,
            userID: UUID(),
            deviceID: deviceID,
            visibility: "public",
            revision: 9,
            createdAt: createdAt,
            updatedAt: updatedAt,
            occurredAt: eventDate,
            endedAt: endDate,
            payload: .object(ownerPayload),
            tagIDs: [],
            media: []
        )

        let mapped = try SyncPayloadMapper.entrySnapshot(from: remote, localMedia: [], tags: [:])

        XCTAssertEqual(mapped.id, recordID)
        XCTAssertEqual(mapped.createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(mapped.updatedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(mapped.eventDate.timeIntervalSince1970, eventDate.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(mapped.endDate).timeIntervalSince1970, endDate.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(mapped.unixTimestamp, original.unixTimestamp)
        XCTAssertEqual(mapped.version, 7)
        XCTAssertEqual(mapped.tagIDs, ["007"])
        XCTAssertEqual(mapped.sourceDeviceID, "SOURCE-PHONE")
        XCTAssertEqual(mapped.text, "Imported observation")
    }

    func testAgentRecordFallsBackToServerOccurrenceAndStandardDomainContext() throws {
        let recordID = UUID()
        let deviceID = UUID()
        let occurredAt = Date(timeIntervalSince1970: 1_750_000_000)
        let remote = SyncRecordResource(
            id: "Sun_1",
            originID: recordID,
            userID: UUID(),
            deviceID: deviceID,
            visibility: "public",
            revision: 3,
            createdAt: occurredAt.addingTimeInterval(60),
            updatedAt: occurredAt.addingTimeInterval(120),
            occurredAt: occurredAt,
            endedAt: nil,
            payload: .object([
                "text": .string("X1.7 solar flare"),
                "emoji": .string("☀️"),
                "location": .object([
                    "latitude": .number(12.5),
                    "longitude": .number(-45.25)
                ]),
                "weather": .object([
                    "code": .integer(2),
                    "emoji": .string("⛅️"),
                    "temperatureC": .integer(18)
                ])
            ]),
            tagIDs: [],
            media: []
        )

        let mapped = try SyncPayloadMapper.entrySnapshot(from: remote, localMedia: [], tags: [:])

        XCTAssertEqual(mapped.id, recordID)
        XCTAssertEqual(mapped.eventDate, occurredAt)
        XCTAssertEqual(mapped.unixTimestamp, Int64(occurredAt.timeIntervalSince1970))
        XCTAssertEqual(mapped.version, 3)
        XCTAssertEqual(mapped.sourceDeviceID, deviceID.uuidString)
        XCTAssertEqual(mapped.text, "X1.7 solar flare")
        XCTAssertEqual(mapped.latitude, 12.5)
        XCTAssertEqual(mapped.longitude, -45.25)
        XCTAssertEqual(mapped.weatherCode, 2)
        XCTAssertEqual(mapped.context.eventDate, occurredAt)
    }

    private func jsonValue<T: Encodable>(_ value: T) throws -> SyncJSONValue {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return try JSONDecoder().decode(SyncJSONValue.self, from: encoder.encode(value))
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

    func eclipseBracket(around date: Date) throws -> EclipseBracket? {
        let total = max(Fixtures.next.date.timeIntervalSince(Fixtures.previous.date), 1)
        let phase = min(max(date.timeIntervalSince(Fixtures.previous.date) / total, 0), 1)
        return EclipseBracket(previous: Fixtures.previous, next: Fixtures.next, normalizedPhase: phase)
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

private final class PolicyFixtureEclipseService: EclipseService {
    private let records: [Eclipse] = [
        Eclipse(
            id: "partial-leading",
            saros: 200,
            date: Date(timeIntervalSince1970: 0),
            type: .partialSolar,
            maximumPoint: nil,
            gamma: nil,
            magnitude: nil,
            durationSeconds: nil,
            pathWidthKm: nil,
            visibilitySummary: nil
        ),
        Eclipse(
            id: "total",
            saros: 200,
            date: Date(timeIntervalSince1970: 10),
            type: .totalSolar,
            maximumPoint: nil,
            gamma: nil,
            magnitude: nil,
            durationSeconds: nil,
            pathWidthKm: nil,
            visibilitySummary: nil
        ),
        Eclipse(
            id: "annular",
            saros: 200,
            date: Date(timeIntervalSince1970: 20),
            type: .annularSolar,
            maximumPoint: nil,
            gamma: nil,
            magnitude: nil,
            durationSeconds: nil,
            pathWidthKm: nil,
            visibilitySummary: nil
        ),
        Eclipse(
            id: "partial-trailing",
            saros: 200,
            date: Date(timeIntervalSince1970: 30),
            type: .partialSolar,
            maximumPoint: nil,
            gamma: nil,
            magnitude: nil,
            durationSeconds: nil,
            pathWidthKm: nil,
            visibilitySummary: nil
        )
    ]

    func allSarosSeries() throws -> [SarosSeriesSummary] {
        [
            SarosSeriesSummary(
                saros: 200,
                eclipseCount: records.count,
                firstEclipseDate: records[0].date,
                lastEclipseDate: records[records.count - 1].date
            )
        ]
    }

    func allEclipses() throws -> [Eclipse] {
        records
    }

    func eclipses(forSaros saros: Int) throws -> [Eclipse] {
        saros == 200 ? records : []
    }

    func eclipse(withID eclipseID: String) throws -> Eclipse? {
        records.first { $0.id == eclipseID }
    }

    func previousAndNextEclipse(saros: Int, around date: Date) throws -> SarosInterval? {
        guard saros == 200 else { return nil }
        let nextIndex = records.firstIndex { $0.date > date } ?? records.count - 1
        let previousIndex = max(nextIndex - 1, 0)
        guard previousIndex != nextIndex else { return nil }
        let previous = records[previousIndex]
        let next = records[nextIndex]
        let duration = next.date.timeIntervalSince(previous.date)
        return SarosInterval(
            saros: saros,
            previous: previous,
            next: next,
            normalizedPhase: date.timeIntervalSince(previous.date) / duration
        )
    }

    func eclipseBracket(around date: Date) throws -> EclipseBracket? {
        nil
    }

    func nearestEclipse(to date: Date) throws -> Eclipse? {
        records.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    func pathGeometry(for eclipseID: String) throws -> EclipsePathGeometry? {
        nil
    }
}

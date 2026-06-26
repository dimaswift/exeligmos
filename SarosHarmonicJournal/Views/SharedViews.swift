import SwiftUI
import UIKit

enum JournalFormatters {
    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let time: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}

extension Color {
    init(hex: String, fallback: Color = .green) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let value = UInt64(raw, radix: 16) else {
            self = fallback
            return
        }

        let red: Double
        let green: Double
        let blue: Double
        switch raw.count {
        case 3:
            red = Double((value >> 8) & 0xF) / 15
            green = Double((value >> 4) & 0xF) / 15
            blue = Double(value & 0xF) / 15
        default:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        }
        self = Color(red: red, green: green, blue: blue)
    }

    var hexRGBString: String {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#00D084"
        }

        return String(
            format: "#%02X%02X%02X",
            Int(red * 255),
            Int(green * 255),
            Int(blue * 255)
        )
    }
}

enum JournalRecordMarkers {
    static let fallback = "✦"

    private static let emojiRanges: [ClosedRange<Int>] = [
        0x1F300...0x1F5FF,
        0x1F600...0x1F64F,
        0x1F900...0x1F9FF
    ]

    static func random() -> String {
        let randomRange = emojiRanges.randomElement()!
        let randomScalar = UnicodeScalar(randomRange.randomElement()!)!
        return String(randomScalar)
    }

    static func marker(from value: String?) -> String {
        value.nilIfBlank ?? fallback
    }
}

enum JournalSettings {
    static let harmonicDepthKey = "harmonicDepth"
    static let notificationRarityPreferencesKey = "notificationRarityPreferences"
    static let catalogStartCenturyKey = "catalogStartCentury"
    static let catalogEndCenturyKey = "catalogEndCentury"
    static let syncServerURLKey = "syncServerURL"
    static let autoSyncEnabledKey = "autoSyncEnabled"
    static let deviceIDKey = "syncDeviceID"
    static let deviceNameKey = "syncDeviceName"
    static let deviceEmojiKey = "syncDeviceEmoji"
    static let pulseSarosKey = "pulseSaros"
    static let lastWeatherCodeKey = "lastWeatherCode"
    static let lastWeatherEmojiKey = "lastWeatherEmoji"
    static let lastWeatherTemperatureKey = "lastWeatherTemperatureC"
    static let cameraPositionKey = "camera.position"
    static let cameraBackLensKey = "camera.backLens"
    static let cameraMirrorModeKey = "camera.mirrorMode"
    static let cameraReflectionSelectionKey = "camera.reflectionSelection"
    static let cameraLensPositionKey = "camera.lensPosition"
    static let cameraExposureLevelKey = "camera.exposureLevel"
    static let cameraThresholdLevelKey = "camera.thresholdLevel"
    static let cameraBinaryFilterEnabledKey = "camera.binaryFilterEnabled"
    static let cameraFocusManualKey = "camera.focusManual"
    static let cameraExposureManualKey = "camera.exposureManual"
    static let cameraTimedVideoDurationKey = "camera.timedVideoDuration"
    static let cameraTimedVideoForwardEnabledKey = "camera.timedVideoForwardEnabled"
    static let cameraTimedVideoBackwardEnabledKey = "camera.timedVideoBackwardEnabled"
    static let defaultHarmonicDepth = 7
    static let canonicalHarmonicDepth = 8
    static let defaultCatalogStartCentury = 20
    static let defaultCatalogEndCentury = 21
    static let supportedHarmonicDepth = 3...8
    static let supportedCatalogCenturies = 1...30
    static let averageSarosPeriod: TimeInterval = 6_585.3211 * 24 * 60 * 60

    static func clampedHarmonicDepth(_ value: Int) -> Int {
        min(max(value, supportedHarmonicDepth.lowerBound), supportedHarmonicDepth.upperBound)
    }

    static func canonicalOctalAddress(_ value: String, storedDepth rawDepth: Int) -> String {
        octalAddress(value, storedDepth: rawDepth, outputDepth: canonicalHarmonicDepth, rightPad: "0")
    }

    static func rarityOctalAddress(
        _ value: String,
        storedDepth rawDepth: Int,
        rarity: FlipRarity,
        outputDepth rawOutputDepth: Int = canonicalHarmonicDepth
    ) -> String {
        let pad = rarity.repeatedDigit > 0 ? Character(String(rarity.repeatedDigit)) : "0"
        return octalAddress(value, storedDepth: rawDepth, outputDepth: rawOutputDepth, rightPad: pad)
    }

    private static func octalAddress(
        _ value: String,
        storedDepth rawDepth: Int,
        outputDepth rawOutputDepth: Int,
        rightPad pad: Character
    ) -> String {
        let depth = clampedHarmonicDepth(rawDepth)
        let outputDepth = min(max(rawOutputDepth, supportedHarmonicDepth.lowerBound), canonicalHarmonicDepth)
        let digits = String(value.filter { "01234567".contains($0) })
        if digits.count >= outputDepth {
            return String(digits.prefix(outputDepth))
        }
        let paddedToStoredDepth = digits.rightPadded(toLength: min(depth, outputDepth), withPad: pad)
        return paddedToStoredDepth.rightPadded(toLength: outputDepth, withPad: pad)
    }

    static func displayOctalAddress(_ value: String, storedDepth: Int, displayDepth rawDisplayDepth: Int) -> String {
        let displayDepth = clampedHarmonicDepth(rawDisplayDepth)
        return String(canonicalOctalAddress(value, storedDepth: storedDepth).prefix(displayDepth))
    }

    static func clampedCatalogCentury(_ value: Int) -> Int {
        min(max(value, supportedCatalogCenturies.lowerBound), supportedCatalogCenturies.upperBound)
    }

    static func centuryLabel(_ century: Int) -> String {
        let suffix: String
        switch century % 100 {
        case 11, 12, 13:
            suffix = "th"
        default:
            switch century % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(century)\(suffix)"
    }
}

enum SarosPulseUnit: String, CaseIterable, Identifiable, Hashable {
    case rollover
    case giga
    case mega
    case kilo
    case saros
    case mili
    case nano

    var id: String { rawValue }

    static let glyphUnits: [SarosPulseUnit] = [.giga, .mega, .kilo, .saros, .mili, .nano]
    static let rulerUnits: [SarosPulseUnit] = [.rollover, .giga, .mega, .kilo]
    static let referenceUnits: [SarosPulseUnit] = [.rollover] + glyphUnits

    var title: String {
        switch self {
        case .rollover: "Rollover"
        case .giga: "Giga"
        case .mega: "Mega"
        case .kilo: "Kilo"
        case .saros: "Saros"
        case .mili: "Milisaros"
        case .nano: "Nanosaros"
        }
    }

    var exponent: Int {
        switch self {
        case .rollover: 3
        case .giga: 4
        case .mega: 5
        case .kilo: 6
        case .saros: 7
        case .mili: 8
        case .nano: 9
        }
    }

    var pattern: String {
        switch self {
        case .rollover: "000000"
        case .giga: "X00000"
        case .mega: "XX0000"
        case .kilo: "XXX000"
        case .saros: "XXXX00"
        case .mili: "XXXXX0"
        case .nano: "XXXXXX"
        }
    }

    var isRulerTick: Bool {
        Self.rulerUnits.contains(self)
    }

    var showsTickLabel: Bool {
        self == .giga
    }

    var color: Color {
        switch self {
        case .rollover: .red
        case .giga: .yellow
        case .mega: .purple
        case .kilo: .blue
        case .saros: .white
        case .mili: .orange
        case .nano: .cyan
        }
    }

    var tickHeight: CGFloat {
        switch self {
        case .rollover: 58
        case .giga: 48
        case .mega: 34
        case .kilo: 22
        case .saros, .mili, .nano: 0
        }
    }
}

struct SarosPulseTick: Identifiable, Hashable {
    let saros: Int
    let unit: SarosPulseUnit
    let digit: Int
    let date: Date

    var id: String {
        "\(saros)-\(unit.id)-\(digit)-\(Int(date.timeIntervalSince1970))"
    }
}

struct SarosPulseReading: Hashable {
    let saros: Int
    let octalAddress: String
    let glyphDepth: Int
    let values: [SarosPulseUnit: Int]

    var trailingZeroCount: Int {
        octalAddress.reversed().prefix { $0 == "0" }.count
    }

    var color: Color {
        switch trailingZeroCount {
        case 0...1: .white
        case 2: .blue
        case 3: .purple
        case 4: .yellow
        default: .red
        }
    }

    var glyphStyle: OctalGlyphStyle {
        .single(color)
    }

    var accessibilityTitle: String {
        SarosPulseUnit.glyphUnits
            .compactMap { unit in
                values[unit].map { "\($0) \(unit.title)" }
            }
            .joined(separator: ", ")
    }
}

struct SarosPulseGlyph: View {
    let reading: SarosPulseReading
    var size: CGFloat

    var body: some View {
        OctalGlyph(
            value: reading.octalAddress,
            depth: reading.glyphDepth,
            style: reading.glyphStyle
        )
        .frame(width: size, height: size)
        .accessibilityLabel(reading.accessibilityTitle)
    }
}

enum SarosPulseCalculator {
    static let pulseDepth = 6
    private static let parentExponent = 3
    private static let pulseBinCount = octalPower(pulseDepth)
    private static let parentBinCount = octalPower(parentExponent)

    static func defaultActiveSaros(
        at date: Date,
        eclipseService: any EclipseService
    ) throws -> Int? {
        try eclipseService.allSarosSeries()
            .filter { $0.firstEclipseDate < date && $0.lastEclipseDate > date }
            .map(\.saros)
            .sorted()
            .first
    }

    static func reading(
        saros: Int,
        date: Date,
        harmonicDepth rawHarmonicDepth: Int,
        eclipseService: any EclipseService
    ) throws -> SarosPulseReading {
        let harmonicDepth = JournalSettings.clampedHarmonicDepth(rawHarmonicDepth)
        guard saros > 0,
              let interval = try eclipseService.previousAndNextEclipse(saros: saros, around: date)
        else {
            return SarosPulseReading(
                saros: saros,
                octalAddress: "",
                glyphDepth: Self.pulseDepth,
                values: [:]
            )
        }

        let reading = try SarosClockCalculator.reading(
            saros: saros,
            previous: interval.previous,
            next: interval.next,
            now: date,
            harmonicDepth: harmonicDepth
        )

        let localPhase = (reading.phase * Double(Self.parentBinCount))
            .truncatingRemainder(dividingBy: 1)
        let pulseIndex = min(
            Int(floor(localPhase * Double(Self.pulseBinCount))),
            Self.pulseBinCount - 1
        )
        let octalAddress = String(pulseIndex, radix: 8)
            .leftPadded(toLength: Self.pulseDepth, withPad: "0")
        let digits = Array(octalAddress)
        let values = SarosPulseUnit.glyphUnits.enumerated().reduce(into: [SarosPulseUnit: Int]()) { values, pair in
            let (index, unit) = pair
            guard digits.indices.contains(index),
                  let digit = Int(String(digits[index]))
            else {
                return
            }
            values[unit] = digit
        }

        return SarosPulseReading(
            saros: saros,
            octalAddress: octalAddress,
            glyphDepth: Self.pulseDepth,
            values: values
        )
    }

    static func ticks(
        in displayInterval: DateInterval,
        saros: Int,
        harmonicDepth rawHarmonicDepth: Int,
        eclipseService: any EclipseService
    ) throws -> [SarosPulseTick] {
        guard saros > 0 else { return [] }

        var ticks: [SarosPulseTick] = []
        var probeDate = displayInterval.start
        var visitedIntervals = Set<String>()

        for _ in 0..<4 {
            guard probeDate < displayInterval.end,
                  let interval = try eclipseService.previousAndNextEclipse(saros: saros, around: probeDate)
            else {
                break
            }

            let key = "\(interval.previous.id)-\(interval.next.id)"
            guard visitedIntervals.insert(key).inserted else { break }

            appendTicks(
                in: displayInterval,
                saros: saros,
                interval: interval,
                into: &ticks
            )

            probeDate = interval.next.date.addingTimeInterval(1)
        }

        return ticks.sorted { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date < rhs.date
            }
            return lhs.unit.exponent < rhs.unit.exponent
        }
    }

    static func averageDuration(for unit: SarosPulseUnit) -> TimeInterval {
        JournalSettings.averageSarosPeriod / Double(octalPower(unit.exponent))
    }

    private static func appendTicks(
        in displayInterval: DateInterval,
        saros: Int,
        interval: SarosInterval,
        into ticks: inout [SarosPulseTick]
    ) {
        let segmentStart = max(displayInterval.start, interval.previous.date)
        let segmentEnd = min(displayInterval.end, interval.next.date)
        guard segmentStart < segmentEnd else { return }

        let intervalDuration = interval.next.date.timeIntervalSince(interval.previous.date)
        guard intervalDuration > 0 else { return }

        for unit in SarosPulseUnit.rulerUnits {
            let divisions = octalPower(unit.exponent)
            let startPhase = segmentStart.timeIntervalSince(interval.previous.date) / intervalDuration
            var bin = max(Int(ceil(startPhase * Double(divisions))), 0)

            while bin <= divisions {
                let date = interval.previous.date.addingTimeInterval(Double(bin) / Double(divisions) * intervalDuration)
                if date >= segmentEnd { break }

                let digit = bin % 8
                let shouldAdd = unit == .rollover ? true : digit > 0
                if date >= segmentStart, shouldAdd {
                    ticks.append(
                        SarosPulseTick(
                            saros: saros,
                            unit: unit,
                            digit: digit,
                            date: date
                        )
                    )
                }

                bin += 1
            }
        }
    }

    private static func octalPower(_ exponent: Int) -> Int {
        guard exponent > 0 else { return 1 }
        return (0..<exponent).reduce(1) { value, _ in value * 8 }
    }
}

struct FlipRarityGroup: Identifiable, Hashable {
    let header: FlipRarity
    let subrarities: [FlipRarity]

    var id: String { header.id }
}

enum FlipRarity: Codable, CaseIterable, Identifiable, Comparable, Hashable, RawRepresentable, Sendable {
    case common
    case rare
    case rareDigit(Int)
    case epic
    case epicDigit(Int)
    case legendary
    case legendaryDigit(Int)
    case mythic
    case mythicDigit(Int)

    static let baseRarities: [FlipRarity] = [
        .common,
        .rare,
        .epic,
        .legendary,
        .mythic
    ]

    static let eventBaseRarities: [FlipRarity] = [
        .rare,
        .epic,
        .legendary,
        .mythic
    ]

    static let allCases: [FlipRarity] = [.common] + eventBaseRarities.flatMap { rarity in
        [rarity] + rarity.subrarities
    }

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .common: "common"
        case .rare: "rare"
        case .rareDigit(let digit): "rare-\(Self.clampedDigit(digit))"
        case .epic: "epic"
        case .epicDigit(let digit): "epic-\(Self.clampedDigit(digit))"
        case .legendary: "legendary"
        case .legendaryDigit(let digit): "legendary-\(Self.clampedDigit(digit))"
        case .mythic: "mythic"
        case .mythicDigit(let digit): "mythic-\(Self.clampedDigit(digit))"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "common": self = .common
        case "rare": self = .rare
        case "epic": self = .epic
        case "legendary": self = .legendary
        case "mythic": self = .mythic
        case "saros": self = .mythicDigit(7)
        case "saros0": self = .mythicDigit(7)
        case "saros1": self = .mythicDigit(1)
        case "saros2": self = .mythicDigit(2)
        case "saros3": self = .mythicDigit(3)
        case "saros4": self = .mythicDigit(4)
        case "saros5": self = .mythicDigit(5)
        case "saros6": self = .mythicDigit(6)
        case "saros7": self = .mythicDigit(7)
        default:
            let parts = rawValue.split(separator: "-", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let digit = Int(parts[1]),
                  (1...7).contains(digit)
            else {
                return nil
            }

            switch parts[0] {
            case "rare": self = .rareDigit(digit)
            case "epic": self = .epicDigit(digit)
            case "legendary": self = .legendaryDigit(digit)
            case "mythic": self = .mythicDigit(digit)
            case "saros":
                self = .mythicDigit(digit)
            default:
                return nil
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let rarity = FlipRarity(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown flip rarity \(rawValue)."
            )
        }
        self = rarity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var order: Int {
        switch self {
        case .common: 0
        case .rare, .rareDigit: 3
        case .epic, .epicDigit: 4
        case .legendary, .legendaryDigit: 5
        case .mythic, .mythicDigit: 6
        }
    }

    var rank: Int {
        guard self != .common else { return 0 }
        return order * 8 + repeatedDigit
    }

    var title: String {
        switch self {
        case .common: "Common"
        case .rare: "Triplex"
        case .rareDigit(let digit): "\(Self.digitPrefix(digit)) Triplex"
        case .epic: "Duplex"
        case .epicDigit(let digit): "\(Self.digitPrefix(digit)) Duplex"
        case .legendary: "Simplex"
        case .legendaryDigit(let digit): "\(Self.digitPrefix(digit)) Simplex"
        case .mythic: "Nihil"
        case .mythicDigit(let digit): "\(Self.digitPrefix(digit)) Nihil"
        }
    }

    var symbolName: String {
        switch baseRarity {
        case .rare: "diamond"
        case .epic: "sparkles"
        case .legendary: "crown"
        case .mythic: "flame"
        default: "circle.fill"
        }
    }

    var color: Color {
        primaryColor
    }

    var primaryColor: Color {
        if case .mythicDigit(let digit) = self, digit == 7 {
            return .red
        }

        switch baseRarity {
        case .common: return .white
        case .rare: return .gray
        case .epic: return .blue
        case .legendary: return .purple
        case .mythic: return .yellow
        default: return .blue
        }
    }

    var secondaryColor: Color {
        primaryColor
    }

    var notificationEligible: Bool {
        self != .common
    }

    var orderLabel: String {
        title
    }

    var repeatedDigit: Int {
        switch self {
        case .common, .rare, .epic, .legendary, .mythic:
            return 0
        case .rareDigit(let digit), .epicDigit(let digit), .legendaryDigit(let digit), .mythicDigit(let digit):
            return Self.clampedDigit(digit)
        }
    }

    var baseRarity: FlipRarity {
        switch self {
        case .common: .common
        case .rare, .rareDigit: .rare
        case .epic, .epicDigit: .epic
        case .legendary, .legendaryDigit: .legendary
        case .mythic, .mythicDigit: .mythic
        }
    }

    var isHeaderRarity: Bool {
        self != .common && repeatedDigit == 0
    }

    var subrarities: [FlipRarity] {
        guard self != .common else { return [] }
        return (1...7).map { digit in
            Self.rarity(order: order, repeatedDigit: digit)
        }
    }

    var suffixPattern: String {
        guard repeatedDigit > 0 else { return title }
        return String(repeating: "\(repeatedDigit)", count: max(order, 1))
    }

    var wildcardPrefixCount: Int {
        switch baseRarity {
        case .common: JournalSettings.defaultHarmonicDepth
        case .rare: 3
        case .epic: 2
        case .legendary: 1
        case .mythic: 0
        default: 3
        }
    }

    var basePeriodDivisions: Int {
        Self.octalPower(wildcardPrefixCount)
    }

    func supports(harmonicDepth rawDepth: Int) -> Bool {
        guard self != .common else { return false }
        return JournalSettings.clampedHarmonicDepth(rawDepth) > wildcardPrefixCount
    }

    func repeatedSuffixLength(harmonicDepth rawDepth: Int) -> Int {
        max(JournalSettings.clampedHarmonicDepth(rawDepth) - wildcardPrefixCount, 0)
    }

    func repeatedSuffixPattern(harmonicDepth rawDepth: Int) -> String {
        guard repeatedDigit > 0 else { return "" }
        return String(repeating: "\(repeatedDigit)", count: repeatedSuffixLength(harmonicDepth: rawDepth))
    }

    func patternLabel(harmonicDepth rawDepth: Int) -> String {
        guard self != .common else { return title }
        guard repeatedDigit > 0 else { return title }
        let depth = JournalSettings.clampedHarmonicDepth(rawDepth)
        let wildcardCount = min(wildcardPrefixCount, depth)
        return String(repeating: "X", count: wildcardCount) + repeatedSuffixPattern(harmonicDepth: depth)
    }

    func glyphAddress(harmonicDepth rawDepth: Int) -> String {
        let depth = JournalSettings.clampedHarmonicDepth(rawDepth)
        guard self != .common else {
            return String(repeating: "0", count: depth)
        }
        let prefixCount = min(wildcardPrefixCount, depth)
        let digit = repeatedDigit > 0 ? repeatedDigit : 7
        let suffixLength = max(depth - prefixCount, 0)
        return String(repeating: "0", count: prefixCount)
            + String(repeating: "\(digit)", count: suffixLength)
    }

    func binStride(harmonicDepth rawDepth: Int) -> Int? {
        guard self != .common else { return nil }
        let suffixLength = repeatedSuffixLength(harmonicDepth: rawDepth)
        guard suffixLength > 0 else { return nil }
        return Self.octalPower(suffixLength)
    }

    func subeventOffset(harmonicDepth rawDepth: Int) -> Int? {
        guard let stride = binStride(harmonicDepth: rawDepth) else { return nil }
        guard repeatedDigit > 0 else { return 0 }
        return repeatedDigit * ((max(stride, 1) - 1) / 7)
    }

    var glyphStyle: OctalGlyphStyle {
        .single(primaryColor)
    }

    func patternAddress(depth: Int) -> String? {
        let clampedDepth = JournalSettings.clampedHarmonicDepth(depth)
        guard supports(harmonicDepth: clampedDepth) else { return nil }
        let suffix = repeatedDigit > 0
            ? repeatedSuffixPattern(harmonicDepth: clampedDepth)
            : String(repeating: "0", count: repeatedSuffixLength(harmonicDepth: clampedDepth))
        return String(repeating: "0", count: wildcardPrefixCount) + suffix
    }

    static func < (lhs: FlipRarity, rhs: FlipRarity) -> Bool {
        lhs.rank < rhs.rank
    }

    static func rarity(forOrder order: Int, isEclipse: Bool = false) -> FlipRarity {
        guard isEclipse else { return .common }
        return rarity(order: 6, repeatedDigit: 7)
    }

    static func rarity(forOctalAddress octalAddress: String, harmonicDepth: Int, isEclipse: Bool = false) -> FlipRarity {
        if isEclipse {
            return .mythicDigit(7)
        }

        let depth = JournalSettings.clampedHarmonicDepth(harmonicDepth)
        let pattern = repeatedSuffixPattern(for: octalAddress, harmonicDepth: depth)
        guard pattern.digit > 0 else { return .common }

        return rarity(order: pattern.order, repeatedDigit: pattern.digit)
    }

    static func order(forOctalAddress octalAddress: String, harmonicDepth: Int) -> Int {
        let pattern = repeatedSuffixPattern(for: octalAddress, harmonicDepth: harmonicDepth)
        return pattern.digit > 0 ? pattern.order : 0
    }

    static func repeatedDigit(forOctalAddress octalAddress: String, harmonicDepth: Int) -> Int {
        repeatedSuffixPattern(for: octalAddress, harmonicDepth: harmonicDepth).digit
    }

    static func visibleRarities(for harmonicDepth: Int, includeSubrarities: Bool = true) -> [FlipRarity] {
        rarityGroups(for: harmonicDepth, includeSubrarities: includeSubrarities).flatMap { group in
            [group.header] + group.subrarities
        }
    }

    static func eventRarities(for harmonicDepth: Int) -> [FlipRarity] {
        rarityGroups(for: harmonicDepth).flatMap(\.subrarities)
    }

    static func rarityGroups(for harmonicDepth: Int, includeSubrarities: Bool = true) -> [FlipRarityGroup] {
        let depth = JournalSettings.clampedHarmonicDepth(harmonicDepth)
        return eventBaseRarities
            .filter { $0.supports(harmonicDepth: depth) }
            .map { header in
                FlipRarityGroup(
                    header: header,
                    subrarities: includeSubrarities ? header.subrarities : []
                )
            }
    }

    static func subrarities(for rarity: FlipRarity) -> [FlipRarity] {
        rarity.baseRarity.subrarities
    }

    static func notificationRarities(for harmonicDepth: Int) -> [FlipRarity] {
        eventRarities(for: harmonicDepth)
            .filter(\.notificationEligible)
    }

    static func rarity(order rawOrder: Int, repeatedDigit rawDigit: Int) -> FlipRarity {
        let order = min(max(rawOrder, 3), 6)
        let digit = clampedDigit(rawDigit)
        switch order {
        case 3: return digit == 0 ? .rare : .rareDigit(digit)
        case 4: return digit == 0 ? .epic : .epicDigit(digit)
        case 5: return digit == 0 ? .legendary : .legendaryDigit(digit)
        default: return digit == 0 ? .mythic : .mythicDigit(digit)
        }
    }

    static func repeatedDigitValue(order rawOrder: Int, digit rawDigit: Int) -> Int {
        let order = min(max(rawOrder, 1), JournalSettings.supportedHarmonicDepth.upperBound)
        let digit = clampedDigit(rawDigit)
        let placeSum = (0..<order).reduce(0) { value, _ in value * 8 + 1 }
        return digit * placeSum
    }

    private static func repeatedSuffixPattern(for octalAddress: String, harmonicDepth: Int) -> (order: Int, digit: Int) {
        let depth = JournalSettings.clampedHarmonicDepth(harmonicDepth)
        let digits = octalAddress.filter { "01234567".contains($0) }
        let trimmed = String(digits.prefix(depth))
        var padded = trimmed.leftPadded(toLength: depth, withPad: "0")
        guard !padded.isEmpty else {
            return (3, 0)
        }

        if (Int(padded, radix: 8) ?? 0) == 0 {
            return (6, 7)
        }

        if padded.last == "0",
           let value = Int(padded, radix: 8),
           value > 0
        {
            padded = String(value - 1, radix: 8).leftPadded(toLength: depth, withPad: "0")
        }

        let characters = Array(padded)
        guard let last = characters.last,
              last != "0",
              let digit = Int(String(last))
        else {
            return (3, 0)
        }

        let suffixLength = characters.reversed().prefix { $0 == last }.count
        let wildcardPrefixCount = depth - suffixLength
        let order = switch wildcardPrefixCount {
        case ...0: 6
        case 1: 5
        case 2: 4
        case 3: 3
        default: 3
        }
        return (order, wildcardPrefixCount <= 3 ? digit : 0)
    }

    static func digitColor(_ digit: Int) -> Color {
        switch clampedDigit(digit) {
        case 0: .white
        case 1: Self.rainbowRed
        case 2: Self.rainbowOrange
        case 3: Self.rainbowYellow
        case 4: Self.rainbowGreen
        case 5: Self.rainbowCyan
        case 6: Self.rainbowBlue
        case 7: Self.rainbowViolet
        default: .white
        }
    }

    private static func clampedDigit(_ digit: Int) -> Int {
        min(max(digit, 0), 7)
    }

    private static func digitPrefix(_ digit: Int) -> String {
        switch clampedDigit(digit) {
        case 1: "Alpha"
        case 2: "Beta"
        case 3: "Gamma"
        case 4: "Delta"
        case 5: "Epsilon"
        case 6: "Digamma"
        case 7: "Omega"
        default: ""
        }
    }

    private static func octalPower(_ exponent: Int) -> Int {
        guard exponent > 0 else { return 1 }
        return (0..<exponent).reduce(1) { value, _ in value * 8 }
    }

    private static let rainbowRed = Color(red: 1.0, green: 0.23, blue: 0.19)
    private static let rainbowOrange = Color(red: 1.0, green: 0.58, blue: 0.0)
    private static let rainbowYellow = Color(red: 1.0, green: 0.84, blue: 0.04)
    private static let rainbowGreen = Color(red: 0.20, green: 0.84, blue: 0.29)
    private static let rainbowCyan = Color(red: 0.20, green: 0.78, blue: 1.0)
    private static let rainbowBlue = Color(red: 0.25, green: 0.50, blue: 1.0)
    private static let rainbowViolet = Color(red: 0.67, green: 0.34, blue: 1.0)
}

struct CatalogCenturyBounds: Hashable {
    let startCentury: Int
    let endCentury: Int

    init(startCentury: Int, endCentury: Int) {
        let start = JournalSettings.clampedCatalogCentury(startCentury)
        let end = JournalSettings.clampedCatalogCentury(endCentury)
        self.startCentury = min(start, end)
        self.endCentury = max(start, end)
    }

    var startDate: Date {
        Self.date(year: (startCentury - 1) * 100 + 1)
    }

    var endDate: Date {
        Self.date(year: endCentury * 100 + 1)
    }

    var displayTitle: String {
        if startCentury == endCentury {
            "\(JournalSettings.centuryLabel(startCentury)) century"
        } else {
            "\(JournalSettings.centuryLabel(startCentury))-\(JournalSettings.centuryLabel(endCentury)) centuries"
        }
    }

    func contains(_ date: Date) -> Bool {
        date >= startDate && date < endDate
    }

    private static func date(year: Int) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = 1
        components.day = 1
        return calendar.date(from: components) ?? .distantPast
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
}

enum FlipNotificationMode: String, Codable, CaseIterable, Identifiable {
    case silent
    case event
    case live
    case alarm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .silent: "Silent"
        case .event: "At flip"
        case .live: "Live"
        case .alarm: "Alarm"
        }
    }

    var symbolName: String {
        switch self {
        case .silent: "bell.slash"
        case .event: "bell"
        case .live: "timer"
        case .alarm: "alarm"
        }
    }

    var usesAdvanceTime: Bool {
        switch self {
        case .silent, .event: false
        case .live, .alarm: true
        }
    }
}

struct FlipNotificationRarityPreference: Codable, Hashable, Identifiable {
    let rarity: FlipRarity
    var mode: FlipNotificationMode
    var advanceMinutes: Int

    var id: String { rarity.id }
}

enum FlipNotificationPreferences {
    static func defaults(for harmonicDepth: Int) -> [FlipNotificationRarityPreference] {
        let depth = JournalSettings.clampedHarmonicDepth(harmonicDepth)
        return FlipRarity.notificationRarities(for: depth).map { rarity in
            let mode: FlipNotificationMode = switch rarity.baseRarity {
            case .rare: .event
            case .epic: .live
            case .legendary, .mythic: .alarm
            default: .silent
            }
            let advanceMinutes = switch rarity.baseRarity {
            case .epic: 30
            case .legendary: 60
            case .mythic: 120
            default: 10
            }
            return FlipNotificationRarityPreference(
                rarity: rarity,
                mode: mode,
                advanceMinutes: advanceMinutes
            )
        }
    }

    static func load(for harmonicDepth: Int) -> [FlipNotificationRarityPreference] {
        guard
            let data = UserDefaults.standard.string(forKey: JournalSettings.notificationRarityPreferencesKey)?.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([FlipNotificationRarityPreference].self, from: data)
        else {
            return defaults(for: harmonicDepth)
        }

        return merged(decoded, harmonicDepth: harmonicDepth)
    }

    static func save(_ preferences: [FlipNotificationRarityPreference]) {
        guard let data = try? JSONEncoder().encode(preferences),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        UserDefaults.standard.set(json, forKey: JournalSettings.notificationRarityPreferencesKey)
    }

    static func order(forOctalAddress octalAddress: String, harmonicDepth: Int) -> Int {
        FlipRarity.order(forOctalAddress: octalAddress, harmonicDepth: harmonicDepth)
    }

    static func rarity(forOctalAddress octalAddress: String, harmonicDepth: Int, isEclipse: Bool = false) -> FlipRarity {
        FlipRarity.rarity(
            forOctalAddress: octalAddress,
            harmonicDepth: harmonicDepth,
            isEclipse: isEclipse
        )
    }

    private static func merged(
        _ decoded: [FlipNotificationRarityPreference],
        harmonicDepth: Int
    ) -> [FlipNotificationRarityPreference] {
        let decodedByRarity = Dictionary(uniqueKeysWithValues: decoded.map { ($0.rarity, $0) })
        return defaults(for: harmonicDepth).map { fallback in
            guard var preference = decodedByRarity[fallback.rarity] else {
                return fallback
            }
            preference.advanceMinutes = min(max(preference.advanceMinutes, 0), 24 * 60)
            return preference
        }
    }
}

struct PhaseRing: View {
    let progress: Double
    let lineWidth: CGFloat

    init(progress: Double, lineWidth: CGFloat = 6) {
        self.progress = min(max(progress, 0), 1)
        self.lineWidth = lineWidth
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.cyan, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 42, height: 42)
        .accessibilityLabel("Phase progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

struct OctalGlyphStyle {
    let primary: Color
    let secondary: Color
    let splitAfterDigitCount: Int?

    var isSingleColor: Bool {
        splitAfterDigitCount == nil
    }

    static func single(_ color: Color) -> OctalGlyphStyle {
        OctalGlyphStyle(primary: color, secondary: color, splitAfterDigitCount: nil)
    }

    static func split(primary: Color, secondary: Color, splitAfterDigitCount: Int) -> OctalGlyphStyle {
        OctalGlyphStyle(
            primary: primary,
            secondary: secondary,
            splitAfterDigitCount: splitAfterDigitCount
        )
    }

    func color(forDigitIndex digitIndex: Int) -> Color {
        guard let splitAfterDigitCount else {
            return primary
        }
        return digitIndex < splitAfterDigitCount ? primary : secondary
    }
}

struct OctalGlyph: View {
    let value: String
    let depth: Int
    var style: OctalGlyphStyle

    init(value: String, depth: Int = JournalSettings.defaultHarmonicDepth, color: Color = .cyan) {
        self.value = value
        self.depth = JournalSettings.clampedHarmonicDepth(depth)
        self.style = .single(color)
    }

    init(value: String, depth: Int = JournalSettings.defaultHarmonicDepth, style: OctalGlyphStyle) {
        self.value = value
        self.depth = JournalSettings.clampedHarmonicDepth(depth)
        self.style = style
    }

    init(value: String, depth: Int = JournalSettings.defaultHarmonicDepth, rarity: FlipRarity) {
        self.value = value
        self.depth = JournalSettings.clampedHarmonicDepth(depth)
        self.style = rarity.glyphStyle
    }

    var body: some View {
        let geometry = OctalGlyphGeometryCache.geometry(for: depth)

        ZStack {
            OctalGlyphCoreShape(depth: depth)
                .fill(style.secondary, style: FillStyle(eoFill: true))

            if style.isSingleColor {
                OctalGlyphArmShape(value: value, depth: depth)
                    .fill(style.primary)
            } else {
                ForEach(0..<geometry.digitCount, id: \.self) { socketIndex in
                    OctalGlyphArmSegmentShape(value: value, depth: depth, socketIndex: socketIndex)
                        .fill(style.color(forDigitIndex: geometry.digitIndex(forSocketIndex: socketIndex)))
                }
            }
        }
        .aspectRatio(geometry.aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Octal glyph")
        .accessibilityValue(geometry.normalizedOctal(value))
    }
}

struct FlipRarityBadge: View {
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    let rarity: FlipRarity
    var compact = false

    var body: some View {
        Group {
            if rarity == .common {
                EmptyView()
            } else if compact {
                FlipRarityGlyphIcon(rarity: rarity, harmonicDepth: harmonicDepth, size: 18)
            } else {
                HStack(spacing: 5) {
                    FlipRarityGlyphIcon(rarity: rarity, harmonicDepth: harmonicDepth, size: 18)
                    Text(rarity.title)
                }
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(rarity.color)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 3)
        .background(rarity.color.opacity(0.14), in: Capsule())
        .overlay {
            Capsule()
                .stroke(rarity.color.opacity(0.28), lineWidth: 1)
        }
        .accessibilityLabel(rarity.title)
    }
}

struct FlipRarityGlyphIcon: View {
    let rarity: FlipRarity
    let harmonicDepth: Int
    var size: CGFloat = 18

    var body: some View {
        if rarity == .common {
            EmptyView()
        } else {
            OctalGlyph(
                value: rarity.glyphAddress(harmonicDepth: harmonicDepth),
                depth: JournalSettings.clampedHarmonicDepth(harmonicDepth),
                style: rarity.glyphStyle
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }
}

struct FlipRarityEventSelector: View {
    let harmonicDepth: Int
    @Binding var baseRarity: FlipRarity
    @Binding var selectedRarity: FlipRarity
    var selectedRarities: Set<FlipRarity> = []
    var onSelect: (FlipRarity) -> Void

    private var depth: Int {
        JournalSettings.clampedHarmonicDepth(harmonicDepth)
    }

    private var baseOptions: [FlipRarity] {
        FlipRarity.eventBaseRarities.filter { $0.supports(harmonicDepth: depth) }
    }

    private var activeBase: FlipRarity {
        let base = baseRarity.baseRarity
        return baseOptions.contains(base) ? base : baseOptions.first ?? .rare
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(baseOptions) { option in
                    Button {
                        selectBase(option)
                    } label: {
                        rarityGlyph(option, isSelected: activeBase == option)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                }
            }

            HStack(spacing: 7) {
                ForEach(activeBase.subrarities) { option in
                    Button {
                        selectedRarity = option
                        onSelect(option)
                    } label: {
                        rarityGlyph(option, isSelected: isSelected(option))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                }
            }
        }
    }

    private func selectBase(_ option: FlipRarity) {
        baseRarity = option
        let digit = selectedRarity.repeatedDigit > 0 ? selectedRarity.repeatedDigit : 7
        selectedRarity = FlipRarity.rarity(order: option.order, repeatedDigit: digit)
    }

    private func isSelected(_ option: FlipRarity) -> Bool {
        selectedRarities.isEmpty ? selectedRarity == option : selectedRarities.contains(option)
    }

    private func rarityGlyph(_ rarity: FlipRarity, isSelected: Bool) -> some View {
        let foreground: Color = if isSelected {
            rarity.baseRarity == .legendary ? .black : .white
        } else {
            rarity.color
        }

        return OctalGlyph(
            value: rarity.glyphAddress(harmonicDepth: depth),
            depth: depth,
            color: foreground
        )
        .frame(width: 24, height: 24)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(
            (isSelected ? rarity.color.opacity(0.88) : rarity.color.opacity(0.12)),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(rarity.color.opacity(isSelected ? 0 : 0.36), lineWidth: 1)
        }
    }
}

struct MoonPhaseGlyph: View {
    let reading: MoonPhaseOctalReading

    var body: some View {
        OctalGlyph(value: reading.octalAddress, depth: reading.depth, style: reading.rarity.glyphStyle)
            .accessibilityLabel("Moon phase glyph")
            .accessibilityValue(reading.octalAddress)
    }
}

private struct OctalGlyphCoreShape: Shape {
    let depth: Int

    func path(in rect: CGRect) -> Path {
        OctalGlyphGeometryCache.geometry(for: depth).corePath(in: rect)
    }
}

private struct OctalGlyphArmShape: Shape {
    let value: String
    let depth: Int

    func path(in rect: CGRect) -> Path {
        OctalGlyphGeometryCache.geometry(for: depth).armPath(for: value, in: rect)
    }
}

private struct OctalGlyphArmSegmentShape: Shape {
    let value: String
    let depth: Int
    let socketIndex: Int

    func path(in rect: CGRect) -> Path {
        OctalGlyphGeometryCache.geometry(for: depth).armPath(
            for: value,
            socketIndex: socketIndex,
            in: rect
        )
    }
}

private enum OctalGlyphGeometryCache {
    private static let geometries: [Int: OctalGlyphGeometry] = {
        Dictionary(
            uniqueKeysWithValues: JournalSettings.supportedHarmonicDepth.map { depth in
                (depth, OctalGlyphGeometry(depth: depth))
            }
        )
    }()

    static func geometry(for depth: Int) -> OctalGlyphGeometry {
        let clampedDepth = JournalSettings.clampedHarmonicDepth(depth)
        return geometries[clampedDepth] ?? OctalGlyphGeometry(depth: clampedDepth)
    }
}

private struct OctalGlyphSocket {
    let start: CGPoint
    let end: CGPoint
}

private struct OctalGlyphSocketFrame {
    let center: CGPoint
    let tangent: CGPoint
    let outward: CGPoint
    let length: CGFloat
}

private struct OctalGlyphGeometry {
    let digitCount: Int
    let aspectRatio: CGFloat
    private let frameBounds: CGRect
    private let coreTemplatePath: Path
    private let armTemplatePaths: [[Path]]

    init(depth: Int) {
        let digitCount = JournalSettings.clampedHarmonicDepth(depth)
        let sockets = Self.makeSockets(digitCount: digitCount)
        let corePolygon = sockets.flatMap { [$0.start, $0.end] }
        let coreHole = if digitCount == 7 {
            Self.defaultCoreHole
        } else {
            Self.insetConvexPolygon(corePolygon, thickness: 14)
        }
        let frameBounds = Self.makeFrameBounds(
            corePolygon: corePolygon,
            coreHole: coreHole,
            sockets: sockets,
            digitCount: digitCount
        )

        self.digitCount = digitCount
        self.frameBounds = frameBounds
        self.aspectRatio = frameBounds.width / frameBounds.height
        self.coreTemplatePath = Self.path(for: [corePolygon, coreHole])
        self.armTemplatePaths = (0..<digitCount).map { socketIndex in
            (0...7).map { digit in
                let points = Self.armToWorldPoints(
                    Self.arms[digit] ?? [],
                    socketIndex: socketIndex,
                    sockets: sockets
                )
                return points.count >= 3 ? Self.path(for: [points]) : Path()
            }
        }
    }

    private static func makeSockets(digitCount: Int) -> [OctalGlyphSocket] {
        let baseStart = CGPoint(x: -Self.socketWidth / 2, y: -Self.coreRadius)
        let baseEnd = CGPoint(x: Self.socketWidth / 2, y: -Self.coreRadius)
        let rotationStep = 360 / CGFloat(digitCount)

        return (0..<digitCount).map { index in
            let rotation = CGFloat(index) * rotationStep
            return OctalGlyphSocket(
                start: Self.rotate(baseStart, degrees: rotation),
                end: Self.rotate(baseEnd, degrees: rotation)
            )
        }
    }

    private static func makeFrameBounds(
        corePolygon: [CGPoint],
        coreHole: [CGPoint],
        sockets: [OctalGlyphSocket],
        digitCount: Int
    ) -> CGRect {
        var points = corePolygon + coreHole
        points.append(contentsOf: sockets.flatMap { [$0.start, $0.end] })

        for socketIndex in 0..<digitCount {
            for arm in Self.arms.values {
                points.append(
                    contentsOf: Self.armToWorldPoints(
                        arm,
                        socketIndex: socketIndex,
                        sockets: sockets
                    )
                )
            }
        }

        let minX = points.map(\.x).min() ?? -90
        let maxX = points.map(\.x).max() ?? 90
        let minY = points.map(\.y).min() ?? -150
        let maxY = points.map(\.y).max() ?? 90
        let padding = Self.gridSize * Self.paddingCells
        let halfWidth = max(
            Self.gridSize,
            ceil(max(abs(minX), abs(maxX)) / Self.gridSize) * Self.gridSize + padding
        )
        let halfHeight = max(
            Self.gridSize,
            ceil(max(abs(minY), abs(maxY)) / Self.gridSize) * Self.gridSize + padding
        )

        return CGRect(
            x: -halfWidth,
            y: -halfHeight,
            width: halfWidth * 2,
            height: halfHeight * 2
        )
    }

    private static let defaultCoreHole: [CGPoint] = [
        CGPoint(x: 27.95, y: 1.45),
        CGPoint(x: 25.81, y: 10.82),
        CGPoint(x: 16.29, y: 22.75),
        CGPoint(x: 7.63, y: 26.92),
        CGPoint(x: -7.63, y: 26.92),
        CGPoint(x: -16.29, y: 22.75),
        CGPoint(x: -25.81, y: 10.82),
        CGPoint(x: -27.95, y: 1.45)
    ]

    private static let socketWidth: CGFloat = 16
    private static let coreRadius: CGFloat = 41.57
    private static let gridSize: CGFloat = 8
    private static let paddingCells: CGFloat = 2

    private static let arms: [Int: [CGPoint]] = [
        0: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: 8, y: 0)
        ],
        1: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: -24, y: 27.71),
            CGPoint(x: -16, y: 41.57),
            CGPoint(x: 8, y: 0)
        ],
        2: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: -8, y: 96.99),
            CGPoint(x: 0, y: 110.85),
            CGPoint(x: 8, y: 96.99),
            CGPoint(x: 8, y: 0)
        ],
        3: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: -40, y: 55.42),
            CGPoint(x: -8, y: 110.85),
            CGPoint(x: 0, y: 96.99),
            CGPoint(x: -24, y: 55.42),
            CGPoint(x: 8, y: 0)
        ],
        4: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: 16, y: 41.57),
            CGPoint(x: 24, y: 27.71),
            CGPoint(x: 8, y: 0)
        ],
        5: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: -40, y: 55.42),
            CGPoint(x: 24, y: 55.42),
            CGPoint(x: 32, y: 41.57),
            CGPoint(x: -16, y: 41.57),
            CGPoint(x: 8, y: 0)
        ],
        6: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: -8, y: 138.56),
            CGPoint(x: 32, y: 69.28),
            CGPoint(x: 24, y: 55.42),
            CGPoint(x: 8, y: 83.14),
            CGPoint(x: 8, y: 0)
        ],
        7: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: -40, y: 55.42),
            CGPoint(x: 0, y: 124.71),
            CGPoint(x: 32, y: 69.28),
            CGPoint(x: 24, y: 55.42),
            CGPoint(x: 0, y: 96.99),
            CGPoint(x: -24, y: 55.42),
            CGPoint(x: 8, y: 0)
        ]
    ]

    func normalizedOctal(_ value: String) -> String {
        normalizedDigits(value).map(String.init).joined()
    }

    func corePath(in rect: CGRect) -> Path {
        coreTemplatePath.applying(transform(in: rect))
    }

    func armPath(for value: String, in rect: CGRect) -> Path {
        let digits = normalizedDigits(value)
        var path = Path()

        for socketIndex in 0..<digitCount {
            let digit = digits[digitIndex(forSocketIndex: socketIndex)]
            path.addPath(armTemplatePaths[socketIndex][digit])
        }

        return path.applying(transform(in: rect))
    }

    func armPath(for value: String, socketIndex: Int, in rect: CGRect) -> Path {
        guard (0..<digitCount).contains(socketIndex) else { return Path() }

        let digits = normalizedDigits(value)
        let digit = digits[digitIndex(forSocketIndex: socketIndex)]
        return armTemplatePaths[socketIndex][digit].applying(transform(in: rect))
    }

    func digitIndex(forSocketIndex socketIndex: Int) -> Int {
        socketIndex == 0 ? 0 : digitCount - socketIndex
    }

    private func normalizedDigits(_ value: String) -> [Int] {
        var digits: [Int] = []
        digits.reserveCapacity(digitCount)

        for byte in value.utf8 where (48...55).contains(byte) {
            digits.append(Int(byte - 48))
        }

        if digits.count > digitCount {
            digits.removeFirst(digits.count - digitCount)
        }

        if digits.count < digitCount {
            digits.insert(
                contentsOf: repeatElement(0, count: digitCount - digits.count),
                at: 0
            )
        }

        return digits
    }

    private static func path(for polygons: [[CGPoint]]) -> Path {
        var path = Path()

        for polygon in polygons where polygon.count >= 3 {
            guard let first = polygon.first else { continue }

            path.move(to: first)
            for point in polygon.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }

        return path
    }

    private static func armToWorldPoints(
        _ points: [CGPoint],
        socketIndex: Int,
        sockets: [OctalGlyphSocket]
    ) -> [CGPoint] {
        guard points.count >= 2 else { return points }

        let frame = Self.socketFrame(socketIndex, sockets: sockets)
        var aligned = points
        aligned[0] = CGPoint(x: -frame.length / 2, y: 0)
        aligned[aligned.count - 1] = CGPoint(x: frame.length / 2, y: 0)

        return aligned.map { point in
            CGPoint(
                x: frame.center.x + frame.tangent.x * point.x + frame.outward.x * point.y,
                y: frame.center.y + frame.tangent.y * point.x + frame.outward.y * point.y
            )
        }
    }

    private static func socketFrame(_ index: Int, sockets: [OctalGlyphSocket]) -> OctalGlyphSocketFrame {
        let socket = sockets[index]
        let center = Self.midpoint(socket.start, socket.end)
        let dx = socket.end.x - socket.start.x
        let dy = socket.end.y - socket.start.y
        let length = max(hypot(dx, dy), 0.001)
        let tangent = CGPoint(x: dx / length, y: dy / length)
        let centerVector = CGPoint(x: center.x, y: center.y)
        var outward = CGPoint(x: tangent.y, y: -tangent.x)

        if outward.x * centerVector.x + outward.y * centerVector.y < 0 {
            outward = CGPoint(x: -outward.x, y: -outward.y)
        }

        return OctalGlyphSocketFrame(
            center: center,
            tangent: tangent,
            outward: outward,
            length: length
        )
    }

    private func transform(in rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / frameBounds.width, rect.height / frameBounds.height)
        let width = frameBounds.width * scale
        let height = frameBounds.height * scale
        let xOffset = rect.midX - width / 2 - frameBounds.minX * scale
        let yOffset = rect.midY - height / 2 - frameBounds.minY * scale

        return CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: xOffset,
            ty: yOffset
        )
    }

    private static func insetConvexPolygon(_ points: [CGPoint], thickness: CGFloat) -> [CGPoint] {
        guard points.count >= 3, thickness > 0 else { return points }

        let inwardSign: CGFloat = signedArea(points) >= 0 ? 1 : -1
        let lines = points.enumerated().map { index, point in
            let next = points[(index + 1) % points.count]
            let dx = next.x - point.x
            let dy = next.y - point.y
            let length = max(hypot(dx, dy), 0.001)
            let normal = CGPoint(
                x: (-dy / length) * inwardSign,
                y: (dx / length) * inwardSign
            )

            return (
                point: CGPoint(
                    x: point.x + normal.x * thickness,
                    y: point.y + normal.y * thickness
                ),
                direction: CGPoint(x: dx, y: dy)
            )
        }

        return points.enumerated().map { index, point in
            let previous = lines[(index + lines.count - 1) % lines.count]
            let current = lines[index]
            return intersectLines(
                pointA: previous.point,
                directionA: previous.direction,
                pointB: current.point,
                directionB: current.direction
            ) ?? point
        }
    }

    private static func intersectLines(
        pointA: CGPoint,
        directionA: CGPoint,
        pointB: CGPoint,
        directionB: CGPoint
    ) -> CGPoint? {
        let cross = directionA.x * directionB.y - directionA.y * directionB.x
        guard abs(cross) >= 0.000001 else { return nil }

        let delta = CGPoint(x: pointB.x - pointA.x, y: pointB.y - pointA.y)
        let t = (delta.x * directionB.y - delta.y * directionB.x) / cross
        return CGPoint(
            x: pointA.x + directionA.x * t,
            y: pointA.y + directionA.y * t
        )
    }

    private static func signedArea(_ points: [CGPoint]) -> CGFloat {
        points.enumerated().reduce(CGFloat.zero) { area, item in
            let next = points[(item.offset + 1) % points.count]
            return area + item.element.x * next.y - next.x * item.element.y
        }
    }

    private static func rotate(_ point: CGPoint, degrees: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)

        return CGPoint(
            x: point.x * cosine - point.y * sine,
            y: point.x * sine + point.y * cosine
        )
    }

    private static func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(
            x: (first.x + second.x) / 2,
            y: (first.y + second.y) / 2
        )
    }
}

struct MetadataRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

extension TimeInterval {
    var compactDuration: String {
        if self <= 0 {
            return "now"
        }
        return JournalFormatters.time.string(from: self) ?? "\(Int(self / 60))m"
    }
}

extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

extension String {
    var nilIfBlank: String? {
        Optional(self).nilIfBlank
    }
}

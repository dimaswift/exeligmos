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

    private static let choices = [
        "✨", "🌙", "☀️", "🪐", "🌀", "🔥", "🌊", "🌿",
        "🧭", "🔮", "🕯️", "💠", "🎐", "🪞", "⚡️", "🌑"
    ]

    static func random() -> String {
        choices.randomElement() ?? fallback
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
    static let defaultHarmonicDepth = 7
    static let defaultCatalogStartCentury = 20
    static let defaultCatalogEndCentury = 21
    static let supportedHarmonicDepth = 3...8
    static let supportedCatalogCenturies = 1...30
    static let averageSarosPeriod: TimeInterval = 6_585.3211 * 24 * 60 * 60

    static func clampedHarmonicDepth(_ value: Int) -> Int {
        min(max(value, supportedHarmonicDepth.lowerBound), supportedHarmonicDepth.upperBound)
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

enum FlipRarity: String, Codable, CaseIterable, Identifiable, Comparable {
    case common
    case rare
    case epic
    case legendary
    case mythic
    case saros

    var id: String { rawValue }

    var order: Int {
        switch self {
        case .common: 2
        case .rare: 3
        case .epic: 4
        case .legendary: 5
        case .mythic: 6
        case .saros: 7
        }
    }

    var title: String {
        switch self {
        case .common: "Common"
        case .rare: "Rare"
        case .epic: "Epic"
        case .legendary: "Legendary"
        case .mythic: "Mythic"
        case .saros: "Saros"
        }
    }

    var symbolName: String {
        switch self {
        case .common: "circle.fill"
        case .rare: "diamond"
        case .epic: "sparkles"
        case .legendary: "crown"
        case .mythic: "flame"
        case .saros: "leaf.fill"
        }
    }

    var color: Color {
        switch self {
        case .common: .gray
        case .rare: .blue
        case .epic: .purple
        case .legendary: .yellow
        case .mythic: .red
        case .saros: .green
        }
    }

    var notificationEligible: Bool {
        self >= .rare
    }

    var orderLabel: String {
        self == .saros ? "Order 7+" : "Order \(order)"
    }

    static func < (lhs: FlipRarity, rhs: FlipRarity) -> Bool {
        lhs.order < rhs.order
    }

    static func rarity(forOrder order: Int, isEclipse: Bool = false) -> FlipRarity {
        if isEclipse || order >= 7 {
            return .saros
        }

        switch max(order, 1) {
        case 1, 2: return .common
        case 3: return .rare
        case 4: return .epic
        case 5: return .legendary
        case 6: return .mythic
        default: return .saros
        }
    }

    static func order(forOctalAddress octalAddress: String, harmonicDepth: Int) -> Int {
        let depth = JournalSettings.clampedHarmonicDepth(harmonicDepth)
        let padded = octalAddress.leftPadded(toLength: depth, withPad: "0")
        return min(padded.reversed().prefix { $0 == "0" }.count, depth)
    }

    static func visibleRarities(for harmonicDepth: Int, includeSaros: Bool = true) -> [FlipRarity] {
        let depth = JournalSettings.clampedHarmonicDepth(harmonicDepth)
        let regular = allCases.filter { rarity in
            rarity != .saros && rarity.order <= min(depth, 6)
        }
        return includeSaros ? regular + [.saros] : regular
    }

    static func notificationRarities(for harmonicDepth: Int) -> [FlipRarity] {
        visibleRarities(for: harmonicDepth)
            .filter(\.notificationEligible)
    }
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
            let mode: FlipNotificationMode = switch rarity {
            case .rare: .event
            case .epic: .live
            case .legendary, .mythic, .saros: .alarm
            default: .silent
            }
            let advanceMinutes = switch rarity {
            case .epic: 30
            case .legendary: 60
            case .mythic: 120
            case .saros: 240
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
            forOrder: order(forOctalAddress: octalAddress, harmonicDepth: harmonicDepth),
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

struct OctalGlyph: View {
    let value: String
    let depth: Int
    var color: Color

    init(value: String, depth: Int = JournalSettings.defaultHarmonicDepth, color: Color = .cyan) {
        self.value = value
        self.depth = JournalSettings.clampedHarmonicDepth(depth)
        self.color = color
    }

    var body: some View {
        let geometry = OctalGlyphGeometryCache.geometry(for: depth)

        ZStack {
            OctalGlyphCoreShape(depth: depth)
                .fill(color, style: FillStyle(eoFill: true))
            OctalGlyphArmShape(value: value, depth: depth)
                .fill(color)
        }
        .aspectRatio(geometry.aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Octal glyph")
        .accessibilityValue(geometry.normalizedOctal(value))
    }
}

struct FlipRarityBadge: View {
    let rarity: FlipRarity
    var compact = false

    var body: some View {
        Group {
            if compact {
                Image(systemName: rarity.symbolName)
            } else {
                Label(rarity.title, systemImage: rarity.symbolName)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(rarity.color)
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

    private func digitIndex(forSocketIndex socketIndex: Int) -> Int {
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

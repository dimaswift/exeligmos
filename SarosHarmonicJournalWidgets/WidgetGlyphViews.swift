import SwiftUI

#if canImport(ActivityKit)
import ActivityKit
#endif

struct TrackingDisplayPayload {
    let glyph: String
    let rarityTitle: String
    let rarityOrderLabel: String
    let raritySymbolName: String
    let rarityColorHex: String
    let flipDate: Date
    let isFlipWindow: Bool
}

struct TrackingCountdownText: View {
    let payload: TrackingDisplayPayload
    let now: Date
    var compact: Bool
    var recordURL: URL?

    var body: some View {
        if payload.isFlipWindow {
            if let recordURL {
                Link(destination: recordURL) {
                    recLabel
                }
            } else {
                recLabel
            }
        } else if payload.flipDate > now {
            Text(timerInterval: now...payload.flipDate, countsDown: true)
        } else {
            if let recordURL {
                Link(destination: recordURL) {
                    recLabel
                }
            } else {
                recLabel
            }
        }
    }

    private var recLabel: some View {
        HStack(spacing: compact ? 3 : 5) {
            Image(systemName: "record.circle.fill")
            Text("Rec")
        }
        .font(compact ? .caption2.weight(.bold) : .callout.weight(.bold))
        .padding(.horizontal, compact ? 5 : 9)
        .padding(.vertical, compact ? 2 : 4)
        .background(.white.opacity(0.16), in: Capsule())
    }
}

extension ThreadTrackingSnapshot {
    func displayPayload(at now: Date) -> TrackingDisplayPayload {
        let shouldShowNext = now >= flipDate.addingTimeInterval(ThreadTrackingSharedStore.flipRolloverDelay)

        if shouldShowNext,
           let nextGlyph,
           let nextRarityTitle,
           let nextRarityOrderLabel,
           let nextRaritySymbolName,
           let nextRarityColorHex,
           let nextFlipDate {
            return TrackingDisplayPayload(
                glyph: nextGlyph,
                rarityTitle: nextRarityTitle,
                rarityOrderLabel: nextRarityOrderLabel,
                raritySymbolName: nextRaritySymbolName,
                rarityColorHex: nextRarityColorHex,
                flipDate: nextFlipDate,
                isFlipWindow: false
            )
        }

        return TrackingDisplayPayload(
            glyph: glyph,
            rarityTitle: rarityTitle,
            rarityOrderLabel: rarityOrderLabel,
            raritySymbolName: raritySymbolName,
            rarityColorHex: rarityColorHex,
            flipDate: flipDate,
            isFlipWindow: now >= flipDate
        )
    }
}

#if canImport(ActivityKit)
extension ThreadTrackingAttributes.ContentState {
    func displayPayload(at now: Date) -> TrackingDisplayPayload {
        let shouldShowNext = now >= flipDate.addingTimeInterval(ThreadTrackingSharedStore.flipRolloverDelay)

        if shouldShowNext,
           let nextGlyph,
           let nextRarityTitle,
           let nextRarityOrderLabel,
           let nextRaritySymbolName,
           let nextRarityColorHex,
           let nextFlipDate {
            return TrackingDisplayPayload(
                glyph: nextGlyph,
                rarityTitle: nextRarityTitle,
                rarityOrderLabel: nextRarityOrderLabel,
                raritySymbolName: nextRaritySymbolName,
                rarityColorHex: nextRarityColorHex,
                flipDate: nextFlipDate,
                isFlipWindow: false
            )
        }

        return TrackingDisplayPayload(
            glyph: glyph,
            rarityTitle: rarityTitle,
            rarityOrderLabel: rarityOrderLabel,
            raritySymbolName: raritySymbolName,
            rarityColorHex: rarityColorHex,
            flipDate: flipDate,
            isFlipWindow: now >= flipDate
        )
    }
}
#endif

struct WidgetOctalGlyph: View {
    let value: String
    let depth: Int
    let color: Color

    var body: some View {
        let geometry = WidgetOctalGlyphGeometryCache.geometry(for: depth)

        ZStack {
            WidgetOctalGlyphCoreShape(depth: depth)
                .fill(color, style: FillStyle(eoFill: true))
            WidgetOctalGlyphArmShape(value: value, depth: depth)
                .fill(color)
        }
        .aspectRatio(geometry.aspectRatio, contentMode: .fit)
        .accessibilityLabel("Octal glyph")
        .accessibilityValue(geometry.normalizedOctal(value))
    }
}

extension Color {
    init(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = UInt64(trimmed, radix: 16) else {
            self = .green
            return
        }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self = Color(red: red, green: green, blue: blue)
    }
}

private struct WidgetOctalGlyphCoreShape: Shape {
    let depth: Int

    func path(in rect: CGRect) -> Path {
        WidgetOctalGlyphGeometryCache.geometry(for: depth).corePath(in: rect)
    }
}

private struct WidgetOctalGlyphArmShape: Shape {
    let value: String
    let depth: Int

    func path(in rect: CGRect) -> Path {
        WidgetOctalGlyphGeometryCache.geometry(for: depth).armPath(for: value, in: rect)
    }
}

private enum WidgetOctalGlyphGeometryCache {
    private static let geometries: [Int: WidgetOctalGlyphGeometry] = {
        Dictionary(uniqueKeysWithValues: (1...8).map { ($0, WidgetOctalGlyphGeometry(depth: $0)) })
    }()

    static func geometry(for depth: Int) -> WidgetOctalGlyphGeometry {
        let clampedDepth = min(max(depth, 1), 8)
        return geometries[clampedDepth] ?? WidgetOctalGlyphGeometry(depth: clampedDepth)
    }
}

private struct WidgetOctalGlyphSocket {
    let start: CGPoint
    let end: CGPoint
}

private struct WidgetOctalGlyphSocketFrame {
    let center: CGPoint
    let tangent: CGPoint
    let outward: CGPoint
    let length: CGFloat
}

private struct WidgetOctalGlyphGeometry {
    let digitCount: Int
    let aspectRatio: CGFloat
    private let frameBounds: CGRect
    private let coreTemplatePath: Path
    private let armTemplatePaths: [[Path]]

    init(depth: Int) {
        let digitCount = min(max(depth, 1), 8)
        let sockets = Self.makeSockets(digitCount: digitCount)
        let corePolygon = sockets.flatMap { [$0.start, $0.end] }
        let coreHole = digitCount == 7
            ? Self.defaultCoreHole
            : Self.insetConvexPolygon(corePolygon, thickness: 14)
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
            digits.insert(contentsOf: repeatElement(0, count: digitCount - digits.count), at: 0)
        }

        return digits
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

    private static func makeSockets(digitCount: Int) -> [WidgetOctalGlyphSocket] {
        let baseStart = CGPoint(x: -socketWidth / 2, y: -coreRadius)
        let baseEnd = CGPoint(x: socketWidth / 2, y: -coreRadius)
        let rotationStep = 360 / CGFloat(digitCount)

        return (0..<digitCount).map { index in
            let rotation = CGFloat(index) * rotationStep
            return WidgetOctalGlyphSocket(
                start: rotate(baseStart, degrees: rotation),
                end: rotate(baseEnd, degrees: rotation)
            )
        }
    }

    private static func makeFrameBounds(
        corePolygon: [CGPoint],
        coreHole: [CGPoint],
        sockets: [WidgetOctalGlyphSocket],
        digitCount: Int
    ) -> CGRect {
        var points = corePolygon + coreHole
        points.append(contentsOf: sockets.flatMap { [$0.start, $0.end] })

        for socketIndex in 0..<digitCount {
            for arm in arms.values {
                points.append(contentsOf: armToWorldPoints(arm, socketIndex: socketIndex, sockets: sockets))
            }
        }

        let minX = points.map(\.x).min() ?? -90
        let maxX = points.map(\.x).max() ?? 90
        let minY = points.map(\.y).min() ?? -150
        let maxY = points.map(\.y).max() ?? 90
        let padding = gridSize * paddingCells
        let halfWidth = max(gridSize, ceil(max(abs(minX), abs(maxX)) / gridSize) * gridSize + padding)
        let halfHeight = max(gridSize, ceil(max(abs(minY), abs(maxY)) / gridSize) * gridSize + padding)

        return CGRect(x: -halfWidth, y: -halfHeight, width: halfWidth * 2, height: halfHeight * 2)
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
        sockets: [WidgetOctalGlyphSocket]
    ) -> [CGPoint] {
        guard points.count >= 2 else { return points }

        let frame = socketFrame(socketIndex, sockets: sockets)
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

    private static func socketFrame(
        _ index: Int,
        sockets: [WidgetOctalGlyphSocket]
    ) -> WidgetOctalGlyphSocketFrame {
        let socket = sockets[index]
        let center = midpoint(socket.start, socket.end)
        let dx = socket.end.x - socket.start.x
        let dy = socket.end.y - socket.start.y
        let length = max(hypot(dx, dy), 0.001)
        let tangent = CGPoint(x: dx / length, y: dy / length)
        let centerVector = CGPoint(x: center.x, y: center.y)
        var outward = CGPoint(x: tangent.y, y: -tangent.x)

        if outward.x * centerVector.x + outward.y * centerVector.y < 0 {
            outward = CGPoint(x: -outward.x, y: -outward.y)
        }

        return WidgetOctalGlyphSocketFrame(
            center: center,
            tangent: tangent,
            outward: outward,
            length: length
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
            let normal = CGPoint(x: (-dy / length) * inwardSign, y: (dx / length) * inwardSign)

            return (
                point: CGPoint(x: point.x + normal.x * thickness, y: point.y + normal.y * thickness),
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
        return CGPoint(x: pointA.x + directionA.x * t, y: pointA.y + directionA.y * t)
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
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
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
}

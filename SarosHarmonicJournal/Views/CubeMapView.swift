import Foundation
import SwiftUI

enum CubeMapDisplayMode: String, CaseIterable, Identifiable {
    case singleFace
    case cross
    case isometric

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleFace: "Single"
        case .cross: "Cross"
        case .isometric: "Iso"
        }
    }
}

struct CubeMapProjectionOffsets: Equatable {
    static let zero = CubeMapProjectionOffsets(latitude: 0, longitude: 0, roll: 0)

    let latitude: Double
    let longitude: Double
    let roll: Double

    var latitudeRadians: Double { latitude * .pi / 180 }
    var longitudeRadians: Double { longitude * .pi / 180 }
    var rollRadians: Double { roll * .pi / 180 }
}

struct CubeMapProjectionFocus: Equatable {
    let offsets: CubeMapProjectionOffsets
    let showsTop: Bool
    let yawQuarter: Int

    static let zero = CubeMapProjectionFocus(offsets: .zero, showsTop: true, yawQuarter: 0)

    static func fitting(rings: [[Coordinate]]) -> CubeMapProjectionFocus {
        let coordinates = rings.flatMap { $0 }
        guard !coordinates.isEmpty else { return .zero }

        let latitude = coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
        let longitudeSin = coordinates.map { sin($0.longitude * .pi / 180) }.reduce(0, +)
        let longitudeCos = coordinates.map { cos($0.longitude * .pi / 180) }.reduce(0, +)
        let longitude = atan2(longitudeSin, longitudeCos) * 180 / .pi

        return CubeMapProjectionFocus(
            offsets: CubeMapProjectionOffsets(latitude: 0, longitude: -longitude, roll: 0),
            showsTop: latitude >= 0,
            yawQuarter: 0
        )
    }
}

struct CubeMapEclipseOverlay: Identifiable {
    let id: String
    let saros: Int
    let title: String
    let date: Date
    let color: Color
    let polygons: [[Coordinate]]
}

struct CubeMapView: View {
    let overlays: [CubeMapEclipseOverlay]
    let displayMode: CubeMapDisplayMode
    let projectionOffsets: CubeMapProjectionOffsets
    let allowsInteraction: Bool
    let showsFrame: Bool
    let showsBackground: Bool

    @State private var cubeFace: CubeMapFace
    @State private var previousSingleFace: CubeMapFace?
    @State private var singleFaceReturnEdge: CubeMapEdge?
    @State private var isometricYawQuarter: Int
    @State private var isometricShowsTop: Bool
    @State private var landPolygons: [[Coordinate]] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(
        overlays: [CubeMapEclipseOverlay],
        displayMode: CubeMapDisplayMode = .isometric,
        projectionOffsets: CubeMapProjectionOffsets = .zero,
        initialFace: CubeMapFace = .front,
        initialYawQuarter: Int = 0,
        initialShowsTop: Bool = true,
        allowsInteraction: Bool = true,
        showsFrame: Bool = true,
        showsBackground: Bool = true
    ) {
        self.overlays = overlays
        self.displayMode = displayMode
        self.projectionOffsets = projectionOffsets
        self.allowsInteraction = allowsInteraction
        self.showsFrame = showsFrame
        self.showsBackground = showsBackground
        _cubeFace = State(initialValue: initialFace)
        _isometricYawQuarter = State(initialValue: initialYawQuarter)
        _isometricShowsTop = State(initialValue: initialShowsTop)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in
                Canvas { context, size in
                    drawMap(context: &context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(edgeTapGesture(in: proxy.size))
            }
            .background {
                if showsBackground {
                    RoundedRectangle(cornerRadius: showsFrame ? 8 : 0)
                        .fill(.white.opacity(0.04))
                }
            }
            .overlay {
                if showsFrame {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                }
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: showsFrame ? 8 : 0))
        .task {
            await loadLand()
        }
    }

    private func edgeTapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard allowsInteraction else { return }

                switch displayMode {
                case .singleFace:
                    switchFace(for: value.location, in: size)
                case .cross:
                    selectCrossFace(for: value.location, in: size)
                case .isometric:
                    rotateIsometric(for: value.location, in: size)
                }
            }
    }

    @MainActor
    private func loadLand() async {
        guard landPolygons.isEmpty else { return }
        isLoading = true
        errorMessage = nil

        do {
            landPolygons = try CubeNaturalEarthStore.shared.landPolygons()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func drawMap(context: inout GraphicsContext, size: CGSize) {
        switch displayMode {
        case .singleFace:
            drawSingleFaceMap(context: &context, size: size)
        case .cross:
            drawCrossMap(context: &context, size: size)
        case .isometric:
            drawIsometricMap(context: &context, size: size)
        }
    }

    private func drawSingleFaceMap(context: inout GraphicsContext, size: CGSize) {
        let rect = mapRect(in: size)
        drawFace(context: &context, rect: rect, face: cubeFace, isHighlighted: true)
    }

    private func drawCrossMap(context: inout GraphicsContext, size: CGSize) {
        let rects = crossFaceRects(in: size)
        for face in CubeMapFace.crossOrder {
            guard let rect = rects[face] else { continue }
            drawFace(
                context: &context,
                rect: rect,
                face: face,
                isHighlighted: face == cubeFace,
                cornerRadius: 0,
                unitTransform: face == .bottom ? { CGPoint(x: -$0.x, y: -$0.y) } : { $0 }
            )
        }
    }

    private func drawFace(
        context: inout GraphicsContext,
        rect: CGRect,
        face: CubeMapFace,
        isHighlighted: Bool,
        cornerRadius: CGFloat = 8,
        unitTransform: (CGPoint) -> CGPoint = { $0 }
    ) {
        var ocean = Path()
        if cornerRadius > 0 {
            ocean.addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        } else {
            ocean.addRect(rect)
        }
        context.fill(ocean, with: .color(.cyan.opacity(isHighlighted ? 0.10 : 0.06)))

        var mapContext = context
        var clip = Path()
        clip.addRect(rect)
        mapContext.clip(to: clip)

        drawGraticule(context: &mapContext, rect: rect, face: face, unitTransform: unitTransform)
        let scale = min(rect.width, rect.height) / 2
        func projectUnitPoint(_ point: CGPoint) -> CGPoint {
            let transformed = unitTransform(point)
            return CGPoint(
                x: rect.midX + transformed.x * scale,
                y: rect.midY - transformed.y * scale
            )
        }

        drawProjectedMapContent(
            context: &mapContext,
            landFillPath: CubeGnomonicProjection.transformedFilledPath(
                for: landPolygons,
                face: face,
                offsets: projectionOffsets
            ) { unitPoint in
                projectUnitPoint(unitPoint)
            },
            landStrokePath: CubeGnomonicProjection.transformedSegmentedPath(
                for: landPolygons,
                face: face,
                closeRings: true,
                offsets: projectionOffsets
            ) { unitPoint in
                projectUnitPoint(unitPoint)
            },
            overlayFillPath: { overlay in
                CubeGnomonicProjection.transformedFilledPath(
                    for: overlay.polygons,
                    face: face,
                    offsets: projectionOffsets
                ) { unitPoint in
                    projectUnitPoint(unitPoint)
                }
            }
        )

        var border = Path()
        if cornerRadius > 0 {
            border.addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        } else {
            border.addRect(rect)
        }
        context.stroke(border, with: .color(.white.opacity(isHighlighted ? 0.42 : 0.16)), lineWidth: isHighlighted ? 1.2 : 0.8)
    }

    private func drawProjectedMapContent(
        context: inout GraphicsContext,
        landFillPath: Path,
        landStrokePath: Path,
        overlayFillPath: (CubeMapEclipseOverlay) -> Path
    ) {
        context.fill(landFillPath, with: .color(.green.opacity(0.16)))
        context.stroke(landStrokePath, with: .color(.white.opacity(0.24)), lineWidth: 0.65)

        for overlay in overlays {
            let path = overlayFillPath(overlay)
            context.fill(path, with: .color(overlay.color.opacity(0.17)))
            context.stroke(
                path,
                with: .color(overlay.color.opacity(0.22)),
                style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                path,
                with: .color(overlay.color.opacity(0.92)),
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func drawGraticule(
        context: inout GraphicsContext,
        rect: CGRect,
        face: CubeMapFace,
        unitTransform: (CGPoint) -> CGPoint = { $0 }
    ) {
        let scale = min(rect.width, rect.height) / 2
        func projectUnitPoint(_ point: CGPoint) -> CGPoint {
            let transformed = unitTransform(point)
            return CGPoint(
                x: rect.midX + transformed.x * scale,
                y: rect.midY - transformed.y * scale
            )
        }

        for longitude in stride(from: -180.0, through: 180.0, by: 30.0) {
            let coordinates = stride(from: -85.0, through: 85.0, by: 5.0).map {
                Coordinate(latitude: $0, longitude: longitude)
            }
            let path = CubeGnomonicProjection.transformedLinePath(
                for: coordinates,
                face: face,
                offsets: projectionOffsets
            ) { unitPoint in
                projectUnitPoint(unitPoint)
            }
            context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 0.7)
        }

        for latitude in stride(from: -60.0, through: 60.0, by: 30.0) {
            let coordinates = stride(from: -180.0, through: 180.0, by: 5.0).map {
                Coordinate(latitude: latitude, longitude: $0)
            }
            let path = CubeGnomonicProjection.transformedLinePath(
                for: coordinates,
                face: face,
                offsets: projectionOffsets
            ) { unitPoint in
                projectUnitPoint(unitPoint)
            }
            context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 0.7)
        }
    }

    private func mapRect(in size: CGSize) -> CGRect {
        let inset: CGFloat = showsFrame ? 16 : 6
        let side = max(min(size.width, size.height) - inset * 2, 1)
        return CGRect(
            x: (size.width - side) / 2,
            y: (size.height - side) / 2,
            width: side,
            height: side
        )
    }

    private func crossFaceRects(in size: CGSize) -> [CubeMapFace: CGRect] {
        let inset: CGFloat = showsFrame ? 12 : 2
        let availableWidth = max(size.width - inset * 2, 1)
        let availableHeight = max(size.height - inset * 2, 1)
        let cellSize = max(min(availableWidth / 4, availableHeight / 3), 1)
        let totalWidth = cellSize * 4
        let totalHeight = cellSize * 3
        let origin = CGPoint(
            x: (size.width - totalWidth) / 2,
            y: (size.height - totalHeight) / 2
        )

        func rect(column: Int, row: Int) -> CGRect {
            CGRect(
                x: origin.x + CGFloat(column) * cellSize,
                y: origin.y + CGFloat(row) * cellSize,
                width: cellSize,
                height: cellSize
            )
        }

        return [
            .left: rect(column: 0, row: 1),
            .front: rect(column: 1, row: 1),
            .right: rect(column: 2, row: 1),
            .back: rect(column: 3, row: 1),
            .top: rect(column: 1, row: 0),
            .bottom: rect(column: 1, row: 2)
        ]
    }

    private func switchFace(for location: CGPoint, in size: CGSize) {
        let rect = mapRect(in: size)
        guard rect.contains(location) else { return }

        let edgeDistances: [(CubeMapEdge, CGFloat)] = [
            (.left, abs(location.x - rect.minX)),
            (.right, abs(location.x - rect.maxX)),
            (.top, abs(location.y - rect.minY)),
            (.bottom, abs(location.y - rect.maxY))
        ]
        guard let edge = edgeDistances.min(by: { $0.1 < $1.1 })?.0 else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            if let previousSingleFace, edge == singleFaceReturnEdge {
                cubeFace = previousSingleFace
                self.previousSingleFace = nil
                singleFaceReturnEdge = nil
            } else {
                let currentFace = cubeFace
                cubeFace = cubeFace.neighbor(toward: edge)
                previousSingleFace = currentFace
                singleFaceReturnEdge = edge.opposite
            }
        }
    }

    private func selectCrossFace(for location: CGPoint, in size: CGSize) {
        guard let face = crossFaceRects(in: size).first(where: { $0.value.contains(location) })?.key else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            cubeFace = face
        }
    }

    private func rotateIsometric(for location: CGPoint, in size: CGSize) {
        let rect = mapRect(in: size)
        guard rect.contains(location) else { return }

        let normalizedX = (location.x - rect.midX) / max(rect.width / 2, 1)
        let normalizedY = (location.y - rect.midY) / max(rect.height / 2, 1)

        withAnimation(.easeInOut(duration: 0.2)) {
            if abs(normalizedX) > abs(normalizedY) {
                isometricYawQuarter += normalizedX < 0 ? -1 : 1
            } else {
                isometricShowsTop = normalizedY < 0
            }
        }
    }

    private func drawIsometricMap(context: inout GraphicsContext, size: CGSize) {
        let rect = mapRect(in: size)
        let projection = CubeIsometricProjection(
            rect: rect,
            yawQuarter: isometricYawQuarter,
            showsTop: isometricShowsTop
        )

        for face in projection.visibleFaces {
            drawIsometricFace(
                context: &context,
                face: face,
                projection: projection
            )
        }
    }

    private func drawIsometricFace(
        context: inout GraphicsContext,
        face: CubeMapFace,
        projection: CubeIsometricProjection
    ) {
        let facePath = projection.facePath(face)
        context.fill(facePath, with: .color(.cyan.opacity(face == .top || face == .bottom ? 0.10 : 0.07)))

        drawIsometricGraticule(context: &context, face: face, projection: projection)

        let landFillPath = CubeGnomonicProjection.transformedFilledPath(
            for: landPolygons,
            face: face,
            offsets: projectionOffsets
        ) { unitPoint in
            projection.project(face: face, unitPoint: unitPoint)
        }
        context.fill(landFillPath, with: .color(.green.opacity(0.14)))

        let landPath = CubeGnomonicProjection.transformedSegmentedPath(
            for: landPolygons,
            face: face,
            closeRings: true,
            offsets: projectionOffsets
        ) { unitPoint in
            projection.project(face: face, unitPoint: unitPoint)
        }
        context.stroke(landPath, with: .color(.white.opacity(0.25)), lineWidth: 0.65)

        for overlay in overlays {
            let path = CubeGnomonicProjection.transformedFilledPath(
                for: overlay.polygons,
                face: face,
                offsets: projectionOffsets
            ) { unitPoint in
                projection.project(face: face, unitPoint: unitPoint)
            }
            context.fill(path, with: .color(overlay.color.opacity(0.16)))
            context.stroke(
                path,
                with: .color(overlay.color.opacity(0.20)),
                style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                path,
                with: .color(overlay.color.opacity(0.92)),
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
            )
        }

        context.stroke(facePath, with: .color(.white.opacity(0.24)), lineWidth: 0.9)
    }

    private func drawIsometricGraticule(
        context: inout GraphicsContext,
        face: CubeMapFace,
        projection: CubeIsometricProjection
    ) {
        for longitude in stride(from: -180.0, through: 180.0, by: 30.0) {
            let coordinates = stride(from: -85.0, through: 85.0, by: 5.0).map {
                Coordinate(latitude: $0, longitude: longitude)
            }
            let path = CubeGnomonicProjection.transformedLinePath(
                for: coordinates,
                face: face,
                offsets: projectionOffsets
            ) { unitPoint in
                projection.project(face: face, unitPoint: unitPoint)
            }
            context.stroke(path, with: .color(.white.opacity(0.07)), lineWidth: 0.6)
        }

        for latitude in stride(from: -60.0, through: 60.0, by: 30.0) {
            let coordinates = stride(from: -180.0, through: 180.0, by: 5.0).map {
                Coordinate(latitude: latitude, longitude: $0)
            }
            let path = CubeGnomonicProjection.transformedLinePath(
                for: coordinates,
                face: face,
                offsets: projectionOffsets
            ) { unitPoint in
                projection.project(face: face, unitPoint: unitPoint)
            }
            context.stroke(path, with: .color(.white.opacity(0.07)), lineWidth: 0.6)
        }
    }
}

enum CubeMapFace: String, CaseIterable, Identifiable {
    case front
    case right
    case back
    case left
    case top
    case bottom

    var id: String { rawValue }

    static let crossOrder: [CubeMapFace] = [.left, .front, .right, .back, .top, .bottom]

    var center: CubeVector3 {
        switch self {
        case .front: CubeVector3(1, 0, 0)
        case .right: CubeVector3(0, 1, 0)
        case .back: CubeVector3(-1, 0, 0)
        case .left: CubeVector3(0, -1, 0)
        case .top: CubeVector3(0, 0, 1)
        case .bottom: CubeVector3(0, 0, -1)
        }
    }

    var horizontalAxis: CubeVector3 {
        switch self {
        case .front: CubeVector3(0, 1, 0)
        case .right: CubeVector3(-1, 0, 0)
        case .back: CubeVector3(0, -1, 0)
        case .left: CubeVector3(1, 0, 0)
        case .top: CubeVector3(0, 1, 0)
        case .bottom: CubeVector3(0, -1, 0)
        }
    }

    var verticalAxis: CubeVector3 {
        switch self {
        case .front, .right, .back, .left: CubeVector3(0, 0, 1)
        case .top, .bottom: CubeVector3(-1, 0, 0)
        }
    }

    func neighbor(toward edge: CubeMapEdge) -> CubeMapFace {
        switch edge {
        case .left:
            Self.nearest(to: -horizontalAxis)
        case .right:
            Self.nearest(to: horizontalAxis)
        case .top:
            Self.nearest(to: verticalAxis)
        case .bottom:
            Self.nearest(to: -verticalAxis)
        }
    }

    private static func nearest(to vector: CubeVector3) -> CubeMapFace {
        allCases.max { lhs, rhs in
            lhs.center.dot(vector) < rhs.center.dot(vector)
        } ?? .front
    }
}

enum CubeMapEdge {
    case left
    case right
    case top
    case bottom

    var opposite: CubeMapEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }
}

struct CubeVector3: Equatable {
    let x: Double
    let y: Double
    let z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    static prefix func - (vector: CubeVector3) -> CubeVector3 {
        CubeVector3(-vector.x, -vector.y, -vector.z)
    }

    static func + (lhs: CubeVector3, rhs: CubeVector3) -> CubeVector3 {
        CubeVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    static func * (lhs: CubeVector3, rhs: Double) -> CubeVector3 {
        CubeVector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    func dot(_ other: CubeVector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: CubeVector3) -> CubeVector3 {
        CubeVector3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    func normalized() -> CubeVector3 {
        let length = max(sqrt(x * x + y * y + z * z), 0.000001)
        return CubeVector3(x / length, y / length, z / length)
    }
}

private struct CubeIsometricProjection {
    let rect: CGRect
    let yawQuarter: Int
    let showsTop: Bool

    private var corner: CubeVector3 {
        let z = showsTop ? 1.0 : -1.0
        switch ((yawQuarter % 4) + 4) % 4 {
        case 1:
            return CubeVector3(-1, 1, z)
        case 2:
            return CubeVector3(-1, -1, z)
        case 3:
            return CubeVector3(1, -1, z)
        default:
            return CubeVector3(1, 1, z)
        }
    }

    var visibleFaces: [CubeMapFace] {
        let faces = CubeMapFace.allCases.filter {
            $0.center.dot(corner) > 0.01
        }
        let capFace: CubeMapFace = showsTop ? .top : .bottom
        return faces.filter { $0 != capFace } + [capFace]
    }

    private var scale: CGFloat {
        min(rect.width / 3.35, rect.height / 3.55)
    }

    private var viewDirection: CubeVector3 {
        corner.normalized()
    }

    private var screenUp: CubeVector3 {
        let north = CubeVector3(0, 0, 1)
        let view = viewDirection
        return (north + view * -north.dot(view)).normalized()
    }

    private var screenRight: CubeVector3 {
        screenUp.cross(viewDirection).normalized()
    }

    func project(face: CubeMapFace, unitPoint: CGPoint) -> CGPoint {
        let vector = face.center
            + face.horizontalAxis * Double(unitPoint.x)
            + face.verticalAxis * Double(unitPoint.y)
        return project(vector)
    }

    func facePath(_ face: CubeMapFace) -> Path {
        let corners = [
            CGPoint(x: -1, y: -1),
            CGPoint(x: 1, y: -1),
            CGPoint(x: 1, y: 1),
            CGPoint(x: -1, y: 1)
        ]
        var path = Path()
        for (index, corner) in corners.enumerated() {
            let point = project(face: face, unitPoint: corner)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    private func project(_ vector: CubeVector3) -> CGPoint {
        let screenX = vector.dot(screenRight)
        let screenY = -vector.dot(screenUp)
        return CGPoint(
            x: rect.midX + CGFloat(screenX) * scale,
            y: rect.midY + CGFloat(screenY) * scale
        )
    }
}

private enum CubeGnomonicProjection {
    static func transformedSegmentedPath(
        for rings: [[Coordinate]],
        face: CubeMapFace,
        closeRings: Bool,
        offsets: CubeMapProjectionOffsets = .zero,
        transform: (CGPoint) -> CGPoint
    ) -> Path {
        var path = Path()
        for ring in rings where ring.count >= (closeRings ? 3 : 2) {
            appendSegmentedRing(
                ring,
                to: &path,
                face: face,
                closeRing: closeRings,
                offsets: offsets,
                transform: transform
            )
        }
        return path
    }

    static func transformedLinePath(
        for coordinates: [Coordinate],
        face: CubeMapFace,
        offsets: CubeMapProjectionOffsets = .zero,
        transform: (CGPoint) -> CGPoint
    ) -> Path {
        transformedSegmentedPath(
            for: [coordinates],
            face: face,
            closeRings: false,
            offsets: offsets,
            transform: transform
        )
    }

    static func transformedFilledPath(
        for rings: [[Coordinate]],
        face: CubeMapFace,
        offsets: CubeMapProjectionOffsets = .zero,
        transform: (CGPoint) -> CGPoint
    ) -> Path {
        var path = Path()
        for ring in rings where ring.count >= 3 {
            let polygons = clippedProjectedPolygons(for: ring, face: face, offsets: offsets)
            for polygon in polygons where polygon.count >= 3 {
                appendPolygon(polygon, to: &path, transform: transform)
            }
        }
        return path
    }

    private static func appendSegmentedRing(
        _ coordinates: [Coordinate],
        to path: inout Path,
        face: CubeMapFace,
        closeRing: Bool,
        offsets: CubeMapProjectionOffsets,
        transform: (CGPoint) -> CGPoint
    ) {
        let vectors = coordinates.map { unitVector(for: $0, offsets: offsets) }
        let edgeCount = closeRing ? vectors.count : max(vectors.count - 1, 0)
        var hasActiveSegment = false

        for edgeIndex in 0..<edgeCount {
            let start = vectors[edgeIndex]
            let end = vectors[(edgeIndex + 1) % vectors.count]
            let sampleCount = sampleCount(from: start, to: end)

            for sampleIndex in 0...sampleCount {
                if edgeIndex > 0, sampleIndex == 0 {
                    continue
                }

                let progress = Double(sampleIndex) / Double(max(sampleCount, 1))
                let vector = interpolatedVector(from: start, to: end, progress: progress)
                if let unitPoint = project(vector, face: face) {
                    let point = transform(unitPoint)
                    if hasActiveSegment {
                        path.addLine(to: point)
                    } else {
                        path.move(to: point)
                        hasActiveSegment = true
                    }
                } else {
                    hasActiveSegment = false
                }
            }
        }
    }

    private static func sampleCount(from start: CubeVector3, to end: CubeVector3) -> Int {
        let dot = min(max(start.dot(end), -1), 1)
        let angle = acos(dot)
        let twoDegrees = Double.pi / 90
        return min(max(Int((angle / twoDegrees).rounded(.up)), 1), 48)
    }

    private static func interpolatedVector(
        from start: CubeVector3,
        to end: CubeVector3,
        progress: Double
    ) -> CubeVector3 {
        CubeVector3(
            start.x + (end.x - start.x) * progress,
            start.y + (end.y - start.y) * progress,
            start.z + (end.z - start.z) * progress
        )
        .normalized()
    }

    private static func project(_ vector: CubeVector3, face: CubeMapFace) -> CGPoint? {
        guard let point = projectOnPlane(vector, face: face) else { return nil }
        guard abs(point.x) <= 1.0001, abs(point.y) <= 1.0001 else { return nil }
        return point
    }

    private static func projectOnPlane(_ vector: CubeVector3, face: CubeMapFace) -> CGPoint? {
        let denominator = vector.dot(face.center)
        guard denominator > 0.0001 else { return nil }

        let x = vector.dot(face.horizontalAxis) / denominator
        let y = vector.dot(face.verticalAxis) / denominator

        return CGPoint(x: x, y: y)
    }

    private static func clippedProjectedPolygons(
        for ring: [Coordinate],
        face: CubeMapFace,
        offsets: CubeMapProjectionOffsets
    ) -> [[CGPoint]] {
        let vectors = ring.map { unitVector(for: $0, offsets: offsets) }
        let edgeCount = vectors.count
        guard edgeCount >= 3 else { return [] }

        var points: [CGPoint] = []
        for edgeIndex in 0..<edgeCount {
            let start = vectors[edgeIndex]
            let end = vectors[(edgeIndex + 1) % edgeCount]
            let sampleCount = sampleCount(from: start, to: end)

            for sampleIndex in 0...sampleCount {
                if edgeIndex > 0, sampleIndex == 0 {
                    continue
                }

                let progress = Double(sampleIndex) / Double(max(sampleCount, 1))
                let vector = interpolatedVector(from: start, to: end, progress: progress)
                guard let point = projectOnPlane(vector, face: face),
                      point.x.isFinite,
                      point.y.isFinite
                else {
                    continue
                }
                points.append(point)
            }
        }

        let clipped = clipPolygonToUnitSquare(points)
        return clipped.count >= 3 ? [clipped] : []
    }

    private static func appendPolygon(
        _ polygon: [CGPoint],
        to path: inout Path,
        transform: (CGPoint) -> CGPoint
    ) {
        for (index, point) in polygon.enumerated() {
            let transformed = transform(point)
            if index == 0 {
                path.move(to: transformed)
            } else {
                path.addLine(to: transformed)
            }
        }
        path.closeSubpath()
    }

    private static func clipPolygonToUnitSquare(_ polygon: [CGPoint]) -> [CGPoint] {
        CubeClipBoundary.allCases.reduce(polygon) { clipped, boundary in
            clip(clipped, to: boundary)
        }
    }

    private static func clip(_ polygon: [CGPoint], to boundary: CubeClipBoundary) -> [CGPoint] {
        guard polygon.count >= 3 else { return [] }

        var output: [CGPoint] = []
        var previous = polygon[polygon.count - 1]
        var previousInside = boundary.contains(previous)

        for current in polygon {
            let currentInside = boundary.contains(current)
            if currentInside {
                if !previousInside, let intersection = boundary.intersection(from: previous, to: current) {
                    output.append(intersection)
                }
                output.append(current)
            } else if previousInside, let intersection = boundary.intersection(from: previous, to: current) {
                output.append(intersection)
            }

            previous = current
            previousInside = currentInside
        }

        return output
    }

    private static func unitVector(
        for coordinate: Coordinate,
        offsets: CubeMapProjectionOffsets
    ) -> CubeVector3 {
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        let latitudeCosine = cos(latitude)
        let vector = CubeVector3(
            latitudeCosine * cos(longitude),
            latitudeCosine * sin(longitude),
            sin(latitude)
        )
        return rotateX(
            rotateY(
                rotateZ(vector, by: offsets.longitudeRadians),
                by: offsets.latitudeRadians
            ),
            by: offsets.rollRadians
        )
    }

    private static func rotateX(_ vector: CubeVector3, by angle: Double) -> CubeVector3 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return CubeVector3(
            vector.x,
            vector.y * cosine - vector.z * sine,
            vector.y * sine + vector.z * cosine
        )
    }

    private static func rotateY(_ vector: CubeVector3, by angle: Double) -> CubeVector3 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return CubeVector3(
            vector.x * cosine + vector.z * sine,
            vector.y,
            -vector.x * sine + vector.z * cosine
        )
    }

    private static func rotateZ(_ vector: CubeVector3, by angle: Double) -> CubeVector3 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return CubeVector3(
            vector.x * cosine - vector.y * sine,
            vector.x * sine + vector.y * cosine,
            vector.z
        )
    }
}

private enum CubeClipBoundary: CaseIterable {
    case left
    case right
    case bottom
    case top

    func contains(_ point: CGPoint) -> Bool {
        switch self {
        case .left:
            point.x >= -1
        case .right:
            point.x <= 1
        case .bottom:
            point.y >= -1
        case .top:
            point.y <= 1
        }
    }

    func intersection(from start: CGPoint, to end: CGPoint) -> CGPoint? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let t: CGFloat

        switch self {
        case .left:
            guard abs(dx) > 0.000001 else { return nil }
            t = (-1 - start.x) / dx
        case .right:
            guard abs(dx) > 0.000001 else { return nil }
            t = (1 - start.x) / dx
        case .bottom:
            guard abs(dy) > 0.000001 else { return nil }
            t = (-1 - start.y) / dy
        case .top:
            guard abs(dy) > 0.000001 else { return nil }
            t = (1 - start.y) / dy
        }

        guard t.isFinite else { return nil }
        let clampedT = min(max(t, 0), 1)
        return CGPoint(
            x: start.x + dx * clampedT,
            y: start.y + dy * clampedT
        )
    }
}

private final class CubeNaturalEarthStore {
    static let shared = CubeNaturalEarthStore()

    private var cachedLandPolygons: [[Coordinate]]?

    private init() {}

    func landPolygons(bundle: Bundle = .main) throws -> [[Coordinate]] {
        if let cachedLandPolygons {
            return cachedLandPolygons
        }

        let url = bundle.url(forResource: "land", withExtension: "json", subdirectory: "NaturalEarth")
            ?? bundle.url(forResource: "land", withExtension: "json")

        guard let url else {
            throw CubeNaturalEarthError.missingLandData
        }

        let data = try Data(contentsOf: url)
        let collection = try JSONDecoder().decode(CubeNaturalEarthFeatureCollection.self, from: data)
        let polygons = collection.features.flatMap(\.geometry.polygons).filter { $0.count >= 3 }
        cachedLandPolygons = polygons
        return polygons
    }
}

private enum CubeNaturalEarthError: LocalizedError {
    case missingLandData

    var errorDescription: String? {
        switch self {
        case .missingLandData:
            "Missing Natural Earth land data."
        }
    }
}

private struct CubeNaturalEarthFeatureCollection: Decodable {
    let features: [CubeNaturalEarthFeature]
}

private struct CubeNaturalEarthFeature: Decodable {
    let geometry: CubeNaturalEarthGeometry
}

private struct CubeNaturalEarthGeometry: Decodable {
    let polygons: [[Coordinate]]

    private enum CodingKeys: String, CodingKey {
        case type
        case coordinates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "Polygon":
            let rings = try container.decode([[[Double]]].self, forKey: .coordinates)
            polygons = rings.first.map { [Self.coordinates(from: $0)] } ?? []
        case "MultiPolygon":
            let multiPolygons = try container.decode([[[[Double]]]].self, forKey: .coordinates)
            polygons = multiPolygons.compactMap { polygon in
                polygon.first.map(Self.coordinates(from:))
            }
        default:
            polygons = []
        }
    }

    private static func coordinates(from ring: [[Double]]) -> [Coordinate] {
        ring.compactMap { point in
            guard point.count >= 2 else { return nil }
            return Coordinate(latitude: point[1], longitude: point[0])
        }
    }
}

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum MirrorReflectionSide: String, Codable, Hashable {
    case positive
    case negative

    var sign: CGFloat {
        switch self {
        case .positive: 1
        case .negative: -1
        }
    }
}

struct MirrorEdge: Codable, Hashable {
    var normalizedPoint: CGPoint
    var angleRadians: CGFloat
    var reflectedSide: MirrorReflectionSide

    init(
        normalizedPoint: CGPoint,
        angleRadians: CGFloat,
        reflectedSide: MirrorReflectionSide = .positive
    ) {
        self.normalizedPoint = normalizedPoint
        self.angleRadians = angleRadians
        self.reflectedSide = reflectedSide
    }

    static let photoBooth = MirrorEdge(
        normalizedPoint: CGPoint(x: 0.5, y: 0.5),
        angleRadians: .pi / 2,
        reflectedSide: .positive
    )
}

enum MirrorReflectionPreset {
    static let photoBooth = [MirrorEdge.photoBooth]
}

enum MirrorReflectionProcessor {
    private static let context = CIContext(options: [
        .cacheIntermediates: false
    ])

    static func process(_ image: CIImage, edges: [MirrorEdge]) -> CIImage {
        guard !edges.isEmpty else { return image }

        return edges.reduce(image) { currentImage, edge in
            reflect(currentImage, edge: edge)
        }
    }

    static func process(_ image: UIImage, edges: [MirrorEdge]) -> UIImage? {
        guard let input = CIImage(image: image)?.oriented(for: image.imageOrientation) else {
            return nil
        }

        let output = process(input, edges: edges)
        guard let cgImage = context.createCGImage(output, from: input.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }

    static func jpegData(from image: UIImage, edges: [MirrorEdge], compressionQuality: CGFloat = 0.92) -> Data? {
        process(image, edges: edges)?.jpegData(compressionQuality: compressionQuality)
    }

    static func renderedImage(from image: CIImage, edges: [MirrorEdge]) -> UIImage? {
        let output = process(image, edges: edges)
        guard let cgImage = context.createCGImage(output, from: image.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func reflect(_ image: CIImage, edge: MirrorEdge) -> CIImage {
        let extent = image.extent
        let linePoint = CGPoint(
            x: extent.minX + extent.width * edge.normalizedPoint.x,
            y: extent.maxY - extent.height * edge.normalizedPoint.y
        )
        let direction = CGVector(
            dx: cos(edge.angleRadians),
            dy: -sin(edge.angleRadians)
        )
        let normal = normalized(CGVector(dx: -direction.dy, dy: direction.dx))
        let transform = reflectionTransform(linePoint: linePoint, normal: normal)
        let reflectedImage = image
            .clampedToExtent()
            .transformed(by: transform)

        let mask = lineMask(
            extent: extent,
            linePoint: linePoint,
            normal: normal,
            reflectedSide: edge.reflectedSide
        )

        let blend = CIFilter.blendWithMask()
        blend.inputImage = reflectedImage
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    private static func reflectionTransform(linePoint: CGPoint, normal: CGVector) -> CGAffineTransform {
        let nx = normal.dx
        let ny = normal.dy
        let a = 1 - 2 * nx * nx
        let b = -2 * nx * ny
        let c = -2 * nx * ny
        let d = 1 - 2 * ny * ny
        let tx = linePoint.x - (a * linePoint.x + c * linePoint.y)
        let ty = linePoint.y - (b * linePoint.x + d * linePoint.y)

        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    private static func lineMask(
        extent: CGRect,
        linePoint: CGPoint,
        normal: CGVector,
        reflectedSide: MirrorReflectionSide
    ) -> CIImage? {
        let epsilon: CGFloat = 0.5
        let negativePoint = CGPoint(
            x: linePoint.x - normal.dx * epsilon,
            y: linePoint.y - normal.dy * epsilon
        )
        let positivePoint = CGPoint(
            x: linePoint.x + normal.dx * epsilon,
            y: linePoint.y + normal.dy * epsilon
        )

        let gradient = CIFilter.linearGradient()
        gradient.point0 = negativePoint
        gradient.point1 = positivePoint
        switch reflectedSide {
        case .positive:
            gradient.color0 = CIColor.black
            gradient.color1 = CIColor.white
        case .negative:
            gradient.color0 = CIColor.white
            gradient.color1 = CIColor.black
        }

        return gradient.outputImage?.cropped(to: extent)
    }

    private static func normalized(_ vector: CGVector) -> CGVector {
        let length = max(hypot(vector.dx, vector.dy), 0.0001)
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }
}

private extension CIImage {
    func oriented(for imageOrientation: UIImage.Orientation) -> CIImage {
        oriented(CGImagePropertyOrientation(imageOrientation))
    }
}

private extension CGImagePropertyOrientation {
    init(_ imageOrientation: UIImage.Orientation) {
        switch imageOrientation {
        case .up:
            self = .up
        case .down:
            self = .down
        case .left:
            self = .left
        case .right:
            self = .right
        case .upMirrored:
            self = .upMirrored
        case .downMirrored:
            self = .downMirrored
        case .leftMirrored:
            self = .leftMirrored
        case .rightMirrored:
            self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}

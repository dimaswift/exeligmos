import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import Vision

protocol AnimacyScoring {
    func score(pixelBuffer: CVPixelBuffer) async throws -> AnimacyResult
}

extension AnimacyScoring {
    func score(cgImage: CGImage) async throws -> AnimacyResult {
        let pixelBuffer = try AnimacyPixelBufferRenderer.pixelBuffer(
            from: cgImage,
            width: AnimacyScorer.modelInputWidth,
            height: AnimacyScorer.modelInputHeight
        )
        return try await score(pixelBuffer: pixelBuffer)
    }
}

final class AnimacyScorer: AnimacyScoring {
    static let modelInputWidth = 224
    static let modelInputHeight = 224

    private let model: VNCoreMLModel?
    private let stateQueue = DispatchQueue(label: "exeligmos.animacy-scorer.state")
    private var previousScore: Float?

    init(modelName: String = "AnimacyModel") {
        self.model = Self.loadModel(named: modelName)
    }

    func score(pixelBuffer: CVPixelBuffer) async throws -> AnimacyResult {
        let modelInput = try AnimacyPixelBufferRenderer.pixelBuffer(
            from: pixelBuffer,
            width: Self.modelInputWidth,
            height: Self.modelInputHeight
        )
        let raw = try model.map {
            try runCoreMLModel($0, pixelBuffer: modelInput)
        } ?? runVisionFallback(pixelBuffer: modelInput)

        let clampedScore = Self.clamp(raw.score)
        let smoothedScore = stateQueue.sync { () -> Float in
            let smoothedScore: Float
            if let previousScore {
                smoothedScore = previousScore * 0.85 + clampedScore * 0.15
            } else {
                smoothedScore = clampedScore
            }
            previousScore = smoothedScore
            return smoothedScore
        }

        return AnimacyResult(
            score: Self.clamp(smoothedScore),
            confidence: Self.clamp(raw.confidence),
            timestamp: Date()
        )
    }

    private static func loadModel(named modelName: String) -> VNCoreMLModel? {
        guard
            let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc"),
            let mlModel = try? MLModel(contentsOf: url)
        else {
            return nil
        }
        return try? VNCoreMLModel(for: mlModel)
    }

    private func runCoreMLModel(
        _ model: VNCoreMLModel,
        pixelBuffer: CVPixelBuffer
    ) throws -> (score: Float, confidence: Float) {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        return try Self.parseCoreMLResults(request.results)
    }

    private func runVisionFallback(pixelBuffer: CVPixelBuffer) -> (score: Float, confidence: Float) {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([faceRequest, saliencyRequest])

        let faceScore = (faceRequest.results ?? [])
            .map { observation in
                let area = Float(observation.boundingBox.width * observation.boundingBox.height)
                return min(Float(1), sqrtf(area) * 2.4)
            }
            .max() ?? Float(0)

        let saliencyScore = (saliencyRequest.results?.first?.salientObjects ?? [])
            .map { observation in
                let area = Float(observation.boundingBox.width * observation.boundingBox.height)
                return min(Float(1), sqrtf(area) * 1.6)
            }
            .max() ?? Float(0)

        let textureScore = Self.textureSymmetryScore(pixelBuffer: pixelBuffer)
        let heuristicScore = min(1, textureScore * 0.55 + saliencyScore * 0.3 + 0.08)
        let score = max(faceScore, heuristicScore)
        let confidence: Float = faceScore > 0.2 ? 0.75 : 0.35
        return (score, confidence)
    }

    private static func parseCoreMLResults(_ results: [VNObservation]?) throws -> (score: Float, confidence: Float) {
        let classifications = (results ?? []).compactMap { $0 as? VNClassificationObservation }
        if !classifications.isEmpty {
            let entity = classifications.first { $0.identifier.localizedCaseInsensitiveContains("entity") && !$0.identifier.localizedCaseInsensitiveContains("non") }
            let nonEntity = classifications.first { $0.identifier.localizedCaseInsensitiveContains("non_entity") || $0.identifier.localizedCaseInsensitiveContains("non-entity") || $0.identifier.localizedCaseInsensitiveContains("non entity") }

            if let entity, let nonEntity {
                return (
                    normalizedEntityScore(entity: entity.confidence, nonEntity: nonEntity.confidence),
                    max(entity.confidence, nonEntity.confidence)
                )
            }
            if let entity {
                return (clamp(entity.confidence), clamp(entity.confidence))
            }
        }

        let features = (results ?? []).compactMap { $0 as? VNCoreMLFeatureValueObservation }
        if let animacy = features.first(where: { $0.featureName == "animacy" }) {
            let score = score(from: animacy.featureValue)
            return (score, max(score, 1 - score))
        }

        let entity = features.first(where: { $0.featureName == "entity" }).map { score(from: $0.featureValue) }
        let nonEntity = features.first(where: { $0.featureName == "non_entity" || $0.featureName == "nonEntity" }).map { score(from: $0.featureValue) }
        if let entity, let nonEntity {
            return (normalizedEntityScore(entity: entity, nonEntity: nonEntity), max(entity, nonEntity))
        }

        if let multiArray = features.compactMap({ $0.featureValue.multiArrayValue }).first,
           multiArray.count >= 2 {
            let nonEntity = Float(truncating: multiArray[0])
            let entity = Float(truncating: multiArray[1])
            return (normalizedEntityScore(entity: entity, nonEntity: nonEntity), 0.65)
        }

        throw AnimacyScorerError.unsupportedModelOutput
    }

    private static func score(from featureValue: MLFeatureValue) -> Float {
        switch featureValue.type {
        case .double:
            return clampOrSigmoid(Float(featureValue.doubleValue))
        case .int64:
            return clampOrSigmoid(Float(featureValue.int64Value))
        case .multiArray:
            guard let value = featureValue.multiArrayValue?[0] else { return 0 }
            return clampOrSigmoid(Float(truncating: value))
        default:
            return 0
        }
    }

    private static func normalizedEntityScore(entity: Float, nonEntity: Float) -> Float {
        if entity >= 0, entity <= 1, nonEntity >= 0, nonEntity <= 1 {
            let total = max(entity + nonEntity, 0.0001)
            return clamp(entity / total)
        }

        let maximum = max(entity, nonEntity)
        let entityExp = expf(entity - maximum)
        let nonEntityExp = expf(nonEntity - maximum)
        return clamp(entityExp / max(entityExp + nonEntityExp, 0.0001))
    }

    private static func textureSymmetryScore(pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

        var symmetryDiff: Float = 0
        var contrast: Float = 0
        var samples: Float = 0
        let step = 4

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width / 2, by: step) {
                let left = luminance(bytes: bytes, bytesPerRow: bytesPerRow, x: x, y: y)
                let right = luminance(bytes: bytes, bytesPerRow: bytesPerRow, x: width - 1 - x, y: y)
                symmetryDiff += abs(left - right)
                contrast += abs(left - 0.5) + abs(right - 0.5)
                samples += 2
            }
        }

        guard samples > 0 else { return 0 }
        let symmetry = 1 - min(1, symmetryDiff / max(samples / 2, 1))
        let normalizedContrast = min(1, contrast / samples * 2)
        return clamp(symmetry * 0.65 + normalizedContrast * 0.35)
    }

    private static func luminance(
        bytes: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        x: Int,
        y: Int
    ) -> Float {
        let offset = y * bytesPerRow + x * 4
        let blue = Float(bytes[offset]) / 255
        let green = Float(bytes[offset + 1]) / 255
        let red = Float(bytes[offset + 2]) / 255
        return red * 0.299 + green * 0.587 + blue * 0.114
    }

    private static func clampOrSigmoid(_ value: Float) -> Float {
        if value >= 0, value <= 1 {
            return value
        }
        return 1 / (1 + expf(-value))
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}

private enum AnimacyPixelBufferRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func pixelBuffer(from source: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
        let output = try makePixelBuffer(width: width, height: height)
        let image = CIImage(cvPixelBuffer: source)
        let extent = image.extent
        let side = min(extent.width, extent.height)
        let crop = CGRect(
            x: extent.midX - side / 2,
            y: extent.midY - side / 2,
            width: side,
            height: side
        )
        let scale = CGFloat(width) / max(side, 1)
        let transformed = image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        ciContext.render(transformed, to: output)
        return output
    }

    static func pixelBuffer(from cgImage: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        let pixelBuffer = try makePixelBuffer(width: width, height: height)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw AnimacyScorerError.couldNotCreatePixelBuffer
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        guard let context else {
            throw AnimacyScorerError.couldNotCreatePixelBuffer
        }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.draw(cgImage, in: aspectFillRect(
            sourceSize: CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)),
            targetSize: CGSize(width: CGFloat(width), height: CGFloat(height))
        ))

        return pixelBuffer
    }

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw AnimacyScorerError.couldNotCreatePixelBuffer
        }
        return pixelBuffer
    }

    private static func aspectFillRect(sourceSize: CGSize, targetSize: CGSize) -> CGRect {
        let scale = max(targetSize.width / sourceSize.width, targetSize.height / sourceSize.height)
        let width = sourceSize.width * scale
        let height = sourceSize.height * scale
        return CGRect(
            x: (targetSize.width - width) / 2,
            y: (targetSize.height - height) / 2,
            width: width,
            height: height
        )
    }
}

private enum AnimacyScorerError: LocalizedError {
    case unsupportedModelOutput
    case couldNotCreatePixelBuffer

    var errorDescription: String? {
        switch self {
        case .unsupportedModelOutput:
            "The animacy model output must expose animacy, entity/non_entity, or two class logits."
        case .couldNotCreatePixelBuffer:
            "Could not create a 224x224 animacy input pixel buffer."
        }
    }
}

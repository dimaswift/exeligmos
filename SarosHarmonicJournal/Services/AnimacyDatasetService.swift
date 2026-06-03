import CoreGraphics
import Foundation

struct AnimacyDatasetUploadPayload: Codable {
    let schemaVersion: Int
    let appVersion: String
    let createdAt: Date
    let capture: AnimacyDatasetCapturePayload
    let originalImage: AnimacyDatasetImageBlob
}

struct AnimacyDatasetCapturePayload: Codable {
    let id: UUID
    let source: String
    let originalWidth: Int
    let originalHeight: Int
    let transformations: [AnimacyDatasetTransformationPayload]
}

enum AnimacyDatasetRarity: String, Codable, CaseIterable, Identifiable, Hashable {
    case common
    case rare
    case epic
    case legendary
    case mythic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .common: "Common"
        case .rare: "Rare"
        case .epic: "Epic"
        case .legendary: "Legendary"
        case .mythic: "Mythic"
        }
    }

    var rank: Int {
        switch self {
        case .common: 0
        case .rare: 1
        case .epic: 2
        case .legendary: 3
        case .mythic: 4
        }
    }

    static func fromLegacyScore(_ score: Int) -> AnimacyDatasetRarity {
        switch score {
        case ..<35:
            .common
        case 35..<55:
            .rare
        case 55..<75:
            .epic
        case 75..<90:
            .legendary
        default:
            .mythic
        }
    }
}

struct AnimacyDatasetTransformationPayload: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let rarity: AnimacyDatasetRarity
    let mirrorMode: String
    let reflectedSide: String?
    let mirrorEdges: [AnimacyDatasetMirrorEdgePayload]
    let imageTransform: AnimacyDatasetImageTransformPayload
    let isBinaryFilterEnabled: Bool
    let thresholdLevel: Double
    let isDoubleOutputEnabled: Bool
    let datasetImage: AnimacyDatasetImageBlob?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case rarity
        case animacyScore
        case mirrorMode
        case reflectedSide
        case mirrorEdges
        case imageTransform
        case isBinaryFilterEnabled
        case thresholdLevel
        case isDoubleOutputEnabled
        case datasetImage
    }

    init(
        id: UUID,
        createdAt: Date,
        rarity: AnimacyDatasetRarity,
        mirrorMode: String,
        reflectedSide: String?,
        mirrorEdges: [AnimacyDatasetMirrorEdgePayload],
        imageTransform: AnimacyDatasetImageTransformPayload,
        isBinaryFilterEnabled: Bool,
        thresholdLevel: Double,
        isDoubleOutputEnabled: Bool,
        datasetImage: AnimacyDatasetImageBlob?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rarity = rarity
        self.mirrorMode = mirrorMode
        self.reflectedSide = reflectedSide
        self.mirrorEdges = mirrorEdges
        self.imageTransform = imageTransform
        self.isBinaryFilterEnabled = isBinaryFilterEnabled
        self.thresholdLevel = thresholdLevel
        self.isDoubleOutputEnabled = isDoubleOutputEnabled
        self.datasetImage = datasetImage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        if let rarity = try container.decodeIfPresent(AnimacyDatasetRarity.self, forKey: .rarity) {
            self.rarity = rarity
        } else {
            let score = (try? container.decode(Int.self, forKey: .animacyScore)) ?? 0
            self.rarity = AnimacyDatasetRarity.fromLegacyScore(score)
        }
        self.mirrorMode = try container.decode(String.self, forKey: .mirrorMode)
        self.reflectedSide = try container.decodeIfPresent(String.self, forKey: .reflectedSide)
        self.mirrorEdges = try container.decode([AnimacyDatasetMirrorEdgePayload].self, forKey: .mirrorEdges)
        self.imageTransform = try container.decode(AnimacyDatasetImageTransformPayload.self, forKey: .imageTransform)
        self.isBinaryFilterEnabled = try container.decode(Bool.self, forKey: .isBinaryFilterEnabled)
        self.thresholdLevel = try container.decode(Double.self, forKey: .thresholdLevel)
        self.isDoubleOutputEnabled = try container.decode(Bool.self, forKey: .isDoubleOutputEnabled)
        self.datasetImage = try container.decodeIfPresent(AnimacyDatasetImageBlob.self, forKey: .datasetImage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(rarity, forKey: .rarity)
        try container.encode(mirrorMode, forKey: .mirrorMode)
        try container.encodeIfPresent(reflectedSide, forKey: .reflectedSide)
        try container.encode(mirrorEdges, forKey: .mirrorEdges)
        try container.encode(imageTransform, forKey: .imageTransform)
        try container.encode(isBinaryFilterEnabled, forKey: .isBinaryFilterEnabled)
        try container.encode(thresholdLevel, forKey: .thresholdLevel)
        try container.encode(isDoubleOutputEnabled, forKey: .isDoubleOutputEnabled)
        try container.encodeIfPresent(datasetImage, forKey: .datasetImage)
    }
}

struct AnimacyDatasetMirrorEdgePayload: Codable, Hashable {
    let normalizedX: Double
    let normalizedY: Double
    let angleRadians: Double
    let reflectedSide: String
}

struct AnimacyDatasetImageTransformPayload: Codable, Hashable {
    let rotationRadians: Double
    let scale: Double
    let offsetX: Double
    let offsetY: Double
}

struct AnimacyDatasetImageBlob: Codable {
    let fileName: String
    let contentType: String
    let dataBase64: String
}

struct AnimacyDatasetUploadResponse: Codable, Hashable {
    let ok: Bool
    let captureID: UUID
    let transformationCount: Int
    let datasetItemCount: Int
}

enum AnimacyDatasetUploadState: String, Codable, Hashable {
    case pending
    case uploaded
    case failed
}

struct AnimacyDatasetQueuedCapture: Codable, Identifiable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var state: AnimacyDatasetUploadState
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastError: String?
    var payload: AnimacyDatasetUploadPayload

    var transformationCount: Int {
        payload.capture.transformations.count
    }
}

struct AnimacyDatasetQueueSummary: Hashable {
    var pendingCaptureCount: Int
    var completedCaptureCount: Int
    var failedCaptureCount: Int
    var pendingTransformationCount: Int
    var completedTransformationCount: Int

    static let empty = AnimacyDatasetQueueSummary(
        pendingCaptureCount: 0,
        completedCaptureCount: 0,
        failedCaptureCount: 0,
        pendingTransformationCount: 0,
        completedTransformationCount: 0
    )

    var hasPendingUploads: Bool {
        pendingCaptureCount + failedCaptureCount > 0
    }
}

struct AnimacyDatasetQueueUploadSummary: Hashable {
    let attemptedCount: Int
    let uploadedCount: Int
    let failedCount: Int
    let pendingRemainingCount: Int
    let lastError: String?
}

final class AnimacyDatasetQueueStore {
    private let uploader: AnimacyDatasetUploadService
    private let fileManager: FileManager

    init(
        uploader: AnimacyDatasetUploadService = AnimacyDatasetUploadService(),
        fileManager: FileManager = .default
    ) {
        self.uploader = uploader
        self.fileManager = fileManager
    }

    @discardableResult
    func enqueue(_ payload: AnimacyDatasetUploadPayload) throws -> AnimacyDatasetQueueSummary {
        try ensureDirectories()
        let now = Date()
        let item = AnimacyDatasetQueuedCapture(
            id: payload.capture.id,
            createdAt: now,
            updatedAt: now,
            state: .pending,
            attemptCount: 0,
            lastAttemptAt: nil,
            lastError: nil,
            payload: payload
        )
        try write(item, to: pendingURL(for: item.id))
        return try summary()
    }

    func summary() throws -> AnimacyDatasetQueueSummary {
        try ensureDirectories()
        let pendingItems = try queuedCaptures(in: pendingDirectory)
        let completedItems = try queuedCaptures(in: completedDirectory)
        let failedItems = pendingItems.filter { $0.state == .failed }
        let activePendingItems = pendingItems.filter { $0.state != .failed }

        return AnimacyDatasetQueueSummary(
            pendingCaptureCount: activePendingItems.count,
            completedCaptureCount: completedItems.count,
            failedCaptureCount: failedItems.count,
            pendingTransformationCount: pendingItems.reduce(0) { $0 + $1.transformationCount },
            completedTransformationCount: completedItems.reduce(0) { $0 + $1.transformationCount }
        )
    }

    func pendingCaptures() throws -> [AnimacyDatasetQueuedCapture] {
        try ensureDirectories()
        return try queuedCaptures(in: pendingDirectory)
    }

    func completedCaptures() throws -> [AnimacyDatasetQueuedCapture] {
        try ensureDirectories()
        return try queuedCaptures(in: completedDirectory)
    }

    func uploadPending(to serverURLString: String) async throws -> AnimacyDatasetQueueUploadSummary {
        try ensureDirectories()
        let items = try queuedCaptures(in: pendingDirectory)
        var uploadedCount = 0
        var failedCount = 0
        var lastError: String?

        for var item in items {
            item.attemptCount += 1
            item.lastAttemptAt = Date()

            do {
                _ = try await uploader.submit(item.payload, to: serverURLString)
                item.state = .uploaded
                item.lastError = nil
                item.updatedAt = Date()
                try write(item, to: completedURL(for: item.id))
                try? fileManager.removeItem(at: pendingURL(for: item.id))
                uploadedCount += 1
            } catch {
                item.state = .failed
                item.lastError = error.localizedDescription
                item.updatedAt = Date()
                try write(item, to: pendingURL(for: item.id))
                lastError = item.lastError
                failedCount += 1
            }
        }

        let remaining = try queuedCaptures(in: pendingDirectory).count
        return AnimacyDatasetQueueUploadSummary(
            attemptedCount: items.count,
            uploadedCount: uploadedCount,
            failedCount: failedCount,
            pendingRemainingCount: remaining,
            lastError: lastError
        )
    }

    func clearCompleted() throws -> AnimacyDatasetQueueSummary {
        try ensureDirectories()
        try fileManager.removeItem(at: completedDirectory)
        try fileManager.createDirectory(at: completedDirectory, withIntermediateDirectories: true)
        return try summary()
    }

    private func queuedCaptures(in directory: URL) throws -> [AnimacyDatasetQueuedCapture] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(AnimacyDatasetQueuedCapture.self, from: data)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func write(_ item: AnimacyDatasetQueuedCapture, to url: URL) throws {
        let data = try encoder.encode(item)
        try data.write(to: url, options: [.atomic])
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: completedDirectory, withIntermediateDirectories: true)
    }

    private func pendingURL(for id: UUID) -> URL {
        pendingDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func completedURL(for id: UUID) -> URL {
        completedDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private var pendingDirectory: URL {
        rootDirectory.appendingPathComponent("pending", isDirectory: true)
    }

    private var completedDirectory: URL {
        rootDirectory.appendingPathComponent("completed", isDirectory: true)
    }

    private var rootDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnimacyDatasetQueue", isDirectory: true)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

final class AnimacyDatasetUploadService {
    enum UploadError: LocalizedError {
        case invalidServerURL
        case invalidResponse(statusCode: Int?, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidServerURL:
                "Enter a sync server URL such as http://192.168.1.10:8787."
            case .invalidResponse(let statusCode, let body):
                if let statusCode {
                    "Dataset server returned HTTP \(statusCode): \(body)"
                } else {
                    "The dataset server returned an invalid response: \(body)"
                }
            }
        }
    }

    func submit(
        _ payload: AnimacyDatasetUploadPayload,
        to serverURLString: String
    ) async throws -> AnimacyDatasetUploadResponse {
        let url = try endpoint(serverURLString, path: "/api/animacy/captures")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        do {
            return try decoder.decode(AnimacyDatasetUploadResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank ?? "\(data.count) bytes"
            throw UploadError.invalidResponse(
                statusCode: nil,
                body: "Could not decode dataset upload response: \(error.localizedDescription). Body: \(body.prefix(500))"
            )
        }
    }

    private func endpoint(_ serverURLString: String, path: String) throws -> URL {
        guard var components = URLComponents(string: serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil,
              components.host != nil else {
            throw UploadError.invalidServerURL
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw UploadError.invalidServerURL
        }
        return url
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse(statusCode: nil, body: response.description)
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw UploadError.invalidResponse(statusCode: httpResponse.statusCode, body: body)
        }
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

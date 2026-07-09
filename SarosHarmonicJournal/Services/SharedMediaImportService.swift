import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SharedMediaImportResult {
    let eventDate: Date
    let mediaItems: [JournalMediaItem]
}

enum SharedMediaImportService {
    private static let appGroupIdentifier = "group.fractonica.exeligmos"
    private static let pendingDirectoryName = "SharedMediaImports"
    private static let pendingQueueFileName = "pending-shared-media.json"

    static func consumePendingImports() async throws -> SharedMediaImportResult? {
        guard let queueURL = pendingQueueURL(),
              FileManager.default.fileExists(atPath: queueURL.path)
        else { return nil }

        let data = try Data(contentsOf: queueURL)
        let payloads = (try? JSONDecoder().decode([PendingSharedMediaPayload].self, from: data)) ?? []
        try? FileManager.default.removeItem(at: queueURL)

        guard !payloads.isEmpty, let directory = pendingDirectoryURL() else { return nil }

        var importedItems: [JournalMediaItem] = []
        var importedDates: [Date] = []

        for payload in payloads {
            let sourceURL = directory.appendingPathComponent(payload.storedFilename)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }

            let mediaDate = await inferredCreationDate(for: sourceURL) ?? payload.creationDate ?? Date()
            let mediaType = payload.mediaType ?? inferredMediaType(for: sourceURL)
            let savedItem = try MediaStorage.saveFile(
                at: sourceURL,
                fileExtension: sourceURL.pathExtension,
                type: mediaType
            )
            importedItems.append(JournalMediaItem(
                id: savedItem.id,
                type: savedItem.type,
                localPath: savedItem.localPath,
                createdAt: mediaDate
            ))
            importedDates.append(mediaDate)
            try? FileManager.default.removeItem(at: sourceURL)
        }

        guard !importedItems.isEmpty else { return nil }
        return SharedMediaImportResult(
            eventDate: importedDates.first ?? Date(),
            mediaItems: importedItems
        )
    }

    static func importExternalURLs(_ urls: [URL]) async throws -> SharedMediaImportResult? {
        var importedItems: [JournalMediaItem] = []
        var importedDates: [Date] = []

        for url in urls {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let mediaDate = await inferredCreationDate(for: url) ?? Date()
            let mediaType = inferredMediaType(for: url)
            let savedItem = try MediaStorage.saveFile(
                at: url,
                fileExtension: url.pathExtension,
                type: mediaType
            )
            importedItems.append(JournalMediaItem(
                id: savedItem.id,
                type: savedItem.type,
                localPath: savedItem.localPath,
                createdAt: mediaDate
            ))
            importedDates.append(mediaDate)
        }

        guard !importedItems.isEmpty else { return nil }
        return SharedMediaImportResult(
            eventDate: importedDates.first ?? Date(),
            mediaItems: importedItems
        )
    }

    private static func pendingDirectoryURL() -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        let directory = container.appendingPathComponent(pendingDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func pendingQueueURL() -> URL? {
        pendingDirectoryURL()?.appendingPathComponent(pendingQueueFileName)
    }

    private static func inferredMediaType(for url: URL) -> MediaType {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return .document
        }

        if type.conforms(to: .image) {
            return .photo
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return .video
        }
        if type.conforms(to: .audio) {
            return .audio
        }
        return .document
    }

    private static func inferredCreationDate(for url: URL) async -> Date? {
        if let imageDate = imageCreationDate(for: url) {
            return imageDate
        }
        if let videoDate = await videoCreationDate(for: url) {
            return videoDate
        }
        return fileCreationDate(for: url)
    }

    private static func imageCreationDate(for url: URL) -> Date? {
        guard inferredMediaType(for: url) == .photo,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let rawDate = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = imageMetadataDateFormatter.date(from: rawDate) {
            return date
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let rawDate = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = imageMetadataDateFormatter.date(from: rawDate) {
            return date
        }

        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           let rawDate = png[kCGImagePropertyPNGCreationTime] as? String {
            return ISO8601DateFormatter().date(from: rawDate) ?? imageMetadataDateFormatter.date(from: rawDate)
        }

        return nil
    }

    private static func videoCreationDate(for url: URL) async -> Date? {
        let mediaType = inferredMediaType(for: url)
        guard mediaType == .video || mediaType == .audio else { return nil }
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)
            for item in metadata where item.commonKey?.rawValue == "creationDate" {
                if let date = try await item.load(.dateValue) {
                    return date
                }
                if let string = try await item.load(.stringValue),
                   let date = ISO8601DateFormatter().date(from: string) {
                    return date
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func fileCreationDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    private static let imageMetadataDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}

private struct PendingSharedMediaPayload: Codable {
    let id: UUID
    let storedFilename: String
    let originalFilename: String?
    let mediaTypeRawValue: String?
    let creationDate: Date?

    var mediaType: MediaType? {
        mediaTypeRawValue.flatMap(MediaType.init(rawValue:))
    }
}

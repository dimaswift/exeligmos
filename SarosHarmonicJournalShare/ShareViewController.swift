import CoreServices
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let appGroupIdentifier = "group.fractonica.exeligmos"
    private let pendingDirectoryName = "SharedMediaImports"
    private let pendingQueueFileName = "pending-shared-media.json"
    private var didBeginImport = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didBeginImport else { return }
        didBeginImport = true
        importSharedItems()
    }

    private func importSharedItems() {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []

        guard !providers.isEmpty else {
            finish(openApp: false)
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var payloads: [PendingSharedMediaPayload] = []

        for provider in providers {
            guard let identifier = preferredTypeIdentifier(for: provider) else { continue }
            group.enter()
            copySharedItem(from: provider, typeIdentifier: identifier) { result in
                defer { group.leave() }
                if case .success(let payload?) = result {
                    lock.lock()
                    payloads.append(payload)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            guard !payloads.isEmpty else {
                self.finish(openApp: false)
                return
            }

            do {
                try self.appendPendingPayloads(payloads)
                self.finish(openApp: true)
            } catch {
                self.finish(openApp: false)
            }
        }
    }

    private func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
        let preferredTypes = [
            UTType.image.identifier,
            UTType.movie.identifier,
            UTType.video.identifier,
            UTType.audio.identifier,
            UTType.fileURL.identifier,
            UTType.item.identifier,
            kUTTypeData as String
        ]
        return preferredTypes.first { provider.hasItemConformingToTypeIdentifier($0) }
    }

    private func copySharedItem(
        from provider: NSItemProvider,
        typeIdentifier: String,
        completion: @escaping (Result<PendingSharedMediaPayload?, Error>) -> Void
    ) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
            if let error {
                completion(.failure(error))
                return
            }

            if let url {
                completion(Result { try self.copyFile(at: url, typeIdentifier: typeIdentifier) })
                return
            }

            provider.loadItem(forTypeIdentifier: typeIdentifier) { item, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                completion(Result {
                    if let url = item as? URL {
                        return try self.copyFile(at: url, typeIdentifier: typeIdentifier)
                    }
                    if let data = item as? Data {
                        return try self.copyData(data, typeIdentifier: typeIdentifier, originalFilename: nil)
                    }
                    if let image = item as? UIImage,
                       let data = image.jpegData(compressionQuality: 0.94) {
                        return try self.copyData(data, typeIdentifier: UTType.jpeg.identifier, originalFilename: nil)
                    }
                    return nil
                })
            }
        }
    }

    private func copyFile(at sourceURL: URL, typeIdentifier: String) throws -> PendingSharedMediaPayload {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileExtension = preferredFileExtension(
            sourceExtension: sourceURL.pathExtension,
            typeIdentifier: typeIdentifier
        )
        let destinationURL = try destinationURL(fileExtension: fileExtension)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        return PendingSharedMediaPayload(
            id: UUID(),
            storedFilename: destinationURL.lastPathComponent,
            originalFilename: sourceURL.lastPathComponent,
            mediaTypeRawValue: mediaTypeRawValue(fileExtension: fileExtension, typeIdentifier: typeIdentifier),
            creationDate: fileCreationDate(for: sourceURL)
        )
    }

    private func copyData(
        _ data: Data,
        typeIdentifier: String,
        originalFilename: String?
    ) throws -> PendingSharedMediaPayload {
        let fileExtension = preferredFileExtension(sourceExtension: nil, typeIdentifier: typeIdentifier)
        let destinationURL = try destinationURL(fileExtension: fileExtension)
        try data.write(to: destinationURL, options: [.atomic])

        return PendingSharedMediaPayload(
            id: UUID(),
            storedFilename: destinationURL.lastPathComponent,
            originalFilename: originalFilename,
            mediaTypeRawValue: mediaTypeRawValue(fileExtension: fileExtension, typeIdentifier: typeIdentifier),
            creationDate: nil
        )
    }

    private func appendPendingPayloads(_ payloads: [PendingSharedMediaPayload]) throws {
        let queueURL = try pendingDirectoryURL().appendingPathComponent(pendingQueueFileName)
        var allPayloads: [PendingSharedMediaPayload] = []
        if let data = try? Data(contentsOf: queueURL),
           let existing = try? JSONDecoder().decode([PendingSharedMediaPayload].self, from: data) {
            allPayloads = existing
        }
        allPayloads.append(contentsOf: payloads)
        let data = try JSONEncoder().encode(allPayloads)
        try data.write(to: queueURL, options: [.atomic])
    }

    private func destinationURL(fileExtension: String) throws -> URL {
        try pendingDirectoryURL()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension.isEmpty ? "bin" : fileExtension)
    }

    private func pendingDirectoryURL() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw ShareImportError.missingAppGroup
        }
        let directory = container.appendingPathComponent(pendingDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func preferredFileExtension(sourceExtension: String?, typeIdentifier: String) -> String {
        if let sourceExtension, !sourceExtension.isEmpty {
            return sourceExtension
        }
        return UTType(typeIdentifier)?.preferredFilenameExtension ?? "bin"
    }

    private func mediaTypeRawValue(fileExtension: String, typeIdentifier: String) -> String {
        let type = UTType(typeIdentifier) ?? UTType(filenameExtension: fileExtension)
        if type?.conforms(to: .image) == true {
            return "photo"
        }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
            return "video"
        }
        if type?.conforms(to: .audio) == true {
            return "audio"
        }
        return "document"
    }

    private func fileCreationDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    private func finish(openApp: Bool) {
        guard openApp,
              let url = URL(string: "exeligmos://import/shared")
        else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        extensionContext?.open(url) { _ in
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

private struct PendingSharedMediaPayload: Codable {
    let id: UUID
    let storedFilename: String
    let originalFilename: String?
    let mediaTypeRawValue: String?
    let creationDate: Date?
}

private enum ShareImportError: Error {
    case missingAppGroup
}

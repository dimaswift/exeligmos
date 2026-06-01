import Foundation

enum MediaStorage {
    static let mediaDirectoryName = "SarosMedia"

    static func saveData(_ data: Data, fileExtension: String, type: MediaType) throws -> JournalMediaItem {
        let cleanExtension = fileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        let url = try newMediaURL(fileExtension: cleanExtension.isEmpty ? "bin" : cleanExtension)
        try data.write(to: url, options: [.atomic])
        return JournalMediaItem(type: type, localPath: relativePath(for: url))
    }

    static func saveFile(at sourceURL: URL, fileExtension: String? = nil, type: MediaType) throws -> JournalMediaItem {
        let sourceExtension = fileExtension ?? sourceURL.pathExtension
        let cleanExtension = sourceExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        let destinationURL = try newMediaURL(fileExtension: cleanExtension.isEmpty ? "bin" : cleanExtension)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return JournalMediaItem(type: type, localPath: relativePath(for: destinationURL))
    }

    static func newMediaURL(fileExtension: String) throws -> URL {
        let directory = try mediaDirectory()
        return directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
    }

    static func mediaDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent(mediaDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func url(for item: JournalMediaItem) -> URL {
        url(forStoredPath: item.localPath)
    }

    static func url(forStoredPath storedPath: String) -> URL {
        if storedPath.hasPrefix("/") {
            let absoluteURL = URL(fileURLWithPath: storedPath)
            if FileManager.default.fileExists(atPath: absoluteURL.path) {
                return absoluteURL
            }
            return documentsDirectory().appendingPathComponent(absoluteURL.lastPathComponent)
                .deletingLastPathComponent()
                .appendingPathComponent(mediaDirectoryName)
                .appendingPathComponent(absoluteURL.lastPathComponent)
        }

        return documentsDirectory().appendingPathComponent(storedPath)
    }

    static func relativePath(for url: URL) -> String {
        let documentsPath = documentsDirectory().standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == documentsPath {
            return ""
        }
        if path.hasPrefix(documentsPath + "/") {
            return String(path.dropFirst(documentsPath.count + 1))
        }
        return "\(mediaDirectoryName)/\(url.lastPathComponent)"
    }

    static func portablePath(for item: JournalMediaItem) -> String {
        let relative = item.localPath.hasPrefix("/")
            ? "\(mediaDirectoryName)/\(URL(fileURLWithPath: item.localPath).lastPathComponent)"
            : item.localPath
        return relative.isEmpty ? "\(mediaDirectoryName)/\(UUID().uuidString)" : relative
    }

    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

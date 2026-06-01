import Foundation

enum MediaStorage {
    static func saveData(_ data: Data, fileExtension: String, type: MediaType) throws -> JournalMediaItem {
        let cleanExtension = fileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        let url = try newMediaURL(fileExtension: cleanExtension.isEmpty ? "bin" : cleanExtension)
        try data.write(to: url, options: [.atomic])
        return JournalMediaItem(type: type, localPath: url.path)
    }

    static func newMediaURL(fileExtension: String) throws -> URL {
        let directory = try mediaDirectory()
        return directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
    }

    static func mediaDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("SarosMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

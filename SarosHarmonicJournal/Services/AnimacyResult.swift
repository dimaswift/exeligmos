import Foundation

struct AnimacyResult: Codable, Hashable {
    let score: Float
    let confidence: Float
    let timestamp: Date
}

struct AnimacyCaptureLog: Codable, Hashable {
    let imageId: String
    let timestamp: Date
    let animacyScore: Float
    let userAccepted: Bool
    let mirrorAngle: Float?
    let mirrorOffset: Float?
}

enum AnimacyCaptureLogger {
    private static let fileName = "animacy_capture_log.jsonl"

    static func append(_ log: AnimacyCaptureLog) throws {
        let url = try logURL()
        var line = try JSONEncoder().encode(log)
        line.append(0x0A)

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try line.write(to: url, options: [.atomic])
        }
    }

    static func logURL() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("AnimacyLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }
}

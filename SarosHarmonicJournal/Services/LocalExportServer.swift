import Combine
import Darwin
import Foundation
import Network

final class LocalExportServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var urlString: String?

    private var listener: NWListener?
    private var exportDirectory: URL?
    private let queue = DispatchQueue(label: "LocalExportServer")

    func start(exportDirectory: URL) throws {
        stop()
        self.exportDirectory = exportDirectory

        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.urlString = "http://\(Self.localIPAddress() ?? "127.0.0.1"):\(listener.port?.rawValue ?? 0)"
                case .failed, .cancelled:
                    self.isRunning = false
                    self.urlString = nil
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        urlString = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request
                .components(separatedBy: "\r\n")
                .first?
                .components(separatedBy: " ")
                .dropFirst()
                .first ?? "/"

            let response = self.response(for: String(path))
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for path: String) -> Data {
        guard let exportDirectory else {
            return http(status: "503 Service Unavailable", contentType: "text/plain", body: Data("Export not ready".utf8))
        }

        if path == "/" {
            let html = """
            <!doctype html>
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Saros Export</title></head>
            <body>
            <h1>Saros Export</h1>
            <ul>
            <li><a href="/archive.json">archive.json</a></li>
            <li><a href="/entities.json">entities.json</a></li>
            <li><a href="/records.json">records.json</a></li>
            </ul>
            </body></html>
            """
            return http(status: "200 OK", contentType: "text/html", body: Data(html.utf8))
        }

        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL = exportDirectory.appendingPathComponent(cleanPath).standardizedFileURL
        let exportPath = exportDirectory.standardizedFileURL.path
        guard fileURL.path == exportPath || fileURL.path.hasPrefix(exportPath + "/"),
              let data = try? Data(contentsOf: fileURL) else {
            return http(status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8))
        }

        return http(status: "200 OK", contentType: contentType(for: fileURL), body: data)
    }

    private func http(status: String, contentType: String, body: Data) -> Data {
        var response = Data()
        response.append(Data("HTTP/1.1 \(status)\r\n".utf8))
        response.append(Data("Content-Type: \(contentType)\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)
        return response
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "json": "application/json"
        case "html": "text/html"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "m4a": "audio/mp4"
        default: "application/octet-stream"
        }
    }

    private static func localIPAddress() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) != "lo0" else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            address = String(cString: host)
            break
        }

        return address
    }
}

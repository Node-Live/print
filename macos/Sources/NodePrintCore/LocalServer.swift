import Foundation
import Network
import os

/// HTTP/1.1 on 127.0.0.1 only, one request per connection.
public final class LocalServer: Sendable {
    public static let defaultPort: UInt16 = 19233

    private let listener: NWListener
    private let api: LocalAPI
    private let queue = DispatchQueue(label: "live.node.print.server")

    public init(api: LocalAPI, port: UInt16 = LocalServer.defaultPort) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        self.api = api
    }

    /// The bound port once listening; reports failure (such as the port being taken) through `onFailure`.
    public func start(onReady: @escaping @Sendable (UInt16) -> Void = { _ in }, onFailure: @escaping @Sendable (NWError) -> Void = { _ in }) {
        let listener = listener
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onReady(listener.port?.rawValue ?? 0)
            case let .failed(error):
                Logger.server.error("listener failed: \(error.localizedDescription, privacy: .public)")
                onFailure(error)
            default: break
            }
        }
        let api = api
        let queue = queue
        listener.newConnectionHandler = { connection in
            HTTPConnection(connection, api: api, queue: queue).start()
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }
}

private final class HTTPConnection: @unchecked Sendable {
    private static let maxHeadBytes = 64 * 1024

    private let connection: NWConnection
    private let api: LocalAPI
    private let queue: DispatchQueue
    private var buffer = Data()

    init(_ connection: NWConnection, api: LocalAPI, queue: DispatchQueue) {
        self.connection = connection
        self.api = api
        self.queue = queue
    }

    func start() {
        connection.start(queue: queue)
        readHead()
    }

    private func readHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer[..<end.lowerBound]
                buffer.removeSubrange(..<end.upperBound)
                handle(head: head)
            } else if isComplete || error != nil || buffer.count > Self.maxHeadBytes {
                connection.cancel()
            } else {
                readHead()
            }
        }
    }

    private func handle(head raw: Data) {
        guard let text = String(data: raw, encoding: .utf8) else { return connection.cancel() }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3 else { return connection.cancel() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let head = RequestHead(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers)
        let length = Int(headers["content-length"] ?? "") ?? 0

        if let response = api.response(to: head, contentLength: length) {
            send(response) { [self] in drain(length - buffer.count) }
            return
        }
        if headers["expect"]?.lowercased() == "100-continue" {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
        }
        readBody(head, length: length)
    }

    private func readBody(_ head: RequestHead, length: Int) {
        if buffer.count >= length {
            let body = Data(buffer.prefix(length))
            let api = api
            Task {
                let response = await api.response(to: head, body: body)
                self.queue.async { self.send(response) { self.connection.cancel() } }
            }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if buffer.count < length, isComplete || error != nil { return connection.cancel() }
            readBody(head, length: length)
        }
    }

    /// Reads and drops what is left of a body the response did not need, so the client is not reset mid-upload.
    private func drain(_ remaining: Int) {
        guard remaining > 0 else { return connection.cancel() }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [self] data, _, isComplete, error in
            let left = remaining - (data?.count ?? 0)
            if left <= 0 || isComplete || error != nil { return connection.cancel() }
            drain(left)
        }
    }

    private func send(_ response: Response, then next: @escaping @Sendable () -> Void) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in next() })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Content Too Large"
        default: "Internal Server Error"
        }
    }
}

extension Logger {
    static let server = Logger(subsystem: "live.node.print", category: "server")
}

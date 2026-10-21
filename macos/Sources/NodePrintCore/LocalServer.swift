import Foundation
import Network
import os

/// HTTP/1.1 on 127.0.0.1 only, one request per connection. When the port cannot be bound it says so and tries
/// again every 5 s. A `POST /print` counts in `activity` from its head until its response.
public final class LocalServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 19233

    private let api: LocalAPI
    private let activity: Activity
    private let port: UInt16
    private let queue = DispatchQueue(label: "live.node.print.server")
    private var listener: NWListener?
    private var stopped = false

    public init(api: LocalAPI, activity: Activity = Activity(), port: UInt16 = LocalServer.defaultPort) {
        self.api = api
        self.activity = activity
        self.port = port
    }

    /// `onChange` gets the bound port while listening and `nil` while the port is unavailable.
    public func start(onChange: @escaping @Sendable (UInt16?) -> Void = { _ in }) {
        queue.async { self.listen(onChange) }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
        }
    }

    private func listen(_ onChange: @escaping @Sendable (UInt16?) -> Void) {
        guard !stopped else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: parameters) else { return retry(onChange) }
        self.listener = listener
        listener.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                onChange(listener.port?.rawValue)
            case let .failed(error), let .waiting(error):
                Logger.server.error("cannot listen on \(self.port): \(error.localizedDescription, privacy: .public)")
                listener.cancel()
                retry(onChange)
            default:
                break
            }
        }
        let api = api
        let activity = activity
        let queue = queue
        listener.newConnectionHandler = { connection in
            HTTPConnection(connection, api: api, activity: activity, queue: queue).start()
        }
        listener.start(queue: queue)
    }

    private func retry(_ onChange: @escaping @Sendable (UInt16?) -> Void) {
        listener = nil
        onChange(nil)
        queue.asyncAfter(deadline: .now() + 5) { self.listen(onChange) }
    }
}

private final class HTTPConnection: @unchecked Sendable {
    private static let maxHeadBytes = 64 * 1024

    private let connection: NWConnection
    private let api: LocalAPI
    private let activity: Activity
    private let queue: DispatchQueue
    private var buffer = Data()
    private var isJob = false

    init(_ connection: NWConnection, api: LocalAPI, activity: Activity, queue: DispatchQueue) {
        self.connection = connection
        self.api = api
        self.activity = activity
        self.queue = queue
    }

    func start() {
        connection.start(queue: queue)
        readHead()
    }

    private func receive(_ handle: @escaping @Sendable (_ ended: Bool) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            handle(isComplete || error != nil)
        }
    }

    private func readHead() {
        if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let head = buffer[..<end.lowerBound]
            buffer.removeSubrange(..<end.upperBound)
            return handle(head: head)
        }
        if buffer.count > Self.maxHeadBytes { return close() }
        receive { [self] ended in ended ? close() : readHead() }
    }

    private func handle(head raw: Data) {
        guard let text = String(data: raw, encoding: .utf8) else { return close() }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3 else { return close() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let head = RequestHead(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers)
        if head.method == "POST", head.path == "/print" {
            isJob = true
            activity.jobArrived()
        }
        let chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
        let length = chunked ? nil : max(0, Int(headers["content-length"] ?? "") ?? 0)

        if let response = api.response(to: head, contentLength: length) {
            return send(response) { [self] in drain(length.map { $0 - buffer.count }) }
        }
        if headers["expect"]?.lowercased() == "100-continue" {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
        }
        if let length {
            readBody(head, length: length)
        } else {
            readChunks(head, body: Data())
        }
    }

    private func readBody(_ head: RequestHead, length: Int) {
        guard buffer.count >= length else {
            return receive { [self] ended in ended && buffer.count < length ? close() : readBody(head, length: length) }
        }
        respond(head, body: Data(buffer.prefix(length)))
    }

    /// `Transfer-Encoding: chunked`, counted against the limit as it arrives.
    private func readChunks(_ head: RequestHead, body: Data) {
        var body = body
        while let lineEnd = buffer.range(of: Data("\r\n".utf8)) {
            let sizeText = String(decoding: buffer[buffer.startIndex ..< lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                return close()
            }
            if size == 0 { return respond(head, body: body) }
            if body.count + size > LocalAPI.maxBodyBytes {
                return send(api.tooLarge(head)) { [self] in drain(nil) }
            }
            let dataEnd = lineEnd.upperBound + size
            guard buffer.endIndex >= dataEnd + 2 else { break }
            body.append(buffer[lineEnd.upperBound ..< dataEnd])
            buffer.removeSubrange(buffer.startIndex ..< dataEnd + 2)
        }
        let sofar = body
        receive { [self] ended in ended ? close() : readChunks(head, body: sofar) }
    }

    private func respond(_ head: RequestHead, body: Data) {
        api.respond(to: head, body: body) { response in
            self.queue.async { self.send(response) { self.close() } }
        }
    }

    /// Reads and drops what is left of a body the response did not need (all of it until the client closes when its
    /// length is unknown), so the client is not reset mid-upload.
    private func drain(_ remaining: Int?) {
        if let remaining, remaining <= 0 { return close() }
        let before = buffer.count
        receive { [self] ended in
            let read = buffer.count - before
            buffer.removeAll()
            if ended { return close() }
            drain(remaining.map { $0 - read })
        }
    }

    private func send(_ response: Response, then next: @escaping @Sendable () -> Void) {
        endJob()
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in next() })
    }

    private func close() {
        endJob()
        connection.cancel()
    }

    private func endJob() {
        guard isJob else { return }
        isJob = false
        activity.jobEnded()
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
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

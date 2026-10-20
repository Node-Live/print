import Foundation

public struct RequestHead: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lower-cased.
    public var headers: [String: String]

    public init(method: String, target: String, headers: [String: String]) {
        self.method = method
        self.headers = headers
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        path = String(parts[0])
        var query: [String: String] = [:]
        if parts.count == 2 {
            for item in parts[1].split(separator: "&") {
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = Self.formDecoded(pair[0])
                if query[key] == nil {
                    query[key] = pair.count == 2 ? Self.formDecoded(pair[1]) : ""
                }
            }
        }
        self.query = query
    }

    /// `application/x-www-form-urlencoded` decoding, as `URLSearchParams` writes it.
    private static func formDecoded(_ text: Substring) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}

public struct Response: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    init(status: Int, json: some Encodable) {
        self.status = status
        headers = [("Content-Type", "application/json; charset=utf-8")]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        body = (try? encoder.encode(json)) ?? Data()
    }

    init(status: Int) {
        self.status = status
        headers = []
        body = Data()
    }

    static func error(_ status: Int, _ code: String, _ message: String) -> Response {
        Response(status: status, json: ["error": ["code": code, "message": message]])
    }
}

/// The local HTTP contract of `docs/protocol.md`, independent of the socket that carries it.
public final class LocalAPI: Sendable {
    public static let maxBodyBytes = 52_428_800
    static let builtInOrigins = ["https://nrp.node.live", "http://localhost:5173", "http://127.0.0.1:5173"]

    private let system: any PrintSystem
    private let config: ConfigStore
    private let queues: [Channel: DispatchQueue]

    public init(system: any PrintSystem, config: ConfigStore) {
        self.system = system
        self.config = config
        queues = Dictionary(uniqueKeysWithValues: Channel.allCases.map { ($0, DispatchQueue(label: "live.node.print.\($0.rawValue)")) })
    }

    /// The answer when the request line and headers already decide it, so the body need not be read.
    /// `contentLength` is `nil` for a body of unknown length.
    public func response(to head: RequestHead, contentLength: Int?) -> Response? {
        if let origin = head.headers["origin"], !allows(origin) {
            return .error(403, "FORBIDDEN_ORIGIN", "\(origin) may not use NODE Print.")
        }
        if let early = routeResponse(head) ?? printHeadResponse(head, contentLength: contentLength) {
            return withCORS(early, head)
        }
        return nil
    }

    /// The answer for a body that grew past the limit while it was read.
    public func tooLarge(_ head: RequestHead) -> Response {
        withCORS(Self.tooLarge, head)
    }

    private static let tooLarge = Response.error(413, "TOO_LARGE", "The document is larger than 52,428,800 bytes.")

    /// Answers a request whose body is in. A print job takes its place in the channel's queue before this returns,
    /// so jobs print in the order their bodies arrived, whatever it takes to open them.
    public func respond(to head: RequestHead, body: Data, completion: @escaping @Sendable (Response) -> Void) {
        if let early = response(to: head, contentLength: body.count) { return completion(early) }
        guard head.path == "/print" else {
            return DispatchQueue.global().async { completion(self.withCORS(self.route(head), head)) }
        }
        let channel = Channel(rawValue: head.query["channel"] ?? "")!
        let chosen = config.config.channels[channel]
        let title = head.query["title"].flatMap { $0.isEmpty ? nil : $0 } ?? (channel == .label ? "NODE label" : "NODE document")
        let copies = copies(head)!
        queues[channel]!.async {
            completion(self.withCORS(self.print(channel, on: chosen, body: body, copies: copies, title: title), head))
        }
    }

    public func response(to head: RequestHead, body: Data) async -> Response {
        await withCheckedContinuation { continuation in
            respond(to: head, body: body) { continuation.resume(returning: $0) }
        }
    }

    private func allows(_ origin: String) -> Bool {
        Self.builtInOrigins.contains(origin) || config.config.allowedOrigins.contains(origin)
    }

    private func routeResponse(_ head: RequestHead) -> Response? {
        if head.method == "OPTIONS" { return Response(status: 204) }
        let allowed = switch head.path {
        case "/status", "/printers": "GET"
        case "/print": "POST"
        default: ""
        }
        if allowed.isEmpty { return .error(404, "NOT_FOUND", "Not found.") }
        if head.method != allowed { return .error(405, "METHOD_NOT_ALLOWED", "Method not allowed.") }
        return nil
    }

    private func printHeadResponse(_ head: RequestHead, contentLength: Int?) -> Response? {
        guard head.path == "/print" else { return nil }
        guard Channel(rawValue: head.query["channel"] ?? "") != nil else {
            return .error(400, "BAD_CHANNEL", "channel must be label or document.")
        }
        guard copies(head) != nil else { return .error(400, "BAD_COPIES", "copies must be a whole number from 1 to 99.") }
        if let contentLength, contentLength > Self.maxBodyBytes { return Self.tooLarge }
        return nil
    }

    private func copies(_ head: RequestHead) -> Int? {
        guard let text = head.query["copies"] else { return 1 }
        guard !text.isEmpty, text.allSatisfy(\.isASCIIDigit), let copies = Int(text), (1 ... 99).contains(copies) else { return nil }
        return copies
    }

    private func route(_ head: RequestHead) -> Response {
        let printers = system.printers()
        guard head.path == "/status" else {
            return Response(status: 200, json: ["printers": printers.inListOrder()])
        }
        let channels = config.config.channels
        return Response(status: 200, json: Status(
            version: NodePrint.version,
            channels: Dictionary(uniqueKeysWithValues: Channel.allCases.map {
                ($0.rawValue, ChannelStatus(chosen: channels[$0], among: printers))
            })
        ))
    }

    /// Runs on the channel's queue, in arrival order, on the printer that was chosen when the body came in.
    private func print(_ channel: Channel, on id: String?, body: Data, copies: Int, title: String) -> Response {
        guard let id else {
            return .error(409, "NO_PRINTER", "No \(channel.rawValue) printer is chosen in NODE Print.")
        }
        guard let printer = system.printers().first(where: { $0.id == id }) else {
            return .error(409, "PRINTER_UNAVAILABLE", "\(id) is not installed.")
        }
        guard printer.state == .ready || printer.state == .busy else {
            return .error(409, "PRINTER_UNAVAILABLE", "\(printer.name) is \(printer.state == .error ? "in error" : printer.state.rawValue).")
        }
        guard let job = PrintJob(channel: channel, body: body, copies: copies, title: title) else {
            return .error(400, "BAD_DOCUMENT", "The body is not a PDF, PNG or JPEG with at least one page.")
        }
        do {
            try system.print(job, on: printer)
        } catch {
            return .error(500, "PRINT_FAILED", error.message)
        }
        return Response(status: 200, json: ["job": JobReceipt(
            channel: job.channel, printer: printer.name, pages: job.pages, copies: job.copies
        )])
    }

    private func withCORS(_ response: Response, _ head: RequestHead) -> Response {
        var response = response
        response.headers.append(("Vary", "Origin"))
        guard let origin = head.headers["origin"], allows(origin) else { return response }
        response.headers += [
            ("Access-Control-Allow-Origin", origin),
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
            ("Access-Control-Allow-Headers", "Content-Type"),
            ("Access-Control-Allow-Private-Network", "true"),
            ("Access-Control-Max-Age", "600"),
        ]
        return response
    }
}

struct Status: Encodable {
    let app = "node-print"
    let version: String
    let platform = "macos"
    let channels: [String: ChannelStatus]
}

struct JobReceipt: Encodable {
    let channel: Channel
    let printer: String
    let pages: Int
    let copies: Int
}

extension Character {
    var isASCIIDigit: Bool { ("0" ... "9").contains(self) }
}

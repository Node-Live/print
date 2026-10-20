import AppKit
import CoreGraphics
import Foundation
import os
import Testing
@testable import NodePrintCore

final class FakePrinting: PrintSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Printer]
    private var failure: PrintFailure?
    private var running = 0
    private(set) var jobs: [(job: PrintJob, printer: Printer)] = []
    private(set) var overlapped = false
    var delay: TimeInterval = 0

    init(_ printers: [Printer], failure: PrintFailure? = nil) {
        list = printers
        self.failure = failure
    }

    func printers() -> [Printer] {
        lock.withLock { list }
    }

    func print(_ job: PrintJob, on printer: Printer) throws(PrintFailure) {
        lock.withLock {
            running += 1
            if running > 1 { overlapped = true }
        }
        Thread.sleep(forTimeInterval: delay)
        let failure = lock.withLock {
            running -= 1
            jobs.append((job, printer))
            return self.failure
        }
        if let failure { throw failure }
    }
}

struct Reply {
    let status: Int
    let headers: [String: String]
    let body: Data

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    var errorCode: String? {
        (json["error"] as? [String: Any])?["code"] as? String
    }
}

/// A running server on a free port with its own config file.
struct Harness {
    let server: LocalServer
    let port: UInt16
    let config: ConfigStore

    static func start(_ system: FakePrinting, channels: Config.Channels = .init(), origins: [String] = []) async throws -> Harness {
        let config = ConfigStore(url: temporaryConfigURL(), firstRun: { [] })
        config.update {
            $0.channels = channels
            $0.allowedOrigins = origins
        }
        let server = LocalServer(api: LocalAPI(system: system, config: config), port: 0)
        let port = await withCheckedContinuation { continuation in
            server.start { port in
                if let port { continuation.resume(returning: port) }
            }
        }
        return Harness(server: server, port: port, config: config)
    }

    func send(_ method: String, _ target: String, headers: [String: String] = [:], body: Data = Data()) async throws -> Reply {
        var head = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if headers["Content-Length"] == nil, !body.isEmpty || method == "POST" { head += "Content-Length: \(body.count)\r\n" }
        return try await exchange(Data((head + "\r\n").utf8) + body)
    }

    /// Blocking socket work stays off the cooperative pool, which the server itself needs.
    func exchange(_ request: Data) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try blockingExchange(request) })
            }
        }
    }

    private func blockingExchange(_ request: Data) throws -> Reply {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        _ = request.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) }

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                let headText = String(decoding: received[..<end.lowerBound], as: UTF8.self)
                var lines = headText.components(separatedBy: "\r\n")
                let statusLine = lines.removeFirst()
                if statusLine.hasPrefix("HTTP/1.1 100 ") {
                    received.removeSubrange(..<end.upperBound)
                    continue
                }
                var headers: [String: String] = [:]
                for line in lines {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if received.count - end.upperBound >= length {
                    let status = Int(statusLine.split(separator: " ")[1])!
                    return Reply(status: status, headers: headers, body: received[end.upperBound...].prefix(length))
                }
            }
            let count = recv(socket, &chunk, chunk.count, 0)
            guard count > 0 else { throw POSIXError(count == 0 ? .ECONNRESET : .ETIMEDOUT) }
            received.append(contentsOf: chunk[0 ..< count])
        }
    }
}

func samplePDF(pages: Int = 1, size: CGSize = CGSize(width: 288, height: 432)) -> Data {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    for _ in 0 ..< pages {
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 0, y: size.height - 72, width: 72, height: 72))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

@Suite struct Status {
    @Test func reportsTheChosenPrintersAndNoneForAnEmptyChannel() async throws {
        let harness = try await Harness.start(FakePrinting([rollo, brother]), channels: .init(label: rollo.id))
        let reply = try await harness.send("GET", "/status")
        #expect(reply.status == 200)
        #expect(reply.headers["content-type"] == "application/json; charset=utf-8")
        #expect(reply.json["app"] as? String == "node-print")
        #expect(reply.json["version"] as? String == NodePrint.version)
        #expect(reply.json["platform"] as? String == "macos")
        let channels = try #require(reply.json["channels"] as? [String: [String: Any]])
        #expect(channels["label"]?["state"] as? String == "ready")
        #expect((channels["label"]?["printer"] as? [String: Any])?["id"] as? String == rollo.id)
        #expect(channels["document"]?["state"] as? String == "none")
        #expect(channels["document"]?["printer"] is NSNull)
    }

    @Test func reportsAChosenPrinterThatIsGoneAsMissing() async throws {
        let harness = try await Harness.start(FakePrinting([brother]), channels: .init(label: "Gone_Printer"))
        let channels = try #require(try await harness.send("GET", "/status").json["channels"] as? [String: [String: Any]])
        #expect(channels["label"]?["state"] as? String == "missing")
        #expect((channels["label"]?["printer"] as? [String: Any])?["id"] as? String == "Gone_Printer")
    }

    @Test func reportsThePrinterState() async throws {
        var paused = brother
        paused.state = .paused
        let harness = try await Harness.start(FakePrinting([paused]), channels: .init(document: brother.id))
        let channels = try #require(try await harness.send("GET", "/status").json["channels"] as? [String: [String: Any]])
        #expect(channels["document"]?["state"] as? String == "paused")
    }
}

@Test func listsLabelPrintersFirstThenTheRestByName() async throws {
    let other = Printer(id: "Canon", name: "Canon TS6420")
    let harness = try await Harness.start(FakePrinting([brother, zebra, other, rollo]))
    let reply = try await harness.send("GET", "/printers")
    let printers = try #require(reply.json["printers"] as? [[String: Any]])
    #expect(printers.map { $0["id"] as? String } == [rollo.id, zebra.id, brother.id, other.id])
    #expect(printers.first?["default"] as? Bool == false)
    #expect(printers.first?["papers"] as? [String] == ["4x6"])
}

@Suite struct Print {
    @Test func handsTheJobToTheChosenPrinter() async throws {
        let system = FakePrinting([rollo])
        let harness = try await Harness.start(system, channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=label&copies=2", headers: ["Content-Type": "application/pdf"], body: samplePDF(pages: 3))
        #expect(reply.status == 200)
        let job = try #require(reply.json["job"] as? [String: Any])
        #expect(job["channel"] as? String == "label")
        #expect(job["printer"] as? String == "Rollo X1038")
        #expect(job["pages"] as? Int == 3)
        #expect(job["copies"] as? Int == 2)
        #expect(system.jobs.first?.job.title == "NODE label")
        #expect(system.jobs.first?.printer.id == rollo.id)
    }

    @Test func usesTheTitleAsSentAndDefaultsTheDocumentTitle() async throws {
        let system = FakePrinting([brother])
        let harness = try await Harness.start(system, channels: .init(document: brother.id))
        _ = try await harness.send("POST", "/print?channel=document&title=Pick+sheet+%23123", body: samplePDF())
        _ = try await harness.send("POST", "/print?channel=document", body: samplePDF())
        #expect(system.jobs.map(\.job.title) == ["Pick sheet #123", "NODE document"])
        #expect(system.jobs.map(\.job.copies) == [1, 1])
    }

    @Test(arguments: ["/print", "/print?channel=", "/print?channel=labels", "/print?channel=LABEL"])
    func rejectsAMissingOrUnknownChannel(target: String) async throws {
        let harness = try await Harness.start(FakePrinting([rollo]), channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", target, body: samplePDF())
        #expect(reply.status == 400)
        #expect(reply.errorCode == "BAD_CHANNEL")
    }

    @Test(arguments: ["0", "100", "-1", "two", "", "1.5", "+1"])
    func rejectsCopiesOutsideOneToNinetyNine(copies: String) async throws {
        let harness = try await Harness.start(FakePrinting([rollo]), channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=label&copies=\(copies)", body: samplePDF())
        #expect(reply.status == 400)
        #expect(reply.errorCode == "BAD_COPIES")
    }

    @Test(arguments: [Data("not a pdf".utf8), Data(), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])])
    func rejectsABodyThatIsNotADocument(body: Data) async throws {
        let system = FakePrinting([rollo])
        let harness = try await Harness.start(system, channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=label", body: body)
        #expect(reply.status == 400)
        #expect(reply.errorCode == "BAD_DOCUMENT")
        #expect(system.jobs.isEmpty)
    }

    @Test func takesABodyOfExactlyTheLimit() async throws {
        let config = ConfigStore(url: temporaryConfigURL(), firstRun: { [] })
        let api = LocalAPI(system: FakePrinting([rollo]), config: config)
        let head = RequestHead(method: "POST", target: "/print?channel=label", headers: [:])
        #expect(api.response(to: head, contentLength: 52_428_800) == nil)
        #expect(api.response(to: head, contentLength: 52_428_801)?.status == 413)
    }

    @Test func readsAChunkedBody() async throws {
        let system = FakePrinting([rollo])
        let harness = try await Harness.start(system, channels: .init(label: rollo.id))
        let pdf = samplePDF()
        let half = pdf.count / 2
        var request = Data("POST /print?channel=label HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        for part in [pdf.prefix(half), pdf.dropFirst(half)] {
            request += Data("\(String(part.count, radix: 16))\r\n".utf8) + part + Data("\r\n".utf8)
        }
        request += Data("0\r\n\r\n".utf8)
        let reply = try await harness.exchange(request)
        #expect(reply.status == 200)
        #expect(system.jobs.first?.job.pages == 1)
    }

    @Test func rejectsAChunkedBodyOnceItPassesTheLimit() async throws {
        let harness = try await Harness.start(FakePrinting([rollo]), channels: .init(label: rollo.id))
        let head = "POST /print?channel=label HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        let reply = try await harness.exchange(Data((head + "\(String(52_428_801, radix: 16))\r\n").utf8))
        #expect(reply.status == 413)
        #expect(reply.errorCode == "TOO_LARGE")
    }

    @Test func rejectsABodyOverTheLimitWithoutReadingIt() async throws {
        let harness = try await Harness.start(FakePrinting([rollo]), channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=label", headers: ["Content-Length": "\(LocalAPI.maxBodyBytes + 1)"])
        #expect(reply.status == 413)
        #expect(reply.errorCode == "TOO_LARGE")
    }

    @Test func rejectsAChannelWithNoPrinterBeforeLookingAtTheBody() async throws {
        let harness = try await Harness.start(FakePrinting([rollo]), channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=document", body: Data("not a pdf".utf8))
        #expect(reply.status == 409)
        #expect(reply.errorCode == "NO_PRINTER")
    }

    @Test func acceptsPNGAndJPEGAsOnePage() async throws {
        let system = FakePrinting([rollo])
        let harness = try await Harness.start(system, channels: .init(label: rollo.id))
        let png = fixturePNG(width: 400, height: 600)
        let image = try #require(NSBitmapImageRep(data: png))
        let jpeg = try #require(image.representation(using: .jpeg, properties: [:]))
        for (type, body) in [("image/png", png), ("image/jpeg", jpeg)] {
            let reply = try await harness.send("POST", "/print?channel=label", headers: ["Content-Type": type], body: body)
            #expect(reply.status == 200)
            #expect((reply.json["job"] as? [String: Any])?["pages"] as? Int == 1)
        }
        #expect(system.jobs.map(\.job.pages) == [1, 1])
    }

    @Test func queuesAJobForABusyPrinter() async throws {
        var printer = rollo
        printer.state = .busy
        let harness = try await Harness.start(FakePrinting([printer]), channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=label", body: samplePDF())
        #expect(reply.status == 200)
    }

    @Test(arguments: [PrinterState.offline, .paused, .error])
    func rejectsAPrinterThatCannotTakeJobsBeforeLookingAtTheBody(state: PrinterState) async throws {
        var printer = rollo
        printer.state = state
        let system = FakePrinting([printer])
        let harness = try await Harness.start(system, channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=label", body: Data("not a pdf".utf8))
        #expect(reply.status == 409)
        #expect(reply.errorCode == "PRINTER_UNAVAILABLE")
        #expect(system.jobs.isEmpty)
    }

    @Test func rejectsAChosenPrinterThatIsGone() async throws {
        let harness = try await Harness.start(FakePrinting([brother]), channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=label", body: samplePDF())
        #expect(reply.status == 409)
        #expect(reply.errorCode == "PRINTER_UNAVAILABLE")
    }

    @Test func passesOnWhatTheSystemSaysWhenItRefuses() async throws {
        let harness = try await Harness.start(
            FakePrinting([rollo], failure: PrintFailure("Rollo X1038 refused the job: out of labels")),
            channels: .init(label: rollo.id)
        )
        let reply = try await harness.send("POST", "/print?channel=label", body: samplePDF())
        #expect(reply.status == 500)
        #expect(reply.errorCode == "PRINT_FAILED")
        #expect((reply.json["error"] as? [String: Any])?["message"] as? String == "Rollo X1038 refused the job: out of labels")
    }

    @Test func runsOneJobAtATimeOnAChannel() async throws {
        let system = FakePrinting([rollo])
        system.delay = 0.05
        let harness = try await Harness.start(system, channels: .init(label: rollo.id))
        let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 3 {
                group.addTask { try await harness.send("POST", "/print?channel=label", body: samplePDF()).status }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(statuses == [200, 200, 200])
        #expect(system.jobs.count == 3)
        #expect(!system.overlapped)
    }

    @Test func printsInTheOrderTheBodiesArrived() async throws {
        let system = FakePrinting([rollo])
        let harness = try await Harness.start(system, channels: .init(label: rollo.id))
        // A takes longer to open than B, but its body is in first.
        let a = fixturePNG(width: 1624, height: 2436)
        let b = samplePDF()
        async let first = harness.send("POST", "/print?channel=label&title=A", body: a)
        try await Task.sleep(for: .milliseconds(30))
        async let second = harness.send("POST", "/print?channel=label&title=B", body: b)
        let statuses = try await [first.status, second.status]
        #expect(statuses == [200, 200])
        #expect(system.jobs.map(\.job.title) == ["A", "B"])
    }

    @Test func answersAnExpectContinueBeforeTheBody() async throws {
        let harness = try await Harness.start(FakePrinting([rollo]), channels: .init(label: rollo.id))
        let pdf = samplePDF()
        let head = "POST /print?channel=label HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(pdf.count)\r\nExpect: 100-continue\r\n\r\n"
        let reply = try await harness.exchange(Data(head.utf8) + pdf)
        #expect(reply.status == 200)
    }
}

@Suite struct Routes {
    @Test func answersAnUnknownPathWithNotFound() async throws {
        let harness = try await Harness.start(FakePrinting([]))
        let reply = try await harness.send("GET", "/print/now")
        #expect(reply.status == 404)
        #expect(reply.errorCode == "NOT_FOUND")
    }

    @Test(arguments: [("POST", "/status"), ("GET", "/print"), ("DELETE", "/printers")])
    func answersTheWrongMethodWithMethodNotAllowed(method: String, path: String) async throws {
        let harness = try await Harness.start(FakePrinting([]))
        let reply = try await harness.send(method, path)
        #expect(reply.status == 405)
        #expect(reply.errorCode == "METHOD_NOT_ALLOWED")
    }
}

@Suite struct CORS {
    @Test(arguments: ["https://nrp.node.live", "http://localhost:5173", "http://127.0.0.1:5173"])
    func allowsTheNODEOrigins(origin: String) async throws {
        let harness = try await Harness.start(FakePrinting([]))
        let reply = try await harness.send("GET", "/status", headers: ["Origin": origin])
        #expect(reply.headers["access-control-allow-origin"] == origin)
        #expect(reply.headers["access-control-allow-methods"] == "GET, POST, OPTIONS")
        #expect(reply.headers["access-control-allow-headers"] == "Content-Type")
        #expect(reply.headers["access-control-allow-private-network"] == "true")
        #expect(reply.headers["access-control-max-age"] == "600")
    }

    @Test func allowsTheOriginsListedInTheConfig() async throws {
        let harness = try await Harness.start(FakePrinting([]), origins: ["https://staging.node.test"])
        let reply = try await harness.send("GET", "/status", headers: ["Origin": "https://staging.node.test"])
        #expect(reply.headers["access-control-allow-origin"] == "https://staging.node.test")
    }

    @Test(arguments: ["https://evil.example", "https://nrp.node.live.evil.example", "http://nrp.node.live", "null"])
    func refusesOtherOriginsWithoutCORSHeaders(origin: String) async throws {
        let harness = try await Harness.start(FakePrinting([]))
        let reply = try await harness.send("GET", "/status", headers: ["Origin": origin])
        #expect(reply.status == 403)
        #expect(reply.errorCode == "FORBIDDEN_ORIGIN")
        #expect(reply.headers.keys.filter { $0.hasPrefix("access-control-") }.isEmpty)
    }

    @Test func doesNotPrintForAnotherOrigin() async throws {
        let system = FakePrinting([rollo])
        let harness = try await Harness.start(system, channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=label", headers: ["Origin": "https://evil.example"], body: samplePDF())
        #expect(reply.errorCode == "FORBIDDEN_ORIGIN")
        #expect(system.jobs.isEmpty)
    }

    @Test func refusesAPreflightFromAnotherOrigin() async throws {
        let harness = try await Harness.start(FakePrinting([]))
        let reply = try await harness.send("OPTIONS", "/print", headers: ["Origin": "https://evil.example"])
        #expect(reply.status == 403)
    }

    @Test func checksTheOriginBeforeAnythingElse() async throws {
        let harness = try await Harness.start(FakePrinting([]))
        let reply = try await harness.send("POST", "/nowhere?channel=nope", headers: ["Origin": "https://evil.example"])
        #expect(reply.errorCode == "FORBIDDEN_ORIGIN")
    }

    @Test func servesRequestsWithoutAnOrigin() async throws {
        let harness = try await Harness.start(FakePrinting([]))
        let reply = try await harness.send("GET", "/status")
        #expect(reply.status == 200)
        #expect(reply.headers["access-control-allow-origin"] == nil)
    }

    @Test(arguments: ["/print?channel=label", "/anywhere"])
    func answersAPreflightOnAnyPathWithNoContent(target: String) async throws {
        let harness = try await Harness.start(FakePrinting([]))
        let reply = try await harness.send("OPTIONS", target, headers: [
            "Origin": "https://nrp.node.live",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Private-Network": "true",
        ])
        #expect(reply.status == 204)
        #expect(reply.body.isEmpty)
        #expect(reply.headers["access-control-allow-origin"] == "https://nrp.node.live")
        #expect(reply.headers["access-control-allow-private-network"] == "true")
    }

    @Test func putsTheHeadersOnErrorsToo() async throws {
        let harness = try await Harness.start(FakePrinting([]))
        let reply = try await harness.send("POST", "/print?channel=label", headers: ["Origin": "https://nrp.node.live"], body: samplePDF())
        #expect(reply.errorCode == "NO_PRINTER")
        #expect(reply.headers["access-control-allow-origin"] == "https://nrp.node.live")
    }
}

@Test func saysSoWhenThePortIsTaken() async throws {
    let first = try await Harness.start(FakePrinting([]))
    let config = ConfigStore(url: temporaryConfigURL(), firstRun: { [] })
    let second = LocalServer(api: LocalAPI(system: FakePrinting([]), config: config), port: first.port)
    let port = await withCheckedContinuation { continuation in
        let once = OSAllocatedUnfairLock(initialState: false)
        second.start { port in
            if once.withLock({ done in defer { done = true }; return !done }) { continuation.resume(returning: port) }
        }
    }
    second.stop()
    #expect(port == nil)
}

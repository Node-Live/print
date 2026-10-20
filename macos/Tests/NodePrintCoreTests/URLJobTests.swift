import Foundation
import Network
import Testing
@testable import NodePrintCore

/// A tiny HTTP server on a free loopback port answering each path from a table.
final class FileServer: @unchecked Sendable {
    struct Answer {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var delay: TimeInterval = 0
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "file-server")
    private let answers: [String: Answer]
    private(set) var port: UInt16 = 0
    private(set) var requests = 0

    init(_ answers: [String: Answer]) async throws {
        self.answers = answers
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let listener = listener
        port = await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.resume(returning: listener.port!.rawValue) }
            }
            listener.newConnectionHandler = { [self] connection in serve(connection) }
            listener.start(queue: queue)
        }
    }

    deinit {
        listener.cancel()
    }

    func url(_ path: String) -> String {
        "http://127.0.0.1:\(port)\(path)"
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, _, _ in
            requests += 1
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let answer = answers[path] ?? Answer(status: 404)
            var head = "HTTP/1.1 \(answer.status) X\r\n"
            var headers = answer.headers
            if headers["Content-Length"] == nil { headers["Content-Length"] = "\(answer.body.count)" }
            for (name, value) in headers { head += "\(name): \(value)\r\n" }
            head += "Connection: close\r\n\r\n"
            queue.asyncAfter(deadline: .now() + answer.delay) {
                connection.send(content: Data(head.utf8) + answer.body, completion: .contentProcessed { _ in
                    if answer.headers["Content-Length"] == nil { connection.cancel() }
                })
            }
        }
    }
}

private func urlJob(_ url: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["url": url])
}

@Suite struct URLJobs {
    @Test func downloadsTheDocumentAndPrintsIt() async throws {
        let files = try await FileServer(["/label.pdf": .init(body: samplePDF(pages: 2))])
        let system = FakePrinting([rollo])
        let harness = try await Harness.start(system, channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=label", headers: ["Content-Type": "application/json"], body: urlJob(files.url("/label.pdf")))
        #expect(reply.status == 200)
        #expect((reply.json["job"] as? [String: Any])?["pages"] as? Int == 2)
        #expect(system.jobs.first?.job.pages == 2)
    }

    @Test func followsARedirectAndSniffsTheType() async throws {
        let files = try await FileServer([
            "/moved": .init(status: 302, headers: ["Location": "/label.bin"]),
            "/label.bin": .init(headers: ["Content-Type": "text/plain"], body: fixturePNG(width: 400, height: 600)),
        ])
        let system = FakePrinting([rollo])
        let harness = try await Harness.start(system, channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=label", headers: ["Content-Type": "application/json"], body: urlJob(files.url("/moved")))
        #expect(reply.status == 200)
        #expect(system.jobs.first?.job.pages == 1)
    }

    @Test(arguments: [#"{"link":"https://example.com/a.pdf"}"#, #"{"url":"ftp://example.com/a.pdf"}"#, #"{"url":"file:///etc/hosts"}"#, "not json"])
    func rejectsABodyWithoutAnHTTPURL(body: String) async throws {
        let system = FakePrinting([rollo])
        let harness = try await Harness.start(system, channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=label", headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        #expect(reply.status == 400)
        #expect(reply.errorCode == "BAD_URL")
        #expect(system.jobs.isEmpty)
    }

    @Test func checksTheURLBeforeThePrinter() async throws {
        let harness = try await Harness.start(FakePrinting([rollo]))
        let reply = try await harness.send("POST", "/print?channel=label", headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        #expect(reply.errorCode == "BAD_URL")
    }

    @Test func downloadsNothingWithoutAPrinter() async throws {
        let files = try await FileServer(["/label.pdf": .init(body: samplePDF())])
        let harness = try await Harness.start(FakePrinting([rollo]))
        let reply = try await harness.send("POST", "/print?channel=label", headers: ["Content-Type": "application/json"], body: urlJob(files.url("/label.pdf")))
        #expect(reply.errorCode == "NO_PRINTER")
        #expect(files.requests == 0)
    }

    @Test(arguments: ["/missing", "/huge"])
    func saysWhenTheDownloadFails(path: String) async throws {
        // Declares more than the limit and sends only a first chunk: refused on the header, without waiting for the rest.
        let files = try await FileServer([
            "/huge": .init(headers: ["Content-Length": "60000000", "Content-Type": "application/pdf"], body: Data(repeating: 0x25, count: 4096)),
        ])
        let system = FakePrinting([rollo])
        let harness = try await Harness.start(system, channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=label", headers: ["Content-Type": "application/json"], body: urlJob(files.url(path)))
        #expect(reply.status == 502)
        #expect(reply.errorCode == "FETCH_FAILED")
        #expect(((reply.json["error"] as? [String: Any])?["message"] as? String)?.hasPrefix(files.url(path) + " could not be downloaded: ") == true)
        #expect(system.jobs.isEmpty)
    }

    @Test func rejectsADownloadThatIsNotADocument() async throws {
        let files = try await FileServer(["/page.html": .init(body: Data("<html></html>".utf8))])
        let harness = try await Harness.start(FakePrinting([rollo]), channels: .init(label: rollo.id))
        let reply = try await harness.send("POST", "/print?channel=label", headers: ["Content-Type": "application/json"], body: urlJob(files.url("/page.html")))
        #expect(reply.errorCode == "BAD_DOCUMENT")
    }

    @Test func keepsArrivalOrderWhileDownloading() async throws {
        let files = try await FileServer(["/slow.pdf": .init(body: samplePDF(), delay: 0.2)])
        let system = FakePrinting([rollo])
        let harness = try await Harness.start(system, channels: .init(label: rollo.id))
        let a = urlJob(files.url("/slow.pdf"))
        let b = samplePDF()
        async let first = harness.send("POST", "/print?channel=label&title=A", headers: ["Content-Type": "application/json"], body: a)
        try await Task.sleep(for: .milliseconds(30))
        async let second = harness.send("POST", "/print?channel=label&title=B", body: b)
        let statuses = try await [first.status, second.status]
        #expect(statuses == [200, 200])
        #expect(system.jobs.map(\.job.title) == ["A", "B"])
    }
}

import Foundation
import Testing
@testable import NodePrintCore

/// Everything a test run writes lives under one directory, removed when the run ends.
let testDirectory: URL = {
    atexit { try? FileManager.default.removeItem(at: runDirectory()) }
    return runDirectory()
}()

private func runDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "node-print-tests-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
}

func temporaryConfigURL() -> URL {
    testDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "config.json")
}

let rollo = Printer(id: "Rollo_X1038", name: "Rollo X1038", connection: .usb, kind: .thermal, papers: [.fourBySix])
let zebra = Printer(id: "Zebra_GX420d", name: "Zebra GX420d", kind: .thermal, papers: [.fourBySix], dpi: 203)
let brother = Printer(id: "Brother_HL", name: "Brother HL-L2350DW", connection: .network, papers: [.letter, .a4], isDefault: true)

@Test func firstRunPicksTheFirstThermalAndTheDefaultPrinter() throws {
    let url = temporaryConfigURL()
    let store = ConfigStore(url: url, firstRun: { [brother, zebra, rollo] })
    #expect(store.config.channels == Config.Channels(label: "Rollo_X1038", document: "Brother_HL"))
    let saved = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    #expect(saved == store.config)
}

@Test func firstRunLeavesDocumentsEmptyWhenTheDefaultIsThermal() {
    var thermalDefault = rollo
    thermalDefault.isDefault = true
    let store = ConfigStore(url: temporaryConfigURL(), firstRun: { [thermalDefault, brother.with(isDefault: false)] })
    #expect(store.config.channels == Config.Channels(label: "Rollo_X1038", document: nil))
}

@Test func anExistingFileIsNotPickedAgain() throws {
    let url = temporaryConfigURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"channels":{"label":null,"document":"Brother_HL"},"allowedOrigins":["https://example.test"],"launchAtLogin":false}"#.utf8).write(to: url)
    let store = ConfigStore(url: url, firstRun: { [rollo, brother] })
    #expect(store.config.channels == Config.Channels(label: nil, document: "Brother_HL"))
    #expect(store.config.allowedOrigins == ["https://example.test"])
    #expect(store.config.launchAtLogin == false)
}

@Test func missingKeysTakeDefaults() throws {
    let url = temporaryConfigURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"channels":{"label":"Zebra_GX420d"}}"#.utf8).write(to: url)
    let store = ConfigStore(url: url, firstRun: { [] })
    #expect(store.config.channels == Config.Channels(label: "Zebra_GX420d", document: nil))
    #expect(store.config.allowedOrigins.isEmpty)
    #expect(store.config.launchAtLogin)
}

@Test func changesAreWrittenToTheFile() throws {
    let url = temporaryConfigURL()
    let store = ConfigStore(url: url, firstRun: { [] })
    store.update { $0.channels[.document] = "Brother_HL" }
    let text = try String(contentsOf: url, encoding: .utf8)
    let saved = try JSONDecoder().decode(Config.self, from: Data(text.utf8))
    #expect(saved.channels == Config.Channels(label: nil, document: "Brother_HL"))
    #expect(text.contains(#""label" : null"#))
}

extension Printer {
    func with(isDefault: Bool) -> Printer {
        var copy = self
        copy.isDefault = isDefault
        return copy
    }
}

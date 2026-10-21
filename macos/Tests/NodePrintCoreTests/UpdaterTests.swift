import Foundation
import Testing
@testable import NodePrintCore

/// One more than the app's own version in its last number.
private let newer: String = {
    var numbers = NodePrint.version.split(separator: ".").map { Int($0)! }
    numbers[numbers.count - 1] += 1
    return numbers.map(String.init).joined(separator: ".")
}()

private func tool(_ path: String, _ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(filePath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 { throw POSIXError(.EIO) }
}

/// A bundle of the shape the updater checks, signed ad hoc like a CI build; its executable is a copy of `true`.
private func makeBundle(at app: URL, version: String) throws {
    let files = FileManager.default
    try files.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
    try files.copyItem(at: URL(filePath: "/usr/bin/true"), to: app.appending(path: "Contents/MacOS/NODE Print"))
    let info = [
        "CFBundleExecutable": "NODE Print",
        "CFBundleIdentifier": "live.node.print.tests",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appending(path: "Contents/Info.plist"))
    try tool("/usr/bin/codesign", "--force", "--sign", "-", app.path)
}

private func version(of app: URL) -> String? {
    NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
}

/// `NODE-Print-macos.zip` as the release workflow packs it; `broken` adds a file after signing.
private func package(version: String, broken: Bool = false) throws -> Data {
    let folder = testDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let app = folder.appending(path: "NODE Print.app")
    try makeBundle(at: app, version: version)
    if broken {
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try Data("added".utf8).write(to: app.appending(path: "Contents/Resources/added"))
    }
    let zip = folder.appending(path: "NODE-Print-macos.zip")
    try tool("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zip.path)
    return try Data(contentsOf: zip)
}

/// GitHub's shape: `/latest` redirects to the release tag, `/latest/download/<asset>` serves the asset.
private func release(_ version: String, _ package: Data, served: @escaping @Sendable () -> Void = {}) async throws -> FileServer {
    try await FileServer([
        "/latest": .init(status: 302, headers: ["Location": "/Node-Live/print/releases/tag/v\(version)"]),
        "/latest/download/NODE-Print-macos.zip": .init(body: package, served: served),
    ])
}

/// The running app's bundle in a folder of its own, with the clock, activity and log its updater reads.
private struct Installation {
    let root = testDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let clock = ManualClock()
    let activity: Activity

    var bundle: URL { root.appending(path: "NODE Print.app") }
    var old: URL { root.appending(path: ".node-print-update/old.app") }
    var log: URL { root.appending(path: "update.log") }

    var logLines: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    init() throws {
        activity = Activity(clock: clock)
        try makeBundle(at: bundle, version: NodePrint.version)
    }

    func updater(_ feed: FileServer) -> Updater {
        Updater(bundle: bundle, feed: URL(string: feed.url(""))!, firstCheck: .zero, activity: activity, clock: clock, log: UpdateLog(url: log))
    }
}

@Suite struct Updates {
    @Test(arguments: [
        ("1.0.1", "1.0.0", true), ("1.10.0", "1.9.9", true), ("2", "1.9.9", true),
        ("1.0.0", "1.0.0", false), ("1.0", "1.0.0", false),
        ("1.0.0", "1.0.1", false), ("1.9.10", "1.10.0", false),
    ])
    func takesOnlyANewerVersionComparedNumberByNumber(candidate: String, current: String, newer: Bool) {
        #expect(Updater.isNewer(candidate, than: current) == newer)
    }

    @Test func readsTheVersionFromTheLatestReleaseRedirect() {
        #expect(Updater.version(fromLocation: "https://github.com/Node-Live/print/releases/tag/v1.2.3") == "1.2.3")
    }

    @Test(arguments: [
        "https://github.com/Node-Live/print/releases",
        "https://github.com/Node-Live/print/releases/tag/v1.2.3-rc.1",
        "https://github.com/Node-Live/print/releases/tag/1.2.3",
        "https://github.com/Node-Live/print/releases/tag/v",
        "https://github.com/Node-Live/print/releases/tag/v1..3",
        "https://github.com/Node-Live/print/releases/download/v1.2.3",
    ])
    func refusesARedirectThatNamesNoReleaseVersion(location: String) {
        #expect(Updater.version(fromLocation: location) == nil)
    }

    @Test func downloadsAndAppliesANewerReleaseWhenIdle() async throws {
        let installation = try Installation()
        let feed = try await release(newer, try package(version: newer))
        #expect(await installation.updater(feed).tick())
        #expect(version(of: installation.bundle) == newer)
        #expect(version(of: installation.old) == NodePrint.version)
        #expect(installation.logLines.count == 1)
    }

    @Test func checksNothingWhileAJobIsInFlight() async throws {
        let installation = try Installation()
        let feed = try await release(newer, try package(version: newer))
        installation.activity.jobArrived()
        #expect(await !installation.updater(feed).tick())
        #expect(feed.requests == 0)
        #expect(version(of: installation.bundle) == NodePrint.version)
        #expect(installation.logLines.isEmpty)
    }

    @Test func keepsTheDownloadWhenAJobArrivesAndAppliesItAtTheNextIdleCheck() async throws {
        let installation = try Installation()
        let activity = installation.activity
        let feed = try await release(newer, try package(version: newer)) { activity.jobArrived() }
        let updater = installation.updater(feed)
        #expect(await !updater.tick())
        #expect(version(of: installation.bundle) == NodePrint.version)
        let requests = feed.requests

        activity.jobEnded()
        installation.clock.advance(by: .seconds(5 * 60))
        #expect(await updater.tick())
        #expect(feed.requests == requests)
        #expect(version(of: installation.bundle) == newer)
        #expect(installation.logLines.count == 2)
    }

    @Test(arguments: [(version: "0.0.1", broken: false), (version: newer, broken: true)])
    func refusesADownloadOfAnotherVersionOrWithABrokenSignature(version packed: String, broken: Bool) async throws {
        let installation = try Installation()
        let feed = try await release(newer, try package(version: packed, broken: broken))
        #expect(await !installation.updater(feed).tick())
        #expect(version(of: installation.bundle) == NodePrint.version)
        #expect(!FileManager.default.fileExists(atPath: installation.old.path))
        #expect(installation.logLines.count == 1)
    }

    @Test func putsTheOldBundleBackWhenTheNewOneCannotTakeItsPlace() throws {
        let installation = try Installation()
        let staging = Updater.stagingFolder(beside: installation.bundle)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try Updater.install(staging.appending(path: "NODE Print.app"), over: installation.bundle)
        }
        #expect(version(of: installation.bundle) == NodePrint.version)
        #expect(!FileManager.default.fileExists(atPath: installation.old.path))
    }
}

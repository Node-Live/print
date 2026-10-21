import Foundation

/// Keeps the app current from the GitHub releases of Node-Live/print, silently and only while it is idle
/// (`docs/updates.md`).
public actor Updater {
    static let stagingName = ".node-print-update"
    private static let hour = Duration.seconds(60 * 60)

    private let bundle: URL
    private let feed: URL
    private let firstCheck: Duration
    private let activity: Activity
    private let clock: any UpdateClock
    private let log: UpdateLog
    /// A download that passed its checks after a job came in, applied at the next idle tick.
    private var kept: Staged?

    struct Staged {
        let version: String
        let app: URL
    }

    init(bundle: URL, feed: URL, firstCheck: Duration, activity: Activity, clock: any UpdateClock, log: UpdateLog) {
        self.bundle = bundle
        self.feed = feed
        self.firstCheck = firstCheck
        self.activity = activity
        self.clock = clock
        self.log = log
    }

    /// GitHub, or the feed `NODE_PRINT_UPDATES` names, which also brings the first check forward to 2 s.
    public init(activity: Activity) {
        let override = ProcessInfo.processInfo.environment["NODE_PRINT_UPDATES"]
        self.init(
            bundle: Bundle.main.bundleURL,
            feed: override.flatMap { URL(string: $0) } ?? URL(string: "https://github.com/Node-Live/print/releases")!,
            firstCheck: override == nil ? Self.hour : .seconds(2),
            activity: activity,
            clock: ContinuousClock(),
            log: UpdateLog()
        )
    }

    /// What the previous version left beside the bundle when it installed this one.
    public static func removeStaging(beside bundle: URL = Bundle.main.bundleURL) {
        guard bundle.pathExtension == "app" else { return }
        try? FileManager.default.removeItem(at: stagingFolder(beside: bundle))
    }

    /// Checks on the timer until an update is installed, then starts the helper that opens it once this process has
    /// ended. `true` when the helper is waiting and the caller should stop the server and exit.
    public func run() async -> Bool {
        var next = clock.now + firstCheck
        while true {
            do {
                try await clock.sleep(until: next)
            } catch {
                return false
            }
            if await tick() {
                do {
                    try Relaunch.afterExit(of: getpid(), open: bundle)
                    return true
                } catch {
                    log.write("failed: the new version could not be started (\(error.localizedDescription)); it starts at the next launch")
                    return false
                }
            }
            next = clock.now + Self.hour
        }
    }

    /// One check; `true` once a newer version is installed in place of the running bundle.
    func tick() async -> Bool {
        guard activity.isIdle else { return false }
        let staged: Staged
        let downloadedNow = kept == nil
        if let kept {
            staged = kept
        } else {
            do {
                let version = try await latestVersion()
                guard Self.isNewer(version, than: NodePrint.version) else { return false }
                staged = try await download(version)
            } catch {
                log.write("failed: \(Self.describe(error))")
                return false
            }
        }
        guard activity.isIdle else {
            kept = staged
            if downloadedNow { log.write("downloaded \(staged.version); a job came in, so it is applied at the next idle check") }
            return false
        }
        kept = nil
        do {
            try Self.install(staged.app, over: bundle)
        } catch {
            log.write("failed: \(staged.version) could not be installed: \(error.localizedDescription)")
            return false
        }
        log.write(downloadedNow ? "downloaded and applied \(staged.version)" : "applied \(staged.version), downloaded at an earlier check")
        return true
    }

    /// `HEAD <feed>/latest`, whose redirect names the newest release; the redirect is read, not followed.
    private func latestVersion() async throws -> String {
        let url = feed.appending(path: "latest")
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: .ephemeral, delegate: RedirectRefusal(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let response: URLResponse
        do {
            response = try await session.data(for: request).1
        } catch {
            throw UpdateFailure("\(url.absoluteString) could not be reached: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (300 ..< 400).contains(status), let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") else {
            throw UpdateFailure("\(url.absoluteString) answered \(status) instead of a redirect to the latest release")
        }
        guard let version = Self.version(fromLocation: location) else {
            throw UpdateFailure("\(url.absoluteString) redirects to \(location), which names no release version")
        }
        return version
    }

    /// Downloads and unpacks the package into the staging folder beside the bundle, the same volume, and accepts the
    /// app in it only when its signature holds and it is `version`.
    private func download(_ version: String) async throws -> Staged {
        guard bundle.pathExtension == "app" else {
            throw UpdateFailure("NODE Print runs from \(bundle.path), not from a .app bundle, so it cannot update itself")
        }
        let files = FileManager.default
        let folder = Self.stagingFolder(beside: bundle)
        let package = folder.appending(path: "NODE-Print-macos.zip")
        let app = folder.appending(path: "NODE Print.app")
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            for leftover in [package, app] where files.fileExists(atPath: leftover.path) {
                try files.removeItem(at: leftover)
            }
            let probe = folder.appending(path: ".write-check")
            try Data().write(to: probe)
            try files.removeItem(at: probe)
        } catch {
            throw UpdateFailure("\(folder.path) cannot be written: \(error.localizedDescription)")
        }
        try await fetch(feed.appending(path: "latest/download/NODE-Print-macos.zip"), to: package)
        try await Self.run("/usr/bin/ditto", ["-x", "-k", package.path, folder.path], failing: "the download of \(version) could not be unpacked")
        try? files.removeItem(at: package)
        try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], failing: "the download of \(version) fails its signature check")
        let found = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        guard found == version else {
            throw UpdateFailure("the download of \(version) is version \(found ?? "unknown")")
        }
        return Staged(version: version, app: app)
    }

    private func fetch(_ url: URL, to file: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 5 * 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (downloaded, response): (URL, URLResponse)
        do {
            (downloaded, response) = try await session.download(from: url)
        } catch {
            throw UpdateFailure("\(url.absoluteString) could not be downloaded: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            try? FileManager.default.removeItem(at: downloaded)
            throw UpdateFailure("\(url.absoluteString) could not be downloaded: the server answered \(status)")
        }
        try FileManager.default.moveItem(at: downloaded, to: file)
    }

    /// Renames the running bundle to `old.app` in the staging folder and the new one into its place, putting the old
    /// one back when the second rename fails. `old.app` stays: it is the image of the running process, and macOS
    /// kills a child spawned from a deleted image.
    static func install(_ app: URL, over bundle: URL) throws {
        let files = FileManager.default
        let old = stagingFolder(beside: bundle).appending(path: "old.app")
        try files.moveItem(at: bundle, to: old)
        do {
            try files.moveItem(at: app, to: bundle)
        } catch {
            try? files.moveItem(at: old, to: bundle)
            throw error
        }
    }

    static func stagingFolder(beside bundle: URL) -> URL {
        bundle.deletingLastPathComponent().appending(path: stagingName, directoryHint: .isDirectory)
    }

    /// The version a redirect to `…/tag/v<version>` names; `nil` for anything else, a prerelease tag included.
    static func version(fromLocation location: String) -> String? {
        guard let path = URL(string: location)?.pathComponents, path.count >= 2, path[path.count - 2] == "tag",
              let tag = path.last, tag.hasPrefix("v")
        else { return nil }
        let version = String(tag.dropFirst())
        return numbers(version) == nil ? nil : version
    }

    /// Compared number by number, a missing one counting as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var candidate = numbers(candidate), var current = numbers(current) else { return false }
        let count = max(candidate.count, current.count)
        candidate += Array(repeating: 0, count: count - candidate.count)
        current += Array(repeating: 0, count: count - current.count)
        return current.lexicographicallyPrecedes(candidate)
    }

    private static func numbers(_ version: String) -> [Int]? {
        let numbers = version.split(separator: ".", omittingEmptySubsequences: false).map { part in
            part.allSatisfy(\.isASCIIDigit) ? Int(part) : nil
        }
        return numbers.contains(nil) ? nil : numbers.compactMap(\.self)
    }

    /// Runs a tool without holding a thread while it works; a non-zero exit fails with what it printed.
    private static func run(_ tool: String, _ arguments: [String], failing message: String) async throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: UpdateFailure("\(message): \(error.localizedDescription)"))
            }
        }
        guard process.terminationStatus == 0 else {
            let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw UpdateFailure("\(message): \(printed.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? UpdateFailure)?.message ?? error.localizedDescription
    }
}

struct UpdateFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// `~/Library/Logs/NODE Print/update.log`: one line per check that downloaded, applied or failed.
struct UpdateLog: Sendable {
    let url: URL

    init(url: URL = URL.libraryDirectory.appending(path: "Logs/NODE Print/update.log")) {
        self.url = url
    }

    func write(_ message: String) {
        let line = Data("\(Date().ISO8601Format()) \(message)\n".utf8)
        let files = FileManager.default
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? line.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}

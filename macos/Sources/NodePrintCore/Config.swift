import Foundation
import os

public struct Config: Codable, Equatable, Sendable {
    public struct Channels: Codable, Equatable, Sendable {
        public var label: String?
        public var document: String?

        public init(label: String? = nil, document: String? = nil) {
            self.label = label
            self.document = document
        }

        public subscript(channel: Channel) -> String? {
            get { channel == .label ? label : document }
            set {
                if channel == .label { label = newValue } else { document = newValue }
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(label, forKey: .label)
            try c.encode(document, forKey: .document)
        }
    }

    public var channels = Channels()
    public var allowedOrigins: [String] = []
    public var launchAtLogin = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channels = try c.decodeIfPresent(Channels.self, forKey: .channels) ?? Channels()
        allowedOrigins = try c.decodeIfPresent([String].self, forKey: .allowedOrigins) ?? []
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
    }

    /// The first-run choice: the first thermal printer for labels, the system default (unless it is thermal) for documents.
    public static func firstRunChannels(for printers: [Printer]) -> Channels {
        let label = printers.inListOrder().first { $0.kind == .thermal }
        let document = printers.first { $0.isDefault && $0.kind != .thermal }
        return Channels(label: label?.id, document: document?.id)
    }
}

public final class ConfigStore: Sendable {
    public let url: URL
    private let state: OSAllocatedUnfairLock<Config>

    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "NODE Print", directoryHint: .isDirectory)
            .appending(path: "config.json", directoryHint: .notDirectory)
    }

    /// Loads the config file; when there is none yet, picks printers from `printers` and writes the file.
    public init(url: URL = ConfigStore.defaultURL, firstRun printers: () -> [Printer]) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            let config = (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
            state = OSAllocatedUnfairLock(initialState: config)
        } else {
            var config = Config()
            config.channels = Config.firstRunChannels(for: printers())
            state = OSAllocatedUnfairLock(initialState: config)
            save(config)
        }
    }

    public var config: Config {
        state.withLock { $0 }
    }

    public func update(_ change: (inout Config) -> Void) {
        let config = state.withLockUnchecked { config in
            change(&config)
            return config
        }
        save(config)
    }

    private func save(_ config: Config) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(config).write(to: url, options: .atomic)
        } catch {
            Logger.core.error("cannot write \(self.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Logger {
    static let core = Logger(subsystem: "live.node.print", category: "core")
}

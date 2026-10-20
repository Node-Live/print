import Foundation

public enum Channel: String, Codable, CaseIterable, Sendable {
    case label
    case document
}

public enum Connection: String, Codable, Sendable {
    case usb
    case network
    case bluetooth
    case other
}

public enum PrinterKind: String, Codable, Sendable {
    case thermal
    case other
}

public enum Paper: String, Codable, CaseIterable, Sendable {
    case fourBySix = "4x6"
    case letter = "Letter"
    case a4 = "A4"
}

public enum PrinterLanguage: String, Codable, Sendable {
    case zpl
    case driver
}

public enum PrinterState: String, Codable, Sendable {
    case ready
    case busy
    case paused
    case offline
    case error
}

public enum ChannelState: String, Codable, Sendable {
    case ready
    case busy
    case paused
    case offline
    case error
    case missing
    case none
}

public struct Printer: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var model: String
    public var connection: Connection
    public var kind: PrinterKind
    public var papers: [Paper]
    public var language: PrinterLanguage
    public var dpi: Int
    public var state: PrinterState
    public var stateMessage: String
    public var isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, model, connection, kind, papers, language, dpi, state, stateMessage
        case isDefault = "default"
    }

    public init(
        id: String, name: String, model: String = "", connection: Connection = .other,
        kind: PrinterKind = .other, papers: [Paper] = [], language: PrinterLanguage = .driver,
        dpi: Int = 0, state: PrinterState = .ready, stateMessage: String = "", isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.connection = connection
        self.kind = kind
        self.papers = papers
        self.language = language
        self.dpi = dpi
        self.state = state
        self.stateMessage = stateMessage
        self.isDefault = isDefault
    }
}

extension [Printer] {
    /// Label printers first, then the rest, each group by name.
    public func inListOrder() -> [Printer] {
        sorted { a, b in
            if (a.kind == .thermal) != (b.kind == .thermal) { return a.kind == .thermal }
            let byName = a.name.localizedCaseInsensitiveCompare(b.name)
            return byName == .orderedSame ? a.id < b.id : byName == .orderedAscending
        }
    }
}

public struct ChannelStatus: Codable, Equatable, Sendable {
    public var printer: Printer?
    public var state: ChannelState

    public init(printer: Printer?, state: ChannelState) {
        self.printer = printer
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case printer, state
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(printer, forKey: .printer)
        try c.encode(state, forKey: .state)
    }

    /// What a channel looks like given the chosen printer id and the printers the system reports.
    public init(chosen id: String?, among printers: [Printer]) {
        guard let id else {
            self.init(printer: nil, state: .none)
            return
        }
        guard let printer = printers.first(where: { $0.id == id }) else {
            self.init(printer: Printer(id: id, name: id, state: .offline), state: .missing)
            return
        }
        let state: ChannelState = switch printer.state {
        case .ready: .ready
        case .busy: .busy
        case .paused: .paused
        case .offline: .offline
        case .error: .error
        }
        self.init(printer: printer, state: state)
    }
}

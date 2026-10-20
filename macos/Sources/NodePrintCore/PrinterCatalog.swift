import CUPS
import Foundation

/// The printers CUPS knows, described the way `docs/protocol.md` wants them.
public enum PrinterCatalog {
    public static func printers() -> [Printer] {
        var dests: UnsafeMutablePointer<cups_dest_t>?
        let count = cupsGetDests2(nil, &dests)
        defer { cupsFreeDests(count, dests) }
        guard let dests else { return [] }
        return (0 ..< Int(count)).compactMap { i in
            var dest = dests[i]
            guard dest.instance == nil else { return nil }
            return printer(&dest)
        }
    }

    private static func printer(_ dest: inout cups_dest_t) -> Printer? {
        let id = String(cString: dest.name)
        let options = UnsafeBufferPointer(start: dest.options, count: Int(dest.num_options))
            .reduce(into: [String: String]()) { $0[String(cString: $1.name)] = String(cString: $1.value) }
        let deviceURI = options["device-uri"] ?? ""
        let printerType = Int(options["printer-type"] ?? "") ?? 0
        let displayName = options["printer-info"] ?? ""
        if isVirtual(deviceURI: deviceURI, printerType: printerType) || hasVirtualName(id) || hasVirtualName(displayName) {
            return nil
        }

        var sizes: [(width: Int, length: Int)] = []
        var dpi = 0
        if let info = cupsCopyDestInfo(nil, &dest) {
            defer { cupsFreeDestInfo(info) }
            for index in 0 ..< cupsGetDestMediaCount(nil, &dest, info, 0) {
                var size = cups_size_t()
                if cupsGetDestMediaByIndex(nil, &dest, info, index, 0, &size) != 0 {
                    sizes.append((Int(size.width), Int(size.length)))
                }
            }
            if let resolution = cupsFindDestDefault(nil, &dest, info, "printer-resolution") {
                var y: Int32 = 0
                var units = IPP_RES_PER_INCH
                let x = Int(ippGetResolution(resolution, 0, &y, &units))
                dpi = units == IPP_RES_PER_CM ? Int((Double(x) * 2.54).rounded()) : x
            }
        }

        let state = state(
            printerState: Int(options["printer-state"] ?? "") ?? 3,
            reasons: (options["printer-state-reasons"] ?? "").split(separator: ",").map(String.init),
            accepting: options["printer-is-accepting-jobs"] != "false"
        )
        return Printer(
            id: id,
            name: displayName.isEmpty ? id : displayName,
            model: options["printer-make-and-model"] ?? "",
            connection: connection(deviceURI: deviceURI),
            kind: isLabelPrinter(sizes) ? .thermal : .other,
            papers: papers(sizes),
            dpi: dpi,
            state: state,
            stateMessage: state == .error ? stateMessage(printerURI: options["printer-uri-supported"] ?? "") : "",
            isDefault: dest.is_default != 0
        )
    }

    static func connection(deviceURI: String) -> Connection {
        let scheme = deviceURI.prefix { $0 != ":" }.lowercased()
        switch scheme {
        case "usb", "ippusb": return .usb
        case "bluetooth": return .bluetooth
        case "dnssd", "mdns", "ipp", "ipps", "http", "https", "socket", "lpd", "smb": return .network
        default: return .other
        }
    }

    /// Queues that do not reach a device: fax queues, and queues whose device URI names no installed CUPS backend
    /// (PDF writers and similar), decided by the backend, never by the queue's name.
    static func isVirtual(deviceURI: String, printerType: Int, backends: Set<String> = installedBackends) -> Bool {
        let scheme = deviceURI.prefix { $0 != ":" }.lowercased()
        return printerType & Int(CUPS_PRINTER_FAX.rawValue) != 0 || !backends.contains(scheme)
    }

    /// "Print to PDF" style drivers that sit on an ordinary backend still give themselves away by name.
    static func hasVirtualName(_ name: String) -> Bool {
        ["pdf", "xps", "fax", "onenote"].contains { name.localizedCaseInsensitiveContains($0) }
    }

    static let installedBackends = Set((try? FileManager.default.contentsOfDirectory(atPath: "/usr/libexec/cups/backend")) ?? [])

    /// The first of offline, error, paused, busy that CUPS reports; ready otherwise.
    static func state(printerState: Int, reasons: [String], accepting: Bool) -> PrinterState {
        if reasons.contains("offline-report") || reasons.contains("offline") { return .offline }
        if reasons.contains(where: { $0.hasSuffix("-error") }) { return .error }
        if reasons.contains("paused") || printerState == 5 || !accepting { return .paused }
        return printerState == 4 ? .busy : .ready
    }

    private static func stateMessage(printerURI: String) -> String {
        let request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES)
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, printerURI)
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", nil, "printer-state-message")
        guard let response = cupsDoRequest(nil, request, "/") else { return "" }
        defer { ippDelete(response) }
        guard let attribute = ippFindAttribute(response, "printer-state-message", IPP_TAG_TEXT),
              let text = ippGetString(attribute, 0, nil)
        else { return "" }
        return String(cString: text)
    }

    /// Sizes are CUPS media sizes in hundredths of a millimetre.
    static func papers(_ sizes: [(width: Int, length: Int)]) -> [Paper] {
        let known: [(Paper, Int, Int)] = [(.fourBySix, 10160, 15240), (.letter, 21590, 27940), (.a4, 21000, 29700)]
        return known.compactMap { paper, width, length in
            sizes.contains { size in
                let short = min(size.width, size.length)
                let long = max(size.width, size.length)
                return abs(short - width) <= 100 && abs(long - length) <= 100
            } ? paper : nil
        }
    }

    /// A label printer lists a paper no wider than 4.25 in (108 mm) and neither Letter nor A4, which every office
    /// printer lists; label drivers often list wide sizes for other models too.
    static func isLabelPrinter(_ sizes: [(width: Int, length: Int)]) -> Bool {
        let office = papers(sizes).contains { $0 == .letter || $0 == .a4 }
        return !office && sizes.contains { min($0.width, $0.length) <= 10800 }
    }
}

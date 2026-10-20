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
        if isVirtual(deviceURI: deviceURI, printerType: printerType) { return nil }

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

        let model = options["printer-make-and-model"] ?? ""
        let zpl = isZPL(makeAndModel: model, deviceID: deviceID(queue: id))
        let state = state(
            printerState: Int(options["printer-state"] ?? "") ?? 3,
            reasons: (options["printer-state-reasons"] ?? "").split(separator: ",").map(String.init),
            accepting: options["printer-is-accepting-jobs"] != "false"
        )
        let info = options["printer-info"] ?? ""
        return Printer(
            id: id,
            name: info.isEmpty ? id : info,
            model: model,
            connection: connection(deviceURI: deviceURI),
            kind: zpl || isLabelSize(largest: sizes) ? .thermal : .other,
            papers: papers(sizes),
            language: zpl ? .zpl : .driver,
            dpi: dpi == 0 && zpl ? 203 : dpi,
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

    /// Queues that write a file or send a fax instead of printing on paper.
    static func isVirtual(deviceURI: String, printerType: Int) -> Bool {
        let scheme = deviceURI.prefix { $0 != ":" }.lowercased()
        return printerType & Int(CUPS_PRINTER_FAX.rawValue) != 0
            || ["file", "cups-pdf", "pdfwriter", "fax"].contains(scheme)
    }

    static func isZPL(makeAndModel: String, deviceID: String) -> Bool {
        let model = makeAndModel.uppercased()
        let commands = deviceID.split(separator: ";").compactMap { field -> String? in
            let parts = field.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let key = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
            return key == "CMD" || key == "COMMAND SET" ? parts[1].uppercased() : nil
        }
        if commands.contains(where: { $0.contains("ZPL") }) || model.contains("ZPL") { return true }
        return model.contains("ZEBRA") && !model.contains("EPL") && !model.contains("CPCL")
    }

    /// CUPS keeps the IEEE 1284 device id of a queue in its PPD, if anywhere.
    private static func deviceID(queue: String) -> String {
        guard let ppd = try? String(contentsOfFile: "/etc/cups/ppd/\(queue).ppd", encoding: .utf8) else { return "" }
        for line in ppd.split(separator: "\n") where line.hasPrefix("*1284DeviceID:") {
            return line.dropFirst("*1284DeviceID:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"\r"))
        }
        return ""
    }

    static func state(printerState: Int, reasons: [String], accepting: Bool) -> PrinterState {
        if reasons.contains(where: { $0.hasSuffix("-error") }) { return .error }
        if reasons.contains("offline-report") || reasons.contains("offline") { return .offline }
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

    /// A queue whose largest paper is no wider than a 4 in label roll (108 mm) is a label printer.
    static func isLabelSize(largest sizes: [(width: Int, length: Int)]) -> Bool {
        guard let largest = sizes.max(by: { $0.width * $0.length < $1.width * $1.length }) else { return false }
        return min(largest.width, largest.length) <= 10800
    }
}

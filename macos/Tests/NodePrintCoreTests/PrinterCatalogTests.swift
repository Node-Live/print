import Testing
@testable import NodePrintCore

@Test(arguments: [
    ("usb://Zebra%20Technologies/ZTC%20GX420d?serial=1", Connection.usb),
    ("ippusb://Brother/HL?serial=2", .usb),
    ("dnssd://Brother%20HL._ipp._tcp.local./?uuid=1", .network),
    ("ipp://192.168.1.20/ipp/print", .network),
    ("ipps://printer.local/ipp/print", .network),
    ("socket://192.168.1.30:9100", .network),
    ("lpd://192.168.1.40/queue", .network),
    ("bluetooth://00-11-22-33-44-55", .bluetooth),
    ("serial:/dev/cu.usbserial", .other),
])
func connectionFollowsTheDeviceURI(uri: String, connection: Connection) {
    #expect(PrinterCatalog.connection(deviceURI: uri) == connection)
}

@Test func hidesQueuesWithoutAPrintingBackend() {
    let backends: Set = ["usb", "ipp", "dnssd", "socket"]
    #expect(PrinterCatalog.isVirtual(deviceURI: "cups-pdf:/", printerType: 0, backends: backends))
    #expect(PrinterCatalog.isVirtual(deviceURI: "pdfwriter:/", printerType: 0, backends: backends))
    #expect(PrinterCatalog.isVirtual(deviceURI: "ipp://fax.local/ipp/fax", printerType: 0x40000, backends: backends))
    #expect(!PrinterCatalog.isVirtual(deviceURI: "usb://Brother/HL", printerType: 0x9004, backends: backends))
    #expect(!PrinterCatalog.isVirtual(deviceURI: "socket://127.0.0.1:9100", printerType: 0, backends: backends))
}

@Test func knowsTheBackendsThisMacHas() {
    #expect(PrinterCatalog.installedBackends.isSuperset(of: ["usb", "ipp", "dnssd", "socket", "lpd"]))
}

@Test func callsAQueueWithALabelSizeAndNoOfficePaperThermal() {
    // The CUPS Zebra driver lists 4 in labels next to sizes up to 8 x 6.5 in.
    #expect(PrinterCatalog.isLabelPrinter([(5080, 2540), (10160, 15240), (10160, 33020), (20320, 16510)]))
    #expect(PrinterCatalog.isLabelPrinter([(10160, 15240)]))
    #expect(!PrinterCatalog.isLabelPrinter([(10160, 15240), (21590, 27940)]))
    #expect(!PrinterCatalog.isLabelPrinter([(10160, 15240), (21000, 29700)]))
    #expect(!PrinterCatalog.isLabelPrinter([(14800, 21000), (25700, 36400)]))
    #expect(!PrinterCatalog.isLabelPrinter([]))
}

@Test func reportsOnlyTheThreeKnownPapers() {
    #expect(PrinterCatalog.papers([(10160, 15240), (21590, 27940), (21000, 29700), (14800, 21000)]) == [.fourBySix, .letter, .a4])
    #expect(PrinterCatalog.papers([(15240, 10160)]) == [.fourBySix])
    #expect(PrinterCatalog.papers([(21590, 35560)]).isEmpty)
}

@Test(arguments: [
    (3, ["none"], true, PrinterState.ready),
    (4, ["none"], true, .busy),
    (5, ["paused"], true, .paused),
    (3, ["none"], false, .paused),
    (4, ["paused"], true, .paused),
    (3, ["offline-report"], true, .offline),
    (5, ["media-empty-error", "paused"], true, .error),
    (5, ["media-empty-error", "offline-report", "paused"], true, .offline),
])
func mapsTheCUPSState(state: Int, reasons: [String], accepting: Bool, expected: PrinterState) {
    #expect(PrinterCatalog.state(printerState: state, reasons: reasons, accepting: accepting) == expected)
}

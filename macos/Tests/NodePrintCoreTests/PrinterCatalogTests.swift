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

@Test func hidesQueuesThatDoNotPrintOnPaper() {
    #expect(PrinterCatalog.isVirtual(deviceURI: "cups-pdf:/", printerType: 0))
    #expect(PrinterCatalog.isVirtual(deviceURI: "file:///tmp/out.prn", printerType: 0))
    #expect(PrinterCatalog.isVirtual(deviceURI: "ipp://fax.local/ipp/fax", printerType: 0x40000))
    #expect(!PrinterCatalog.isVirtual(deviceURI: "usb://Brother/HL", printerType: 0x9004))
}

@Test(arguments: [
    ("Zebra ZPL Label Printer", "", true),
    ("ZDesigner GX420d ZPL", "", true),
    ("Generic Label Printer", "MFG:Zebra Technologies;CMD:ZPL,EPL;MDL:GX420d;", true),
    ("Zebra EPL2 Label Printer", "", false),
    ("Zebra CPCL Label Printer", "", false),
    ("Generic Label Printer", "MFG:Zebra;CMD:EPL;MDL:LP2844;", false),
    ("Brother HL-L2350DW series", "MFG:Brother;CMD:PJL,PCL,PCLXL,URF;", false),
])
func recognisesZPLQueues(model: String, deviceID: String, zpl: Bool) {
    #expect(PrinterCatalog.isZPL(makeAndModel: model, deviceID: deviceID) == zpl)
}

@Test func callsAQueueWhoseLargestPaperIsALabelThermal() {
    #expect(PrinterCatalog.isLabelSize(largest: [(5080, 2540), (10160, 15240), (10160, 20320)]))
    #expect(!PrinterCatalog.isLabelSize(largest: [(10160, 15240), (21590, 27940)]))
    #expect(!PrinterCatalog.isLabelSize(largest: []))
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
    (3, ["offline-report"], true, .offline),
    (5, ["media-empty-error", "paused"], true, .error),
])
func mapsTheCUPSState(state: Int, reasons: [String], accepting: Bool, expected: PrinterState) {
    #expect(PrinterCatalog.state(printerState: state, reasons: reasons, accepting: accepting) == expected)
}

import AppKit
import CUPS
import PDFKit

public struct PrintJob: @unchecked Sendable {
    public let channel: Channel
    public let pdf: Data
    public let document: CGPDFDocument
    public let copies: Int
    public let title: String

    /// `nil` when `pdf` is not a PDF that opens, or has no pages.
    public init?(channel: Channel, pdf: Data, copies: Int, title: String) {
        guard let provider = CGDataProvider(data: pdf as CFData),
              let document = CGPDFDocument(provider),
              document.isUnlocked || document.unlockWithPassword(""),
              document.numberOfPages > 0
        else { return nil }
        self.channel = channel
        self.pdf = pdf
        self.document = document
        self.copies = copies
        self.title = title
    }

    public var pages: [CGPDFPage] {
        (1 ... document.numberOfPages).compactMap { document.page(at: $0) }
    }
}

public struct PrintFailure: Error, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

public protocol PrintSystem: Sendable {
    func printers() -> [Printer]
    /// Hands the job to the OS queue; runs on the channel's own serial queue.
    func print(_ job: PrintJob, on printer: Printer) throws(PrintFailure)
}

/// Printing through CUPS: raw ZPL for ZPL label printers, PDFKit through the driver for everything else.
public struct SystemPrinting: PrintSystem {
    /// When set, driver jobs are written to PDF files in this directory and ZPL jobs to `.zpl` files, instead of printing.
    public let saveDirectory: URL?

    public init(saveDirectory: URL? = nil) {
        self.saveDirectory = saveDirectory
    }

    public func printers() -> [Printer] {
        PrinterCatalog.printers()
    }

    public func print(_ job: PrintJob, on printer: Printer) throws(PrintFailure) {
        if job.channel == .label, printer.language == .zpl {
            let zpl = ZPL.job(pages: job.pages.map { LabelLayout.bitmap($0, dpi: printer.dpi) }, copies: job.copies)
            try sendRaw(Data(zpl.utf8), to: printer, title: job.title)
        } else {
            let result = DispatchQueue.main.sync {
                MainActor.assumeIsolated { Result { () throws(PrintFailure) in try printWithDriver(job, on: printer) } }
            }
            try result.get()
        }
    }

    private func sendRaw(_ data: Data, to printer: Printer, title: String) throws(PrintFailure) {
        if let saveDirectory {
            do {
                try data.write(to: saveDirectory.appending(path: "\(title).zpl"))
                return
            } catch {
                throw PrintFailure(error.localizedDescription)
            }
        }
        let queue = printer.id
        let job = cupsCreateJob(nil, queue, title, 0, nil)
        guard job > 0 else { throw refused(printer) }
        guard cupsStartDocument(nil, queue, job, title, CUPS_FORMAT_RAW, 1) == HTTP_STATUS_CONTINUE else {
            let failure = refused(printer)
            cupsCancelJob2(nil, queue, job, 0)
            throw failure
        }
        let written = data.withUnsafeBytes { cupsWriteRequestData(nil, $0.baseAddress, $0.count) }
        guard written == HTTP_STATUS_CONTINUE else {
            let failure = refused(printer)
            _ = cupsFinishDocument(nil, queue)
            cupsCancelJob2(nil, queue, job, 0)
            throw failure
        }
        guard cupsFinishDocument(nil, queue) == IPP_STATUS_OK else { throw refused(printer) }
    }

    private func refused(_ printer: Printer) -> PrintFailure {
        PrintFailure("\(printer.name) refused the job: \(String(cString: cupsLastErrorString()))")
    }

    @MainActor
    private func printWithDriver(_ job: PrintJob, on printer: Printer) throws(PrintFailure) {
        guard let document = PDFDocument(data: job.pdf) else { throw PrintFailure("The PDF cannot be opened.") }
        if job.channel == .label {
            for index in 0 ..< document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let box = page.bounds(for: .cropBox)
                let landscape = page.rotation % 180 == 0 ? box.width > box.height : box.height > box.width
                if landscape { page.rotation = (page.rotation + 90) % 360 }
            }
        }
        let info = try printInfo(for: printer, channel: job.channel, copies: job.copies)
        if let saveDirectory {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = saveDirectory.appending(path: "\(job.title).pdf")
        }
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: job.channel == .document)
        else { throw PrintFailure("\(printer.name) cannot print this PDF.") }
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = job.title
        guard operation.run() else { throw PrintFailure("\(printer.name) did not take the job.") }
    }

    /// A print info for `printer` with the channel's paper set on the job: 4 × 6 in for labels (the variant with the
    /// smallest margins, so the page fits the whole label), Letter for documents (the variant with the largest
    /// margins, so borderless modes are not picked).
    @MainActor
    private func printInfo(for printer: Printer, channel: Channel, copies: Int) throws(PrintFailure) -> NSPrintInfo {
        guard let pmPrinter = PMPrinterCreateFromPrinterID(printer.id as CFString) else {
            throw PrintFailure("\(printer.name) is not installed.")
        }
        defer { PMRelease(UnsafeRawPointer(pmPrinter)) }
        let info = NSPrintInfo()
        let session = OpaquePointer(info.pmPrintSession())
        guard PMSessionSetCurrentPMPrinter(session, pmPrinter) == noErr else {
            throw PrintFailure("\(printer.name) cannot be selected for printing.")
        }
        info.updateFromPMPrintSettings()

        let size = channel == .label ? CGSize(width: 288, height: 432) : CGSize(width: 612, height: 792)
        var list: Unmanaged<CFArray>?
        var candidates: [(paper: PMPaper, margins: Double)] = []
        if PMPrinterGetPaperList(pmPrinter, &list) == noErr, let array = list?.takeUnretainedValue() {
            for index in 0 ..< CFArrayGetCount(array) {
                guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
                let paper = PMPaper(raw)
                var width = 0.0, height = 0.0
                var margins = PMPaperMargins()
                PMPaperGetWidth(paper, &width)
                PMPaperGetHeight(paper, &height)
                PMPaperGetMargins(paper, &margins)
                if abs(width - size.width) < 1.5, abs(height - size.height) < 1.5 {
                    candidates.append((paper, margins.top + margins.left + margins.bottom + margins.right))
                }
            }
        }
        candidates.sort { $0.margins < $1.margins }
        var custom: PMPaper?
        defer { if let custom { PMRelease(UnsafeRawPointer(custom)) } }
        let paper: PMPaper
        if let match = channel == .label ? candidates.first : candidates.last {
            paper = match.paper
        } else {
            var margins = PMPaperMargins()
            let name = channel == .label ? "4 x 6 in" : "Letter"
            guard PMPaperCreateCustom(pmPrinter, "NODE \(name)" as CFString, name as CFString, size.width, size.height, &margins, &custom) == noErr,
                  let custom
            else { throw PrintFailure("\(printer.name) cannot take \(name) paper.") }
            paper = custom
        }
        var format: PMPageFormat?
        guard PMCreatePageFormatWithPMPaper(&format, paper) == noErr, let format else {
            throw PrintFailure("\(printer.name) cannot take this paper.")
        }
        defer { PMRelease(UnsafeRawPointer(format)) }
        PMSessionValidatePageFormat(session, format, nil)
        PMCopyPageFormat(format, OpaquePointer(info.pmPageFormat()))
        info.updateFromPMPageFormat()

        PMSetCopies(OpaquePointer(info.pmPrintSettings()), UInt32(copies), false)
        info.updateFromPMPrintSettings()
        return info
    }
}

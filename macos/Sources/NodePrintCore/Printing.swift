import Accelerate
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A print request whose body opened: the document as a PDF (an image body becomes a one-page PDF).
public struct PrintJob: Sendable {
    public let channel: Channel
    public let pdf: Data
    /// Pages of the document as sent, before copies.
    public let pages: Int
    public let copies: Int
    public let title: String

    /// `nil` when `body` is not a PDF, PNG or JPEG that opens, or has no pages.
    public init?(channel: Channel, body: Data, copies: Int, title: String) {
        guard let pdf = Self.pdf(from: body),
              let provider = CGDataProvider(data: pdf as CFData),
              let document = CGPDFDocument(provider),
              document.isUnlocked || document.unlockWithPassword(""),
              document.numberOfPages > 0
        else { return nil }
        self.channel = channel
        self.pdf = pdf
        pages = document.numberOfPages
        self.copies = copies
        self.title = title
    }

    private static func pdf(from body: Data) -> Data? {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        guard body.starts(with: png) || body.starts(with: jpeg) else { return body }
        return imagePage(body)
    }

    /// One page the size of the image at its own resolution (72 dpi when it names none), turned upright by its
    /// orientation tag.
    private static func imagePage(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width, height),
              ] as CFDictionary)
        else { return nil }
        let dpiX = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        let dpiY = properties[kCGImagePropertyDPIHeight] as? Double ?? 72
        let turned = image.width != width
        var box = CGRect(
            x: 0, y: 0,
            width: Double(image.width) * 72 / (turned ? dpiY : dpiX),
            height: Double(image.height) * 72 / (turned ? dpiX : dpiY)
        )
        let pdf = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdf), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            return nil
        }
        context.beginPDFPage(nil)
        context.interpolationQuality = .high
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return pdf as Data
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
    /// Hands the job to the OS spooler; runs on the channel's own serial queue.
    func print(_ job: PrintJob, on printer: Printer) throws(PrintFailure)
}

/// Every job goes through the printer's driver: an AppKit print job with the channel's paper set on it, one sheet
/// per page after copies are expanded, each PDFKit page placed by `SheetsView`.
public struct SystemPrinting: PrintSystem {
    /// When set, jobs are written to PDF files in this directory instead of printing.
    public let saveDirectory: URL?

    public init(saveDirectory: URL? = nil) {
        self.saveDirectory = saveDirectory
    }

    public func printers() -> [Printer] {
        PrinterCatalog.printers()
    }

    public func print(_ job: PrintJob, on printer: Printer) throws(PrintFailure) {
        let result = DispatchQueue.main.sync {
            MainActor.assumeIsolated { Result { () throws(PrintFailure) in try printWithDriver(job, on: printer) } }
        }
        try result.get()
    }

    @MainActor
    private func printWithDriver(_ job: PrintJob, on printer: Printer) throws(PrintFailure) {
        guard let source = PDFDocument(data: job.pdf), !source.isLocked || source.unlock(withPassword: "") else {
            throw PrintFailure("The document cannot be opened.")
        }
        let info = try printInfo(for: printer, channel: job.channel)
        let paper = CGRect(origin: .zero, size: info.paperSize)
        if job.channel == .label, abs(paper.width - 288) > 5.76 || abs(paper.height - 432) > 5.76 {
            let size = String(format: "%.2f × %.2f", paper.width / 72, paper.height / 72)
            throw PrintFailure("The driver set the paper to \(size) in instead of 4 × 6 in.")
        }
        // AppKit lays each page out inside the margins, so the margins are the printable area's and a page is the
        // printable area.
        let printable = info.imageablePageBounds
        info.leftMargin = printable.minX
        info.bottomMargin = printable.minY
        info.rightMargin = paper.maxX - printable.maxX
        info.topMargin = paper.maxY - printable.maxY
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        if let saveDirectory {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = saveDirectory.appending(path: "\(job.title).pdf")
        }
        let pages = (0 ..< source.pageCount).compactMap { source.page(at: $0) }
        let order = job.channel == .label
            ? pages.flatMap { Array(repeating: $0, count: job.copies) }
            : Array(Array(repeating: pages, count: job.copies).joined())
        let view = SheetsView(
            pages: order, channel: job.channel, sheet: paper.size, printable: printable.size, dpi: printer.dpi > 0 ? printer.dpi : 203
        )
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = job.title
        guard operation.run() else { throw PrintFailure("\(printer.name) did not take the job.") }
    }

    /// A print info for `printer` with the channel's paper set on the job and one copy: 4 × 6 in for labels,
    /// Letter for documents. Of the driver's matching papers the one with the largest margins is taken, so a
    /// borderless variant is not picked; a printer without one gets a custom size.
    @MainActor
    func printInfo(for printer: Printer, channel: Channel) throws(PrintFailure) -> NSPrintInfo {
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
        var custom: PMPaper?
        defer { if let custom { PMRelease(UnsafeRawPointer(custom)) } }
        let paper: PMPaper
        if let match = candidates.max(by: { $0.margins < $1.margins }) {
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
        info.orientation = .portrait

        PMSetCopies(OpaquePointer(info.pmPrintSettings()), 1, false)
        info.updateFromPMPrintSettings()
        return info
    }
}

/// One printable area per page, stacked top to bottom. A page is reduced to its crop box turned by its own
/// rotation, then turned again so it stands the way it prints (a landscape label 90° clockwise, a document page
/// whose orientation differs from the sheet's 90° counter-clockwise), fitted to the printable area and centred.
/// Labels go to the driver as black-and-white dots at the printer's resolution, one image pixel per dot.
final class SheetsView: NSView {
    private let pages: [PDFPage]
    private let channel: Channel
    private let sheet: CGSize
    private let printable: CGSize
    private let dpi: Int
    private var dots: [ObjectIdentifier: CGImage] = [:]

    init(pages: [PDFPage], channel: Channel, sheet: CGSize, printable: CGSize, dpi: Int) {
        self.pages = pages
        self.channel = channel
        self.sheet = sheet
        self.printable = printable
        self.dpi = dpi
        super.init(frame: NSRect(x: 0, y: 0, width: printable.width, height: printable.height * CGFloat(pages.count)))
    }

    required init?(coder: NSCoder) {
        fatalError("not used from a coder")
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pages.count)
        return true
    }

    override func rectForPage(_ number: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(pages.count - number) * printable.height, width: printable.width, height: printable.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let number = NSPrintOperation.current?.currentPage else { return }
        let page = pages[number - 1]
        context.saveGState()
        context.clip(to: rectForPage(number))
        if channel == .label {
            let key = ObjectIdentifier(page)
            let image = dots[key] ?? Self.labelDots(page, printable: printable, dpi: dpi)
            dots[key] = image
            context.interpolationQuality = .none
            context.draw(image, in: rectForPage(number))
        } else {
            let size = Self.visibleSize(of: page)
            let turn: Turn = (size.width > size.height) != (sheet.width > sheet.height) ? .counterclockwise : .none
            context.concatenate(Self.placement(of: size, in: rectForPage(number), turn: turn))
            context.clip(to: CGRect(origin: .zero, size: size))
            page.draw(with: .cropBox, to: context)
        }
        context.restoreGState()
    }

    /// The label page drawn in grey at `dpi` into the printable area (a landscape page turned clockwise, images
    /// sampled without interpolation), then cut to black below 128 and white from 128 up, with no dithering: a 1-bit
    /// image of exactly the printable area's dots, which the driver has no reason to scale or halftone.
    static func labelDots(_ page: PDFPage, printable: CGSize, dpi: Int) -> CGImage {
        let width = Int((printable.width * CGFloat(dpi) / 72).rounded())
        let height = Int((printable.height * CGFloat(dpi) / 72).rounded())
        var grey = [UInt8](repeating: 0, count: width * height)
        let bytesPerRow = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: bytesPerRow * height)
        grey.withUnsafeMutableBytes { greyBytes in
            let context = CGContext(
                data: greyBytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            let size = visibleSize(of: page)
            let turn: Turn = size.width > size.height ? .clockwise : .none
            context.concatenate(placement(of: size, in: CGRect(x: 0, y: 0, width: width, height: height), turn: turn))
            context.clip(to: CGRect(origin: .zero, size: size))
            page.draw(with: .cropBox, to: context)
            bits.withUnsafeMutableBytes { bitBytes in
                var source = vImage_Buffer(data: greyBytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var target = vImage_Buffer(data: bitBytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
                _ = vImageConvert_Planar8toPlanar1(&source, &target, nil, Int32(kvImageConvert_DitherNone), vImage_Flags(kvImageNoFlags))
            }
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(bits) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private static func visibleSize(of page: PDFPage) -> CGSize {
        let crop = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
    }

    enum Turn {
        case none
        case clockwise
        case counterclockwise
    }

    /// Maps a page of `size` (origin at 0, 0) into `target`, turned, fitted and centred; y-up.
    static func placement(of size: CGSize, in target: CGRect, turn: Turn) -> CGAffineTransform {
        let turned = turn == .none ? size : CGSize(width: size.height, height: size.width)
        let scale = min(target.width / turned.width, target.height / turned.height)
        let rotation: CGAffineTransform = switch turn {
        case .none: .identity
        case .clockwise: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        case .counterclockwise: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        }
        return rotation
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(
                translationX: target.minX + (target.width - turned.width * scale) / 2,
                y: target.minY + (target.height - turned.height * scale) / 2
            ))
    }
}

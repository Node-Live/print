import CoreGraphics
import Foundation
import Testing
@testable import NodePrintCore

/// These go through PDFKit and the real print system with a driver queue, saving the job as a PDF instead of printing.
@Suite(.enabled(if: !PrinterCatalog.printers().filter { $0.language == .driver }.isEmpty, "needs a driver print queue"))
struct DriverPrint {
    let printer = PrinterCatalog.printers().first { $0.language == .driver }!
    let directory = FileManager.default.temporaryDirectory.appending(path: "node-print-driver-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Prints `pdf` and returns the saved page sizes plus where the black ink sits on the first page, in a
    /// top-left-origin unit square.
    private func printAndInspect(_ channel: Channel, _ pdf: Data) async throws -> (sizes: [CGSize], ink: CGRect) {
        let job = try #require(PrintJob(channel: channel, pdf: pdf, copies: 1, title: channel.rawValue))
        let system = SystemPrinting(saveDirectory: directory)
        let printer = printer
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try system.print(job, on: printer) })
            }
        }
        let saved = try #require(CGPDFDocument(directory.appending(path: "\(channel.rawValue).pdf") as CFURL))
        let sizes = (1 ... saved.numberOfPages).map { saved.page(at: $0)!.getBoxRect(.mediaBox).size }
        let page = try #require(saved.page(at: 1))
        let width = Int(sizes[0].width), height = Int(sizes[0].height)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(page)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where pixels[y * width * 4 + x * 4] < 128 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        let ink = CGRect(
            x: Double(minX) / Double(width), y: Double(minY) / Double(height),
            width: Double(maxX + 1 - minX) / Double(width), height: Double(maxY + 1 - minY) / Double(height)
        )
        return (sizes, ink)
    }

    @Test func printsALabelOn4x6WithALandscapePageTurnedClockwise() async throws {
        let result = try await printAndInspect(.label, samplePDF(pages: 2, size: CGSize(width: 432, height: 288)))
        #expect(result.sizes.count == 2)
        for size in result.sizes {
            #expect(abs(size.width - 288) < 1 && abs(size.height - 432) < 1)
        }
        // The square at the page's top-left corner lands at the label's top-right.
        #expect(result.ink.minX > 0.6 && result.ink.maxX > 0.95)
        #expect(result.ink.minY < 0.05 && result.ink.maxY < 0.4)
    }

    @Test func printsADocumentOnLetterScaledIntoThePrintableArea() async throws {
        let result = try await printAndInspect(.document, samplePDF(size: CGSize(width: 612, height: 792)))
        #expect(abs(result.sizes[0].width - 612) < 1 && abs(result.sizes[0].height - 792) < 1)
        // The 1 in square at the top-left, scaled down a little into the printable area and centred.
        #expect(result.ink.minX > 0 && result.ink.minX < 0.04)
        #expect(result.ink.minY > 0 && result.ink.minY < 0.04)
        #expect(result.ink.width < 72 / 612.0 && result.ink.width > 60 / 612.0)
    }

    @Test func keepsALandscapeDocumentPageInItsOwnOrientation() async throws {
        let result = try await printAndInspect(.document, samplePDF(size: CGSize(width: 792, height: 612)))
        #expect(abs(result.sizes[0].width - 612) < 1 && abs(result.sizes[0].height - 792) < 1)
        // Landscape on the sheet: the page's top-left square ends up along the sheet's left edge, not shrunk to fit its width.
        #expect(result.ink.height > 60 / 792.0)
        #expect(result.ink.minX < 0.04)
    }
}

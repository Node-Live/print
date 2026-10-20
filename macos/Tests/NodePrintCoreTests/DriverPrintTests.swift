import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import NodePrintCore

/// These go through PDFKit and the real print system on a CUPS queue, saving the job as a PDF instead of printing.
@Suite(.enabled(if: !PrinterCatalog.printers().isEmpty, "needs a CUPS print queue"))
struct DriverPrint {
    let printer = PrinterCatalog.printers().first!
    let directory = FileManager.default.temporaryDirectory.appending(path: "node-print-driver-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private struct SavedPage {
        var size: CGSize
        /// Where the ink sits, in points from the top-left corner of the sheet.
        var ink: CGRect
        /// The darkest quarter of the sheet: the corner the square ended up in.
        var square: Corner
    }

    private func print(_ channel: Channel, _ body: Data, copies: Int = 1) async throws -> [SavedPage] {
        let job = try #require(PrintJob(channel: channel, body: body, copies: copies, title: channel.rawValue))
        let system = SystemPrinting(saveDirectory: directory)
        let printer = printer
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try system.print(job, on: printer) })
            }
        }
        let saved = try #require(CGPDFDocument(directory.appending(path: "\(channel.rawValue).pdf") as CFURL))
        return try (1 ... saved.numberOfPages).map { try inspect(#require(saved.page(at: $0))) }
    }

    private func inspect(_ page: CGPDFPage) throws -> SavedPage {
        let size = page.getBoxRect(.mediaBox).size
        let width = Int(size.width), height = Int(size.height)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(page)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        var quarters = [0, 0, 0, 0]
        for y in 0 ..< height {
            for x in 0 ..< width where pixels[y * width * 4 + x * 4] < 128 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                quarters[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)] += 1
            }
        }
        let corners: [Corner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        return SavedPage(
            size: size,
            ink: CGRect(x: minX, y: minY, width: maxX + 1 - minX, height: maxY + 1 - minY),
            square: corners[quarters.firstIndex(of: quarters.max()!)!]
        )
    }

    /// A page of `size` (as it stands on the sheet) fitted into the printable area of the channel's paper and
    /// centred, in top-left coordinates.
    private func expectedInk(_ channel: Channel, upright size: CGSize) async throws -> CGRect {
        let printer = printer
        let (paper, printable) = try await MainActor.run {
            let info = try SystemPrinting().printInfo(for: printer, channel: channel)
            return (info.paperSize, info.imageablePageBounds)
        }
        let scale = min(printable.width / size.width, printable.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        let x = printable.minX + (printable.width - fitted.width) / 2
        let y = printable.minY + (printable.height - fitted.height) / 2
        return CGRect(x: x, y: paper.height - y - fitted.height, width: fitted.width, height: fitted.height)
    }

    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.maxX - b.maxX) < 2 && abs(a.maxY - b.maxY) < 2
    }

    @Test func printsALabelOn4x6FittedToThePrintableArea() async throws {
        let pages = try await print(.label, fixturePDF([.framed(CGSize(width: 288, height: 432))]))
        let page = try #require(pages.first)
        #expect(abs(page.size.width - 288) < 1 && abs(page.size.height - 432) < 1)
        let expected = try await expectedInk(.label, upright: CGSize(width: 288, height: 432))
        #expect(near(page.ink, expected), "ink \(page.ink), expected \(expected)")
        #expect(page.square == .topLeft)
    }

    @Test func turnsALandscapeLabelClockwise() async throws {
        let pages = try await print(.label, fixturePDF([.framed(CGSize(width: 432, height: 288))]))
        let page = try #require(pages.first)
        let expected = try await expectedInk(.label, upright: CGSize(width: 288, height: 432))
        #expect(near(page.ink, expected), "ink \(page.ink), expected \(expected)")
        #expect(page.square == .topRight)
    }

    @Test func repeatsEachLabelPageInARow() async throws {
        let body = fixturePDF([.framed(CGSize(width: 288, height: 432)), .framed(CGSize(width: 288, height: 432), square: .bottomRight)])
        let pages = try await print(.label, body, copies: 2)
        #expect(pages.map(\.square) == [.topLeft, .topLeft, .bottomRight, .bottomRight])
    }

    @Test func repeatsTheWholeDocument() async throws {
        let body = fixturePDF([.framed(CGSize(width: 612, height: 792)), .framed(CGSize(width: 612, height: 792), square: .bottomRight)])
        let pages = try await print(.document, body, copies: 2)
        #expect(pages.map(\.square) == [.topLeft, .bottomRight, .topLeft, .bottomRight])
    }

    @Test func printsADocumentOnLetterFittedAndCentredInThePrintableArea() async throws {
        let pages = try await print(.document, fixturePDF([.framed(CGSize(width: 288, height: 432))]))
        let page = try #require(pages.first)
        #expect(abs(page.size.width - 612) < 1 && abs(page.size.height - 792) < 1)
        let expected = try await expectedInk(.document, upright: CGSize(width: 288, height: 432))
        #expect(near(page.ink, expected), "ink \(page.ink), expected \(expected)")
        #expect(page.square == .topLeft)
    }

    @Test func printsALandscapeDocumentPageLandscape() async throws {
        let pages = try await print(.document, fixturePDF([.framed(CGSize(width: 792, height: 612))]))
        let page = try #require(pages.first)
        let expected = try await expectedInk(.document, upright: CGSize(width: 612, height: 792))
        #expect(near(page.ink, expected), "ink \(page.ink), expected \(expected)")
        #expect(page.square == .bottomLeft)
    }

    @Test func printsOnlyWhatIsInsideTheCropBox() async throws {
        let crop = CGRect(x: 100, y: 100, width: 288, height: 432)
        let outside = "0 g 0 0 90 90 re f "
        let page = FixturePage(media: CGRect(x: 0, y: 0, width: 612, height: 792), crop: crop, content: outside + FixturePage.frame(crop, square: .topLeft))
        let saved = try #require(try await print(.label, fixturePDF([page])).first)
        let expected = try await expectedInk(.label, upright: crop.size)
        #expect(near(saved.ink, expected), "ink \(saved.ink), expected \(expected)")
        #expect(saved.square == .topLeft)
    }

    @Test func turnsAPageByItsOwnRotateFirst() async throws {
        // Landscape in its media box, but /Rotate 90 makes it stand portrait: no further turn on a label.
        var page = FixturePage.framed(CGSize(width: 432, height: 288))
        page.rotate = 90
        let saved = try #require(try await print(.label, fixturePDF([page])).first)
        let expected = try await expectedInk(.label, upright: CGSize(width: 288, height: 432))
        #expect(near(saved.ink, expected), "ink \(saved.ink), expected \(expected)")
        #expect(saved.square == .topRight)
    }

    @Test func printsAnImageAsOnePage() async throws {
        let pages = try await print(.label, fixturePNG(width: 400, height: 600))
        let page = try #require(pages.first)
        #expect(pages.count == 1)
        let expected = try await expectedInk(.label, upright: CGSize(width: 400, height: 600))
        #expect(near(page.ink, expected), "ink \(page.ink), expected \(expected)")
        #expect(page.square == .topLeft)
    }
}

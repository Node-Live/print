import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import NodePrintCore

/// A page with a 2 pt frame along its edges and a 1 in square in its top-left corner.
private func framedPDF(_ size: CGSize, pages: Int = 1) -> Data {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    for _ in 0 ..< pages {
        context.beginPDFPage(nil)
        context.stroke(box.insetBy(dx: 1, dy: 1), width: 2)
        context.fill(CGRect(x: 0, y: size.height - 72, width: 72, height: 72))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// These go through the real print system with a driver queue, saving the job as a PDF instead of printing.
@Suite(.enabled(if: !PrinterCatalog.printers().filter { $0.language == .driver }.isEmpty, "needs a driver print queue"))
struct DriverPrint {
    let printer = PrinterCatalog.printers().first { $0.language == .driver }!
    let directory = FileManager.default.temporaryDirectory.appending(path: "node-print-driver-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private struct Saved {
        var sizes: [CGSize]
        /// Where the ink of the first page sits, in points from the top-left corner of the sheet.
        var ink: CGRect
        /// The darkest quarter of the first page: the corner the square ended up in.
        var squareCorner: String
    }

    private func print(_ channel: Channel, _ pdf: Data) async throws -> Saved {
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
        let width = Int(sizes[0].width), height = Int(sizes[0].height)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(try #require(saved.page(at: 1)))
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
        let corners = ["top-left", "top-right", "bottom-left", "bottom-right"]
        return Saved(
            sizes: sizes,
            ink: CGRect(x: minX, y: minY, width: maxX + 1 - minX, height: maxY + 1 - minY),
            squareCorner: corners[quarters.firstIndex(of: quarters.max()!)!]
        )
    }

    /// The page fitted into the whole label or the printable area of the Letter sheet, centred, in top-left coordinates.
    private func expectedInk(_ channel: Channel, turnedSize size: CGSize) async throws -> CGRect {
        let printer = printer
        let (paper, printable) = try await MainActor.run {
            let info = try SystemPrinting().printInfo(for: printer, channel: channel, copies: 1)
            return (info.paperSize, info.imageablePageBounds)
        }
        let target = channel == .label ? CGRect(origin: .zero, size: paper) : printable
        let scale = min(target.width / size.width, target.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        let x = target.minX + (target.width - fitted.width) / 2
        let y = target.minY + (target.height - fitted.height) / 2
        return CGRect(x: x, y: paper.height - y - fitted.height, width: fitted.width, height: fitted.height)
    }

    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.maxX - b.maxX) < 2 && abs(a.maxY - b.maxY) < 2
    }

    @Test func printsLabelsOn4x6WithALandscapePageTurnedClockwise() async throws {
        let saved = try await print(.label, framedPDF(CGSize(width: 432, height: 288), pages: 2))
        #expect(saved.sizes.count == 2)
        #expect(saved.sizes.allSatisfy { abs($0.width - 288) < 1 && abs($0.height - 432) < 1 })
        let expected = try await expectedInk(.label, turnedSize: CGSize(width: 288, height: 432))
        #expect(near(saved.ink, expected), "ink \(saved.ink), expected \(expected)")
        #expect(saved.squareCorner == "top-right")
    }

    @Test func printsADocumentOnLetterFittedAndCentredInThePrintableArea() async throws {
        let saved = try await print(.document, framedPDF(CGSize(width: 288, height: 432)))
        #expect(abs(saved.sizes[0].width - 612) < 1 && abs(saved.sizes[0].height - 792) < 1)
        let expected = try await expectedInk(.document, turnedSize: CGSize(width: 288, height: 432))
        #expect(near(saved.ink, expected), "ink \(saved.ink), expected \(expected)")
        #expect(saved.squareCorner == "top-left")
    }

    @Test func printsALandscapeDocumentPageLandscape() async throws {
        let saved = try await print(.document, framedPDF(CGSize(width: 792, height: 612)))
        #expect(abs(saved.sizes[0].width - 612) < 1 && abs(saved.sizes[0].height - 792) < 1)
        let expected = try await expectedInk(.document, turnedSize: CGSize(width: 612, height: 792))
        #expect(near(saved.ink, expected), "ink \(saved.ink), expected \(expected)")
        #expect(saved.squareCorner == "bottom-left")
    }
}

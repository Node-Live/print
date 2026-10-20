import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import NodePrintCore

/// A 4 x 6 in page filled by a 300 dpi greyscale image of vertical bars, 3 px black and 3 px white.
private func barcodePage() throws -> PDFPage {
    let width = 1200, height = 1800
    var grey = [UInt8](repeating: 255, count: width * height)
    for y in 0 ..< height {
        for x in 0 ..< width where (x / 3) % 2 == 0 { grey[y * width + x] = 0 }
    }
    let image = try #require(CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: CGDataProvider(data: Data(grey) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent
    ))
    let pdf = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 288, height: 432)
    let context = try #require(CGContext(consumer: CGDataConsumer(data: pdf)!, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.draw(image, in: box)
    context.endPDFPage()
    context.closePDF()
    return try #require(PDFDocument(data: pdf as Data)?.page(at: 0))
}

@Test @MainActor func turnsAThreeHundredDpiBarcodeIntoCleanDotsAtTheLabelResolution() throws {
    let dots = SheetsView.labelDots(try barcodePage(), printable: CGSize(width: 288, height: 432), dpi: 203)
    #expect(dots.width == 812 && dots.height == 1218)
    #expect(dots.bitsPerComponent == 1)

    let context = try #require(CGContext(
        data: nil, width: dots.width, height: dots.height, bitsPerComponent: 8, bytesPerRow: dots.width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    context.draw(dots, in: CGRect(x: 0, y: 0, width: dots.width, height: dots.height))
    let pixels = UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: dots.width * dots.height)
    #expect(Set(pixels) == [0, 255])

    // Every one of the 200 bars survives as its own run of dots in the middle row.
    let row = pixels[(dots.height / 2) * dots.width ..< (dots.height / 2 + 1) * dots.width]
    var bars = 0
    var previous: UInt8 = 255
    for dot in row {
        if dot == 0, previous == 255 { bars += 1 }
        previous = dot
    }
    #expect(bars == 200)
}

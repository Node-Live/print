import CoreGraphics
import Foundation

/// A 1-bit label image: rows top to bottom, each packed left to right, most significant bit first.
public struct Bitmap: Equatable, Sendable {
    public let width: Int
    public let length: Int
    public var bytes: [UInt8]

    public var bytesPerRow: Int { (width + 7) / 8 }

    public init(width: Int, length: Int, bytes: [UInt8]) {
        precondition(bytes.count == (width + 7) / 8 * length)
        self.width = width
        self.length = length
        self.bytes = bytes
    }

    public func row(_ y: Int) -> ArraySlice<UInt8> {
        bytes[y * bytesPerRow ..< (y + 1) * bytesPerRow]
    }
}

/// ZPL for Zebra label printers (`docs/zpl.md`). Parked: v1 prints every label through the driver; this stays so
/// the shared vectors in `testdata/zpl` keep passing.
public enum ZPL {
    /// The `^GFA` data field in ZPL's ASCII compression.
    public static func compressed(_ bitmap: Bitmap) -> String {
        var out = ""
        var previous: ArraySlice<UInt8>?
        for y in 0 ..< bitmap.length {
            let row = bitmap.row(y)
            if let previous, previous == row {
                out += ":"
            } else {
                appendRow(row, to: &out)
            }
            previous = row
        }
        return out
    }

    /// One `^XA … ^XZ` block per page, each printed `copies` times.
    public static func job(pages: [Bitmap], copies: Int) -> String {
        pages.map { page in
            let total = page.bytesPerRow * page.length
            return """
            ^XA
            ^PW\(page.width)
            ^LL\(page.length)
            ^LH0,0
            ^FO0,0^GFA,\(total),\(total),\(page.bytesPerRow),\(compressed(page))^FS
            ^PQ\(copies),0,1,Y
            ^XZ

            """
        }.joined()
    }

    private static let hexDigits = Array("0123456789ABCDEF")

    private static func appendRow(_ row: ArraySlice<UInt8>, to out: inout String) {
        var digits: [Character] = []
        digits.reserveCapacity(row.count * 2)
        for byte in row {
            digits.append(hexDigits[Int(byte >> 4)])
            digits.append(hexDigits[Int(byte & 0x0F)])
        }
        var i = 0
        while i < digits.count {
            let digit = digits[i]
            var j = i + 1
            while j < digits.count, digits[j] == digit { j += 1 }
            if j == digits.count, digit == "0" {
                out += ","
            } else if j == digits.count, digit == "F" {
                out += "!"
            } else {
                out += countPrefix(j - i)
                out.append(digit)
            }
            i = j
        }
    }

    private static func countPrefix(_ n: Int) -> String {
        guard n > 1 else { return "" }
        var prefix = String(repeating: "z", count: n / 400)
        var rest = n % 400
        if rest >= 20 {
            prefix.append(Character(UnicodeScalar(UInt8(ascii: "g") + UInt8(rest / 20 - 1))))
            rest %= 20
        }
        if rest > 0 {
            prefix.append(Character(UnicodeScalar(UInt8(ascii: "G") + UInt8(rest - 1))))
        }
        return prefix
    }

    /// A PDF page as a 4 × 6 in label at the printer's own dots: a landscape page turned 90° clockwise, fitted to
    /// the whole label and centred; a dot prints when its luminance is below 128, no dithering.
    public static func labelBitmap(_ page: CGPDFPage, dpi: Int) -> Bitmap {
        let width = 4 * dpi
        let length = 6 * dpi
        let rgbaPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: rgbaPerRow * length)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: length, bitsPerComponent: 8, bytesPerRow: rgbaPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: length))
            draw(page, in: context, label: CGRect(x: 0, y: 0, width: width, height: length))
        }
        let bytesPerRow = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: bytesPerRow * length)
        for y in 0 ..< length {
            for x in 0 ..< width {
                let o = y * rgbaPerRow + x * 4
                let luminance = 0.299 * Double(pixels[o]) + 0.587 * Double(pixels[o + 1]) + 0.114 * Double(pixels[o + 2])
                if luminance < 128 {
                    bits[y * bytesPerRow + (x >> 3)] |= 0x80 >> UInt8(x & 7)
                }
            }
        }
        return Bitmap(width: width, length: length, bytes: bits)
    }

    private static func draw(_ page: CGPDFPage, in context: CGContext, label: CGRect) {
        let box = page.getBoxRect(.cropBox)
        let size = page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let landscape = size.width > size.height
        let turned = landscape ? CGSize(width: size.height, height: size.width) : size
        let scale = min(label.width / turned.width, label.height / turned.height)
        let clockwise = landscape ? CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width) : .identity
        let placement = clockwise
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(
                translationX: label.minX + (label.width - turned.width * scale) / 2,
                y: label.minY + (label.height - turned.height * scale) / 2
            ))
        context.saveGState()
        context.concatenate(placement)
        context.clip(to: CGRect(origin: .zero, size: size))
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        context.restoreGState()
    }
}

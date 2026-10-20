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
}

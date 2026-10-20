import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One page of a hand-written PDF: its boxes, its /Rotate and its content stream.
struct FixturePage {
    var media = CGRect(x: 0, y: 0, width: 288, height: 432)
    var crop: CGRect?
    var rotate = 0
    var content = ""

    /// A 2 pt frame along the visible box and a 1 in square in its top-left corner (both in unrotated page space).
    static func framed(_ size: CGSize, square: Corner = .topLeft) -> FixturePage {
        FixturePage(media: CGRect(origin: .zero, size: size), content: frame(CGRect(origin: .zero, size: size), square: square))
    }

    static func frame(_ box: CGRect, square: Corner) -> String {
        let s = 72.0
        let x = square == .topLeft || square == .bottomLeft ? box.minX : box.maxX - s
        let y = square == .topLeft || square == .topRight ? box.maxY - s : box.minY
        return "0 g 2 w \(box.minX + 1) \(box.minY + 1) \(box.width - 2) \(box.height - 2) re S \(x) \(y) \(s) \(s) re f"
    }
}

enum Corner: String {
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"
}

func fixturePDF(_ pages: [FixturePage]) -> Data {
    var objects = ["<< /Type /Catalog /Pages 2 0 R >>", ""]
    var kids: [String] = []
    for page in pages {
        let pageNumber = objects.count + 1
        kids.append("\(pageNumber) 0 R")
        func box(_ r: CGRect) -> String { "[\(r.minX) \(r.minY) \(r.maxX) \(r.maxY)]" }
        var dictionary = "<< /Type /Page /Parent 2 0 R /MediaBox \(box(page.media)) /Contents \(pageNumber + 1) 0 R /Resources << >>"
        if let crop = page.crop { dictionary += " /CropBox \(box(crop))" }
        if page.rotate != 0 { dictionary += " /Rotate \(page.rotate)" }
        objects.append(dictionary + " >>")
        objects.append("<< /Length \(page.content.utf8.count) >>\nstream\n\(page.content)\nendstream")
    }
    objects[1] = "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pages.count) >>"
    var out = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
        offsets.append(out.utf8.count)
        out += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xref = out.utf8.count
    out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
    out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(out.utf8)
}

/// A white PNG with a black frame and a black block in its top-left corner.
func fixturePNG(width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(gray: 0, alpha: 1)
    context.stroke(CGRect(x: 2, y: 2, width: width - 4, height: height - 4), width: 4)
    context.fill(CGRect(x: 0, y: height - width / 4, width: width / 4, height: width / 4))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

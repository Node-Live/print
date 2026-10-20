import CoreGraphics

/// Where a PDF page lands on the sheet. Coordinates are y-up, as in PDF and Core Graphics.
///
/// Labels: a landscape page turns 90° clockwise, then fits the whole 4 × 6 in label. Documents: a page whose
/// orientation differs from the sheet's turns 90° counter-clockwise (the usual landscape printing), then fits the
/// printable area. Both keep the aspect ratio and centre the page.
public enum PageLayout {
    public enum Turn: Sendable {
        case none
        case clockwise
        case counterclockwise
    }

    /// The page as a viewer shows it: the crop box with the page's own rotation applied.
    public static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        return page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    public static func labelTurn(for size: CGSize) -> Turn {
        size.width > size.height ? .clockwise : .none
    }

    public static func documentTurn(for size: CGSize, on sheet: CGSize) -> Turn {
        (size.width > size.height) != (sheet.width > sheet.height) ? .counterclockwise : .none
    }

    public static func transform(pageSize size: CGSize, into target: CGRect, turn: Turn) -> CGAffineTransform {
        let turned = turn == .none ? size : CGSize(width: size.height, height: size.width)
        let scale = min(target.width / turned.width, target.height / turned.height)
        let x = target.minX + (target.width - turned.width * scale) / 2
        let y = target.minY + (target.height - turned.height * scale) / 2
        let rotation: CGAffineTransform = switch turn {
        case .none: .identity
        case .clockwise: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        case .counterclockwise: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        }
        return rotation
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: x, y: y))
    }

    /// Draws `page` into `target` of a y-up context.
    public static func draw(_ page: CGPDFPage, in context: CGContext, target: CGRect, turn: Turn) {
        let size = displaySize(of: page)
        context.saveGState()
        context.concatenate(transform(pageSize: size, into: target, turn: turn))
        context.clip(to: CGRect(origin: .zero, size: size))
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        context.restoreGState()
    }

    /// The page as a label at the printer's own dots, 1 bit per dot (`zpl.md`: luminance below 128 prints, no dithering).
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
            context.setShouldAntialias(true)
            context.interpolationQuality = .high
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: length))
            draw(page, in: context, target: CGRect(x: 0, y: 0, width: width, height: length), turn: labelTurn(for: displaySize(of: page)))
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
}

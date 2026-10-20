import AppKit
import SwiftUI

/// The NODE mark from `assets/logo-symbol-*.svg`, drawn on its 512-unit view box.
enum LogoGeometry {
    static let nodes: [(CGPoint, CGFloat)] = [
        (CGPoint(x: 256, y: 48), 37), (CGPoint(x: 80, y: 152), 38), (CGPoint(x: 432, y: 152), 38),
        (CGPoint(x: 256, y: 256), 48), (CGPoint(x: 80, y: 360), 37), (CGPoint(x: 432, y: 360), 37),
        (CGPoint(x: 256, y: 464), 37),
    ]

    static func frame(in rect: CGRect) -> Path {
        Path { path in
            path.addLines([(256, 48), (80, 152), (80, 360), (256, 464), (432, 360), (432, 152)].map(point))
            path.closeSubpath()
        }.applying(transform(rect))
    }

    static func spokes(in rect: CGRect) -> Path {
        Path { path in
            path.addLines([(256, 48), (256, 464)].map(point))
            path.addLines([(80, 152), (256, 256), (432, 152)].map(point))
            path.addLines([(80, 360), (256, 256), (432, 360)].map(point))
        }.applying(transform(rect))
    }

    static func dots(in rect: CGRect) -> Path {
        Path { path in
            for (center, radius) in nodes {
                path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
        }.applying(transform(rect))
    }

    static func scale(_ rect: CGRect) -> CGFloat {
        min(rect.width, rect.height) / 512
    }

    private static func point(_ xy: (CGFloat, CGFloat)) -> CGPoint {
        CGPoint(x: xy.0, y: xy.1)
    }

    private static func transform(_ rect: CGRect) -> CGAffineTransform {
        let s = scale(rect)
        return CGAffineTransform(translationX: rect.midX - 256 * s, y: rect.midY - 256 * s).scaledBy(x: s, y: s)
    }
}

struct LogoMark: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let s = LogoGeometry.scale(rect)
            let gradient = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: 0x3B8EF3), location: 0),
                    .init(color: Color(hex: 0x2BBFE0), location: 0.5),
                    .init(color: Color(hex: 0x2DD4BF), location: 1),
                ]),
                startPoint: CGPoint(x: rect.midX - 256 * s, y: rect.midY - 256 * s),
                endPoint: CGPoint(x: rect.midX + 256 * s, y: rect.midY + 256 * s)
            )
            let round = { (width: CGFloat) in StrokeStyle(lineWidth: width * s, lineCap: .round, lineJoin: .round) }
            context.stroke(LogoGeometry.frame(in: rect), with: gradient, style: round(31))
            context.stroke(LogoGeometry.spokes(in: rect), with: gradient, style: round(16))
            context.fill(LogoGeometry.dots(in: rect), with: gradient)
        }
    }
}

extension NSImage {
    /// The mark as a template image for the menu bar.
    static func logoTemplate(height: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: height, height: height), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let s = LogoGeometry.scale(rect)
            context.addPath(LogoGeometry.frame(in: rect).cgPath)
            context.setLineWidth(40 * s)
            context.strokePath()
            context.addPath(LogoGeometry.spokes(in: rect).cgPath)
            context.setLineWidth(24 * s)
            context.strokePath()
            context.addPath(LogoGeometry.dots(in: rect).cgPath)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

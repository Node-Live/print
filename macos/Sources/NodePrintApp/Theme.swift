import SwiftUI

enum Theme {
    static let windowSize = CGSize(width: 522, height: 374)
    static let inset: CGFloat = 21
    static let cardWidth = windowSize.width - 2 * inset

    static let ink = Color(hex: 0x101014)
    static let secondary = Color(hex: 0x85858D)
    static let pillText = Color(hex: 0x6E6E76)
    static let card = Color(hex: 0xF2F2F4)
    static let tileBorder = Color(hex: 0xE3E3E5)
    static let pillBorder = Color(hex: 0xE5E5E7)
    static let capsuleEdge = Color(hex: 0xE7E7E7)
    static let raisedBorder = Color(hex: 0xE6E6E8)
    static let openPillBorder = Color(hex: 0xF1F1F1)
    static let hover = Color(hex: 0xF7F7F9)
    static let check = Color(hex: 0x2C3BFF)

    static let green = Color(hex: 0x1BA865)
    static let greenText = Color(hex: 0x13814D)
    static let amber = Color(hex: 0xE8A317)
    static let amberText = Color(hex: 0x9A6700)
    static let red = Color(hex: 0xE5484D)
    static let redText = Color(hex: 0xC4314B)
    static let gray = Color(hex: 0xB4B4BB)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double(hex >> 16 & 0xFF) / 255,
            green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

import SwiftUI

/// Design tokens shared by every view. Extend freely; don't rename tokens
/// other views already use.
enum Theme {
    enum Metrics {
        static let sidebarWidth: CGFloat = 264
        static let sidebarWidthRange: ClosedRange<CGFloat> = 210...380
        static let assistantWidth: CGFloat = 380
        /// Gap between the window edge or sidebar and the page card.
        static let contentInset: CGFloat = 8
        static let contentCornerRadius: CGFloat = 10
        static let controlCornerRadius: CGFloat = 8
        static let tabRowHeight: CGFloat = 34
    }

    enum Motion {
        static let quick = Animation.snappy(duration: 0.18)
        static let standard = Animation.smooth(duration: 0.28)
    }

    struct Palette {
        let accent: Color
        let gradient: [Color]
    }

    static func palette(_ tint: SpaceTint) -> Palette {
        switch tint {
        case .bamboo: Palette(accent: Color(hex: 0x2FA36B), gradient: [Color(hex: 0x56C98B), Color(hex: 0x1F8A5A)])
        case .ocean: Palette(accent: Color(hex: 0x2F7BEA), gradient: [Color(hex: 0x5AA2FF), Color(hex: 0x1D5FD1)])
        case .sunset: Palette(accent: Color(hex: 0xF0743E), gradient: [Color(hex: 0xFFA25C), Color(hex: 0xE2504C)])
        case .lavender: Palette(accent: Color(hex: 0x8467F0), gradient: [Color(hex: 0xA98BFF), Color(hex: 0x6A4FE0)])
        case .rose: Palette(accent: Color(hex: 0xE0548F), gradient: [Color(hex: 0xF784B8), Color(hex: 0xC93A7B)])
        case .graphite: Palette(accent: Color(hex: 0x6B7280), gradient: [Color(hex: 0x8A919C), Color(hex: 0x3F4651)])
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

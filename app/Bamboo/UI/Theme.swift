import AppKit
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
        /// Height of the title bar the traffic lights sit in when AppKit doesn't
        /// say (full screen); the window's toolbar normally sets it.
        static let titlebarHeight: CGFloat = 40
        static let toolbarHeight: CGFloat = 40
        static let bookmarksBarHeight: CGFloat = 30
        static let tabHeight: CGFloat = 32
        static let tabWidthRange: ClosedRange<CGFloat> = 46...236
        static let pinnedTabWidth: CGFloat = 42
        /// The curve where the selected tab meets the toolbar.
        static let tabFlare: CGFloat = 8
        /// Room the traffic lights take at the leading edge of the titlebar.
        static let trafficLightsWidth: CGFloat = 72
        static let addressPillHeight: CGFloat = 34
        static let pinnedTileHeight: CGFloat = 40
        static let floatingCornerRadius: CGFloat = 14
        static let commandBarWidth: CGFloat = 640
    }

    enum Motion {
        static let quick = Animation.snappy(duration: 0.18)
        static let standard = Animation.smooth(duration: 0.28)
        static let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
    }

    enum Colors {
        /// The selected tab: a raised sheet of paper on the translucent sidebar.
        static let selectedRow = Color.adaptive(light: NSColor.white.withAlphaComponent(0.82),
                                                dark: NSColor.white.withAlphaComponent(0.11))
        static let hoverRow = Color.adaptive(light: NSColor.black.withAlphaComponent(0.05),
                                             dark: NSColor.white.withAlphaComponent(0.06))
        static let pressedRow = Color.adaptive(light: NSColor.black.withAlphaComponent(0.09),
                                               dark: NSColor.white.withAlphaComponent(0.1))
        /// Fill for fields and pills sitting on the sidebar.
        static let field = Color.adaptive(light: NSColor.black.withAlphaComponent(0.055),
                                          dark: NSColor.white.withAlphaComponent(0.07))
        static let hairline = Color.adaptive(light: NSColor.black.withAlphaComponent(0.1),
                                             dark: NSColor.white.withAlphaComponent(0.1))
        /// The toolbar and bookmarks bar, which the selected tab joins.
        static let toolbar = Color.adaptive(light: NSColor(white: 0.995, alpha: 1),
                                            dark: NSColor(srgbRed: 0.165, green: 0.17, blue: 0.175, alpha: 1))
        /// Background of the page card and other content surfaces.
        static let card = Color.adaptive(light: NSColor.white, dark: NSColor(white: 0.12, alpha: 1))
        static let cardShadow = Color.adaptive(light: NSColor.black.withAlphaComponent(0.12),
                                               dark: NSColor.black.withAlphaComponent(0.45))
        static let scrim = Color.adaptive(light: NSColor.black.withAlphaComponent(0.12),
                                          dark: NSColor.black.withAlphaComponent(0.35))
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

    /// A colour that follows the view's light or dark appearance.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// AppKit's translucent window materials, which SwiftUI's `Material` can't
/// blend with what is behind the window.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Surfaces that float over the page (command bar, find bar, reader controls):
/// Liquid Glass on macOS 26, a thick material with a hairline before that.
struct FloatingSurface: ViewModifier {
    var cornerRadius: CGFloat = Theme.Metrics.floatingCornerRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.18), radius: 28, y: 14)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 28, y: 14)
        }
    }
}

extension View {
    func floatingSurface(cornerRadius: CGFloat = Theme.Metrics.floatingCornerRadius) -> some View {
        modifier(FloatingSurface(cornerRadius: cornerRadius))
    }
}

/// Icon buttons on the sidebar and floating bars: no bezel, a soft rounded
/// fill on hover and a darker one while pressed.
struct ChromeButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        ChromeButtonBody(configuration: configuration, size: size)
    }

    private struct ChromeButtonBody: View {
        let configuration: Configuration
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: size, minHeight: size)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(configuration.isPressed ? Theme.Colors.pressedRow
                              : isHovered && isEnabled ? Theme.Colors.hoverRow : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .opacity(isEnabled ? 1 : 0.35)
                .onHover { isHovered = $0 }
                .animation(Theme.Motion.quick, value: isHovered)
        }
    }
}

extension ButtonStyle where Self == ChromeButtonStyle {
    static var chrome: ChromeButtonStyle { ChromeButtonStyle() }
    static func chrome(size: CGFloat) -> ChromeButtonStyle { ChromeButtonStyle(size: size) }
}

extension EnvironmentValues {
    /// The selected space's accent, for the few places the tint shows.
    @Entry var spaceAccent: Color = Theme.palette(.bamboo).accent
}

extension Tab {
    /// What the sidebar, palette and command bar call this tab.
    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host() ?? "New Tab"
    }
}

extension Int64 {
    /// Milliseconds since the epoch, as the Rust store uses them.
    var dateFromMilliseconds: Date { Date(timeIntervalSince1970: Double(self) / 1000) }
}

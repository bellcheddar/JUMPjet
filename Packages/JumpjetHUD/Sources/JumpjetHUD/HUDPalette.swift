import SwiftUI

/// The Night Sortie palette.
///
/// JUMPjet is deliberately not the other two apps: BOFFIN is light native iOS
/// and FlexAppeal is marcdeller blue on the web, so this one is a dark cockpit.
/// The hex values are the build plan's, and they are the only place a colour is
/// written down.
public enum HUDPalette {

    /// Near-black night flight.
    public static let background = Color(hex: 0x0A_0E_14)
    /// Instrument panel face.
    public static let panel = Color(hex: 0x11_18_26)
    /// One-pixel panel border.
    public static let border = Color(hex: 0x1E_29_3B)
    /// Phosphor green: live data, traces, the running state.
    public static let primary = Color(hex: 0x00_E6_76)
    /// Afterburner amber: jump events, warnings, the RUN control.
    public static let accent = Color(hex: 0xFF_B3_00)
    public static let text = Color(hex: 0xE6_ED_F3)
    public static let muted = Color(hex: 0x8B_99_A9)

    /// A dimmed phosphor for gridlines and inactive traces. Derived rather than
    /// a fifth hex value, so the palette stays as small as the build plan set it.
    public static let grid = primary.opacity(0.18)
    public static let panelShadow = Color.black.opacity(0.45)

    /// Semantic roles. Never colour alone: each carries a symbol so the meaning
    /// survives for a user who cannot separate green from amber.
    public enum Role: Sendable, Hashable, CaseIterable {
        case nominal
        case caution
        case inactive

        public var colour: Color {
            switch self {
            case .nominal: HUDPalette.primary
            case .caution: HUDPalette.accent
            case .inactive: HUDPalette.muted
            }
        }

        /// The shape that carries the same meaning as the colour.
        public var symbolName: String {
            switch self {
            case .nominal: "checkmark.circle.fill"
            case .caution: "exclamationmark.triangle.fill"
            case .inactive: "circle.dashed"
            }
        }
    }
}

extension Color {
    /// A colour from a 24-bit RGB literal, so the palette reads as the hex codes
    /// the design system is specified in.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

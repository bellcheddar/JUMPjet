import SwiftUI

/// Type styles for the instrument panel.
///
/// Every numeric readout uses monospaced digits. Instruments do not use
/// proportional figures: a value that jitters sideways as it counts is a value
/// nobody can read at a glance, and an RMSD tape updating ten times a second is
/// exactly that case.
public enum HUDTypography {

    public static func readout(_ size: CGFloat = 28) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    public static func readoutSmall(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    /// Panel and gauge captions: small, wide-tracked, upper case in use.
    public static func label(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    public static func body(_ size: CGFloat = 14) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    public static func title(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
}

extension View {
    /// Caption styling for an instrument label.
    public func hudLabelStyle() -> some View {
        self
            .font(HUDTypography.label())
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(HUDPalette.muted)
    }

    /// Numeric styling, with monospaced digits enforced rather than hoped for.
    public func hudReadoutStyle(size: CGFloat = 28, colour: Color = HUDPalette.primary)
        -> some View
    {
        self
            .font(HUDTypography.readout(size))
            .monospacedDigit()
            .foregroundStyle(colour)
    }
}

/// Spacing, radii and line weights, so the panels line up without each view
/// inventing its own numbers.
public enum HUDMetrics {
    public static let panelPadding: CGFloat = 14
    public static let panelSpacing: CGFloat = 12
    public static let cornerRadius: CGFloat = 10
    public static let hairline: CGFloat = 1
    public static let gaugeLineWidth: CGFloat = 2
    public static let tickLength: CGFloat = 6
}

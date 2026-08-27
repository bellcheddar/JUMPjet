import SwiftUI

/// An instrument panel: a titled, bordered surface.
///
/// The panel is the only container in the app. Everything the user reads sits
/// inside one, which is what makes the layout read as a cockpit rather than as
/// a settings screen with a dark theme.
public struct HUDPanel<Content: View>: View {
    private let title: String?
    private let trailing: String?
    private let content: Content

    public init(
        _ title: String? = nil, trailing: String? = nil, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HUDMetrics.panelSpacing) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).hudLabelStyle() }
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing)
                            .font(HUDTypography.readoutSmall(11))
                            .monospacedDigit()
                            .foregroundStyle(HUDPalette.muted)
                    }
                }
            }
            content
        }
        .padding(HUDMetrics.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HUDPalette.panel, in: RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius)
                .strokeBorder(HUDPalette.border, lineWidth: HUDMetrics.hairline)
        )
    }
}

/// A labelled numeric readout: the smallest unit of the instrument language.
public struct HUDReadout: View {
    private let label: String
    private let value: String
    private let unit: String?
    private let size: CGFloat
    private let colour: Color

    public init(
        label: String, value: String, unit: String? = nil, size: CGFloat = 24,
        colour: Color = HUDPalette.primary
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.size = size
        self.colour = colour
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).hudLabelStyle()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).hudReadoutStyle(size: size, colour: colour)
                if let unit {
                    Text(unit)
                        .font(HUDTypography.readoutSmall(size * 0.5))
                        .foregroundStyle(HUDPalette.muted)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(unit.map { "\(value) \($0)" } ?? value)
    }
}

/// A status lamp that carries its meaning in a symbol as well as a colour, per
/// the build plan's accessibility rule: never colour alone.
public struct HUDLamp: View {
    private let role: HUDPalette.Role
    private let text: String

    public init(role: HUDPalette.Role, text: String) {
        self.role = role
        self.text = text
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: role.symbolName)
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(HUDTypography.label())
                .tracking(1.0)
                .textCase(.uppercase)
        }
        .foregroundStyle(role.colour)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(role.colour.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(role.colour.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

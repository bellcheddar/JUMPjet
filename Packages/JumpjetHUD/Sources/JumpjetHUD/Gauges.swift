import SwiftUI

/// A tape gauge, read like an altimeter: the scale scrolls behind a fixed index
/// mark rather than a needle sweeping a fixed scale.
///
/// This is the right instrument for a value with no natural maximum, which RMSD
/// is: it starts at zero and goes as far as the protein goes.
public struct TapeGauge: View {
    private let label: String
    private let value: Double
    private let scale: GaugeScale
    private let unit: String?
    private let colour: Color

    public init(
        label: String, value: Double, scale: GaugeScale, unit: String? = nil,
        colour: Color = HUDPalette.primary
    ) {
        self.label = label
        self.value = value
        self.scale = scale
        self.unit = unit
        self.colour = colour
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).hudLabelStyle()
                Spacer(minLength: 4)
                Text(HUDFormat.fixed(value))
                    .hudReadoutStyle(size: 16, colour: scale.isPinned(value) ? HUDPalette.accent : colour)
                if let unit {
                    Text(unit)
                        .font(HUDTypography.readoutSmall(10))
                        .foregroundStyle(HUDPalette.muted)
                }
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                let fraction = scale.fraction(of: value)
                ZStack(alignment: .leading) {
                    Capsule().fill(HUDPalette.border)
                    Capsule()
                        .fill(colour)
                        .frame(width: max(2, width * fraction))
                    // Ticks sit on top so the filled portion does not hide the
                    // scale it is being read against.
                    ForEach(Array(scale.ticks().enumerated()), id: \.offset) { _, tick in
                        Rectangle()
                            .fill(HUDPalette.background.opacity(0.7))
                            .frame(width: 1)
                            .offset(x: width * scale.fraction(of: tick))
                    }
                }
            }
            .frame(height: 8)
            HStack {
                Text(HUDFormat.fixed(scale.lower, decimals: 1))
                Spacer()
                Text(HUDFormat.fixed(scale.upper, decimals: 1))
            }
            .font(HUDTypography.readoutSmall(9))
            .foregroundStyle(HUDPalette.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(HUDFormat.fixed(value)) \(unit ?? "")")
    }
}

/// A thin-line dial, read like an airspeed indicator: a needle over a 240
/// degree arc, open at the bottom.
public struct DialGauge: View {
    private let label: String
    private let value: Double
    private let scale: GaugeScale
    private let unit: String?
    private let colour: Color

    /// The arc runs from 150 degrees to 390 degrees clockwise from the positive
    /// x axis, leaving the familiar gap at the bottom.
    private static let arcStart = Angle.degrees(150)
    private static let arcSweep = Angle.degrees(240)

    public init(
        label: String, value: Double, scale: GaugeScale, unit: String? = nil,
        colour: Color = HUDPalette.primary
    ) {
        self.label = label
        self.value = value
        self.scale = scale
        self.unit = unit
        self.colour = colour
    }

    public var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .trim(from: 0, to: Self.arcSweep.degrees / 360)
                    .stroke(HUDPalette.border, style: .init(lineWidth: HUDMetrics.gaugeLineWidth, lineCap: .round))
                    .rotationEffect(Self.arcStart)
                Circle()
                    .trim(from: 0, to: Self.arcSweep.degrees / 360 * scale.fraction(of: value))
                    .stroke(colour, style: .init(lineWidth: HUDMetrics.gaugeLineWidth, lineCap: .round))
                    .rotationEffect(Self.arcStart)
                VStack(spacing: 0) {
                    Text(HUDFormat.fixed(value, decimals: 1))
                        .hudReadoutStyle(size: 18, colour: colour)
                    if let unit {
                        Text(unit)
                            .font(HUDTypography.readoutSmall(9))
                            .foregroundStyle(HUDPalette.muted)
                    }
                }
            }
            .padding(HUDMetrics.gaugeLineWidth)
            Text(label).hudLabelStyle()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(HUDFormat.fixed(value, decimals: 1)) \(unit ?? "")")
    }
}

/// The primary action control, styled as the amber RUN switch of the build
/// plan rather than as a system button.
public struct HUDActionButton: View {
    private let title: String
    private let systemImage: String
    private let role: HUDPalette.Role
    private let isEnabled: Bool
    private let action: () -> Void

    public init(
        _ title: String, systemImage: String = "play.fill",
        role: HUDPalette.Role = .caution, isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
                    .font(HUDTypography.label(13))
                    .tracking(1.4)
                    .textCase(.uppercase)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(isEnabled ? HUDPalette.background : HUDPalette.muted)
            .background(
                isEnabled ? role.colour : HUDPalette.border,
                in: RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// A determinate or indeterminate progress bar in the HUD idiom, used while a
/// structure is being fetched.
public struct HUDProgressBar: View {
    private let caption: String
    private let fraction: Double?

    public init(caption: String, fraction: Double? = nil) {
        self.caption = caption
        self.fraction = fraction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(HUDTypography.label())
                .tracking(1.2)
                .foregroundStyle(HUDPalette.primary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(HUDPalette.border)
                    if let fraction {
                        Capsule()
                            .fill(HUDPalette.primary)
                            .frame(width: max(2, geometry.size.width * min(1, max(0, fraction))))
                    } else {
                        IndeterminateSweep(width: geometry.size.width)
                    }
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }
}

/// The sweep used when there is no known total, as during a download whose
/// content length the server did not declare.
private struct IndeterminateSweep: View {
    let width: CGFloat
    @State private var offset: CGFloat = -0.35

    var body: some View {
        Capsule()
            .fill(HUDPalette.primary)
            .frame(width: max(2, width * 0.35))
            .offset(x: offset * width)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    offset = 1.0
                }
            }
            .clipped()
    }
}

import Foundation

/// The maths behind an instrument face, kept out of the view so it can be
/// tested without rendering anything.
///
/// A gauge that mislabels its ticks is a gauge that lies quietly, and there is
/// no way to catch that in a screenshot.
public struct GaugeScale: Sendable, Hashable {
    public let lower: Double
    public let upper: Double

    public init(lower: Double, upper: Double) {
        // A zero-width scale would divide by zero on every reading. Widening it
        // is better than trapping: a constant signal is a legitimate thing for
        // an instrument to be showing.
        if upper > lower {
            self.lower = lower
            self.upper = upper
        } else {
            self.lower = lower
            self.upper = lower + max(abs(lower) * 0.1, 1)
        }
    }

    public var span: Double { upper - lower }

    /// Where a value sits on the face, from 0 at the bottom to 1 at the top.
    /// Clamped, because a needle that leaves its dial is worse than one pinned
    /// at the limit.
    public func fraction(of value: Double) -> Double {
        min(1, max(0, (value - lower) / span))
    }

    /// Whether a value is off the end of the scale, so the view can show it is
    /// pinned rather than pretending the reading is at the limit.
    public func isPinned(_ value: Double) -> Bool {
        value < lower || value > upper
    }

    /// Tick positions at a round step, covering the scale.
    public func ticks(approximately count: Int = 5) -> [Double] {
        guard count > 1 else { return [lower, upper] }
        let step = Self.niceStep(span / Double(count - 1))
        guard step > 0 else { return [lower, upper] }

        let first = (lower / step).rounded(.up) * step
        var values: [Double] = []
        var value = first
        // The guard is on the value, not on an iteration count: a step that
        // rounded to something tiny would otherwise spin here.
        var safety = 0
        while value <= upper + step * 1e-9, safety < 1_000 {
            values.append(value)
            value += step
            safety += 1
        }
        return values
    }

    /// A scale that covers the data with round numbers at both ends.
    public static func nice(covering values: [Double], minimumSpan: Double = 1) -> GaugeScale {
        guard let smallest = values.min(), let largest = values.max() else {
            return GaugeScale(lower: 0, upper: minimumSpan)
        }
        var low = smallest
        var high = largest
        if high - low < minimumSpan {
            let centre = (high + low) / 2
            low = centre - minimumSpan / 2
            high = centre + minimumSpan / 2
        }
        let step = niceStep((high - low) / 4)
        return GaugeScale(
            lower: (low / step).rounded(.down) * step,
            upper: (high / step).rounded(.up) * step)
    }

    /// The nearest 1, 2 or 5 times a power of ten, which is what makes tick
    /// labels readable rather than merely correct.
    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let exponent = (log10(raw)).rounded(.down)
        let magnitude = pow(10, exponent)
        let normalised = raw / magnitude
        let step: Double
        switch normalised {
        case ..<1.5: step = 1
        case ..<3.5: step = 2
        case ..<7.5: step = 5
        default: step = 10
        }
        return step * magnitude
    }
}

/// Value formatting for instrument readouts.
///
/// Instruments show a fixed number of digits so the reading does not change
/// width as it counts. A gauge whose text reflows is a gauge you have to stop
/// and read rather than glance at.
public enum HUDFormat {

    /// Fixed decimal places, never scientific notation.
    public static func fixed(_ value: Double, decimals: Int = 2) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(decimals)f", value)
    }

    /// Thousands-separated integers, for sweep counters.
    public static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// A percentage from a 0 to 1 fraction.
    public static func percent(_ fraction: Double, decimals: Int = 0) -> String {
        guard fraction.isFinite else { return "—" }
        return fixed(fraction * 100, decimals: decimals) + "%"
    }

    /// Angstroms with the unit, for RMSD and radius of gyration.
    public static func angstroms(_ value: Double, decimals: Int = 2) -> String {
        fixed(value, decimals: decimals) + " A"
    }

    /// Elapsed time as m:ss, for a run that is under way.
    public static func elapsed(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

import Foundation
import JumpjetCore
import simd

/// How the structure is coloured.
///
/// The mapping is a pure function of the structure, kept out of the renderer so
/// it can be tested. A colour scale that mislabels its bands is the sort of
/// mistake that looks fine and misinforms every reader, and no screenshot test
/// would catch it.
public enum ColourMode: String, Sendable, Hashable, CaseIterable, Codable {
    /// N-terminus blue through to C-terminus red, the convention every
    /// structural biologist already reads fluently.
    case chainbow
    /// AlphaFold's own pLDDT bands. Only meaningful for a prediction.
    case confidence
    /// Per-residue flexibility from the Phase 2 neural prior.
    case flexibility
    /// CPK by element, for when the side chains are showing.
    case element
    /// One colour per chain.
    case chain

    public var displayName: String {
        switch self {
        case .chainbow: "Chainbow"
        case .confidence: "Confidence"
        case .flexibility: "Flexibility"
        case .element: "Element"
        case .chain: "Chain"
        }
    }

    /// The name for a segmented control, where four or five segments share the
    /// width of one instrument panel. "Confidence" truncates to "Confide..."
    /// there, and pLDDT is the more precise word for it anyway.
    public var shortName: String {
        switch self {
        case .chainbow: "Rainbow"
        case .confidence: "pLDDT"
        case .flexibility: "Flex"
        case .element: "Atom"
        case .chain: "Chain"
        }
    }

    /// Whether this mode says anything about the structure in hand.
    ///
    /// Offering a confidence scale for a crystal structure would put a 1.5
    /// angstrom entry's B-factors on a prediction's certainty axis, which is
    /// the same category error the model layer refuses to make.
    public func isAvailable(for structure: Structure) -> Bool {
        switch self {
        case .confidence: structure.source == .alphaFold
        case .flexibility: false  // Phase 2 supplies the prior.
        default: true
        }
    }
}

/// Turns a structure and a mode into one colour per residue.
public enum ResidueColouring {

    /// The official AlphaFold pLDDT bands, as the EBI viewer draws them.
    /// Reproduced exactly so a JUMPjet screenshot and an AlphaFold DB page
    /// agree about which loop is uncertain.
    public static func confidenceColour(plddt: Float) -> SIMD3<Float> {
        switch plddt {
        case 90...: SIMD3(0x00 / 255, 0x53 / 255, 0xD6 / 255)  // very high
        case 70..<90: SIMD3(0x65 / 255, 0xCB / 255, 0xF3 / 255)  // confident
        case 50..<70: SIMD3(0xFF / 255, 0xDB / 255, 0x13 / 255)  // low
        default: SIMD3(0xFF / 255, 0x7D / 255, 0x45 / 255)  // very low
        }
    }

    /// The confidence band's name, for a legend that does not rely on colour.
    public static func confidenceBand(plddt: Float) -> String {
        switch plddt {
        case 90...: "Very high"
        case 70..<90: "Confident"
        case 50..<70: "Low"
        default: "Very low"
        }
    }

    /// Blue at the N-terminus through to red at the C-terminus.
    public static func chainbowColour(fraction: Float) -> SIMD3<Float> {
        // Hue runs 240 degrees (blue) down to 0 (red), which is the direction
        // that reads as "start to end" rather than as a random rainbow.
        let hue = (1 - min(1, max(0, fraction))) * (2.0 / 3.0)
        return hsvToRGB(hue: hue, saturation: 0.85, value: 0.95)
    }

    /// Flexibility: rigid phosphor green through to floppy amber, matching the
    /// HUD's own semantic pair rather than introducing a third scale.
    public static func flexibilityColour(_ value: Float) -> SIMD3<Float> {
        let t = min(1, max(0, value))
        let rigid = SIMD3<Float>(0x00 / 255, 0xE6 / 255, 0x76 / 255)
        let floppy = SIMD3<Float>(0xFF / 255, 0xB3 / 255, 0x00 / 255)
        return rigid + (floppy - rigid) * t
    }

    /// A distinct colour per chain, evenly spaced around the hue circle.
    public static func chainColour(index: Int, of count: Int) -> SIMD3<Float> {
        guard count > 0 else { return SIMD3(0.5, 0.5, 0.5) }
        // The golden-ratio offset keeps adjacent chains distinguishable even
        // when there are many of them, which evenly spaced hues do not.
        let hue = Float(index) * 0.618_034
        return hsvToRGB(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.7, value: 1.0)
    }

    /// One colour per residue for the whole structure.
    public static func colours(
        for structure: Structure, mode: ColourMode, flexibility: [Float]? = nil
    ) -> [SIMD3<Float>] {
        let plddt = structure.perResiduePLDDT
        return structure.residues.enumerated().map { index, residue in
            switch mode {
            case .confidence:
                return confidenceColour(plddt: index < plddt.count ? plddt[index] : 0)
            case .chainbow:
                // The fraction runs along the CHAIN, not along the whole file.
                // Measuring it across the file would restart the rainbow's
                // colours mid-protein in a multi-chain entry.
                let chain = structure.chains[residue.chainIndex]
                let position = index - chain.residueRange.lowerBound
                let denominator = max(1, chain.residueCount - 1)
                return chainbowColour(fraction: Float(position) / Float(denominator))
            case .chain:
                return chainColour(index: residue.chainIndex, of: structure.chains.count)
            case .flexibility:
                guard let flexibility, index < flexibility.count else {
                    return SIMD3(0.5, 0.5, 0.5)
                }
                return flexibilityColour(flexibility[index])
            case .element:
                // The tube has no element, so the backbone falls back to a
                // neutral grey and the sticks carry the CPK colours.
                return SIMD3(0.55, 0.60, 0.68)
            }
        }
    }

    static func hsvToRGB(hue: Float, saturation: Float, value: Float) -> SIMD3<Float> {
        let sector = (hue * 6).truncatingRemainder(dividingBy: 6)
        let index = Int(sector)
        let fraction = sector - Float(index)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * fraction)
        let t = value * (1 - saturation * (1 - fraction))

        switch index {
        case 0: return SIMD3(value, t, p)
        case 1: return SIMD3(q, value, p)
        case 2: return SIMD3(p, value, t)
        case 3: return SIMD3(p, q, value)
        case 4: return SIMD3(t, p, value)
        default: return SIMD3(value, p, q)
        }
    }
}

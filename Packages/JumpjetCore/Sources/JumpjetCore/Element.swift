import Foundation

/// The chemical elements JUMPjet expects to meet in a protein structure, plus
/// the handful of ions and cofactor atoms that turn up in experimental entries.
///
/// The radii matter to the physics core in Phase 2, so they live in the model
/// layer rather than in the engine: one table, one source of truth.
public enum Element: String, Sendable, Hashable, CaseIterable, Codable {
    case hydrogen = "H"
    case carbon = "C"
    case nitrogen = "N"
    case oxygen = "O"
    case sulphur = "S"
    case selenium = "SE"
    case phosphorus = "P"
    case magnesium = "MG"
    case calcium = "CA"
    case zinc = "ZN"
    case iron = "FE"
    case manganese = "MN"
    case sodium = "NA"
    case potassium = "K"
    case chlorine = "CL"
    case unknown = "X"

    /// Bondi van der Waals radius in angstroms. The soft-sphere term in
    /// `JetEngine` scales these by 0.85 (build plan, Phase 2).
    public var vanDerWaalsRadius: Float {
        switch self {
        case .hydrogen: 1.20
        case .carbon: 1.70
        case .nitrogen: 1.55
        case .oxygen: 1.52
        case .sulphur: 1.80
        case .selenium: 1.90
        case .phosphorus: 1.80
        case .magnesium: 1.73
        case .calcium: 2.31
        case .zinc: 1.39
        case .iron: 2.00
        case .manganese: 2.05
        case .sodium: 2.27
        case .potassium: 2.75
        case .chlorine: 1.75
        case .unknown: 1.70
        }
    }

    /// Covalent radius in angstroms (Cordero 2008), used to decide whether two
    /// atoms are bonded. Bond detection compares the distance against the sum
    /// of these plus a tolerance, which is why they matter more than they look.
    public var covalentRadius: Float {
        switch self {
        case .hydrogen: 0.31
        case .carbon: 0.76
        case .nitrogen: 0.71
        case .oxygen: 0.66
        case .sulphur: 1.05
        case .selenium: 1.20
        case .phosphorus: 1.07
        case .magnesium: 1.41
        case .calcium: 1.76
        case .zinc: 1.22
        case .iron: 1.32
        case .manganese: 1.39
        case .sodium: 1.66
        case .potassium: 2.03
        case .chlorine: 1.02
        case .unknown: 0.77
        }
    }

    /// Display colour as a linear RGB triple, following the CPK convention the
    /// structural biology world already reads fluently.
    public var cpkColour: SIMD3<Float> {
        switch self {
        case .hydrogen: SIMD3(0.92, 0.92, 0.92)
        case .carbon: SIMD3(0.35, 0.78, 0.55)
        case .nitrogen: SIMD3(0.19, 0.44, 0.96)
        case .oxygen: SIMD3(0.94, 0.24, 0.24)
        case .sulphur: SIMD3(0.98, 0.78, 0.20)
        case .selenium: SIMD3(1.00, 0.63, 0.00)
        case .phosphorus: SIMD3(1.00, 0.50, 0.00)
        case .chlorine: SIMD3(0.12, 0.94, 0.12)
        case .unknown: SIMD3(0.72, 0.45, 0.90)
        default: SIMD3(0.60, 0.60, 0.72)
        }
    }

    /// Whether this element is a metal ion rather than a protein backbone or
    /// side-chain atom. Used to keep ions out of the torsional degrees of
    /// freedom in Phase 2.
    public var isMetalIon: Bool {
        switch self {
        case .magnesium, .calcium, .zinc, .iron, .manganese, .sodium, .potassium: true
        default: false
        }
    }

    /// Resolve an element from the two-character element column of a PDB record
    /// or the `type_symbol` field of an mmCIF atom site.
    ///
    /// - Parameter symbol: the raw column text, of any case and with any padding.
    public static func named(_ symbol: some StringProtocol) -> Element {
        let cleaned = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !cleaned.isEmpty else { return .unknown }
        return Element(rawValue: cleaned) ?? .unknown
    }

    /// Guess an element from a PDB atom name when the element column is absent
    /// or blank, which happens in older and in hand-edited files.
    ///
    /// PDB atom names are column-aligned: a name that starts in column 13 has a
    /// two-character element, one that starts in column 14 has a one-character
    /// element. Callers that still have the raw columns should prefer
    /// ``named(_:)``. This is the fallback for callers that only kept the name.
    public static func guessed(fromAtomName name: some StringProtocol) -> Element {
        let trimmed = name.trimmingCharacters(in: .whitespaces).uppercased()
        guard let first = trimmed.first else { return .unknown }

        // A leading digit is a positional prefix, as in "1HB". Skip it.
        let letters = trimmed.drop { $0.isNumber }
        guard let lead = letters.first else { return Element.named(String(first)) }

        // Two-letter elements only win when the name cannot be a protein atom:
        // "CA" is an alpha carbon far more often than it is a calcium ion, and
        // the caller resolves that ambiguity with the residue name instead.
        if letters.count >= 2 {
            let pair = String(letters.prefix(2))
            if pair == "SE", let element = Element(rawValue: pair) { return element }
        }
        return Element(rawValue: String(lead)) ?? .unknown
    }
}

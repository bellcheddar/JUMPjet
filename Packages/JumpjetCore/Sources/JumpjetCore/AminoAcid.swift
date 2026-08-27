import Foundation

/// A standard amino acid, plus a catch-all for anything else in the file.
///
/// The side-chain torsion definitions live here because they are chemistry, not
/// physics: `JetEngine` proposes moves against them in Phase 2 and `Analysis`
/// scores jumps against the same table in Phase 3. One table, both readers.
public enum AminoAcid: String, Sendable, Hashable, CaseIterable, Codable {
    case alanine = "ALA"
    case arginine = "ARG"
    case asparagine = "ASN"
    case asparticAcid = "ASP"
    case cysteine = "CYS"
    case glutamine = "GLN"
    case glutamicAcid = "GLU"
    case glycine = "GLY"
    case histidine = "HIS"
    case isoleucine = "ILE"
    case leucine = "LEU"
    case lysine = "LYS"
    case methionine = "MET"
    case phenylalanine = "PHE"
    case proline = "PRO"
    case serine = "SER"
    case threonine = "THR"
    case tryptophan = "TRP"
    case tyrosine = "TYR"
    case valine = "VAL"
    case other = "UNK"

    /// The one-letter code, with `X` for anything unrecognised.
    public var oneLetterCode: Character {
        switch self {
        case .alanine: "A"
        case .arginine: "R"
        case .asparagine: "N"
        case .asparticAcid: "D"
        case .cysteine: "C"
        case .glutamine: "Q"
        case .glutamicAcid: "E"
        case .glycine: "G"
        case .histidine: "H"
        case .isoleucine: "I"
        case .leucine: "L"
        case .lysine: "K"
        case .methionine: "M"
        case .phenylalanine: "F"
        case .proline: "P"
        case .serine: "S"
        case .threonine: "T"
        case .tryptophan: "W"
        case .tyrosine: "Y"
        case .valine: "V"
        case .other: "X"
        }
    }

    /// Whether this residue is part of the polypeptide JUMPjet will sample.
    /// `other` covers ligands, waters and ions, which are held rigid.
    public var isStandard: Bool { self != .other }

    /// Resolve from a three-letter residue name, tolerating the common
    /// modified-residue aliases that would otherwise be dropped as ligands.
    public static func named(_ name: some StringProtocol) -> AminoAcid {
        let key = name.trimmingCharacters(in: .whitespaces).uppercased()
        if let direct = AminoAcid(rawValue: key) { return direct }
        return Self.aliases[key] ?? .other
    }

    /// Modified residues that are chemically the parent amino acid as far as a
    /// torsional sampler is concerned. Selenomethionine is the common one; the
    /// protonation-state variants of histidine come from force-field output.
    private static let aliases: [String: AminoAcid] = [
        "MSE": .methionine,   // selenomethionine
        "HSD": .histidine, "HSE": .histidine, "HSP": .histidine,
        "HID": .histidine, "HIE": .histidine, "HIP": .histidine,
        "CYX": .cysteine, "CYM": .cysteine,
        "ASH": .asparticAcid, "GLH": .glutamicAcid,
        "LYN": .lysine, "SEC": .cysteine,
        "PYL": .lysine, "MLY": .lysine,
        "SEP": .serine, "TPO": .threonine, "PTR": .tyrosine,
    ]

    // MARK: - Side-chain torsions

    /// The atom quadruples defining chi1 upwards, in order.
    ///
    /// A dihedral is measured across four bonded atoms, so each entry names them
    /// by their PDB atom names. An empty array means the side chain has no
    /// rotatable torsion, which is true of glycine and alanine.
    public var chiDefinitions: [[String]] {
        switch self {
        case .alanine, .glycine, .other:
            []
        case .serine:
            [["N", "CA", "CB", "OG"]]
        case .cysteine:
            [["N", "CA", "CB", "SG"]]
        case .threonine:
            [["N", "CA", "CB", "OG1"]]
        case .valine:
            [["N", "CA", "CB", "CG1"]]
        case .isoleucine:
            [["N", "CA", "CB", "CG1"], ["CA", "CB", "CG1", "CD1"]]
        case .leucine:
            [["N", "CA", "CB", "CG"], ["CA", "CB", "CG", "CD1"]]
        case .proline:
            [["N", "CA", "CB", "CG"], ["CA", "CB", "CG", "CD"]]
        case .asparticAcid, .asparagine:
            [["N", "CA", "CB", "CG"], ["CA", "CB", "CG", "OD1"]]
        case .histidine:
            [["N", "CA", "CB", "CG"], ["CA", "CB", "CG", "ND1"]]
        case .phenylalanine, .tyrosine, .tryptophan:
            [["N", "CA", "CB", "CG"], ["CA", "CB", "CG", "CD1"]]
        case .methionine:
            [["N", "CA", "CB", "CG"], ["CA", "CB", "CG", "SD"], ["CB", "CG", "SD", "CE"]]
        case .glutamicAcid, .glutamine:
            [["N", "CA", "CB", "CG"], ["CA", "CB", "CG", "CD"], ["CB", "CG", "CD", "OE1"]]
        case .lysine:
            [
                ["N", "CA", "CB", "CG"], ["CA", "CB", "CG", "CD"],
                ["CB", "CG", "CD", "CE"], ["CG", "CD", "CE", "NZ"],
            ]
        case .arginine:
            [
                ["N", "CA", "CB", "CG"], ["CA", "CB", "CG", "CD"],
                ["CB", "CG", "CD", "NE"], ["CG", "CD", "NE", "CZ"],
            ]
        }
    }

    /// The number of rotatable side-chain torsions.
    public var chiCount: Int { chiDefinitions.count }

    /// Chi indices (zero-based, so 1 means chi2) whose terminal group is
    /// twofold symmetric, meaning a 180 degree change produces an identical
    /// structure.
    ///
    /// Phase 3's ring-flip detection depends on this being right: without it a
    /// flipped phenylalanine reads as a 180 degree jump when the two states are
    /// physically indistinguishable, and every aromatic residue looks busy.
    public var symmetricChiIndices: Set<Int> {
        switch self {
        case .phenylalanine, .tyrosine: [1]
        case .asparticAcid: [1]
        case .glutamicAcid: [2]
        case .arginine: []
        default: []
        }
    }

    /// Whether this residue has an aromatic ring that can flip about chi2:
    /// phenylalanine and tyrosine only. Histidine and tryptophan rings are not
    /// symmetric, so their 180 degree rotations are genuine conformational
    /// changes rather than relabellings.
    public var hasFlippableRing: Bool {
        self == .phenylalanine || self == .tyrosine
    }

    /// Heavy side-chain atom names beyond CB, used by the parser to decide
    /// whether a residue is complete enough to sample.
    public var isBackboneOnlyCapable: Bool { self == .glycine }
}

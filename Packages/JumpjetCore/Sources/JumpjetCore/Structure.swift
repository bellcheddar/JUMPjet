import Foundation
import simd

/// A single atom.
///
/// Coordinates are `Float`: a torsional Monte Carlo sampler does not need
/// double precision, and halving the working set is what keeps the Metal clash
/// grid in Phase 2 cheap to rebuild.
public struct Atom: Sendable, Hashable, Codable {
    /// The PDB atom name, trimmed. "CA", "CB", "OG1" and so on.
    public let name: String
    public let element: Element
    public var position: SIMD3<Float>
    public let occupancy: Float
    /// The B-factor column. For an AlphaFold model this carries pLDDT in the
    /// range 0 to 100, which is why it survives into the flexibility prior.
    public let temperatureFactor: Float
    /// Index into ``Structure/residues``.
    public let residueIndex: Int

    public init(
        name: String,
        element: Element,
        position: SIMD3<Float>,
        occupancy: Float = 1,
        temperatureFactor: Float = 0,
        residueIndex: Int
    ) {
        self.name = name
        self.element = element
        self.position = position
        self.occupancy = occupancy
        self.temperatureFactor = temperatureFactor
        self.residueIndex = residueIndex
    }

    /// The four atoms every standard residue except glycine's side chain hangs from.
    public var isBackbone: Bool {
        name == "N" || name == "CA" || name == "C" || name == "O"
    }
}

/// One residue, addressing its atoms by a range into the structure's flat atom
/// array rather than owning them. Keeping atoms contiguous and shared is what
/// lets the engine hand a single buffer to the GPU.
public struct Residue: Sendable, Hashable, Codable {
    public let kind: AminoAcid
    /// The residue name exactly as the file spelled it, so a selenomethionine
    /// still reports as MSE even though it samples as a methionine.
    public let rawName: String
    /// Author sequence number. Not an index, and not guaranteed contiguous:
    /// crystallographic entries skip disordered stretches.
    public let sequenceNumber: Int
    /// The author insertion code, kept as a string because `Character` is not
    /// `Codable` and the cache round-trips these. Always zero or one character.
    public let insertionCode: String?
    /// Index into ``Structure/chains``.
    public let chainIndex: Int
    /// Range into ``Structure/atoms``.
    public let atomRange: Range<Int>

    public init(
        kind: AminoAcid,
        rawName: String,
        sequenceNumber: Int,
        insertionCode: String? = nil,
        chainIndex: Int,
        atomRange: Range<Int>
    ) {
        self.kind = kind
        self.rawName = rawName
        self.sequenceNumber = sequenceNumber
        self.insertionCode = insertionCode
        self.chainIndex = chainIndex
        self.atomRange = atomRange
    }

    /// "A:LEU 42" style label for the HUD and for analysis tables.
    public func label(chainID: String) -> String {
        let insertion = insertionCode ?? ""
        return "\(chainID):\(rawName) \(sequenceNumber)\(insertion)"
    }
}

/// One polymer chain.
public struct Chain: Sendable, Hashable, Codable {
    /// The author chain identifier, which is what a user recognises.
    public let id: String
    /// Range into ``Structure/residues``.
    public let residueRange: Range<Int>

    public init(id: String, residueRange: Range<Int>) {
        self.id = id
        self.residueRange = residueRange
    }

    public var residueCount: Int { residueRange.count }
}

/// Where a structure came from. Recorded so the HUD can say so, and so the
/// cache can tell an AlphaFold model from an experimental one.
public enum StructureSource: String, Sendable, Hashable, Codable {
    case alphaFold
    case pdbe
    case local

    public var displayName: String {
        switch self {
        case .alphaFold: "AlphaFold DB"
        case .pdbe: "PDBe"
        case .local: "Local file"
        }
    }
}

/// A parsed all-atom structure: flat atoms, with residues and chains indexing
/// into them.
public struct Structure: Sendable, Hashable, Codable {
    /// The entry identifier: a UniProt accession for an AlphaFold model, a PDB
    /// ID for an experimental one.
    public let identifier: String
    public let title: String
    public let source: StructureSource
    /// The AlphaFold model version, when the source supplies one.
    public let modelVersion: String?

    public private(set) var atoms: [Atom]
    public let residues: [Residue]
    public let chains: [Chain]

    public init(
        identifier: String,
        title: String,
        source: StructureSource,
        modelVersion: String? = nil,
        atoms: [Atom],
        residues: [Residue],
        chains: [Chain]
    ) {
        self.identifier = identifier
        self.title = title
        self.source = source
        self.modelVersion = modelVersion
        self.atoms = atoms
        self.residues = residues
        self.chains = chains
    }

    public var atomCount: Int { atoms.count }
    public var residueCount: Int { residues.count }

    /// The chain with the most residues, which is what the viewer opens on when
    /// the user has not picked one.
    public var longestChainIndex: Int? {
        chains.indices.max { chains[$0].residueCount < chains[$1].residueCount }
    }

    /// Replace every coordinate at once. Used by trajectory playback, which
    /// swaps frames into a structure it has already built a scene from.
    public mutating func setPositions(_ positions: [SIMD3<Float>]) {
        precondition(
            positions.count == atoms.count,
            "position count \(positions.count) does not match atom count \(atoms.count)"
        )
        for index in atoms.indices {
            atoms[index].position = positions[index]
        }
    }

    public var positions: [SIMD3<Float>] { atoms.map(\.position) }

    /// Find a named atom within a residue. Returns an index into ``atoms``.
    public func atomIndex(named name: String, inResidue residueIndex: Int) -> Int? {
        guard residues.indices.contains(residueIndex) else { return nil }
        return residues[residueIndex].atomRange.first { atoms[$0].name == name }
    }

    /// The alpha carbon of a residue, which is the backbone the tube renderer
    /// and the elastic network both hang from.
    public func alphaCarbonIndex(ofResidue residueIndex: Int) -> Int? {
        atomIndex(named: "CA", inResidue: residueIndex)
    }

    /// One-letter sequence for a chain.
    public func sequence(ofChain chainIndex: Int) -> String {
        guard chains.indices.contains(chainIndex) else { return "" }
        return String(chains[chainIndex].residueRange.map { residues[$0].kind.oneLetterCode })
    }

    /// Mean pLDDT across residues, or `nil` when the source carries no
    /// confidence in the B-factor column. Only meaningful for AlphaFold models,
    /// where the value is per-residue and identical across a residue's atoms.
    public var meanPLDDT: Float? {
        guard source == .alphaFold, !residues.isEmpty else { return nil }
        var total: Float = 0
        var counted = 0
        for residue in residues {
            guard let index = residue.atomRange.first else { continue }
            total += atoms[index].temperatureFactor
            counted += 1
        }
        guard counted > 0 else { return nil }
        return total / Float(counted)
    }

    /// Per-residue pLDDT, taken from the first atom of each residue.
    public var perResiduePLDDT: [Float] {
        residues.map { residue in
            residue.atomRange.first.map { atoms[$0].temperatureFactor } ?? 0
        }
    }

    /// The geometric centre of all atoms, used to frame the camera.
    public var centroid: SIMD3<Float> {
        guard !atoms.isEmpty else { return .zero }
        var sum = SIMD3<Float>.zero
        for atom in atoms { sum += atom.position }
        return sum / Float(atoms.count)
    }

    /// Radius of the smallest sphere about the centroid containing every atom.
    public var boundingRadius: Float {
        let centre = centroid
        var maximum: Float = 0
        for atom in atoms {
            maximum = max(maximum, simd_distance(atom.position, centre))
        }
        return maximum
    }
}

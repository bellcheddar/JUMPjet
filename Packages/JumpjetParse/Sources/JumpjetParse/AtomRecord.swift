import Foundation
import JumpjetCore
import simd

/// One atom exactly as a file spelled it, before any grouping or filtering.
///
/// Both readers produce these, and ``StructureBuilder`` turns them into a
/// `Structure`. Keeping the intermediate means the PDB and mmCIF paths share
/// every policy decision (which alternate location wins, what counts as a
/// water) instead of each inventing its own.
public struct AtomRecord: Sendable, Hashable {
    public var name: String
    public var alternateLocation: String?
    public var residueName: String
    public var chainID: String
    public var residueSequence: Int
    public var insertionCode: String?
    public var position: SIMD3<Float>
    public var occupancy: Float
    public var temperatureFactor: Float
    public var element: Element
    /// `HETATM` in PDB, `HETATM` in the mmCIF `group_PDB` column.
    public var isHeteroAtom: Bool
    public var modelNumber: Int

    public init(
        name: String,
        alternateLocation: String? = nil,
        residueName: String,
        chainID: String,
        residueSequence: Int,
        insertionCode: String? = nil,
        position: SIMD3<Float>,
        occupancy: Float = 1,
        temperatureFactor: Float = 0,
        element: Element,
        isHeteroAtom: Bool = false,
        modelNumber: Int = 1
    ) {
        self.name = name
        self.alternateLocation = alternateLocation
        self.residueName = residueName
        self.chainID = chainID
        self.residueSequence = residueSequence
        self.insertionCode = insertionCode
        self.position = position
        self.occupancy = occupancy
        self.temperatureFactor = temperatureFactor
        self.element = element
        self.isHeteroAtom = isHeteroAtom
        self.modelNumber = modelNumber
    }
}

/// What the reader threw away and why, so the HUD can say so out loud rather
/// than quietly showing the user two thirds of their file.
public struct ParseReport: Sendable, Hashable, Codable {
    public var atomRecordsRead = 0
    public var modelsSeen = 0
    public var hydrogensDropped = 0
    public var watersDropped = 0
    public var nonPolymerResiduesDropped = 0
    public var alternateLocationsDropped = 0
    public var extraModelsDropped = 0

    public init() {}

    /// A one-line summary, empty when nothing was dropped.
    public var summary: String {
        var parts: [String] = []
        if extraModelsDropped > 0 { parts.append("\(extraModelsDropped) extra models") }
        if alternateLocationsDropped > 0 {
            parts.append("\(alternateLocationsDropped) alternate locations")
        }
        if nonPolymerResiduesDropped > 0 {
            parts.append("\(nonPolymerResiduesDropped) non-polymer residues")
        }
        if watersDropped > 0 { parts.append("\(watersDropped) waters") }
        if hydrogensDropped > 0 { parts.append("\(hydrogensDropped) hydrogens") }
        guard !parts.isEmpty else { return "" }
        return "Ignored " + parts.joined(separator: ", ") + "."
    }
}

/// A parsed structure and the account of what it cost to get there.
public struct ParseResult: Sendable, Hashable {
    public let structure: Structure
    public let report: ParseReport

    public init(structure: Structure, report: ParseReport) {
        self.structure = structure
        self.report = report
    }
}

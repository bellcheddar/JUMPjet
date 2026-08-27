import Foundation
import JumpjetCore

/// Turns a flat list of ``AtomRecord`` into a `Structure`, applying every
/// policy decision in one place.
///
/// The policies, all of which the report records:
///
/// - Only the first model survives. An NMR ensemble is twenty structures in one
///   file and JUMPjet samples from a single starting point.
/// - Hydrogens are dropped. The torsional sampler holds bond lengths fixed and
///   scores sterics on heavy atoms, and AlphaFold models carry none anyway.
/// - Waters and non-amino-acid residues are dropped. v1 samples the polymer.
/// - Where a residue has alternate locations, the highest-occupancy one wins
///   per atom name, with the first-seen breaking a tie. Taking whichever came
///   last would silently prefer the minor conformer of a partly ordered side
///   chain.
public enum StructureBuilder {

    private static let waterNames: Set<String> = ["HOH", "DOD", "WAT", "H2O", "TIP", "TIP3"]

    public static func build(
        records: [AtomRecord],
        identifier: String,
        title: String,
        source: StructureSource,
        modelVersion: String? = nil,
        residueLimit: Int = Limits.maximumResidues
    ) throws -> ParseResult {
        var report = ParseReport()
        report.atomRecordsRead = records.count

        let models = Set(records.map(\.modelNumber))
        report.modelsSeen = models.count
        let firstModel = models.min() ?? 1

        /// Identity of a residue within the file. The insertion code is part of
        /// it: 52 and 52A are different residues in an antibody.
        struct ResidueKey: Hashable {
            let chainID: String
            let sequence: Int
            let insertionCode: String?
        }

        var order: [ResidueKey] = []
        var grouped: [ResidueKey: [String: AtomRecord]] = [:]
        var residueNames: [ResidueKey: String] = [:]

        for record in records {
            guard record.modelNumber == firstModel else {
                report.extraModelsDropped += 1
                continue
            }
            if record.element == .hydrogen {
                report.hydrogensDropped += 1
                continue
            }
            let upperResidue = record.residueName.uppercased()
            if waterNames.contains(upperResidue) {
                report.watersDropped += 1
                continue
            }
            guard AminoAcid.named(upperResidue).isStandard else {
                report.nonPolymerResiduesDropped += 1
                continue
            }

            let key = ResidueKey(
                chainID: record.chainID,
                sequence: record.residueSequence,
                insertionCode: record.insertionCode)
            if grouped[key] == nil {
                grouped[key] = [:]
                residueNames[key] = upperResidue
                order.append(key)
            }
            if let existing = grouped[key]?[record.name] {
                report.alternateLocationsDropped += 1
                // Strictly greater, so a tie keeps the first seen.
                if record.occupancy > existing.occupancy {
                    grouped[key]?[record.name] = record
                }
            } else {
                grouped[key]?[record.name] = record
            }
        }

        guard !order.isEmpty else { throw JumpjetError.emptyStructure }

        // Chains in first-appearance order, residues in file order within them.
        // Sorting residues by sequence number would look tidier and would be
        // wrong: a file is free to number a chain non-monotonically, and the
        // backbone connectivity the tube renderer draws follows the file.
        var chainOrder: [String] = []
        var residuesByChain: [String: [ResidueKey]] = [:]
        for key in order {
            if residuesByChain[key.chainID] == nil {
                residuesByChain[key.chainID] = []
                chainOrder.append(key.chainID)
            }
            residuesByChain[key.chainID]?.append(key)
        }

        if let longest = chainOrder.map({ residuesByChain[$0]?.count ?? 0 }).max(),
            longest > residueLimit
        {
            throw JumpjetError.tooLarge(residues: longest, limit: residueLimit)
        }

        var atoms: [Atom] = []
        atoms.reserveCapacity(records.count)
        var residues: [Residue] = []
        var chains: [Chain] = []

        for chainID in chainOrder {
            let chainIndex = chains.count
            let residueStart = residues.count
            for key in residuesByChain[chainID] ?? [] {
                guard let atomsByName = grouped[key], !atomsByName.isEmpty else { continue }
                let residueIndex = residues.count
                let atomStart = atoms.count

                // Backbone first and in order, then side chain alphabetically.
                // A stable order matters: the engine addresses atoms by index
                // and a cached trajectory must line up with a re-parsed file.
                let ordering = ["N", "CA", "C", "O"]
                let backbone = ordering.compactMap { atomsByName[$0] }
                let sideChain = atomsByName
                    .filter { !ordering.contains($0.key) }
                    .sorted { $0.key < $1.key }
                    .map(\.value)

                for record in backbone + sideChain {
                    atoms.append(
                        Atom(
                            name: record.name,
                            element: record.element,
                            position: record.position,
                            occupancy: record.occupancy,
                            temperatureFactor: record.temperatureFactor,
                            residueIndex: residueIndex))
                }

                let rawName = residueNames[key] ?? "UNK"
                residues.append(
                    Residue(
                        kind: AminoAcid.named(rawName),
                        rawName: rawName,
                        sequenceNumber: key.sequence,
                        insertionCode: key.insertionCode,
                        chainIndex: chainIndex,
                        atomRange: atomStart..<atoms.count))
            }
            guard residues.count > residueStart else { continue }
            chains.append(Chain(id: chainID, residueRange: residueStart..<residues.count))
        }

        guard !atoms.isEmpty else { throw JumpjetError.emptyStructure }

        let structure = Structure(
            identifier: identifier,
            title: title,
            source: source,
            modelVersion: modelVersion,
            atoms: atoms,
            residues: residues,
            chains: chains)
        return ParseResult(structure: structure, report: report)
    }
}

import Foundation
import JumpjetCore
import simd

/// A reader for mmCIF, the format AlphaFold DB and the PDB both serve today.
public enum MMCIFParser {

    public static func parse(
        _ text: String,
        identifier: String? = nil,
        source: StructureSource = .local,
        modelVersion: String? = nil,
        residueLimit: Int = Limits.maximumResidues
    ) throws -> ParseResult {
        let document = CIFDocument.parse(text)

        let names = document.firstColumn(
            of: ["_atom_site.auth_atom_id", "_atom_site.label_atom_id"])
        guard !names.isEmpty else {
            throw JumpjetError.parseFailure(reason: "no _atom_site loop found")
        }

        let count = names.count
        let groups = document.column("_atom_site.group_pdb")
        let symbols = document.column("_atom_site.type_symbol")
        let alternates = document.column("_atom_site.label_alt_id")
        // Author numbering is what a user, a paper and the HUD all mean by
        // "residue 42". label_seq_id is a one-based internal index and using it
        // as a fallback without saying so renumbers the whole protein.
        let residueNames = document.firstColumn(
            of: ["_atom_site.auth_comp_id", "_atom_site.label_comp_id"])
        let chainIDs = document.firstColumn(
            of: ["_atom_site.auth_asym_id", "_atom_site.label_asym_id"])
        let sequences = document.firstColumn(
            of: ["_atom_site.auth_seq_id", "_atom_site.label_seq_id"])
        let insertions = document.column("_atom_site.pdbx_pdb_ins_code")
        let xs = document.column("_atom_site.cartn_x")
        let ys = document.column("_atom_site.cartn_y")
        let zs = document.column("_atom_site.cartn_z")
        let occupancies = document.column("_atom_site.occupancy")
        let temperatures = document.column("_atom_site.b_iso_or_equiv")
        let models = document.column("_atom_site.pdbx_pdb_model_num")

        guard xs.count == count, ys.count == count, zs.count == count else {
            throw JumpjetError.parseFailure(
                reason: "atom_site columns disagree on length "
                    + "(\(count) names, \(xs.count) x, \(ys.count) y, \(zs.count) z)")
        }

        /// Safe column access: a tag absent from the file yields an empty
        /// column, and a short one must not trap the whole parse.
        func at(_ column: [String?], _ index: Int) -> String? {
            index < column.count ? column[index] : nil
        }

        var records: [AtomRecord] = []
        records.reserveCapacity(count)

        for index in 0..<count {
            guard let name = names[index],
                let x = at(xs, index).flatMap(Float.init),
                let y = at(ys, index).flatMap(Float.init),
                let z = at(zs, index).flatMap(Float.init)
            else { continue }

            let element = at(symbols, index).map(Element.named)
                ?? Element.guessed(fromAtomName: name)

            records.append(
                AtomRecord(
                    name: name,
                    alternateLocation: at(alternates, index),
                    residueName: at(residueNames, index) ?? "UNK",
                    chainID: at(chainIDs, index) ?? "A",
                    residueSequence: at(sequences, index).flatMap(Int.init) ?? 0,
                    insertionCode: at(insertions, index),
                    position: SIMD3(x, y, z),
                    occupancy: at(occupancies, index).flatMap(Float.init) ?? 1,
                    temperatureFactor: at(temperatures, index).flatMap(Float.init) ?? 0,
                    element: element,
                    isHeteroAtom: at(groups, index)?.uppercased() == "HETATM",
                    modelNumber: at(models, index).flatMap(Int.init) ?? 1))
        }

        guard !records.isEmpty else {
            throw JumpjetError.parseFailure(reason: "_atom_site loop contained no usable rows")
        }

        let title = document.value("_struct.title")
            ?? document.value("_struct.pdbx_descriptor")
            ?? ""
        let entryID = document.value("_entry.id") ?? document.blockName

        // AlphaFold entries carry their model version in the file. Trusting it
        // beats guessing from the URL, which the cache key also depends on.
        let version = modelVersion
            ?? document.value("_ma_model_list.model_name")
            ?? document.value("_audit_conform.dict_version")

        return try StructureBuilder.build(
            records: records,
            identifier: identifier ?? (entryID.isEmpty ? "UNKNOWN" : entryID),
            title: title.isEmpty ? (identifier ?? entryID) : title,
            source: source,
            modelVersion: version,
            residueLimit: residueLimit)
    }
}

/// Format sniffing, so callers can hand over bytes without knowing which of the
/// two the server chose to send.
public enum StructureReader {

    public enum Format: String, Sendable {
        case pdb
        case mmCIF
    }

    /// Decide the format from the content, not the file extension.
    ///
    /// AlphaFold DB serves both, and a cache that trusted the extension would
    /// hand a `.cif` body to the column-slicing PDB reader, which returns an
    /// empty structure rather than an error.
    public static func detectFormat(_ text: String) -> Format {
        let head = text.prefix(4_096)
        if head.contains("data_") || head.contains("_atom_site.") || head.contains("loop_") {
            return .mmCIF
        }
        return .pdb
    }

    public static func parse(
        _ text: String,
        identifier: String? = nil,
        source: StructureSource = .local,
        modelVersion: String? = nil,
        residueLimit: Int = Limits.maximumResidues
    ) throws -> ParseResult {
        switch detectFormat(text) {
        case .mmCIF:
            try MMCIFParser.parse(
                text, identifier: identifier, source: source, modelVersion: modelVersion,
                residueLimit: residueLimit)
        case .pdb:
            try PDBParser.parse(
                text, identifier: identifier, source: source, modelVersion: modelVersion,
                residueLimit: residueLimit)
        }
    }

    public static func parse(
        data: Data,
        identifier: String? = nil,
        source: StructureSource = .local,
        modelVersion: String? = nil,
        residueLimit: Int = Limits.maximumResidues
    ) throws -> ParseResult {
        guard let text = String(data: data, encoding: .utf8) else {
            throw JumpjetError.parseFailure(reason: "the file is not valid UTF-8 text")
        }
        return try parse(
            text, identifier: identifier, source: source, modelVersion: modelVersion,
            residueLimit: residueLimit)
    }
}

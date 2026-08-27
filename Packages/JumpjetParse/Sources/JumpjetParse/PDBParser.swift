import Foundation
import JumpjetCore
import simd

/// A reader for the legacy fixed-column PDB format.
///
/// Fixed-column really does mean fixed column here. Splitting an ATOM record on
/// whitespace works right up until a four-character atom name abuts a
/// three-character residue name, or a coordinate of -100.123 abuts the next
/// one, at which point fields silently merge. Every field below is sliced by
/// its documented columns.
public enum PDBParser {

    public static func parse(
        _ text: String,
        identifier: String? = nil,
        source: StructureSource = .local,
        modelVersion: String? = nil,
        residueLimit: Int = Limits.maximumResidues
    ) throws -> ParseResult {
        var records: [AtomRecord] = []
        var titleParts: [String] = []
        var headerIdentifier: String?
        var currentModel = 1

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let columns = Array(line.hasSuffix("\r") ? line.dropLast() : line)
            // Records are identified by columns 1 to 6, which is safe here
            // BECAUSE the format is column-oriented. The same trick applied to
            // mmCIF drops every ATOM and keeps HETATM by luck.
            let recordName = Self.trimmed(columns, 1, 6)

            switch recordName {
            case "ATOM", "HETATM":
                guard let record = Self.atomRecord(from: columns, model: currentModel) else { continue }
                records.append(record)
            case "MODEL":
                currentModel = Int(Self.trimmed(columns, 11, 14)) ?? currentModel
            case "TITLE":
                let part = Self.trimmed(columns, 11, 80)
                if !part.isEmpty { titleParts.append(part) }
            case "HEADER":
                let candidate = Self.trimmed(columns, 63, 66)
                if !candidate.isEmpty { headerIdentifier = candidate }
            case "END":
                break
            default:
                continue
            }
        }

        guard !records.isEmpty else {
            throw JumpjetError.parseFailure(reason: "no ATOM or HETATM records found")
        }

        let title = titleParts.joined(separator: " ")
        return try StructureBuilder.build(
            records: records,
            identifier: identifier ?? headerIdentifier ?? "UNKNOWN",
            title: title.isEmpty ? (identifier ?? "Structure") : title,
            source: source,
            modelVersion: modelVersion,
            residueLimit: residueLimit)
    }

    // MARK: - Records

    private static func atomRecord(from columns: [Character], model: Int) -> AtomRecord? {
        // Columns 31 to 54 hold the coordinates. A line too short to contain
        // them is truncated or corrupt, and skipping it beats reading zeros.
        guard columns.count >= 54 else { return nil }

        guard
            let x = Float(Self.trimmed(columns, 31, 38)),
            let y = Float(Self.trimmed(columns, 39, 46)),
            let z = Float(Self.trimmed(columns, 47, 54))
        else { return nil }

        let rawName = Self.field(columns, 13, 16)
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let alternate = Self.trimmed(columns, 17, 17)
        let residueName = Self.trimmed(columns, 18, 20)
        let chain = Self.trimmed(columns, 22, 22)
        let sequence = Int(Self.trimmed(columns, 23, 26)) ?? 0
        let insertion = Self.trimmed(columns, 27, 27)
        let occupancy = Float(Self.trimmed(columns, 55, 60)) ?? 1
        let temperature = Float(Self.trimmed(columns, 61, 66)) ?? 0
        let elementColumn = Self.trimmed(columns, 77, 78)

        // The element column is authoritative when present. When it is blank,
        // the atom name's COLUMN ALIGNMENT carries the answer: a two-character
        // element starts in column 13, a one-character element in column 14.
        // That is what keeps "CA" as an alpha carbon and " CA " in a calcium
        // ion's record as calcium.
        let element: Element
        if !elementColumn.isEmpty {
            element = Element.named(elementColumn)
        } else if rawName.first == " " || rawName.first?.isNumber == true {
            element = Element.guessed(fromAtomName: name)
        } else {
            let leading = String(rawName.prefix(2)).trimmingCharacters(in: .whitespaces)
            element = Element(rawValue: leading.uppercased()) ?? Element.guessed(fromAtomName: name)
        }

        return AtomRecord(
            name: name,
            alternateLocation: alternate.isEmpty ? nil : alternate,
            residueName: residueName,
            chainID: chain.isEmpty ? "A" : chain,
            residueSequence: sequence,
            insertionCode: insertion.isEmpty ? nil : insertion,
            position: SIMD3(x, y, z),
            occupancy: occupancy,
            temperatureFactor: temperature,
            element: element,
            isHeteroAtom: Self.trimmed(columns, 1, 6) == "HETATM",
            modelNumber: model)
    }

    /// One-indexed, inclusive column slice, clamped to the length of the line.
    ///
    /// Takes an already-split line: splitting inside the accessor would re-walk
    /// the string for each of the twelve fields an ATOM record has, which on a
    /// 1,200 residue model is roughly ten million redundant character copies.
    ///
    /// PDB files in the wild are routinely truncated at the last non-blank
    /// character, so asking for columns 77 to 78 of a 66-character line has to
    /// return an empty string rather than trap.
    private static func field(_ characters: [Character], _ start: Int, _ end: Int) -> String {
        guard start <= characters.count, start <= end else { return "" }
        return String(characters[(start - 1)..<min(end, characters.count)])
    }

    /// The same slice, trimmed, which is what almost every caller wants.
    private static func trimmed(_ characters: [Character], _ start: Int, _ end: Int) -> String {
        field(characters, start, end).trimmingCharacters(in: .whitespaces)
    }
}

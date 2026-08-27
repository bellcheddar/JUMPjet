import Foundation
import JumpjetCore

/// A validated UniProt accession.
///
/// Validating before the first network call is what makes a typo a one-line
/// message instead of three round trips ending in a 404 from somebody else's
/// server.
public struct Accession: Sendable, Hashable, CustomStringConvertible {
    public let value: String
    /// The isoform suffix, if the user typed one. AlphaFold DB keys on the base
    /// accession, so it is kept for display and stripped for lookup.
    public let isoform: Int?

    public var description: String { value }

    /// The UniProtKB accession grammar, from the UniProt help pages. Six or ten
    /// characters, with the ten-character form being the newer allocation.
    private static let pattern = try? NSRegularExpression(
        pattern: "^([OPQ][0-9][A-Z0-9]{3}[0-9]|[A-NR-Z][0-9]([A-Z][A-Z0-9]{2}[0-9]){1,2})$")

    public init(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { throw JumpjetError.malformedAccession(raw) }

        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(parts[0])
        let suffix = parts.count > 1 ? Int(parts[1]) : nil
        if parts.count > 1, suffix == nil { throw JumpjetError.malformedAccession(raw) }

        guard let pattern = Self.pattern else { throw JumpjetError.malformedAccession(raw) }
        let range = NSRange(base.startIndex..<base.endIndex, in: base)
        guard pattern.firstMatch(in: base, range: range) != nil else {
            throw JumpjetError.malformedAccession(raw)
        }

        self.value = base
        self.isoform = suffix
    }

    /// Whether a string would validate, for live feedback as the user types.
    public static func isValid(_ raw: String) -> Bool {
        (try? Accession(raw)) != nil
    }
}

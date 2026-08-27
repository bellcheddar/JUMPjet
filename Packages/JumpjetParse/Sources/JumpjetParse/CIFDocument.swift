import Foundation

/// A tokenised mmCIF data block.
///
/// mmCIF is whitespace-delimited with quoting, NOT column-aligned, which is the
/// single most common way a PDB reader is mis-ported to it: slicing the first
/// six characters of a line drops every `ATOM` record (five characters, so the
/// slice reads into the next field) while `HETATM` survives by being exactly
/// six characters long. The result is a structure containing only its ligands,
/// which looks like an empty protein rather than like a bug.
///
/// Both looped and key-value items are stored the same way, as an ordered
/// column of values per tag, so a caller never has to know which form the file
/// used. A single key-value item is simply a column of length one.
public struct CIFDocument: Sendable {
    public let blockName: String
    private let columns: [String: [String?]]

    public init(blockName: String, columns: [String: [String?]]) {
        self.blockName = blockName
        self.columns = columns
    }

    /// The first value for a tag, or `nil` when absent or explicitly null.
    public func value(_ tag: String) -> String? {
        columns[tag.lowercased()]?.first ?? nil
    }

    /// Every value for a tag, in file order. Empty when the tag is absent.
    public func column(_ tag: String) -> [String?] {
        columns[tag.lowercased()] ?? []
    }

    /// The first tag present from a preference list, with its column.
    ///
    /// Used to prefer author numbering over label numbering: `auth_seq_id` is
    /// what a paper and a user's memory both refer to, and `label_seq_id` is
    /// the internal one-based index, so falling back silently would renumber
    /// the whole protein.
    public func firstColumn(of tags: [String]) -> [String?] {
        for tag in tags {
            let found = column(tag)
            if !found.isEmpty { return found }
        }
        return []
    }

    public func has(_ tag: String) -> Bool { columns[tag.lowercased()] != nil }

    public var tags: [String] { Array(columns.keys) }
}

/// The mmCIF tokeniser.
///
/// Handles the four things a naive `split(separator: " ")` gets wrong:
/// single and double quoted values, semicolon-delimited multi-line text fields,
/// comments, and the fact that `.` and `?` mean null only when unquoted.
enum CIFTokeniser {

    struct Token {
        let text: String
        let wasQuoted: Bool

        /// A tag is an unquoted token starting with an underscore. The quoting
        /// test matters: `'_not_a_tag'` is a perfectly legal string value.
        var isTag: Bool { !wasQuoted && text.hasPrefix("_") }

        var isReservedWord: Bool {
            guard !wasQuoted else { return false }
            let lower = text.lowercased()
            return lower == "loop_" || lower.hasPrefix("data_") || lower.hasPrefix("save_")
                || lower == "stop_" || lower == "global_"
        }

        /// `.` (inapplicable) and `?` (unknown) are nulls, but only unquoted.
        var isNull: Bool { !wasQuoted && (text == "." || text == "?") }
    }

    static func tokenise(_ text: String) -> [Token] {
        var tokens: [Token] = []
        tokens.reserveCapacity(text.count / 8)

        // Multi-line state is a local, not a static: `tokenise` is called from
        // concurrent parses and shared mutable state here would be a data race
        // that shows up as one download's text field appearing in another's.
        var multiline: [String]?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]

            // A semicolon in column 1 opens a multi-line text field that runs
            // until the next semicolon in column 1. Everything between is one
            // value, comments and all, so this test comes before every other.
            if line.first == ";" {
                if let buffer = multiline {
                    tokens.append(Token(text: buffer.joined(separator: "\n"), wasQuoted: true))
                    multiline = nil
                } else {
                    multiline = [String(line.dropFirst())]
                }
                continue
            }
            if multiline != nil {
                multiline?.append(String(line))
                continue
            }

            tokeniseLine(line, into: &tokens)
        }

        // An unterminated text field still yields its content rather than
        // vanishing: a truncated download should read as a short file, not an
        // empty one.
        if let buffer = multiline, !buffer.isEmpty {
            tokens.append(Token(text: buffer.joined(separator: "\n"), wasQuoted: true))
        }
        return tokens
    }

    private static func tokeniseLine(_ line: Substring, into tokens: inout [Token]) {
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == " " || character == "\t" {
                index = line.index(after: index)
                continue
            }
            // A comment runs to end of line, but only when the hash opens a
            // token. A hash inside a value is just a character.
            if character == "#" { return }

            if character == "'" || character == "\"" {
                // The closing quote is only a closing quote when followed by
                // whitespace or end of line. Names like 5'-O-... are legal
                // unquoted content and legal inside quotes.
                var cursor = line.index(after: index)
                var value = ""
                var closed = false
                while cursor < line.endIndex {
                    if line[cursor] == character {
                        let next = line.index(after: cursor)
                        if next == line.endIndex || line[next] == " " || line[next] == "\t" {
                            closed = true
                            cursor = next
                            break
                        }
                    }
                    value.append(line[cursor])
                    cursor = line.index(after: cursor)
                }
                tokens.append(Token(text: value, wasQuoted: true))
                index = cursor
                if !closed { return }
                continue
            }

            var cursor = index
            while cursor < line.endIndex, line[cursor] != " ", line[cursor] != "\t" {
                cursor = line.index(after: cursor)
            }
            tokens.append(Token(text: String(line[index..<cursor]), wasQuoted: false))
            index = cursor
        }
    }
}

extension CIFDocument {

    /// Parse the first data block of an mmCIF file.
    ///
    /// Only the first block is read. Multi-block files exist but a structure
    /// entry is one block, and reading further would merge two entries' atoms
    /// into one protein.
    public static func parse(_ text: String) -> CIFDocument {
        let tokens = CIFTokeniser.tokenise(text)
        var columns: [String: [String?]] = [:]
        var blockName = ""

        var index = 0
        var seenBlock = false

        func store(_ tag: String, _ token: CIFTokeniser.Token) {
            columns[tag.lowercased(), default: []].append(token.isNull ? nil : token.text)
        }

        while index < tokens.count {
            let token = tokens[index]

            if !token.wasQuoted, token.text.lowercased().hasPrefix("data_") {
                if seenBlock { break }
                seenBlock = true
                blockName = String(token.text.dropFirst(5))
                index += 1
                continue
            }

            if !token.wasQuoted, token.text.lowercased() == "loop_" {
                index += 1
                var loopTags: [String] = []
                while index < tokens.count, tokens[index].isTag {
                    loopTags.append(tokens[index].text)
                    index += 1
                }
                guard !loopTags.isEmpty else { continue }

                // Values run in row-major order until the next tag or reserved
                // word. A row cut short by the end of the loop is discarded
                // rather than shifting every later column by one.
                var pending: [CIFTokeniser.Token] = []
                while index < tokens.count,
                    !tokens[index].isTag, !tokens[index].isReservedWord
                {
                    pending.append(tokens[index])
                    index += 1
                }
                let rows = pending.count / loopTags.count
                for row in 0..<rows {
                    for (offset, tag) in loopTags.enumerated() {
                        store(tag, pending[row * loopTags.count + offset])
                    }
                }
                continue
            }

            if token.isTag {
                if index + 1 < tokens.count, !tokens[index + 1].isTag,
                    !tokens[index + 1].isReservedWord
                {
                    store(token.text, tokens[index + 1])
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            index += 1
        }

        return CIFDocument(blockName: blockName, columns: columns)
    }
}

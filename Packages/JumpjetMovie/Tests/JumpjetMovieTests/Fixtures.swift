import Foundation

/// Locates the repository's `Fixtures` directory from a test's own source path.
///
/// The fixtures are NOT bundled as package resources. There is one copy at the
/// repository root shared by every test target, and copying it into each
/// package's bundle would put four megabytes of duplicated structure files into
/// the build and make "update the fixture" a four-place edit.
enum Fixtures {

    static let root: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Walk up until a directory containing Fixtures/ turns up. Counting
        // `deletingLastPathComponent` calls instead would break the moment a
        // test file moved one level deeper.
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("Fixtures")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        fatalError("could not find Fixtures/ above \(#filePath)")
    }()

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(relativePath))
    }
}

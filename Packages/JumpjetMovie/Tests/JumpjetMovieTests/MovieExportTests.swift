import AVFoundation
import XCTest
import JumpjetCore
import JumpjetParse
import JumpjetViewer
import simd

@testable import JumpjetMovie

/// The movie export, end to end: a real structure, a synthetic trajectory, and
/// a file that a video player can actually open.
///
/// Reading the written file back with `AVAsset` is the point. An exporter that
/// returns a URL without error and produces a file nothing can play is the
/// failure this catches, and it is not a hypothetical: the H.264 encoder
/// rejects odd dimensions, and a zero-length track looks like success from the
/// writer's side.
final class MovieExportTests: XCTestCase {

    private func structureAndFrames(count: Int = 12) throws -> (Structure, [[SIMD3<Float>]]) {
        let structure = try PDBParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.pdb"),
            identifier: "P69905", source: .alphaFold
        ).structure
        // A synthetic trajectory: the real thing would need the sampler, and
        // what is being tested is the writer, not the physics.
        let frames = (0..<count).map { index -> [SIMD3<Float>] in
            let nudge = Float(index) * 0.05
            return structure.positions.map { $0 + SIMD3(nudge, 0, 0) }
        }
        return (structure, frames)
    }

    private func destination(_ name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jumpjet-movie-\(name)-\(UUID().uuidString).mp4")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Presets

    /// H.264 encodes in macroblocks with chroma subsampling, so an odd width or
    /// height is either rejected or silently padded, and a silently padded
    /// frame is a movie with a stripe down one edge.
    func testPresetsHaveEvenDimensions() {
        for preset in MoviePreset.allCases {
            XCTAssertTrue(preset.isValid, "\(preset.name) is not encodable")
            XCTAssertEqual(preset.width % 2, 0)
            XCTAssertEqual(preset.height % 2, 0)
        }
        XCTAssertFalse(
            MoviePreset(id: "odd", name: "odd", width: 1921, height: 1080, bitsPerSecond: 1)
                .isValid)
    }

    func testTheBuildPlansTwoPresets() {
        XCTAssertEqual(MoviePreset.landscape1080.width, 1920)
        XCTAssertEqual(MoviePreset.landscape1080.height, 1080)
        XCTAssertEqual(MoviePreset.square720.width, MoviePreset.square720.height)
        XCTAssertEqual(MoviePreset.square720.aspect, 1, accuracy: 1e-9)
    }

    /// Every trajectory frame becomes one movie frame, plus a tail that holds
    /// the last one. Interpolating to pad the movie out would invent
    /// conformations the sampler never visited.
    func testFrameCountIsTheTrajectoryPlusATail() {
        var options = MovieOptions()
        options.framesPerSecond = 30
        options.tailSeconds = 0.5
        XCTAssertEqual(options.movieFrameCount(trajectoryFrames: 201), 201 + 15)
        XCTAssertEqual(options.duration(trajectoryFrames: 201), 216.0 / 30.0, accuracy: 1e-9)

        options.tailSeconds = 0
        XCTAssertEqual(options.movieFrameCount(trajectoryFrames: 100), 100)
    }

    // MARK: - Writing

    func testExportsAFileAVFoundationCanRead() async throws {
        let (structure, frames) = try structureAndFrames(count: 10)
        var options = MovieOptions()
        options.preset = .square720
        options.tailSeconds = 0
        options.orbits = true

        let url = destination("readable")
        let written = try await MovieExporter().export(
            structure: structure, frames: frames, viewerOptions: ViewerOptions(),
            flexibility: nil, options: options,
            caption: MovieExporter.Caption(
                accession: "P69905", title: "Haemoglobin alpha",
                sweeps: (0..<10).map { $0 * 25 },
                rmsd: (0..<10).map { Float($0) * 0.1 }),
            to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        let size = try FileManager.default.attributesOfItem(atPath: written.path)[.size] as? Int
        XCTAssertGreaterThan(size ?? 0, 5_000, "a file this small has no video in it")

        // The check that matters: something can play it.
        let asset = AVURLAsset(url: written)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1, "no video track")

        let track = try XCTUnwrap(tracks.first)
        let dimensions = try await track.load(.naturalSize)
        XCTAssertEqual(Int(dimensions.width), 720)
        XCTAssertEqual(Int(dimensions.height), 720)

        let duration = try await asset.load(.duration)
        XCTAssertEqual(
            CMTimeGetSeconds(duration), 10.0 / 30.0, accuracy: 0.05,
            "ten frames at thirty a second is a third of a second")
    }

    func testProgressReachesOne() async throws {
        let (structure, frames) = try structureAndFrames(count: 6)
        var options = MovieOptions()
        options.preset = .square720
        options.tailSeconds = 0
        options.burnsInHUD = false

        let collector = ProgressCollector()
        _ = try await MovieExporter().export(
            structure: structure, frames: frames, viewerOptions: ViewerOptions(),
            flexibility: nil, options: options,
            caption: MovieExporter.Caption(
                accession: "P69905", title: "", sweeps: [], rmsd: []),
            to: destination("progress"),
            progress: { collector.record($0) })

        let values = collector.values
        XCTAssertEqual(values.count, 6)
        XCTAssertEqual(values.last ?? 0, 1.0, accuracy: 1e-6)
        XCTAssertEqual(values, values.sorted(), "progress must not go backwards")
    }

    func testAnEmptyTrajectoryIsRefused() async {
        do {
            _ = try await MovieExporter().export(
                structure: try structureAndFrames().0, frames: [],
                viewerOptions: ViewerOptions(), flexibility: nil, options: MovieOptions(),
                caption: MovieExporter.Caption(
                    accession: "X", title: "", sweeps: [], rmsd: []),
                to: destination("empty"))
            XCTFail("expected noFrames")
        } catch let error as MovieExporter.Failure {
            guard case .noFrames = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertNotNil(error.errorDescription)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testAnOddSizedPresetIsRefusedBeforeAnythingIsWritten() async throws {
        let (structure, frames) = try structureAndFrames(count: 3)
        var options = MovieOptions()
        options.preset = MoviePreset(
            id: "odd", name: "odd", width: 641, height: 481, bitsPerSecond: 1_000_000)
        let url = destination("odd")

        do {
            _ = try await MovieExporter().export(
                structure: structure, frames: frames, viewerOptions: ViewerOptions(),
                flexibility: nil, options: options,
                caption: MovieExporter.Caption(
                    accession: "X", title: "", sweeps: [], rmsd: []),
                to: url)
            XCTFail("expected invalidPreset")
        } catch let error as MovieExporter.Failure {
            guard case .invalidPreset = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "nothing should have been written")
        }
    }

    /// The output goes to Caches, because it is handed straight to a share
    /// sheet: a second copy in Documents is one the user never asked for and
    /// cannot see to delete.
    func testTemporaryURLIsInCachesAndSafeForAnyAccession() {
        let url = MovieExporter.temporaryURL(accession: "P69905")
        XCTAssertTrue(url.path.contains("Caches") || url.path.contains("tmp"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".mp4"))

        // A full stop is a legal filename character, so "../../etc/passwd"
        // sanitises to ".._.._etc_passwd": ugly, and harmless, because there is
        // no separator left in it. What matters is that the name stays ONE path
        // component and never resolves to a directory reference.
        for awkward in ["../../etc/passwd", "..", ".", "", "///", "a/b\\c"] {
            let url = MovieExporter.temporaryURL(accession: awkward)
            let name = url.lastPathComponent
            XCTAssertFalse(name.contains("/"), "\(awkward) kept a separator")
            XCTAssertNotEqual(name, "..")
            XCTAssertNotEqual(name, ".")
            XCTAssertTrue(name.hasSuffix(".mp4"))
            XCTAssertFalse(
                name.hasPrefix("JUMPjet-.mp4"), "\(awkward) produced a nameless file")
            XCTAssertEqual(
                url.deletingLastPathComponent().path,
                MovieExporter.temporaryURL(accession: "X").deletingLastPathComponent().path,
                "\(awkward) escaped the movies directory")
        }
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

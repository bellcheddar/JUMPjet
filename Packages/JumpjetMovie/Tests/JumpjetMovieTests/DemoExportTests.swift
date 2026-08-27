import AVFoundation
import XCTest
import JumpjetCore
import JumpjetEngine
import JumpjetParse
import JumpjetViewer

@testable import JumpjetMovie

/// A real sortie, end to end: sample a protein, export the movie, check it back.
///
/// Opt-in, because it runs the sampler and that is seconds rather than
/// milliseconds. It exists because every other test in this package feeds the
/// exporter a SYNTHETIC trajectory, and the one thing they cannot catch is the
/// two halves being wired together wrongly.
///
///     JUMPJET_DEMO=/tmp/jumpjet-demo.mp4 swift test -c release --filter DemoExportTests
final class DemoExportTests: XCTestCase {

    func testASortieBecomesAWatchableMovie() async throws {
        let destination = ProcessInfo.processInfo.environment["JUMPJET_DEMO"]
        try XCTSkipUnless(
            destination != nil, "set JUMPJET_DEMO=<path.mp4> to write a demo movie")
        let url = URL(fileURLWithPath: destination!)

        let structure = try PDBParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.pdb"),
            identifier: "P69905", source: .alphaFold
        ).structure
        let models = Fixtures.root.deletingLastPathComponent()
            .appendingPathComponent("Models")
        let tables = try TorsionTables.load(
            from: models.appendingPathComponent("torsion_tables.json"))

        // A prior that varies along the chain, so the amplitude scaling is
        // genuinely exercised rather than constant-folded away.
        let prior = (0..<structure.residueCount).map { index -> Float in
            0.15 + 0.7 * (sin(Float(index) / 20) * 0.5 + 0.5)
        }

        let sampler = MonteCarloSampler(
            structure: structure, flexibility: prior, tables: tables,
            configuration: RunConfiguration(sweeps: 3_000, snapshotStride: 20, seed: 4))
        let trajectory = sampler.run()
        let frames = (0..<trajectory.frameCount).map { Array(trajectory.frame($0)) }

        var options = MovieOptions()
        options.preset = .landscape1080
        options.orbits = true
        options.burnsInHUD = true

        var viewer = ViewerOptions()
        viewer.colourMode = .confidence

        let rmsd = frames.map {
            Geometry.superposedRMSD(moving: $0, onto: frames[0])
        }

        let written = try await MovieExporter().export(
            structure: structure, frames: frames, viewerOptions: viewer,
            flexibility: prior, options: options,
            caption: MovieExporter.Caption(
                accession: "P69905", title: "Haemoglobin subunit alpha",
                sweeps: trajectory.sweeps, rmsd: rmsd),
            to: url)

        let asset = AVURLAsset(url: written)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let size = try FileManager.default.attributesOfItem(atPath: written.path)[.size] as? Int
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        print(String(
            format: "demo movie: %d frames, %.1f s, %.1f MB, acceptance %.3f",
            frames.count, duration, Double(size ?? 0) / 1e6, trajectory.acceptanceRatio))
        XCTAssertGreaterThan(duration, 1)
    }
}

import CoreGraphics
import Foundation

/// Output size and framing for an exported movie.
public struct MoviePreset: Sendable, Hashable, Identifiable, CaseIterable {
    public let id: String
    public let name: String
    public let width: Int
    public let height: Int
    /// The bit rate the H.264 encoder is asked for.
    public let bitsPerSecond: Int

    public var size: CGSize { CGSize(width: width, height: height) }
    public var aspect: Double { Double(width) / Double(height) }

    /// The build plan's two: 1080p and square 720p.
    public static let landscape1080 = MoviePreset(
        id: "1080p", name: "1080p", width: 1920, height: 1080, bitsPerSecond: 8_000_000)
    public static let square720 = MoviePreset(
        id: "square", name: "Square 720", width: 720, height: 720, bitsPerSecond: 5_000_000)

    public static var allCases: [MoviePreset] { [.landscape1080, .square720] }

    /// Dimensions must be EVEN. H.264 encodes in 16x16 macroblocks with 4:2:0
    /// chroma subsampling, so an odd width or height is either rejected or
    /// silently padded, and a silently padded frame is a movie with a green
    /// stripe down one edge.
    public var isValid: Bool {
        width > 0 && height > 0 && width % 2 == 0 && height % 2 == 0
    }
}

/// What goes into the movie beyond the structure.
public struct MovieOptions: Sendable, Hashable {
    public var preset: MoviePreset = .landscape1080
    public var framesPerSecond: Int = 30
    /// Burn the accession, sweep counter and RMSD into the corner.
    public var burnsInHUD = true
    /// Rotate the camera slowly through the run, so a movie of a protein that
    /// barely moves still shows it in three dimensions.
    public var orbits = true
    /// Degrees of orbit across the whole movie.
    public var orbitDegrees: Double = 120
    /// Hold the last frame this many seconds, so a movie does not cut dead on
    /// its final sweep.
    public var tailSeconds: Double = 0.5

    public init() {}

    /// Frames the writer will produce for a trajectory of `frameCount`.
    ///
    /// Each trajectory frame becomes one movie frame. A 5,000 sweep run at a
    /// stride of 25 is 201 frames, which at 30 fps is under seven seconds:
    /// short, and honest about how much was actually sampled. Interpolating to
    /// pad it out would invent conformations the sampler never visited.
    public func movieFrameCount(trajectoryFrames: Int) -> Int {
        trajectoryFrames + Int((tailSeconds * Double(framesPerSecond)).rounded())
    }

    public func duration(trajectoryFrames: Int) -> Double {
        Double(movieFrameCount(trajectoryFrames: trajectoryFrames)) / Double(framesPerSecond)
    }
}

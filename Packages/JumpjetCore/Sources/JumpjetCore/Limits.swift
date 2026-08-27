import Foundation

/// The numbers the build plan fixes, in one place so the HUD, the parser and
/// the engine cannot drift apart on them.
public enum Limits {
    /// Residues per chain that v1 will parse and sample. Beyond this the user
    /// gets ``JumpjetError/tooLarge(residues:limit:)`` rather than a slideshow.
    public static let maximumResidues = 1_200

    /// Above this the HUD warns that the sampler will be slow, but still runs.
    public static let comfortableResidues = 600

    /// Elastic network cutoff in angstroms (build plan, Phase 2).
    public static let elasticNetworkCutoff: Float = 11

    /// Soft-sphere radii are scaled by this before the clash test.
    public static let vanDerWaalsScale: Float = 0.85

    /// Default Monte Carlo sweep count for a run.
    public static let defaultSweeps = 5_000
}

import Foundation
import JumpjetCore
import simd

/// Everything the flight recorder computes from one trajectory.
///
/// Assembled in one pass so the six panels the build plan asks for share their
/// intermediate work: the chi1 tracks feed both the jump raster and nothing
/// else, but the backbone tracks feed the PCA, and re-extracting torsions per
/// panel would be most of the cost.
public struct FlightRecord: Sendable {
    public let rmsd: SweepSeries
    public let radiusOfGyration: SweepSeries
    /// Per residue, aligned with `Structure.residues`.
    public let rmsf: [Float]
    /// The prior the run was parameterised with, for the validation panel.
    public let flexibilityPrior: [Float]?
    /// Spearman rho between RMSF and the prior, or `nil` without a prior.
    public let rmsfVersusPrior: Float?

    public let rotamerJumps: JumpDetection.Report
    public let ringFlips: RingFlipDetection.Report
    public let projection: DihedralProjection?
    public let landscape: OccupancyLandscape?
    public let basins: BasinAnalysis?

    public let sweeps: [Int]
    public let frameCount: Int
    /// How long the whole analysis took. The definition of done puts a budget
    /// on it, so it is measured rather than hoped for.
    public let secondsToCompute: Double

    /// The headline for the sortie report card.
    public var summary: String {
        var parts: [String] = []
        parts.append("\(rotamerJumps.totalJumps) rotamer jumps")
        parts.append("\(ringFlips.totalFlips) ring flips")
        if let basins { parts.append("\(basins.basinCount) basins") }
        return parts.joined(separator: ", ")
    }

    /// The most mobile residues by RMSF, for the report card.
    public func hotspots(structure: Structure, limit: Int = 5)
        -> [(residueIndex: Int, label: String, rmsf: Float)]
    {
        rmsf.indices
            .sorted { rmsf[$0] > rmsf[$1] }
            .prefix(limit)
            .map { index in
                let residue = structure.residues[index]
                let chain = structure.chains.indices.contains(residue.chainIndex)
                    ? structure.chains[residue.chainIndex].id : "?"
                return (index, residue.label(chainID: chain), rmsf[index])
            }
    }
}

public enum FlightRecorder {

    /// Analyse a trajectory.
    ///
    /// - Parameter flexibility: the prior the run used, if any. Supplying it
    ///   turns on the validation panel, which is the one place the neural layer
    ///   and the physics are checked against each other. The build plan is
    ///   explicit that a disagreement should be visible rather than hidden.
    public static func analyse(
        structure: Structure,
        trajectory: TrajectoryFrames,
        flexibility: [Float]? = nil
    ) -> FlightRecord {
        let started = Date()

        let rmsd = TrajectoryStatistics.rmsd(trajectory)
        let radius = TrajectoryStatistics.radiusOfGyration(trajectory)
        let rmsf = TrajectoryStatistics.rmsf(trajectory, structure: structure)

        var correlation: Float?
        if let flexibility, flexibility.count == rmsf.count {
            correlation = Spearman.correlation(rmsf, flexibility)
        }

        let chi1 = TorsionSeries.chiTracks(
            structure: structure, trajectory: trajectory, chiIndex: 0)
        let chi2 = TorsionSeries.chiTracks(
            structure: structure, trajectory: trajectory, chiIndex: 1)

        let jumps = JumpDetection.report(tracks: chi1, sweeps: trajectory.sweeps)
        let flips = RingFlipDetection.report(chi2Tracks: chi2, sweeps: trajectory.sweeps)

        let projection = DihedralPCA.project(structure: structure, trajectory: trajectory)
        let landscape = projection.map { BasinFinder.landscape($0) }
        let basins = projection.flatMap { BasinFinder.analyse($0) }

        return FlightRecord(
            rmsd: rmsd, radiusOfGyration: radius, rmsf: rmsf,
            flexibilityPrior: flexibility, rmsfVersusPrior: correlation,
            rotamerJumps: jumps, ringFlips: flips, projection: projection,
            landscape: landscape, basins: basins,
            sweeps: trajectory.sweeps, frameCount: trajectory.frameCount,
            secondsToCompute: Date().timeIntervalSince(started))
    }
}

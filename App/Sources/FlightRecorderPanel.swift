import Charts
import JumpjetAnalysis
import JumpjetCore
import JumpjetHUD
import SwiftUI

/// The flight recorder: the six panels the build plan's Phase 3 asks for.
///
/// Swift Charts throughout, HUD-styled. Every horizontal axis is labelled in
/// SWEEPS, per ground rule 3, and nothing here converts them to anything else.
struct FlightRecorderPanel: View {
    let record: FlightRecord
    let structure: Structure
    /// Called when the user taps something that points at a residue or a frame,
    /// so the viewer can jump there.
    var onSelect: (AnalysisSelection) -> Void = { _ in }

    var body: some View {
        VStack(spacing: HUDMetrics.panelSpacing) {
            basicsPanel
            validationPanel
            jumpsPanel
            flipsPanel
            landscapePanel
            basinsPanel
        }
    }

    // MARK: - 1. Per-trajectory basics

    private var basicsPanel: some View {
        HUDPanel("Flight data", trailing: "\(record.frameCount) FRAMES") {
            VStack(alignment: .leading, spacing: 14) {
                seriesChart(record.rmsd, colour: HUDPalette.primary)
                seriesChart(record.radiusOfGyration, colour: HUDPalette.accent)
                Text("Sweeps are pseudo-time, not picoseconds.")
                    .font(HUDTypography.readoutSmall(9))
                    .foregroundStyle(HUDPalette.muted)
            }
        }
    }

    private func seriesChart(_ series: SweepSeries, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(series.label) (\(series.unit))").hudLabelStyle()
                Spacer()
                Text(HUDFormat.fixed(Double(series.values.last ?? 0)))
                    .font(HUDTypography.readoutSmall(11))
                    .foregroundStyle(colour)
            }
            Chart {
                ForEach(Array(zip(series.sweeps, series.values)), id: \.0) { sweep, value in
                    LineMark(x: .value("Sweep", sweep), y: .value(series.label, value))
                        .foregroundStyle(colour)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis { hudAxis(label: "sweeps") }
            .chartYAxis { hudValueAxis() }
            .frame(height: 90)
        }
    }

    // MARK: - 2. Validation panel

    /// RMSF against the neural prior, per residue, with Spearman rho shown.
    ///
    /// The build plan is explicit that a disagreement between the engine and
    /// the prior should be VISIBLE rather than hidden, so the coefficient is
    /// printed whatever it says and the scatter is drawn beside it.
    @ViewBuilder
    private var validationPanel: some View {
        if let prior = record.flexibilityPrior, prior.count == record.rmsf.count {
            HUDPanel(
                "Validation", trailing: record.rmsfVersusPrior.map {
                    "SPEARMAN \(HUDFormat.fixed(Double($0)))"
                } ?? "NO PRIOR"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Chart {
                        ForEach(record.rmsf.indices, id: \.self) { index in
                            PointMark(
                                x: .value("Prior", prior[index]),
                                y: .value("RMSF", record.rmsf[index])
                            )
                            .foregroundStyle(HUDPalette.primary.opacity(0.6))
                            .symbolSize(12)
                        }
                    }
                    .chartXAxis { hudAxis(label: "flexibility prior") }
                    .chartYAxis { hudValueAxis() }
                    .frame(height: 130)

                    Text(validationVerdict)
                        .font(HUDTypography.body(11))
                        .foregroundStyle(HUDPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var validationVerdict: String {
        guard let rho = record.rmsfVersusPrior else { return "" }
        let base = "RMSF in angstroms against the prior on 0 to 1, per residue. "
        switch rho {
        case 0.5...:
            return base + "The sampler and the neural prior agree about which parts move."
        case 0.2..<0.5:
            return base + "Weak agreement. The prior is one of several things setting the "
                + "amplitude, and the elastic network is another."
        case ..<0:
            return base + "They DISAGREE: residues the prior calls floppy are moving least. "
                + "Worth looking at before trusting either."
        default:
            return base + "Almost no relationship. The prior is not, on this run, predicting "
                + "what actually moved."
        }
    }

    // MARK: - 3. Rotamer jumps

    private var jumpsPanel: some View {
        HUDPanel(
            "Rotamer jumps",
            trailing: "\(record.rotamerJumps.totalJumps) · "
                + "\(HUDFormat.fixed(Double(record.rotamerJumps.jumpsPerThousandSweeps), decimals: 1))/1K"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if record.rotamerJumps.totalJumps == 0 {
                    Text("No chi1 rotamer changed well during this run.")
                        .font(HUDTypography.body(12))
                        .foregroundStyle(HUDPalette.muted)
                } else {
                    JumpRaster(report: record.rotamerJumps, onSelect: onSelect)
                    ForEach(record.rotamerJumps.busiest(limit: 5), id: \.residueIndex) { entry in
                        Button {
                            onSelect(.residue(entry.residueIndex))
                        } label: {
                            HStack {
                                Text(entry.label)
                                    .font(HUDTypography.readoutSmall(11))
                                    .foregroundStyle(HUDPalette.text)
                                Spacer()
                                Text("\(entry.jumps)")
                                    .font(HUDTypography.readoutSmall(11))
                                    .foregroundStyle(HUDPalette.accent)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Text(record.rotamerJumps.interpretation)
                        .font(HUDTypography.readoutSmall(9))
                        .foregroundStyle(HUDPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 4. Ring flips

    private var flipsPanel: some View {
        HUDPanel(
            "Ring flips",
            trailing: "\(record.ringFlips.totalFlips) OF "
                + "\(record.ringFlips.flippableResidues.count) RINGS"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if record.ringFlips.totalFlips == 0 {
                    Text(
                        "No phenylalanine or tyrosine ring flipped. "
                            + record.ringFlips.caveat
                    )
                    .font(HUDTypography.body(11))
                    .foregroundStyle(HUDPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(record.ringFlips.busiest(limit: 5), id: \.residueIndex) { entry in
                        Button {
                            onSelect(.residue(entry.residueIndex))
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10))
                                    .foregroundStyle(HUDPalette.accent)
                                Text(entry.label)
                                    .font(HUDTypography.readoutSmall(11))
                                    .foregroundStyle(HUDPalette.text)
                                Spacer()
                                Text("\(entry.flips)")
                                    .font(HUDTypography.readoutSmall(11))
                                    .foregroundStyle(HUDPalette.accent)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Text(record.ringFlips.caveat)
                        .font(HUDTypography.readoutSmall(9))
                        .foregroundStyle(HUDPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 5. The terrain map

    @ViewBuilder
    private var landscapePanel: some View {
        // A panel that VANISHES when it has nothing to show reads as a bug. The
        // projection is legitimately unavailable on a short run: fewer than two
        // residues clear the eight degree threshold for having moved at all, so
        // there is no plane to project onto. Saying that is information; an
        // absence is not.
        if let landscape = record.landscape, let projection = record.projection {
            HUDPanel(
                "Terrain",
                trailing: "PC1 \(HUDFormat.percent(Double(projection.explainedVariance.x)))"
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    TerrainMap(
                        landscape: landscape, projection: projection,
                        basins: record.basins, onSelect: onSelect)
                        .frame(height: 200)
                    Text(
                        "Dihedral PCA on sin and cos of phi and psi. Darker is more "
                            + "occupied; the scale is -ln(density) in kT."
                    )
                    .font(HUDTypography.readoutSmall(9))
                    .foregroundStyle(HUDPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HUDPanel("Terrain", trailing: "NO PROJECTION") {
                Text(
                    "Too little backbone motion to project. Fewer than two residues "
                        + "moved by more than eight degrees, so there is no plane to "
                        + "draw a landscape on. Run more sweeps, or raise the throttle."
                )
                .font(HUDTypography.body(11))
                .foregroundStyle(HUDPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 6. Basins

    @ViewBuilder
    private var basinsPanel: some View {
        if let basins = record.basins {
            HUDPanel(
                "Basins",
                trailing: "K=\(basins.chosenK) · SILHOUETTE "
                    + HUDFormat.fixed(Double(basins.silhouette))
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<basins.basinCount, id: \.self) { basin in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Self.basinColour(basin))
                                .frame(width: 8, height: 8)
                            Text("Basin \(basin + 1)")
                                .font(HUDTypography.readoutSmall(11))
                                .foregroundStyle(HUDPalette.text)
                            Spacer()
                            Text("\(basins.occupancy[basin]) frames")
                                .font(HUDTypography.readoutSmall(10))
                                .foregroundStyle(HUDPalette.muted)
                            Text("dwell \(HUDFormat.count(Int(basins.meanDwell(basin: basin))))")
                                .font(HUDTypography.readoutSmall(10))
                                .foregroundStyle(HUDPalette.primary)
                        }
                    }

                    Text("Jumps between basins").hudLabelStyle()
                    JumpMatrixGrid(basins: basins)

                    Text(basins.caveat)
                        .font(HUDTypography.readoutSmall(9))
                        .foregroundStyle(HUDPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HUDPanel("Basins", trailing: "NOT CLUSTERED") {
                Text(
                    record.projection == nil
                        ? "No projection to cluster: see the terrain panel."
                        : "The trajectory did not separate into basins. Either it never "
                            + "left one, or there are too few frames to tell."
                )
                .font(HUDTypography.body(11))
                .foregroundStyle(HUDPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func basinColour(_ index: Int) -> Color {
        let hues: [Double] = [0.42, 0.11, 0.58, 0.85, 0.02]
        return Color(hue: hues[index % hues.count], saturation: 0.7, brightness: 0.95)
    }

    // MARK: - Axis styling

    private func hudAxis(label: String) -> some AxisContent {
        AxisMarks(preset: .aligned) { _ in
            AxisGridLine().foregroundStyle(HUDPalette.grid)
            AxisTick().foregroundStyle(HUDPalette.border)
            AxisValueLabel()
                .font(HUDTypography.readoutSmall(8))
                .foregroundStyle(HUDPalette.muted)
        }
    }

    private func hudValueAxis() -> some AxisContent {
        AxisMarks(preset: .aligned, position: .leading) { _ in
            AxisGridLine().foregroundStyle(HUDPalette.grid)
            AxisValueLabel()
                .font(HUDTypography.readoutSmall(8))
                .foregroundStyle(HUDPalette.muted)
        }
    }
}

/// What the user tapped, so the viewer can jump to it.
enum AnalysisSelection: Equatable {
    case residue(Int)
    case frame(Int)
}

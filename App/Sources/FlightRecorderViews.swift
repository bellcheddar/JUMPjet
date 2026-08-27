import JumpjetAnalysis
import JumpjetHUD
import SwiftUI

/// The jump raster: residue down, sweep across, one cell per frame coloured by
/// which rotamer well the side chain was in.
///
/// Drawn in a `Canvas` rather than as a chart. A 300-residue run at 200 frames
/// is 60,000 cells, and a chart mark per cell is 60,000 views: the raster is
/// the one panel where the naive approach does not merely look slow, it stops
/// laying out at all.
struct JumpRaster: View {
    let report: JumpDetection.Report
    var onSelect: (AnalysisSelection) -> Void = { _ in }

    /// Rows are capped, because a raster taller than the screen is a raster
    /// nobody reads. The busiest residues are the ones worth the space, and the
    /// caption says how many were left out.
    private static let maximumRows = 24

    private var rows: [(residueIndex: Int, label: String, states: [RotamerState])] {
        let busiest = Set(report.busiest(limit: Self.maximumRows).map(\.residueIndex))
        return report.raster.filter { busiest.contains($0.residueIndex) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let visible = rows
                guard !visible.isEmpty, let frames = visible.first?.states.count, frames > 0
                else { return }
                let rowHeight = size.height / CGFloat(visible.count)
                let cellWidth = size.width / CGFloat(frames)

                for (rowIndex, row) in visible.enumerated() {
                    for (frame, state) in row.states.enumerated() {
                        let rect = CGRect(
                            x: CGFloat(frame) * cellWidth,
                            y: CGFloat(rowIndex) * rowHeight,
                            width: max(cellWidth, 1), height: max(rowHeight - 1, 1))
                        context.fill(Path(rect), with: .color(Self.colour(for: state)))
                    }
                }
            }
            .frame(height: CGFloat(min(rows.count, Self.maximumRows)) * 7)
            .background(HUDPalette.background)
            .accessibilityLabel(
                "Rotamer state raster, \(rows.count) residues across "
                    + "\(report.sweeps.last ?? 0) sweeps")

            HStack(spacing: 10) {
                ForEach(RotamerState.allCases, id: \.self) { state in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Self.colour(for: state))
                            .frame(width: 8, height: 8)
                        Text(state.shortName)
                            .font(HUDTypography.readoutSmall(9))
                            .foregroundStyle(HUDPalette.muted)
                    }
                }
                Spacer()
                if report.raster.count > Self.maximumRows {
                    Text("\(report.raster.count - Self.maximumRows) more not shown")
                        .font(HUDTypography.readoutSmall(9))
                        .foregroundStyle(HUDPalette.muted)
                }
            }
        }
    }

    /// The three wells get three distinct colours, and none of them is the
    /// HUD's amber: amber means a jump EVENT everywhere else in the app, and
    /// reusing it for a resting state would make a still raster look eventful.
    static func colour(for state: RotamerState) -> Color {
        switch state {
        case .gaucheMinus: Color(hue: 0.55, saturation: 0.75, brightness: 0.85)
        case .gauchePlus: Color(hue: 0.42, saturation: 0.70, brightness: 0.80)
        case .trans: Color(hue: 0.75, saturation: 0.55, brightness: 0.80)
        }
    }
}

/// The occupancy landscape as a heat map, with the trajectory's path over it.
struct TerrainMap: View {
    let landscape: OccupancyLandscape
    let projection: DihedralProjection
    let basins: BasinAnalysis?
    var onSelect: (AnalysisSelection) -> Void = { _ in }

    var body: some View {
        Canvas { context, size in
            let bins = landscape.bins
            let cellWidth = size.width / CGFloat(bins)
            let cellHeight = size.height / CGFloat(bins)

            for y in 0..<bins {
                for x in 0..<bins {
                    let energy = landscape.value(x: x, y: y)
                    // Low energy is occupied and bright. Inverted, the picture
                    // is still a plausible-looking contour map and says the
                    // opposite of what it means.
                    let occupancy = 1 - min(1, Double(energy / max(landscape.ceiling, 1e-6)))
                    let rect = CGRect(
                        // Row 0 is the LOW end of y, and a canvas draws
                        // downwards, so the rows are flipped. Without this the
                        // landscape is a mirror image of the basins drawn on
                        // top of it, which looks like a clustering bug.
                        x: CGFloat(x) * cellWidth,
                        y: size.height - CGFloat(y + 1) * cellHeight,
                        width: cellWidth + 0.5, height: cellHeight + 0.5)
                    context.fill(
                        Path(rect),
                        with: .color(
                            Color(
                                hue: 0.45 - 0.12 * occupancy, saturation: 0.55 * occupancy + 0.1,
                                brightness: 0.10 + 0.75 * occupancy)))
                }
            }

            // The path the run actually took, faintly, over the density.
            var path = Path()
            for (index, point) in projection.points.enumerated() {
                let position = CGPoint(
                    x: CGFloat(fraction(point.x, landscape.xRange)) * size.width,
                    y: size.height
                        - CGFloat(fraction(point.y, landscape.yRange)) * size.height)
                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
            context.stroke(
                path, with: .color(HUDPalette.text.opacity(0.35)), lineWidth: 0.6)

            // Basin centres on top.
            if let basins {
                for (index, centre) in basins.centres.enumerated() {
                    let position = CGPoint(
                        x: CGFloat(fraction(centre.x, landscape.xRange)) * size.width,
                        y: size.height
                            - CGFloat(fraction(centre.y, landscape.yRange)) * size.height)
                    let marker = CGRect(
                        x: position.x - 5, y: position.y - 5, width: 10, height: 10)
                    context.stroke(
                        Path(ellipseIn: marker),
                        with: .color(FlightRecorderPanel.basinColour(index)), lineWidth: 2)
                }
            }
        }
        .background(HUDPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(
            "Conformational landscape, \(basins?.basinCount ?? 0) basins over "
                + "\(projection.frameCount) frames")
    }

    private func fraction(_ value: Float, _ range: ClosedRange<Float>) -> Float {
        let span = range.upperBound - range.lowerBound
        guard span > 1e-9 else { return 0.5 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }
}

/// The basin-to-basin jump matrix, as a small grid.
struct JumpMatrixGrid: View {
    let basins: BasinAnalysis

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow {
                Text("").frame(width: 22)
                ForEach(0..<basins.basinCount, id: \.self) { column in
                    Text("\(column + 1)")
                        .font(HUDTypography.readoutSmall(9))
                        .foregroundStyle(FlightRecorderPanel.basinColour(column))
                        .frame(width: 28)
                }
            }
            ForEach(0..<basins.basinCount, id: \.self) { row in
                GridRow {
                    Text("\(row + 1)")
                        .font(HUDTypography.readoutSmall(9))
                        .foregroundStyle(FlightRecorderPanel.basinColour(row))
                        .frame(width: 22)
                    ForEach(0..<basins.basinCount, id: \.self) { column in
                        let count = basins.jumpMatrix[row][column]
                        // The diagonal is residence, not a jump, and it dwarfs
                        // everything else. Shown dimmed so the off-diagonal
                        // (which is what the panel is about) still reads.
                        Text("\(count)")
                            .font(HUDTypography.readoutSmall(10))
                            .monospacedDigit()
                            .foregroundStyle(
                                row == column
                                    ? HUDPalette.muted
                                    : (count > 0 ? HUDPalette.accent : HUDPalette.border))
                            .frame(width: 28, height: 18)
                            .background(
                                row == column
                                    ? Color.clear
                                    : HUDPalette.accent.opacity(count > 0 ? 0.12 : 0))
                    }
                }
            }
        }
        .accessibilityLabel(
            "Basin transition matrix, \(basins.totalTransitions) jumps between "
                + "\(basins.basinCount) basins")
    }
}

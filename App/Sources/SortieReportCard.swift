import JumpjetAnalysis
import JumpjetCore
import JumpjetFetch
import JumpjetHUD
import SwiftUI

/// The one-card summary of a sortie, exportable as a PNG alongside the movie.
///
/// Fixed size rather than adaptive: it is a picture, not a screen, and a
/// shareable card whose layout depends on the phone it was made on is a card
/// that looks different every time somebody sends one.
struct SortieReportCard: View {
    let model: LoadedModel
    let record: FlightRecord
    let prior: FlexibilitySummary?

    static let size = CGSize(width: 1000, height: 1400)

    struct FlexibilitySummary: Sendable {
        let blend: String
        let mean: Float
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header
            Divider().overlay(HUDPalette.border)
            counts
            Divider().overlay(HUDPalette.border)
            events
            Divider().overlay(HUDPalette.border)
            hotspots
            Spacer(minLength: 0)
            footer
        }
        .padding(46)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(HUDPalette.background)
        .foregroundStyle(HUDPalette.text)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JUMPjet · SORTIE REPORT")
                .font(HUDTypography.label(15))
                .tracking(3)
                .foregroundStyle(HUDPalette.primary)
            Text(model.entry?.proteinName ?? model.structure.title)
                .font(.system(size: 40, weight: .semibold))
                .lineLimit(2)
            HStack(spacing: 14) {
                Text(model.accession.value)
                    .font(HUDTypography.readout(24))
                    .foregroundStyle(HUDPalette.primary)
                if let organism = model.entry?.organism {
                    Text(organism)
                        .font(.system(size: 20).italic())
                        .foregroundStyle(HUDPalette.muted)
                }
            }
            Text(model.provenance.detail)
                .font(HUDTypography.readoutSmall(16))
                .foregroundStyle(HUDPalette.muted)
        }
    }

    private var counts: some View {
        HStack(alignment: .top, spacing: 0) {
            statistic("Residues", HUDFormat.count(model.structure.residueCount))
            statistic("Atoms", HUDFormat.count(model.structure.atomCount))
            statistic("Sweeps", HUDFormat.count(record.sweeps.last ?? 0))
            statistic("Frames", "\(record.frameCount)")
        }
    }

    private var events: some View {
        HStack(alignment: .top, spacing: 0) {
            statistic(
                "Rotamer jumps", HUDFormat.count(record.rotamerJumps.totalJumps),
                colour: HUDPalette.accent)
            statistic(
                "Ring flips", HUDFormat.count(record.ringFlips.totalFlips),
                colour: HUDPalette.accent)
            statistic("Basins", record.basins.map { "\($0.basinCount)" } ?? "—")
            statistic(
                "RMSD", HUDFormat.fixed(Double(record.rmsd.values.last ?? 0)) + " A")
        }
    }

    private var hotspots: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Most mobile residues, by RMSF")
                .font(HUDTypography.label(14))
                .tracking(1.6)
                .foregroundStyle(HUDPalette.muted)
            ForEach(
                record.hotspots(structure: model.structure, limit: 5), id: \.residueIndex
            ) { entry in
                HStack {
                    Text(entry.label)
                        .font(HUDTypography.readoutSmall(20))
                    Spacer()
                    Text(HUDFormat.fixed(Double(entry.rmsf)) + " A")
                        .font(HUDTypography.readoutSmall(20))
                        .foregroundStyle(HUDPalette.primary)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let prior {
                Text(
                    "Flexibility prior: \(prior.blend), mean "
                        + HUDFormat.fixed(Double(prior.mean))
                        + (record.rmsfVersusPrior.map {
                            ". Spearman against RMSF: " + HUDFormat.fixed(Double($0))
                        } ?? "")
                )
                .font(HUDTypography.readoutSmall(15))
                .foregroundStyle(HUDPalette.muted)
            }
            // Ground rule 3 travels with the card, for the same reason it
            // travels with the movie: whoever is sent one cannot see the About
            // screen.
            Text(
                "Sweeps are pseudo-time, not picoseconds. JUMPjet is a crude on-device "
                    + "torsional Monte Carlo sampler; jump counts reflect its move set as "
                    + "well as the protein."
            )
            .font(HUDTypography.readoutSmall(14))
            .foregroundStyle(HUDPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
            Text("marcdeller.com")
                .font(HUDTypography.readoutSmall(14))
                .foregroundStyle(HUDPalette.primary)
        }
    }

    private func statistic(
        _ label: String, _ value: String, colour: Color = HUDPalette.primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(HUDTypography.label(13))
                .tracking(1.4)
                .foregroundStyle(HUDPalette.muted)
            Text(value)
                .font(HUDTypography.readout(34))
                .foregroundStyle(colour)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

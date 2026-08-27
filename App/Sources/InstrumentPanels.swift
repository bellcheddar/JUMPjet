import JumpjetCore
import JumpjetFetch
import JumpjetHUD
import JumpjetViewer
import SwiftUI

/// What was loaded and where it came from. JUMPjet never shows a structure
/// without saying which one it is.
struct SortiePanel: View {
    let model: LoadedModel

    var body: some View {
        HUDPanel("Sortie", trailing: model.provenance.fromCache ? "CACHED" : "LIVE") {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.entry?.proteinName ?? model.structure.title)
                    .font(HUDTypography.title(16))
                    .foregroundStyle(HUDPalette.text)
                    .lineLimit(2)
                if let organism = model.entry?.organism {
                    Text(organism)
                        .font(HUDTypography.body(12).italic())
                        .foregroundStyle(HUDPalette.muted)
                }

                Divider().overlay(HUDPalette.border)

                HStack(alignment: .top) {
                    HUDReadout(
                        label: "Residues", value: HUDFormat.count(model.structure.residueCount),
                        size: 22)
                    Spacer()
                    HUDReadout(
                        label: "Atoms", value: HUDFormat.count(model.structure.atomCount), size: 22)
                    Spacer()
                    HUDReadout(
                        label: "Chains", value: "\(model.structure.chains.count)", size: 22)
                }

                if let plddt = model.structure.meanPLDDT {
                    TapeGauge(
                        label: "Mean pLDDT", value: Double(plddt),
                        scale: GaugeScale(lower: 0, upper: 100),
                        colour: plddt >= 70 ? HUDPalette.primary : HUDPalette.accent)
                }

                Text(model.provenance.detail)
                    .font(HUDTypography.readoutSmall(11))
                    .foregroundStyle(HUDPalette.muted)

                // The residue-count warning is honest rather than blocking: the
                // build plan's comfortable ceiling is about frame rate in the
                // Phase 2 sampler, not about whether the model can be shown.
                if model.structure.residueCount > Limits.comfortableResidues {
                    HUDLamp(
                        role: .caution,
                        text: "\(model.structure.residueCount) residues, sampling will be slow")
                }
            }
        }
    }
}

/// Viewer controls: colour mode, side chains, chain picker.
struct DisplayPanel: View {
    @Bindable var model: AppModel
    let structure: Structure

    var body: some View {
        HUDPanel("Display") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Colour").hudLabelStyle()
                    Picker("Colour", selection: $model.options.colourMode) {
                        ForEach(model.availableColourModes, id: \.self) { mode in
                            Text(mode.shortName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Toggle(isOn: $model.options.showsSideChains) {
                    Text("Side chains")
                        .font(HUDTypography.body(13))
                }
                .toggleStyle(.switch)
                .tint(HUDPalette.primary)

                if structure.chains.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Chain").hudLabelStyle()
                        // "All" is offered as well as the individual chains,
                        // so a tetramer can be seen as a tetramer. It is not
                        // the default: the accession names one chain, and
                        // drawing four buries the one that was asked for.
                        Picker("Chain", selection: chainBinding) {
                            Text("All").tag(Int?.none)
                            ForEach(structure.chains.indices, id: \.self) { index in
                                Text(model.chainLabel(index)).tag(Int?.some(index))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityIdentifier("chainPicker")
                    }
                }
            }
        }
    }

    private var chainBinding: Binding<Int?> {
        Binding(
            get: { model.focusedChain },
            set: { model.focus(chain: $0) })
    }
}

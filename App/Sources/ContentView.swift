import JumpjetCore
import JumpjetHUD
import JumpjetViewer
import SwiftUI

/// The cockpit.
///
/// iPhone stacks the viewer over the instruments; iPad puts the viewer left and
/// the instruments right, which is the build plan's Phase 4 layout brought
/// forward because doing it later would mean rewriting this view rather than
/// adding to it.
struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ZStack {
            HUDPalette.background.ignoresSafeArea()

            GeometryReader { geometry in
                // Split on the actual SHAPE of the window, not on the size
                // class. An iPad is `.regular` in both orientations, and in
                // portrait a side-by-side split leaves the viewer a pane about
                // twice as tall as it is wide, where fitting a structure that
                // can be rotated in any direction means most of the panel is
                // empty. Landscape on a phone gets the split for the same
                // reason: it is the right shape for it.
                let sideBySide = geometry.size.width > geometry.size.height

                VStack(spacing: HUDMetrics.panelSpacing) {
                    AccessionBar(model: model)

                    if sideBySide {
                        HStack(alignment: .top, spacing: HUDMetrics.panelSpacing) {
                            viewerArea
                                .frame(maxWidth: .infinity)
                            ScrollView { instruments }
                                .frame(width: sizeClass == .regular ? 340 : 300)
                        }
                    } else {
                        viewerArea
                            .frame(maxHeight: .infinity)
                        ScrollView { instruments }
                            // Taller since Phase 2 added the engine panel: at
                            // 260 the RUN control was below the fold on a
                            // phone, which made the app look like it had no
                            // engines at all.
                            .frame(maxHeight: sizeClass == .regular ? 420 : 330)
                    }
                }
                .padding(HUDMetrics.panelSpacing)
            }
        }
        .foregroundStyle(HUDPalette.text)
    }

    // MARK: - Viewer

    @ViewBuilder
    private var viewerArea: some View {
        HUDPanel {
            ZStack {
                switch model.status {
                case .idle:
                    StandbyView(model: model)
                case .loading(let phase):
                    HUDProgressBar(caption: phase.caption)
                        .padding(.horizontal, 40)
                case .failed(let error):
                    FailureView(error: error) { model.load() }
                case .loaded(let loaded):
                    StructureViewer(
                        structure: model.run.liveStructure ?? loaded.structure,
                        options: model.options,
                        flexibility: model.run.flexibilityValues,
                        frameVersion: model.run.frameVersion)
                        .clipShape(RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius - 4))
                        .overlay(alignment: .bottomLeading) {
                            ColourLegend(mode: model.options.colourMode, structure: loaded.structure)
                                .padding(8)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Instruments

    @ViewBuilder
    private var instruments: some View {
        VStack(spacing: HUDMetrics.panelSpacing) {
            if let loaded = model.status.model {
                // The engines come first once they are doing something. A run
                // in progress is the thing the user is watching, and on a phone
                // the instrument column scrolls, so third place means offscreen.
                if model.run.stage.isBusy || model.run.trajectory != nil {
                    EnginePanel(model: model)
                    SortiePanel(model: loaded)
                } else {
                    SortiePanel(model: loaded)
                    EnginePanel(model: model)
                }
                DisplayPanel(model: model, structure: loaded.structure)
                if !loaded.report.summary.isEmpty {
                    HUDPanel("Parser") {
                        Text(loaded.report.summary)
                            .font(HUDTypography.body(12))
                            .foregroundStyle(HUDPalette.muted)
                    }
                }
            } else {
                HUDPanel("Engines") {
                    VStack(alignment: .leading, spacing: 8) {
                        HUDLamp(role: .inactive, text: "JetEngine offline")
                        HUDLamp(role: .inactive, text: "Neural prior offline")
                        Text(
                            "The sampler and the neural flexibility prior arrive in Phase 2. "
                                + "Phase 1 flies the airframe: fetch, parse and view."
                        )
                        .font(HUDTypography.body(12))
                        .foregroundStyle(HUDPalette.muted)
                    }
                }
            }
        }
    }
}

/// Shown before anything is loaded: the test accessions from the build plan, so
/// the first flight takes one tap.
private struct StandbyView: View {
    let model: AppModel

    /// Small, medium and large, as the build plan's definition of done asks for.
    private static let suggestions: [(accession: String, label: String, detail: String)] = [
        ("P69905", "HBA_HUMAN", "142 aa"),
        ("P04406", "G3P_HUMAN", "335 aa"),
        ("P07900", "HS90A_HUMAN", "732 aa"),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "airplane.departure")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(HUDPalette.primary.opacity(0.7))
            Text("Enter a UniProt accession")
                .font(HUDTypography.title())
                .foregroundStyle(HUDPalette.text)
            Text("Vertical take-off molecular dynamics. No cluster, no queue, no cloud.")
                .font(HUDTypography.body(13))
                .foregroundStyle(HUDPalette.muted)
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                Text(model.recentAccessions.isEmpty ? "Test flights" : "Recent sorties")
                    .hudLabelStyle()
                if model.recentAccessions.isEmpty {
                    ForEach(Self.suggestions, id: \.accession) { suggestion in
                        Button {
                            model.load(suggestion.accession)
                        } label: {
                            HStack(spacing: 8) {
                                Text(suggestion.accession)
                                    .font(HUDTypography.readoutSmall(13))
                                    .foregroundStyle(HUDPalette.primary)
                                Text(suggestion.label)
                                    .font(HUDTypography.body(12))
                                    .foregroundStyle(HUDPalette.text)
                                Text(suggestion.detail)
                                    .font(HUDTypography.readoutSmall(11))
                                    .foregroundStyle(HUDPalette.muted)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 8) {
                        ForEach(model.recentAccessions.prefix(4), id: \.self) { accession in
                            Button(accession) { model.load(accession) }
                                .font(HUDTypography.readoutSmall(12))
                                .foregroundStyle(HUDPalette.primary)
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
        .padding(24)
    }
}

/// Errors get their own view rather than an alert: the message is the useful
/// part and an alert makes the user dismiss it before they can act on it.
private struct FailureView: View {
    let error: JumpjetError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: HUDPalette.Role.caution.symbolName)
                .font(.system(size: 30))
                .foregroundStyle(HUDPalette.accent)
            Text(error.title)
                .font(HUDTypography.title(17))
            Text(error.message)
                .font(HUDTypography.body(13))
                .foregroundStyle(HUDPalette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HUDActionButton("Try again", systemImage: "arrow.clockwise", action: retry)
                .frame(maxWidth: 200)
                .padding(.top, 4)
        }
        .padding(28)
    }
}

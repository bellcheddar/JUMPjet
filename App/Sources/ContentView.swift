import JumpjetCore
import JumpjetAnalysis
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
                            instrumentColumn
                                .frame(width: sizeClass == .regular ? 340 : 300)
                        }
                    } else {
                        // Once there is a flight record the balance flips.
                        // Before a run the structure is what you came for;
                        // after one the analysis is, and six panels under a
                        // 330 point window is a scroll nobody finishes.
                        //
                        // The panel column was already raised from 260 to 330
                        // when Phase 2 added the engines, because at 260 the
                        // RUN control sat below the fold and the app looked as
                        // though it had none.
                        let hasRecord = model.run.record != nil
                        viewerArea
                            .frame(
                                maxHeight: hasRecord
                                    ? geometry.size.height * 0.34 : .infinity)
                        instrumentColumn
                            .frame(
                                maxHeight: hasRecord
                                    ? .infinity
                                    : (sizeClass == .regular ? 420 : 330))
                    }
                }
                .padding(HUDMetrics.panelSpacing)
            }
        }
        .foregroundStyle(HUDPalette.text)
    }

    // MARK: - Instruments

    /// The instrument column, plus the seam a screenshot run needs.
    ///
    /// `JUMPJET_PANEL=recorder` scrolls straight to that panel once a record
    /// exists. Without it there is no way to photograph anything below the
    /// fold from outside the app: the column scrolls and a capture script
    /// cannot drag. It reads an environment variable rather than a build flag
    /// so a release build behaves identically when nothing sets it, which is
    /// the choice `JUMPJET_AUTOLOAD` already makes.
    @ViewBuilder
    private var instrumentColumn: some View {
        ScrollViewReader { proxy in
            ScrollView { instruments }
                .onChange(of: model.run.record != nil) { _, hasRecord in
                    guard hasRecord, let panel = Self.panelToShow else { return }
                    // A record arriving relays the whole column, so scrolling
                    // in the same turn lands on a layout that is about to be
                    // replaced.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        withAnimation { proxy.scrollTo(panel, anchor: .top) }
                    }
                }
        }
    }

    private static var panelToShow: String? {
        let value = ProcessInfo.processInfo.environment["JUMPJET_PANEL"]?
            .trimmingCharacters(in: .whitespaces)
        return (value?.isEmpty == false) ? value : nil
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
                        frameVersion: model.run.frameVersion,
                        ghosts: model.run.ghostFrames)
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
                // Newest information first. The instrument column scrolls on a
                // phone, so "third panel down" means offscreen, and the panel
                // worth reading changes as a sortie progresses: the engines
                // while they are running, the flight recorder once they stop.
                if let record = model.run.record {
                    // Playback above the analysis: the analysis is what to look
                    // at, and the transport is how you look at it.
                    PlaybackPanel(run: model.run).id("playback")
                    ExportPanel(model: model).id("export")
                    FlightRecorderPanel(
                        record: record, structure: loaded.structure,
                        // Written as a closure, not `model.select`: `model` is
                        // `@Bindable`, so a bare method reference resolves
                        // through the dynamic-member subscript and comes back
                        // as a Binding.
                        onSelect: { model.select($0) })
                        .id("recorder")
                    EnginePanel(model: model).id("engine")
                    SortiePanel(model: loaded)
                } else if model.run.stage.isBusy {
                    EnginePanel(model: model)
                    SortiePanel(model: loaded)
                } else {
                    SortiePanel(model: loaded)
                    EnginePanel(model: model)
                }
                DisplayPanel(model: model, structure: loaded.structure).id("display")
            } else {
                HUDPanel("Engines") {
                    VStack(alignment: .leading, spacing: 8) {
                        HUDLamp(role: .inactive, text: "JetEngine offline")
                        HUDLamp(role: .inactive, text: "Neural prior offline")
                        Text(
                            "Enter an accession to bring the airframe online. The sampler "
                                + "and the neural flexibility prior spin up with it."
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
            Text("Vertical take-off conformational sampling. No cluster, no queue, no cloud.")
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

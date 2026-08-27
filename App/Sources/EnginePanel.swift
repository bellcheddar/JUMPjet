import JumpjetCore
import JumpjetEngine
import JumpjetHUD
import JumpjetNeural
import SwiftUI

/// The engine instruments: the RUN control, the throttle, and the live gauges.
struct EnginePanel: View {
    @Bindable var model: AppModel

    private var run: RunCoordinator { model.run }

    var body: some View {
        HUDPanel("Engines", trailing: run.stage.caption) {
            VStack(alignment: .leading, spacing: 12) {
                lamps

                switch run.stage {
                case .sampling(let progress):
                    instruments(progress)
                    HUDActionButton(
                        "Abort", systemImage: "stop.fill", role: .caution,
                        action: run.cancel)
                case .loadingModel, .embedding:
                    HUDProgressBar(caption: run.stage.caption)
                    HUDActionButton(
                        "Abort", systemImage: "stop.fill", role: .caution,
                        action: run.cancel)
                default:
                    if let progress = run.lastProgress, run.trajectory != nil {
                        instruments(progress)
                    }
                    controls
                }

                if case .failed(let message) = run.stage {
                    Text(message)
                        .font(HUDTypography.body(12))
                        .foregroundStyle(HUDPalette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let prior = run.prior {
                    Text("Flexibility prior: \(prior.blend.caption)")
                        .font(HUDTypography.readoutSmall(10))
                        .foregroundStyle(HUDPalette.muted)
                }
                timescaleNote
            }
        }
    }

    // MARK: - Lamps

    private var lamps: some View {
        HStack(spacing: 6) {
            // The Neural Engine lamp reports what Core ML PLANNED, and says so.
            // Ground rule 2 asks for this to be verified rather than claimed,
            // and a compute plan is not a measurement of execution.
            HUDLamp(
                role: run.computePlan.isPredominantlyNeuralEngine ? .nominal
                    : (run.computePlan.isUnavailable ? .inactive : .caution),
                text: run.computePlan.caption)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Live instruments

    private func instruments(_ progress: RunProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                // Acceptance ratio as engine RPM, per the design system's
                // instrument language.
                // "Acceptance" wraps to two lines inside an 84 point dial and
                // reads as "ACCEPTANC / E". The gauge is labelled by what it
                // measures, not by the longest word for it.
                DialGauge(
                    label: "Accept", value: Double(progress.acceptanceRatio * 100),
                    scale: GaugeScale(lower: 0, upper: 100), unit: "%",
                    colour: (0.20...0.60).contains(Double(progress.acceptanceRatio))
                        ? HUDPalette.primary : HUDPalette.accent)
                .frame(width: 84)
                DialGauge(
                    label: "Sweep/s", value: Double(progress.sweepsPerSecond),
                    scale: GaugeScale(lower: 0, upper: 200))
                .frame(width: 84)
                Spacer(minLength: 0)
            }
            // RMSD as an altimeter tape: it starts at zero and has no natural
            // ceiling, which is exactly what a tape is for.
            TapeGauge(
                label: "RMSD from start", value: Double(progress.rmsdFromStart),
                scale: GaugeScale(lower: 0, upper: 5), unit: "A")
            HStack {
                HUDReadout(
                    label: "Sweep", value: HUDFormat.count(progress.sweep), size: 18)
                Spacer()
                HUDReadout(
                    label: "Energy", value: HUDFormat.fixed(Double(progress.energy.total), decimals: 0),
                    size: 18)
            }
            HUDProgressBar(
                caption: "Progress", fraction: progress.fraction)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Sweeps").hudLabelStyle()
                    Spacer()
                    Text(HUDFormat.count(model.run.configuration.sweeps))
                        .font(HUDTypography.readoutSmall(12))
                        .foregroundStyle(HUDPalette.primary)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.run.configuration.sweeps) },
                        set: { model.run.configuration.sweeps = Int($0) }),
                    in: 200...20_000, step: 200)
                .tint(HUDPalette.primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Throttle (kT)").hudLabelStyle()
                    Spacer()
                    Text(HUDFormat.fixed(Double(model.run.configuration.temperature), decimals: 2))
                        .font(HUDTypography.readoutSmall(12))
                        .foregroundStyle(HUDPalette.accent)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.run.configuration.temperature) },
                        set: { model.run.configuration.temperature = Float($0) }),
                    in: 0.2...4.0, step: 0.05)
                .tint(HUDPalette.accent)
            }

            HUDActionButton(
                "Run", systemImage: "flame.fill",
                isEnabled: model.structure != nil && !run.stage.isBusy,
                action: model.launchEngines)
        }
    }

    // MARK: - Honesty

    /// Ground rule 3, stated where the numbers are, not buried in an About
    /// screen. Frames are Monte Carlo sweeps and not femtoseconds, and the
    /// interface says so wherever a rate appears.
    private var timescaleNote: some View {
        Text(
            "Sweeps are pseudo-time, not picoseconds. This is a crude on-device "
                + "sampler: rates and dwell times are reported in sweeps."
        )
        .font(HUDTypography.readoutSmall(10))
        .foregroundStyle(HUDPalette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
}

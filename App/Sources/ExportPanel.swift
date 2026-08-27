import JumpjetAnalysis
import JumpjetCore
import JumpjetHUD
import JumpjetMovie
import JumpjetViewer
import SwiftUI

/// Movie and report-card export: the shareable payoff.
struct ExportPanel: View {
    @Bindable var model: AppModel

    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var movieURL: URL?
    @State private var cardURL: URL?
    @State private var failure: String?
    @State private var preset: MoviePreset = .landscape1080
    @State private var burnsInHUD = true
    @State private var orbits = true

    private var run: RunCoordinator { model.run }

    var body: some View {
        HUDPanel("Export", trailing: durationCaption) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Size", selection: $preset) {
                    ForEach(MoviePreset.allCases) { option in
                        Text(option.name).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isExporting)

                Toggle(isOn: $burnsInHUD) {
                    Text("Burn in the HUD").font(HUDTypography.body(13))
                }
                .toggleStyle(.switch)
                .tint(HUDPalette.primary)
                .disabled(isExporting)

                Toggle(isOn: $orbits) {
                    Text("Slow orbit").font(HUDTypography.body(13))
                }
                .toggleStyle(.switch)
                .tint(HUDPalette.primary)
                .disabled(isExporting)

                if isExporting {
                    HUDProgressBar(caption: "RENDERING", fraction: progress)
                } else {
                    HUDActionButton(
                        "Export movie", systemImage: "film.fill",
                        isEnabled: run.trajectory != nil, action: exportMovie)
                }

                if let movieURL {
                    ShareLink(item: movieURL) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share the movie").font(HUDTypography.body(13))
                        }
                        .foregroundStyle(HUDPalette.primary)
                    }
                }

                Button(action: exportCard) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.richtext")
                        Text("Sortie report card").font(HUDTypography.body(13))
                    }
                    .foregroundStyle(HUDPalette.primary)
                }
                .buttonStyle(.plain)
                .disabled(run.record == nil)

                if let cardURL {
                    ShareLink(item: cardURL) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share the card").font(HUDTypography.body(13))
                        }
                        .foregroundStyle(HUDPalette.primary)
                    }
                }

                if let failure {
                    Text(failure)
                        .font(HUDTypography.body(12))
                        .foregroundStyle(HUDPalette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var durationCaption: String {
        guard let trajectory = run.trajectory else { return "NO TRAJECTORY" }
        var options = MovieOptions()
        options.preset = preset
        let seconds = options.duration(trajectoryFrames: trajectory.frameCount)
        return String(format: "%.1f S · %d FRAMES", seconds, trajectory.frameCount)
    }

    // MARK: - Actions

    private func exportMovie() {
        guard let loaded = model.status.model, let trajectory = run.trajectory else { return }
        failure = nil
        movieURL = nil
        isExporting = true
        progress = 0

        var options = MovieOptions()
        options.preset = preset
        options.burnsInHUD = burnsInHUD
        options.orbits = orbits

        let frames = (0..<trajectory.frameCount).map { Array(trajectory.frame($0)) }
        let caption = MovieExporter.Caption(
            accession: loaded.accession.value,
            title: loaded.entry?.proteinName ?? loaded.structure.title,
            sweeps: trajectory.sweeps,
            rmsd: run.record?.rmsd.values ?? [])
        let viewerOptions = model.options
        let flexibility = run.flexibilityValues
        let structure = loaded.structure
        let destination = MovieExporter.temporaryURL(accession: loaded.accession.value)

        Task {
            do {
                let url = try await MovieExporter().export(
                    structure: structure, frames: frames, viewerOptions: viewerOptions,
                    flexibility: flexibility, options: options, caption: caption,
                    to: destination,
                    progress: { value in
                        Task { @MainActor in progress = value }
                    })
                movieURL = url
            } catch {
                failure = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            isExporting = false
        }
    }

    /// The card is rendered by `ImageRenderer` at a fixed size, so a card made
    /// on a phone and one made on an iPad are the same picture.
    @MainActor
    private func exportCard() {
        guard let loaded = model.status.model, let record = run.record else { return }
        failure = nil

        let summary = run.prior.map {
            SortieReportCard.FlexibilitySummary(blend: $0.blend.caption, mean: $0.mean)
        }
        let card = SortieReportCard(model: loaded, record: record, prior: summary)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(SortieReportCard.size)

        guard let image = renderer.uiImage, let data = image.pngData() else {
            failure = "The report card could not be rendered."
            return
        }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("JUMPjet/Movies", isDirectory: true)
            .appendingPathComponent("JUMPjet-\(loaded.accession.value)-report.png")
        guard let url else {
            failure = "Nowhere to write the report card."
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
            cardURL = url
        } catch {
            failure = error.localizedDescription
        }
    }
}

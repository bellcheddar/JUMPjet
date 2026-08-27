import Foundation
import JumpjetCore
import JumpjetAnalysis
import JumpjetEngine
import JumpjetFetch
import JumpjetNeural
import JumpjetViewer
import Observation

/// The app's single piece of state.
///
/// Main-actor isolated in full: everything it holds ends up in a SwiftUI view,
/// and the alternative is a scattering of hops that each have to be right.
@MainActor
@Observable
final class AppModel {

    /// What the airframe is doing.
    enum Status {
        case idle
        case loading(LoadPhase)
        case loaded(LoadedModel)
        case failed(JumpjetError)

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }

        var model: LoadedModel? {
            if case .loaded(let model) = self { return model }
            return nil
        }
    }

    var accessionText = ""
    private(set) var status: Status = .idle
    var options = ViewerOptions()
    /// The chain the viewer is framed on. `nil` means every chain.
    var focusedChain: Int?
    private(set) var recentAccessions: [String] = []
    /// Phase 2's engines. Owned here so a new structure resets them: a prior
    /// and a trajectory belong to the protein they were computed for.
    let run = RunCoordinator()

    private let service: StructureService
    private let defaults: UserDefaults
    private var loadTask: Task<Void, Never>?

    private static let recentsKey = "jumpjet.recentAccessions"
    private static let recentsLimit = 8

    init(service: StructureService = StructureService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.recentAccessions = defaults.stringArray(forKey: Self.recentsKey) ?? []
    }

    /// Whether the entry field currently holds something worth sending.
    var canLaunch: Bool {
        Accession.isValid(accessionText) && !status.isLoading
    }

    var structure: Structure? { status.model?.structure }

    /// Colour modes that say something about the structure in hand.
    ///
    /// Flexibility becomes available only once the neural prior has actually
    /// been computed. Offering it before then would give the user a colour
    /// scale with nothing behind it.
    var availableColourModes: [ColourMode] {
        guard let structure else { return [.chainbow] }
        return ColourMode.allCases.filter {
            if $0 == .flexibility { return run.flexibilityValues != nil }
            return $0.isAvailable(for: structure)
        }
    }

    /// Start a run on the currently loaded structure.
    func launchEngines() {
        guard let model = status.model else { return }
        run.run(structure: model.structure, chainIndex: focusedChain)
    }

    func load() {
        loadTask?.cancel()
        let text = accessionText
        loadTask = Task { [weak self] in
            await self?.performLoad(text)
        }
    }

    func load(_ accession: String) {
        accessionText = accession
        load()
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        status = .idle
    }

    private func performLoad(_ text: String) async {
        status = .loading(.validating)
        do {
            let model = try await service.load(text) { [weak self] phase in
                // The service reports progress from whatever context it is on,
                // so the hop to the main actor happens here rather than being
                // assumed.
                Task { @MainActor [weak self] in
                    guard let self, self.status.isLoading else { return }
                    self.status = .loading(phase)
                }
            }
            guard !Task.isCancelled else { return }
            apply(model)
        } catch let error as JumpjetError {
            guard !Task.isCancelled else { return }
            status = .failed(error)
        } catch {
            guard !Task.isCancelled else { return }
            status = .failed(.parseFailure(reason: error.localizedDescription))
        }
    }

    private func apply(_ model: LoadedModel) {
        status = .loaded(model)
        run.reset()
        accessionText = model.accession.value

        // Open on the longest chain, as the build plan asks, with the rest
        // reachable through the picker. Drawing all four chains of a
        // haemoglobin by default buries the one the accession actually names.
        let longest = model.structure.longestChainIndex
        focusedChain = model.structure.chains.count > 1 ? longest : nil
        options.visibleChains = focusedChain.map { [$0] } ?? []

        // A prediction defaults to its confidence colouring, because that is
        // the first question anyone asks of a predicted structure. An
        // experimental entry has no confidence to show, so it opens chainbow.
        options.colourMode = model.structure.source == .alphaFold ? .confidence : .chainbow
        options.showsSideChains = false

        remember(model.accession.value)
    }

    private func remember(_ accession: String) {
        var recents = recentAccessions.filter { $0 != accession }
        recents.insert(accession, at: 0)
        recents = Array(recents.prefix(Self.recentsLimit))
        recentAccessions = recents
        defaults.set(recents, forKey: Self.recentsKey)
    }

    // MARK: - Flight recorder

    /// Act on a tap in the flight recorder.
    ///
    /// Build plan, Phase 3 item 6: tapping an analysis element takes the viewer
    /// to that residue or frame. A table of jump-happy residues that points at
    /// nothing is a table nobody can act on.
    func select(_ selection: AnalysisSelection) {
        switch selection {
        case .residue(let index):
            // Toggle, and replace rather than accumulate. Highlighting that can
            // only be added ends with the whole protein amber and nothing
            // distinguishable in it.
            if options.highlightedResidues.contains(index) {
                options.highlightedResidues.remove(index)
            } else {
                options.highlightedResidues = [index]
            }
        case .frame(let index):
            run.show(frame: index)
        }
    }

    // MARK: - Chain selection

    func focus(chain index: Int?) {
        focusedChain = index
        options.visibleChains = index.map { [$0] } ?? []
    }

    /// A label for a chain in the picker: identifier, length and sequence start,
    /// which is enough to tell two copies of the same protein apart.
    func chainLabel(_ index: Int) -> String {
        guard let structure, structure.chains.indices.contains(index) else { return "—" }
        let chain = structure.chains[index]
        return "\(chain.id) · \(chain.residueCount) aa"
    }
}

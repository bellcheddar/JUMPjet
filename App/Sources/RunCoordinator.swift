import Foundation
import JumpjetCore
import JumpjetEngine
import JumpjetNeural
import Observation

/// Owns the Phase 2 engines: the neural flexibility prior and the sampler.
///
/// The order is the build plan's, and it is not arbitrary. The prior is
/// computed FIRST because it parameterises the physics: spring constants are
/// scaled down by it and move amplitudes scaled up by it, so a run started
/// before the prior arrives would be a different run.
/// A one-way cancellation flag, readable from the sampler's own thread.
///
/// This exists because the obvious version crashed the app. The sampler's
/// progress callback runs on a cooperative-pool thread, and reading a
/// main-actor property from there through `MainActor.assumeIsolated` is not a
/// borrow, it is an ASSERTION: `dispatch_assert_queue` fails and the process
/// traps. Nothing in the host test suite could catch it, because the tests call
/// the sampler directly and never cross an actor at all.
///
/// A lock rather than an actor because the reader is a synchronous callback
/// that cannot await, and rather than a bare `Bool` because a data race is
/// undefined behaviour even when the value only ever goes one way.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        flag = false
        lock.unlock()
    }
}

@MainActor
@Observable
final class RunCoordinator {

    enum Stage: Equatable {
        case idle
        case loadingModel
        case embedding
        case sampling(RunProgress)
        case finished(sweeps: Int, seconds: Double)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .loadingModel, .embedding, .sampling: true
            default: false
            }
        }

        var caption: String {
            switch self {
            case .idle: "ENGINES IDLE"
            case .loadingModel: "SPOOLING UP"
            case .embedding: "NEURAL PRIOR"
            case .sampling(let progress):
                "SWEEP \(progress.sweep) OF \(progress.totalSweeps)"
            case .finished(let sweeps, _): "\(sweeps) SWEEPS COMPLETE"
            case .failed: "ENGINE FAULT"
            }
        }
    }

    private(set) var stage: Stage = .idle
    private(set) var prior: FlexibilityPrior?
    private(set) var trajectory: Trajectory?
    private(set) var computePlan: ComputePlanReport = .unavailable
    private(set) var lastProgress: RunProgress?
    /// The structure as the sampler currently has it, republished as frames
    /// arrive. Phase 2's whole point is to press RUN and watch the protein
    /// breathe, so the viewer follows this rather than the starting model.
    private(set) var liveStructure: Structure?
    /// Bumped on every published frame. The viewer keys its geometry rebuild on
    /// this: an identifier and an atom count are identical between frames, so
    /// without a counter nothing would ever redraw.
    private(set) var frameVersion = 0

    var configuration = RunConfiguration()

    private var embedder: ESMEmbedder?
    private var tables: TorsionTables?
    private var task: Task<Void, Never>?
    private let stopFlag = StopFlag()

    /// The prior as the viewer wants it: one value per residue, 0 to 1.
    var flexibilityValues: [Float]? { prior?.values }

    // MARK: - Loading

    /// Load the bundled model and tables once, off the main actor.
    private func loadEngines() throws -> (ESMEmbedder, TorsionTables) {
        if let embedder, let tables { return (embedder, tables) }
        let resources = try ESMEmbedder.Resources.inBundle()
        let loaded = try ESMEmbedder(resources: resources)
        guard let url = Bundle.main.url(forResource: "torsion_tables", withExtension: "json")
        else {
            throw JumpjetError.parseFailure(
                reason: "torsion_tables.json is missing from the app bundle")
        }
        let loadedTables = try TorsionTables.load(from: url)
        embedder = loaded
        tables = loadedTables
        return (loaded, loadedTables)
    }

    /// The prior for a whole structure, computed one CHAIN at a time.
    ///
    /// Chains are separate molecules and ESM-2 is a sequence model: handing it
    /// two chains joined end to end would invent a peptide bond that is not
    /// there and give every residue near the join a context it does not have.
    /// Smoothing is per chain for the same reason, so a rigid N-terminus cannot
    /// stiffen the C-terminus of the chain before it.
    nonisolated static func prior(
        for structure: Structure, using embedder: ESMEmbedder
    ) throws -> FlexibilityPrior {
        let perResiduePLDDT = structure.perResiduePLDDT
        let hasConfidence = structure.source == .alphaFold
        var values: [Float] = []
        values.reserveCapacity(structure.residueCount)
        var blend: FlexibilityPrior.Blend = .embeddingOnly

        for chainIndex in structure.chains.indices {
            let range = structure.chains[chainIndex].residueRange
            let sequence = structure.sequence(ofChain: chainIndex)
            let confidence = hasConfidence ? Array(perResiduePLDDT[range]) : nil
            let chainPrior = try embedder.flexibilityPrior(
                sequence: sequence, plddt: confidence)
            values.append(contentsOf: chainPrior.values)
            blend = chainPrior.blend
        }
        return FlexibilityPrior(values: values, blend: blend)
    }

    // MARK: - Running

    func run(structure: Structure, chainIndex: Int?) {
        cancel()
        liveStructure = nil
        frameVersion = 0
        stopFlag.reset()
        let configuration = configuration

        baseStructure = structure
        task = Task { [weak self] in
            guard let self else { return }
            do {
                self.stage = .loadingModel
                let (embedder, tables) = try self.loadEngines()

                // The compute plan is a background curiosity, not a gate: the
                // run proceeds whatever it says, and the HUD reports it.
                let modelURL = try ESMEmbedder.Resources.inBundle().modelURL
                Task { [weak self] in
                    let report = await ComputePlanReport.plan(for: modelURL)
                    await MainActor.run { self?.computePlan = report }
                }

                self.stage = .embedding
                let prior = try await Task.detached(priority: .userInitiated) {
                    try Self.prior(for: structure, using: embedder)
                }.value
                guard !Task.isCancelled else { return }
                self.prior = prior

                // The sampler needs one value per residue of the STRUCTURE.
                // Checked rather than assumed: an off-by-one here would shift
                // every spring constant onto its neighbour and still run.
                guard prior.values.count == structure.residueCount else {
                    throw JumpjetError.parseFailure(
                        reason: "the prior has \(prior.values.count) values for a structure "
                            + "of \(structure.residueCount) residues")
                }

                self.stage = .sampling(
                    RunProgress(
                        sweep: 0, totalSweeps: configuration.sweeps, acceptanceRatio: 0,
                        energy: Energy(), rmsdFromStart: 0, sweepsPerSecond: 0))

                let started = Date()
                let values = prior.values
                let stopFlag = self.stopFlag
                let trajectory = await Task.detached(priority: .userInitiated) {
                    [weak self] () -> Trajectory in
                    let sampler = MonteCarloSampler(
                        structure: structure, flexibility: values, tables: tables,
                        configuration: configuration, chainIndex: chainIndex)
                    return sampler.run { progress in
                        // The sampler calls this every sweep from its own
                        // thread. Hopping to the main actor per sweep would
                        // make the UI the bottleneck at 130 sweeps a second, so
                        // it is throttled to roughly ten updates a second.
                        Task { @MainActor [weak self] in
                            self?.publish(progress)
                        }
                        return !stopFlag.isSet
                    }
                }.value

                guard !Task.isCancelled else { return }
                self.trajectory = trajectory
                self.stage = .finished(
                    sweeps: trajectory.sweeps.last ?? 0,
                    seconds: Date().timeIntervalSince(started))
            } catch let error as JumpjetError {
                self.stage = .failed(error.message)
            } catch {
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    private var lastPublished = Date.distantPast

    private func publish(_ progress: RunProgress) {
        let now = Date()
        let isLast = progress.sweep >= progress.totalSweeps
        guard isLast || now.timeIntervalSince(lastPublished) > 0.1 else { return }
        lastPublished = now
        lastProgress = progress
        if case .sampling = stage { stage = .sampling(progress) }

        if let snapshot = progress.snapshot, var structure = baseStructure,
            snapshot.count == structure.atomCount
        {
            structure.setPositions(snapshot)
            liveStructure = structure
            frameVersion += 1
        }
    }

    private var baseStructure: Structure?

    func cancel() {
        stopFlag.set()
        task?.cancel()
        task = nil
        if stage.isBusy { stage = .idle }
    }

    func reset() {
        cancel()
        prior = nil
        trajectory = nil
        lastProgress = nil
        stage = .idle
    }
}

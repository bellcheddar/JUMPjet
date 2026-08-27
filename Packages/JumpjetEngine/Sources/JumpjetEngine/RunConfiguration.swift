import Foundation
import JumpjetCore

/// The controls the HUD exposes for a run.
public struct RunConfiguration: Sendable, Hashable, Codable {
    /// Monte Carlo sweeps. One sweep is one attempted move per residue, which
    /// is the definition every rate in the app is quoted against.
    public var sweeps: Int
    /// The throttle. kT in the Metropolis criterion, in the same arbitrary
    /// energy units the force field uses. Higher means more accepted moves and
    /// a wilder trajectory.
    public var temperature: Float
    /// Store a frame every this many sweeps.
    public var snapshotStride: Int
    /// The seed. Two runs with the same seed and the same structure must
    /// produce byte-identical trajectories, which is what makes a reported jump
    /// reproducible rather than an anecdote.
    public var seed: UInt64
    /// Rebuild the neighbour grid every this many sweeps.
    public var gridRebuildInterval: Int

    public init(
        sweeps: Int = Limits.defaultSweeps,
        temperature: Float = 1.0,
        snapshotStride: Int = 25,
        seed: UInt64 = 0x4A_55_4D_50,  // "JUMP"
        gridRebuildInterval: Int = 10
    ) {
        self.sweeps = sweeps
        self.temperature = temperature
        self.snapshotStride = snapshotStride
        self.seed = seed
        self.gridRebuildInterval = gridRebuildInterval
    }

    public var snapshotCount: Int { sweeps / max(1, snapshotStride) + 1 }
}

/// How the move set is divided up.
///
/// Side-chain moves dominate deliberately. They are local, so their cost is a
/// residue's worth of atoms; a backbone move rotates everything on one side of
/// the bond, so it costs a fraction of the whole protein. Discrete rotamer and
/// ring-flip proposals are what make the app's own subject matter reachable:
/// a Gaussian perturbation small enough to be accepted will essentially never
/// cross a 120 degree barrier on its own.
public struct MoveMix: Sendable, Hashable, Codable {
    public var sideChainPerturbation: Float
    public var rotamerJump: Float
    public var ringFlip: Float
    public var backbonePerturbation: Float

    /// The shipping mix, chosen by measurement at EQUAL WALL CLOCK on a
    /// 335-residue protein over three seeds.
    ///
    /// Backbone was 22% and is now 3%, which is what takes the sampler from
    /// 22.4 sweeps per second to 124.2 and meets the build plan's target of 100
    /// at 300 residues. The trade, stated rather than buried: in a fixed eight
    /// seconds the new mix does 5.5 times as many side-chain moves and about a
    /// quarter fewer backbone ones (9,990 against 13,266), and mid-chain
    /// backbone coverage falls from 60.4% to 53.1%.
    ///
    /// That is the right way round for this app. Rotamer jumps and ring flips
    /// are its subject, and they are side-chain events; the backbone still gets
    /// nearly as many proposals per second as before because the sweeps are so
    /// much cheaper.
    ///
    /// Worth knowing: 11% is strictly better than the original 22% on every
    /// axis measured (1.9x the throughput, MORE coverage, more displacement), so
    /// the original number was not a considered trade-off, it was too high.
    public init(
        sideChainPerturbation: Float = 0.622,
        rotamerJump: Float = 0.274,
        ringFlip: Float = 0.074,
        backbonePerturbation: Float = 0.03
    ) {
        self.sideChainPerturbation = sideChainPerturbation
        self.rotamerJump = rotamerJump
        self.ringFlip = ringFlip
        self.backbonePerturbation = backbonePerturbation
    }

    var total: Float {
        sideChainPerturbation + rotamerJump + ringFlip + backbonePerturbation
    }
}

/// Move amplitudes, in degrees of standard deviation.
///
/// These set the acceptance ratio, which the build plan's definition of done
/// puts between 20 and 60 per cent at the default throttle. Too small and the
/// sampler accepts almost everything and explores almost nothing; too large and
/// it rejects almost everything and explores almost nothing. The values here
/// were calibrated by measurement, not chosen.
///
/// Each is a base plus a term scaled by the residue's flexibility prior, which
/// is the build plan's coupling between the neural layer and the physics: a
/// residue the prior calls rigid gets small nudges and a floppy loop gets large
/// ones.
public struct MoveAmplitudes: Sendable, Hashable, Codable {
    /// How strongly backbone torsion selection is biased towards CHEAP
    /// torsions, as the exponent in `weight = 1 / count^exponent`.
    ///
    /// A pivot rotates everything on the smaller side of its bond, so its cost
    /// ranges from a handful of atoms near a terminus to a quarter of the
    /// protein in the middle: 1 to 1,267 atoms on a 335-residue structure. With
    /// uniform selection the expensive ones dominate the wall clock while
    /// contributing no more sampling than the cheap ones.
    ///
    /// **This does not break detailed balance.** The proposal is its own
    /// reverse (the same torsion rotated by the opposite amount), and the
    /// selection probability is FIXED rather than state-dependent, so the
    /// forward and reverse proposal densities are equal and the Metropolis
    /// criterion is unchanged. The equilibrium ensemble is identical; what
    /// changes is how often each torsion is visited, and sweeps are pseudo-time
    /// already.
    ///
    /// **Default 0: measured, and not worth it.** The mechanism works and is
    /// fast (bias 1.0 gives 155 sweeps per second against 73), and it buys that
    /// speed by genuinely starving the chain: at equal wall clock, mid-chain
    /// torsion coverage falls from 55.4% to 35.6%. Reducing the backbone SHARE
    /// gets the same throughput for a fraction of that cost, so it does.
    ///
    /// The trap worth remembering is why this looked fine at first. Mean
    /// alpha-carbon displacement barely moved (ratio 0.79 against 0.82),
    /// because a mid-chain pivot shifts hundreds of atoms whenever it lands: a
    /// starved torsion and a well-sampled one produce the same displacement.
    /// Counting accepted moves is what showed it.
    ///
    /// Left in, defaulted off, because it is the right lever if throughput ever
    /// has to be bought again and coverage can be given up knowingly.
    public var backboneCostBias: Float = 0

    public var sideChainBase: Float
    public var sideChainFlexible: Float
    /// The jitter added to a well-to-well rotamer proposal, so it lands near
    /// the well rather than exactly on it.
    public var rotamerJitter: Float
    /// Backbone amplitudes are far smaller. A phi rotation swings everything on
    /// one side of the bond, so a degree at the pivot is angstroms at the far
    /// end of the lever.
    public var backboneBase: Float
    public var backboneFlexible: Float

    public init(
        sideChainBase: Float = 12,
        sideChainFlexible: Float = 60,
        rotamerJitter: Float = 10,
        backboneBase: Float = 1.8,
        backboneFlexible: Float = 9.0,
        backboneCostBias: Float = 0
    ) {
        self.backboneCostBias = backboneCostBias
        self.sideChainBase = sideChainBase
        self.sideChainFlexible = sideChainFlexible
        self.rotamerJitter = rotamerJitter
        self.backboneBase = backboneBase
        self.backboneFlexible = backboneFlexible
    }

    func sideChain(flexibility: Float) -> Float {
        sideChainBase + sideChainFlexible * flexibility
    }

    func backbone(flexibility: Float) -> Float {
        backboneBase + backboneFlexible * flexibility
    }
}

/// A deterministic random source.
///
/// `SystemRandomNumberGenerator` cannot be seeded, so a run using it is not
/// reproducible, and the build plan's definition of done asks for replay from a
/// seed. This is SplitMix64: small, fast, and passes the statistical tests that
/// matter for a Metropolis criterion.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        // A zero seed makes SplitMix64 start from a fixed point that is
        // correlated with its own output. Salt it.
        self.state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform float in [0, 1).
    public mutating func uniform() -> Float {
        Float(next() >> 40) * (1.0 / 16_777_216.0)
    }

    /// A standard normal, by Box-Muller. One value per call; the second is
    /// discarded rather than cached, because caching it makes the generator's
    /// output depend on how many normals were drawn before it and quietly
    /// breaks reproducibility when the move mix changes.
    public mutating func normal() -> Float {
        let u1 = max(uniform(), 1e-7)
        let u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    public mutating func index(below limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        return Int(next() % UInt64(limit))
    }
}

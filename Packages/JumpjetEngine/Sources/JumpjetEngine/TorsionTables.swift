import Foundation
import JumpjetCore

/// The backbone and side-chain torsion statistics the sampler biases against.
///
/// Binned energies in kT, derived by `Tools/coreml/compute_torsion_tables.py`
/// from AlphaFold DB models. Coarser than a real rotamer library and
/// deliberately so: this one can be redistributed inside an app bundle.
public struct TorsionTables: Sendable {
    public let backboneBins: Int
    public let chiBins: Int
    public let maximumEnergy: Float

    /// Row-major `[phiBin][psiBin]`, flattened.
    private let general: [Float]
    private let glycine: [Float]
    private let proline: [Float]
    private let chi1: [String: [Float]]
    private let chi2: [String: [Float]]

    public init(
        backboneBins: Int, chiBins: Int, maximumEnergy: Float,
        general: [Float], glycine: [Float], proline: [Float],
        chi1: [String: [Float]], chi2: [String: [Float]]
    ) {
        self.backboneBins = backboneBins
        self.chiBins = chiBins
        self.maximumEnergy = maximumEnergy
        self.general = general
        self.glycine = glycine
        self.proline = proline
        self.chi1 = chi1
        self.chi2 = chi2
    }

    private struct Payload: Decodable {
        let backboneBins: Int
        let chiBins: Int
        let maximumEnergy: Float
        let backbone: [String: [[Float]]]
        let chi1: [String: [Float]]
        let chi2: [String: [Float]]

        enum CodingKeys: String, CodingKey {
            case backboneBins = "backbone_bins"
            case chiBins = "chi_bins"
            case maximumEnergy = "maximum_energy"
            case backbone, chi1, chi2
        }
    }

    public static func load(from url: URL) throws -> TorsionTables {
        let payload = try JSONDecoder().decode(Payload.self, from: try Data(contentsOf: url))

        func flatten(_ name: String) throws -> [Float] {
            guard let rows = payload.backbone[name] else {
                throw JumpjetError.parseFailure(
                    reason: "torsion tables are missing the \(name) backbone table")
            }
            guard rows.count == payload.backboneBins,
                rows.allSatisfy({ $0.count == payload.backboneBins })
            else {
                throw JumpjetError.parseFailure(
                    reason: "the \(name) backbone table is not "
                        + "\(payload.backboneBins) by \(payload.backboneBins)")
            }
            return rows.flatMap { $0 }
        }

        return TorsionTables(
            backboneBins: payload.backboneBins, chiBins: payload.chiBins,
            maximumEnergy: payload.maximumEnergy,
            general: try flatten("general"), glycine: try flatten("glycine"),
            proline: try flatten("proline"), chi1: payload.chi1, chi2: payload.chi2)
    }

    /// A flat table, for tests and for the case where the bundle has none.
    /// Explicitly zero rather than a guess, so a missing file shows up as a
    /// sampler with no torsional bias rather than as a plausible wrong one.
    public static func flat(backboneBins: Int = 24, chiBins: Int = 36) -> TorsionTables {
        TorsionTables(
            backboneBins: backboneBins, chiBins: chiBins, maximumEnergy: 0,
            general: [Float](repeating: 0, count: backboneBins * backboneBins),
            glycine: [Float](repeating: 0, count: backboneBins * backboneBins),
            proline: [Float](repeating: 0, count: backboneBins * backboneBins),
            chi1: [:], chi2: [:])
    }

    /// Wrap an angle in degrees onto `[0, bins)`.
    ///
    /// The wrap is the whole point: -180 and +180 are the same angle, and a
    /// table indexed without it puts a discontinuity in the middle of the
    /// extended backbone region.
    static func bin(_ degrees: Float, bins: Int) -> Int {
        let width = 360 / Float(bins)
        var shifted = (degrees + 180).truncatingRemainder(dividingBy: 360)
        if shifted < 0 { shifted += 360 }
        return min(bins - 1, Int(shifted / width))
    }

    public func backboneEnergy(phi: Float, psi: Float, residue: AminoAcid) -> Float {
        let table: [Float]
        switch residue {
        case .glycine: table = glycine
        case .proline: table = proline
        default: table = general
        }
        let phiBin = Self.bin(phi, bins: backboneBins)
        let psiBin = Self.bin(psi, bins: backboneBins)
        return table[phiBin * backboneBins + psiBin]
    }

    /// Chi energy, or zero when the residue has no table.
    ///
    /// Zero rather than a penalty: an unlisted residue is one there were too
    /// few of to make a table from, and inventing a bias for it would be worse
    /// than having none.
    public func chiEnergy(_ degrees: Float, chiIndex: Int, residue: AminoAcid) -> Float {
        let table: [Float]?
        switch chiIndex {
        case 0: table = chi1[residue.rawValue]
        case 1: table = chi2[residue.rawValue]
        default: return 0
        }
        guard let table, !table.isEmpty else { return 0 }
        return table[Self.bin(degrees, bins: table.count)]
    }

    public var hasData: Bool { maximumEnergy > 0 }
}

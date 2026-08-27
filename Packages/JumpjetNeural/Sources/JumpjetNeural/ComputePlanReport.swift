import CoreML
import Foundation

/// Where the model's operations are planned to run.
///
/// Build plan ground rule 2 asks for an "ANE ✓" indicator when the compiled
/// plan maps to the Neural Engine and "GPU/CPU fallback" otherwise, with the
/// explicit instruction not to claim it without checking. This is the check.
///
/// **It is a PLAN, not a measurement of execution.** `MLComputePlan` answers
/// "can these operations run on the Neural Engine", which is the structural
/// question the app's premise depends on. It does not answer "how fast will
/// they", and a configuration reporting 99% residency can still run slower
/// than one reporting less. The HUD wording says "planned" for that reason.
public struct ComputePlanReport: Sendable, Hashable {
    public let totalOperations: Int
    public let neuralEngineOperations: Int
    public let cpuOperations: Int
    public let gpuOperations: Int
    /// True when the plan could not be obtained at all, on an OS too old to
    /// have `MLComputePlan`. Distinguished from a genuine zero: "we did not
    /// look" and "it does not use the Neural Engine" are different answers and
    /// the HUD must not conflate them.
    public let isUnavailable: Bool

    public init(
        totalOperations: Int, neuralEngineOperations: Int, cpuOperations: Int,
        gpuOperations: Int, isUnavailable: Bool = false
    ) {
        self.totalOperations = totalOperations
        self.neuralEngineOperations = neuralEngineOperations
        self.cpuOperations = cpuOperations
        self.gpuOperations = gpuOperations
        self.isUnavailable = isUnavailable
    }

    public static let unavailable = ComputePlanReport(
        totalOperations: 0, neuralEngineOperations: 0, cpuOperations: 0,
        gpuOperations: 0, isUnavailable: true)

    public var neuralEngineFraction: Double {
        guard totalOperations > 0 else { return 0 }
        return Double(neuralEngineOperations) / Double(totalOperations)
    }

    /// What the HUD shows. Never claims more than was established.
    public var caption: String {
        if isUnavailable { return "ANE residency not checked" }
        guard totalOperations > 0 else { return "ANE residency unknown" }
        let percent = Int((neuralEngineFraction * 100).rounded())
        if neuralEngineFraction >= 0.9 { return "ANE \(percent)% planned" }
        if neuralEngineFraction > 0 { return "GPU/CPU fallback, ANE \(percent)% planned" }
        return "GPU/CPU fallback"
    }

    public var isPredominantlyNeuralEngine: Bool {
        !isUnavailable && neuralEngineFraction >= 0.9
    }

    /// Ask Core ML where it plans to run each operation.
    ///
    /// Returns ``unavailable`` rather than throwing when the API is missing, so
    /// the app degrades to "not checked" on iOS 17.0 to 17.3 instead of failing
    /// to produce a prior at all.
    public static func plan(for url: URL) async -> ComputePlanReport {
        guard #available(iOS 17.4, macOS 14.4, *) else { return .unavailable }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard
            let plan = try? await MLComputePlan.load(
                contentsOf: url, configuration: configuration),
            case let .program(program) = plan.modelStructure,
            let function = program.functions["main"]
        else { return .unavailable }

        var total = 0
        var neuralEngine = 0
        var cpu = 0
        var gpu = 0
        for operation in function.block.operations {
            guard let assignment = plan.deviceUsage(for: operation) else { continue }
            total += 1
            // `MLComputeDevice` is an ENUM with associated values, not a class
            // hierarchy. Written as `case is MLNeuralEngineComputeDevice` it
            // compiles, matches nothing, and reports 391 operations of which
            // zero are on any device: a report that looks like a measurement
            // and is an empty one.
            switch assignment.preferred {
            case .neuralEngine: neuralEngine += 1
            case .gpu: gpu += 1
            case .cpu: cpu += 1
            @unknown default: break
            }
        }
        return ComputePlanReport(
            totalOperations: total, neuralEngineOperations: neuralEngine,
            cpuOperations: cpu, gpuOperations: gpu)
    }
}

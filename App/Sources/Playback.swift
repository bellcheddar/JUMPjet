import Foundation
import JumpjetAnalysis
import JumpjetCore
import JumpjetEngine
import simd

/// Trajectory playback: the scrubber, the transport controls and the ghost
/// trail.
///
/// Lives on `RunCoordinator` because that is what owns the trajectory. A
/// separate controller would need a reference to it anyway, and two objects
/// holding a mutable frame index between them is how a scrubber and a play
/// timer end up fighting.
@MainActor
extension RunCoordinator {

    /// Frames the ghost trail may draw. Four is enough to read a direction and
    /// few enough that rebuilding them at thirty frames a second is affordable.
    static let maximumGhosts = 4

    var frameCount: Int { trajectory?.frameCount ?? 0 }

    var canPlay: Bool { frameCount > 1 }

    /// The sweeps each frame was taken at, for the scrubber's tick marks.
    var frameSweeps: [Int] { trajectory?.sweeps ?? [] }

    /// The frames worth putting a tick mark on.
    ///
    /// NOT every frame containing a rotamer jump. Measured on a real run, a
    /// 5,000 sweep trajectory of 335 residues has a jump in essentially every
    /// stored frame, because the sampler proposes rotamer moves directly. Tick
    /// them all and the scrub bar is a solid amber band that points at nothing:
    /// a mark that appears everywhere carries no information.
    ///
    /// So: every ring flip, which is genuinely rare (67 against 15,889 jumps on
    /// the same run), plus the frames in the busiest tenth for rotamer jumps.
    /// That leaves a scrub bar whose marks are worth pressing "next event" to
    /// reach.
    var eventFrames: Set<Int> {
        guard let record else { return [] }

        // Ring flips always tick.
        var frames = Set(record.ringFlips.flips.map(\.frame))

        var jumpsPerFrame: [Int: Int] = [:]
        for jump in record.rotamerJumps.jumps {
            jumpsPerFrame[jump.frame, default: 0] += 1
        }
        guard !jumpsPerFrame.isEmpty else { return frames }

        // The busiest tenth, by jump count. `max(1, ...)` so a run with a
        // handful of jumps still marks its busiest frame rather than none.
        let counts = jumpsPerFrame.values.sorted()
        let threshold = counts[max(0, counts.count * 9 / 10 - 1)]
        for (frame, count) in jumpsPerFrame where count >= max(1, threshold) {
            frames.insert(frame)
        }
        return frames
    }

    /// The trailing frames behind the current one, oldest first.
    var ghostFrames: [[SIMD3<Float>]] {
        guard ghostCount > 0, let trajectory, let current = pinnedFrame else { return [] }
        let start = max(0, current - ghostCount)
        guard start < current else { return [] }
        return (start..<current).map { Array(trajectory.frame($0)) }
    }

    // MARK: - Transport

    func togglePlayback() {
        isPlaying ? pausePlayback() : startPlayback()
    }

    func startPlayback() {
        guard canPlay else { return }
        pausePlayback()
        isPlaying = true
        // Restarting from the end plays from the top, which is what every
        // transport control anybody has used does.
        if (pinnedFrame ?? 0) >= frameCount - 1 { show(frame: 0) }

        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { return }
                let interval = 1.0 / (30.0 * self.playbackSpeed)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self.advanceFrame()
            }
        }
    }

    func pausePlayback() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    private func advanceFrame() {
        guard let current = pinnedFrame else { return show(frame: 0) }
        let next = current + 1
        if next >= frameCount {
            if loopsPlayback {
                show(frame: 0)
            } else {
                pausePlayback()
            }
        } else {
            show(frame: next)
        }
    }

    func step(by delta: Int) {
        pausePlayback()
        show(frame: (pinnedFrame ?? 0) + delta)
    }

    /// Jump to the next frame containing a jump or a flip, which is what the
    /// tick marks on the scrub bar are for.
    func stepToNextEvent(forward: Bool) {
        pausePlayback()
        let events = eventFrames.sorted()
        guard !events.isEmpty else { return }
        let current = pinnedFrame ?? 0
        let target = forward
            ? events.first { $0 > current } ?? events.first
            : events.last { $0 < current } ?? events.last
        if let target { show(frame: target) }
    }
}

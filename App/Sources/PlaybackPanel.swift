import JumpjetAnalysis
import JumpjetHUD
import SwiftUI

/// The transport: scrub bar with jump ticks, play/pause, speed, loop and the
/// ghost trail.
struct PlaybackPanel: View {
    // The coordinator directly, not `model.run`. `run` is a `let` on AppModel,
    // so `$model.run.playbackSpeed` is not a settable key path and every slider
    // has to be hand-wrapped in a Binding. Binding the object that owns the
    // values is simpler than working around where it happens to live.
    @Bindable var run: RunCoordinator

    var body: some View {
        HUDPanel("Playback", trailing: positionCaption) {
            VStack(alignment: .leading, spacing: 12) {
                ScrubBar(
                    frameCount: run.frameCount,
                    frame: run.pinnedFrame ?? 0,
                    eventFrames: run.eventFrames,
                    onScrub: { run.show(frame: $0) })
                    .frame(height: 34)

                transport
                speedControl
                trailControl
            }
        }
    }

    private var positionCaption: String {
        guard run.frameCount > 0 else { return "NO TRAJECTORY" }
        let frame = run.pinnedFrame ?? 0
        let sweeps = run.frameSweeps
        let sweep = frame < sweeps.count ? sweeps[frame] : 0
        return "SWEEP \(HUDFormat.count(sweep))"
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 14) {
            transportButton("backward.end.fill", "Previous event") {
                run.stepToNextEvent(forward: false)
            }
            transportButton("backward.frame.fill", "Step back") { run.step(by: -1) }
            Button {
                run.togglePlayback()
            } label: {
                Image(systemName: run.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(HUDPalette.background)
                    .frame(width: 46, height: 34)
                    .background(
                        HUDPalette.accent,
                        in: RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(run.isPlaying ? "Pause" : "Play")
            transportButton("forward.frame.fill", "Step forward") { run.step(by: 1) }
            transportButton("forward.end.fill", "Next event") {
                run.stepToNextEvent(forward: true)
            }
            Spacer(minLength: 0)
            Button {
                run.loopsPlayback.toggle()
            } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        run.loopsPlayback ? HUDPalette.primary : HUDPalette.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Loop")
            .accessibilityValue(run.loopsPlayback ? "on" : "off")
        }
    }

    private func transportButton(
        _ symbol: String, _ label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HUDPalette.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Speed and trail

    private var speedControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Speed").hudLabelStyle()
                Spacer()
                Text("\(HUDFormat.fixed(run.playbackSpeed, decimals: 1))x")
                    .font(HUDTypography.readoutSmall(11))
                    .foregroundStyle(HUDPalette.primary)
            }
            // The build plan's range, and the reason it stops at 4: the frames
            // are redrawn from scratch, so past about four times real time the
            // renderer, not the slider, is what sets the rate.
            Slider(value: $run.playbackSpeed, in: 0.5...4.0, step: 0.5)
                .tint(HUDPalette.primary)
        }
    }

    private var trailControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Ghost trail").hudLabelStyle()
                Spacer()
                Text(run.ghostCount == 0 ? "off" : "\(run.ghostCount) frames")
                    .font(HUDTypography.readoutSmall(11))
                    .foregroundStyle(
                        run.ghostCount == 0 ? HUDPalette.muted : HUDPalette.primary)
            }
            Slider(
                value: Binding(
                    get: { Double(run.ghostCount) },
                    set: { run.ghostCount = Int($0) }),
                in: 0...Double(RunCoordinator.maximumGhosts), step: 1)
                .tint(HUDPalette.primary)
        }
    }
}

/// The scrub bar, with a tick for every frame containing a jump or a flip.
///
/// Drawn rather than assembled from a Slider and an overlay, because the ticks
/// have to line up with the thumb exactly: a tick half a frame off is a tick
/// that points at the wrong event, and the user's whole reason for tapping it
/// is that it points at something.
struct ScrubBar: View {
    let frameCount: Int
    let frame: Int
    let eventFrames: Set<Int>
    let onScrub: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let position = frameCount > 1
                ? CGFloat(frame) / CGFloat(frameCount - 1) * width : 0

            ZStack(alignment: .topLeading) {
                // The track.
                Capsule()
                    .fill(HUDPalette.border)
                    .frame(height: 5)
                    .offset(y: 14)

                Capsule()
                    .fill(HUDPalette.primary)
                    .frame(width: max(2, position), height: 5)
                    .offset(y: 14)

                // Jump ticks, in the amber that means an event everywhere else.
                Canvas { context, size in
                    for event in eventFrames {
                        guard frameCount > 1 else { continue }
                        let x = CGFloat(event) / CGFloat(frameCount - 1) * size.width
                        let rect = CGRect(x: x - 0.75, y: 0, width: 1.5, height: 11)
                        context.fill(Path(rect), with: .color(HUDPalette.accent))
                    }
                }
                .frame(height: 11)
                .allowsHitTesting(false)

                // The thumb.
                Circle()
                    .fill(HUDPalette.primary)
                    .frame(width: 14, height: 14)
                    .offset(x: position - 7, y: 9)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard frameCount > 1, width > 0 else { return }
                        let fraction = min(1, max(0, value.location.x / width))
                        onScrub(Int((fraction * CGFloat(frameCount - 1)).rounded()))
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Trajectory scrubber")
        .accessibilityValue(
            "frame \(frame + 1) of \(frameCount), \(eventFrames.count) marked events")
        .accessibilityAdjustableAction { direction in
            onScrub(frame + (direction == .increment ? 1 : -1))
        }
    }
}

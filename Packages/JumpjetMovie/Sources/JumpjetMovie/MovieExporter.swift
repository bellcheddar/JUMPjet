import AVFoundation
import CoreGraphics
import Foundation
import JumpjetCore
import JumpjetViewer
import SceneKit
import simd

/// Renders a trajectory to an H.264 movie.
///
/// Offscreen `SCNRenderer` into a `CVPixelBuffer` into `AVAssetWriter`, as the
/// build plan specifies. Offscreen rather than screen-recording the live view,
/// because the movie's size, frame rate and framing should not depend on the
/// device it happens to be exported from.
public actor MovieExporter {

    public enum Failure: Error, LocalizedError {
        case cannotCreateWriter(String)
        case cannotCreatePixelBuffer
        case noFrames
        case invalidPreset(String)
        case writingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotCreateWriter(let reason): "Could not start the movie: \(reason)"
            case .cannotCreatePixelBuffer: "Could not allocate a video frame."
            case .noFrames: "There is no trajectory to export."
            case .invalidPreset(let reason): "That size cannot be encoded: \(reason)"
            case .writingFailed(let reason): "The movie could not be written: \(reason)"
            }
        }
    }

    /// What the HUD burn-in says.
    public struct Caption: Sendable, Hashable {
        public var accession: String
        public var title: String
        public var sweeps: [Int]
        public var rmsd: [Float]

        public init(accession: String, title: String, sweeps: [Int], rmsd: [Float]) {
            self.accession = accession
            self.title = title
            self.sweeps = sweeps
            self.rmsd = rmsd
        }
    }

    public init() {}

    /// Write a movie and return where it landed.
    ///
    /// - Parameter progress: called with 0 to 1 as frames are written.
    public func export(
        structure: Structure,
        frames: [[SIMD3<Float>]],
        viewerOptions: ViewerOptions,
        flexibility: [Float]?,
        options: MovieOptions,
        caption: Caption,
        to url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard !frames.isEmpty else { throw Failure.noFrames }
        guard options.preset.isValid else {
            throw Failure.invalidPreset(
                "\(options.preset.width) by \(options.preset.height): H.264 needs even "
                    + "dimensions")
        }

        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw Failure.cannotCreateWriter(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: options.preset.width,
            AVVideoHeightKey: options.preset.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.preset.bitsPerSecond,
                AVVideoMaxKeyFrameIntervalKey: options.framesPerSecond * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: options.preset.width,
                kCVPixelBufferHeightKey as String: options.preset.height,
                // Required for the renderer to draw into these buffers on iOS.
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])

        guard writer.canAdd(input) else {
            throw Failure.cannotCreateWriter("the video input was refused")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.cannotCreateWriter(
                writer.error?.localizedDescription ?? "unknown reason")
        }
        writer.startSession(atSourceTime: .zero)

        let renderer = FrameRenderer(
            structure: structure, viewerOptions: viewerOptions, flexibility: flexibility,
            options: options)

        let total = options.movieFrameCount(trajectoryFrames: frames.count)
        for index in 0..<total {
            // The tail holds the LAST frame rather than repeating the whole
            // trajectory, so a movie does not cut dead on its final sweep.
            let source = min(index, frames.count - 1)
            let fraction = total > 1 ? Double(index) / Double(total - 1) : 0

            guard let buffer = try renderer.render(
                positions: frames[source],
                orbitFraction: options.orbits ? fraction : 0,
                caption: options.burnsInHUD ? caption : nil,
                frameIndex: source,
                pool: adaptor.pixelBufferPool)
            else { throw Failure.cannotCreatePixelBuffer }

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(options.framesPerSecond))
            if !adaptor.append(buffer, withPresentationTime: time) {
                throw Failure.writingFailed(
                    writer.error?.localizedDescription ?? "a frame was rejected")
            }
            progress?(Double(index + 1) / Double(total))
        }

        input.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            throw Failure.writingFailed(
                writer.error?.localizedDescription ?? "the writer failed at the end")
        }
        return url
    }

    /// A default destination in the caches directory.
    ///
    /// Caches, because the file is handed straight to a share sheet or saved to
    /// Photos: keeping a second copy in Documents is a copy the user never asked
    /// for and cannot see to delete.
    public static func temporaryURL(accession: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("JUMPjet/Movies", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Sanitise, then guard the two cases sanitising alone does not fix. A
        // full stop is a legal filename character, so "../../etc/passwd"
        // survives as ".._.._etc_passwd", which is harmless; an accession of
        // ".." survives as "..", which is a directory reference. And an
        // accession of nothing but punctuation sanitises to an empty string and
        // yields a file called "JUMPjet-.mp4".
        var safe = accession.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        if safe.isEmpty || safe.allSatisfy({ $0 == "." }) { safe = "structure" }
        return directory.appendingPathComponent("JUMPjet-\(safe).mp4")
    }
}

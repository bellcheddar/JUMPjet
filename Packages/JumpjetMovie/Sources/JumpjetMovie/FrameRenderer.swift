import CoreGraphics
import CoreVideo
import Foundation
import JumpjetCore
import JumpjetHUD
import JumpjetViewer
import SceneKit
import simd

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Renders one trajectory frame into a pixel buffer.
///
/// Holds ONE scene and one renderer for the whole movie and swaps coordinates
/// into it. Rebuilding the scene per frame would re-derive the elastic network,
/// the bond list and the colour scale two hundred times for a picture that
/// differs only in where the atoms are.
final class FrameRenderer {

    private let structure: Structure
    private let viewerOptions: ViewerOptions
    private let flexibility: [Float]?
    private let options: MovieOptions
    private let scene: SCNScene
    private let root: SCNNode
    private let cameraNode: SCNNode
    private let renderer: SCNRenderer
    private let baseCameraPosition: SIMD3<Float>
    private var working: Structure

    init(
        structure: Structure, viewerOptions: ViewerOptions, flexibility: [Float]?,
        options: MovieOptions
    ) {
        self.structure = structure
        self.viewerOptions = viewerOptions
        self.flexibility = flexibility
        self.options = options
        self.working = structure

        let scene = StructureScene.make(
            structure: structure, options: viewerOptions, flexibility: flexibility)
        self.scene = scene
        self.root = scene.rootNode.childNode(
            withName: StructureScene.NodeName.root, recursively: false) ?? scene.rootNode
        let camera = scene.rootNode.childNode(
            withName: StructureScene.NodeName.camera, recursively: false) ?? SCNNode()
        self.cameraNode = camera

        // Fit the camera to the movie's aspect ratio, not the screen's. A
        // square 720 export from a landscape phone would otherwise be framed
        // for a shape it is not.
        let distance = StructureScene.cameraDistance(
            boundingRadius: structure.boundingRadius,
            aspect: Float(options.preset.aspect))
        camera.simdPosition = SIMD3(0, 0, distance)
        self.baseCameraPosition = camera.simdPosition

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        self.renderer = renderer
    }

    /// Render one frame.
    func render(
        positions: [SIMD3<Float>],
        orbitFraction: Double,
        caption: MovieExporter.Caption?,
        frameIndex: Int,
        pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer? {
        guard positions.count == structure.atomCount else { return nil }

        working.setPositions(positions)
        StructureScene.rebuildGeometry(
            in: root, structure: working, options: viewerOptions, flexibility: flexibility)

        // Orbit by moving the camera on a circle about the origin, not by
        // rotating the structure: the lights are in the scene's frame, so
        // spinning the molecule would carry its own shading round with it and
        // the protein would look flat.
        let angle = Float(orbitFraction * options.orbitDegrees * .pi / 180)
        let radius = simd_length(baseCameraPosition)
        cameraNode.simdPosition = SIMD3(sin(angle) * radius, 0, cos(angle) * radius)
        cameraNode.simdEulerAngles = SIMD3(0, angle, 0)

        // `snapshot` rather than a Metal render pass into the buffer's own
        // texture. The pass version needs a device, a command queue, a texture
        // cache and a command buffer that must be committed and waited on, and
        // every one of those is a place for a movie export to fail on a device
        // nobody tested. Snapshot returns an image, the image goes into the
        // buffer through Core Graphics, and the same code path draws the HUD.
        let image = renderer.snapshot(
            atTime: 0, with: options.preset.size, antialiasingMode: .multisampling4X)
        guard let cgImage = image.jumpjetCGImage else { return nil }

        guard let buffer = makeBuffer(pool: pool) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let address = CVPixelBufferGetBaseAddress(buffer),
            let colourSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: address, width: options.preset.width, height: options.preset.height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: colourSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        context.draw(
            cgImage,
            in: CGRect(origin: .zero, size: options.preset.size))

        if let caption {
            draw(caption: caption, frameIndex: frameIndex, in: context)
        }
        return buffer
    }

    private func makeBuffer(pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault, options.preset.width, options.preset.height,
                kCVPixelFormatType_32BGRA,
                [
                    kCVPixelBufferCGImageCompatibilityKey: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                    kCVPixelBufferMetalCompatibilityKey: true,
                ] as CFDictionary,
                &buffer)
        }
        return buffer
    }

    /// The HUD burn-in, drawn straight into the pixel buffer with Core Graphics.
    ///
    /// Text over the rendered frame rather than a SceneKit overlay: an overlay
    /// scales with the scene's camera and would swim about during the orbit.
    private func draw(
        caption: MovieExporter.Caption, frameIndex: Int, in context: CGContext
    ) {
        let scale = CGFloat(options.preset.height) / 1080
        let margin = 34 * scale
        let sweep = frameIndex < caption.sweeps.count ? caption.sweeps[frameIndex] : 0
        let rmsd = frameIndex < caption.rmsd.count ? caption.rmsd[frameIndex] : 0

        let lines: [(String, CGFloat, CGColor)] = [
            (caption.accession, 34 * scale, Self.phosphor),
            (caption.title, 20 * scale, Self.text),
            ("SWEEP \(sweep)   RMSD \(String(format: "%.2f", rmsd)) A",
             22 * scale, Self.phosphor),
            // Ground rule 3 travels with the movie. A clip shared out of the
            // app has to carry its own caveat, because nobody watching it can
            // see the About screen.
            ("MC sweeps, pseudo-time. Crude on-device sampler.", 15 * scale, Self.muted),
        ]

        var y = margin
        for (text, size, colour) in lines.reversed() {
            draw(text: text, at: CGPoint(x: margin, y: y), size: size, colour: colour,
                 in: context)
            y += size * 1.45
        }
    }

    private func draw(
        text: String, at point: CGPoint, size: CGFloat, colour: CGColor, in context: CGContext
    ) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: colour,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private static let phosphor = CGColor(red: 0, green: 0xE6 / 255.0, blue: 0x76 / 255.0, alpha: 1)
    private static let text = CGColor(red: 0xE6 / 255.0, green: 0xED / 255.0, blue: 0xF3 / 255.0, alpha: 1)
    private static let muted = CGColor(red: 0x8B / 255.0, green: 0x99 / 255.0, blue: 0xA9 / 255.0, alpha: 0.9)
}

extension PlatformImage {
    /// `UIImage` has `cgImage`; `NSImage` does not. One accessor so the renderer
    /// does not carry an availability check per platform.
    var jumpjetCGImage: CGImage? {
        #if canImport(UIKit)
            return cgImage
        #else
            var rect = CGRect(origin: .zero, size: size)
            return cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }
}

#if canImport(UIKit)
    typealias PlatformImage = UIImage
#else
    typealias PlatformImage = NSImage
#endif

import JumpjetCore
import JumpjetHUD
import SceneKit
import SwiftUI
import simd

/// The 3D view: a SceneKit scene with orbit, pinch and pan.
///
/// A representable rather than SwiftUI's `SceneView` because the scene has to
/// be updated in place. Rebuilding it on every option change is what throws the
/// user's camera back to the default the moment they change the colour mode.
public struct StructureViewer: View {
    private let structure: Structure
    private let options: ViewerOptions
    private let flexibility: [Float]?

    public init(structure: Structure, options: ViewerOptions, flexibility: [Float]? = nil) {
        self.structure = structure
        self.options = options
        self.flexibility = flexibility
    }

    public var body: some View {
        SceneKitContainer(structure: structure, options: options, flexibility: flexibility)
            .background(HUDPalette.background)
            .accessibilityLabel("Three dimensional structure of \(structure.identifier)")
            .accessibilityHint("Drag to rotate, pinch to zoom, two fingers to pan.")
    }
}

/// Identity of the geometry currently in the scene, so an update knows whether
/// anything it cares about actually changed.
private struct GeometryKey: Equatable {
    let identifier: String
    let atomCount: Int
    let colourMode: ColourMode
    let showsSideChains: Bool
    let visibleChains: Set<Int>

    init(_ structure: Structure, _ options: ViewerOptions) {
        self.identifier = structure.identifier
        self.atomCount = structure.atomCount
        self.colourMode = options.colourMode
        self.showsSideChains = options.showsSideChains
        self.visibleChains = options.visibleChains
    }
}

#if canImport(UIKit)
    import UIKit

    private struct SceneKitContainer: UIViewRepresentable {
        let structure: Structure
        let options: ViewerOptions
        let flexibility: [Float]?

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context: Context) -> FramingSCNView {
            let view = FramingSCNView()
            view.scene = StructureScene.make(
                structure: structure, options: options, flexibility: flexibility)
            view.allowsCameraControl = true
            view.defaultCameraController.interactionMode = .orbitTurntable
            view.defaultCameraController.inertiaEnabled = true
            view.autoenablesDefaultLighting = false
            view.antialiasingMode = .multisampling2X
            view.backgroundColor = .clear
            view.rendersContinuously = false
            // Name the camera explicitly. Left nil, SceneKit finds a camera at
            // RENDER time, and until then `defaultCameraController` has nothing
            // to act on, so every reframe silently does nothing.
            view.pointOfView = view.scene?.rootNode.childNode(
                withName: StructureScene.NodeName.camera, recursively: false)
            context.coordinator.key = GeometryKey(structure, options)
            context.coordinator.boundingRadius = structure.boundingRadius
            // Framing is driven by LAYOUT, not by this call. The view has no
            // bounds yet here, and on iPad the pane it ends up in is a very
            // different shape from the one it is first measured at: framing
            // once, early, left a third of the structure outside the panel.
            view.onLayout = { [weak view] in
                guard let view else { return }
                context.coordinator.frameIfSizeChanged(view)
            }
            return view
        }

        func updateUIView(_ view: FramingSCNView, context: Context) {
            let key = GeometryKey(structure, options)
            guard key != context.coordinator.key else { return }
            let isNewStructure = context.coordinator.key?.identifier != key.identifier
            context.coordinator.key = key
            defer {
                if isNewStructure {
                    context.coordinator.framedSize = nil
                    context.coordinator.boundingRadius = structure.boundingRadius
                    context.coordinator.frameIfSizeChanged(view)
                }
            }

            guard let scene = view.scene,
                let root = scene.rootNode.childNode(
                    withName: StructureScene.NodeName.root, recursively: false)
            else {
                view.scene = StructureScene.make(
                    structure: structure, options: options, flexibility: flexibility)
                return
            }
            // Geometry only. The camera node is a sibling of the structure
            // root, so the user's viewpoint survives every option change.
            StructureScene.rebuildGeometry(
                in: root, structure: structure, options: options, flexibility: flexibility)
        }

        final class Coordinator {
            var key: GeometryKey?
            /// The size the camera was last framed against. Framing depends on
            /// the aspect ratio, so a rotation or a split-view resize needs a
            /// new fit and a repeat at the same size does not.
            var framedSize: CGSize?
            var boundingRadius: Float = 1

            /// Refit the camera to the view's real aspect ratio.
            ///
            /// Only on a new structure or a genuine size change, never on every
            /// update: reframing on each pass would yank the camera back to
            /// default the moment the user orbited it.
            ///
            /// The distance changes; the DIRECTION does not. The geometry is
            /// centred on the origin, so scaling the camera's position vector
            /// refits without disturbing an orientation the user has chosen.
            func frameIfSizeChanged(_ view: SCNView) {
                let size = view.bounds.size
                guard size.width > 1, size.height > 1 else { return }
                if let framedSize,
                    abs(framedSize.width - size.width) < 1,
                    abs(framedSize.height - size.height) < 1
                { return }
                guard let camera = view.scene?.rootNode.childNode(
                    withName: StructureScene.NodeName.camera, recursively: false)
                else { return }
                framedSize = size

                let distance = StructureScene.cameraDistance(
                    boundingRadius: boundingRadius,
                    aspect: Float(size.width / size.height))
                let current = camera.simdPosition
                let direction = simd_length(current) > 1e-4
                    ? simd_normalize(current) : SIMD3<Float>(0, 0, 1)
                camera.simdPosition = direction * distance
                view.pointOfView = camera
            }
        }
    }

    /// An SCNView that reports its own layout.
    ///
    /// SwiftUI does not call `updateUIView` when only the view's BOUNDS change,
    /// so a representable that frames its camera in `update` frames it against
    /// whatever size it was first measured at and never corrects.
    final class FramingSCNView: SCNView {
        var onLayout: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }
#else
    import AppKit

    private struct SceneKitContainer: NSViewRepresentable {
        let structure: Structure
        let options: ViewerOptions
        let flexibility: [Float]?

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> SCNView {
            let view = SCNView()
            view.scene = StructureScene.make(
                structure: structure, options: options, flexibility: flexibility)
            view.allowsCameraControl = true
            view.autoenablesDefaultLighting = false
            context.coordinator.key = GeometryKey(structure, options)
            return view
        }

        func updateNSView(_ view: SCNView, context: Context) {
            let key = GeometryKey(structure, options)
            guard key != context.coordinator.key else { return }
            context.coordinator.key = key
            guard let root = view.scene?.rootNode.childNode(
                withName: StructureScene.NodeName.root, recursively: false)
            else { return }
            StructureScene.rebuildGeometry(
                in: root, structure: structure, options: options, flexibility: flexibility)
        }

        final class Coordinator {
            var key: GeometryKey?
        }
    }
#endif

/// The colour-mode legend, which names every band rather than relying on the
/// colours alone, per the build plan's accessibility rule.
public struct ColourLegend: View {
    private let mode: ColourMode
    private let structure: Structure

    public init(mode: ColourMode, structure: Structure) {
        self.mode = mode
        self.structure = structure
    }

    public var body: some View {
        HStack(spacing: 10) {
            ForEach(entries, id: \.label) { entry in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            Color(
                                red: Double(entry.colour.x), green: Double(entry.colour.y),
                                blue: Double(entry.colour.z))
                        )
                        .frame(width: 10, height: 10)
                    Text(entry.label)
                        .font(HUDTypography.readoutSmall(9))
                        .foregroundStyle(HUDPalette.muted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var entries: [(label: String, colour: SIMD3<Float>)] {
        switch mode {
        case .confidence:
            [
                ("Very high", ResidueColouring.confidenceColour(plddt: 95)),
                ("Confident", ResidueColouring.confidenceColour(plddt: 80)),
                ("Low", ResidueColouring.confidenceColour(plddt: 60)),
                ("Very low", ResidueColouring.confidenceColour(plddt: 30)),
            ]
        case .chainbow:
            [
                ("N", ResidueColouring.chainbowColour(fraction: 0)),
                ("mid", ResidueColouring.chainbowColour(fraction: 0.5)),
                ("C", ResidueColouring.chainbowColour(fraction: 1)),
            ]
        case .flexibility:
            [
                ("Rigid", ResidueColouring.flexibilityColour(0)),
                ("Floppy", ResidueColouring.flexibilityColour(1)),
            ]
        case .chain:
            structure.chains.indices.prefix(6).map { index in
                (
                    structure.chains[index].id,
                    ResidueColouring.chainColour(index: index, of: structure.chains.count)
                )
            }
        case .element:
            [
                ("C", Element.carbon.cpkColour), ("N", Element.nitrogen.cpkColour),
                ("O", Element.oxygen.cpkColour), ("S", Element.sulphur.cpkColour),
            ]
        }
    }
}

import Foundation
import JumpjetCore
import SceneKit
import simd

/// What the viewer is showing.
public struct ViewerOptions: Sendable, Hashable {
    public var colourMode: ColourMode = .chainbow
    public var showsSideChains = false
    /// Chains to draw. Empty means every chain.
    public var visibleChains: Set<Int> = []
    public var tubeRadius: Float = 0.42
    public var stickRadius: Float = 0.12
    /// Residues drawn in the accent colour, whatever the colour mode.
    ///
    /// Phase 3 needs this: tapping a jump-happy residue or a flipped ring in
    /// the analysis has to point at something in the structure, and a table of
    /// labels that highlights nothing is a table nobody can act on.
    public var highlightedResidues: Set<Int> = []

    public init() {}

    public func drawsChain(_ index: Int) -> Bool {
        visibleChains.isEmpty || visibleChains.contains(index)
    }

    /// Afterburner amber, the same colour a jump event gets everywhere else in
    /// the app. Reusing it here is deliberate: one colour, one meaning.
    public static let highlightColour = SIMD3<Float>(1.0, 0xB3 / 255.0, 0)

    /// How many trailing frames the ghost trail draws.
    public var ghostCount = 0
    /// Radius of a ghost's tube. Much thinner than the real one: a trail drawn
    /// at full thickness hides the structure it is a trail of.
    public var ghostRadius: Float = 0.14
}

/// Builds a SceneKit scene from a structure.
///
/// Node names are stable and meaningful (`tube.0`, `sticks`, `camera`) so the
/// view can update one part without rebuilding the scene: swapping colours on a
/// 600-residue tube costs a geometry rebuild, and rebuilding the whole scene
/// costs the camera position the user just set.
public enum StructureScene {

    public enum NodeName {
        public static let root = "structure"
        public static let camera = "camera"
        public static let sticks = "sticks"
        public static func tube(_ chainIndex: Int) -> String { "tube.\(chainIndex)" }
        public static func ghost(_ index: Int) -> String { "ghost.\(index)" }
    }

    public static func make(
        structure: Structure, options: ViewerOptions, flexibility: [Float]? = nil,
        ghosts: [[SIMD3<Float>]] = []
    ) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = PlatformColour(
            red: 0x0A / 255, green: 0x0E / 255, blue: 0x14 / 255, alpha: 1)

        let root = SCNNode()
        root.name = NodeName.root
        // The structure is centred by MOVING ITS VERTICES, not by putting a
        // translation in the node's pivot. A pivot centres it on screen and
        // leaves the node's bounding box where the file put it, which quietly
        // defeats SCNCameraController.frameNodes: it fits the camera to a
        // volume tens of angstroms from anything visible, and the structure
        // arrives half outside the panel.
        scene.rootNode.addChildNode(root)

        rebuildGeometry(
            in: root, structure: structure, options: options, flexibility: flexibility,
            ghosts: ghosts)
        addLighting(to: scene, radius: structure.boundingRadius)
        addCamera(to: scene, radius: structure.boundingRadius)
        return scene
    }

    /// Replace the geometry without touching the camera or the lights.
    public static func rebuildGeometry(
        in root: SCNNode, structure: Structure, options: ViewerOptions,
        flexibility: [Float]? = nil, ghosts: [[SIMD3<Float>]] = []
    ) {
        root.childNodes.forEach { $0.removeFromParentNode() }

        var colours = ResidueColouring.colours(
            for: structure, mode: options.colourMode, flexibility: flexibility)
        for residue in options.highlightedResidues where colours.indices.contains(residue) {
            colours[residue] = ViewerOptions.highlightColour
        }
        // Centre on the whole structure, not on the visible subset: filtering
        // to one chain of a tetramer should not slide the other three across
        // the panel as it is toggled.
        let centre = structure.centroid

        for chainIndex in structure.chains.indices where options.drawsChain(chainIndex) {
            var mesh = TubeBuilder.backboneTube(
                structure: structure, chainIndex: chainIndex, residueColours: colours,
                radius: options.tubeRadius)
            mesh.translate(by: -centre)
            guard !mesh.isEmpty, let geometry = geometry(from: mesh) else { continue }
            let node = SCNNode(geometry: geometry)
            node.name = NodeName.tube(chainIndex)
            root.addChildNode(node)
        }

        // Ghosts first, so the current frame draws over them.
        //
        // Cα trace only, and thin. A ghost trail of full tubes is four more
        // copies of the most expensive geometry in the scene, redrawn on every
        // frame of playback, and it buries the structure it is a trail of.
        for (index, ghost) in ghosts.enumerated() where ghost.count == structure.atomCount {
            var mesh = TubeMesh()
            for chainIndex in structure.chains.indices where options.drawsChain(chainIndex) {
                var chainMesh = ghostTube(
                    structure: structure, chainIndex: chainIndex, positions: ghost,
                    radius: options.ghostRadius,
                    // Older ghosts are fainter, which is what makes the trail
                    // read as a direction rather than as a tangle.
                    fade: Float(index + 1) / Float(ghosts.count + 1))
                chainMesh.translate(by: -centre)
                let offset = Int32(mesh.positions.count)
                mesh.positions.append(contentsOf: chainMesh.positions)
                mesh.normals.append(contentsOf: chainMesh.normals)
                mesh.colours.append(contentsOf: chainMesh.colours)
                mesh.indices.append(contentsOf: chainMesh.indices.map { $0 + offset })
            }
            guard !mesh.isEmpty, let geometry = geometry(from: mesh) else { continue }
            let node = SCNNode(geometry: geometry)
            node.name = NodeName.ghost(index)
            node.opacity = CGFloat(0.15 + 0.35 * Double(index + 1) / Double(ghosts.count + 1))
            root.addChildNode(node)
        }

        if options.showsSideChains, let sticks = stickGeometry(
            structure: structure, options: options, colours: colours, centre: centre)
        {
            let node = SCNNode(geometry: sticks)
            node.name = NodeName.sticks
            root.addChildNode(node)
        }
    }

    /// A thin Cα tube for one chain of a past frame.
    static func ghostTube(
        structure: Structure, chainIndex: Int, positions: [SIMD3<Float>], radius: Float,
        fade: Float
    ) -> TubeMesh {
        let range = structure.chains[chainIndex].residueRange
        var controls: [SIMD3<Float>] = []
        for residueIndex in range {
            guard let alphaCarbon = structure.alphaCarbonIndex(ofResidue: residueIndex) else {
                continue
            }
            controls.append(positions[alphaCarbon])
        }
        guard controls.count >= 2 else { return TubeMesh() }
        // Three segments per residue rather than six, and six sides rather than
        // ten: a ghost is a hint of where the chain was, not a model of it.
        let path = TubeBuilder.interpolate(controls, segmentsPerSpan: 3)
        let colour = SIMD3<Float>(repeating: 0.35 + 0.4 * fade)
        return TubeBuilder.sweep(path: path, colours: [colour], radius: radius, sides: 6)
    }

    // MARK: - Geometry

    static func geometry(from mesh: TubeMesh) -> SCNGeometry? {
        guard !mesh.isEmpty, !mesh.indices.isEmpty else { return nil }

        let positions = mesh.positions.map {
            SCNVector3Make(SceneFloat($0.x), SceneFloat($0.y), SceneFloat($0.z))
        }
        let normals = mesh.normals.map {
            SCNVector3Make(SceneFloat($0.x), SceneFloat($0.y), SceneFloat($0.z))
        }

        let vertexSource = SCNGeometrySource(vertices: positions)
        let normalSource = SCNGeometrySource(normals: normals)
        let colourSource = colourSource(mesh.colours)
        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)

        let geometry = SCNGeometry(
            sources: [vertexSource, normalSource, colourSource], elements: [element])
        geometry.materials = [instrumentMaterial()]
        return geometry
    }

    /// Per-vertex colour, which is what lets one geometry carry a whole colour
    /// scale instead of needing one material and one draw call per band.
    static func colourSource(_ colours: [SIMD3<Float>]) -> SCNGeometrySource {
        var packed: [Float] = []
        packed.reserveCapacity(colours.count * 3)
        for colour in colours {
            packed.append(colour.x)
            packed.append(colour.y)
            packed.append(colour.z)
        }
        let data = packed.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(
            data: data,
            semantic: .color,
            vectorCount: colours.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3)
    }

    static func instrumentMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = PlatformColour.white
        material.roughness.contents = 0.55
        material.metalness.contents = 0.0
        // Vertex colours multiply the diffuse, so the material stays white and
        // the geometry carries the scale.
        material.isDoubleSided = false
        return material
    }

    /// Side chains as thin cylinders, built as one merged mesh.
    ///
    /// One node per bond would be several thousand nodes and several thousand
    /// draw calls, which is how a 600-residue protein drops from 60 fps to a
    /// slideshow on a phone.
    static func stickGeometry(
        structure: Structure, options: ViewerOptions, colours: [SIMD3<Float>],
        centre: SIMD3<Float>
    ) -> SCNGeometry? {
        let bonds = BondFinder.sideChainBonds(in: structure)
        guard !bonds.isEmpty else { return nil }

        var mesh = TubeMesh()
        let sides = 6
        for bond in bonds {
            let first = structure.atoms[bond.a]
            let second = structure.atoms[bond.b]
            let residue = structure.residues[first.residueIndex]
            guard options.drawsChain(residue.chainIndex) else { continue }

            let colourA = options.colourMode == .element
                ? first.element.cpkColour
                : (first.residueIndex < colours.count ? colours[first.residueIndex] : SIMD3(1, 1, 1))
            let colourB = options.colourMode == .element
                ? second.element.cpkColour
                : (second.residueIndex < colours.count
                    ? colours[second.residueIndex] : SIMD3(1, 1, 1))

            // Split at the midpoint so each half takes its own atom's colour,
            // which is what makes a CPK stick read as two elements rather than
            // as one arbitrary blend.
            let midpoint = (first.position + second.position) / 2
            append(
                cylinder: &mesh, from: first.position, to: midpoint, colour: colourA,
                radius: options.stickRadius, sides: sides)
            append(
                cylinder: &mesh, from: midpoint, to: second.position, colour: colourB,
                radius: options.stickRadius, sides: sides)
        }

        mesh.translate(by: -centre)
        return geometry(from: mesh)
    }

    static func append(
        cylinder mesh: inout TubeMesh, from start: SIMD3<Float>, to end: SIMD3<Float>,
        colour: SIMD3<Float>, radius: Float, sides: Int
    ) {
        let segment = TubeBuilder.sweep(
            path: [start, end], colours: [colour], radius: radius, sides: sides)
        guard !segment.isEmpty else { return }
        let offset = Int32(mesh.positions.count)
        mesh.positions.append(contentsOf: segment.positions)
        mesh.normals.append(contentsOf: segment.normals)
        mesh.colours.append(contentsOf: segment.colours)
        mesh.indices.append(contentsOf: segment.indices.map { $0 + offset })
    }

    // MARK: - Camera and lights

    /// The camera's vertical field of view, in degrees.
    public static let fieldOfViewDegrees: Float = 45

    /// How far back the camera must sit for a sphere of `radius` about the
    /// origin to fit a view of the given aspect ratio.
    ///
    /// The aspect ratio is not optional here, and that is the whole point.
    /// SceneKit applies `fieldOfView` to ONE dimension, so on a tall narrow
    /// pane the horizontal angle is far smaller than the 45 degrees the naive
    /// distance assumes, and the structure runs off both sides of the panel
    /// while looking perfectly framed on a square iPhone view. Fitting the
    /// tighter of the two angles is what makes one formula serve both.
    ///
    /// `radius / sin(halfAngle)` is the exact tangent distance for a sphere,
    /// not the `radius / tan(halfAngle)` that fits a flat square at the centre
    /// plane: the near face of a sphere is closer than its centre.
    public static func cameraDistance(
        boundingRadius radius: Float, aspect: Float, margin: Float = 1.06
    ) -> Float {
        let halfVertical = degreesToRadians(fieldOfViewDegrees) / 2
        let safeAspect = aspect.isFinite && aspect > 0.01 ? aspect : 1
        let halfHorizontal = atan(tan(halfVertical) * safeAspect)
        let half = max(0.01, min(halfVertical, halfHorizontal))
        return max(5, radius / sin(half) * margin)
    }

    static func degreesToRadians(_ degrees: Float) -> Float { degrees * .pi / 180 }

    static func addCamera(to scene: SCNScene, radius: Float) {
        let camera = SCNCamera()
        camera.fieldOfView = Double(fieldOfViewDegrees)
        // Pin the direction: `.automatic` applies the field of view to the
        // larger dimension, so the same camera means two different things on a
        // portrait phone and a landscape iPad, and `cameraDistance` could not
        // reason about either.
        camera.projectionDirection = .vertical
        camera.zNear = 0.5
        camera.zFar = Double(radius) * 20 + 200
        camera.wantsHDR = false

        let node = SCNNode()
        node.name = NodeName.camera
        node.camera = camera
        // A square view to start with. The view refits against its real aspect
        // ratio as soon as it has been laid out.
        node.position = SCNVector3Make(
            0, 0, SceneFloat(cameraDistance(boundingRadius: radius, aspect: 1)))
        scene.rootNode.addChildNode(node)
    }

    static func addLighting(to scene: SCNScene, radius: Float) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        // Dim, but not so dim that the tube disappears: AlphaFold's very-high
        // confidence blue is #0053D6, which on a #0A0E14 background is close to
        // invisible under a 260 lumen ambient. The palette is fixed by the
        // scale it means, so the LIGHTING is what has to give.
        ambient.light?.intensity = 340
        ambient.light?.color = PlatformColour(
            red: 0.55, green: 0.62, blue: 0.75, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1250
        key.light?.castsShadow = false
        key.eulerAngles = SCNVector3Make(-0.6, 0.5, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 400
        fill.light?.color = PlatformColour(red: 0.35, green: 0.85, blue: 0.62, alpha: 1)
        fill.eulerAngles = SCNVector3Make(0.9, -1.1, 0)
        scene.rootNode.addChildNode(fill)
    }
}

// SceneKit's scalar is CGFloat on macOS and Float on iOS, and its colour type
// differs too. These aliases keep the geometry code identical on both rather
// than sprinkling it with availability checks.
#if canImport(UIKit)
    import UIKit
    typealias PlatformColour = UIColor
    typealias SceneFloat = Float
#else
    import AppKit
    typealias PlatformColour = NSColor
    typealias SceneFloat = CGFloat
#endif

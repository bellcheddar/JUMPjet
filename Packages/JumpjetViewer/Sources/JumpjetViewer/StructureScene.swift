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

    public init() {}

    public func drawsChain(_ index: Int) -> Bool {
        visibleChains.isEmpty || visibleChains.contains(index)
    }
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
    }

    public static func make(
        structure: Structure, options: ViewerOptions, flexibility: [Float]? = nil
    ) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = PlatformColour(
            red: 0x0A / 255, green: 0x0E / 255, blue: 0x14 / 255, alpha: 1)

        let root = SCNNode()
        root.name = NodeName.root
        // Centre the structure on the origin so the camera orbits its middle
        // rather than swinging around a point tens of angstroms away, which is
        // what makes a far-from-origin crystal structure feel broken to drag.
        root.position = SCNVector3Make(0, 0, 0)
        let centre = structure.centroid
        root.pivot = SCNMatrix4MakeTranslation(
            SceneFloat(centre.x), SceneFloat(centre.y), SceneFloat(centre.z))
        scene.rootNode.addChildNode(root)

        rebuildGeometry(in: root, structure: structure, options: options, flexibility: flexibility)
        addLighting(to: scene, radius: structure.boundingRadius)
        addCamera(to: scene, radius: structure.boundingRadius)
        return scene
    }

    /// Replace the geometry without touching the camera or the lights.
    public static func rebuildGeometry(
        in root: SCNNode, structure: Structure, options: ViewerOptions, flexibility: [Float]? = nil
    ) {
        root.childNodes.forEach { $0.removeFromParentNode() }

        let colours = ResidueColouring.colours(
            for: structure, mode: options.colourMode, flexibility: flexibility)

        for chainIndex in structure.chains.indices where options.drawsChain(chainIndex) {
            let mesh = TubeBuilder.backboneTube(
                structure: structure, chainIndex: chainIndex, residueColours: colours,
                radius: options.tubeRadius)
            guard !mesh.isEmpty, let geometry = geometry(from: mesh) else { continue }
            let node = SCNNode(geometry: geometry)
            node.name = NodeName.tube(chainIndex)
            root.addChildNode(node)
        }

        if options.showsSideChains, let sticks = stickGeometry(
            structure: structure, options: options, colours: colours)
        {
            let node = SCNNode(geometry: sticks)
            node.name = NodeName.sticks
            root.addChildNode(node)
        }
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
        structure: Structure, options: ViewerOptions, colours: [SIMD3<Float>]
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

    static func addCamera(to scene: SCNScene, radius: Float) {
        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.zNear = 0.5
        camera.zFar = Double(radius) * 10 + 100
        camera.wantsHDR = false

        let node = SCNNode()
        node.name = NodeName.camera
        node.camera = camera
        // Far enough back that the whole structure fits the 45 degree field
        // with a margin, derived rather than guessed so a 142-residue globin
        // and an 800-residue kinase both arrive framed.
        let distance = max(12, radius / tan(Float.pi / 8) * 1.25)
        node.position = SCNVector3Make(0, 0, SceneFloat(distance))
        scene.rootNode.addChildNode(node)
    }

    static func addLighting(to scene: SCNScene, radius: Float) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        // Dim: this is a night cockpit, and a bright ambient washes the tube
        // into a flat silhouette with no depth at all.
        ambient.light?.intensity = 260
        ambient.light?.color = PlatformColour(
            red: 0.55, green: 0.62, blue: 0.75, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.light?.castsShadow = false
        key.eulerAngles = SCNVector3Make(-0.6, 0.5, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 320
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

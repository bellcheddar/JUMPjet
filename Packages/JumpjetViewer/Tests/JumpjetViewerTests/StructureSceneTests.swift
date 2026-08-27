import XCTest
import JumpjetCore
import JumpjetParse
import SceneKit
import simd

@testable import JumpjetViewer

final class StructureSceneTests: XCTestCase {

    private func haemoglobin() throws -> Structure {
        try PDBParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.pdb"),
            identifier: "P69905", source: .alphaFold
        ).structure
    }

    func testSceneHasOneTubeNodePerChainPlusACamera() throws {
        let structure = try PDBParser.parse(
            Fixtures.text("structures/1bab.pdb"), source: .pdbe).structure
        let scene = StructureScene.make(structure: structure, options: ViewerOptions())

        let root = try XCTUnwrap(
            scene.rootNode.childNode(withName: StructureScene.NodeName.root, recursively: false))
        XCTAssertEqual(root.childNodes.count, 4)
        for index in structure.chains.indices {
            XCTAssertNotNil(
                root.childNode(withName: StructureScene.NodeName.tube(index), recursively: false))
        }
        XCTAssertNotNil(
            scene.rootNode.childNode(
                withName: StructureScene.NodeName.camera, recursively: false))
    }

    /// Rebuilding the geometry must leave the camera node alone. It is a
    /// sibling of the structure root precisely so that changing the colour mode
    /// does not throw the user's viewpoint back to the default.
    func testRebuildingGeometryLeavesTheCameraUntouched() throws {
        let structure = try haemoglobin()
        let scene = StructureScene.make(structure: structure, options: ViewerOptions())
        let camera = try XCTUnwrap(
            scene.rootNode.childNode(withName: StructureScene.NodeName.camera, recursively: false))
        camera.position = SCNVector3Make(11, 22, 33)

        var options = ViewerOptions()
        options.colourMode = .confidence
        let root = try XCTUnwrap(
            scene.rootNode.childNode(withName: StructureScene.NodeName.root, recursively: false))
        StructureScene.rebuildGeometry(in: root, structure: structure, options: options)

        let after = try XCTUnwrap(
            scene.rootNode.childNode(withName: StructureScene.NodeName.camera, recursively: false))
        XCTAssertEqual(after.position.x, 11, accuracy: 1e-4)
        XCTAssertEqual(after.position.y, 22, accuracy: 1e-4)
        XCTAssertEqual(after.position.z, 33, accuracy: 1e-4)
    }

    /// The geometry itself is centred on the origin, and the node carries no
    /// pivot translation.
    ///
    /// Centring with a pivot puts the structure in the middle of the screen and
    /// leaves the node's BOUNDING BOX where the file put it, which defeats
    /// SCNCameraController.frameNodes: it fits the camera to a volume tens of
    /// angstroms from anything visible and the structure lands half outside the
    /// panel. A crystal structure is nowhere near the origin, so this is not a
    /// theoretical distinction.
    func testTheGeometryItselfIsCentredOnTheOrigin() throws {
        let structure = try PDBParser.parse(
            Fixtures.text("structures/1bab.pdb"), source: .pdbe).structure
        XCTAssertGreaterThan(simd_length(structure.centroid), 5, "the fixture must be off-origin")

        let scene = StructureScene.make(structure: structure, options: ViewerOptions())
        let root = try XCTUnwrap(
            scene.rootNode.childNode(withName: StructureScene.NodeName.root, recursively: false))

        XCTAssertEqual(Float(root.pivot.m41), 0, accuracy: 1e-6)
        XCTAssertEqual(Float(root.pivot.m42), 0, accuracy: 1e-6)
        XCTAssertEqual(Float(root.pivot.m43), 0, accuracy: 1e-6)

        let box = root.boundingBox
        let centre = SIMD3<Float>(
            Float(box.min.x + box.max.x) / 2, Float(box.min.y + box.max.y) / 2,
            Float(box.min.z + box.max.z) / 2)
        XCTAssertLessThan(
            simd_length(centre), 2, "the rendered geometry is not centred on the origin")
    }

    /// Filtering to one chain must not slide the rest of the structure across
    /// the panel: the centre comes from the whole structure, not the subset.
    func testChainFilteringDoesNotRecentreTheView() throws {
        let structure = try PDBParser.parse(
            Fixtures.text("structures/1bab.pdb"), source: .pdbe).structure

        func chainABox(_ options: ViewerOptions) throws -> SCNVector3 {
            let scene = StructureScene.make(structure: structure, options: options)
            let root = try XCTUnwrap(
                scene.rootNode.childNode(
                    withName: StructureScene.NodeName.root, recursively: false))
            let tube = try XCTUnwrap(root.childNode(withName: "tube.0", recursively: false))
            return tube.boundingBox.min
        }

        var filtered = ViewerOptions()
        filtered.visibleChains = [0]
        let all = try chainABox(ViewerOptions())
        let one = try chainABox(filtered)
        XCTAssertEqual(Float(all.x), Float(one.x), accuracy: 1e-4)
        XCTAssertEqual(Float(all.y), Float(one.y), accuracy: 1e-4)
    }

    func testSideChainsAreOffByDefaultAndAddASingleMergedNode() throws {
        let structure = try haemoglobin()
        var options = ViewerOptions()

        let plain = StructureScene.make(structure: structure, options: options)
        let plainRoot = try XCTUnwrap(
            plain.rootNode.childNode(withName: StructureScene.NodeName.root, recursively: false))
        XCTAssertNil(
            plainRoot.childNode(withName: StructureScene.NodeName.sticks, recursively: false))

        options.showsSideChains = true
        let withSticks = StructureScene.make(structure: structure, options: options)
        let stickRoot = try XCTUnwrap(
            withSticks.rootNode.childNode(
                withName: StructureScene.NodeName.root, recursively: false))
        let sticks = try XCTUnwrap(
            stickRoot.childNode(withName: StructureScene.NodeName.sticks, recursively: false))
        // One node, not one per bond: a few thousand nodes is a few thousand
        // draw calls, which is how 60 fps becomes a slideshow.
        XCTAssertEqual(stickRoot.childNodes.count, 2)
        XCTAssertNotNil(sticks.geometry)
    }

    func testChainFilteringDrawsOnlyTheChosenChains() throws {
        let structure = try PDBParser.parse(
            Fixtures.text("structures/1bab.pdb"), source: .pdbe).structure
        var options = ViewerOptions()
        options.visibleChains = [0, 2]

        let scene = StructureScene.make(structure: structure, options: options)
        let root = try XCTUnwrap(
            scene.rootNode.childNode(withName: StructureScene.NodeName.root, recursively: false))
        XCTAssertEqual(root.childNodes.count, 2)
        XCTAssertNotNil(root.childNode(withName: "tube.0", recursively: false))
        XCTAssertNil(root.childNode(withName: "tube.1", recursively: false))
        XCTAssertNotNil(root.childNode(withName: "tube.2", recursively: false))
    }

    /// A tall narrow pane gets a much smaller HORIZONTAL angle than the 45
    /// degree field of view, because SceneKit applies the field to one
    /// dimension only. Ignoring that framed an iPad's tall viewer pane as if it
    /// were square and ran the structure off both sides of the panel while
    /// looking perfectly framed on an iPhone.
    func testCameraDistanceAccountsForAspectRatio() {
        let radius: Float = 30
        let square = StructureScene.cameraDistance(boundingRadius: radius, aspect: 1)
        let tall = StructureScene.cameraDistance(boundingRadius: radius, aspect: 0.5)
        let wide = StructureScene.cameraDistance(boundingRadius: radius, aspect: 2)

        XCTAssertGreaterThan(tall, square, "a narrow pane needs the camera further back")
        XCTAssertEqual(wide, square, accuracy: 1e-3, "past square, height is the tighter limit")
    }

    /// `radius / sin(halfAngle)` is the tangent distance for a sphere. Using
    /// `tan` instead fits a flat square at the centre plane and clips the near
    /// face of anything round.
    func testCameraDistanceIsTheSphereTangentNotThePlaneFit() {
        let radius: Float = 20
        let distance = StructureScene.cameraDistance(
            boundingRadius: radius, aspect: 1, margin: 1)
        let halfAngle = StructureScene.degreesToRadians(StructureScene.fieldOfViewDegrees) / 2

        XCTAssertEqual(distance, radius / sin(halfAngle), accuracy: 1e-3)
        XCTAssertGreaterThan(distance, radius / tan(halfAngle))
    }

    func testCameraDistanceSurvivesNonsenseAspectRatios() {
        for aspect in [Float.nan, 0, -1, .infinity] {
            let distance = StructureScene.cameraDistance(boundingRadius: 20, aspect: aspect)
            XCTAssertTrue(distance.isFinite, "aspect \(aspect) produced \(distance)")
            XCTAssertGreaterThan(distance, 0)
        }
    }

    /// The camera distance is derived from the bounding radius, so a small
    /// globin and a large chaperone both arrive framed rather than one filling
    /// the screen and the other being a dot.
    func testCameraDistanceScalesWithTheStructure() throws {
        let small = try haemoglobin()
        let large = try PDBParser.parse(
            Fixtures.text("structures/1bab.pdb"), source: .pdbe).structure

        func distance(_ structure: Structure) throws -> Float {
            let scene = StructureScene.make(structure: structure, options: ViewerOptions())
            let camera = try XCTUnwrap(
                scene.rootNode.childNode(
                    withName: StructureScene.NodeName.camera, recursively: false))
            return Float(camera.position.z)
        }

        XCTAssertGreaterThan(try distance(large), try distance(small))
        XCTAssertGreaterThan(try distance(small), small.boundingRadius)
    }

    /// A geometry whose vertex, normal and colour counts disagree renders as
    /// garbage or not at all, and SceneKit says nothing about it.
    func testGeometrySourcesAgreeOnVertexCount() throws {
        let structure = try haemoglobin()
        let scene = StructureScene.make(structure: structure, options: ViewerOptions())
        let root = try XCTUnwrap(
            scene.rootNode.childNode(withName: StructureScene.NodeName.root, recursively: false))
        let tube = try XCTUnwrap(root.childNode(withName: "tube.0", recursively: false))
        let geometry = try XCTUnwrap(tube.geometry)

        let counts = Set(geometry.sources.map(\.vectorCount))
        XCTAssertEqual(counts.count, 1, "sources disagree on vertex count: \(counts)")
        XCTAssertEqual(geometry.sources.count, 3)
        XCTAssertTrue(geometry.sources.contains { $0.semantic == .color })
    }

    /// A single-residue chain has no path to sweep. It must be skipped rather
    /// than producing an empty or malformed geometry.
    func testASingleResidueChainIsSkippedNotCrashed() throws {
        let structure = try MMCIFParser.parse(
            Fixtures.text("structures/edge/cif_label_only.cif"), source: .local
        ).structure
        XCTAssertEqual(structure.residueCount, 1)

        let scene = StructureScene.make(structure: structure, options: ViewerOptions())
        let root = try XCTUnwrap(
            scene.rootNode.childNode(withName: StructureScene.NodeName.root, recursively: false))
        XCTAssertTrue(root.childNodes.isEmpty)
    }
}

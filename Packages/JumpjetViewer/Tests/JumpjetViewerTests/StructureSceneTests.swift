import XCTest
import JumpjetCore
import JumpjetParse
import SceneKit

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

    /// The pivot centres the structure so the camera orbits its middle. Without
    /// it, a crystal structure sitting tens of angstroms from the origin swings
    /// around a point outside itself and feels broken to drag.
    func testTheStructureIsPivotedOnItsOwnCentroid() throws {
        let structure = try PDBParser.parse(
            Fixtures.text("structures/1bab.pdb"), source: .pdbe).structure
        let centroid = structure.centroid
        XCTAssertGreaterThan(abs(centroid.x) + abs(centroid.y) + abs(centroid.z), 5)

        let scene = StructureScene.make(structure: structure, options: ViewerOptions())
        let root = try XCTUnwrap(
            scene.rootNode.childNode(withName: StructureScene.NodeName.root, recursively: false))
        XCTAssertEqual(Float(root.pivot.m41), centroid.x, accuracy: 1e-3)
        XCTAssertEqual(Float(root.pivot.m42), centroid.y, accuracy: 1e-3)
        XCTAssertEqual(Float(root.pivot.m43), centroid.z, accuracy: 1e-3)
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

    /// The camera distance is derived from the bounding radius, so a small
    /// globin and a large kinase both arrive framed rather than one filling the
    /// screen and the other being a dot.
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

import XCTest
import JumpjetCore

@testable import JumpjetFetch

final class StructureServiceTests: XCTestCase {

    private func makeService(
        transport: RecordedTransport, cache: ModelCache, at date: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> StructureService {
        StructureService(transport: transport, cache: cache, now: { date })
    }

    // MARK: - The happy path

    func testAlphaFoldIsPreferredAndTheModelParses() async throws {
        let transport = Recorded.complete()
        let service = makeService(transport: transport, cache: makeTemporaryCache(self))

        let model = try await service.load("P69905")

        XCTAssertEqual(model.structure.residueCount, 142)
        XCTAssertEqual(model.structure.source, .alphaFold)
        XCTAssertEqual(model.provenance.version, "v6")
        XCTAssertEqual(model.provenance.detail, "AlphaFold DB v6")
        XCTAssertFalse(model.provenance.fromCache)
        XCTAssertEqual(model.entry?.proteinName, "Hemoglobin subunit alpha")

        // PDBe must not have been asked at all: it is the fallback.
        let pdbeCalls = await transport.requests(containing: "pdbe")
        XCTAssertEqual(pdbeCalls, 0)
    }

    func testProgressPhasesAreReportedInOrder() async throws {
        let service = makeService(transport: Recorded.complete(), cache: makeTemporaryCache(self))
        let collector = PhaseCollector()

        _ = try await service.load("P69905") { phase in
            collector.append(phase)
        }

        let phases = collector.phases
        XCTAssertEqual(phases.first, .validating)
        XCTAssertTrue(phases.contains(.readingMetadata))
        XCTAssertTrue(phases.contains(.downloading(source: .alphaFold)))
        XCTAssertTrue(phases.contains(.parsing))
        XCTAssertEqual(phases.last, .done)
    }

    // MARK: - Fallback

    func testPDBeTakesOverWhenAlphaFoldHasNoModel() async throws {
        let transport = Recorded.complete().replacing(Recorded.alphaFoldAPI, with: .status(404))
        let service = makeService(transport: transport, cache: makeTemporaryCache(self))

        let model = try await service.load("P69905")

        XCTAssertEqual(model.structure.source, .pdbe)
        XCTAssertEqual(model.provenance.entryID, "1BAB")
        XCTAssertTrue(model.provenance.detail.contains("X-ray diffraction"))
        XCTAssertTrue(model.provenance.detail.contains("1.50 A"))
        XCTAssertEqual(model.structure.residueCount, 576)
    }

    /// Neither source has a model. That is a real answer about the accession
    /// and must not be papered over.
    func testNoStructureAnywhereIsItsOwnError() async {
        let transport = Recorded.complete()
            .replacing(Recorded.alphaFoldAPI, with: .status(404))
            .replacing(Recorded.pdbeAPI, with: .status(404))
        let service = makeService(transport: transport, cache: makeTemporaryCache(self))

        do {
            _ = try await service.load("P69905")
            XCTFail("expected noStructureAvailable")
        } catch {
            XCTAssertEqual(error as? JumpjetError, .noStructureAvailable(accession: "P69905"))
        }
    }

    func testMalformedAccessionFailsBeforeAnyRequest() async {
        let transport = Recorded.complete()
        let service = makeService(transport: transport, cache: makeTemporaryCache(self))

        do {
            _ = try await service.load("not-an-accession")
            XCTFail("expected malformedAccession")
        } catch {
            XCTAssertEqual(error as? JumpjetError, .malformedAccession("not-an-accession"))
        }
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty, "a typo should cost no network at all")
    }

    // MARK: - Cache

    /// The build plan's offline relaunch: fetch once with a network, then fetch
    /// again with none and still get the structure.
    func testOfflineRelaunchServesFromCache() async throws {
        let cache = makeTemporaryCache(self)
        _ = try await makeService(transport: Recorded.complete(), cache: cache).load("P69905")

        let offline = Recorded.offline()
        let model = try await makeService(transport: offline, cache: cache).load("P69905")

        XCTAssertEqual(model.structure.residueCount, 142)
        XCTAssertTrue(model.provenance.fromCache)
        XCTAssertEqual(model.provenance.detail, "AlphaFold DB v6")
        // The UniProt metadata was cached with the model, so the HUD still has
        // a protein name offline rather than showing a bare accession.
        XCTAssertEqual(model.entry?.proteinName, "Hemoglobin subunit alpha")
    }

    func testOfflineWithAnEmptyCacheSaysSo() async {
        let offline = Recorded.offline()
        let service = makeService(transport: offline, cache: makeTemporaryCache(self))

        do {
            _ = try await service.load("P69905")
            XCTFail("expected offlineAndUncached")
        } catch {
            XCTAssertEqual(error as? JumpjetError, .offlineAndUncached(accession: "P69905"))
        }
    }

    /// A second online load must not re-download the coordinates.
    func testASecondLoadReusesTheCachedCoordinates() async throws {
        let cache = makeTemporaryCache(self)
        _ = try await makeService(transport: Recorded.complete(), cache: cache).load("P69905")

        let transport = Recorded.complete()
        let model = try await makeService(transport: transport, cache: cache).load("P69905")

        XCTAssertTrue(model.provenance.fromCache)
        let downloads = await transport.requests(containing: Recorded.alphaFoldCIF)
        XCTAssertEqual(downloads, 0, "the coordinates should have come off disk")
        // The API is still asked, because that is the only way to learn whether
        // the cached version is still current.
        let apiCalls = await transport.requests(containing: Recorded.alphaFoldAPI)
        XCTAssertEqual(apiCalls, 1)
    }

    /// A new AlphaFold release must be a cache miss. Keying on the accession
    /// alone would serve a superseded prediction for as long as the app is
    /// installed, and say nothing about it.
    func testANewModelVersionBustsTheCache() async throws {
        let cache = makeTemporaryCache(self)
        _ = try await makeService(transport: Recorded.complete(), cache: cache).load("P69905")

        let bumped = """
            [{"entryId": "AF-P69905-F1", "uniprotAccession": "P69905",
              "uniprotDescription": "Hemoglobin subunit alpha", "latestVersion": 7,
              "cifUrl": "https://alphafold.ebi.ac.uk/files/AF-P69905-F1-model_v7.cif"}]
            """
        let transport = Recorded.complete()
            .replacing(Recorded.alphaFoldAPI, with: .body(bumped))
            .replacing(
                "AF-P69905-F1-model_v7.cif",
                with: .fixture("structures/AF-P69905-F1-model_v6.cif"))

        let model = try await makeService(transport: transport, cache: cache).load("P69905")

        XCTAssertFalse(model.provenance.fromCache)
        XCTAssertEqual(model.provenance.version, "v7")
        let downloads = await transport.requests(containing: "model_v7.cif")
        XCTAssertEqual(downloads, 1)
    }

    /// A structure that is too large is too large whether it arrived over the
    /// network or off the disk, so that error must not be rescued by a cache
    /// fallback that then serves the same oversized file.
    func testResidueLimitIsNotRescuedByTheCache() async {
        let transport = Recorded.complete()
        let service = StructureService(
            transport: transport, cache: makeTemporaryCache(self), residueLimit: 50)

        do {
            _ = try await service.load("P69905")
            XCTFail("expected tooLarge")
        } catch {
            XCTAssertEqual(error as? JumpjetError, .tooLarge(residues: 142, limit: 50))
        }
    }

    /// A server outage falls back to whatever is cached rather than failing.
    func testServerOutageFallsBackToTheCache() async throws {
        let cache = makeTemporaryCache(self)
        _ = try await makeService(transport: Recorded.complete(), cache: cache).load("P69905")

        let broken = Recorded.complete()
            .replacing(Recorded.alphaFoldAPI, with: .status(503))
            .replacing(Recorded.pdbeAPI, with: .status(503))
        let model = try await makeService(transport: broken, cache: cache).load("P69905")

        XCTAssertTrue(model.provenance.fromCache)
        XCTAssertEqual(model.structure.residueCount, 142)
    }
}

/// Collects progress phases from the loader's callback.
private final class PhaseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LoadPhase] = []

    func append(_ phase: LoadPhase) {
        lock.lock()
        storage.append(phase)
        lock.unlock()
    }

    var phases: [LoadPhase] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

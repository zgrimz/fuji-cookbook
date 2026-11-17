import XCTest
@testable import FujiCookbook

/// The refusal an operation threw, or nil when it ran.
@MainActor
func busyRefusal<T>(_ operation: () async throws(CameraBusy) -> T) async -> CameraBusy? {
    do throws(CameraBusy) {
        _ = try await operation()
        return nil
    } catch {
        return error
    }
}

/// Every gated entry point, called while another operation holds the gate: each answers with the
/// gate's typed refusal, naming the holder, and none of them reaches the camera.
///
/// The gate is held by running the call inside `gate.run`, which is not reentrant, so nothing here
/// depends on two tasks racing.
@MainActor
final class OperationGateRefusalTests: XCTestCase {

    private let holder = "held by the test"
    private var busy: CameraBusy { CameraBusy(runningOperation: holder) }

    private func connected() async -> (CameraServices, MockCameraTransport) {
        let transport = MockCameraTransport(faults: MockCameraFaults(isInstant: true))
        let camera = CameraServices()
        await camera.connector.connectDemo(using: transport)
        return (camera, transport)
    }

    /// Runs `operation` with the gate held and asserts the camera saw no transaction while it ran.
    private func whileHeld<T>(_ camera: CameraServices, _ transport: MockCameraTransport,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ operation: () async -> T) async throws -> T {
        let before = await transport.transactionCount
        let result = try await camera.gate.run(holder) { await operation() }
        let after = await transport.transactionCount
        XCTAssertEqual(after, before, "a refused operation sends the camera nothing", file: file, line: line)
        return result
    }

    func testTheGateThrowsTheOperationThatHoldsIt() async throws {
        let gate = CameraOperationGate()
        let refusal = try await gate.run("outer") {
            await busyRefusal { () async throws(CameraBusy) in try await gate.run("inner") { 1 } }
        }
        XCTAssertEqual(refusal, CameraBusy(runningOperation: "outer"))
        XCTAssertNil(gate.runningOperation, "the outer run released the gate")
    }

    func testARefusalNamesTheOperationHoldingTheCamera() {
        let message = CameraBusy(runningOperation: "push to C3").localizedDescription
        XCTAssertTrue(message.contains("push to C3"), message)
        XCTAssertTrue(message.contains("nothing was sent"), message)
    }

    // MARK: Entry points that answered with a sentinel now throw

    func testARefusedSlotRefreshThrows() async throws {
        let (camera, transport) = await connected()
        let refusal = try await whileHeld(camera, transport) {
            await busyRefusal { () async throws(CameraBusy) in try await camera.slotReader.requestRefresh() }
        }
        XCTAssertEqual(refusal, busy)
    }

    func testARefusedPropertyReportThrows() async throws {
        let (camera, transport) = await connected()
        let refusal = try await whileHeld(camera, transport) {
            await busyRefusal { () async throws(CameraBusy) in try await camera.diagnostics.probeProperties(slot: 2) }
        }
        XCTAssertEqual(refusal, busy)
    }

    func testARefusedWriteProbeThrows() async throws {
        let (camera, transport) = await connected()
        let refusal = try await whileHeld(camera, transport) {
            await busyRefusal { () async throws(CameraBusy) in
                try await camera.diagnostics.probeWriteValues(slot: 2, property: .grain, candidates: [1, 2])
            }
        }
        XCTAssertEqual(refusal, busy)
    }

    func testARefusedProfileHarvestThrows() async throws {
        let (camera, transport) = await connected()
        let refusal = try await whileHeld(camera, transport) {
            await busyRefusal { () async throws(CameraBusy) in
                try await camera.conversion.harvestConversionProfile(raf: RAFFixture.raf())
            }
        }
        XCTAssertEqual(refusal, busy)
    }

    func testARefusedConversionDynamicRangeProbeThrows() async throws {
        let (camera, transport) = await connected()
        let refusal = try await whileHeld(camera, transport) {
            await busyRefusal { () async throws(CameraBusy) in
                try await camera.conversion.probeConversionDynamicRange(raf: RAFFixture.raf(), filename: "probe.RAF")
            }
        }
        XCTAssertEqual(refusal, busy)
    }

    // MARK: Entry points whose results carry the refusal

    func testARefusedPushCarriesTheRefusal() async throws {
        let (camera, transport) = await connected()
        let result = try await whileHeld(camera, transport) {
            await camera.slotWriter.push(settings: RecipeSettings(filmSimulation: .classicNeg), name: "A", toSlot: 3)
        }
        XCTAssertEqual(result.refusedBy, busy)
        XCTAssertEqual(result.slot, 3)
        XCTAssertEqual(result.outcome, .notWritten)
    }

    func testARefusedRestoreCarriesTheRefusal() async throws {
        let (camera, transport) = await connected()
        let saved = try XCTUnwrap(camera.slotReader.slots.first { $0.index == 2 }?.rawProperties)
        let result = try await whileHeld(camera, transport) {
            await camera.slotWriter.restore(saved, name: "B", toSlot: 2)
        }
        XCTAssertEqual(result.refusedBy, busy)
        XCTAssertEqual(result.outcome, .notWritten)
    }

    /// One refused result per slot it was asked to write: an empty list would read as a batch of
    /// nothing.
    func testARefusedBatchPushReportsEverySlotAsRefused() async throws {
        let (camera, transport) = await connected()
        let settings = RecipeSettings(filmSimulation: .classicNeg)
        let results = try await whileHeld(camera, transport) {
            await camera.slotWriter.pushBatch([(settings: settings, name: "A", slot: 1),
                                               (settings: settings, name: "B", slot: 4)])
        }
        XCTAssertEqual(results.map(\.slot), [1, 4])
        XCTAssertEqual(results.map(\.refusedBy), [busy, busy])
        XCTAssertEqual(results.map(\.outcome), [.notWritten, .notWritten])
    }

    func testRefusedDevelopsAreRecordedAsBusy() async throws {
        let (camera, transport) = await connected()
        let (single, batch, matrix) = try await whileHeld(camera, transport) {
            let single = await camera.conversion.cook(raf: RAFFixture.raf(), filename: "one.RAF", settings: .neutral)
            let batch = await camera.conversion.cookBatch(
                [CookItem(raf: .inMemory(RAFFixture.raf(), filename: "two.RAF"), settings: .neutral)])
            let matrix = await camera.conversion.cookMatrix(
                rafs: [.inMemory(RAFFixture.raf(), filename: "three.RAF")],
                recipes: [(settings: .neutral, displayName: "Neutral", filmSimulation: nil)])
            return (single, batch, matrix)
        }
        XCTAssertEqual(single.evidence.failureReason, "camera_busy")
        XCTAssertEqual(batch.map(\.evidence.failureReason), ["camera_busy"])
        XCTAssertEqual(matrix.flatMap(\.versions).map(\.result.evidence.failureReason), ["camera_busy"])
    }

    /// The control: a result from a write that ran carries no refusal.
    func testAPushThatRanCarriesNoRefusal() async {
        let (camera, _) = await connected()
        let result = await camera.slotWriter.push(settings: RecipeSettings(filmSimulation: .classicNeg),
                                                  name: "A", toSlot: 1)
        XCTAssertNil(result.refusedBy)
        XCTAssertNotEqual(result.outcome, .notWritten, result.errorMessage ?? "no message")
    }
}

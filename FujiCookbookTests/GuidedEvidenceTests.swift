import XCTest
@testable import FujiCookbook

@MainActor
final class GuidedEvidenceTests: XCTestCase {
    func testReconnectEvidenceSurvivesViewRecreationAndSameSecondReconnect() {
        let instant = Date(timeIntervalSince1970: 1_790_000_000)
        var trial = GuidedTestSession.PushTrial(recipe: "priority", recipeName: "CT Priority", slot: 1)
        trial.connectionStartedAt = instant
        trial.connectionID = "before"
        XCTAssertEqual(GuidedTestFlow.connectionChanged(for: trial, currentID: "after",
            currentStartedAt: instant, observedDisconnect: false), true)
        XCTAssertEqual(GuidedTestFlow.connectionChanged(for: trial, currentID: "before",
            currentStartedAt: instant, observedDisconnect: false), false)
        trial.connectionID = nil
        XCTAssertNil(GuidedTestFlow.connectionChanged(for: trial, currentID: nil,
            currentStartedAt: instant, observedDisconnect: false))
        XCTAssertEqual(GuidedTestFlow.connectionChanged(for: trial, currentID: nil,
            currentStartedAt: instant, observedDisconnect: true), true)
    }

    func testSuccessfulPersistenceExportsActualReadingsAndConnectionIdentity() throws {
        let code = FujiPTP.PresetProp.filmSimulation.rawValue
        let bytes = FujiEncoding.packU16(11)
        let readAt = Date(timeIntervalSince1970: 1_790_000_010)
        var trial = GuidedTestSession.PushTrial(recipe: "colour", recipeName: "CT Colour", slot: 1)
        trial.wrote = [PTPHex.code(code): PTPHex.bytes(bytes)]
        trial.connectionID = "write-connection"
        let slot = CameraSlot(index: 1, label: "C1", name: "CT Colour", isOccupied: true,
            settings: nil, rawProperties: [code: bytes], unsupportedFields: [:])
        trial.persistence = GuidedTestFlow.persistence(trial: trial, slot: slot, nameApplied: "CT Colour",
            connectionChanged: true, readAt: readAt, connectionStartedAt: readAt,
            connectionID: "restart-connection")
        var session = GuidedTestSession.beginContinuous()
        session.writePass = .init(trials: [trial])
        let projected = CameraCompatibilityReport.GuidedTestRecord(session: session)
        let persisted = try XCTUnwrap(projected.writePass?.trials?.first?.persistence)
        XCTAssertEqual(persisted.evidenceState, "passed")
        XCTAssertEqual(persisted.expected, trial.wrote)
        XCTAssertEqual(persisted.readback, trial.wrote)
        XCTAssertEqual(persisted.readAt, readAt)
        XCTAssertEqual(persisted.nameReadBack, "CT Colour")
        XCTAssertEqual(persisted.connectionID, "restart-connection")
        XCTAssertEqual(projected.writePass?.trials?.first?.connectionID, "write-connection")
        let failed = GuidedTestFlow.persistence(trial: trial, slot: slot, nameApplied: "CT Colour",
            freshReadSucceeded: false, readAt: readAt)
        XCTAssertNil(failed.readback, "A cached slot is not evidence of a failed fresh read")
        XCTAssertNil(failed.readAt)
        var incompleteSlot = slot
        incompleteSlot.rawProperties = [:]
        let incomplete = GuidedTestFlow.persistence(trial: trial, slot: incompleteSlot,
            nameApplied: "CT Colour")
        XCTAssertEqual(incomplete.settingsState, .couldNotVerify,
                       "A missing value cannot establish that a setting changed")
    }

    func testReadEvidenceIsRetainedAcrossLaterCameraWrites() async throws {
        var faults = MockCameraFaults()
        faults.isInstant = true
        let camera = CameraServices()
        await camera.connector.connectDemo(using: MockCameraTransport(faults: faults))
        defer { CameraReportStore.deleteLatest() }
        var session = GuidedTestSession.beginContinuous(step: .readSlots)
        session.adopt(camera: GuidedTestRunner.facts(camera))
        session.propertyReport = await GuidedTestRunner.runPropertyReport(camera, slot: 1)
        GuidedTestRunner.captureReadEvidence(camera, session: &session)
        let initial = try XCTUnwrap(session.initialSlots)
        let sweep = try XCTUnwrap(session.propertySweep)
        XCTAssertFalse(initial.reads.isEmpty)
        XCTAssertNotNil(sweep.capturedAt)
        XCTAssertEqual(session.propertyReport?.evidenceID, sweep.evidenceID)
        let deniedRead = try await camera.gate.run("another operation") { () async -> Result<WalkResult?, CameraBusy> in
            do throws(CameraBusy) {
                return .success(try await camera.slotReader.requestRefresh())
            } catch {
                return .failure(error)
            }
        }
        // The outer run holds the gate, so the inner refresh is refused.
        XCTAssertEqual(deniedRead, .failure(CameraBusy(runningOperation: "another operation")),
                       "Refused reads must not verify cached values")
        session.propertyReport = try await camera.gate.run("another operation") {
            await GuidedTestRunner.runPropertyReport(camera, slot: 1)
        }
        GuidedTestRunner.captureReadEvidence(camera, session: &session)
        XCTAssertNotEqual(session.propertyReport?.evidenceID, sweep.evidenceID,
                          "A refused new attempt must not acquire the previous sweep's identity")
        XCTAssertEqual(session.propertySweep, sweep, "Earlier evidence remains separately retained")
        _ = await camera.slotWriter.push(settings: .init(filmSimulation: .acros), name: "After", toSlot: 1)
        var trial = GuidedTestSession.PushTrial(recipe: "mono", recipeName: "CT Mono", slot: 1)
        trial.pushedAt = CameraCompatibilityReport.timestamp()
        session.writePass = .init(trials: [trial])
        GuidedTestRunner.captureReadEvidence(camera, session: &session)
        XCTAssertEqual(session.initialSlots, initial)
        XCTAssertEqual(session.propertySweep, sweep)
        let projection = CameraCompatibilityReport.GuidedTestRecord(session: session)
        XCTAssertEqual(projection.initialSlots, initial)
        XCTAssertEqual(projection.propertySweep, sweep)
        await camera.connector.disconnect()
    }

    func testLegacyEvidenceDoesNotAcquireInventedTimestampsOrIdentity() throws {
        let probe = try JSONDecoder().decode(GuidedTestSession.ProbeOutcome.self,
            from: Data(#"{"state":"ran","count":26}"#.utf8))
        XCTAssertNil(probe.capturedAt)
        XCTAssertNil(probe.evidenceID)
        let outcome = try JSONDecoder().decode(GuidedTestSession.RestoreOutcome.self,
            from: Data(#"{"slot":1,"outcome":"partiallyApplied"}"#.utf8))
        XCTAssertNil(outcome.verification)
        XCTAssertEqual(outcome.outcome, .partiallyApplied)
    }
}

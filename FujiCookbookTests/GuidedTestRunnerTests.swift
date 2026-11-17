import XCTest
@testable import FujiCookbook

/// The guided test driving a real camera session, on the mock transport.
///
/// The harness follows `PushAuditTests`: assert what the *app* concluded, and separately what the
/// camera physically holds, because the whole point of the guided test is the places those two
/// diverge.
///
/// Camera facts in these tests are from zgrimz/fujifilm-ptp-reference:
/// `docs/01-transport.md#getdevicepropdesc-is-usually-refused`, `docs/04-custom-slots.md#iso-gating`,
/// `docs/04-custom-slots.md#values-a-bank-remembers-while-they-are-inactive`, and
/// `docs/04-custom-slots.md#restoring-a-bank`.
@MainActor
final class GuidedTestRunnerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CameraReportStore.deleteLatest()
        GuidedTestStore.deleteAll()
        GuidedRecoveryStore.deleteAll()
    }

    override func tearDown() {
        GuidedTestStore.deleteAll()
        GuidedRecoveryStore.deleteAll()
        super.tearDown()
    }

    private func connect(_ faults: MockCameraFaults = MockCameraFaults())
        async -> (CameraServices, MockCameraTransport) {
        var faults = faults
        faults.isInstant = true
        let transport = MockCameraTransport(faults: faults)
        let manager = CameraServices()
        await manager.connector.connectDemo(using: transport)
        return (manager, transport)
    }

    /// What the camera physically holds, read straight off the transport, bypassing everything the
    /// app believes.
    private func cameraHolds(_ transport: MockCameraTransport, slot: Int,
                             _ prop: FujiPTP.PresetProp) async -> Int? {
        await transport.storedProperty(prop.rawValue, slot: slot).flatMap(FujiEncoding.decodeInt16)
    }

    private func preparedSession(_ camera: CameraServices) -> GuidedTestSession {
        var session = GuidedTestSession.beginContinuous(step: .push)
        session.adopt(camera: GuidedTestRunner.facts(camera))
        session.identity = .init(confirmed: true)
        session.propertyReport = .init(state: .ran, count: 24)
        if let slot = camera.slotReader.slots.first(where: \.isOccupied) {
            var comparison = GuidedTestFlow.comparison(for: slot, model: camera.session.model)
            comparison.confirmedMatching = true
            comparison.checkedAt = CameraCompatibilityReport.timestamp()
            session.slotComparisons = [comparison]
        }
        session.writePass = .init(consentAt: CameraCompatibilityReport.timestamp(), dialConfirmed: true)
        session.grainConsentAt = CameraCompatibilityReport.timestamp()
        if camera.session.model?.id == "X-M5" { session.setStillBankConfirmation(1, confirmed: true) }
        XCTAssertNil(GuidedTestRunner.prepareRecovery(camera, session: &session))
        // Existing recipe-write tests start after the required grain check. Tests of the check
        // itself replace this fixture outcome with the real operation result.
        session.grainProbe = .init(state: .ran, slot: 1, count: CameraDiagnostics.grainProbeCandidates.count)
        return session
    }

    // MARK: The gate

    func testTheGateNamesWhatTheTesterShouldBeOffered() {
        XCTAssertEqual(GuidedTestRunner.gate(status: .connected, isConnected: true), .ready)
        XCTAssertEqual(GuidedTestRunner.gate(status: .connected, isConnected: false), .disconnected)
        XCTAssertEqual(GuidedTestRunner.gate(status: .disconnected, isConnected: false), .disconnected)
        XCTAssertEqual(GuidedTestRunner.gate(status: .working("Reading slot C3…"), isConnected: true),
                       .busy("Reading slot C3…"))
        XCTAssertEqual(GuidedTestRunner.gate(status: .failed("The camera disconnected."), isConnected: false),
                       .lost("The camera disconnected."))
    }

    /// Recovery publishes itself through the same status as any other operation. Telling them apart
    /// is the difference between "wait a moment" and "check your cable".
    func testRecoveryIsNotReportedAsAnOperation() {
        XCTAssertEqual(GuidedTestRunner.gate(status: .working("Reconnecting…"), isConnected: true,
                                             isRecovering: true),
                       .reconnecting)
        // The words are not the signal. An expected removal's status says something else entirely,
        // and it is still a recovery.
        XCTAssertEqual(GuidedTestRunner.gate(status: .working("Waiting for the camera to come back…"),
                                             isConnected: true, isRecovering: true),
                       .reconnecting)
        // And a status that merely *mentions* reconnecting, with no recovery running, is what it
        // says it is: an operation.
        XCTAssertEqual(GuidedTestRunner.gate(status: .working("Reconnecting…"), isConnected: true,
                                             isRecovering: false),
                       .busy("Reconnecting…"))
    }

    // MARK: Reading

    func testTheSlotsTheConnectAlreadyReadAreNotReadAgain() async {
        let (m, t) = await connect()
        let before = await t.totalWriteCount
        XCTAssertNotNil(m.slotReader.probedSlotCount)

        let gate = await GuidedTestRunner.ensureSlots(m)
        XCTAssertEqual(gate, .ready)
        let after = await t.totalWriteCount
        XCTAssertEqual(after, before, "a slot select is a write, and this step had nothing to read")
    }

    /// A body with no slot protocol has an empty `slots` permanently and never finishes a walk, so
    /// keying this step off either would sweep the whole property set every time it was shown.
    func testABodyWithNoSlotsIsNotSweptOverAndOverAgain() async {
        let (m, t) = await connect(.noSlotProtocolBody)
        XCTAssertTrue(m.slotReader.slots.isEmpty)
        XCTAssertNil(m.slotReader.probedSlotCount, "swept, not walked")
        let sweepBefore = m.reports.report?.propertySweep?.evidenceID
        XCTAssertNotNil(sweepBefore, "the connect swept the body")

        _ = await GuidedTestRunner.ensureSlots(m)
        _ = await GuidedTestRunner.ensureSlots(m)
        // Each sweep stamps a fresh evidence ID. The trace's transaction count can't show a second
        // sweep: it reads the same as before one ran.
        XCTAssertEqual(m.reports.report?.propertySweep?.evidenceID, sweepBefore, "nothing was re-read")
        let writes = await t.totalWriteCount
        XCTAssertEqual(writes, 0)
    }

    // MARK: The diagnostics the flow runs for the tester

    func testThePropertyReportAndGrainProbeRunWithoutDiagnosticMode() async {
        // The flow runs both on the tester's behalf; the Diagnostic Mode toggle only ever hid the
        // screens, and a tester was never going to find them.
        let previous = UserDefaults.standard.object(forKey: DiagnosticMode.key) as? Bool
        addTeardownBlock {
            if let previous {
                UserDefaults.standard.set(previous, forKey: DiagnosticMode.key)
            } else {
                UserDefaults.standard.removeObject(forKey: DiagnosticMode.key)
            }
        }
        UserDefaults.standard.set(false, forKey: DiagnosticMode.key)
        let (m, _) = await connect()

        let property = await GuidedTestRunner.runPropertyReport(m, slot: 1)
        XCTAssertEqual(property.state, .ran)
        XCTAssertEqual(property.slot, 1)
        XCTAssertEqual(property.readOnly, false, "a writable body gets the slot select")
        XCTAssertNotNil(m.reports.report?.propertySweep)

        var session = preparedSession(m)
        session.grainProbe = nil
        XCTAssertNotNil(GuidedTestRunner.mutationBlockReason(m, session: session, slot: 1, kind: .recipeWrite))
        let grain = await GuidedTestRunner.runGrainProbe(m, slot: 1, session: session)
        XCTAssertEqual(grain.state, .ran)
        XCTAssertEqual(grain.count, CameraDiagnostics.grainProbeCandidates.count)
        XCTAssertTrue(m.reports.report?.notes.contains { $0.hasPrefix("write probe Grain") } ?? false,
                      "the finding outlives the step that produced it")
        session.grainProbe = grain
        XCTAssertNil(GuidedTestRunner.mutationBlockReason(m, session: session, slot: 1, kind: .recipeWrite))
        XCTAssertTrue(GuidedRecoveryStore.load(sessionID: session.id)?.unresolvedSlots.isEmpty == true)
    }

    func testInterruptedGrainCheckKeepsRecoveryPendingAndBlocksRecipeWrites() async {
        var faults = MockCameraFaults()
        faults.dropSessionAfterWrites = 3
        let (camera, transport) = await connect(faults)
        var session = preparedSession(camera)
        session.grainProbe = await GuidedTestRunner.runGrainProbe(camera, slot: 1, session: session)
        XCTAssertEqual(session.grainProbe?.state, .failed)
        XCTAssertEqual(GuidedRecoveryStore.load(sessionID: session.id)?.unresolvedSlots, [1])
        let writesBefore = await transport.totalWriteCount
        let recipe = GuidedTestRecipes.recipe(id: "priority", for: camera.session.model!)!
        let blocked = await GuidedTestRunner.runPush(camera, recipe: recipe, slot: 1, session: session)
        XCTAssertEqual(blocked.trial.outcome, .notWritten)
        let writesAfter = await transport.totalWriteCount
        XCTAssertEqual(writesBefore, writesAfter)
    }

    /// The cleanup verdict is read from the probe's own notes, so the words have to be the ones the
    /// probe writes today: the check matched "restore FAILED" after that note had been renamed, and
    /// a refused restore went unreported until the slot re-read caught it.
    func testARefusedRestoreFailsTheGrainCheckInTheProbesOwnWords() async {
        var faults = MockCameraFaults()
        // The candidates are preset writes 1 to 10; the first restore write is the eleventh.
        faults.rejectWriteAtIndex = CameraDiagnostics.grainProbeCandidates.count + 1
        let (camera, _) = await connect(faults)
        var session = preparedSession(camera)
        session.grainProbe = nil
        let grain = await GuidedTestRunner.runGrainProbe(camera, slot: 1, session: session)
        XCTAssertEqual(grain.state, .failed)
        XCTAssertTrue(grain.detail?.contains("restore refused") == true, grain.detail ?? "nil")
        XCTAssertEqual(GuidedRecoveryStore.load(sessionID: session.id)?.unresolvedSlots, [1])
    }

    /// The probe writes real values. A body the app doesn't write to must not be asked to consent to
    /// something that cannot happen — and the refusal is itself a fact worth recording.
    func testABlockedBodyRecordsTheGrainProbeAsNotApplicableAndWritesNothing() async {
        // What this asserts is the gate, so the fixture follows whichever body the registry blocks
        // rather than pinning one.
        let (m, t) = await connect(.noSlotProtocolBody)
        XCTAssertEqual(m.session.model?.id, "X-T20")
        XCTAssertFalse(m.session.connected?.isWritable ?? true)
        let before = await t.totalWriteCount

        let grain = await GuidedTestRunner.runGrainProbe(m, slot: 1)
        XCTAssertEqual(grain.state, .notWritable)
        let after = await t.totalWriteCount
        XCTAssertEqual(after, before, "not one byte")
    }

    /// On a body the app won't write to, the sweep degrades to reading whichever slot the camera
    /// already had — a weaker diagnostic, and the report says which it was.
    func testAnUnrecognizedBodyGetsTheReadOnlySweep() async {
        let (m, t) = await connect(.unknownBody)
        let property = await GuidedTestRunner.runPropertyReport(m, slot: 3)

        XCTAssertEqual(property.state, .ran)
        XCTAssertEqual(property.readOnly, true)
        XCTAssertEqual(property.slot, 1, "the slot it actually read, not the one it was asked for")
        let writes = await t.totalWriteCount
        XCTAssertEqual(writes, 0)
    }

    /// Two camera operations at once is refused, not queued (`CameraProbeGatingTests` covers the
    /// gate itself). What matters here is that the flow checks before it calls, and records a
    /// refusal as the retryable state it is rather than as something the body did.
    func testAnOperationAlreadyInFlightIsReportedAsRefusedRatherThanAsAFinding() async {
        let (m, t) = await connect()
        let before = await t.totalWriteCount
        m.session.setStatus(.working("Reading slot C3…"))

        let property = await GuidedTestRunner.runPropertyReport(m, slot: 2)
        XCTAssertEqual(property.state, .refused)
        XCTAssertNil(property.count, "nothing was measured, so nothing is claimed")

        let grain = await GuidedTestRunner.runGrainProbe(m, slot: 2)
        XCTAssertEqual(grain.state, .refused)
        let after = await t.totalWriteCount
        XCTAssertEqual(after, before, "and neither one reached the camera")
    }

    /// The operation gate's own refusal, with the session still reading as connected, so the check
    /// before the call passes. The steps take the refusal from the error the gate throws, not from
    /// an empty result.
    func testARefusalByTheOperationGateIsRecordedAsRefused() async throws {
        let (m, t) = await connect()
        var session = preparedSession(m)
        session.grainProbe = nil
        let before = await t.transactionCount

        let (property, grain) = try await m.gate.run("another operation") {
            (await GuidedTestRunner.runPropertyReport(m, slot: 2),
             await GuidedTestRunner.runGrainProbe(m, slot: 1, session: session))
        }
        XCTAssertEqual(property.state, .refused)
        XCTAssertNil(property.count, "nothing was measured, so nothing is claimed")
        XCTAssertNil(property.evidenceID, "a refused report has no sweep of its own")
        XCTAssertEqual(grain.state, .refused, grain.detail ?? "nil")
        let after = await t.transactionCount
        XCTAssertEqual(after, before, "and neither one reached the camera")
    }

    /// A slot read the operation gate refused has read nothing, so the step is not ready.
    func testASlotReadRefusedByTheOperationGateLeavesTheStepBusy() async throws {
        let (m, _) = await connect()
        m.slotReader.discardProbedSlotCount()
        XCTAssertFalse(m.slotReader.hasRead, "precondition: the step has slots to read")

        let gate = try await m.gate.run("another operation") { await GuidedTestRunner.ensureSlots(m) }
        XCTAssertEqual(gate, .busy("Another camera operation is still running."))
    }

    /// A push the operation gate refused wrote nothing, so the trial carries no push time: the
    /// recipe stays retryable and the slot is not counted among those written.
    func testAPushRefusedByTheOperationGateIsNotFiledAsAnAttempt() async throws {
        let (m, t) = await connect()
        let session = preparedSession(m)
        let recipe = try XCTUnwrap(GuidedTestRecipes.recipe(id: "priority", for: try XCTUnwrap(m.session.model)))
        let before = await t.transactionCount

        let (trial, result) = try await m.gate.run("another operation") {
            await GuidedTestRunner.runPush(m, recipe: recipe, slot: 1, session: session)
        }
        XCTAssertNil(trial.pushedAt)
        XCTAssertNil(trial.connectionID)
        XCTAssertEqual(trial.outcome, .notWritten)
        XCTAssertEqual(trial.refusalReason, CameraBusy(runningOperation: "another operation").localizedDescription)
        XCTAssertNil(result, "no per-field table for a push that never started")
        let after = await t.transactionCount
        XCTAssertEqual(after, before)
    }

    func testAProfileHarvestRefusedByTheOperationGateIsRecordedAsRefused() async throws {
        let (m, t) = await connect(MockCameraFaults(productName: "FUJIFILM GFX 100", firmwareVersion: nil,
                                                    profileNeedsUpload: true))
        XCTAssertTrue(m.conversion.canHarvestProfile, "precondition: a body the harvest is for")
        let before = await t.transactionCount

        let harvest = try await m.gate.run("another operation") {
            await GuidedTestRunner.runProfileHarvest(m, raf: RAFFixture.raf())
        }
        XCTAssertEqual(harvest.state, .refused, harvest.detail ?? "nil")
        let after = await t.transactionCount
        XCTAssertEqual(after, before)
    }

    /// A property report that read nothing because its slot select was refused is a failed reading,
    /// not a busy camera. The connect walk on this body stops at its own refused select, so the
    /// status is set back to connected for the report to be attempted at all.
    func testAPropertyReportWhoseSelectWasRefusedIsAFailure() async {
        let (m, _) = await connect(.busyXM5)
        m.session.setStatus(.connected)
        XCTAssertEqual(GuidedTestRunner.gate(m), .ready, "precondition: the step will call the report")

        let property = await GuidedTestRunner.runPropertyReport(m, slot: 2)
        XCTAssertEqual(property.state, .failed, property.detail ?? "nil")
        XCTAssertTrue(property.detail?.contains("Device Busy (0x2019)") == true, property.detail ?? "nil")
    }

    /// A grain probe whose session is replaced while it selects the bank stops before any
    /// candidate and leaves no abort note, so the step falls back to its own reason.
    func testAGrainProbeStoppedByANewSessionGivesTheFallbackReason() async throws {
        let (m, t) = await connect()
        var prepared = preparedSession(m)
        prepared.grainProbe = nil
        let session = prepared
        let held = expectation(description: "the probe is selecting its bank")
        await t.holdNextWrite(to: FujiPTP.Prop.slotSelector) { held.fulfill() }
        let probe = Task { await GuidedTestRunner.runGrainProbe(m, slot: 1, session: session) }
        await fulfillment(of: [held], timeout: 10)

        await m.connector.connectDemo(using: MockCameraTransport(faults: MockCameraFaults(isInstant: true)))
        await t.releaseHeldWrite()
        let grain = await probe.value

        XCTAssertEqual(grain.state, .failed)
        XCTAssertEqual(grain.detail, "The grain probe stopped before writing any value. Reconnect the camera and try again.")
    }

    func testALostCameraIsRefusedAtTheGateRatherThanReportedAsEmpty() async {
        let (m, _) = await connect()
        await m.connector.disconnect()

        XCTAssertEqual(GuidedTestRunner.gate(m), .disconnected)
        let property = await GuidedTestRunner.runPropertyReport(m, slot: 1)
        XCTAssertEqual(property.state, .refused, "the gate stopped it before it reached the camera")
    }

    // MARK: Facts

    func testTheFactsReadTheTransportFromTheReportRatherThanTheModelID() async {
        let (m, _) = await connect(.xT30III)
        let facts = GuidedTestRunner.facts(m)
        XCTAssertEqual(facts.transport, "demo", "a faulted demo carries a real body's product name")
        XCTAssertTrue(facts.isDemo)
        XCTAssertEqual(facts.modelID, "X-T30 III")
        XCTAssertEqual(facts.badge, "Read & Write · not yet tested", "writable on inference")
        XCTAssertTrue(facts.hasFilmSimulationDial)
        XCTAssertTrue(facts.canWrite)
    }

    /// Recognition is what routes a body to the identity check and the slot steps rather than to the
    /// sweep. It follows what the app will do with the body, not whether the registry lists it: an
    /// unlisted body its slot read granted is recognized and writable with no model id to persist;
    /// the same body refused by its read, and a body nothing names, are not; a listed body the
    /// record blocks is recognized, has no slots, and is not writable, as before.
    func testTheFactsRecognizeAnUnlistedBodyByWhatItsSlotReadGranted() async {
        let (granted, _) = await connect(.unlistedBody)
        let facts = GuidedTestRunner.facts(granted)
        XCTAssertTrue(facts.isRecognized)
        XCTAssertTrue(facts.hasSlotProtocol)
        XCTAssertTrue(facts.canWrite)
        XCTAssertNil(facts.modelID, "the provisional model's placeholder id is nothing to store")
        XCTAssertEqual(facts.identification, "unlisted")
        XCTAssertEqual(facts.productName, "FUJIFILM X-T99")
        XCTAssertEqual(facts.badge, "Read & Write · not yet tested")
        XCTAssertFalse(facts.canConvert, "the Kitchen keys on a trusted match")
        XCTAssertFalse(facts.canHarvestProfile)

        var noBankBlock = MockCameraFaults.unlistedBody
        noBankBlock.unsupportedReadCodes = [FujiPTP.Prop.slotSelector]
        let (refused, _) = await connect(noBankBlock)
        let refusedFacts = GuidedTestRunner.facts(refused)
        XCTAssertEqual(refusedFacts.identification, "unlisted")
        XCTAssertFalse(refusedFacts.isRecognized)
        XCTAssertFalse(refusedFacts.hasSlotProtocol)
        XCTAssertFalse(refusedFacts.canWrite)

        let (unknown, _) = await connect(.unknownBody)
        XCTAssertFalse(GuidedTestRunner.facts(unknown).isRecognized)

        let (blocked, _) = await connect(.noSlotProtocolBody)
        let blockedFacts = GuidedTestRunner.facts(blocked)
        XCTAssertTrue(blockedFacts.isRecognized)
        XCTAssertFalse(blockedFacts.hasSlotProtocol)
        XCTAssertFalse(blockedFacts.canWrite)
        XCTAssertEqual(blockedFacts.modelID, "X-T20")
    }

    /// The whole continuous test on an unlisted body, each step asking the flow where it goes next
    /// with the live facts, through the grain check and a push to a trial the report carries. The
    /// path a tester's report of a new body comes back along.
    func testAnUnlistedBodyIsDrivenThroughTheWritePassToARecordedPushTrial() async throws {
        let (m, t) = await connect(.unlistedBody)
        var session = GuidedTestSession.beginContinuous(step: .connect)
        func advance() -> GuidedTestStep {
            session.adopt(camera: GuidedTestRunner.facts(m))
            let next = GuidedTestFlow.next(after: session.step, session: session, facts: GuidedTestRunner.facts(m))
            session.advance(to: next)
            return next
        }
        XCTAssertEqual(advance(), .confirmIdentity)
        session.identity = .init(confirmed: true)
        XCTAssertEqual(advance(), .readSlots)
        session.propertyReport = await GuidedTestRunner.runPropertyReport(m, slot: 1)
        XCTAssertEqual(session.propertyReport?.state, .ran, session.propertyReport?.detail ?? "")
        XCTAssertEqual(advance(), .compareSlots)
        let compared = try XCTUnwrap(m.slotReader.slots.first(where: \.isOccupied))
        var comparison = GuidedTestFlow.comparison(for: compared, model: m.session.model)
        comparison.confirmedMatching = true
        comparison.checkedAt = CameraCompatibilityReport.timestamp()
        session.slotComparisons = [comparison]
        XCTAssertEqual(advance(), .writeIntro)
        session.writePass = .init(consentAt: CameraCompatibilityReport.timestamp())
        XCTAssertEqual(advance(), .backup)
        XCTAssertNil(GuidedTestRunner.prepareRecovery(m, session: &session))
        XCTAssertEqual(advance(), .grainProbe, "the provisional model claims no dial")
        session.grainConsentAt = CameraCompatibilityReport.timestamp()
        session.grainProbe = await GuidedTestRunner.runGrainProbe(m, slot: compared.index, session: session)
        XCTAssertEqual(session.grainProbe?.state, .ran, session.grainProbe?.detail ?? "")
        XCTAssertEqual(advance(), .chooseRecipe)
        let recipe = try XCTUnwrap(GuidedTestFlow.suggestedWriteRecipe(session: session))
        // The flow suggests an empty slot first, and the tester may move it. The Demo Camera's
        // unprogrammed slots answer nothing, which the writer refuses to overwrite, so the tester
        // here picks the slot they compared.
        session.selectedWriteSlot = compared.index
        let slot = try XCTUnwrap(GuidedTestFlow.suggestedWriteSlot(in: m.slotReader.slots, session: session))
        XCTAssertEqual(slot, compared.index)
        session.writePass?.trials = [.init(recipe: recipe.id, recipeName: recipe.name, slot: slot)]
        session.writePass?.currentTrial = 0
        XCTAssertEqual(advance(), .chooseSlot)
        XCTAssertEqual(advance(), .push)
        XCTAssertNil(GuidedTestRunner.mutationBlockReason(m, session: session, slot: slot, kind: .recipeWrite))
        let (trial, _) = await GuidedTestRunner.runPush(m, recipe: recipe, slot: slot, session: session)
        XCTAssertEqual(trial.outcome, .applied, trial.refusalReason ?? "")
        session.writePass?.trials[0] = trial
        XCTAssertEqual(advance(), .powerCycle, "the first accepted trial gets the restart check")
        let holds = await cameraHolds(t, slot: slot, .filmSimulation).flatMap { FujiEncoding.byteToFilmSim[$0] }
        XCTAssertEqual(holds, recipe.settings.filmSimulation)

        GuidedTestRunner.project(session, into: m)
        let report = try XCTUnwrap(m.reports.report)
        let record = try XCTUnwrap(report.guidedTests?.first { $0.sessionID == session.id })
        XCTAssertEqual(record.writePass?.trials?.first?.outcome, .applied)
        XCTAssertEqual(record.writePass?.trials?.first?.slot, slot)
        XCTAssertEqual(record.grainProbe?.state, "ran")
        XCTAssertEqual(record.identity?.identification, "unlisted")
        XCTAssertNil(record.identity?.appShowedModelID)
        XCTAssertNil(report.camera.identifiedModelID)
        XCTAssertNil(session.identifiedModelID)
    }

    /// The stored report outlives the connection. A phone that once tried the Demo Camera kept
    /// reporting "demo" for every later session until a real connect rewrote the report — including
    /// on the test's own hub, which told the tester their run counted for nothing.
    func testTheFactsClaimNoTransportWhenNothingIsAttached() async {
        let (m, _) = await connect(.xT30III)
        XCTAssertEqual(GuidedTestRunner.facts(m).transport, "demo")

        await m.connector.disconnect()
        let facts = GuidedTestRunner.facts(m)
        XCTAssertNil(facts.transport, "the report describes the last camera, not the one in hand")
        XCTAssertNil(facts.serialHash)
        XCTAssertFalse(facts.isDemo)
        XCTAssertNotNil(m.reports.report, "the report itself is still there to be sent")
    }

    // MARK: The write pass

    func testAPushRecordsWhatItIntendedForEveryProperty() async {
        let (m, t) = await connect()
        let model = m.session.model!
        let recipe = GuidedTestRecipes.recipe(id: "colour", for: model)!

        let (trial, result) = await GuidedTestRunner.runPush(m, recipe: recipe, slot: 2, session: preparedSession(m))

        XCTAssertEqual(trial.outcome, .applied)
        XCTAssertEqual(trial.slot, 2)
        XCTAssertEqual(trial.recipeName, "CT Colour")
        XCTAssertFalse(trial.wrote.isEmpty)
        XCTAssertEqual(trial.wrote[PTPHex.code(FujiPTP.PresetProp.filmSimulation.rawValue)], "0B00",
                       "Classic Chrome, as the recipe asked")
        let holds = await cameraHolds(t, slot: 2, .filmSimulation)
        XCTAssertEqual(holds, 0x0B, "and the camera agrees")

        // The per-field table comes back with the trial: a single push never publishes
        // `lastWriteResults`, so this is the only route the results screen has to it.
        XCTAssertEqual(result?.slot, 2)
        XCTAssertFalse(result?.fields.isEmpty ?? true)
    }

    /// The Camera Test is how an unlisted body gets listed, and its write pass is the evidence it
    /// brings back: a recipe from the provisional model, pushed to the body, and recorded with no
    /// model id anywhere two bodies could be compared by one.
    func testAnUnlistedBodyPushesARecipeFromItsProvisionalModel() async throws {
        let (m, t) = await connect(.unlistedBody)
        var session = preparedSession(m)
        XCTAssertNil(session.identifiedModelID)
        let recipe = try XCTUnwrap(GuidedTestFlow.suggestedWriteRecipe(session: session))
        XCTAssertEqual(recipe.id, "priority")
        XCTAssertNil(GuidedTestRunner.mutationBlockReason(m, session: session, slot: 2, kind: .recipeWrite))

        let (trial, result) = await GuidedTestRunner.runPush(m, recipe: recipe, slot: 2, session: session)
        XCTAssertEqual(trial.outcome, .applied, trial.refusalReason ?? "")
        XCTAssertNotNil(result)
        XCTAssertTrue(trial.hasAcceptedRecipeFields)
        let holds = await cameraHolds(t, slot: 2, .filmSimulation).flatMap { FujiEncoding.byteToFilmSim[$0] }
        XCTAssertEqual(holds, recipe.settings.filmSimulation, "and the camera holds what the recipe asked")

        session.writePass?.trials = [trial]
        session.writePass?.currentTrial = 0
        GuidedTestRunner.project(session, into: m)
        let report = try XCTUnwrap(m.reports.report)
        let record = try XCTUnwrap(report.guidedTests?.first)
        XCTAssertEqual(record.writePass?.trials?.first?.outcome, .applied)
        XCTAssertEqual(record.writePass?.trials?.first?.recipe, "priority")
        XCTAssertNil(record.identity?.appShowedModelID)
        XCTAssertEqual(record.identity?.identification, "unlisted")
        XCTAssertNil(report.camera.identifiedModelID)
        XCTAssertNil(report.pushes?.last?.modelID)
        XCTAssertNil(GuidedRecoveryStore.load(sessionID: session.id)?.backup.camera.modelID)
    }

    /// The slot preparation is answered at Choose a slot, on a trial the push then replaces with its
    /// own value. The answer describes that slot, so it travels with a push to the same slot and not
    /// with one to another.
    func testAPushKeepsTheSlotPreparationAnsweredBeforeIt() async {
        let (m, _) = await connect()
        let recipe = GuidedTestRecipes.recipe(id: "colour", for: m.session.model!)!
        var session = preparedSession(m)
        var pending = GuidedTestSession.PushTrial(recipe: recipe.id, recipeName: recipe.name, slot: 2)
        pending.preparation = .setForTest
        pending.preparationConfirmedAt = Date(timeIntervalSince1970: 1_760_000_000)
        session.writePass?.trials = [pending]
        session.writePass?.currentTrial = 0

        let (trial, _) = await GuidedTestRunner.runPush(m, recipe: recipe, slot: 2, session: session)
        XCTAssertEqual(trial.outcome, .applied)
        XCTAssertEqual(trial.preparation, .setForTest)
        XCTAssertEqual(trial.preparationConfirmedAt, Date(timeIntervalSince1970: 1_760_000_000))

        let (elsewhere, _) = await GuidedTestRunner.runPush(m, recipe: recipe, slot: 4, session: session)
        XCTAssertNil(elsewhere.preparation, "an answer about C2 says nothing about C4")
    }

    /// The happy case for the step: the recipe is still there after the camera has been switched off
    /// and on.
    func testARecipeThatSurvivesAPowerCycleIsReportedAsSurviving() async {
        let (m, _) = await connect()
        let recipe = GuidedTestRecipes.recipe(id: "colour", for: m.session.model!)!
        let (trial, _) = await GuidedTestRunner.runPush(m, recipe: recipe, slot: 2, session: preparedSession(m))

        // The power cycle: disconnect, then connect to the same body again.
        await m.connector.disconnect()
        await m.connector.connectDemo()
        XCTAssertTrue(m.session.isConnected)

        let slot = m.slotReader.slots.first { $0.index == 2 }
        let persistence = GuidedTestFlow.persistence(trial: trial, slot: slot,
                                                     nameApplied: trial.nameApplied)
        XCTAssertTrue(persistence.persisted, "differences: \(persistence.differences)")
        XCTAssertEqual(persistence.nameHolds, true)
    }

    /// And the failure it exists for. The push is answered OK, the read-back agrees, and the recipe
    /// is gone the next time the camera comes up — invisible to everything else in the app.
    func testARecipeThatDoesNotSurviveAPowerCycleIsCaughtAndNamed() async {
        let (m, t) = await connect(.forgetsWritesOnPowerCycle)
        let recipe = GuidedTestRecipes.recipe(id: "colour", for: m.session.model!)!
        let (trial, _) = await GuidedTestRunner.runPush(m, recipe: recipe, slot: 2, session: preparedSession(m))
        XCTAssertEqual(trial.outcome, .applied, "the push itself reported success, as it would")
        let heldBefore = await cameraHolds(t, slot: 2, .filmSimulation)
        XCTAssertEqual(heldBefore, 0x0B, "and the camera really did hold it")

        await m.connector.disconnect()
        await m.connector.connectDemo()

        let heldAfter = await cameraHolds(t, slot: 2, .filmSimulation)
        XCTAssertNotEqual(heldAfter, 0x0B, "the body forgot it, exactly as the fault says")

        let persistence = GuidedTestFlow.persistence(trial: trial,
                                                     slot: m.slotReader.slots.first { $0.index == 2 },
                                                     nameApplied: trial.nameApplied)
        XCTAssertFalse(persistence.persisted)
        XCTAssertTrue(persistence.differences.contains { $0.field == "Film Simulation" },
                      "got: \(persistence.differences.map(\.field))")
    }

    /// A property the camera refused at push time is a finding the push record already carries.
    /// The power-cycle check asks a different question — did what landed survive — so a refusal
    /// must not come back a second time as "did not persist". The case that makes it matter: CT
    /// Colour carries DR200, and the ISO floor refuses DR200 on any bank at base ISO, which is the
    /// state a fresh bank on a tester's camera is most likely in.
    func testAPropertyRefusedAtPushTimeIsNotReportedAgainAsNotPersisting() async {
        var faults = MockCameraFaults()
        faults.invalidValueWriteCodes = [FujiPTP.PresetProp.dynamicRange.rawValue]
        let (m, _) = await connect(faults)
        let recipe = GuidedTestRecipes.recipe(id: "colour", for: m.session.model!)!
        XCTAssertEqual(recipe.settings.dynamicRange, .dr200, "precondition: the recipe asks for the gated value")
        let (trial, _) = await GuidedTestRunner.runPush(m, recipe: recipe, slot: 2, session: preparedSession(m))
        XCTAssertEqual(trial.outcome, .partiallyApplied, "the push itself reports the refusal")
        XCTAssertNil(trial.wrote[PTPHex.code(FujiPTP.PresetProp.dynamicRange.rawValue)],
                     "a refused property is not something the camera took")
        XCTAssertNotNil(trial.wrote[PTPHex.code(FujiPTP.PresetProp.filmSimulation.rawValue)],
                        "and the ones it did take are still checked")

        await m.connector.disconnect()
        await m.connector.connectDemo()

        let persistence = GuidedTestFlow.persistence(trial: trial,
                                                     slot: m.slotReader.slots.first { $0.index == 2 },
                                                     nameApplied: trial.nameApplied)
        XCTAssertTrue(persistence.persisted, "differences: \(persistence.differences)")
        XCTAssertFalse(persistence.differences.contains { $0.field == "Dynamic Range" })
    }

    /// The demo has to behave like hardware across a reconnect, or the power-cycle step reports
    /// every push as lost on a transport that never lost anything.
    func testReconnectingToTheDemoKeepsWhatWasWrittenToIt() async {
        let (m, _) = await connect()
        _ = await m.slotWriter.push(settings: RecipeSettings(filmSimulation: .classicNeg), name: "Kept", toSlot: 1)
        await m.connector.disconnect()
        await GuidedTestRunner.reconnect(m, transport: "demo")

        XCTAssertEqual(m.slotReader.slots.first { $0.index == 1 }?.settings?.filmSimulation, .classicNeg)
        XCTAssertEqual(m.slotReader.slots.first { $0.index == 1 }?.resolvedName, "Kept")
    }

    // MARK: Projection

    func testProjectingTwiceLeavesOneRecordThatCarriesTheLatestState() async {
        let (m, _) = await connect()
        var session = GuidedTestSession.begin(wave: 1, step: .propertyReport)
        session.adopt(camera: GuidedTestRunner.facts(m))
        GuidedTestRunner.project(session, into: m)

        session.propertyReport = await GuidedTestRunner.runPropertyReport(m, slot: 1)
        session.advance(to: .grainProbe)
        GuidedTestRunner.project(session, into: m)

        XCTAssertEqual(m.reports.report?.guidedTests?.count, 1)
        XCTAssertEqual(m.reports.report?.guidedTests?.first?.propertyReport?.state, "ran")
        XCTAssertEqual(m.reports.report?.guidedTests?.first?.outcomeStep, "grainProbe")
        XCTAssertTrue(m.reports.report?.textRendering.contains("Camera test  wave 1 (legacy) · demo") ?? false)
    }

    /// The whole read pass, end to end, on the demo — the shape a tester's report arrives in.
    func testAWholeReadPassReachesTheReport() async {
        let (m, _) = await connect()
        var session = GuidedTestSession.begin(wave: 1, step: .intro)
        session.adopt(camera: GuidedTestRunner.facts(m))
        session.advance(to: .confirmIdentity)
        session.identity = .init(confirmed: true)

        session.advance(to: .compareSlots)
        var comparison = GuidedTestFlow.comparison(for: m.slotReader.slots.first { $0.index == 2 }!, model: m.session.model)
        comparison.rows[0].differs = true
        comparison.rows[0].cameraShows = "something else"
        comparison.checkedAt = CameraCompatibilityReport.timestamp()
        session.slotComparisons = [comparison]

        session.advance(to: .propertyReport)
        session.propertyReport = await GuidedTestRunner.runPropertyReport(m, slot: 2)
        session.advance(to: .grainProbe)
        session.grainProbe = await GuidedTestRunner.runGrainProbe(m, slot: 2, session: session)
        session.advance(to: .review)
        session.develop = .init(state: .notRun)
        session.freeText = "Nothing else to report."
        session.advance(to: .send)
        session.outcome = .completed
        GuidedTestRunner.project(session, into: m)

        let record = m.reports.report?.guidedTests?.first
        XCTAssertEqual(record?.outcome, "completed")
        XCTAssertEqual(record?.identity?.confirmed, true)
        XCTAssertEqual(record?.slotComparisons?.first?.verdict, "differs")
        XCTAssertEqual(record?.propertyReport?.state, "ran")
        XCTAssertEqual(record?.grainProbe?.state, "refused", "a menu discrepancy must stop a mutation")

        // And the whole thing survives the round trip into the file a tester actually sends.
        let decoded = try? CameraCompatibilityReport.decode(m.reports.report!.json)
        XCTAssertEqual(decoded?.guidedTests, m.reports.report?.guidedTests)
    }

    func testGuidedWritesEnforcePrerequisitesAtTheOperationBoundary() async {
        let (m, t) = await connect(.xM5)
        let recipe = GuidedTestRecipes.recipe(id: "priority", for: m.session.model!)!
        let ready = preparedSession(m)
        var cases = [GuidedTestSession?]()
        cases.append(nil)
        var wrongIdentity = ready; wrongIdentity.identity?.confirmed = false; cases.append(wrongIdentity)
        var noConsent = ready; noConsent.writePass?.consentAt = nil; cases.append(noConsent)
        var noDial = ready; noDial.writePass?.dialConfirmed = false; cases.append(noDial)
        var noStillBank = ready; noStillBank.stillBankConfirmations = nil; cases.append(noStillBank)
        var noGrain = ready; noGrain.grainProbe = nil; cases.append(noGrain)
        for state: GuidedTestSession.ProbeOutcome.State in [.skipped, .notRun, .notWritable, .refused, .failed] {
            var unfinishedGrain = ready
            unfinishedGrain.grainProbe = .init(state: state)
            cases.append(unfinishedGrain)
        }
        var failedRead = ready; failedRead.propertyReport = .init(state: .failed); cases.append(failedRead)
        var differs = ready
        differs.slotComparisons = [.init(slot: 1, rows: [.init(field: "filmSimulation", label: "Film Simulation",
                                                              appShowed: "REALA ACE", differs: true)])]
        cases.append(differs)
        var noBaseline = ready; noBaseline.recoveryBaselineID = nil; cases.append(noBaseline)
        var differentBody = ready; differentBody.cameraProductName = "FUJIFILM X-T30 III"; cases.append(differentBody)
        let before = await t.totalWriteCount
        for session in cases {
            let outcome = await GuidedTestRunner.runPush(m, recipe: recipe, slot: 1, session: session)
            XCTAssertEqual(outcome.trial.outcome, .notWritten)
            XCTAssertNil(outcome.trial.pushedAt)
            XCTAssertNotNil(outcome.trial.refusalReason)
            XCTAssertNil(outcome.result)
        }
        let invalidSlot = await GuidedTestRunner.runPush(m, recipe: recipe, slot: 0, session: ready)
        XCTAssertEqual(invalidSlot.trial.outcome, .notWritten)
        let after = await t.totalWriteCount
        XCTAssertEqual(before, after)
    }

    func testXM5RequiresTheActualBankConfirmationBeforeEitherMutationIncludingEmptyBanks() async {
        for startsEmpty in [false, true] {
            var faults = MockCameraFaults.xM5
            faults.startsWithEmptySlots = startsEmpty
            let (camera, transport) = await connect(faults)
            var session = preparedSession(camera)
            session.stillBankConfirmations = nil
            let recipe = GuidedTestRecipes.recipe(id: "priority", for: camera.session.model!)!
            let before = await transport.totalWriteCount

            let grain = await GuidedTestRunner.runGrainProbe(camera, slot: 1, session: session)
            XCTAssertEqual(grain.state, .refused)
            XCTAssertTrue(grain.detail?.contains("C1 is assigned to STILL") == true)
            let push = await GuidedTestRunner.runPush(camera, recipe: recipe, slot: 1, session: session)
            XCTAssertEqual(push.trial.outcome, .notWritten)
            XCTAssertNil(push.trial.pushedAt)
            let after = await transport.totalWriteCount
            XCTAssertEqual(before, after, "Missing confirmation must prevent every camera write")

            session.setStillBankConfirmation(1, confirmed: true)
            XCTAssertNil(GuidedTestRunner.mutationBlockReason(camera, session: session, slot: 1, kind: .grainProbe))
            XCTAssertNil(GuidedTestRunner.mutationBlockReason(camera, session: session, slot: 1, kind: .recipeWrite))
            for kind: GuidedTestRunner.MutationKind in [.grainProbe, .recipeWrite] {
                XCTAssertTrue(GuidedTestRunner.mutationBlockReason(camera, session: session, slot: 2, kind: kind)?
                    .contains("C2 is assigned to STILL") == true, "C1 confirmation cannot authorize C2")
            }
            session.setStillBankConfirmation(2, confirmed: true)
            XCTAssertNil(GuidedTestRunner.mutationBlockReason(camera, session: session, slot: 2, kind: .recipeWrite))
            session.setStillBankConfirmation(2, confirmed: false)
            XCTAssertNotNil(GuidedTestRunner.mutationBlockReason(camera, session: session, slot: 2, kind: .recipeWrite))
            await camera.connector.disconnect()
        }
    }

    func testXT30IIIDoesNotRequireAnXM5BankConfirmation() async {
        let (camera, _) = await connect(.xT30III)
        let session = preparedSession(camera)
        XCTAssertNil(session.stillBankConfirmations)
        XCTAssertNil(GuidedTestRunner.mutationBlockReason(camera, session: session, slot: 1, kind: .grainProbe))
        XCTAssertNil(GuidedTestRunner.mutationBlockReason(camera, session: session, slot: 1, kind: .recipeWrite))
        await camera.connector.disconnect()
    }

    /// The Kelvin trial rewrites the slot's stored colour temperature, which the non-Kelvin original
    /// hides. The restore starts while the slot is still on Kelvin, so it puts the original value
    /// back first and the white balance after; the original is exact, dormant value included.
    func testOriginalSurvivesTwoTrialsIncludingTheDormantKelvin() async throws {
        let (m, _) = await connect()
        let session = preparedSession(m)
        let original = try XCTUnwrap(GuidedRecoveryStore.load(sessionID: session.id))
        let slotIndex = try XCTUnwrap(original.backup.slots.first(where: \.occupied)).index
        let first = GuidedTestRecipes.recipe(id: "colour", for: m.session.model!)!
        let second = GuidedTestRecipes.recipe(id: "kelvin", for: m.session.model!)!
        _ = await GuidedTestRunner.runPush(m, recipe: first, slot: slotIndex, session: session)
        _ = await GuidedTestRunner.runPush(m, recipe: second, slot: slotIndex, session: session)
        let retained = try XCTUnwrap(GuidedRecoveryStore.load(sessionID: session.id))
        XCTAssertEqual(retained.backup, original.backup, "the baseline never becomes the previous test recipe")
        XCTAssertEqual(retained.unresolvedSlots, [slotIndex])
        let bytes = try XCTUnwrap(retained.backup.properties(forSlot: slotIndex))
        let name = retained.backup.slots.first { $0.index == slotIndex }?.name ?? "C\(slotIndex)"
        let inactiveKelvin = FujiPTP.PresetProp.colorTemp.rawValue
        let beforeRestore = try XCTUnwrap(m.slotReader.slots.first { $0.index == slotIndex })
        XCTAssertEqual(beforeRestore.rawProperties[FujiPTP.PresetProp.whiteBalance.rawValue],
                       FujiEncoding.packU16(FujiEncoding.wbColorTempValue), "the Kelvin trial left the slot on Kelvin")
        XCTAssertNotEqual(beforeRestore.rawProperties[inactiveKelvin], bytes[inactiveKelvin], "and changed the stored value")
        let restored = await m.slotWriter.restore(bytes, name: name, toSlot: slotIndex)
        XCTAssertEqual(restored.outcome, .applied)
        XCTAssertEqual(m.slotReader.slots.first { $0.index == slotIndex }?.resolvedName, name)
        let final = try XCTUnwrap(m.slotReader.slots.first { $0.index == slotIndex })
        for (code, expected) in bytes where FujiPTP.PresetProp(rawValue: code)?.recipeField != nil {
            XCTAssertTrue(SlotWriteVerification.readBackMatches(code, wrote: expected, read: final.rawProperties[code]),
                          "original \(PTPHex.code(code)) was not restored")
        }
        XCTAssertEqual(final.rawProperties[inactiveKelvin], bytes[inactiveKelvin],
                       "the dormant Kelvin was put back while the slot still accepted it")
        let verification = RestoreView.verifyRestore(restored, saved: bytes, current: final,
            fidelity: .init(), cameraReady: true, expectedName: name)
        XCTAssertEqual(verification.outcome, .applied)
        XCTAssertTrue(verification.reasons.isEmpty, "\(verification.reasons)")
        XCTAssertTrue(AppLog.reportText(in: .camera).contains("writes Color Temp (K) first"),
                      "the order is said in the log")
    }

    func testReopeningGrainAfterARecipeWriteCannotClearPendingRecovery() async {
        let (camera, transport) = await connect()
        var session = preparedSession(camera)
        let recipe = GuidedTestRecipes.recipe(id: "priority", for: camera.session.model!)!
        let written = await GuidedTestRunner.runPush(camera, recipe: recipe, slot: 1, session: session)
        XCTAssertTrue(written.trial.hasAcceptedWrite)
        session.writePass?.trials = [written.trial]
        session.grainProbe = .init(state: .skipped)
        let before = await transport.totalWriteCount
        let grain = await GuidedTestRunner.runGrainProbe(camera, slot: 1, session: session)
        XCTAssertEqual(grain.state, .refused)
        let after = await transport.totalWriteCount
        XCTAssertEqual(before, after)
        XCTAssertEqual(GuidedRecoveryStore.load(sessionID: session.id)?.unresolvedSlots, [1])
    }

    func testMissingRecoveryAndWrittenLegacyTestsCannotCaptureANewOriginal() async {
        let (m, t) = await connect()
        var prepared = preparedSession(m)
        GuidedRecoveryStore.deleteAll()
        XCTAssertNotNil(GuidedTestRunner.prepareRecovery(m, session: &prepared))
        var legacy = GuidedTestSession.begin(wave: 2, step: .powerCycle)
        legacy.adopt(camera: GuidedTestRunner.facts(m))
        legacy.writePass = .init(trials: [.init(recipe: "colour", recipeName: "CT Colour", slot: 1,
                                               pushedAt: CameraCompatibilityReport.timestamp())])
        XCTAssertNotNil(GuidedTestRunner.prepareRecovery(m, session: &legacy))
        XCTAssertNil(GuidedRecoveryStore.load(sessionID: legacy.id))
        let before = await t.totalWriteCount
        let recipe = GuidedTestRecipes.recipe(id: "colour", for: m.session.model!)!
        let blocked = await GuidedTestRunner.runPush(m, recipe: recipe, slot: 1, session: prepared)
        XCTAssertEqual(blocked.trial.outcome, .notWritten)
        let after = await t.totalWriteCount
        XCTAssertEqual(before, after)
    }

    func testRestartedTestCannotCaptureChangedSettingsUntilPriorRecoveryIsResolved() async throws {
        let (camera, transport) = await connect()
        var previous = preparedSession(camera)
        let original = try XCTUnwrap(GuidedRecoveryStore.load(sessionID: previous.id))
        let slot = try XCTUnwrap(original.backup.slots.first(where: \.occupied)).index
        let recipe = try XCTUnwrap(GuidedTestRecipes.recipe(id: "priority", for: camera.session.model!))
        let written = await GuidedTestRunner.runPush(camera, recipe: recipe, slot: slot, session: previous)
        XCTAssertTrue(written.trial.hasAcceptedWrite)
        previous.writePass?.trials = [written.trial]
        XCTAssertTrue(GuidedTestStore.archive(previous))
        XCTAssertNil(GuidedTestStore.load())
        XCTAssertEqual(GuidedRecoveryStore.load(sessionID: previous.id)?.unresolvedSlots, [slot])

        // A new test can complete its reading, but must not silently call the old test recipe
        // the camera's original settings merely because the previous session was archived.
        var fresh = GuidedTestSession.beginContinuous(step: .backup)
        fresh.adopt(camera: GuidedTestRunner.facts(camera))
        fresh.identity = .init(confirmed: true)
        fresh.propertyReport = .init(state: .ran, count: 24)
        var comparison = GuidedTestFlow.comparison(
            for: try XCTUnwrap(camera.slotReader.slots.first { $0.index == slot }), model: camera.session.model)
        comparison.confirmedMatching = true
        comparison.checkedAt = CameraCompatibilityReport.timestamp()
        fresh.slotComparisons = [comparison]
        fresh.writePass = .init(consentAt: CameraCompatibilityReport.timestamp(), dialConfirmed: true)
        XCTAssertNotNil(GuidedTestStore.save(fresh))
        let writesBefore = await transport.totalWriteCount

        let refusal = GuidedTestRunner.prepareRecovery(camera, session: &fresh)
        XCTAssertTrue(refusal?.contains("earlier test") == true, refusal ?? "Expected unresolved recovery to block the new baseline")
        XCTAssertNil(fresh.recoveryBaselineID)
        XCTAssertNil(GuidedRecoveryStore.load(sessionID: fresh.id))
        XCTAssertEqual(GuidedRecoveryStore.load(sessionID: previous.id)?.backup, original.backup)

        // Keeping the recipe is an explicit choice. A later test may then use those settings as
        // its baseline, while the earlier test's actual original remains available unchanged.
        XCTAssertTrue(GuidedRecoveryStore.recordDisposition(sessionID: previous.id, slot: slot, outcome: .kept))
        XCTAssertNil(GuidedTestRunner.prepareRecovery(camera, session: &fresh))
        let newRecovery = try XCTUnwrap(GuidedRecoveryStore.load(sessionID: fresh.id))
        XCTAssertEqual(fresh.recoveryBaselineID, fresh.id)
        XCTAssertEqual(newRecovery.backup.properties(forSlot: slot), camera.slotReader.slotBackup?.properties(forSlot: slot))
        XCTAssertNotEqual(newRecovery.backup.properties(forSlot: slot), original.backup.properties(forSlot: slot))
        XCTAssertEqual(GuidedRecoveryStore.load(sessionID: previous.id)?.backup, original.backup)
        XCTAssertEqual(GuidedRecoveryStore.load(sessionID: previous.id)?.dispositions[String(slot)], .kept)
        let writesAfter = await transport.totalWriteCount
        XCTAssertEqual(writesBefore, writesAfter, "baseline preparation never writes camera settings")
    }

    func testDocumentedXM5BoundaryIsAValidReadButAShorterWalkIsNot() async {
        let (expected, _) = await connect(.xM5)
        let expectedRead = await GuidedTestRunner.runPropertyReport(expected, slot: 1)
        XCTAssertEqual(expected.slotReader.probedSlotCount, 4)
        XCTAssertEqual(expectedRead.state, .ran, expectedRead.detail ?? "")
        var short = MockCameraFaults.xM5
        short.maxSelectableSlot = 2
        let (unexpected, _) = await connect(short)
        XCTAssertTrue(unexpected.session.isConnected, "the generic connection can remain usable for reporting")
        let failed = await GuidedTestRunner.runPropertyReport(unexpected, slot: 1)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertTrue(failed.detail?.contains("2 slots") == true)
    }

    func testExpectedUnsupportedValuesAndDescriptorRefusalsDoNotFailReading() async {
        var faults = MockCameraFaults.xM5
        faults.unsupportedReadCodes = [FujiPTP.PresetProp.smoothSkin.rawValue]
        faults.profileNeedsUpload = true
        let (camera, _) = await connect(faults)
        let outcome = await GuidedTestRunner.runPropertyReport(camera, slot: 1)
        XCTAssertEqual(outcome.state, .ran, outcome.detail ?? "")
        let probe = PropertyProbe(
            code: FujiPTP.PresetProp.filmSimulation.rawValue, name: "Film Simulation",
            value: FujiEncoding.packU16(1), descriptor: nil, valueError: nil,
            descriptorError: "no descriptor (camera answered 0x2002 General Error)")
        XCTAssertNil(GuidedTestRunner.propertyReadFailure([probe]))
    }

    func testUnexpectedValueReadFailuresCannotCountAsSuccessfulPropertySweeps() {
        for failure in [CameraError.timeout.errorDescription!, CameraError.ptpError(code: 0x2002).errorDescription!] {
            let probe = PropertyProbe(
                code: FujiPTP.PresetProp.filmSimulation.rawValue, name: "Film Simulation",
                value: nil, descriptor: nil, valueError: failure, descriptorError: nil)
            XCTAssertNotNil(GuidedTestRunner.propertyReadFailure([probe]))
        }
        let summary = CameraCompatibilityReport.SlotSummary(
            documentedSlotCount: 4, probedSlotCount: 4,
            reads: [.init(slot: 1, selected: true,
                          properties: [.init(code: "0xD192", error: "General Error", responseCode: "0x2002")])])
        XCTAssertNotNil(GuidedTestRunner.slotReadFailure(summary, model: CameraModelRegistry.shared.model(withID: "X-M5"),
                                                         maySelectSlots: true))
    }

    /// Reproduce an X-T50 fw 1.32 report (2026-10-03) without storing anyone's recipe data:
    /// all seven slots read, while D183/D185 refuse value reads and standard ISO is unsupported.
    func testXT50ConversionControlReadRefusalsAllowTheMenuComparison() async throws {
        var faults = MockCameraFaults(productName: "FUJIFILM X-T50", firmwareVersion: "1.32")
        faults.readResponseCodes = [FujiPTP.Prop.startRawConversion: 0x2002]
        faults.profileNeedsUpload = true
        faults.unsupportedReadCodes = [FujiPTP.Prop.exposureIndex]
        let (camera, _) = await connect(faults)
        XCTAssertEqual(camera.session.model?.id, "X-T50")
        XCTAssertEqual(camera.slotReader.probedSlotCount, 7)

        var session = GuidedTestSession.beginContinuous(step: .readSlots)
        session.adopt(camera: GuidedTestRunner.facts(camera))
        session.identity = .init(confirmed: true)
        session.propertyReport = await GuidedTestRunner.runPropertyReport(camera, slot: 1)
        XCTAssertEqual(session.propertyReport?.state, .ran, session.propertyReport?.detail ?? "")
        XCTAssertEqual(GuidedTestFlow.next(after: .readSlots, session: session,
                                         facts: GuidedTestRunner.facts(camera)), .compareSlots)

        // The diagnostic refusal remains available to the developer; no conversion or recipe
        // write has been attempted to make the pre-upload reading look successful.
        let report = try XCTUnwrap(camera.reports.report)
        for code in ["0xD183", "0xD185"] {
            let entry = try XCTUnwrap(report.propertySweep?.entries.first { $0.code == code })
            XCTAssertTrue(entry.valueError?.contains("0x2002") == true)
        }
        XCTAssertTrue(report.pushes?.isEmpty ?? true)
        XCTAssertTrue(report.develops?.isEmpty ?? true)

        // Once the tester actually confirms an occupied slot, the saved originals can be
        // prepared. The same expected diagnostic refusal must not strand the writing branch.
        let slot = try XCTUnwrap(camera.slotReader.slots.first(where: \.isOccupied))
        var comparison = GuidedTestFlow.comparison(for: slot, model: camera.session.model)
        comparison.confirmedMatching = true
        comparison.checkedAt = CameraCompatibilityReport.timestamp()
        session.slotComparisons = [comparison]
        session.writePass = .init(consentAt: CameraCompatibilityReport.timestamp(), dialConfirmed: true)
        XCTAssertNil(GuidedTestRunner.prepareRecovery(camera, session: &session))
        session.grainProbe = .init(state: .ran, slot: slot.index, count: CameraDiagnostics.grainProbeCandidates.count)
        XCTAssertNil(GuidedTestRunner.mutationBlockReason(camera, session: session,
                                                        slot: slot.index, kind: .recipeWrite))
    }

    func testConversionControlTimeoutsAndOtherErrorsStillFailReading() {
        for code in [FujiPTP.Prop.startRawConversion, FujiPTP.Prop.rawConvProfile] {
            for error in [CameraError.timeout, CameraError.ptpError(code: 0x201C)] {
                let probe = PropertyProbe(code: code, name: "Conversion control",
                    value: nil, descriptor: nil, valueError: error.errorDescription, descriptorError: nil)
                XCTAssertNotNil(GuidedTestRunner.propertyReadFailure([probe]))
            }
        }
    }

    func testIgnoredSelectorAtTheDocumentedBoundaryIsNotAnExpectedRefusal() {
        let summary = CameraCompatibilityReport.SlotSummary(
            documentedSlotCount: 4, probedSlotCount: 4,
            reads: [.init(slot: 5, selected: false, selectError: "asked for C5, camera reports C4")])
        XCTAssertNotNil(GuidedTestRunner.slotReadFailure(summary, model: CameraModelRegistry.shared.model(withID: "X-M5"),
                                                         maySelectSlots: true))
    }
}

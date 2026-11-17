import XCTest
@testable import FujiCookbook

/// The diagnostic probes write, so they are held to the same gate and the same allowlist as a push.
///
/// `SlotReader.sweepReadOnly` promises an unrecognized camera that nothing was written to it, and the
/// card that offers its report says the app "changed nothing". That has to hold with Diagnostic
/// Mode on as well: the Property Report's first act is a `SetDevicePropValue` on the slot selector,
/// and the grain probe writes real candidate values, so both check the model before they start.
///
/// Camera facts in these tests are from zgrimz/fujifilm-ptp-reference: `docs/07-cameras.md#x-t20`, and
/// `docs/03-encodings.md#0xd195-grain-effect`.
@MainActor
final class CameraProbeGatingTests: XCTestCase {

    private func connect(_ faults: MockCameraFaults) async -> (CameraServices, MockCameraTransport) {
        var faults = faults
        faults.isInstant = true
        let transport = MockCameraTransport(faults: faults)
        let manager = CameraServices()
        await manager.connector.connectDemo(using: transport)
        return (manager, transport)
    }

    /// The same promise, for a body that *is* recognized and simply has no slots to select. Already
    /// true via `maySelectSlots`, so this is a guard rather than a fix — the X-T20 that prompted
    /// `supportsSlotProtocol` reached the Property Report, and that must stay a read.
    func testPropertyReportWritesNothingOnANoSlotProtocolBody() async throws {
        let (m, t) = await connect(.noSlotProtocolBody)
        XCTAssertEqual(m.session.model?.id, "X-T20", "precondition: recognized, not an unknown body")
        let before = await t.totalWriteCount

        let result = try await m.diagnostics.probeProperties(slot: 3)
        let after = await t.totalWriteCount

        XCTAssertEqual(after, before, "not one SetDevicePropValue, including the slot select")
        XCTAssertFalse(result.probes.isEmpty, "degraded, not refused")
        XCTAssertEqual(m.reports.report?.propertySweep?.readOnly, true)
    }

    /// The same assertion `testUnrecognizedBodyIsSweptWithoutASingleWrite` makes about connect, now
    /// made about the diagnostic a tester can reach afterwards.
    func testPropertyReportWritesNothingOnAnUnrecognizedBody() async throws {
        let (m, t) = await connect(.unknownBody)
        XCTAssertNil(m.session.connected?.model, "precondition: nothing in the registry matched")
        let before = await t.totalWriteCount

        let result = try await m.diagnostics.probeProperties(slot: 3)
        let after = await t.totalWriteCount
        let cameraSlot = await t.currentSlot

        XCTAssertEqual(after, before, "not one SetDevicePropValue, including the slot select")
        XCTAssertFalse(result.probes.isEmpty, "and it still produces a report — degraded, not refused")
        XCTAssertEqual(result.slot, cameraSlot, "it read whichever slot the camera already had")
        XCTAssertEqual(m.reports.report?.propertySweep?.readOnly, true,
                       "and the report says so rather than implying a slot was chosen")
    }

    /// The property report on a guessed body sends exactly one `SetDevicePropValue`: the slot
    /// select. No recipe, whatever the walk has since granted.
    ///
    /// This assertion used to be `after == before` — no selector write at all — on the reasoning
    /// that a guessed body reads only. The reasoning was sound about recipes and wrong about the
    /// selector, and the test's own baseline is the proof: `before` is **7**, the seven `0xD18C`
    /// writes `SlotReader.refresh()` had just made walking this same guessed body's slots at connect. So
    /// the old rule forbade an eighth selector write to a camera that had already taken seven, and
    /// the tester got the weaker diagnostic for it. `maySelectSlots` is now the single rule both
    /// paths use — see `CameraSession.maySelectSlots`.
    func testPropertyReportSelectsButWritesNoRecipeOnAGuessedBody() async throws {
        let (m, t) = await connect(MockCameraFaults(productName: "Demo Camera (no hardware) TETHER"))
        XCTAssertTrue(m.session.connected?.identification.isGuess ?? false, "precondition: matched by name")
        XCTAssertTrue(m.session.connected?.isWritable ?? false, "precondition: granted by its slot read")
        let before = await t.totalWriteCount
        XCTAssertEqual(before, m.slotReader.effectiveSlotCount + 1,
                       "precondition: connect already selected every slot to read it, then put the bank back")

        let result = try await m.diagnostics.probeProperties(slot: 2)
        let after = await t.totalWriteCount

        XCTAssertEqual(after, before + 2, "the slot select and the restore, and nothing else — no recipe")
        XCTAssertEqual(result.slot, 2, "and it reached the slot the tester asked for")
        XCTAssertEqual(m.reports.report?.propertySweep?.readOnly, false,
                       "the report says a slot was selected rather than claiming it wrote nothing")
    }

    /// The grain probe writes real candidate values into the property whose encoding is the open
    /// question, so it runs exactly where a push would: on a guess once its slot read has granted it.
    func testWriteProbeRunsOnAGuessedBodyItsSlotReadGranted() async throws {
        let (m, t) = await connect(MockCameraFaults(productName: "Demo Camera (no hardware) TETHER"))
        XCTAssertTrue(m.session.connected?.isWritable ?? false, "precondition: granted by its slot read")
        let before = await t.totalWriteCount

        let entries = try await m.diagnostics.probeWriteValues(slot: 1, property: .grain, candidates: [1, 2, 3])
        let after = await t.totalWriteCount

        XCTAssertEqual(entries.count, 3)
        XCTAssertGreaterThan(after, before, "the candidates reached the camera")
    }

    /// A body the registry blocks on a recorded failure — the acceptance case that matters. The
    /// write probe must refuse outright: unlike the property report, there is no read-only version
    /// of writing candidate values.
    func testWriteProbeIsRefusedOnABodyTheRegistryBlocks() async throws {
        let (m, t) = await connect(.noSlotProtocolBody)
        XCTAssertFalse(m.session.connected?.isWritable ?? true, "precondition: the X-T20 is blocked")
        let before = await t.totalWriteCount

        let entries = try await m.diagnostics.probeWriteValues(slot: 1, property: .grain, candidates: [1, 2, 3])
        let after = await t.totalWriteCount

        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(after, before, "no candidate reached the camera")
    }

    /// An unlisted body that named itself and whose slot read granted it is probed like any other.
    func testWriteProbeRunsOnAnUnlistedBodyItsSlotReadGranted() async throws {
        let (m, _) = await connect(.unlistedBody)
        XCTAssertTrue(m.session.connected?.isWritable ?? false, "precondition: granted by its slot read")

        let entries = try await m.diagnostics.probeWriteValues(slot: 1, property: .grain, candidates: [1, 2, 3])

        XCTAssertEqual(entries.count, 3)
    }

    /// A body nothing names — no entry, and no firmware in its DeviceInfo — is refused.
    func testWriteProbeIsRefusedOnAnUnrecognizedBody() async throws {
        let (m, t) = await connect(.unknownBody)
        let before = await t.totalWriteCount

        let entries = try await m.diagnostics.probeWriteValues(slot: 1, property: .grain, candidates: [1, 2, 3])
        let after = await t.totalWriteCount

        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(after, before)
    }

    // MARK: Controls — the diagnostics still work where they are allowed to

    func testPropertyReportStillSelectsTheSlotOnATrustedBody() async throws {
        let (m, t) = await connect(MockCameraFaults())
        let before = await t.totalWriteCount

        let result = try await m.diagnostics.probeProperties(slot: 4)
        let after = await t.totalWriteCount

        XCTAssertEqual(result.slot, 4, "it went where it was asked")
        XCTAssertGreaterThan(after, before, "which takes a slot-select write")
        XCTAssertEqual(m.reports.report?.propertySweep?.readOnly, false)
    }

    /// The case that prompted aligning the two rules: a body the app will not write recipes to,
    /// that nonetheless has slots and has them read by selecting each one. The property report now
    /// aims at the slot the tester picked instead of describing whichever slot the camera was left
    /// on — a stronger diagnostic, using a write the connect path had already made seven times.
    func testPropertyReportSelectsTheSlotOnAnUntestedBodyWithSlots() async throws {
        let (m, t) = await connect(.readOnlyWithSlots)
        XCTAssertEqual(m.session.model?.writeSupport, .untested, "precondition: the GFX100 II has no record")
        XCTAssertTrue(m.session.maySelectSlots, "precondition: and its slots answered")
        let before = await t.totalWriteCount

        let result = try await m.diagnostics.probeProperties(slot: 4)
        let after = await t.totalWriteCount

        XCTAssertEqual(result.slot, 4, "it went where the tester asked")
        XCTAssertEqual(after, before + 2, "the slot select and the restore, and nothing else — no recipe")
        XCTAssertEqual(m.reports.report?.propertySweep?.readOnly, false)
    }

    func testWriteProbeStillRunsOnATrustedBody() async throws {
        let (m, _) = await connect(MockCameraFaults())

        let entries = try await m.diagnostics.probeWriteValues(slot: 1, property: .grain, candidates: [2, 1, 3])

        XCTAssertEqual(entries.count, 3)
    }

    // MARK: Mutation-time preflight

    func testGrainProbeStopsWhenSelectionIsIgnoredAfterACleanScan() async throws {
        let (m, t) = await connect(MockCameraFaults())
        XCTAssertEqual(m.slotReader.slots.count, 7, "the prior read was successful")
        let code = FujiPTP.PresetProp.grain.rawValue
        let firstOriginal = await t.storedProperty(code, slot: 1)
        let secondOriginal = await t.storedProperty(code, slot: 2)
        let before = await t.totalWriteCount
        await t.ignoreNextWrite(to: FujiPTP.Prop.slotSelector)

        let entries = try await m.diagnostics.probeWriteValues(slot: 2, property: .grain, candidates: [2, 1, 3])

        let after = await t.totalWriteCount
        let selected = await t.currentSlot
        let firstAfter = await t.storedProperty(code, slot: 1)
        let secondAfter = await t.storedProperty(code, slot: 2)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(after, before + 1, "only the ignored selection was attempted")
        XCTAssertEqual(selected, 1)
        XCTAssertEqual(firstAfter, firstOriginal, "the wrong bank received no candidates")
        XCTAssertEqual(secondAfter, secondOriginal)
        XCTAssertTrue(m.reports.report?.notes.contains {
            $0.contains("aborted") && $0.contains("asked for C2") && $0.contains("reads C1")
        } ?? false)
    }

    func testGrainProbeRestoresSelectionWhenItsReadBackFails() async throws {
        let (m, t) = await connect(MockCameraFaults())
        let before = await t.totalWriteCount
        await t.queueRead(.normal, for: FujiPTP.Prop.slotSelector)
        await t.queueRead(.response(0x2002), for: FujiPTP.Prop.slotSelector)

        let entries = try await m.diagnostics.probeWriteValues(slot: 2, property: .grain, candidates: [2, 1, 3])

        let after = await t.totalWriteCount
        let selected = await t.currentSlot
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(after, before + 2, "the select took effect, so it must be put back")
        XCTAssertEqual(selected, 1)
        let saved = CameraReportStore.loadLatest()
        XCTAssertTrue(saved?.notes.contains { $0.contains("aborted") && $0.contains("reads nothing") } ?? false)
        XCTAssertFalse(saved?.transactions.contains {
            $0.operation == "0x1016" && $0.parameters.first == "0xD195"
        } ?? true, "the saved report proves no grain candidates were sent")
    }

    func testGrainProbeStopsOnATransientOriginalReadFailure() async throws {
        let (m, t) = await connect(MockCameraFaults())
        let code = FujiPTP.PresetProp.grain.rawValue
        let original = await t.storedProperty(code, slot: 2)
        let before = await t.totalWriteCount
        await t.queueRead(.response(0x2002), for: code)

        let entries = try await m.diagnostics.probeWriteValues(slot: 2, property: .grain, candidates: [2, 1, 3])

        let after = await t.totalWriteCount
        let current = await t.storedProperty(code, slot: 2)
        let selected = await t.currentSlot
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(after, before + 2, "selection and restoration only")
        XCTAssertEqual(current, original)
        XCTAssertEqual(selected, 1)
        XCTAssertTrue(m.reports.report?.notes.contains {
            $0.contains("aborted") && $0.contains("could not be read") && $0.contains("0x2002")
        } ?? false)
    }

    func testGrainProbeRequiresAUsableOriginalOnAnOccupiedBank() async throws {
        let (m, t) = await connect(MockCameraFaults())
        let code = FujiPTP.PresetProp.grain.rawValue
        let original = await t.storedProperty(code, slot: 2)
        let invalid: [Data?] = [nil, Data(), Data([2]), Data([2, 0, 0]), FujiEncoding.packU16(99)]
        for value in invalid {
            let before = await t.totalWriteCount
            await t.queueRead(.value(value), for: code)

            let entries = try await m.diagnostics.probeWriteValues(slot: 2, property: .grain, candidates: [2, 1, 3])

            let after = await t.totalWriteCount
            let current = await t.storedProperty(code, slot: 2)
            let selected = await t.currentSlot
            XCTAssertTrue(entries.isEmpty, "unusable original: \(String(describing: value))")
            XCTAssertEqual(after, before + 2, "no candidate or property restore is needed")
            XCTAssertEqual(current, original)
            XCTAssertEqual(selected, 1)
        }
        XCTAssertFalse(m.reports.report?.notes.contains { $0.contains("the slot was empty") } ?? true)
    }

    func testMissingGrainAndFilmSimulationDoNotProveAnEmptyBank() async throws {
        let code = FujiPTP.PresetProp.grain.rawValue
        let (m, t) = await connect(MockCameraFaults(emptyReadCodes: [code, FujiPTP.PresetProp.filmSimulation.rawValue]))
        XCTAssertEqual(m.slotReader.slots.first?.isOccupied, false, "the scan's occupancy bit alone is insufficient")
        XCTAssertFalse(m.slotReader.slots.first?.rawProperties.isEmpty ?? true,
                       "partial raw observations survive a missing film simulation")
        XCTAssertTrue(m.reports.report?.slots.reads.first { $0.slot == 1 }?.properties.contains {
            $0.value != nil
        } ?? false, "the raw report still records the bank's other settings")
        let original = await t.storedProperty(code, slot: 1)
        let before = await t.totalWriteCount

        let entries = try await m.diagnostics.probeWriteValues(slot: 1, property: .grain, candidates: [2, 1, 3])

        let after = await t.totalWriteCount
        let current = await t.storedProperty(code, slot: 1)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(after, before + 1, "the candidate loop must not run")
        XCTAssertEqual(current, original)
        XCTAssertTrue(m.reports.report?.notes.contains { $0.contains("does not establish an empty bank") } ?? false,
                      "the fresh preflight prevents the misleading slot projection from authorizing writes")
    }

    func testGrainProbeRequiresFreshEvidenceForAnEmptyBank() async throws {
        let (m, t) = await connect(MockCameraFaults())
        XCTAssertEqual(m.slotReader.slots.first { $0.index == 3 }?.isOccupied, false)
        // Simulate a bank being named after the scan, without changing the slot reader's cached slots.
        try await t.writeProperty(FujiPTP.Prop.slotSelector, FujiEncoding.packU16(3))
        try await t.writeProperty(FujiPTP.Prop.presetName, FujiEncoding.packPTPString("New bank"))
        try await t.writeProperty(FujiPTP.Prop.slotSelector, FujiEncoding.packU16(1))
        let before = await t.totalWriteCount

        let entries = try await m.diagnostics.probeWriteValues(slot: 3, property: .grain, candidates: [2, 1, 3])

        let after = await t.totalWriteCount
        let selected = await t.currentSlot
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(after, before + 2)
        XCTAssertEqual(selected, 1)
        XCTAssertTrue(m.reports.report?.notes.contains { $0.contains("does not establish an empty bank") } ?? false)
    }

    func testGrainProbeRefusesMissingOriginalsEvenWhenEveryReadIsEmpty() async throws {
        let (m, t) = await connect(MockCameraFaults(startsWithEmptySlots: true))
        let entries = try await m.diagnostics.probeWriteValues(slot: 3, property: .grain, candidates: [2, 1, 3])
        let selected = await t.currentSlot
        let actual = await t.storedProperty(FujiPTP.PresetProp.grain.rawValue, slot: 3)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(selected, 1)
        XCTAssertNil(actual)
        XCTAssertTrue(m.reports.report?.notes.contains { $0.contains("does not establish an empty bank") } ?? false)
    }

    // MARK: One operation at a time

    /// The confirmed cross-slot write. `probeWriteValues` writes real candidate values to D195 in a
    /// loop; `probeProperties` writes D18C. Run concurrently, the second moves the selector out from
    /// under the first, so the remaining candidates — and the "restore" — land in a slot the user
    /// never picked, while every log line and the report still say the slot they asked for.
    ///
    /// The grain probe is held at its first candidate write, with C2 selected, so the report is
    /// asked for while the loop is provably in flight. Started side by side, the first can finish
    /// before the second begins, and two probes in sequence are not the race the gate exists for.
    func testAProbeCannotStartWhileAnotherIsRunning() async throws {
        let (m, t) = await connect(MockCameraFaults())
        let slotBefore = await t.currentSlot
        let held = expectation(description: "the grain probe reaches its first candidate write")
        await t.holdNextWrite(to: FujiPTP.PresetProp.grain.rawValue) { held.fulfill() }

        let grain = Task { try await m.diagnostics.probeWriteValues(slot: 2, property: .grain, candidates: [2, 1, 3, 6, 4]) }
        await fulfillment(of: [held], timeout: 10)
        let slotMidLoop = await t.currentSlot
        let writesMidLoop = await t.totalWriteCount

        let refused = await busyRefusal { () async throws(CameraBusy) in try await m.diagnostics.probeProperties(slot: 5) }

        let slotAfterRefusal = await t.currentSlot
        let writesAfterRefusal = await t.totalWriteCount
        XCTAssertEqual(slotMidLoop, 2, "precondition: held inside the loop, with the probe's bank selected")
        XCTAssertEqual(refused, CameraBusy(runningOperation: "\(FujiPTP.PresetProp.grain.debugName) write probe"),
                       "the report is refused while the grain probe is running")
        XCTAssertEqual(writesAfterRefusal, writesMidLoop, "and writes nothing, not even the slot select")
        XCTAssertEqual(slotAfterRefusal, 2, "so the selector is still where the probe put it")

        await t.releaseHeldWrite()
        let entries = try await grain.value
        let slotAfter = await t.currentSlot
        XCTAssertEqual(entries.map(\.wrote), [2, 1, 3, 6, 4], "the held probe finishes every candidate")
        XCTAssertEqual(slotAfter, slotBefore, "and puts back the bank it borrowed")

        let report = try await m.diagnostics.probeProperties(slot: 5)
        XCTAssertFalse(report.probes.isEmpty, "the gate opens again once the probe is done, so it was the gate")
    }

    /// `connect` reports `.connected` before it awaits its own slot read, so the Camera tab is
    /// pullable while that read is still walking slots — two loops writing D18C at each other.
    func testASlotReadCannotBeStartedWhileAnotherIsRunning() async {
        let (m, _) = await connect(MockCameraFaults())
        let occupied = m.slotReader.slots.filter(\.isOccupied).count

        func read() async -> Result<WalkResult?, CameraBusy> {
            do throws(CameraBusy) { return .success(try await m.slotReader.requestRefresh()) } catch { return .failure(error) }
        }
        async let a = read()
        async let b = read()
        let results = await [a, b]
        XCTAssertEqual(results.filter { (try? $0.get()) != nil }.count, 1,
                       "Only the accepted read may be used as fresh evidence")
        XCTAssertEqual(results.filter { $0 == .failure(CameraBusy(runningOperation: "refresh slots")) }.count, 1,
                       "and the other is the gate's refusal")

        XCTAssertEqual(m.slotReader.slots.count, 7, "one clean read, not two interleaved ones")
        XCTAssertEqual(m.slotReader.slots.filter(\.isOccupied).count, occupied)
    }

    /// A push refused by the gate must say so rather than silently doing nothing.
    func testAPushRefusedByTheGateReportsItself() async {
        let (m, _) = await connect(MockCameraFaults())
        let settings = RecipeSettings(filmSimulation: .classicNeg)

        async let first = m.slotWriter.push(settings: settings, name: "A", toSlot: 1)
        async let second = m.slotWriter.push(settings: settings, name: "B", toSlot: 2)
        let results = await [first, second]

        let refused = results.filter { $0.outcome == .notWritten }
        XCTAssertEqual(refused.count, 1, "exactly one push was let through")
        XCTAssertNotNil(refused.first?.refusedBy, "and the other says the gate refused it")
        XCTAssertTrue(refused.first?.errorMessage?.contains("still running") ?? false,
                      "in words: \(refused.first?.errorMessage ?? "nil")")
    }

    // MARK: Controls — the gate must not break the normal path

    func testProbesStillRunOneAfterTheOther() async throws {
        let (m, _) = await connect(MockCameraFaults())

        let first = try await m.diagnostics.probeProperties(slot: 2)
        let second = try await m.diagnostics.probeWriteValues(slot: 2, property: .grain, candidates: [2, 1])

        XCTAssertFalse(first.probes.isEmpty)
        XCTAssertEqual(second.count, 2)
    }

    func testASlotReadStillWorksWhenNothingElseIsRunning() async throws {
        let (m, t) = await connect(MockCameraFaults())
        let writesBefore = await t.totalWriteCount

        try await m.slotReader.requestRefresh()

        XCTAssertEqual(m.slotReader.slots.count, 7)
        // It actually re-read rather than being quietly refused: seven more slot selects went out,
        // plus the one that puts the selected bank back.
        let writesAfter = await t.totalWriteCount
        XCTAssertEqual(writesAfter - writesBefore, 7 + 1)
    }
    func testLostCandidateReplyStopsProbeAndDefersRecoveryWrites() async throws {
        var faults = MockCameraFaults()
        faults.lostWriteResponseCodes = [FujiPTP.PresetProp.grain.rawValue]
        let (manager, transport) = await connect(faults)
        let before = await transport.totalWriteCount
        let entries = try await manager.diagnostics.probeWriteValues(slot: 2, property: .grain, candidates: [2, 1, 3])
        let after = await transport.totalWriteCount
        let held = await transport.storedProperty(FujiPTP.PresetProp.grain.rawValue, slot: 2)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.completionUnknown, true)
        XCTAssertTrue(entries.first?.outcome.contains("outcome unknown") == true)
        XCTAssertEqual(after - before, 2, "only the initial select and first candidate were sent")
        XCTAssertEqual(held, FujiEncoding.packU16(2), "the unconfirmed write may have taken effect")
        XCTAssertTrue(manager.reports.report?.notes.contains { $0.contains("reconnect before recovering") } == true)
    }

    func testOldPushCompletionCannotScanOrRecordAgainstReplacementSession() async {
        let (manager, oldTransport) = await connect(MockCameraFaults())
        let held = expectation(description: "old write is in flight")
        await oldTransport.holdNextWrite(to: FujiPTP.PresetProp.filmSimulation.rawValue) { held.fulfill() }
        let push = Task { await manager.slotWriter.push(settings: RecipeSettings(filmSimulation: .velvia), name: "Old session", toSlot: 1) }
        await fulfillment(of: [held], timeout: 10)
        await manager.connector.disconnect()
        var faults = MockCameraFaults(productName: "FUJIFILM X-T5")
        faults.isInstant = true
        let replacement = MockCameraTransport(faults: faults)
        await manager.connector.connectDemo(using: replacement)
        let before = await replacement.totalWriteCount
        let reportCount = manager.reports.report?.pushes?.count
        await oldTransport.releaseHeldWrite()
        let result = await push.value
        let after = await replacement.totalWriteCount
        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertEqual(after, before, "an old completion must not trigger a selector scan on the new camera")
        XCTAssertEqual(manager.reports.report?.pushes?.count, reportCount)
        XCTAssertEqual(manager.session.connected?.model?.id, "X-T5")
        XCTAssertEqual(manager.session.status, .connected)
    }

    /// `connect` reports `.connected` before its own slot read has finished, and that read selects
    /// every slot in turn. A push or a probe started in that window is refused, not interleaved
    /// with the walk: interleaved, it would write into whichever slot the walk had just selected.
    func testNothingElseCanStartDuringTheConnectTimeSlotRead() async throws {
        var faults = MockCameraFaults()
        faults.isInstant = true
        let transport = MockCameraTransport(faults: faults)
        let manager = CameraServices()
        let held = expectation(description: "the connect-time slot read is selecting a slot")
        await transport.holdNextWrite(to: FujiPTP.Prop.slotSelector) { held.fulfill() }
        let connect = Task { await manager.connector.connectDemo(using: transport) }
        await fulfillment(of: [held], timeout: 10)
        XCTAssertTrue(manager.session.isConnected, "precondition: the session reads as connected while its slot read runs")
        let writesMidWalk = await transport.totalWriteCount

        let probe = await busyRefusal { () async throws(CameraBusy) in try await manager.diagnostics.probeProperties(slot: 3) }
        let push = await manager.slotWriter.push(settings: RecipeSettings(filmSimulation: .velvia), name: "Mid-walk", toSlot: 3)
        let writesAfterRefusals = await transport.totalWriteCount
        let walk = CameraBusy(runningOperation: "refresh slots")
        XCTAssertEqual(probe, walk, "the property report is refused while the connect-time read is walking the slots")
        XCTAssertEqual(push.refusedBy, walk, "and so is a push")
        XCTAssertEqual(push.outcome, .notWritten)
        XCTAssertEqual(writesAfterRefusals, writesMidWalk, "neither wrote anything, not even a slot select")

        await transport.releaseHeldWrite()
        await connect.value
        XCTAssertEqual(manager.session.status, .connected)
        XCTAssertEqual(manager.slotReader.slots.count, 7, "the walk finished as one clean read")
        let report = try await manager.diagnostics.probeProperties(slot: 3)
        XCTAssertFalse(report.probes.isEmpty, "and the gate opens again once the walk is done")
    }

}

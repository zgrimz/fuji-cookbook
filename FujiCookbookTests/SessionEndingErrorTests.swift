import XCTest
@testable import FujiCookbook

/// Which errors end the session for a loop over camera commands, decided once in
/// `CameraError.endsSession`, and every loop that walks properties stopping on exactly those.
///
/// The timeouts here are the mock's one-shot `.noResponse`, standing for the transport's own command
/// timeout rather than any one body's behaviour.
@MainActor
final class SessionEndingErrorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CameraReportStore.deleteLatest()
    }

    private func connect(_ faults: MockCameraFaults = MockCameraFaults()) async -> (CameraServices, MockCameraTransport) {
        var faults = faults
        faults.isInstant = true
        let transport = MockCameraTransport(faults: faults)
        let manager = CameraServices()
        await manager.connector.connectDemo(using: transport)
        return (manager, transport)
    }

    private func failureMessage(_ status: CameraSession.Status) -> String? {
        guard case .failed(let message) = status else { return nil }
        return message
    }

    func testADisconnectAndATimeoutEndTheSession() {
        XCTAssertTrue(CameraError.endsSession(CameraError.disconnectedDuringOperation))
        XCTAssertTrue(CameraError.endsSession(CameraError.timeout))
    }

    /// A refusal is the camera answering about one command; the next one can still be sent.
    func testARefusalOrAnUnclassifiedFailureDoesNot() {
        XCTAssertFalse(CameraError.endsSession(CameraError.ptpError(code: FujiPTP.responseDevicePropNotSupported)))
        XCTAssertFalse(CameraError.endsSession(CameraError.ptpError(code: 0x2019)))
        XCTAssertFalse(CameraError.endsSession(CameraError.sessionFailed("unmapped")))
        XCTAssertFalse(CameraError.endsSession(CameraError.slotSelectFailed(slot: 2, code: nil)))
        XCTAssertFalse(CameraError.endsSession(CocoaError(.fileReadUnknown)))
    }

    func testATimeoutOnAPresetPropertyReadEndsTheWalk() async throws {
        let (m, transport) = await connect()
        XCTAssertEqual(m.slotReader.walk, .finished(slotCount: 7), "precondition: the connect walk finished")
        await transport.queueRead(.noResponse, for: FujiPTP.PresetProp.grain.rawValue)

        let result = await m.slotReader.refresh()

        XCTAssertEqual(result.walk, .failed(CameraError.timeout.cameraLogDescription))
        XCTAssertEqual(m.slotReader.walk, .failed)
        XCTAssertEqual(failureMessage(m.session.status), CameraError.timeout.message)
        let notes = m.reports.report?.notes ?? []
        XCTAssertTrue(notes.contains { $0.hasPrefix("slot read aborted") }, "\(notes)")
    }

    func testATimeoutInTheReadOnlySweepEndsIt() async throws {
        var faults = MockCameraFaults.noSlotProtocolBody
        faults.presentsAsHardware = true
        let (m, transport) = await connect(faults)
        XCTAssertEqual(m.slotReader.walk, .sweptReadOnly, "precondition: this body takes the sweep")
        await transport.queueRead(.noResponse, for: FujiPTP.Prop.presetName)

        let result = await m.slotReader.refresh()

        XCTAssertEqual(result.walk, .notWalked, "a sweep that did not complete")
        XCTAssertEqual(failureMessage(m.session.status), CameraError.timeout.message)
        let notes = m.reports.report?.notes ?? []
        XCTAssertTrue(notes.contains { $0.hasPrefix("sweep aborted") }, "\(notes)")
        let entries = try XCTUnwrap(m.reports.report?.propertySweep?.entries)
        XCTAssertEqual(entries.map(\.code), [PTPHex.code(FujiPTP.Prop.slotSelector)],
                       "the sweep stopped at the read that timed out")
    }

    /// The name read is one of the walk's reads, so a timeout on it ends the walk like any other.
    func testATimeoutOnASlotsNameReadEndsTheWalk() async throws {
        let (m, transport) = await connect()
        await transport.queueRead(.noResponse, for: FujiPTP.Prop.presetName)
        let writesBefore = await transport.totalWriteCount

        let result = await m.slotReader.refresh()

        XCTAssertEqual(result.walk, .failed(CameraError.timeout.cameraLogDescription))
        XCTAssertEqual(m.slotReader.walk, .failed)
        XCTAssertEqual(failureMessage(m.session.status), CameraError.timeout.message)
        let writes = await transport.totalWriteCount - writesBefore
        XCTAssertEqual(writes, 1, "the C1 select and nothing after it: no further select, no restore")
    }

    /// A timeout on the C1 select is reported as the timeout, not as a select the camera refused.
    func testATimeoutOnTheFirstSlotSelectEndsTheWalkAsATimeout() async throws {
        let (m, transport) = await connect()
        await transport.queueWrite(.noResponse, for: FujiPTP.Prop.slotSelector)

        let result = await m.slotReader.refresh()

        XCTAssertEqual(result.walk, .failed(CameraError.timeout.cameraLogDescription))
        XCTAssertEqual(failureMessage(m.session.status), CameraError.timeout.message)
    }

    /// A timeout on a later select is not a body with fewer slots than the registry assumes: the
    /// walk fails, and no slot count is remembered for the Chapter screen.
    func testATimeoutOnALaterSlotSelectEndsTheWalkAndRemembersNoSlotCount() async throws {
        let name = "SessionEndingErrorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        var faults = MockCameraFaults(productName: "FUJIFILM X-S20", firmwareVersion: nil)
        faults.presentsAsHardware = true
        faults.isInstant = true
        let transport = MockCameraTransport(faults: faults)
        await transport.queueWrite(.normal, for: FujiPTP.Prop.slotSelector)
        await transport.queueWrite(.noResponse, for: FujiPTP.Prop.slotSelector)
        let m = CameraServices()
        m.slotReader.rememberedCameraDefaults = defaults

        await m.connector.connectDemo(using: transport)

        XCTAssertTrue(m.session.canPush, "precondition: a body the app writes to, so a finished walk is remembered")
        XCTAssertEqual(m.slotReader.walk, .failed)
        XCTAssertNil(m.slotReader.probedSlotCount)
        XCTAssertNil(RememberedCamera(defaults: defaults))
        XCTAssertEqual(failureMessage(m.session.status), CameraError.timeout.message)
        let notes = m.reports.report?.notes ?? []
        XCTAssertFalse(notes.contains { $0.contains("slot select refused") }, "\(notes)")
    }

    /// A timeout in the property report's reads ends it, keeping what was read before.
    func testATimeoutInThePropertyReportEndsIt() async throws {
        let (m, transport) = await connect()
        let grain = FujiPTP.PresetProp.grain.rawValue
        await transport.queueRead(.noResponse, for: grain)

        let result = try await m.diagnostics.probeProperties(slot: 1)

        XCTAssertEqual(failureMessage(m.session.status), CameraError.timeout.message)
        XCTAssertFalse(result.probes.isEmpty, "the reads before the timeout are kept")
        XCTAssertFalse(result.probes.contains { $0.code == grain }, "the read that timed out is the last one sent")
        let codes = FujiPTP.PresetProp.allCases.map(\.rawValue)
        XCTAssertLessThan(result.probes.count, codes.count + 2, "the reads after it are not sent")
        XCTAssertEqual(m.reports.report?.propertySweep?.entries.count, result.probes.count)
        let notes = m.reports.report?.notes ?? []
        XCTAssertTrue(notes.contains { $0.hasPrefix("property report aborted") }, "\(notes)")
    }

    /// The read that checks a select is one of the walk's reads too. Its timeout is not a select
    /// the camera ignored, which would end the walk "finished" one short and remember that count.
    func testATimeoutOnTheReadThatChecksALaterSelectEndsTheWalkAndRemembersNoSlotCount() async throws {
        let name = "SessionEndingErrorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        var faults = MockCameraFaults(productName: "FUJIFILM X-S20", firmwareVersion: nil)
        faults.presentsAsHardware = true
        faults.isInstant = true
        let transport = MockCameraTransport(faults: faults)
        // The walk's opening read, the C1 check, the C2 check.
        await transport.queueRead(.normal, for: FujiPTP.Prop.slotSelector)
        await transport.queueRead(.normal, for: FujiPTP.Prop.slotSelector)
        await transport.queueRead(.noResponse, for: FujiPTP.Prop.slotSelector)
        let m = CameraServices()
        m.slotReader.rememberedCameraDefaults = defaults

        await m.connector.connectDemo(using: transport)

        XCTAssertTrue(m.session.canPush, "precondition: a body the app writes to, so a finished walk is remembered")
        XCTAssertEqual(m.slotReader.walk, .failed)
        XCTAssertNil(RememberedCamera(defaults: defaults))
        XCTAssertEqual(failureMessage(m.session.status), CameraError.timeout.message)
        let notes = m.reports.report?.notes ?? []
        XCTAssertFalse(notes.contains { $0.contains("did not take") }, "\(notes)")
    }

    /// A timeout on the read that checks the property report's select ends the report before it
    /// reads anything, rather than reading on under the slot it asked for.
    func testATimeoutOnTheReadThatChecksThePropertyReportsSelectEndsIt() async throws {
        let (m, transport) = await connect()
        // The read before the select, then the check after it.
        await transport.queueRead(.normal, for: FujiPTP.Prop.slotSelector)
        await transport.queueRead(.noResponse, for: FujiPTP.Prop.slotSelector)

        let result = try await m.diagnostics.probeProperties(slot: 2)

        XCTAssertEqual(failureMessage(m.session.status), CameraError.timeout.message)
        XCTAssertTrue(result.probes.isEmpty)
    }
}

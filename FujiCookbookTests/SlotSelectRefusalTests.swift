import XCTest
@testable import FujiCookbook

/// A refused slot select names the camera's answer at every site that selects a slot: the connect's
/// slot walk, a push, and the property report. The answer is what tells a busy body (`0x2019`)
/// from a slot the body doesn't have (`0x200A`, zgrimz/fujifilm-ptp-reference
/// `docs/04-custom-slots.md#how-many-banks`), and the tester reads it off the screen.
///
/// Camera facts in these tests are from zgrimz/fujifilm-ptp-reference: `docs/01-transport.md#response-codes`.
@MainActor
final class SlotSelectRefusalTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CameraReportStore.deleteLatest()
    }

    private func connect(_ faults: MockCameraFaults) async -> (CameraServices, MockCameraTransport) {
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

    func testTheConnectWalkNamesTheAnswerThatRefusedC1() async throws {
        let (m, _) = await connect(.busyXM5)

        let message = try XCTUnwrap(failureMessage(m.session.status), "got \(m.session.status)")
        XCTAssertTrue(message.contains("C1"), message)
        XCTAssertTrue(message.contains("Device Busy (0x2019)"), message)
        XCTAssertTrue(m.slotReader.slots.isEmpty)
        let notes = m.reports.report?.notes ?? []
        XCTAssertTrue(notes.contains { $0.hasPrefix("slot read aborted") && $0.contains("0x2019") },
                      "the report says what the camera answered: \(notes)")
    }

    func testAPushNamesTheAnswerThatRefusedItsSelect() async throws {
        let (m, _) = await connect(.busyXM5)

        let r = await m.slotWriter.push(settings: .neutral, name: "Busy", toSlot: 2)

        XCTAssertEqual(r.outcome, .notWritten)
        let message = try XCTUnwrap(r.errorMessage)
        XCTAssertTrue(message.contains("C2"), message)
        XCTAssertTrue(message.contains("Device Busy (0x2019)"), message)
    }

    func testThePropertyReportNamesTheAnswerThatRefusedItsSelect() async throws {
        let (m, _) = await connect(.busyXM5)

        _ = try await m.diagnostics.probeProperties(slot: 2)

        let message = try XCTUnwrap(failureMessage(m.session.status), "got \(m.session.status)")
        XCTAssertTrue(message.contains("C2"), message)
        XCTAssertTrue(message.contains("Device Busy (0x2019)"), message)
    }

    /// A select that failed without a response — a timeout, a dropped cable — has no answer to
    /// name, and keeps the plain sentence.
    func testASelectThatFailedWithoutAnAnswerKeepsThePlainMessage() {
        let error = CameraError.slotSelectFailed(3, after: CameraError.timeout)
        XCTAssertEqual(error, .slotSelectFailed(slot: 3, code: nil))
        XCTAssertEqual(error.message, "Couldn't select custom slot C3 on the camera. Nothing was changed.")
    }

    /// A response PTP has no name for is still shown, as the bare code.
    func testAnUnnamedAnswerIsShownAsItsCode() {
        let error = CameraError.slotSelectFailed(1, after: CameraError.ptpError(code: 0xA001))
        XCTAssertEqual(error.message, "Couldn't select custom slot C1 on the camera: it answered 0xA001. Nothing was changed.")
    }
}

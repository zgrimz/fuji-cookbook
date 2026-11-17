import XCTest
@testable import FujiCookbook

/// Recovery after an established hardware session drops, driven through `HeldCameraDiscovery`.
///
/// Each recovery attempt first sleeps for `RecoveryPolicy.plan`'s delay, so a test that reaches
/// an attempt waits half a second for it.
@MainActor
final class ConnectionRecoveryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CameraReportStore.deleteLatest()
    }

    override func tearDown() {
        CameraReportStore.deleteLatest()
        super.tearDown()
    }

    /// Unplugs `camera` and returns once the recovery that follows is waiting for it to come back.
    private func loseAndWaitForRecoveryAttempt(_ camera: FakeDiscoveredCamera,
                                               _ manager: CameraServices,
                                               _ discovery: HeldCameraDiscovery) async {
        let waiting = expectation(description: "recovery is waiting for the camera")
        discovery.onWait = { waiting.fulfill() }
        discovery.attached = nil
        discovery.onDeviceRemoved?(camera)
        XCTAssertTrue(manager.connector.isRecovering)
        await fulfillment(of: [waiting], timeout: 10)
        discovery.onWait = nil
    }

    func testARecoveryThatReconnectsIsNoLongerRecovering() async {
        let discovery = HeldCameraDiscovery()
        let camera = FakeDiscoveredCamera()
        discovery.attached = camera
        let manager = CameraServices(discovery: { discovery })
        await manager.connector.connectHardware()
        await loseAndWaitForRecoveryAttempt(camera, manager, discovery)

        discovery.attach(camera)
        let deadline = ContinuousClock.now + .seconds(10)
        while manager.connector.isRecovering {
            guard ContinuousClock.now < deadline else {
                XCTFail("the recovery that reconnected was still recovering after 10 seconds")
                break
            }
            await Task.yield()
        }

        XCTAssertFalse(manager.connector.isRecovering)
        XCTAssertEqual(manager.session.status, .connected)
        await manager.connector.disconnect()
    }

    /// A recovery that a manual Reconnect cancelled runs on until its next cancellation check, and
    /// the next loss can start another before it gets there. When it does end, the newer recovery
    /// is still the one running. The held discovery ignores the cancel, which stretches that window
    /// to whenever the test ends the first recovery's wait.
    func testACancelledRecoveryLeavesItsReplacementRunning() async {
        let discovery = HeldCameraDiscovery()
        let camera = FakeDiscoveredCamera()
        discovery.attached = camera
        let manager = CameraServices(discovery: { discovery })
        await manager.connector.connectHardware()
        await loseAndWaitForRecoveryAttempt(camera, manager, discovery)

        // Reconnect while the first recovery is still held in discovery, which ignores its cancel.
        discovery.attached = camera
        await manager.connector.connectHardware()
        XCTAssertEqual(manager.session.status, .connected)
        XCTAssertFalse(manager.connector.isRecovering, "the Reconnect cancelled the first recovery")

        // A second loss starts a second recovery; then the first one's wait ends, and so does it.
        discovery.attached = nil
        discovery.onDeviceRemoved?(camera)
        XCTAssertTrue(manager.connector.isRecovering)
        let secondWaiting = expectation(description: "the second recovery is waiting for the camera")
        discovery.onWait = { secondWaiting.fulfill() }
        discovery.failWaits(with: CameraError.noDeviceConnected)
        await fulfillment(of: [secondWaiting], timeout: 10)
        discovery.onWait = nil

        XCTAssertTrue(manager.connector.isRecovering, "the first recovery ending did not drop the second")
        await manager.connector.disconnect()
        XCTAssertFalse(manager.connector.isRecovering, "and a disconnect still stops the second")
        discovery.failWaits(with: CameraError.noDeviceConnected)
    }
}

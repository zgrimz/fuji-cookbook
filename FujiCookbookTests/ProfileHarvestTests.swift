import XCTest
@testable import FujiCookbook

/// The profile harvest: upload one RAF, read `0xD185`, stop.
///
/// The claim under test is what it does *not* do as much as what it does. It is the first half of
/// a develop on a body the app refuses to develop on, and the trace has to show that the second
/// half never happened: no profile written back, no conversion triggered, no JPEG fetched.
///
/// Camera facts in these tests are from zgrimz/fujifilm-ptp-reference:
/// `docs/05-raw-conversion.md#the-sequence`, `docs/06-conversion-profile.md#lengths-seen`,
/// `docs/07-cameras.md#gfx100s`, and `evidence/gfx100s-20260917-211657`.
@MainActor
final class ProfileHarvestTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CameraReportStore.deleteLatest()
    }

    private func connected(_ faults: MockCameraFaults) async -> CameraServices {
        var faults = faults
        faults.isInstant = true
        let manager = CameraServices()
        await manager.connector.connectDemo(using: MockCameraTransport(faults: faults))
        return manager
    }

    /// A body the registry reads from and writes to but does not develop on — and whose `0xD185`
    /// refuses until it has been given a RAF, exactly as the real one did.
    ///
    /// The GFX100S held this role until 2026-09-17, when its owner's harvest came back with a
    /// 621-byte profile and the Kitchen was turned on for it. The GFX100 is the sibling that still
    /// has no blob of its own: same registry entry, writable on the GFX100S's report, Kitchen off.
    private var noKitchenBody: MockCameraFaults {
        MockCameraFaults(productName: "FUJIFILM GFX 100", firmwareVersion: nil, profileNeedsUpload: true)
    }

    private let raf = Data(repeating: 0x46, count: 4096)

    private func count(_ m: CameraServices, _ operation: String, param: String? = nil) -> Int {
        (m.reports.report?.transactions ?? []).filter {
            $0.operation == operation && (param == nil || $0.parameters.first == param)
        }.count
    }

    // MARK: The point

    func testABodyTheAppDoesNotDevelopOnCanStillHaveItsProfileHarvested() async throws {
        let m = await connected(noKitchenBody)
        XCTAssertEqual(m.session.model?.id, "GFX100")
        XCTAssertFalse(m.session.canConvert, "the registry does not develop on this body")
        XCTAssertTrue(m.conversion.canHarvestProfile, "and that is not what the harvest asks")

        let harvested = try await m.conversion.harvestConversionProfile(raf: raf)
        let outcome = try XCTUnwrap(harvested)

        XCTAssertEqual(outcome.record.uploadOutcome, "accepted")
        XCTAssertNotNil(outcome.record.profileLength)
        XCTAssertNotNil(outcome.record.layoutBase, "the demo profile resolves — that is the whole answer")
        XCTAssertTrue(outcome.layoutResolved)
        XCTAssertEqual(outcome.record.rafBytes, raf.count)
    }

    /// The before/after contrast is what makes the record readable on its own: a refusal that
    /// became a profile once the camera had something to describe.
    func testTheRecordShowsTheRefusalBeforeAndTheProfileAfter() async throws {
        let m = await connected(noKitchenBody)
        let harvested = try await m.conversion.harvestConversionProfile(raf: raf)
        let outcome = try XCTUnwrap(harvested)

        XCTAssertTrue(outcome.record.profileBeforeUpload?.contains("0x2002") == true,
                      "before the upload the camera refuses, as two real reports showed: \(outcome.record.profileBeforeUpload ?? "nil")")
        XCTAssertGreaterThan(outcome.record.profileLength ?? 0, 0, "after it there is a profile")
    }

    func testTheHarvestNeverDevelops() async throws {
        let m = await connected(noKitchenBody)
        let harvested = try await m.conversion.harvestConversionProfile(raf: raf)
        _ = try XCTUnwrap(harvested)

        XCTAssertEqual(count(m, "0x900C"), 1, "one SendObjectInfo")
        XCTAssertEqual(count(m, "0x900D"), 1, "one SendObject2")
        XCTAssertGreaterThanOrEqual(count(m, "0x1015", param: "0xD185"), 2, "0xD185 read before and after")
        XCTAssertEqual(count(m, "0x1016", param: "0xD185"), 0, "the profile is never written back")
        XCTAssertEqual(count(m, "0x1016", param: "0xD183"), 0, "no conversion is ever triggered")
        XCTAssertEqual(count(m, "0x1009"), 0, "no JPEG is ever fetched")
    }

    // MARK: The gate

    /// Deliberately still a GFX100S spelling, and deliberately one whose Kitchen is now *on*: the
    /// gate is identification, not capability, so a guess is refused either way. (It also has to
    /// stay this body — "FUJIFILM GFX 100 TETHER" resolves to `.unknown` rather than a guess, which
    /// would be a different test.)
    func testAGuessedBodyIsNotHarvested() async throws {
        let m = await connected(MockCameraFaults(productName: "FUJIFILM GFX100S TETHER", firmwareVersion: "2.13"))
        XCTAssertEqual(m.session.model?.id, "GFX100S", "matched by name pattern")
        XCTAssertFalse(m.conversion.canHarvestProfile, "a guess reads; it does not get a RAF sent to it")

        let outcome = try await m.conversion.harvestConversionProfile(raf: raf)
        XCTAssertNil(outcome)
        XCTAssertEqual(count(m, "0x900C"), 0, "and nothing went over the wire")
    }

    /// The gate is about trust, not about conversion being enabled — a body the app already
    /// develops on may be harvested too, it just won't be offered.
    func testAConvertingBodyMayBeHarvestedAsWell() async throws {
        let m = await connected(MockCameraFaults())
        XCTAssertTrue(m.session.canConvert)
        XCTAssertTrue(m.conversion.canHarvestProfile)
        let harvested = try await m.conversion.harvestConversionProfile(raf: raf)
        XCTAssertNotNil(harvested)
    }

    // MARK: The two refusals, which are two different findings

    func testARefusedUploadStopsTheHarvest() async throws {
        var faults = noKitchenBody
        faults.rejectsUpload = 0x2002
        let m = await connected(faults)
        let harvested = try await m.conversion.harvestConversionProfile(raf: raf)
        let outcome = try XCTUnwrap(harvested)

        XCTAssertEqual(outcome.record.failureReason, "upload_general_error")
        XCTAssertTrue(outcome.record.uploadOutcome.contains("0x2002"))
        XCTAssertNil(outcome.record.profileLength)
        XCTAssertEqual(count(m, "0x1015", param: "0xD185"), 1,
                       "only the before-read; there is no after to read")
        XCTAssertFalse(outcome.layoutResolved)
    }

    func testAProfileStillRefusedAfterAGoodUploadIsRecordedAsTheFinding() async throws {
        var faults = noKitchenBody
        faults.profileNeedsUpload = false
        faults.unsupportedReadCodes = [FujiPTP.Prop.rawConvProfile]
        let m = await connected(faults)
        let harvested = try await m.conversion.harvestConversionProfile(raf: raf)
        let outcome = try XCTUnwrap(harvested)

        XCTAssertEqual(outcome.record.uploadOutcome, "accepted", "the upload itself was fine")
        XCTAssertNil(outcome.record.profileLength)
        XCTAssertNil(outcome.record.layoutBase)
        XCTAssertNotNil(outcome.record.profileReadError, "and the refusal after it is the finding")
        XCTAssertNotNil(outcome.record.failureReason)
    }

    // MARK: What the upload leaves behind

    func testAnUploadThatAppearsAsAnObjectIsTakenBack() async throws {
        var faults = noKitchenBody
        faults.uploadCreatesObject = true
        let m = await connected(faults)
        let harvested = try await m.conversion.harvestConversionProfile(raf: raf)
        let outcome = try XCTUnwrap(harvested)

        XCTAssertEqual(outcome.record.uploadCreatedObject, true)
        XCTAssertEqual(outcome.record.objectDeleted, true)
        XCTAssertEqual(count(m, "0x100B"), 1, "one DeleteObject")
        XCTAssertNotNil(outcome.record.profileAfterDelete, "and 0xD185 is read once more to see what the delete did")
    }

    func testAnUploadThatLeavesNoObjectSaysSo() async throws {
        let m = await connected(noKitchenBody)
        let harvested = try await m.conversion.harvestConversionProfile(raf: raf)
        let outcome = try XCTUnwrap(harvested)

        XCTAssertEqual(outcome.record.uploadCreatedObject, false)
        XCTAssertNil(outcome.record.objectDeleted)
        XCTAssertEqual(count(m, "0x100B"), 0)
    }

    // MARK: The record outlives the screen

    func testTheRecordIsInTheSavedReportAndSurvivesTheReconnectThePassRequires() async throws {
        let transport = MockCameraTransport(faults: {
            var f = noKitchenBody; f.isInstant = true; return f
        }())
        let m = CameraServices()
        await m.connector.connectDemo(using: transport)
        let harvested = try await m.conversion.harvestConversionProfile(raf: raf)
        _ = try XCTUnwrap(harvested)

        XCTAssertEqual(CameraReportStore.loadLatest()?.profileHarvests?.count, 1,
                       "in the file the tester sends, not only in memory")

        await m.connector.disconnect()
        await m.connector.connectDemo(using: transport)
        XCTAssertEqual(m.reports.report?.profileHarvests?.count, 1,
                       "the same body picks its harvest back up across the unplug the pass asks for")
    }

    // MARK: The runner the step calls

    func testTheRunnerReportsAResolvedLayoutAsRan() async {
        let m = await connected(noKitchenBody)
        let outcome = await GuidedTestRunner.runProfileHarvest(m, raf: raf)
        XCTAssertEqual(outcome.state, .ran)
        XCTAssertTrue(outcome.detail?.contains("layout resolved") == true, outcome.detail ?? "nil")
    }

    /// A refused upload is the tester's to fix, so it ends on "try again" rather than being filed.
    func testTheRunnerReportsARefusedUploadAsFailedSoTheStepOffersARetry() async {
        var faults = noKitchenBody
        faults.rejectsUpload = 0x2002
        let m = await connected(faults)
        let outcome = await GuidedTestRunner.runProfileHarvest(m, raf: raf)
        XCTAssertEqual(outcome.state, .failed)
        XCTAssertTrue(outcome.detail?.contains("0x2002") == true, outcome.detail ?? "nil")
    }

    func testTheRunnerDoesNotSendAFileToAGuessedBody() async {
        let m = await connected(MockCameraFaults(productName: "FUJIFILM GFX100S TETHER", firmwareVersion: "2.13"))
        let outcome = await GuidedTestRunner.runProfileHarvest(m, raf: raf)
        XCTAssertEqual(outcome.state, .notWritable)
        XCTAssertEqual(count(m, "0x900C"), 0)
    }

    // MARK: The demo that shows the step

    /// The Diagnostic Mode demo that makes this step reachable without owning such a body: a mock
    /// that presents as a GFX100 and refuses `0xD185` until it has a RAF. Walked in the Simulator on
    /// 2026-09-16 — consent card, picker, 625-byte profile, layout resolved, record on disk. That
    /// walk was of the GFX100S preset; on 2026-09-17 only the product name moved, when the real
    /// GFX100S's harvest turned its Kitchen on and a preset named for it would have demonstrated
    /// the opposite of its own name.
    func testTheDemoNoKitchenPresetIsABodyTheStepOffersTheHarvestOn() async {
        let m = await connected(.gfx100WithoutKitchen)
        XCTAssertEqual(m.session.model?.id, "GFX100")
        XCTAssertEqual(m.session.connected?.identification.confidence, "alias",
                       "spelled with a space, so not exact — and trusted anyway, which is the gate")
        XCTAssertFalse(m.session.canConvert, "the Kitchen is off for it, as on the real body")
        XCTAssertTrue(GuidedTestFlow.offersProfileHarvest(facts: GuidedTestRunner.facts(m)))
    }
}

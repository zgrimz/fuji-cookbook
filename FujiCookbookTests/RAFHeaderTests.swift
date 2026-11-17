import XCTest
@testable import FujiCookbook

/// The RAF header check that runs before an upload.
///
/// A Fujifilm body develops only its own files (zgrimz/fujifilm-ptp-reference
/// `docs/05-raw-conversion.md#prerequisites`), and the RAF header names the body that shot it (the
/// layout and its sources are in `RAFHeader`). Reading it costs nothing and settles, before a
/// 50 MB upload, what the camera's General Error afterwards can't: `0x2002` names no cause.
///
/// Camera facts in these tests are from zgrimz/fujifilm-ptp-reference: `docs/01-transport.md#response-codes`.
@MainActor
final class RAFHeaderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CameraReportStore.deleteLatest()
    }

    /// `RAFFixture.raf`, with the model named at every call: these tests are about the header.
    private func raf(model: String, cameraID: String = "FF189504", firmware: String = "0132",
                     length: Int = 4096) -> Data {
        RAFFixture.raf(model: model, cameraID: cameraID, firmware: firmware, length: length)
    }

    private func model(_ id: String) throws -> CameraModel {
        try XCTUnwrap(CameraModelRegistry.shared.model(matchingProductName: id))
    }

    // MARK: Parsing

    func testAnXT50HeaderParses() throws {
        let header = try XCTUnwrap(RAFHeader(raf(model: "X-T50")))
        XCTAssertEqual(header.cameraID, "FF189504")
        XCTAssertEqual(header.model, "X-T50")
        XCTAssertEqual(header.firmware, "0132")
    }

    func testAnythingElseIsNotAHeader() {
        XCTAssertNil(RAFHeader(Data(repeating: 0xAB, count: 4096)), "arbitrary bytes")
        XCTAssertNil(RAFHeader(Data(repeating: 0x46, count: 64)))
        XCTAssertNil(RAFHeader(raf(model: "X-T50").prefix(40)), "too short to hold the model")
        XCTAssertNil(RAFHeader(Data()))
        var blankModel = raf(model: "X-T50")
        blankModel.replaceSubrange(28..<60, with: Data(repeating: 0, count: 32))
        XCTAssertNil(RAFHeader(blankModel), "a header with no model name decides nothing")
        var binaryModel = raf(model: "X-T50")
        binaryModel.replaceSubrange(28..<32, with: Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertNil(RAFHeader(binaryModel))
    }

    func testTheMagicIsWhatTheFormatSnifferLooksFor() {
        XCTAssertEqual(FileKind.detect(raf(model: "X-T50")), .raf)
    }

    // MARK: Whose file it is

    func testTheHeaderNamesTheConnectedBodyOrAnother() throws {
        let xt50 = try model("X-T50")
        let header = try XCTUnwrap(RAFHeader(raf(model: "X-T50")))
        XCTAssertEqual(header.origin(for: xt50), .sameBody)
        XCTAssertEqual(header.origin(for: try model("X-T5")), .otherBody(xt50))
        XCTAssertEqual(try XCTUnwrap(RAFHeader(raf(model: "X-T5"))).origin(for: xt50), .otherBody(try model("X-T5")))
    }

    /// Fujifilm spells one body more than one way across its own strings; the registry's
    /// identification already knows the spellings it trusts, and the check uses nothing stricter.
    func testASpellingTheRegistryTrustsCountsAsThatBody() throws {
        let gfx100 = try model("GFX100")
        XCTAssertEqual(try XCTUnwrap(RAFHeader(raf(model: "GFX 100"))).origin(for: gfx100), .sameBody)
        XCTAssertEqual(try XCTUnwrap(RAFHeader(raf(model: "GFX100"))).origin(for: gfx100), .sameBody)
        XCTAssertEqual(try XCTUnwrap(RAFHeader(raf(model: "GFX100S"))).origin(for: gfx100),
                       .otherBody(try model("GFX100S")))
    }

    func testAModelTheRegistryCannotPlaceDecidesNothing() throws {
        let header = try XCTUnwrap(RAFHeader(raf(model: "X-Q9")))
        XCTAssertEqual(header.origin(for: try model("X-T50")), .undetermined)
    }

    func testTheDemoCameraIsNeverAMismatch() throws {
        let header = try XCTUnwrap(RAFHeader(raf(model: "X-T50")))
        XCTAssertEqual(header.origin(for: CameraModelRegistry.shared.demoModel), .undetermined)
    }

    // MARK: Through the Kitchen

    private func connected(_ faults: MockCameraFaults) async -> CameraServices {
        var faults = faults
        faults.isInstant = true
        let manager = CameraServices()
        await manager.connector.connectDemo(using: MockCameraTransport(faults: faults))
        return manager
    }

    private func uploads(_ m: CameraServices) -> Int {
        (m.reports.report?.transactions ?? []).filter { $0.operation == "0x900C" }.count
    }

    func testAFileFromAnotherBodyIsRefusedBeforeAnythingIsSent() async throws {
        let m = await connected(MockCameraFaults(productName: "FUJIFILM X-T50"))
        XCTAssertEqual(m.session.connected?.model?.id, "X-T50")
        XCTAssertTrue(m.session.canConvert)
        let result = await m.conversion.cook(raf: raf(model: "X-T5"), filename: "DSCF0001.RAF",
                                  settings: RecipeSettings(filmSimulation: .velvia))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.evidence.failureReason, "raf_from_different_body")
        let message = try XCTUnwrap(result.errorMessage)
        XCTAssertTrue(message.contains("X-T5)"), message)
        XCTAssertTrue(message.contains("this X-T50"), message)
        XCTAssertTrue(message.contains("Nothing was sent"), message)
        XCTAssertEqual(uploads(m), 0, "no SendObjectInfo in the trace")
    }

    func testTheBodysOwnFileIsUploaded() async throws {
        AppLog.clear(.kitchen)
        let m = await connected(MockCameraFaults(productName: "FUJIFILM X-T50"))
        let result = await m.conversion.cook(raf: raf(model: "X-T50"), filename: "DSCF0001.RAF",
                                  settings: RecipeSettings(filmSimulation: .velvia))
        defer { DevelopOutputRecovery.removeAfterLibrarySave(result.recoveryFileURL) }
        XCTAssertTrue(result.success, result.errorMessage ?? "")
        XCTAssertEqual(uploads(m), 1)
        XCTAssertTrue(AppLog.reportText(in: .kitchen).contains("RAF header names the connected body (X-T50)"),
                      "a passed check leaves a line, so a report can tell it from a file with no header")
    }

    /// `0x2002` to the upload of a file that names this body is a General Error a RAF from another
    /// body can't explain, and is reported as that rather than blamed on the file.
    func testAGeneralErrorOnTheBodysOwnFileIsNotBlamedOnTheFile() async throws {
        var faults = MockCameraFaults(productName: "FUJIFILM X-T50")
        faults.rejectsUpload = 0x2002
        let m = await connected(faults)
        let result = await m.conversion.cook(raf: raf(model: "X-T50"), filename: "DSCF0001.RAF",
                                  settings: RecipeSettings(filmSimulation: .velvia))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.evidence.failureReason, "upload_general_error")
        let message = try XCTUnwrap(result.errorMessage)
        XCTAssertTrue(message.contains("General Error 0x2002"), message)
        XCTAssertTrue(message.contains("isn't the cause"), message)
        XCTAssertEqual(uploads(m), 1, "the upload was attempted")
    }

    /// A header naming a body the registry can't place gives nothing to check, and an upload
    /// refusal alone doesn't establish a cause (zgrimz/fujifilm-ptp-reference
    /// `docs/05-raw-conversion.md#prerequisites`), so the message names none.
    func testAnUploadRefusalOnAFileTheRegistryCannotPlaceNamesNoCause() async throws {
        var faults = MockCameraFaults(productName: "FUJIFILM X-T50")
        faults.rejectsUpload = 0x2002
        let m = await connected(faults)
        let result = await m.conversion.cook(raf: raf(model: "X-Q9"), filename: "DSCF0001.RAF",
                                  settings: RecipeSettings(filmSimulation: .velvia))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.evidence.failureReason, "upload_general_error")
        let message = try XCTUnwrap(result.errorMessage)
        XCTAssertTrue(message.contains("General Error 0x2002"), message)
        XCTAssertFalse(message.contains("another camera"), message)
        XCTAssertEqual(uploads(m), 1, "sent: the header rules nothing out")
    }

    /// Where the published foreign-RAF failure lands: the camera takes the upload and refuses the
    /// profile read after it (same section). With nothing in the header to rule it out, that is
    /// the cause the message names.
    func testAProfileRefusalAfterUploadingAFileTheRegistryCannotPlaceNamesThePublishedCause() async throws {
        var faults = MockCameraFaults(productName: "FUJIFILM X-T50")
        faults.readResponseCodes = [FujiPTP.Prop.rawConvProfile: 0x2002]
        let m = await connected(faults)
        let result = await m.conversion.cook(raf: raf(model: "X-Q9"), filename: "DSCF0001.RAF",
                                  settings: RecipeSettings(filmSimulation: .velvia))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.evidence.failureReason, "raf_from_different_body")
        let message = try XCTUnwrap(result.errorMessage)
        XCTAssertTrue(message.contains("General Error 0x2002"), message)
        XCTAssertTrue(message.contains("another camera"), message)
        XCTAssertEqual(uploads(m), 1, "the upload itself was accepted")
    }

    /// The same refusal on a file whose header names this body is not blamed on the file.
    func testAProfileRefusalAfterUploadingTheBodysOwnFileIsNotBlamedOnTheFile() async throws {
        var faults = MockCameraFaults(productName: "FUJIFILM X-T50")
        faults.readResponseCodes = [FujiPTP.Prop.rawConvProfile: 0x2002]
        let m = await connected(faults)
        let result = await m.conversion.cook(raf: raf(model: "X-T50"), filename: "DSCF0001.RAF",
                                  settings: RecipeSettings(filmSimulation: .velvia))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.evidence.failureReason, "ptp_0x2002")
        let message = try XCTUnwrap(result.errorMessage)
        XCTAssertFalse(message.contains("another camera"), message)
    }

    /// A file with no RAF header is never a RAF, so it is refused before the upload: a camera can
    /// accept an upload and then have no profile to give, as an X-M5 answered `0x2002` to the
    /// `0xD185` read after one (zgrimz/fujifilm-ptp-reference `docs/07-cameras.md#x-m5`).
    func testAFileWithNoRAFHeaderIsRefusedBeforeAnythingIsSent() async throws {
        let m = await connected(MockCameraFaults(productName: "FUJIFILM X-M5"))
        let result = await m.conversion.cook(raf: Data(repeating: 0xAB, count: 4096), filename: "DSCF0001.RAF",
                                  settings: RecipeSettings(filmSimulation: .velvia))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.evidence.failureReason, "not_a_raf")
        let message = try XCTUnwrap(result.errorMessage)
        XCTAssertTrue(message.contains("isn't a Fujifilm RAW file"), message)
        XCTAssertTrue(message.contains("Nothing was sent"), message)
        XCTAssertEqual(uploads(m), 0, "no SendObjectInfo in the trace")
        XCTAssertTrue(AppLog.reportText(in: .kitchen).contains("no RAF header (unknown)"))
    }

    /// When the sniffer knows what the file is, the message says so: the JPEG of a RAW+JPEG pair
    /// is the likely pick.
    func testAJPEGIsNamedAsOne() async throws {
        let m = await connected(MockCameraFaults(productName: "FUJIFILM X-M5"))
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1])
        jpeg.append(Data(repeating: 0, count: 4092))
        let result = await m.conversion.cook(raf: jpeg, filename: "DSCF0001.JPG",
                                  settings: RecipeSettings(filmSimulation: .velvia))
        XCTAssertEqual(result.evidence.failureReason, "not_a_raf")
        let message = try XCTUnwrap(result.errorMessage)
        XCTAssertTrue(message.hasPrefix("“DSCF0001.JPG” is a JPEG, not a Fujifilm RAW file"), message)
        XCTAssertEqual(uploads(m), 0)
    }

    /// The harvest is a probe, so it sends a foreign file and records what the camera says to it —
    /// the observation the published claim lacks — with the header's verdict beside the answer. An
    /// upload refusal is filed as that and nothing more; a profile refusal after an accepted upload
    /// is where the published foreign-RAF failure lands.
    func testTheHarvestSendsAForeignFileAndSaysSo() async throws {
        var faults = MockCameraFaults(productName: "FUJIFILM GFX 100", firmwareVersion: nil, profileNeedsUpload: true)
        faults.rejectsUpload = 0x2002
        let m = await connected(faults)
        XCTAssertEqual(m.session.connected?.model?.id, "GFX100")
        let harvested = try await m.conversion.harvestConversionProfile(raf: raf(model: "X-T5"))
        let outcome = try XCTUnwrap(harvested)
        XCTAssertEqual(uploads(m), 1, "sent, unlike a develop")
        XCTAssertEqual(outcome.record.failureReason, "upload_general_error")
        XCTAssertTrue(outcome.record.uploadOutcome.contains("0x2002"), outcome.record.uploadOutcome)
        XCTAssertEqual(outcome.record.rafHeader, "names X-T5, not this GFX100")
        XCTAssertTrue(outcome.summary.contains("names X-T5, not this GFX100"), outcome.summary)

        var own = MockCameraFaults(productName: "FUJIFILM GFX 100", firmwareVersion: nil, profileNeedsUpload: true)
        own.rejectsUpload = 0x2002
        let m2 = await connected(own)
        let harvested2 = try await m2.conversion.harvestConversionProfile(raf: raf(model: "GFX 100"))
        let outcome2 = try XCTUnwrap(harvested2)
        XCTAssertEqual(outcome2.record.failureReason, "upload_general_error")
        XCTAssertEqual(outcome2.record.rafHeader, "names this body")

        var accepts = MockCameraFaults(productName: "FUJIFILM GFX 100", firmwareVersion: nil)
        accepts.readResponseCodes = [FujiPTP.Prop.rawConvProfile: 0x2002]
        let m3 = await connected(accepts)
        let harvested3 = try await m3.conversion.harvestConversionProfile(raf: raf(model: "X-T5"))
        let outcome3 = try XCTUnwrap(harvested3)
        XCTAssertEqual(outcome3.record.uploadOutcome, "accepted")
        XCTAssertEqual(outcome3.record.failureReason, "raf_from_different_body")

        let m4 = await connected(accepts)
        let harvested4 = try await m4.conversion.harvestConversionProfile(raf: raf(model: "GFX 100"))
        let outcome4 = try XCTUnwrap(harvested4)
        XCTAssertEqual(outcome4.record.failureReason, "ptp_0x2002", "the body's own file is not blamed")
    }

    /// The verdict is its own field. Appended to `uploadOutcome`, it made every RAF a camera shot
    /// (they all have headers) compare as refused, and the Camera Test's develop step failed on an
    /// upload that had worked.
    func testTheHarvestOfTheBodysOwnFileIsAcceptedNotRefused() async throws {
        let own = MockCameraFaults(productName: "FUJIFILM GFX 100", firmwareVersion: nil, profileNeedsUpload: true)
        let m = await connected(own)
        let harvested = try await m.conversion.harvestConversionProfile(raf: raf(model: "GFX 100"))
        let outcome = try XCTUnwrap(harvested)
        XCTAssertEqual(outcome.record.uploadOutcome, "accepted")
        XCTAssertEqual(outcome.record.rafHeader, "names this body")
        XCTAssertNil(outcome.record.failureReason)
        XCTAssertFalse(outcome.summary.hasPrefix("upload refused"), outcome.summary)
        XCTAssertTrue(outcome.summary.contains("names this body"), outcome.summary)

        let m2 = await connected(own)
        let step = await GuidedTestRunner.runProfileHarvest(m2, raf: raf(model: "GFX 100"))
        XCTAssertEqual(step.state, .ran, step.detail ?? "nil")
    }
}

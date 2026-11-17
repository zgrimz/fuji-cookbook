import XCTest
@testable import FujiCookbook

final class ObjectEnumerationTests: XCTestCase {
    private func dataset(_ handles: [UInt32], count: UInt32? = nil) -> Data {
        var data = Data()
        data.appendLE(count ?? UInt32(handles.count))
        for handle in handles { data.appendLE(handle) }
        return data
    }

    private func response(code: UInt16 = FujiPTP.responseOK, transactionID: UInt32 = 42) -> Data {
        var data = Data()
        data.appendLE(UInt32(12))
        data.appendLE(FujiPTP.ContainerType.response.rawValue)
        data.appendLE(code)
        data.appendLE(transactionID)
        return data
    }

    func testValidEmptyAndPopulatedEnumerations() throws {
        XCTAssertEqual(try FujiPTP.parseObjectHandles(dataset([])), [])
        XCTAssertEqual(try FujiPTP.parseObjectHandles(dataset([12, 34])), [12, 34])
    }

    func testMalformedEnumerationsNeverBecomeEmptyOrPartialSuccess() {
        let malformed: [Data?] = [nil, Data(), Data([0, 0, 0]), dataset([12], count: 2),
                                 dataset([12], count: 0), dataset([], count: UInt32.max),
                                 dataset([]) + Data([0]), dataset([0]), dataset([UInt32.max]),
                                 dataset([12, 12])]
        for data in malformed {
            XCTAssertThrowsError(try FujiPTP.parseObjectHandles(data)) { error in
                XCTAssertEqual(error as? FujiPTP.InvalidDataset, .objectHandles)
            }
        }
    }

    func testSuccessfulResponseRequiresACompleteContainer() throws {
        XCTAssertEqual(try FujiPTP.validatedResponseCode(from: response()), FujiPTP.responseOK)
        XCTAssertEqual(try FujiPTP.validatedResponseCode(from: response(code: 0x2002)), 0x2002,
                       "a well-formed refusal stays a camera refusal for the transport to report")
        XCTAssertEqual(try FujiPTP.validatedResponseCode(from: response(transactionID: 7)), FujiPTP.responseOK,
                       "ImageCaptureCore numbers the session's transactions itself; the echoed ID is not ours to check")
        var wrongLength = response(); wrongLength.writeLE(UInt32(16), at: 0)
        var wrongType = response(); wrongType.writeLE(FujiPTP.ContainerType.data.rawValue, at: 4)
        let malformed: [Data?] = [nil, Data(), Data(response().prefix(8)), wrongLength, wrongType,
                                 response() + Data([0, 0, 0, 0])]
        for data in malformed {
            XCTAssertThrowsError(try FujiPTP.validatedResponseCode(from: data))
        }
    }

    func testInvalidDatasetsFileUnderTheirOwnReasons() {
        XCTAssertEqual((FujiPTP.InvalidDataset.response as Error).diagnosticReason, "invalid_response")
        XCTAssertEqual((FujiPTP.InvalidDataset.objectHandles as Error).diagnosticReason, "invalid_object_list")
        XCTAssertEqual(FujiPTP.transactionID(from: response(transactionID: 42)), 42)
    }
}

@MainActor
final class ObjectCleanupSafetyTests: XCTestCase {
    override func setUp() { super.setUp(); CameraReportStore.deleteLatest() }

    private func connected(harvest: Bool = false) async -> (CameraServices, MockCameraTransport) {
        var faults = harvest ? MockCameraFaults.gfx100WithoutKitchen : MockCameraFaults()
        faults.isInstant = true
        faults.uploadCreatesObject = harvest
        let transport = MockCameraTransport(faults: faults)
        let manager = CameraServices()
        await manager.connector.connectDemo(using: transport)
        return (manager, transport)
    }

    private func cook(_ camera: CameraServices) async -> ConversionResult {
        await camera.conversion.cook(raf: RAFFixture.raf(), filename: "test.RAF",
                          settings: .neutral)
    }

    func testMissingBaselineDoesNotTriggerConversionOrDeleteAnExistingObject() async throws {
        let (camera, transport) = await connected()
        let original = Data([1, 2, 3])
        let existing = await transport.storeObject(original)
        await transport.queueObjectHandles(.data(nil))

        let result = await cook(camera)
        let triggers = await transport.conversionTriggerCount
        let deleted = await transport.deletedObjectHandles
        let retained = try await transport.getObject(existing)
        XCTAssertFalse(result.success)
        XCTAssertEqual(triggers, 0)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(retained, original)
    }

    func testTruncatedPollingListNeverAuthorizesCleanup() async {
        let (camera, transport) = await connected()
        await transport.queueObjectHandles(.normal)
        var truncated = Data(); truncated.appendLE(UInt32(2)); truncated.appendLE(UInt32(12))
        await transport.queueObjectHandles(.data(truncated))

        let result = await cook(camera)
        let triggers = await transport.conversionTriggerCount
        let deleted = await transport.deletedObjectHandles
        XCTAssertFalse(result.success)
        XCTAssertEqual(triggers, 1)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testValidBaselineDeletesOnlyTheNewConversionObject() async throws {
        let (camera, transport) = await connected()
        let original = Data([1, 2, 3])
        let existing = await transport.storeObject(original)
        let result = await cook(camera)
        let deleted = await transport.deletedObjectHandles
        let retained = try await transport.getObject(existing)
        XCTAssertTrue(result.success)
        XCTAssertEqual(deleted.count, 1)
        XCTAssertFalse(deleted.contains(existing))
        XCTAssertEqual(retained, original)
    }

    func testValidEmptyBaselineStillConvertsAndCleansUp() async {
        let (camera, transport) = await connected()
        await transport.queueObjectHandles(.data(Data([0, 0, 0, 0])))
        let result = await cook(camera)
        let deleted = await transport.deletedObjectHandles
        XCTAssertTrue(result.success)
        XCTAssertEqual(deleted.count, 1)
    }

    func testMalformedHarvestBaselineNeverAuthorizesDeletion() async throws {
        let (camera, transport) = await connected(harvest: true)
        let original = Data([1, 2, 3])
        let existing = await transport.storeObject(original)
        await transport.queueObjectHandles(.data(nil))
        let result = try await camera.conversion.harvestConversionProfile(raf: Data(repeating: 0x46, count: 64))
        let deleted = await transport.deletedObjectHandles
        let retained = try await transport.getObject(existing)
        XCTAssertEqual(result?.record.uploadOutcome, "accepted", "the read-only profile harvest still uploads")
        XCTAssertNil(result?.record.uploadCreatedObject)
        XCTAssertNil(result?.record.objectDeleted)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(retained, original)
    }
}

import XCTest
import SwiftData
@testable import FujiCookbook

@MainActor
final class DevelopSafetyTests: XCTestCase {
    private let profile = FujiPTP.Prop.rawConvProfile

    private func connected(_ supplied: MockCameraFaults = MockCameraFaults()) async
        -> (CameraServices, MockCameraTransport) {
        var faults = supplied
        faults.isInstant = true
        let transport = MockCameraTransport(faults: faults)
        let camera = CameraServices()
        await camera.connector.connectDemo(using: transport)
        return (camera, transport)
    }

    private func cook(_ camera: CameraServices, settings: RecipeSettings = RecipeSettings(filmSimulation: .velvia)) async -> ConversionResult {
        await camera.conversion.cook(raf: RAFFixture.raf(), filename: "test.RAF", settings: settings)
    }

    private func item(_ filename: String, settings: RecipeSettings = .neutral) -> CookItem {
        CookItem(raf: .inMemory(RAFFixture.raf(), filename: filename), settings: settings)
    }

    private func removeRecovery(_ result: ConversionResult) {
        DevelopOutputRecovery.removeAfterLibrarySave(result.recoveryFileURL)
    }

    /// The recovery file holds the camera's JPEG whole: the size the camera reported, and valid.
    private func assertRecoveryFileHoldsTheDevelop(of result: ConversionResult,
                                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let saved = try Data(contentsOf: try XCTUnwrap(result.recoveryFileURL, file: file, line: line))
        XCTAssertEqual(saved.count, result.evidence.outputBytes, file: file, line: line)
        XCTAssertNoThrow(try DevelopOutputRecovery.validate(saved, expectedSize: UInt32(saved.count)),
                         file: file, line: line)
    }

    func testFailedEmptyAndMissingProfileReadbackStayUnavailable() async {
        var invalidCount = FujiRawConvProfile.demoBaseProfile()
        invalidCount.writeLE(UInt16.max, at: 0)
        var invalidString = FujiRawConvProfile.demoBaseProfile()
        invalidString[2] = 255
        let failures: [MockCameraTransport.QueuedRead] = [.value(nil), .value(Data()), .response(0x2002),
            .value(Data([29, 0])), .value(invalidCount), .value(invalidString)]
        for failure in failures {
            let (camera, transport) = await connected()
            await transport.queueRead(.normal, for: profile)
            await transport.queueRead(failure, for: profile)
            let result = await cook(camera)
            defer { removeRecovery(result) }
            XCTAssertTrue(result.success, "readback uncertainty does not fabricate a render failure")
            XCTAssertNil(result.evidence.profileVerified)
            XCTAssertEqual(result.evidence.profileVerification, "unavailable")
            XCTAssertTrue(result.warnings.contains { $0.contains("unverified") })
        }
    }

    func testNoAuthoredCellsIsNotTestedInsteadOfVacuouslyVerified() async {
        let (camera, _) = await connected()
        let result = await cook(camera, settings: RecipeSettings())
        defer { removeRecovery(result) }
        XCTAssertTrue(result.success)
        XCTAssertNil(result.evidence.profileVerified)
        XCTAssertEqual(result.evidence.profileVerification, "not_tested")
    }

    func testExplicitResetToAsShotValueRemainsInVerificationPlan() throws {
        let base = FujiRawConvProfile.demoBaseProfile()
        let layout = try XCTUnwrap(FujiRawConvProfile.resolveLayout(base))
        let asShot = try XCTUnwrap(FujiRawConvProfile.decode(base, layout: layout).filmSimulation)
        let model = CameraModelRegistry.shared.demoModel
        let reset = FujiRawConvProfile.patchPlan(base: base, with: RecipeSettings(filmSimulation: asShot), model: model, layout: layout)
        XCTAssertEqual(reset.profile, base)
        XCTAssertEqual(reset.fields, [.filmSimulation])
        let previous = FujiRawConvProfile.patch(base: base, with: RecipeSettings(filmSimulation: asShot == .velvia ? .astia : .velvia), model: model, layout: layout)
        XCTAssertFalse(FujiRawConvProfile.verificationMismatches(expected: reset.profile, actual: previous,
                                                                 fields: reset.fields, layout: layout).isEmpty)
    }

    func testMultipleOutputCandidatesAreRetainedAndStopTheBatch() async {
        var faults = MockCameraFaults()
        faults.extraObjectsOnConversion = [Data([1, 2, 3])]
        let (camera, transport) = await connected(faults)
        let items = ["one.RAF", "two.RAF"].map { item($0, settings: RecipeSettings(filmSimulation: .velvia)) }
        let results = await camera.conversion.cookBatch(items)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].evidence.failureReason, "ambiguous_conversion_objects")
        XCTAssertEqual(results[0].evidence.cleanupOutcome, "retained")
        XCTAssertEqual(results[1].evidence.failureReason, "previous_conversion_uncertain")
        let triggers = await transport.conversionTriggerCount
        let deleted = await transport.deletedObjectHandles
        XCTAssertEqual(triggers, 1)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testUnexpectedFormatNeverDownloadsOrDeletesTheObject() async {
        var faults = MockCameraFaults()
        faults.conversionObjectFormat = FujiPTP.rafObjectFormat
        let (camera, transport) = await connected(faults)
        let result = await cook(camera)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.evidence.failureReason, "unexpected_conversion_format")
        let deleted = await transport.deletedObjectHandles
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertNil(result.recoveryFileURL)
    }

    func testEmptyAndIncompleteDownloadsAreNeverDeleted() async {
        for payload in [Data(), Data([0xFF, 0xD8])] {
            var faults = MockCameraFaults()
            faults.conversionDownloadOverride = payload
            let (camera, transport) = await connected(faults)
            let result = await cook(camera)
            XCTAssertFalse(result.success)
            XCTAssertEqual(result.evidence.failureReason, "incomplete_conversion_download")
            let deleted = await transport.deletedObjectHandles
            XCTAssertTrue(deleted.isEmpty)
        }
    }

    func testNonJPEGWithMatchingObjectSizeIsRetained() async {
        var faults = MockCameraFaults()
        faults.conversionDownloadOverride = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let (camera, transport) = await connected(faults)
        await transport.overrideObjectInfo(.init(objectFormat: 0x3801, compressedSize: 4, filename: "result.JPG"), for: 0x0001_0001)
        let result = await cook(camera)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.evidence.failureReason, "invalid_conversion_jpeg")
        let deleted = await transport.deletedObjectHandles
        XCTAssertTrue(deleted.isEmpty)
    }

    func testCleanupFailureKeepsSuccessfulSavedOutputAndReportsCleanupSeparately() async throws {
        var faults = MockCameraFaults()
        faults.deleteObjectResponse = 0x2002
        let (camera, _) = await connected(faults)
        let result = await cook(camera)
        defer { removeRecovery(result) }
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.evidence.outputValidation, "validated")
        XCTAssertEqual(result.evidence.cleanupOutcome, "failed")
        XCTAssertTrue(result.warnings.contains { $0.contains("couldn't be removed") })
        let url = try XCTUnwrap(result.recoveryFileURL)
        try assertRecoveryFileHoldsTheDevelop(of: result)
    }

    func testLibrarySaveRemovesRecoveryCopyOnlyAfterSavingTheImage() async throws {
        let (camera, _) = await connected()
        let result = await cook(camera)
        defer { removeRecovery(result) }
        let url = try XCTUnwrap(result.recoveryFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let developed = try Data(contentsOf: url)
        let comparison = TestKitchenComparison(sourceFilename: "test.RAF", versions: [
            TestKitchenVersion(recipeName: "Test", filmSimulation: "Velvia", result: result)
        ])
        let container = try ModelContainer(for: CookedPhoto.self, CookedVersion.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        _ = try await CookStore.persistChecked([comparison], fullResolution: true, into: container.mainContext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let reopened = ModelContext(container)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<CookedVersion>()).first?.imageData, developed)
    }

    func testTheResultsSheetReadsTheRecoveryFileUntilTheLibraryHasTheImage() async throws {
        let (camera, _) = await connected()
        let result = await cook(camera)
        defer { removeRecovery(result) }
        let url = try XCTUnwrap(result.recoveryFileURL)
        let developed = try Data(contentsOf: url)
        let container = try ModelContainer(for: CookedPhoto.self, CookedVersion.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))

        let beforeSave = try await CookStore.developedJPEG(for: result, in: container.mainContext)
        XCTAssertEqual(beforeSave, developed, "until the library saves it, the recovery file is the copy to show")

        let comparison = TestKitchenComparison(sourceFilename: "test.RAF", versions: [
            TestKitchenVersion(recipeName: "Test", filmSimulation: "Velvia", result: result)
        ])
        _ = try await CookStore.persistChecked([comparison], fullResolution: true, into: container.mainContext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let afterSave = try await CookStore.developedJPEG(for: result, in: ModelContext(container))
        XCTAssertEqual(afterSave, developed, "once saved, the library's copy stands in for the removed file")
    }

    func testFailedLibrarySaveKeepsTheCompleteRecoveryFile() async throws {
        let (camera, _) = await connected()
        let result = await cook(camera)
        defer { removeRecovery(result) }
        let url = try XCTUnwrap(result.recoveryFileURL)
        let comparison = TestKitchenComparison(sourceFilename: "test.RAF", versions: [
            TestKitchenVersion(recipeName: "Test", filmSimulation: "Velvia", result: result)
        ])
        let container = try ModelContainer(for: CookedPhoto.self, CookedVersion.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        do {
            _ = try await CookStore.persistChecked([comparison], fullResolution: true, into: container.mainContext,
                save: { _ in throw CocoaError(.fileWriteOutOfSpace) })
            XCTFail("the library save should fail")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try assertRecoveryFileHoldsTheDevelop(of: result)
        try container.mainContext.save()
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<CookedPhoto>()).isEmpty,
                      "a failed save leaves nothing of the batch pending for a later save to file")
    }

    /// A batch of N develops has one JPEG outside the store at any point: the store reads each
    /// version's bytes from its recovery file, hands them to the context, and lets them go before
    /// it opens the next file. A file that is gone by then fails the save with nothing saved, and
    /// nothing of the batch left pending for a later save to file.
    func testTheStoreReadsEachVersionsFileOnlyAfterTheOneBeforeItIsFiled() async throws {
        let (camera, _) = await connected()
        let results = await camera.conversion.cookBatch(["one.RAF", "two.RAF", "three.RAF"].map { item($0) })
        defer { results.forEach(removeRecovery) }
        XCTAssertEqual(results.filter(\.success).count, 3)
        let urls = try results.map { try XCTUnwrap($0.recoveryFileURL) }
        try FileManager.default.removeItem(at: urls[2])

        let container = try ModelContainer(for: CookedPhoto.self, CookedVersion.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let recipe = ResolvedRecipe(settings: .neutral, displayName: "Test")
        // The versions already in the context each time a file is opened.
        var filedWhenOpened: [Set<UUID>] = []
        do {
            _ = try await CookStore.persistChecked(CookStore.comparisons(from: results, recipe: recipe),
                                                  fullResolution: true, into: context, load: { url in
                filedWhenOpened.append(Set(context.insertedModelsArray.compactMap { ($0 as? CookedVersion)?.uuid }))
                return try await DevelopOutputRecovery.load(url)
            })
            XCTFail("a recovery file that is gone fails the save")
        } catch {}
        XCTAssertEqual(filedWhenOpened, [[], [results[0].id], [results[0].id, results[1].id]],
                       "each version is in the context before the next file is opened")
        try context.save()
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<CookedPhoto>()).isEmpty,
                      "nothing of the batch stays pending for a later save to file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path), "nothing saved, so the files stay")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[1].path))
    }

    func testFailedLocalSaveCannotCreateARecoveryAcknowledgement() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertThrowsError(try DevelopOutputRecovery.save(Data([1]), id: UUID(), directory: parent)) { error in
            XCTAssertEqual((error as? DevelopOutputError)?.diagnosticReason, "conversion_save_failed")
        }
    }

    func testARecoveryCopySavedUnderAnOverrideIsRemovedAfterTheLibrarySave() throws {
        let override = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: override) }
        try DevelopOutputRecovery.$directoryOverride.withValue(override) {
            let url = try DevelopOutputRecovery.save(Data([1]), id: UUID(),
                                                     directory: DevelopOutputRecovery.destinationDirectory)
            DevelopOutputRecovery.removeAfterLibrarySave(url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testLocalSaveFailureRetainsTheCameraOutput() async throws {
        let blockedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: blockedDirectory)
        defer { try? FileManager.default.removeItem(at: blockedDirectory) }
        let (camera, transport) = await connected()
        let result = await DevelopOutputRecovery.$directoryOverride.withValue(blockedDirectory) {
            await cook(camera)
        }
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.evidence.failureReason, "conversion_save_failed")
        XCTAssertEqual(result.evidence.cleanupOutcome, "retained")
        XCTAssertNil(result.recoveryFileURL)
        let deleted = await transport.deletedObjectHandles
        XCTAssertTrue(deleted.isEmpty)
        let retained = try await transport.getObjectHandles()
        XCTAssertEqual(retained.count, 1)
    }

    func testDevelopGateRejectsProbeBatchMatrixAndHarvestUntilTheWholeCookFinishes() async throws {
        let (camera, transport) = await connected()
        let held = expectation(description: "profile write is held")
        await transport.holdNextWrite(to: profile) { held.fulfill() }
        let running = Task { await self.cook(camera) }
        await fulfillment(of: [held], timeout: 3)
        let develop = CameraBusy(runningOperation: "develop")
        let probe = await busyRefusal { () async throws(CameraBusy) in
            try await camera.conversion.probeConversionDynamicRange(raf: RAFFixture.raf(), filename: "other.RAF")
        }
        XCTAssertEqual(probe, develop)
        let batch = await camera.conversion.cookBatch([item("other.RAF")])
        XCTAssertEqual(batch.first?.evidence.failureReason, "camera_busy")
        let matrix = await camera.conversion.cookMatrix(rafs: [.inMemory(RAFFixture.raf(), filename: "other.RAF")],
            recipes: [(settings: .neutral, displayName: "Other", filmSimulation: nil)])
        XCTAssertEqual(matrix.first?.versions.first?.result.evidence.failureReason, "camera_busy")
        let harvest = await busyRefusal { () async throws(CameraBusy) in
            try await camera.conversion.harvestConversionProfile(raf: Data([1]))
        }
        XCTAssertEqual(harvest, develop)
        await transport.releaseHeldWrite()
        let result = await running.value
        defer { removeRecovery(result) }
        XCTAssertTrue(result.success)
    }

    func testProbeOwnsTheGateAndStopsAfterAmbiguousOutput() async throws {
        var faults = MockCameraFaults()
        faults.extraObjectsOnConversion = [Data([1])]
        let (camera, transport) = await connected(faults)
        let held = expectation(description: "probe profile write is held")
        await transport.holdNextWrite(to: profile) { held.fulfill() }
        let running = Task { try await camera.conversion.probeConversionDynamicRange(raf: RAFFixture.raf(), filename: "probe.RAF") }
        await fulfillment(of: [held], timeout: 3)
        let refused = await cook(camera)
        XCTAssertEqual(refused.evidence.failureReason, "camera_busy")
        await transport.releaseHeldWrite()
        let run = try await running.value
        XCTAssertTrue(run.report.contains("RESTORE NOT ATTEMPTED"))
        let triggers = await transport.conversionTriggerCount
        let deleted = await transport.deletedObjectHandles
        XCTAssertEqual(triggers, 1)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testOldBatchCannotContinueOrReportAgainstAReplacementSession() async {
        let (camera, oldTransport) = await connected()
        let held = expectation(description: "old session profile write is held")
        await oldTransport.holdNextWrite(to: profile) { held.fulfill() }
        let running = Task {
            await camera.conversion.cookBatch(["one.RAF", "two.RAF"].map {
                self.item($0, settings: RecipeSettings(filmSimulation: .velvia))
            })
        }
        await fulfillment(of: [held], timeout: 3)
        await camera.connector.disconnect()
        var faults = MockCameraFaults(); faults.isInstant = true
        let newTransport = MockCameraTransport(faults: faults)
        await camera.connector.connectDemo(using: newTransport)
        let reportBefore = camera.reports.report?.develops?.count ?? 0
        let writesBefore = await newTransport.totalWriteCount
        await oldTransport.releaseHeldWrite()
        let results = await running.value
        XCTAssertEqual(results.count, 2)
        XCTAssertFalse(results[0].success)
        XCTAssertEqual(results[1].evidence.failureReason, "previous_conversion_uncertain")
        let oldTriggers = await oldTransport.conversionTriggerCount
        let newTriggers = await newTransport.conversionTriggerCount
        let oldDeleted = await oldTransport.deletedObjectHandles
        let newDeleted = await newTransport.deletedObjectHandles
        let writesAfter = await newTransport.totalWriteCount
        XCTAssertEqual(oldTriggers, 0)
        XCTAssertEqual(newTriggers, 0)
        XCTAssertTrue(oldDeleted.isEmpty && newDeleted.isEmpty)
        XCTAssertEqual(writesAfter, writesBefore)
        XCTAssertEqual(camera.reports.report?.develops?.count ?? 0, reportBefore)
        XCTAssertEqual(camera.session.status, .connected)
    }

    func testUnsupportedSimulationExplainsTheRetainedAsShotLook() async {
        let (camera, _) = await connected(MockCameraFaults(productName: "FUJIFILM X-T4"))
        let result = await cook(camera, settings: RecipeSettings(filmSimulation: .realaAce))
        defer { removeRecovery(result) }
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.warnings.contains { $0.contains("REALA ACE") && $0.contains("keeps") })
    }

    func testUnconfirmedProfileWriteStopsBatchAndMatrixBeforeAnotherUploadOrTrigger() async throws {
        for matrix in [false, true] {
            var faults = MockCameraFaults()
            faults.lostWriteResponseCodes = [profile]
            faults.uploadCreatesObject = true
            let (camera, transport) = await connected(faults)
            let writesBefore = await transport.totalWriteCount
            let results: [ConversionResult]
            if matrix {
                let comparisons = await camera.conversion.cookMatrix(
                    rafs: [.inMemory(RAFFixture.raf(), filename: "one.RAF"), .inMemory(RAFFixture.raf(), filename: "two.RAF")],
                    recipes: [(settings: .neutral, displayName: "One", filmSimulation: nil),
                              (settings: .neutral, displayName: "Two", filmSimulation: nil)])
                results = comparisons.flatMap { $0.versions.map(\.result) }
            } else {
                results = await camera.conversion.cookBatch(["one.RAF", "two.RAF"].map { item($0) })
            }
            XCTAssertTrue(try XCTUnwrap(results.first).requiresReconnect)
            XCTAssertTrue(results.dropFirst().allSatisfy { $0.evidence.failureReason == "previous_conversion_uncertain" })
            let writesAfter = await transport.totalWriteCount
            let triggers = await transport.conversionTriggerCount
            let uploadedObjects = try await transport.getObjectHandles()
            XCTAssertEqual(writesAfter - writesBefore, 1)
            XCTAssertEqual(triggers, 0)
            XCTAssertEqual(uploadedObjects.count, 1, "no subsequent RAF may replace the uncertain upload/profile state")
        }
    }

    func testUnconfirmedUploadStopsBatchAndMatrixBeforeAnotherUpload() async throws {
        for matrix in [false, true] {
            var faults = MockCameraFaults()
            faults.lostUploadResponse = true
            faults.uploadCreatesObject = true
            let (camera, transport) = await connected(faults)
            let writesBefore = await transport.totalWriteCount
            let results: [ConversionResult]
            if matrix {
                let comparisons = await camera.conversion.cookMatrix(
                    rafs: [.inMemory(RAFFixture.raf(), filename: "one.RAF"), .inMemory(RAFFixture.raf(), filename: "two.RAF")],
                    recipes: [(settings: .neutral, displayName: "One", filmSimulation: nil)])
                results = comparisons.flatMap { $0.versions.map(\.result) }
            } else {
                results = await camera.conversion.cookBatch(["one.RAF", "two.RAF"].map { item($0) })
            }
            XCTAssertTrue(try XCTUnwrap(results.first).requiresReconnect)
            XCTAssertEqual(results.last?.evidence.failureReason, "previous_conversion_uncertain")
            let writesAfter = await transport.totalWriteCount
            let uploadedObjects = try await transport.getObjectHandles()
            XCTAssertEqual(writesAfter, writesBefore)
            XCTAssertEqual(uploadedObjects.count, 1)
        }
    }

    func testProbeStopsAfterUnconfirmedProfileWriteWithoutRestoration() async throws {
        var faults = MockCameraFaults()
        faults.lostWriteResponseCodes = [profile]
        let (camera, transport) = await connected(faults)
        let writesBefore = await transport.totalWriteCount
        let run = try await camera.conversion.probeConversionDynamicRange(raf: RAFFixture.raf(), filename: "test.RAF")
        XCTAssertTrue(run.report.contains("OUTCOME UNKNOWN"))
        XCTAssertTrue(run.report.contains("RESTORE NOT ATTEMPTED"))
        let writesAfter = await transport.totalWriteCount
        let triggers = await transport.conversionTriggerCount
        XCTAssertEqual(writesAfter - writesBefore, 1)
        XCTAssertEqual(triggers, 0)
    }

    func testUnconfirmedCleanupKeepsSavedSuccessButStopsBatchAndMatrix() async throws {
        for matrix in [false, true] {
            var faults = MockCameraFaults()
            faults.lostDeleteResponse = true
            let (camera, transport) = await connected(faults)
            let results: [ConversionResult]
            if matrix {
                let comparisons = await camera.conversion.cookMatrix(rafs: [.inMemory(RAFFixture.raf(), filename: "one.RAF")],
                    recipes: [(settings: .neutral, displayName: "One", filmSimulation: nil),
                              (settings: .neutral, displayName: "Two", filmSimulation: nil)])
                results = comparisons.flatMap { $0.versions.map(\.result) }
            } else {
                results = await camera.conversion.cookBatch(["one.RAF", "two.RAF"].map { item($0) })
            }
            let saved = try XCTUnwrap(results.first)
            defer { removeRecovery(saved) }
            XCTAssertTrue(saved.success)
            XCTAssertTrue(saved.requiresReconnect)
            XCTAssertEqual(saved.evidence.cleanupOutcome, "unknown")
            try assertRecoveryFileHoldsTheDevelop(of: saved)
            XCTAssertEqual(results.last?.evidence.failureReason, "previous_conversion_uncertain")
            let triggers = await transport.conversionTriggerCount
            XCTAssertEqual(triggers, 1)
        }
    }

    func testProbeStopsAfterUnconfirmedCleanupButKeepsItsSavedPreview() async throws {
        var faults = MockCameraFaults()
        faults.lostDeleteResponse = true
        let (camera, transport) = await connected(faults)
        let writesBefore = await transport.totalWriteCount
        let run = try await camera.conversion.probeConversionDynamicRange(raf: RAFFixture.raf(), filename: "test.RAF")
        let saved = try XCTUnwrap(run.comparison?.versions.first?.result)
        defer { removeRecovery(saved) }
        XCTAssertTrue(saved.success)
        XCTAssertTrue(saved.requiresReconnect)
        XCTAssertTrue(run.report.contains("RESTORE NOT ATTEMPTED"))
        let writesAfter = await transport.totalWriteCount
        let triggers = await transport.conversionTriggerCount
        XCTAssertEqual(writesAfter - writesBefore, 2, "one profile write and one trigger; no retry or restore")
        XCTAssertEqual(triggers, 1)
    }

    func testConfirmedCleanupRefusalCanContinueTheBatch() async {
        var faults = MockCameraFaults()
        faults.deleteObjectResponse = 0x2002
        let (camera, transport) = await connected(faults)
        let results = await camera.conversion.cookBatch(["one.RAF", "two.RAF"].map { item($0) })
        defer { results.forEach(removeRecovery) }
        XCTAssertTrue(results.allSatisfy { $0.success && !$0.requiresReconnect && $0.evidence.cleanupOutcome == "failed" })
        let triggers = await transport.conversionTriggerCount
        XCTAssertEqual(triggers, 2)
    }

    func testEachRAFIsReadWhenItsUploadRunsAndNotAfterTheBatchStops() async throws {
        for matrix in [false, true] {
            var faults = MockCameraFaults()
            faults.lostUploadResponse = true
            let (camera, _) = await connected(faults)
            var reads: [String] = []
            let sources = ["one.RAF", "two.RAF"].map { name in
                RAFSource(filename: name) { reads.append(name); return RAFFixture.raf() }
            }
            let results: [ConversionResult]
            if matrix {
                let comparisons = await camera.conversion.cookMatrix(rafs: sources,
                    recipes: [(settings: .neutral, displayName: "One", filmSimulation: nil)])
                results = comparisons.flatMap { $0.versions.map(\.result) }
            } else {
                results = await camera.conversion.cookBatch(sources.map { CookItem(raf: $0, settings: .neutral) })
            }
            XCTAssertTrue(try XCTUnwrap(results.first).requiresReconnect)
            XCTAssertEqual(results.last?.evidence.failureReason, "previous_conversion_uncertain")
            XCTAssertEqual(reads, ["one.RAF"], "a file whose develop never ran is never read (matrix: \(matrix))")
        }
    }

    func testAFileThatCannotBeReadFailsItsOwnDevelopAndTheBatchGoesOn() async throws {
        struct Gone: Error {}
        let (camera, transport) = await connected()
        let results = await camera.conversion.cookBatch([
            CookItem(raf: RAFSource(filename: "gone.RAF") { throw Gone() }, settings: .neutral),
            item("two.RAF"),
        ])
        defer { results.forEach(removeRecovery) }
        XCTAssertEqual(results.count, 2)
        let gone = try XCTUnwrap(results.first)
        XCTAssertFalse(gone.success)
        XCTAssertEqual(gone.evidence.failureReason, "file_unreadable")
        XCTAssertEqual(gone.errorMessage, ConversionResult.unreadableFile(named: "gone.RAF").errorMessage,
                       "the same words the Kitchen uses for a file found unreadable before the batch")
        XCTAssertFalse(gone.requiresReconnect, "a local read failure says nothing about the camera")
        XCTAssertTrue(try XCTUnwrap(results.last).success)
        let triggers = await transport.conversionTriggerCount
        XCTAssertEqual(triggers, 1)
    }
}

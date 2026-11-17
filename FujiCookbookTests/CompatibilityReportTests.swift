import XCTest
@testable import FujiCookbook

/// Every connect produces a Camera Compatibility Report, and the capture behind it is tolerant of
/// the ways an untested body can differ from the tested ones.
///
/// Camera facts in these tests are from zgrimz/fujifilm-ptp-reference:
/// `docs/03-encodings.md#read-signed-or-unsigned`, `docs/03-encodings.md#0xd199-white-balance-mode`,
/// `docs/03-encodings.md#0xd1a1-high-iso-noise-reduction`, `docs/03-encodings.md#0xd195-grain-effect`,
/// `docs/04-custom-slots.md#how-many-banks`, and `docs/04-custom-slots.md#iso-gating`.
@MainActor
final class CompatibilityReportTests: XCTestCase {

    /// `CameraReportStore` is a real file in the App Group, and a report now adopts the push history
    /// of the last one describing the same body — so without this, one test's pushes show up in the
    /// next test's report.
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

    // MARK: The DeviceInfo dataset

    func testDeviceInfoRoundTripsThroughTheParser() {
        var info = FujiPTP.DeviceInfo()
        info.standardVersion = 100
        info.vendorExtensionID = 0x0000_0006
        info.vendorExtensionVersion = 100
        info.vendorExtensionDesc = "fujifilm.com: 1.0;"
        info.operationsSupported = [0x1001, 0x1002, 0x1015, 0x1016, 0x900C]
        info.eventsSupported = [0x4002, 0x4006]
        info.devicePropertiesSupported = [0xD18C, 0xD18D, 0xD192]
        info.captureFormats = [0xF802]
        info.imageFormats = [0x3801, 0xF802]
        info.manufacturer = "FUJIFILM"
        info.model = "X-T50"
        info.deviceVersion = "1.20"
        info.serialNumber = "12A34567"
        XCTAssertEqual(FujiPTP.parseDeviceInfo(FujiPTP.encodeDeviceInfo(info)), info)
    }

    func testEmptyDeviceInfoRoundTrips() {
        let info = FujiPTP.DeviceInfo()   // every string empty, every list empty
        XCTAssertEqual(FujiPTP.parseDeviceInfo(FujiPTP.encodeDeviceInfo(info)), info)
    }

    func testTruncatedDeviceInfoKeepsWhatItRead() {
        var info = FujiPTP.DeviceInfo()
        info.operationsSupported = [0x1001, 0x1015]
        info.model = "X-T50"
        let data = FujiPTP.encodeDeviceInfo(info)
        // Header (11 bytes: version, extension id, extension version, empty description, mode),
        // the operations array (4 + 2×2) and the empty events array (4): cut just before the
        // property list. Everything before the cut survives; everything after reads as absent.
        let parsed = FujiPTP.parseDeviceInfo(Data(data.prefix(23)))
        XCTAssertEqual(parsed?.operationsSupported, [0x1001, 0x1015])
        XCTAssertEqual(parsed?.model, "", "never reached, never invented")
        XCTAssertNil(FujiPTP.parseDeviceInfo(Data([0x64])), "a dataset with no header is nothing")
    }

    // MARK: Capture on connect

    func testFirmwareComesFromDeviceInfoWhenTheTransportHasNone() async {
        let (m, t) = await connect(MockCameraFaults())
        XCTAssertNil(t.firmwareVersion, "the transport, like hardware, doesn't know")
        XCTAssertEqual(m.session.connected?.firmwareVersion, "1.00", "GetDeviceInfo's deviceVersion fills it")
        let report = m.reports.report
        XCTAssertEqual(report?.deviceInfo?.deviceVersion, "1.00")
        XCTAssertEqual(report?.camera.firmwareVersion, "1.00")
        XCTAssertEqual(report?.camera.identification, "exact", "the demo model is a registry entry like any other")
        XCTAssertTrue(report?.deviceInfo?.devicePropertiesSupported.contains { $0.code == "0xD18C" && $0.name == "Slot Selector" } ?? false)
        XCTAssertNotNil(report?.camera.serialHash)
        let json = String(decoding: report!.json, as: UTF8.self)
        XCTAssertFalse(json.contains("DEMO0000001"), "the serial never appears in the report")
        XCTAssertTrue(json.contains("\"reportVersion\" : \(CameraCompatibilityReport.currentVersion)"))
    }

    func testRefusedDeviceInfoIsRecordedAndConnectStillSucceeds() async {
        var f = MockCameraFaults()
        f.refusesDeviceInfo = true
        let (m, _) = await connect(f)
        XCTAssertEqual(m.session.status, .connected)
        XCTAssertEqual(m.slotReader.slots.count, 7)
        XCTAssertNil(m.session.connected?.firmwareVersion, "nothing to fill it from")
        XCTAssertEqual(m.reports.report?.deviceInfo?.error, "0x2005 Operation Not Supported")
    }

    // MARK: Fault-tolerant slot reads

    func testOneUnsupportedPropertyNoLongerLosesTheOtherSlots() async {
        var f = MockCameraFaults()
        f.unsupportedReadCodes = [FujiPTP.PresetProp.clarity.rawValue]
        let (m, _) = await connect(f)
        XCTAssertEqual(m.session.status, .connected)
        XCTAssertEqual(m.slotReader.slots.count, 7, "all seven slots read; only clarity is missing from each")
        XCTAssertEqual(m.slotReader.slots.filter(\.isOccupied).count, 2)
        XCTAssertEqual(m.reports.report?.unsupportedPropertyCodes, ["0xD1A2"])
        let c1 = m.reports.report?.slots.reads.first { $0.slot == 1 }
        let clarity = c1?.properties.first { $0.code == "0xD1A2" }
        XCTAssertEqual(clarity?.responseCode, "0x200A")
        XCTAssertNil(clarity?.value)
        // Readable demo banks include inactive originals too. Only the refused property is lost;
        // the live Image Size property is not part of this bank namespace.
        XCTAssertEqual(c1?.properties.filter { $0.value != nil }.count, FujiPTP.PresetProp.allCases.count - 1)
        XCTAssertEqual(c1?.properties.filter { $0.error != nil }.count, 1)
    }

    func testFiveSlotBodyIsReadAsFiveSlots() async {
        let (m, _) = await connect(.fiveSlots)
        XCTAssertEqual(m.session.status, .connected, "a shorter body is not an error")
        XCTAssertEqual(m.slotReader.slots.count, 5)
        XCTAssertEqual(m.slotReader.probedSlotCount, 5)
        XCTAssertEqual(m.slotReader.effectiveSlotCount, 5)
        XCTAssertEqual(m.reports.report?.slots.assumedSlotCount, 7)
        XCTAssertEqual(m.reports.report?.slots.probedSlotCount, 5)
        let c6 = m.reports.report?.slots.reads.first { $0.slot == 6 }
        XCTAssertEqual(c6?.selected, false)
        XCTAssertTrue(c6?.selectError?.contains("0x200A") ?? false, "the refusal is recorded with its code")
        XCTAssertNil(m.reports.report?.slots.reads.first { $0.slot == 7 }, "probing stops at the first refusal")
    }

    // MARK: Unrecognized body — read-only sweep

    func testUnrecognizedBodyIsSweptWithoutASingleWrite() async {
        let (m, t) = await connect(.unknownBody)
        XCTAssertNil(m.session.connected?.model)
        XCTAssertEqual(m.session.status, .connected, "connected, read-only — not failed")
        XCTAssertTrue(m.slotReader.slots.isEmpty)
        XCTAssertEqual(m.slotReader.effectiveSlotCount, 0, "nothing to offer a push")
        let writes = await t.totalWriteCount
        XCTAssertEqual(writes, 0, "nothing was written — not even the slot selector")
        let report = m.reports.report
        XCTAssertEqual(report?.camera.identification, "unknown")
        XCTAssertEqual(report?.propertySweep?.readOnly, true)
        XCTAssertEqual(report?.propertySweep?.entries.count, 5 + FujiPTP.PresetProp.allCases.count,
                       "the four the sweep has always read, plus ISO")
        XCTAssertEqual(report?.propertySweep?.slot, 1, "the selector was read, not written")
        XCTAssertFalse(report!.transactions.contains { $0.operation == "0x1016" }, "no SetDevicePropValue in the trace")
        let sim = report?.propertySweep?.entries.first { $0.code == "0xD192" }
        XCTAssertNotNil(sim?.value)
        XCTAssertEqual(sim?.descriptor?.form, "enumeration")
        XCTAssertEqual(sim?.name, "Film Simulation")
    }

    // MARK: Recognized body with no slot protocol

    /// A recognized body without the slot protocol, as the registry carries the X-T20
    /// (zgrimz/fujifilm-ptp-reference `docs/07-cameras.md#x-t20`), is swept read-only and sent no
    /// bank write. It is not the unrecognized path: it is the same read-only sweep reached
    /// deliberately.
    func testABodyWithoutTheSlotProtocolIsSweptWithoutASingleWrite() async {
        let (m, t) = await connect(.noSlotProtocolBody)
        XCTAssertEqual(m.session.model?.id, "X-T20", "recognized — not a fallthrough to the unknown-body path")
        XCTAssertEqual(m.session.status, .connected, "connected and explained, never .failed")
        XCTAssertTrue(m.slotReader.slots.isEmpty)
        XCTAssertEqual(m.slotReader.effectiveSlotCount, 0, "no phantom C1–C7 for a body with no slots")
        XCTAssertFalse(m.session.canPush)

        let writes = await t.totalWriteCount
        XCTAssertEqual(writes, 0, "nothing was written — not even the slot selector")
        let scan = m.reports.report!.transactions
        XCTAssertFalse(scan.contains { $0.operation == "0x1016" && $0.parameters.first == "0xD18C" },
                       "no SetDevicePropValue(0xD18C) reached the camera")
    }

    /// The sweep is the point, not a consolation prize: the tester ends up with a shareable report
    /// that characterizes the body, including the `0xD183`/`0xD185` conversion properties, which is
    /// the open question for this generation.
    func testTheSweepStillProducesAFullReportOnANoSlotBody() async {
        let (m, _) = await connect(.noSlotProtocolBody)
        let report = m.reports.report
        XCTAssertEqual(report?.camera.identification, "exact")
        XCTAssertEqual(report?.propertySweep?.readOnly, true)
        XCTAssertEqual(report?.propertySweep?.entries.count, 5 + FujiPTP.PresetProp.allCases.count,
                       "the four the sweep has always read, plus ISO")
        let unsupported = report?.unsupportedPropertyCodes ?? []
        XCTAssertTrue(unsupported.contains("0xD18C"), "got: \(unsupported)")
        XCTAssertTrue(unsupported.contains("0xD18D"), "got: \(unsupported)")
        XCTAssertNotNil(report?.propertySweep?.entries.first { $0.code == "0xD183" },
                        "the conversion trigger is characterized too")
    }

    /// The registry is an inference for three of the four gen-III bodies, so the sweep checks it
    /// rather than assuming it. A body that answers `0xD18C` against expectation is being blocked
    /// for nothing — the loudest thing the app can do about that is put it at the top of the report
    /// the tester shares, and at error level in the log that travels with it.
    func testAnUnexpectedSlotProtocolAnswerIsFlaggedLoudly() async {
        // Default faults: this mock *does* answer 0xD18C, so it contradicts the registry entry.
        let (m, t) = await connect(MockCameraFaults(productName: "FUJIFILM X-T20"))
        XCTAssertEqual(m.session.model?.id, "X-T20")
        XCTAssertEqual(m.session.status, .connected)

        let notes = m.reports.report?.notes ?? []
        XCTAssertTrue(notes.contains { $0.contains("UNEXPECTED") && $0.contains("X-T20") },
                      "got: \(notes)")
        XCTAssertTrue(AppLog.reportText(in: .camera).contains("UNEXPECTED"),
                      "and at error level in the shared log")

        let writes = await t.totalWriteCount
        XCTAssertEqual(writes, 0, "it is still read the whole way — the finding costs no write")
    }

    /// The other side of the same check: a body that refuses, as expected, raises no alarm.
    func testAnExpectedRefusalIsNotFlagged() async {
        let (m, _) = await connect(.noSlotProtocolBody)
        let notes = m.reports.report?.notes ?? []
        XCTAssertFalse(notes.contains { $0.contains("UNEXPECTED") }, "got: \(notes)")
        XCTAssertTrue(notes.contains { $0.contains("no USB slot protocol") }, "got: \(notes)")
        // And on disk. These notes are written after the sweep's own `persist()`, so the
        // expected-refusal path is the one where a missing persist would go unnoticed.
        let saved = CameraReportStore.loadLatest()?.notes ?? []
        XCTAssertTrue(saved.contains { $0.contains("no USB slot protocol") }, "got: \(saved)")
    }

    /// The regression guard for the X-T50, the body the maintainers drive end to end. If the new branch ever
    /// catches a body it shouldn't, this is what says so.
    func testAHealthyBodyStillWalksAllSevenSlots() async {
        let (m, _) = await connect(MockCameraFaults(productName: "FUJIFILM X-T50"))
        XCTAssertEqual(m.session.model?.id, "X-T50")
        XCTAssertEqual(m.session.status, .connected)
        XCTAssertEqual(m.slotReader.slots.count, 7)
        XCTAssertEqual(m.slotReader.effectiveSlotCount, 7)
        let selects = m.reports.report!.transactions
            .filter { $0.operation == "0x1016" && $0.parameters.first == "0xD18C" }.count
        XCTAssertEqual(selects, 7 + 1, "every slot was selected, then the bank the camera was on was put back")
    }

    // MARK: Persistence and shape

    func testReportSurvivesDisconnectAndCarriesRawSlotBytes() async {
        let (m, _) = await connect(MockCameraFaults())
        await m.connector.disconnect()
        XCTAssertNil(m.session.connected)
        let report = m.reports.report
        XCTAssertNotNil(report, "the report outlives the session")
        let c1 = report?.slots.reads.first { $0.slot == 1 }
        XCTAssertEqual(c1?.occupied, true)
        XCTAssertEqual(c1?.name, "Sunny 16")
        XCTAssertNotNil(c1?.properties.first { $0.code == "0xD192" }?.value, "raw property bytes are in the report")
        if let onDisk = CameraReportStore.loadLatest() {
            XCTAssertEqual(onDisk.generatedAt.timeIntervalSince1970, report!.generatedAt.timeIntervalSince1970, accuracy: 1)
            XCTAssertEqual(onDisk.slots.reads.count, 7)
        } else {
            XCTAssertNil(CameraReportStore.latestURL, "a store that exists must hold the report")
        }
    }

    func testReportJSONDecodesToTheSameFacts() async throws {
        let (m, _) = await connect(.fiveSlots)
        let report = try XCTUnwrap(m.reports.report)
        let decoded = try CameraCompatibilityReport.decode(report.json)
        XCTAssertEqual(decoded.reportVersion, CameraCompatibilityReport.currentVersion)
        XCTAssertEqual(decoded.camera, report.camera)
        XCTAssertEqual(decoded.deviceInfo, report.deviceInfo)
        XCTAssertEqual(decoded.slots, report.slots)
        XCTAssertEqual(decoded.transactions, report.transactions)
        XCTAssertEqual(decoded.notes, report.notes)
        // Dates included: they are truncated at the source precisely so ISO 8601, which has no
        // sub-second component, decodes back to the value that was written.
        XCTAssertEqual(decoded.generatedAt, report.generatedAt)
        XCTAssertEqual(decoded.updatedAt, report.updatedAt)
    }

    func testConnectTraceCoversDeviceInfoAndEverySlotRead() async {
        let (m, _) = await connect(MockCameraFaults())
        let ops = m.reports.report!.transactions.map(\.operation)
        XCTAssertEqual(ops.first, "0x1001", "GetDeviceInfo is the first transaction")
        XCTAssertEqual(ops.filter { $0 == "0x1016" }.count, 7 + 1, "one slot select per slot, plus the restore")
        XCTAssertEqual(ops.filter { $0 == "0x1015" }.count, 7 * (2 + FujiPTP.PresetProp.allCases.count) + 3,
                       "the selector read-back, the name, and every preset property, per slot — "
                       + "plus three for the restore: the read before the walk, the is-it-already-there "
                       + "check, and the read-back after the write")
        XCTAssertEqual(m.reports.report?.transactionsDropped, 0)
    }

    func testTraceIsBoundedAndSkipsBulkPayloads() {
        let r = PTPTraceRecorder()
        for i in 0..<(PTPTraceRecorder.maxTransactions + 25) {
            r.record(operation: 0x1015, parameters: [0xD192], outDataLength: nil, inData: Data([1, 2]),
                     response: 0x2001, error: nil, durationMs: i)
        }
        XCTAssertEqual(r.snapshot.count, PTPTraceRecorder.maxTransactions)
        XCTAssertEqual(r.droppedCount, 25)

        r.reset()
        r.record(operation: 0x1009, parameters: [1], outDataLength: nil,
                 inData: Data(repeating: 0xAB, count: 5000), response: 0x2001, error: nil,
                 durationMs: 0, dumpData: false)
        XCTAssertNil(r.snapshot.first?.inData, "a GetObject payload is never dumped")
        XCTAssertEqual(r.snapshot.first?.inDataLength, 5000)
        r.record(operation: 0x1015, parameters: [0xD185], outDataLength: nil,
                 inData: Data(repeating: 0xCD, count: 200), response: 0x2001, error: nil, durationMs: 0)
        XCTAssertTrue(r.snapshot.last?.inData?.hasSuffix("…(+136 bytes)") ?? false, "long values are capped")
        XCTAssertEqual(r.snapshot.last?.operationName, "GetDevicePropValue")
        XCTAssertEqual(r.snapshot.last?.parameters, ["0xD185"])
        r.record(operation: 0x1016, parameters: [0xD18C], outData: Data([0x03, 0x00]), inData: nil,
                 response: 0x2001, error: nil, durationMs: 0)
        XCTAssertEqual(r.snapshot.last?.outData, "0300", "a slot select says which slot")
        XCTAssertEqual(r.snapshot.last?.outDataLength, 2)
        r.record(operation: 0x900D, parameters: [], outData: Data(repeating: 0, count: 40_000), inData: nil,
                 response: 0x2001, error: nil, durationMs: 0)
        XCTAssertNil(r.snapshot.last?.outData, "an upload is recorded by size only")
        XCTAssertEqual(r.snapshot.last?.outDataLength, 40_000)

        r.isRecording = false
        r.record(operation: 0x1015, parameters: [], outDataLength: nil, inData: nil,
                 response: 0x2001, error: nil, durationMs: 0)
        XCTAssertEqual(r.snapshot.count, 4, "disarmed means dropped on the floor, not counted")
    }

    func testTextRenderingMentionsTheEssentials() async {
        let (m, _) = await connect(MockCameraFaults())
        let text = m.reports.report!.textRendering
        XCTAssertTrue(text.contains("camera compatibility report v\(CameraCompatibilityReport.currentVersion)"))
        XCTAssertTrue(text.contains("0xD18C Slot Selector"))
        XCTAssertTrue(text.contains("C1  occupied \"Sunny 16\""))
        XCTAssertTrue(text.contains("Trace       "))
        XCTAssertFalse(text.contains("DEMO0000001"), "the serial is hashed, never printed")
    }

    func testConnectionProvenanceDoesNotClaimACompleteTestTraceOrNewHardwareVerification() {
        func report() -> CameraCompatibilityReport {
            .begin(productName: "X-T50", transport: "usb", usb: nil, modelID: "X-T50",
                   identification: "exact", firmwareVersion: "1.32", verification: "hardware",
                   assumedSlotCount: 7)
        }
        let first = report()
        let second = report()
        XCTAssertNotNil(first.connectionID)
        XCTAssertNotEqual(first.connectionID, second.connectionID, "same-second reconnects still have distinct identities")
        XCTAssertEqual(first.traceStartedAt, first.generatedAt)
        XCTAssertEqual(first.traceScope, "connection")
        let text = first.textRendering
        XCTAssertTrue(text.contains("existing app metadata, not a verdict from this test"))
        XCTAssertTrue(text.contains("Latest camera state"))
        XCTAssertTrue(text.contains("zero omitted does not mean the whole test was captured"))
    }

    func testReadPhaseAndRestartEvidenceRoundTripSeparatelyFromLatestSlots() throws {
        var report = CameraCompatibilityReport.beginUnreached()
        var record = guidedTest()
        let before = CameraCompatibilityReport.SlotRead(slot: 1, selected: true, name: "Original", occupied: true,
                                                       properties: [.init(code: "0xD192", value: "0100")])
        record.initialSlots = .init(reads: [before], readAt: Date(timeIntervalSince1970: 100))
        record.propertySweep = .init(slot: 1, readOnly: false, entries: [],
                                     capturedAt: Date(timeIntervalSince1970: 101), evidenceID: "read-sweep")
        record.propertyReport?.capturedAt = record.propertySweep?.capturedAt
        record.propertyReport?.evidenceID = "read-sweep"
        var trial = CameraCompatibilityReport.PushTrialRecord(recipe: "priority", slot: 1)
        trial.connectionID = "before-restart"
        trial.persistence = .init(evidenceState: "couldNotVerify", settingsState: "couldNotVerify",
                                  freshReadSucceeded: false, restartConfirmed: true,
                                  connectionChanged: true, persisted: false,
                                  expected: ["0xD192": "1400"], connectionID: "after-restart")
        record.writePass = .init(trials: [trial])
        report.record(guidedTest: record)
        report.slots.reads = [.init(slot: 1, selected: true, name: "Later recipe", occupied: true, properties: [])]
        report.slots.readAt = Date(timeIntervalSince1970: 200)

        let decoded = try CameraCompatibilityReport.decode(report.json)
        XCTAssertEqual(decoded.guidedTests?.first?.initialSlots?.reads.first?.name, "Original")
        XCTAssertEqual(decoded.slots.reads.first?.name, "Later recipe")
        XCTAssertEqual(decoded.guidedTests?.first?.propertySweep?.evidenceID, "read-sweep")
        XCTAssertEqual(decoded.guidedTests?.first?.writePass?.trials?.first?.persistence?.expected, ["0xD192": "1400"])
        XCTAssertTrue(decoded.textRendering.contains("restart       couldNotVerify"))
        XCTAssertFalse(decoded.textRendering.contains("did NOT survive"), "an unavailable reading is not lost settings")
        XCTAssertTrue(decoded.textRendering.contains("read after-restart · push before-restart"))
    }

    func testSessionCoverageKeepsSlotWritingSeparateFromDevelopAndUsesAuthoredSettings() {
        var record = guidedTest()
        var trial = CameraCompatibilityReport.PushTrialRecord(recipeSettings: .init(dRangePriority: .auto),
                                                             recipe: "priority", slot: 1, recipeName: "CT Priority",
                                                             outcome: .applied)
        trial.persistence = .init(settingsState: "passed", persisted: true)
        record.writePass = .init(trials: [trial])
        record.kitchenRuns = [.init(caseID: "develop", recipes: [
            .init(id: "colour", name: "CT Colour", settings: .init(dynamicRange: .dr200, highlightTone: -0.5))
        ], fullResolution: true)]
        let text = CameraCompatibilityReport.coverageLines(for: record).joined(separator: "\n")
        XCTAssertTrue(text.contains("Slot write CT Priority → C1: applied"))
        XCTAssertFalse(text.contains("Slot write CT Colour"))
        XCTAssertTrue(text.contains("Authored settings: D-Range Priority"))
        XCTAssertTrue(text.contains("CT Colour, supplied settings: Dynamic Range, Highlight Tone"))
        XCTAssertTrue(text.contains("attempt has no completion evidence"), "starting a develop does not prove it completed")
        XCTAssertFalse(text.contains("Kelvin"), "current/default camera values cannot invent authored feature coverage")
    }

    func testRestoreRenderingSeparatesRefusedCommandsFromVerifiedFinalState() throws {
        var record = guidedTest()
        let verification = RestoreVerification(at: Date(timeIntervalSince1970: 200),
            readAt: Date(timeIntervalSince1970: 199), outcome: .applied, commandOutcome: .partiallyApplied,
            freshReadSucceeded: true, originalName: "Original", expectedName: "Original", currentName: "Original",
            nameMatches: true, originalNameRestorable: true,
            fields: [.init(code: "0xD190", original: "9001", current: "9001", matches: true)], reasons: [])
        record.writePass = .init(restores: [.init(slot: 1, outcome: .partiallyApplied, verification: verification)])
        var report = CameraCompatibilityReport.beginUnreached()
        report.record(guidedTest: record)
        let decoded = try CameraCompatibilityReport.decode(report.json)
        XCTAssertEqual(decoded.guidedTests?.first?.writePass?.restores?.first?.verification, verification)
        XCTAssertTrue(decoded.textRendering.contains("C1 final state: applied · commands: partiallyApplied"))
        XCTAssertTrue(decoded.textRendering.contains("1/1 original properties match"))
    }

    // MARK: v2 — divergences, pushes, and reading a v1 file

    /// The regression that would otherwise be found by a tester losing their report.
    ///
    /// `CameraCompatibilityReport` has no `CodingKeys` and no `init(from:)`, so Swift's synthesized
    /// `Decodable` throws `keyNotFound` for a missing key *even when the property has a default
    /// value*. `CameraReportStore.loadLatest()` reads a file written by the previous build every
    /// time the diagnostics screen opens, so a non-optional field added in v2 would make a stored
    /// report silently vanish on update.
    func testAV1ReportStillDecodes() throws {
        let v1 = """
        {
          "reportVersion": 1,
          "generatedAt": "2026-09-04T10:00:00Z",
          "updatedAt": "2026-09-04T10:00:05Z",
          "app": { "version": "1.0", "build": "1", "channel": "testflight" },
          "host": { "systemVersion": "26.0", "deviceIdentifier": "iPhone16,1" },
          "camera": { "productName": "FUJIFILM X-T5", "transport": "usb", "identification": "exact" },
          "slots": { "reads": [ { "slot": 1, "selected": true, "properties": [] } ] },
          "unsupportedPropertyCodes": [],
          "transactions": [],
          "transactionsDropped": 0,
          "notes": []
        }
        """
        let report = try CameraCompatibilityReport.decode(Data(v1.utf8))

        XCTAssertEqual(report.reportVersion, 1, "a v1 file keeps saying it is v1")
        XCTAssertNil(report.pushes, "absent, not empty — this build never looked")
        XCTAssertNil(report.slots.reads.first?.divergences)
        XCTAssertNil(report.camera.verification)
        XCTAssertFalse(report.textRendering.isEmpty, "and it still renders")
    }

    /// The v2 half of the same contract, and the one that actually bites now.
    ///
    /// `CameraReportStore.loadLatest()` reads a file written by the *previous* build every time the
    /// diagnostics screen opens, so the moment v3 shipped a non-optional `develops` or
    /// `connectionFailures`, every tester who had ever connected a camera would have watched their
    /// stored report vanish on update — silently, and at the exact moment they went to send it.
    func testAV2ReportStillDecodesUnderV3() throws {
        let v2 = """
        {
          "reportVersion": 2,
          "generatedAt": "2026-09-06T10:00:00Z",
          "updatedAt": "2026-09-06T10:00:05Z",
          "app": { "version": "1.0", "build": "1", "channel": "testflight" },
          "host": { "systemVersion": "26.0", "deviceIdentifier": "iPhone16,1" },
          "camera": { "productName": "FUJIFILM X-T50", "transport": "usb", "identification": "exact",
                      "verification": "hardware" },
          "slots": { "reads": [ { "slot": 1, "selected": true, "properties": [] } ] },
          "unsupportedPropertyCodes": [],
          "transactions": [],
          "transactionsDropped": 0,
          "notes": [],
          "pushes": [ { "at": "2026-09-06T10:00:03Z", "slot": 1, "outcome": "applied",
                        "nameWritten": true, "clampedFields": [], "fields": [] } ]
        }
        """
        let report = try CameraCompatibilityReport.decode(Data(v2.utf8))

        XCTAssertEqual(report.reportVersion, 2, "a v2 file keeps saying it is v2")
        XCTAssertEqual(report.pushes?.count, 1, "and keeps the section it did carry")
        XCTAssertNil(report.develops, "absent, not empty — that build never developed anything")
        XCTAssertNil(report.developsDropped)
        XCTAssertNil(report.connectionFailures)
        XCTAssertFalse(report.textRendering.isEmpty, "and it still renders")
    }

    func testAV4ReportStillDecodesUnderV5() throws {
        let v4 = """
        {
          "reportVersion": 4,
          "generatedAt": "2026-09-15T10:00:00Z",
          "updatedAt": "2026-09-15T10:00:05Z",
          "app": { "version": "1.0", "build": "3", "channel": "testflight" },
          "host": { "systemVersion": "26.3", "deviceIdentifier": "iPad13,8" },
          "camera": { "productName": "FUJIFILM GFX100S", "transport": "usb", "identification": "exact",
                      "verification": "inferred" },
          "slots": { "reads": [] },
          "unsupportedPropertyCodes": [],
          "transactions": [],
          "transactionsDropped": 0,
          "notes": [],
          "develops": [ { "at": "2026-09-15T10:00:04Z", "succeeded": true } ],
          "connectionFailures": [ { "at": "2026-09-15T10:00:02Z", "stage": "discovery",
                                    "reason": "No camera found." } ],
          "guidedTests": [ { "sessionID": "S1", "wave": 1, "startedAt": "2026-09-15T10:00:01Z" } ]
        }
        """
        let report = try CameraCompatibilityReport.decode(Data(v4.utf8))

        XCTAssertEqual(report.reportVersion, 4)
        XCTAssertEqual(report.develops?.count, 1)
        XCTAssertEqual(report.connectionFailures?.count, 1)
        XCTAssertEqual(report.guidedTests?.count, 1)
        XCTAssertNil(report.profileHarvests, "absent, not empty — that build had no harvest")
        XCTAssertFalse(report.textRendering.isEmpty)
    }

    // MARK: v5 — the profile harvest

    /// Synthetic values: an unresolved layout, which the GFX100S's real harvest was not (its record
    /// is in zgrimz/fujifilm-ptp-reference `evidence/gfx100s-20260917-211657`).
    func testAHarvestRecordRoundTripsAndRenders() throws {
        var report = CameraCompatibilityReport.begin(
            productName: "FUJIFILM GFX100S", transport: "usb", usb: nil, modelID: "GFX100S",
            identification: "exact", firmwareVersion: "2.13", verification: "owner-report",
            assumedSlotCount: 6)
        var harvest = CameraCompatibilityReport.ProfileHarvestRecord(
            at: Date(timeIntervalSince1970: 1_757_900_000), modelID: "GFX100S", firmwareVersion: "2.13",
            rafBytes: 123_456_789, uploadOutcome: "accepted")
        harvest.profileBeforeUpload = "0x2002 General Error"
        harvest.uploadCreatedObject = false
        harvest.profileLength = 601
        harvest.declaredParams = 42
        harvest.layoutBase = nil
        harvest.layoutDiagnostic = "601 bytes / 42 params / no base scored valid"
        harvest.profileHead = "0000  2a 00 00 00"
        harvest.failureReason = "conversion_profile_mismatch"
        report.record(harvest: harvest)

        let decoded = try CameraCompatibilityReport.decode(report.json)
        XCTAssertEqual(decoded.reportVersion, CameraCompatibilityReport.currentVersion)
        XCTAssertEqual(decoded.profileHarvests, [harvest])

        let text = decoded.textRendering
        XCTAssertTrue(text.contains("Harvests"), text)
        XCTAssertTrue(text.contains("layout unresolved"), "an unresolved layout is the headline")
        XCTAssertTrue(text.contains("0x2002"), "and the before-upload refusal is shown beside it")
        XCTAssertFalse(text.contains("harvest.RAF"), "no filename, anywhere")
    }

    /// The guided-test block names the harvest on its own line, so a reader sees "harvest ran" next
    /// to "develop notWritable" and does not take the second for the whole story. The detail text
    /// is synthetic.
    func testTheGuidedTestTextNamesTheHarvest() {
        var record = guidedTest()
        record.develop = .init(state: "notWritable", detail: "RAW conversion isn't enabled for this body.")
        record.profileHarvest = .init(state: "ran", detail: "601-byte profile, layout resolved at base 0x1FD")
        var report = CameraCompatibilityReport.begin(
            productName: "FUJIFILM GFX100S", transport: "usb", usb: nil, modelID: "GFX100S",
            identification: "exact", firmwareVersion: "2.13", verification: "owner-report",
            assumedSlotCount: 6)
        report.record(guidedTest: record)

        let text = report.textRendering
        XCTAssertTrue(text.contains("harvest       ran"), text)
        XCTAssertTrue(text.contains("layout resolved at base 0x1FD"))
        XCTAssertTrue(text.contains("develop       notWritable"), "and the develop line is still there, still true")
    }

    // MARK: v4 — what the tester observed

    private func guidedTest(id: String = "S1", wave: Int = 1) -> CameraCompatibilityReport.GuidedTestRecord {
        var record = CameraCompatibilityReport.GuidedTestRecord(
            sessionID: id, wave: wave, startedAt: Date(timeIntervalSince1970: 1_757_000_000))
        record.transport = "usb"
        record.outcome = "sentEarly"
        record.outcomeStep = "grainProbe"
        record.identity = .init(appShowedModelID: "X-T5", badge: "Read & Write · unverified",
                                confirmed: true)
        record.slotComparisons = [
            .init(slot: 2, name: "ACROS Street", verdict: "differs",
                  rows: [.init(field: "Grain Effect", appShowed: "Weak, Large", differs: true,
                               cameraShows: "Weak, Small")],
                  fieldsAppCouldNotRead: ["White Balance"])
        ]
        record.propertyReport = .init(state: "ran", slot: 2, count: 26, readOnly: false)
        record.grainProbe = .init(state: "skipped")
        record.freeText = "Dial was on C the whole time."
        return record
    }

    /// The line this whole section exists for: a setting the app displayed confidently and the
    /// camera's own menu shows differently. Read-back verification cannot see it, and before this
    /// there was no field for it — it landed in free text, if the tester thought to write any.
    func testAGuidedTestRendersTheDisagreementWithABang() {
        var report = CameraCompatibilityReport.beginUnreached()
        report.record(guidedTest: guidedTest())

        let text = report.textRendering
        XCTAssertTrue(text.contains("Camera test  wave 1"), text)
        XCTAssertTrue(text.contains("! Grain Effect: app showed Weak, Large — camera shows Weak, Small"), text)
        XCTAssertTrue(text.contains("! Tester reported a difference from the camera's menu"), text)
        XCTAssertTrue(text.contains("the app couldn't read: White Balance"), text)
        XCTAssertTrue(text.contains("grain probe   skipped by the tester"), text)
        XCTAssertTrue(text.contains("sent early, at grainProbe"), text)
        XCTAssertTrue(text.contains("\"Dial was on C the whole time.\""), text)
    }

    /// A push that verified, read back correctly, and was gone after the camera was switched off and
    /// on. Nothing else in this document can report it.
    func testAWritePassThatDidNotSurviveAPowerCycleSaysSoLoudly() {
        var record = guidedTest(id: "S2", wave: 2)
        var trial = CameraCompatibilityReport.PushTrialRecord(recipe: "colour", slot: 5)
        trial.recipeName = "CT Colour"
        trial.outcome = .applied
        trial.persistence = .init(persisted: false,
                                  differences: [.init(field: "Film Simulation", code: "0xD192",
                                                      wrote: "0B00", holds: "0100")])
        trial.photoMatchesRecipe = "no"
        record.writePass = .init(consentAt: Date(), backup: .init(savedAt: Date(), activity: "Files"),
                                 dialConfirmed: true, trials: [trial],
                                 restores: [.init(slot: 5, outcome: .applied)])
        var report = CameraCompatibilityReport.beginUnreached()
        report.record(guidedTest: record)

        let text = report.textRendering
        XCTAssertTrue(text.contains("trial 1  \"CT Colour\" → C5"), text)
        XCTAssertTrue(text.contains("! did NOT survive"), text)
        XCTAssertTrue(text.contains("! Film Simulation: wrote 0B00, holds 0100"), text)
        XCTAssertTrue(text.contains("! does NOT look like the recipe"), text)
        XCTAssertTrue(text.contains("backup saved (Files)"), text)
        XCTAssertTrue(text.contains("restores      C5 applied"), text)
    }

    /// A test is projected repeatedly as it progresses. Appending would fill the section with a
    /// dozen snapshots of one session.
    func testProjectingTheSameTestTwiceReplacesRatherThanAppends() {
        var report = CameraCompatibilityReport.beginUnreached()
        report.record(guidedTest: guidedTest())
        var later = guidedTest()
        later.outcome = "completed"
        later.outcomeStep = nil
        report.record(guidedTest: later)

        XCTAssertEqual(report.guidedTests?.count, 1)
        XCTAssertEqual(report.guidedTests?.first?.outcome, "completed")

        report.record(guidedTest: guidedTest(id: "S2", wave: 2))
        XCTAssertEqual(report.guidedTests?.count, 2, "a write pass sits next to its read pass")
    }

    /// A session the tester walked away from has to stop saying it is under way. `Outcome` has had
    /// an `abandoned` case from the start and, until the flow started setting it, one button in the
    /// whole app produced it — so a test given up on read as "in progress" in every later report.
    func testAnAbandonedTestStopsClaimingToBeInProgress() {
        var report = CameraCompatibilityReport.beginUnreached()
        var record = guidedTest(id: "S9", wave: 2)
        record.outcome = "inProgress"
        record.outcomeStep = "dialCheck"
        report.record(guidedTest: record)
        XCTAssertTrue(report.textRendering.contains("in progress at dialCheck"))

        record.outcome = "abandoned"
        report.record(guidedTest: record)
        XCTAssertEqual(report.guidedTests?.count, 1, "the same session, not a second record")
        XCTAssertTrue(report.textRendering.contains("stopped at dialCheck"), report.textRendering)
        XCTAssertFalse(report.textRendering.contains("in progress at"), report.textRendering)
    }

    /// The write probe is the only thing that settles the D195 read/write asymmetry on a new body,
    /// and it was the one diagnostic whose wire traffic never reached the report — the property
    /// report, the push, the restore and the develop all arm the trace; this didn't. The summary
    /// says "reads back 6", which is a *decoded* guess; on the body whose encoding differs, the
    /// bytes are the evidence.
    func testTheWriteProbeLeavesItsTransactionsInTheReport() async throws {
        let transport = MockCameraTransport(faults: MockCameraFaults(isInstant: true))
        let m = CameraServices()
        await m.connector.connectDemo(using: transport)
        let before = m.reports.report?.transactions.count ?? 0

        _ = try await m.diagnostics.probeWriteValues(slot: 1, property: .grain,
                                     candidates: CameraDiagnostics.grainProbeCandidates)

        let after = m.reports.report?.transactions ?? []
        XCTAssertGreaterThan(after.count, before, "the probe's traffic reached the trace")
        XCTAssertTrue(after.contains { $0.operation == "0x1016" && $0.parameters.first == "0xD195" },
                      "a write to D195 is in the trace")
    }

    /// The probe promises to put the value back, so the *saved* copy of the report has to hold the
    /// restore. The recorder's `persist()` is what snapshots the trace, so it must run after the
    /// restore; the in-memory trace is complete either way, which is why the test above can't tell.
    func testTheSavedReportProvesTheProbeRestoredTheValue() async throws {
        CameraReportStore.deleteLatest()
        let transport = MockCameraTransport(faults: MockCameraFaults(isInstant: true))
        let m = CameraServices()
        await m.connector.connectDemo(using: transport)

        _ = try await m.diagnostics.probeWriteValues(slot: 1, property: .grain,
                                     candidates: CameraDiagnostics.grainProbeCandidates)

        let saved = CameraReportStore.loadLatest()
        let writes = (saved?.transactions ?? []).filter {
            $0.operation == "0x1016" && $0.parameters.first == "0xD195"
        }
        XCTAssertEqual(writes.count, CameraDiagnostics.grainProbeCandidates.count + 1,
                       "every candidate plus the restore is in the file the tester sends")
        let reads = (saved?.transactions ?? []).filter {
            $0.operation == "0x1015" && $0.parameters.first == "0xD195"
        }
        XCTAssertEqual(reads.last?.inData, writes.last?.outData,
                       "and the last thing recorded is a read agreeing with the restore")
    }

    /// A comparison the step seeded and nobody opened still has its rows — it is the same snapshot,
    /// waiting. Saying "12 settings shown" about it claims work that wasn't done.
    func testAnUncheckedComparisonDoesNotClaimSettingsWereReviewed() {
        var report = CameraCompatibilityReport.beginUnreached()
        var record = guidedTest()
        record.slotComparisons = [
            .init(slot: 1, name: "HARBOUR", verdict: "notChecked",
                  rows: [.init(field: "Grain Effect", appShowed: "Off", differs: false),
                         .init(field: "Dynamic Range", appShowed: "DR400", differs: false)])
        ]
        report.record(guidedTest: record)

        let text = report.textRendering
        XCTAssertTrue(text.contains("not checked"), text)
        XCTAssertFalse(text.contains("settings shown"), text)
    }

    /// A comparison with settings the app couldn't read is unverified, whatever the tester answered,
    /// and the report must not call it unchecked: the suffix names what couldn't be read.
    func testAnUnverifiedComparisonIsNotRenderedAsUnchecked() {
        var report = CameraCompatibilityReport.beginUnreached()
        var record = guidedTest()
        var comparison = CameraCompatibilityReport.SlotComparisonRecord(
            slot: 1, name: "HARBOUR", verdict: "unverified",
            rows: [.init(field: "Grain Effect", appShowed: "Off", differs: false)])
        comparison.fieldsAppCouldNotRead = ["Clarity"]
        record.slotComparisons = [comparison]
        report.record(guidedTest: record)

        let text = report.textRendering
        XCTAssertTrue(text.contains("could not be fully verified against the camera's menu"), text)
        XCTAssertTrue(text.contains("the app couldn't read: Clarity"), text)
        XCTAssertFalse(text.contains("not checked"), text)
    }

    // MARK: The sweep a record cites

    /// A report holds exactly one property sweep, and the write pass's power cycle rebuilds the
    /// report — so a tester who ran Part One and then Part Two used to arrive with a record saying
    /// "ran on C1 — 26 properties" and no sweep in the report at all.
    func testThePropertySweepSurvivesTheReconnectToo() async throws {
        let transport = MockCameraTransport(faults: MockCameraFaults(isInstant: true))
        let m = CameraServices()
        await m.connector.connectDemo(using: transport)
        _ = try await m.diagnostics.probeProperties(slot: 1)
        let entries = m.reports.report?.propertySweep?.entries.count ?? 0
        XCTAssertGreaterThan(entries, 0)

        await m.connector.disconnect()
        await m.connector.connectDemo(using: transport)
        XCTAssertEqual(m.reports.report?.propertySweep?.entries.count, entries,
                       "the sweep the record cites is still there after a power cycle")
    }

    /// But a sweep this connect actually ran describes the camera as it is now, and must win.
    func testAFreshSweepIsNotOverwrittenByTheAdoptedOne() async throws {
        let transport = MockCameraTransport(faults: MockCameraFaults(isInstant: true))
        let m = CameraServices()
        await m.connector.connectDemo(using: transport)
        _ = try await m.diagnostics.probeProperties(slot: 1)
        XCTAssertEqual(m.reports.report?.propertySweep?.slot, 1)

        await m.connector.disconnect()
        await m.connector.connectDemo(using: transport)
        _ = try await m.diagnostics.probeProperties(slot: 3)
        XCTAssertEqual(m.reports.report?.propertySweep?.slot, 3,
                       "the newer sweep is the live one, not the carried-over C1")
    }

    /// Two read passes, and the second's sweep replaces the first's. The first record still names
    /// 26 properties on C1 — which are now nowhere in the report, so the line has to say so rather
    /// than sending a reader to a different slot's numbers.
    func testARecordSaysWhenItsSweepIsNoLongerTheOneInTheReport() {
        var report = CameraCompatibilityReport.beginUnreached()
        report.record(guidedTest: guidedTest())            // propertyReport ran on C2
        report.propertySweep = .init(slot: 5, readOnly: false, entries: [])

        let text = report.textRendering
        XCTAssertTrue(text.contains("! the Sweep below is C5, not this one"), text)
    }

    func testARecordSaysWhenItsSweepIsGoneEntirely() {
        var report = CameraCompatibilityReport.beginUnreached()
        report.record(guidedTest: guidedTest())
        XCTAssertNil(report.propertySweep)

        let text = report.textRendering
        XCTAssertTrue(text.contains("! not in this report (a later connect replaced it)"), text)
    }

    func testARecordIsQuietWhenItsSweepIsTheOneInTheReport() {
        var report = CameraCompatibilityReport.beginUnreached()
        report.record(guidedTest: guidedTest())            // propertyReport ran on C2
        report.propertySweep = .init(slot: 2, readOnly: false, entries: [])

        let text = report.textRendering
        XCTAssertFalse(text.contains("not this one"), text)
        XCTAssertFalse(text.contains("a later connect replaced it"), text)
    }

    /// "Matches" costs one tap. The timestamp is the only thing in the record that separates a
    /// careful read-through from three slots confirmed in four seconds, and the text block is what
    /// anyone actually reads — so it has to carry it.
    func testTheComparisonSaysWhenItWasChecked() {
        var report = CameraCompatibilityReport.beginUnreached()
        var record = guidedTest()
        record.slotComparisons = [
            .init(slot: 1, name: "HARBOUR", verdict: "matches",
                  checkedAt: Date(timeIntervalSince1970: 1_757_000_297),
                  rows: [.init(field: "Grain Effect", appShowed: "Off", differs: false)])
        ]
        report.record(guidedTest: record)

        let text = report.textRendering
        XCTAssertTrue(text.contains("matches the camera's menu"), text)
        XCTAssertTrue(text.contains("checked 2025-09-04T15:38:17Z"), text)
    }

    /// Two bank conditions the tester can read off the camera and the app can't. Noted, the
    /// comparison line carries them; absent, the line says nothing rather than implying JPEG or
    /// base ISO.
    func testTheComparisonNamesTheBankConditionsTheTesterNoted() {
        var report = CameraCompatibilityReport.beginUnreached()
        var record = guidedTest()
        record.slotComparisons = [
            .init(slot: 1, name: "HARBOUR", verdict: "matches", checkedAt: Date(),
                  rows: [.init(field: "Grain Effect", appShowed: "Off", differs: false)],
                  isoShown: "1600", imageFormatShown: "heif"),
            .init(slot: 3, name: "QUIET", verdict: "matches", checkedAt: Date(),
                  rows: [.init(field: "Grain Effect", appShowed: "Off", differs: false)])
        ]
        report.record(guidedTest: record)

        let text = report.textRendering
        XCTAssertTrue(text.contains("· ISO 1600 · HEIF"), text)
        let quiet = text.components(separatedBy: "\n").first { $0.contains("C3 \"QUIET\"") } ?? ""
        XCTAssertFalse(quiet.isEmpty, text)
        XCTAssertFalse(quiet.contains("ISO"), quiet)
        XCTAssertFalse(quiet.contains("JPEG"), quiet)
    }

    /// The push line says whether the tester prepared the slot, because a refused DR200 or
    /// D-Range Priority write after "left as it was" is the expected ISO gate, and the write-pass
    /// line carries AUTO UPDATE CUSTOM SETTING, which every restart result is read against.
    func testTheWritePassNamesThePreparationAndTheAutoUpdateState() {
        var record = guidedTest(id: "S3", wave: 2)
        var prepared = CameraCompatibilityReport.PushTrialRecord(recipe: "priority", slot: 7)
        prepared.recipeName = "CT Priority"
        prepared.outcome = .applied
        prepared.preparation = "setForTest"
        var left = CameraCompatibilityReport.PushTrialRecord(recipe: "colour", slot: 6)
        left.recipeName = "CT Colour"
        left.outcome = .partiallyApplied
        left.preparation = "leftUnchanged"
        record.writePass = .init(consentAt: Date(), dialConfirmed: true, trials: [prepared, left],
                                 autoUpdateCustomSetting: "disable")
        var report = CameraCompatibilityReport.beginUnreached()
        report.record(guidedTest: record)

        let text = report.textRendering
        XCTAssertTrue(text.contains("AUTO UPDATE CUSTOM SETTING DISABLE"), text)
        XCTAssertTrue(text.contains("\"CT Priority\" → C7  applied  slot prepared (ISO 800+, JPEG)"), text)
        XCTAssertTrue(text.contains("\"CT Colour\" → C6  partiallyApplied  slot left as it was"), text)
    }

    /// A report from before the questions existed says nothing about them.
    func testAWritePassWithoutTheConditionsStaysSilentAboutThem() {
        var record = guidedTest(id: "S4", wave: 2)
        var trial = CameraCompatibilityReport.PushTrialRecord(recipe: "colour", slot: 5)
        trial.outcome = .applied
        record.writePass = .init(consentAt: Date(), trials: [trial])
        var report = CameraCompatibilityReport.beginUnreached()
        report.record(guidedTest: record)

        let text = report.textRendering
        XCTAssertFalse(text.contains("AUTO UPDATE"), text)
        XCTAssertFalse(text.contains("slot prepared"), text)
        XCTAssertFalse(text.contains("slot left"), text)
    }

    /// Clear Diagnostics promises to erase what a problem report draws on, and the tester's own
    /// answers are the most personal thing in it.
    func testClearingDropsTheGuidedTests() {
        var report = CameraCompatibilityReport.beginUnreached()
        report.record(guidedTest: guidedTest())
        report.stripToDriftBaseline()
        XCTAssertNil(report.guidedTests)
    }

    /// The write pass asks the tester to switch the camera off and on, which rebuilds this report
    /// from scratch — so without carrying the record forward, the procedure would destroy the
    /// evidence of the push it exists to check.
    func testGuidedTestsSurviveTheReconnectTheWritePassRequires() async {
        let transport = MockCameraTransport(faults: MockCameraFaults(isInstant: true))
        let m = CameraServices()
        await m.connector.connectDemo(using: transport)
        var session = GuidedTestSession.beginContinuous()
        session.adopt(camera: GuidedTestRunner.facts(m))
        m.reports.recordGuidedTest(session, connectedProductName: m.session.connected?.productName)
        XCTAssertEqual(m.reports.report?.guidedTests?.count, 1)

        await m.connector.disconnect()
        await m.connector.connectDemo(using: transport)
        XCTAssertEqual(m.reports.report?.guidedTests?.count, 1,
                       "the same body picks its guided test back up")

        // A different body does not inherit it.
        let other = CameraServices()
        await other.connector.connectDemo(using: MockCameraTransport(faults: .unknownBody))
        XCTAssertNil(other.reports.report?.guidedTests)
    }

    /// The failed-detect branch is the one where there may be no live report at all — and the five
    /// answers the tester typed are the whole of what that session produced.
    func testAGuidedTestIsRecordedEvenWhenNoCameraEverConnected() {
        let m = CameraServices()
        XCTAssertNil(m.reports.report)

        var session = GuidedTestSession.beginContinuous(step: .noCamera)
        session.noCamera = .init(modelAsPrinted: "X-T30 III", firmwareFromMenu: "1.02",
                                usbModeWording: "USB RAW CONV./BACKUP RESTORE",
                                cable: "the one that came with the camera",
                                cameraPromptSeen: .yes, filesPromptSeen: .no,
                                appSaid: "No camera found.")
        m.reports.recordGuidedTest(session, connectedProductName: m.session.connected?.productName)

        let text = m.reports.report?.textRendering ?? ""
        XCTAssertTrue(text.contains("no camera     the app never saw it"), text)
        XCTAssertTrue(text.contains("USB RAW CONV./BACKUP RESTORE"), text)
        XCTAssertTrue(text.contains("camera yes, files & folders no"), text)
    }

    /// A develop reaches the report at all — the gap that made the Kitchen the one camera workflow
    /// whose evidence was prose in a log.
    func testDevelopRecordCarriesTheProfileFacts() {
        var report = CameraCompatibilityReport.begin(
            productName: "FUJIFILM X-T5", transport: "usb", usb: nil, modelID: "X-T5",
            identification: "exact", firmwareVersion: "1.10", verification: "inferred",
            assumedSlotCount: 7)
        var evidence = CookEvidence()
        evidence.profileLength = 625
        evidence.declaredParams = 29
        evidence.layoutBase = 0x1FD
        evidence.profileVerified = false
        evidence.mismatches = ["cell 6 dynamic range: wrote 200, has 100"]
        evidence.dynamicRange = "cappedToAsShot(400->200)"
        evidence.fullResolution = true
        evidence.outputBytes = 8_412_003

        report.record(develop: evidence, at: Date(timeIntervalSince1970: 1_757_000_000),
                      modelID: "X-T5", firmwareVersion: "1.10", succeeded: true,
                      clampedFields: ["Clarity"], filmSimulation: "Classic Chrome")

        let cook = report.develops?.first
        XCTAssertEqual(report.develops?.count, 1)
        XCTAssertEqual(cook?.profileLength, 625)
        XCTAssertEqual(cook?.layoutBase, 0x1FD)
        XCTAssertEqual(cook?.profileVerified, false)
        XCTAssertEqual(cook?.dynamicRange, "cappedToAsShot(400->200)")
        XCTAssertEqual(cook?.clampedFields, ["Clarity"])
        XCTAssertEqual(cook?.filmSimulation, "Classic Chrome")

        let text = report.textRendering
        XCTAssertTrue(text.contains("625 bytes"), "the profile length is the finding on a new body")
        XCTAssertTrue(text.contains("NOT confirmed"), "and an unconfirmed profile is called out")
    }

    /// A failed connect appends to whatever report exists rather than replacing it. Replacing was
    /// the trap: a reconnect that fails would erase the successful session before it.
    func testConnectionFailureAppendsWithoutErasingTheSession() {
        var report = CameraCompatibilityReport.begin(
            productName: "FUJIFILM X-T5", transport: "usb", usb: nil, modelID: "X-T5",
            identification: "exact", firmwareVersion: "1.10", verification: "inferred",
            assumedSlotCount: 7)
        report.note("a real session happened here")

        report.record(connectionFailure: "discovery", reason: "No camera found.",
                      authorization: (control: "authorized", contents: "denied"))

        XCTAssertEqual(report.connectionFailures?.count, 1)
        XCTAssertEqual(report.connectionFailures?.first?.contentsAuthorization, "denied")
        XCTAssertTrue(report.notes.contains("a real session happened here"),
                      "the session that preceded the failure is still there")
        XCTAssertTrue(report.textRendering.contains("contents denied"),
                      "and the permission split is what the reader needs first")
    }

    func testDivergenceReachesTheSlotReadAndTheLog() async {
        AppLog.clear(.camera)
        let (m, _) = await connect(.divergentWhiteBalance)

        let read = m.reports.report?.slots.reads.first { $0.slot == 1 }
        XCTAssertEqual(read?.divergences?.count, 1)
        XCTAssertEqual(read?.divergences?.first?.code, "0xD199")
        XCTAssertEqual(read?.divergences?.first?.kind, "unrecognized")
        XCTAssertEqual(m.slotReader.slots.first?.unsupportedFields.count, 1, "and the slot the UI flags off")

        let log = AppLog.reportText(in: .camera)
        XCTAssertTrue(log.contains("0xD199"), "the property code is the fact I need")
        XCTAssertTrue(log.contains("0x8099"), "so is the value it holds")

        let text = m.reports.report!.textRendering
        XCTAssertTrue(text.contains("! 0xD199"), "and the rendered report leads the line with !")
        XCTAssertTrue(text.contains("did not match this app's encodings"), "with a note near the top")
    }

    /// A clean body must produce no divergence section at all — the control that keeps this from
    /// becoming noise on the one body that is verified.
    func testACleanBodyDivergesFromNothing() async {
        let (m, _) = await connect(MockCameraFaults())

        XCTAssertTrue(m.reports.report!.slots.reads.allSatisfy { $0.divergences == nil })
        XCTAssertTrue(m.slotReader.slots.allSatisfy { $0.unsupportedFields.isEmpty })
        XCTAssertFalse(m.reports.report!.textRendering.contains("!"))
    }

    // MARK: Report legibility

    /// `SlotWriter.push` ends with `SlotReader.refresh()`, so a report carrying a push has slot reads
    /// from *after* it while `transactions` and `slotBefore` are from before. Without this the two
    /// silently contradict each other.
    func testSlotReadsCarryTheirOwnTimestamp() async throws {
        let (m, _) = await connect(MockCameraFaults())
        XCTAssertNotNil(m.reports.report?.slots.readAt)

        _ = await m.slotWriter.push(settings: RecipeSettings(filmSimulation: .classicNeg), name: "T", toSlot: 3)

        let readAt = try XCTUnwrap(m.reports.report?.slots.readAt)
        let pushedAt = try XCTUnwrap(m.reports.report?.pushes?.first?.at)
        // The ordering is the whole point: a reader seeing `readAt` at or after the last push knows
        // the slot section is the camera *after* it, not the pre-push state the trace shows.
        XCTAssertGreaterThanOrEqual(readAt, pushedAt,
                                    "the post-push refresh must not look like it predated the push")
        XCTAssertTrue(m.reports.report!.textRendering.contains("· read "))
    }

    /// A signed 16-bit reading is right for tones and misleading for the properties Fuji stores as
    /// bit patterns. An X-T50 reported white balance `0x8020`, which the report printed as raw bytes
    /// `2080` and decoded `-32736` — two numbers, neither of them the one to look up.
    func testBitPatternValuesRenderAsUnsignedHex() {
        XCTAssertEqual(CameraCompatibilityReport.reading(-32736), " (u16 0x8020)", "AWB white priority")
        XCTAssertEqual(CameraCompatibilityReport.reading(-32768), " (u16 0x8000)", "High ISO NR -4")

        // The ordinary signed readings are untouched: these are real numbers, not bit patterns.
        XCTAssertEqual(CameraCompatibilityReport.reading(-15), " (-15)", "a highlight tone")
        XCTAssertEqual(CameraCompatibilityReport.reading(-40), " (-40)", "a clarity")
        XCTAssertEqual(CameraCompatibilityReport.reading(10000), " (10000)", "a colour temperature")
        XCTAssertEqual(CameraCompatibilityReport.reading(nil), "")
    }

    // MARK: Clear Diagnostics keeps the drift baseline

    func testStripWithNoStoredReportIsANoOp() {
        CameraReportStore.deleteLatest()
        CameraReportStore.stripLatestToDriftBaseline()
        XCTAssertNil(CameraReportStore.loadLatest())
    }

    /// A report with no applied push has no baseline worth a file.
    func testStripWithNothingToKeepDeletes() async {
        let (m, _) = await connect(MockCameraFaults())
        XCTAssertNotNil(m.reports.report)
        CameraReportStore.stripLatestToDriftBaseline()
        XCTAssertNil(CameraReportStore.loadLatest(), "no push, no baseline, no file")
    }

    /// The stripped report must still be recognised as the same camera, or the baseline it kept is
    /// never adopted.
    func testAStrippedReportStillDescribesTheSameBody() async {
        let (m, _) = await connect(MockCameraFaults())
        let full = m.reports.report!
        var stripped = full
        stripped.stripToDriftBaseline()
        XCTAssertTrue(stripped.describesSameBody(as: full))
        XCTAssertEqual(stripped.camera, full.camera, "identity is kept whole")
        // And it round-trips, like every v2 shape.
        XCTAssertNoThrow(try CameraCompatibilityReport.decode(stripped.json))
    }

    /// Develops, conversion checks and failed connects (with the iOS permission states at the
    /// time) are not baseline, so Clear Diagnostics must not leave any of the three behind.
    func testStripDropsDevelopsConversionChecksAndConnectionFailures() {
        var report = CameraCompatibilityReport.begin(
            productName: "FUJIFILM X-T5", transport: "usb", usb: nil, modelID: "X-T5",
            identification: "exact", firmwareVersion: "4.10", verification: "owner-report",
            assumedSlotCount: 7)
        report.record(develop: CookEvidence(), at: Date(), modelID: "X-T5", firmwareVersion: "4.10",
                      succeeded: true, clampedFields: [], filmSimulation: "Classic Chrome")
        report.record(harvest: CameraCompatibilityReport.ProfileHarvestRecord(
            at: Date(), modelID: "X-T5", firmwareVersion: "4.10", rafBytes: 1, uploadOutcome: "accepted"))
        report.record(connectionFailure: "session", reason: "test",
                      authorization: (control: "authorized", contents: "denied"))
        XCTAssertNotNil(report.develops)
        XCTAssertNotNil(report.profileHarvests)
        XCTAssertNotNil(report.connectionFailures)

        report.stripToDriftBaseline()

        XCTAssertNil(report.develops)
        XCTAssertNil(report.developsDropped)
        XCTAssertNil(report.profileHarvests)
        XCTAssertNil(report.profileHarvestsDropped)
        XCTAssertNil(report.connectionFailures)
    }

    /// The trace lives in `CompatibilityReportRecorder`, not the report, and `persist()` copies it
    /// back in at every stage boundary — a disconnect is one. Clearing with the camera still
    /// connected used to let the disconnect write the whole pre-clear trace back to disk.
    func testClearingWhileConnectedDoesNotWriteThePreClearTraceBack() async throws {
        let (m, _) = await connect(MockCameraFaults())
        // Only an `applied` push leaves a baseline, and without one the live report is dropped and
        // the disconnect writes nothing — which would pass this test for the wrong reason. A colour
        // sim and no exposure bias (the demo body refuses it), as in BackupRestoreTests.
        var settings = RecipeSettings.neutral
        settings.filmSimulation = .velvia
        settings.exposureBias = nil
        let pushed = await m.slotWriter.push(settings: settings, name: "Traced", toSlot: 1)
        XCTAssertEqual(pushed.outcome, .applied, "precondition: a push that leaves a baseline")
        XCTAssertTrue(m.reports.report!.transactions.contains { $0.operation == "0x1001" },
                      "precondition: the connect's GetDeviceInfo is in the trace")

        CameraReportStore.stripLatestToDriftBaseline()
        m.reports.clear()
        await m.connector.disconnect()

        let saved = try XCTUnwrap(CameraReportStore.loadLatest(),
                                  "the baseline survives, so the disconnect still writes the file")
        XCTAssertNotNil(saved.pushes)
        XCTAssertFalse(saved.transactions.contains { $0.operation == "0x1001" },
                       "nothing recorded before the clear comes back with the disconnect")
    }

    // MARK: Notes that restate a standing fact

    /// The GFX100S report carried "C7: slot select refused" twice — once from the connect walk and
    /// once from the walk that ends every push — which reads as two events rather than one fact.
    func testAStandingFactIsNotedOnceHoweverOftenItIsFound() {
        var report = CameraCompatibilityReport.begin(
            productName: "FUJIFILM GFX100S", transport: "usb", usb: nil, modelID: "GFX100S",
            identification: "exact", firmwareVersion: "2.13", verification: "inferred",
            assumedSlotCount: 6)
        report.noteOnce("C7: slot select refused (0x200A) — this body has 6 slots")
        report.noteOnce("C7: slot select refused (0x200A) — this body has 6 slots")
        XCTAssertEqual(report.notes.count, 1)

        report.noteOnce("C7: slot select refused (0x200A) — this body has 5 slots")
        XCTAssertEqual(report.notes.count, 2, "a different finding is still its own line")
    }

    /// And the repetition that *is* the record stays. Two probes with the same candidates produce
    /// the same summary, and collapsing them would hide that the camera was written to twice.
    func testARepeatedEventIsStillRecordedTwice() {
        var report = CameraCompatibilityReport.begin(
            productName: "FUJIFILM GFX100S", transport: "usb", usb: nil, modelID: "GFX100S",
            identification: "exact", firmwareVersion: "2.13", verification: "inferred",
            assumedSlotCount: 6)
        report.note("write probe Grain Effect C1: 0→rejected, 2→ACCEPTED")
        report.note("write probe Grain Effect C1: 0→rejected, 2→ACCEPTED")
        XCTAssertEqual(report.notes.count, 2)
    }
}

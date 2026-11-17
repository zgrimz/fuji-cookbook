import XCTest
@testable import FujiCookbook

/// Backup and per-slot restore.
///
/// Restoration distinguishes exact saved bytes from semantic agreement. Grain Off's remembered
/// size is reconstructed only on bodies with evidence for the required write sequence.
///
/// Camera facts in these tests are from zgrimz/fujifilm-ptp-reference:
/// `docs/03-encodings.md#0xd195-grain-effect`, `docs/03-encodings.md#0xd18d-bank-name`,
/// `docs/03-encodings.md#0xd1a5-x-raw-studios-live-image-size`,
/// `docs/03-encodings.md#0xd191-d-range-priority`,
/// `docs/04-custom-slots.md#values-a-bank-remembers-while-they-are-inactive`,
/// `docs/04-custom-slots.md#iso-gating`, `docs/04-custom-slots.md#the-d-range-priority-interlock`, and
/// `docs/04-custom-slots.md#why-a-write-is-refused`.
@MainActor
final class BackupRestoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CameraReportStore.deleteLatest()
    }

    private func connected() async -> CameraServices {
        var faults = MockCameraFaults()
        faults.isInstant = true
        let manager = CameraServices()
        await manager.connector.connectDemo(using: MockCameraTransport(faults: faults))
        return manager
    }

    private var model: CameraModel { CameraModelRegistry.shared.demoModel }

    // MARK: Capture

    func testABackupCapturesEverySlotsRawBytes() async {
        let manager = await connected()
        let backup = manager.slotReader.slotBackup
        XCTAssertNotNil(backup)
        XCTAssertEqual(backup?.schema, CameraBackup.schemaName)
        XCTAssertEqual(backup?.slots.count, manager.slotReader.slots.count)

        let c1 = backup?.slots.first { $0.index == 1 }
        XCTAssertEqual(c1?.occupied, true)
        XCTAssertFalse(c1?.properties.isEmpty ?? true, "raw property bytes, not a decoded recipe")
        XCTAssertNotNil(c1?.properties["0xD192"], "film simulation is in there by property code")
    }

    func testABackupRoundTripsThroughJSON() async throws {
        let manager = await connected()
        let backup = try XCTUnwrap(manager.slotReader.slotBackup)
        let decoded = try CameraBackup.decode(backup.json)
        XCTAssertEqual(decoded, backup, "the file is the backup, exactly")
        XCTAssertEqual(decoded.properties(forSlot: 1), manager.slotReader.slots.first { $0.index == 1 }?.rawProperties)
    }

    func testARecipeFileIsRefusedAsABackup() {
        let recipeFile = Data(#"{"schema":"fuji-recipe","version":1,"recipe":{}}"#.utf8)
        XCTAssertThrowsError(try CameraBackup.decode(recipeFile)) { error in
            guard case CameraBackupError.wrongSchema(let found) = error else {
                return XCTFail("expected wrongSchema, got \(error)")
            }
            XCTAssertEqual(found, "fuji-recipe")
        }
    }

    func testATooNewBackupIsRefusedRatherThanPartlyRead() {
        let future = Data(#"{"schema":"fuji-camera-backup","version":99,"capturedAt":"2026-09-08T00:00:00Z","camera":{"productName":"X"},"slots":[]}"#.utf8)
        XCTAssertThrowsError(try CameraBackup.decode(future))
    }

    // MARK: Fidelity — the part that can't be perfect

    /// The whole reason `RestoreFidelity` exists. Grain's read set and write set differ, so a saved
    /// 6 or 7 cannot be replayed; it round-trips through meaning and the caller is told.
    func testGrainIsReEncodedAndReported() {
        var saved: [UInt16: Data] = [:]
        saved[FujiPTP.PresetProp.filmSimulation.rawValue] = FujiEncoding.packU16(4)
        saved[FujiPTP.PresetProp.grain.rawValue] = FujiEncoding.packU16(6)   // read-side "Off, small"

        let (writes, fidelity) = FujiPresetCodec.encodeRestore(from: saved, model: model)

        let grain = writes.first { $0.code == FujiPTP.PresetProp.grain.rawValue }
        XCTAssertEqual(grain?.bytes, FujiEncoding.packU16(1), "6 is not writable; Off writes as 1")
        XCTAssertTrue(fidelity.reEncoded.contains { $0.lowercased().contains("grain") },
                      "and the difference is reported rather than discovered in a read-back")
        XCTAssertFalse(fidelity.isPerfect)
    }

    func testAWritableGrainValueIsLeftAlone() {
        var saved: [UInt16: Data] = [:]
        saved[FujiPTP.PresetProp.grain.rawValue] = FujiEncoding.packU16(3)   // strong / small
        let (writes, fidelity) = FujiPresetCodec.encodeRestore(from: saved, model: model)
        XCTAssertEqual(writes.first { $0.code == FujiPTP.PresetProp.grain.rawValue }?.bytes,
                       FujiEncoding.packU16(3))
        XCTAssertTrue(fidelity.isPerfect, "nothing to warn about when the bytes are already writable")
    }

    /// A grain value our table doesn't contain — the case a body nobody has tested most plausibly
    /// hits. Writing a guess would be worse than leaving the slot's own value.
    func testAnUnknownGrainValueIsNotWrittenAtAll() {
        var saved: [UInt16: Data] = [:]
        saved[FujiPTP.PresetProp.grain.rawValue] = FujiEncoding.packU16(9)
        let (writes, fidelity) = FujiPresetCodec.encodeRestore(from: saved, model: model)
        XCTAssertNil(writes.first { $0.code == FujiPTP.PresetProp.grain.rawValue },
                     "no guess is written")
        XCTAssertTrue(fidelity.notWritable.contains { $0.lowercased().contains("grain") })
    }

    // MARK: What an undo calls the slot

    /// The write itself, on a body that names its banks: an occupied bank whose name is empty,
    /// pushed over and undone, ends up unnamed again and verified as such.
    func testAnUndoWritesTheEmptyNameAndTheCameraAnswersUnnamed() async throws {
        let transport = MockCameraTransport(faults: MockCameraFaults(productName: "FUJIFILM X-T50", isInstant: true))
        let manager = CameraServices()
        await manager.connector.connectDemo(using: transport)
        XCTAssertEqual(manager.session.connected?.model?.id, "X-T50")
        // Clear the seeded C2's name on the wire the way the app writes an empty name. (`SlotWriter`
        // refuses a push to a bank whose originals it cannot read, so the unnamed bank has to be an
        // occupied one.)
        try await transport.writeProperty(FujiPTP.Prop.slotSelector, FujiEncoding.packU16(2))
        try await transport.writeProperty(FujiPTP.Prop.presetName, FujiEncoding.packPTPString(""))
        await manager.connector.connectDemo(using: transport)
        let unnamed = try XCTUnwrap(manager.slotReader.slots.first { $0.index == 2 })
        XCTAssertTrue(unnamed.isOccupied)
        XCTAssertNil(unnamed.resolvedName, "the bank answers 01 00 00, which is no name")

        let pushed = await manager.slotWriter.push(settings: RecipeSettings(filmSimulation: .acros), name: "CT MONO", toSlot: 2)
        XCTAssertEqual(pushed.outcome, .applied, pushed.errorMessage ?? "")
        XCTAssertEqual(manager.reports.history.undoName(forSlot: 2), "")
        let bytes = try XCTUnwrap(manager.reports.history.lastPushPriorBytes(forSlot: 2))
        let restored = await manager.slotWriter.restore(bytes, name: manager.reports.history.undoName(forSlot: 2), toSlot: 2)
        XCTAssertEqual(restored.outcome, .applied)
        XCTAssertEqual(restored.nameApplied, "")
        XCTAssertEqual(restored.nameOutcome, .written, "the camera's 01 00 00 answer verifies the empty write")
        let slot = try XCTUnwrap(manager.slotReader.slots.first { $0.index == 2 })
        XCTAssertNil(slot.resolvedName, "the slot is unnamed again")
        let verification = RestoreView.verifyRestore(restored, saved: bytes, current: slot, fidelity: .init(),
                                                     cameraReady: true, expectedName: "", originalName: "")
        XCTAssertEqual(verification.outcome, .applied, "\(verification.reasons)")
        XCTAssertEqual(verification.nameMatches, true)
    }

    /// Through ImageCaptureCore an X-T50 answered OK to the one-byte empty name and kept the bank's
    /// old name (fw 1.32, iOS 27.0.1, 2026-10-19). The undo writes the count and the NUL instead,
    /// the bytes the unnamed bank answers, so the name clears there too and the restore verifies.
    func testAnUndoClearsTheNameWhereAOneByteNameWriteIsIgnored() async throws {
        var faults = MockCameraFaults(productName: "FUJIFILM X-T50", isInstant: true)
        faults.ignoresOneByteNameWrites = true
        let transport = MockCameraTransport(faults: faults)
        let manager = CameraServices()
        await manager.connector.connectDemo(using: transport)
        try await transport.writeProperty(FujiPTP.Prop.slotSelector, FujiEncoding.packU16(2))
        try await transport.writeProperty(FujiPTP.Prop.presetName, Data([1, 0, 0]))
        await manager.connector.connectDemo(using: transport)
        XCTAssertNil(try XCTUnwrap(manager.slotReader.slots.first { $0.index == 2 }).resolvedName)

        let pushed = await manager.slotWriter.push(settings: RecipeSettings(filmSimulation: .acros), name: "CT MONO", toSlot: 2)
        XCTAssertEqual(pushed.outcome, .applied, pushed.errorMessage ?? "")
        let bytes = try XCTUnwrap(manager.reports.history.lastPushPriorBytes(forSlot: 2))
        let restored = await manager.slotWriter.restore(bytes, name: manager.reports.history.undoName(forSlot: 2), toSlot: 2)

        XCTAssertEqual(restored.nameOutcome, .written, "the three-byte form is not the one that is dropped")
        XCTAssertEqual(restored.outcome, .applied)
        XCTAssertNil(try XCTUnwrap(manager.slotReader.slots.first { $0.index == 2 }).resolvedName,
                     "not still called CT MONO")
    }

    /// A one-byte count can't describe more than 254 characters and the NUL, so a longer string is
    /// cut to fit rather than sent with a count that disagrees with its characters.
    func testAStringTooLongForItsCountIsCutToFit() {
        let long = String(repeating: "A", count: 300)
        let packed = FujiEncoding.packPTPString(long)
        XCTAssertEqual(packed.first, 255)
        XCTAssertEqual(packed.count, 1 + 254 * 2 + 2)
        XCTAssertEqual(FujiEncoding.parsePTPString(packed), String(long.prefix(254)))
        XCTAssertEqual(SlotWriter.completePresetName(packed), String(long.prefix(254)))
    }

    /// The bytes on the wire: the count and the NUL out, the bank's own unnamed form, and both
    /// empty forms read as a complete empty name.
    func testAnEmptyNameIsWrittenAsTheUnnamedFormTheBankAnswers() {
        XCTAssertEqual(FujiEncoding.packPTPString(""), Data([1, 0, 0]))
        XCTAssertEqual(FujiEncoding.parsePTPString(Data([0])), "")
        XCTAssertEqual(FujiEncoding.parsePTPString(Data([1, 0, 0])), "")
        XCTAssertEqual(SlotWriter.completePresetName(Data([0])), "")
        XCTAssertEqual(SlotWriter.completePresetName(Data([1, 0, 0])), "")
        XCTAssertNil(SlotWriter.completePresetName(Data([1, 0])), "a truncated string is not a name")
        XCTAssertNil(SlotWriter.completePresetName(Data([2, 0, 0])), "nor a count without its characters")
        XCTAssertEqual(SlotWriter.completePresetName(FujiEncoding.packPTPString("Lua de Mel")), "Lua de Mel")
    }

    /// A push never writes an empty name, whatever the recipe is called.
    func testAPushNeverWritesAnEmptyName() async throws {
        let transport = MockCameraTransport(faults: MockCameraFaults(productName: "FUJIFILM X-T50", isInstant: true))
        let manager = CameraServices()
        await manager.connector.connectDemo(using: transport)
        let result = await manager.slotWriter.push(settings: RecipeSettings(filmSimulation: .velvia), name: "", toSlot: 2)
        XCTAssertEqual(result.outcome, .applied, result.errorMessage ?? "")
        XCTAssertEqual(result.nameApplied, CameraSlotName.fallbackName)
        XCTAssertEqual(manager.slotReader.slots.first { $0.index == 2 }?.resolvedName, CameraSlotName.fallbackName)
    }

    /// And the other half: a slot that *did* have a name gets it back.
    func testAnUndoRestoresANameTheSlotActuallyHad() async throws {
        let manager = await connected()
        let named = try XCTUnwrap(manager.slotReader.slots.first { $0.resolvedName != nil })
        let before = named.resolvedName

        _ = await manager.slotWriter.push(settings: GuidedTestRecipes.canonical(for: model)[0].settings,
                               name: "PUSHED OVER IT", toSlot: named.index)

        XCTAssertEqual(manager.reports.history.lastPushPriorName(forSlot: named.index), before,
                       "the undo is offered the name the push replaced")
        XCTAssertEqual(manager.reports.history.undoName(forSlot: named.index), before)
    }

    // MARK: Properties a body refuses

    /// C2 before the GFX100S write pass, PROVIA with grain reading back as 6: the trial push's
    /// `bankBeforeUnsigned` and `liveBeforeUnsigned` in zgrimz/fujifilm-ptp-reference
    /// `evidence/gfx100s-20260915-195437` [Owner report: GFX100S fw 2.13].
    private var gfx100SSlotBefore: [UInt16: Data] {
        let hex: [String: String] = [
            "D18E": "0E00", "D18F": "0200", "D190": "6400", "D191": "0000",
            "D192": "0100", "D193": "0000", "D194": "0000", "D195": "0600",
            "D196": "0100", "D197": "0100", "D198": "0100", "D199": "0200",
            "D19A": "0000", "D19B": "0000", "D19C": "1027", "D19D": "0000",
            "D19E": "0000", "D19F": "0000", "D1A0": "0000", "D1A1": "0020",
            "D1A2": "0000", "D1A3": "0100", "D1A4": "0100", "D1A5": "0E00",
        ]
        return Dictionary(uniqueKeysWithValues: hex.compactMap { key, value in
            guard let code = UInt16(key, radix: 16), let bytes = Data(hexString: value) else { return nil }
            return (code, bytes)
        })
    }

    /// Historical captures included D1A5 before it was identified as live Image Size.
    /// The bank planner excludes it on every body while retaining the bank's own D191.
    func testARestoreToTheGFX100SLeavesOutOnlyLiveImageSize() throws {
        let gfx = try XCTUnwrap(CameraModelRegistry.shared.model(withID: "GFX100S"))
        let codes = Set(FujiPresetCodec.encodeRestore(from: gfx100SSlotBefore, model: gfx).writes.map(\.code))

        XCTAssertFalse(codes.contains(FujiPTP.Prop.liveImageSize))
        XCTAssertTrue(codes.contains(FujiPTP.PresetProp.dRangePriority.rawValue),
                      "the bank's own D-Range Priority goes back")
        // Everything else the bank holds goes back too, the bank's own image size and colour space
        // among them.
        XCTAssertTrue(codes.contains(FujiPTP.PresetProp.imageSize.rawValue))
        XCTAssertTrue(codes.contains(FujiPTP.PresetProp.colorSpace.rawValue))
    }

    // MARK: The X-T50's own bytes

    /// C1 as the X-T50 read it on 2026-09-14 (fw 1.32), the bank whose undo collected three `0x201C`
    /// refusals. PRO Neg. Hi with white balance on Auto: the state in which mono toning and a colour
    /// temperature are refused. The read is in zgrimz/fujifilm-ptp-reference
    /// `evidence/xt50-client-traces/xt50-20260914-200137` and the undo in
    /// `xt50-20260914-203812` (`docs/04-custom-slots.md#restoring-a-bank`).
    private var xt50SlotBefore: [UInt16: Data] {
        let hex: [String: String] = [
            "D18E": "0700", "D18F": "0400", "D190": "9001", "D191": "0000",
            "D192": "0400", "D193": "0000", "D194": "0000", "D195": "0700",
            "D196": "0300", "D197": "0300", "D198": "0100", "D199": "0200",
            "D19A": "0300", "D19B": "FBFF", "D19C": "A816", "D19D": "ECFF",
            "D19E": "0A00", "D19F": "1E00", "D1A0": "0000", "D1A1": "0080",
            "D1A2": "0000", "D1A3": "0100", "D1A4": "0100", "D1A5": "0700",
        ]
        return Dictionary(uniqueKeysWithValues: hex.compactMap { key, value in
            guard let code = UInt16(key, radix: 16), let bytes = Data(hexString: value) else { return nil }
            return (code, bytes)
        })
    }

    /// The conditional write rules, against a bank the X-T50 recorded rather than a constructed case.
    func testAnXT50ColourRestoreLeavesOutTheInactiveToningAndTemperature() throws {
        let xt50 = try XCTUnwrap(CameraModelRegistry.shared.model(withID: "X-T50"))
        let writes = FujiPresetCodec.encodeRestore(from: xt50SlotBefore, model: xt50).writes
        let codes = Set(writes.map(\.code))

        XCTAssertFalse(codes.contains(FujiPTP.PresetProp.monochromaticWC.rawValue))
        XCTAssertFalse(codes.contains(FujiPTP.PresetProp.monochromaticMG.rawValue))
        XCTAssertFalse(codes.contains(FujiPTP.PresetProp.colorTemp.rawValue))

        // Grain 7 is reconstructed through Strong/Large then Off; D1A5 is excluded.
        XCTAssertEqual(writes.first { $0.code == FujiPTP.PresetProp.filmSimulation.rawValue }?.bytes,
                       FujiEncoding.packU16(4))
        XCTAssertEqual(writes.filter { $0.code == FujiPTP.PresetProp.grain.rawValue }.map(\.bytes),
                       [FujiEncoding.packU16(5), FujiEncoding.packU16(1)])
        XCTAssertEqual(writes.count, 21, "23 bank settings, minus three inactive, plus grain preparation")
    }

    // MARK: What Undo Last Push has to put back

    /// A slot's name is not a `PresetProp` — `PresetProp` starts at D18E — so `slotBefore` never
    /// carried it and Undo Last Push restored every setting under whatever name the push had left.
    /// On hardware that produces a C1 holding the restored recipe and still calling itself "CT
    /// Colour", which reads as the restore having failed.
    func testAPushRemembersTheNameItReplaced() async throws {
        let manager = await connected()
        let before = try XCTUnwrap(manager.slotReader.slots.first { $0.index == 1 }?.resolvedName)

        _ = await manager.slotWriter.push(settings: RecipeSettings(filmSimulation: .classicChrome),
                               name: "CT Colour", toSlot: 1)

        XCTAssertEqual(manager.reports.history.lastPushPriorName(forSlot: 1), before,
                       "the undo knows what the slot used to be called")
        XCTAssertEqual(manager.reports.report?.pushes?.last?.nameApplied, "CT Colour")
        XCTAssertNotEqual(manager.reports.history.lastPushPriorName(forSlot: 1), "CT Colour")
    }

    // MARK: A camera nobody has programmed

    private func emptyCamera() async -> CameraServices {
        var faults = MockCameraFaults.emptyCamera
        faults.isInstant = true
        let manager = CameraServices()
        await manager.connector.connectDemo(using: MockCameraTransport(faults: faults))
        return manager
    }

    func testAnEmptyCameraReadsAsSevenEmptySlots() async {
        let manager = await emptyCamera()
        XCTAssertEqual(manager.slotReader.slots.count, 7, "the slots are read, they just hold nothing")
        XCTAssertTrue(manager.occupiedSlots.isEmpty)
        XCTAssertNotNil(manager.slotReader.slotBackup, "a backup of seven empty slots is still a backup")
    }

    /// The point of `slotWasEmpty`. A slot that held nothing cannot be put back to nothing — no
    /// clearing operation is characterized (zgrimz/fujifilm-ptp-reference
    /// `docs/04-custom-slots.md#how-many-banks`) — so offering an undo would write the seeded
    /// defaults and call it a restore.
    func testAPushToAnEmptySlotOffersNoUndo() async {
        let manager = await emptyCamera()
        _ = await manager.slotWriter.push(settings: RecipeSettings(filmSimulation: .classicChrome),
                               name: "CT Colour", toSlot: 1)

        XCTAssertNil(manager.reports.report?.pushes?.last?.slotWasEmpty,
                     "missing reads do not establish occupancy")
        XCTAssertNil(manager.reports.history.lastPushPriorBytes(forSlot: 1), "and the undo honours it")
        XCTAssertEqual(manager.reports.history.lastPushPriorName(forSlot: 1), "",
                       "the empty bank answered no name; without the bytes nothing hangs on it")
    }

    /// No-data reads never authorize a diagnostic experiment or a seeded recipe push.
    func testMissingOriginalsPreventBothTheProbeAndPush() async throws {
        let manager = await emptyCamera()
        let entries = try await manager.diagnostics.probeWriteValues(slot: 1, property: .grain,
                                                     candidates: CameraDiagnostics.grainProbeCandidates)
        let result = await manager.slotWriter.push(settings: RecipeSettings(filmSimulation: .classicChrome),
                                        name: "CT Colour", toSlot: 1)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(result.outcome, .notWritten)
        XCTAssertFalse(result.nameWritten)
        XCTAssertNil(manager.reports.history.lastPushPriorBytes(forSlot: 1))
    }

    /// The same push on a camera that had something there stays fully undoable — the behaviour
    /// verified on X-T50 hardware must not move.
    func testAPushOverARecipeStillOffersItsUndo() async {
        let manager = await connected()
        let before = manager.slotReader.slots.first { $0.index == 1 }?.resolvedName

        _ = await manager.slotWriter.push(settings: RecipeSettings(filmSimulation: .classicChrome),
                               name: "CT Colour", toSlot: 1)

        XCTAssertEqual(manager.reports.report?.pushes?.last?.slotWasEmpty, false)
        XCTAssertNotNil(manager.reports.history.lastPushPriorBytes(forSlot: 1))
        XCTAssertEqual(manager.reports.history.lastPushPriorName(forSlot: 1), before)
    }

    // MARK: The conditional write rules, which a restore has to obey too

    /// Measured on X-T50 hardware (2026-09-14): undoing a push of a colour recipe collected three
    /// `0x201C` rejections — D193, D194 and D19C — and reported `partiallyApplied` for a restore that
    /// had put every setting back. `encode` has always skipped those three unless the state allows
    /// them; `encodeRestore` wrote everything it held.
    func testAColourRestoreDoesNotSendMonoToningOrAColourTemperature() {
        var saved: [UInt16: Data] = [:]
        saved[FujiPTP.PresetProp.filmSimulation.rawValue] = FujiEncoding.packU16(4)      // PRO Neg. Hi
        saved[FujiPTP.PresetProp.whiteBalance.rawValue] = FujiEncoding.packU16(2)        // Auto
        saved[FujiPTP.PresetProp.monochromaticWC.rawValue] = FujiEncoding.packU16(0)
        saved[FujiPTP.PresetProp.monochromaticMG.rawValue] = FujiEncoding.packU16(0)
        saved[FujiPTP.PresetProp.colorTemp.rawValue] = FujiEncoding.packU16(5800)

        let codes = Set(FujiPresetCodec.encodeRestore(from: saved, model: model).writes.map(\.code))

        XCTAssertFalse(codes.contains(FujiPTP.PresetProp.monochromaticWC.rawValue),
                       "mono toning on a colour simulation is refused")
        XCTAssertFalse(codes.contains(FujiPTP.PresetProp.monochromaticMG.rawValue))
        XCTAssertFalse(codes.contains(FujiPTP.PresetProp.colorTemp.rawValue),
                       "a colour temperature with white balance on Auto is refused")
        XCTAssertTrue(codes.contains(FujiPTP.PresetProp.filmSimulation.rawValue), "the rest still goes")
    }

    /// And the other way: the three are exactly what a mono, Kelvin slot needs back.
    func testAMonoKelvinRestoreStillSendsThem() {
        var saved: [UInt16: Data] = [:]
        saved[FujiPTP.PresetProp.filmSimulation.rawValue] =
            FujiEncoding.packU16(FujiEncoding.filmSimToByte[.acros] ?? 0x0C)
        saved[FujiPTP.PresetProp.whiteBalance.rawValue] =
            FujiEncoding.packU16(FujiEncoding.wbColorTempValue)
        saved[FujiPTP.PresetProp.monochromaticWC.rawValue] = FujiEncoding.packI16(20)
        saved[FujiPTP.PresetProp.monochromaticMG.rawValue] = FujiEncoding.packI16(-10)
        saved[FujiPTP.PresetProp.colorTemp.rawValue] = FujiEncoding.packU16(5600)

        let writes = FujiPresetCodec.encodeRestore(from: saved, model: model).writes
        let codes = writes.map(\.code)

        XCTAssertTrue(codes.contains(FujiPTP.PresetProp.monochromaticWC.rawValue))
        XCTAssertTrue(codes.contains(FujiPTP.PresetProp.monochromaticMG.rawValue))
        XCTAssertTrue(codes.contains(FujiPTP.PresetProp.colorTemp.rawValue))
        // Order is load-bearing: an X-T50 refused a colour temperature written while the white
        // balance mode was not Kelvin (zgrimz/fujifilm-ptp-reference
        // `docs/04-custom-slots.md#restoring-a-bank`; `docs/03-encodings.md#0xd19c-color-temperature`).
        let wb = codes.firstIndex(of: FujiPTP.PresetProp.whiteBalance.rawValue)
        let temp = codes.firstIndex(of: FujiPTP.PresetProp.colorTemp.rawValue)
        XCTAssertLessThan(try XCTUnwrap(wb), try XCTUnwrap(temp))
    }

    /// Replay the measured X-T50 restriction independently of the restore planner: once ACROS
    /// is active, a Color write is refused even when the requested bytes are already present.
    private func replayWithAcrosColorRestriction(_ writes: [(code: UInt16, bytes: Data)],
                                                 current: [UInt16: Data])
        -> (values: [UInt16: Data], rejected: [UInt16]) {
        typealias P = FujiPTP.PresetProp
        var values = current
        var rejected: [UInt16] = []
        for write in writes {
            let simulation = values[P.filmSimulation.rawValue].flatMap(FujiEncoding.decodeUInt16)
            if write.code == P.color.rawValue,
               let simulation, (0x0C...0x0F).contains(simulation) {
                rejected.append(write.code)
            } else {
                values[write.code] = write.bytes
            }
        }
        return (values, rejected)
    }

    func testRestoreDoesNotResendUnchangedColorForMonochromeTarget() {
        typealias P = FujiPTP.PresetProp
        for simulation in [0x0C, 0x0E] { // ACROS and ACROS+R
            let saved = [P.filmSimulation.rawValue: FujiEncoding.packU16(simulation),
                         P.color.rawValue: FujiEncoding.packI16(-10)]
            var current = saved
            current[P.filmSimulation.rawValue] = FujiEncoding.packU16(0x14) // REALA ACE
            let plan = FujiPresetCodec.encodeRestore(from: saved, model: model, current: current)
            let replay = replayWithAcrosColorRestriction(plan.writes, current: current)
            XCTAssertTrue(replay.rejected.isEmpty, "an unchanged inactive Color needs no write")
            XCTAssertEqual(replay.values, saved)
            XCTAssertFalse(plan.writes.contains { $0.code == P.color.rawValue })
            let slot = CameraSlot(index: 1, label: "C1", name: "Original", isOccupied: true,
                                  settings: nil, rawProperties: replay.values, unsupportedFields: [:])
            let result = SlotWriteResult(slot: 1, outcome: .applied, nameWritten: true,
                                         nameApplied: "Original", clampedFields: [], fields: [], errorMessage: nil)
            let verification = RestoreView.verifyRestore(result, saved: saved, current: slot,
                fidelity: plan.fidelity, cameraReady: true, expectedName: "Original")
            XCTAssertEqual(verification.outcome, .applied)
            XCTAssertTrue(verification.fields.allSatisfy(\.matches))
            XCTAssertTrue(verification.reasons.isEmpty)
        }
    }

    /// A colour push over an ACROS bank rewrote Color. The undo used to send Color after the
    /// simulation, where ACROS refuses it, and report the restore as partial over a value it could
    /// have put back a moment earlier: the slot is still on the colour simulation when the undo
    /// starts, so Color is accepted *first*.
    func testRestorePutsBackChangedColorBeforeTheMonochromeSimulationHidesIt() {
        typealias P = FujiPTP.PresetProp
        let saved = [P.filmSimulation.rawValue: FujiEncoding.packU16(0x0C),
                     P.color.rawValue: FujiEncoding.packI16(-10)]
        let current = [P.filmSimulation.rawValue: FujiEncoding.packU16(0x14),
                       P.color.rawValue: FujiEncoding.packI16(20)]
        let plan = FujiPresetCodec.encodeRestore(from: saved, model: model, current: current)
        let codes = plan.writes.map(\.code)
        XCTAssertEqual(codes.filter { $0 == P.color.rawValue }.count, 1, "written once, not again after the simulation")
        XCTAssertLessThan(try XCTUnwrap(codes.firstIndex(of: P.color.rawValue)),
                          try XCTUnwrap(codes.firstIndex(of: P.filmSimulation.rawValue)),
                          "Color goes while the colour simulation still accepts it")
        XCTAssertEqual(plan.fidelity.restoredWhileActive, ["Color"])
        XCTAssertTrue(plan.fidelity.isPerfect, "an order, not an imperfection")
        XCTAssertTrue(plan.fidelity.hasNotes, "but one the confirmation screen explains")
        let replay = replayWithAcrosColorRestriction(plan.writes, current: current)
        XCTAssertTrue(replay.rejected.isEmpty)
        XCTAssertEqual(replay.values, saved)
        let slot = CameraSlot(index: 1, label: "C1", name: "Original", isOccupied: true,
                              settings: nil, rawProperties: replay.values, unsupportedFields: [:])
        let result = SlotWriteResult(slot: 1, outcome: .applied, nameWritten: true,
                                     nameApplied: "Original", clampedFields: [], fields: [], errorMessage: nil)
        let verification = RestoreView.verifyRestore(result, saved: saved, current: slot,
            fidelity: plan.fidelity, cameraReady: true, expectedName: "Original")
        XCTAssertEqual(verification.outcome, .applied)
        XCTAssertTrue(verification.fields.allSatisfy(\.matches))
    }

    /// Replay the two conditional-write refusals the X-T50 measured: toning on a simulation
    /// without it, and a colour temperature with white balance off Kelvin, both draw `0x201C`.
    private func replayWithModeRestrictions(_ writes: [(code: UInt16, bytes: Data)],
                                            current: [UInt16: Data])
        -> (values: [UInt16: Data], rejected: [UInt16]) {
        typealias P = FujiPTP.PresetProp
        var values = current
        var rejected: [UInt16] = []
        for write in writes {
            let simulation = values[P.filmSimulation.rawValue].flatMap(FujiEncoding.decodeInt16)
                .flatMap { FujiEncoding.byteToFilmSim[$0] }
            let whiteBalance = values[P.whiteBalance.rawValue].flatMap(FujiEncoding.decodeUInt16).map(Int.init)
            let isToning = write.code == P.monochromaticWC.rawValue || write.code == P.monochromaticMG.rawValue
            if isToning, simulation?.hasMonochromaticColor != true { rejected.append(write.code); continue }
            if write.code == P.colorTemp.rawValue, whiteBalance != FujiEncoding.wbColorTempValue {
                rejected.append(write.code); continue
            }
            values[write.code] = write.bytes
        }
        return (values, rejected)
    }

    /// A Kelvin recipe pushed over an Auto bank rewrote the bank's stored colour temperature. The
    /// backup's white balance is Auto, so the saved-bytes rule would never send `D19C` back and
    /// the push's Kelvin would stay in the bank. The slot is still on Kelvin when the undo starts.
    func testRestorePutsBackADormantColourTemperatureBeforeTheWhiteBalanceHidesIt() throws {
        typealias P = FujiPTP.PresetProp
        let saved = [P.whiteBalance.rawValue: FujiEncoding.packU16(2),
                     P.colorTemp.rawValue: FujiEncoding.packU16(5300),
                     P.wbShiftR.rawValue: FujiEncoding.packI16(3),
                     P.wbShiftB.rawValue: FujiEncoding.packI16(-2)]
        let current = [P.whiteBalance.rawValue: FujiEncoding.packU16(FujiEncoding.wbColorTempValue),
                       P.colorTemp.rawValue: FujiEncoding.packU16(5500),
                       P.wbShiftR.rawValue: FujiEncoding.packI16(0),
                       P.wbShiftB.rawValue: FujiEncoding.packI16(0)]
        let plan = FujiPresetCodec.encodeRestore(from: saved, model: model, current: current)
        let codes = plan.writes.map(\.code)
        XCTAssertEqual(codes.filter { $0 == P.colorTemp.rawValue }.count, 1)
        let kelvin = try XCTUnwrap(codes.firstIndex(of: P.colorTemp.rawValue))
        XCTAssertLessThan(kelvin, try XCTUnwrap(codes.firstIndex(of: P.whiteBalance.rawValue)))
        XCTAssertLessThan(kelvin, try XCTUnwrap(codes.firstIndex(of: P.wbShiftR.rawValue)),
                          "and still before both shifts, which Kelvin can reset")
        XCTAssertLessThan(kelvin, try XCTUnwrap(codes.firstIndex(of: P.wbShiftB.rawValue)))
        XCTAssertEqual(plan.fidelity.restoredWhileActive, [P.colorTemp.debugName])
        let replay = replayWithModeRestrictions(plan.writes, current: current)
        XCTAssertTrue(replay.rejected.isEmpty)
        XCTAssertEqual(replay.values, saved, "the stored Kelvin is the original again, under Auto")
    }

    /// The same for toning: a toned ACROS recipe over a PROVIA bank rewrote `D193`/`D194`, which
    /// the backup's colour simulation hides.
    func testRestorePutsBackDormantToningBeforeTheColourSimulationHidesIt() throws {
        typealias P = FujiPTP.PresetProp
        let saved = [P.filmSimulation.rawValue: FujiEncoding.packU16(4),
                     P.monochromaticWC.rawValue: FujiEncoding.packI16(0),
                     P.monochromaticMG.rawValue: FujiEncoding.packI16(0)]
        let current = [P.filmSimulation.rawValue: FujiEncoding.packU16(FujiEncoding.filmSimToByte[.acros] ?? 0x0C),
                       P.monochromaticWC.rawValue: FujiEncoding.packI16(20),
                       P.monochromaticMG.rawValue: FujiEncoding.packI16(-10)]
        let plan = FujiPresetCodec.encodeRestore(from: saved, model: model, current: current)
        let codes = plan.writes.map(\.code)
        let simulation = try XCTUnwrap(codes.firstIndex(of: P.filmSimulation.rawValue))
        for axis in [P.monochromaticWC, P.monochromaticMG] {
            XCTAssertEqual(codes.filter { $0 == axis.rawValue }.count, 1)
            XCTAssertLessThan(try XCTUnwrap(codes.firstIndex(of: axis.rawValue)), simulation)
        }
        XCTAssertEqual(plan.fidelity.restoredWhileActive, [P.monochromaticWC.debugName, P.monochromaticMG.debugName])
        let replay = replayWithModeRestrictions(plan.writes, current: current)
        XCTAssertTrue(replay.rejected.isEmpty)
        XCTAssertEqual(replay.values, saved)
    }

    /// Exposed but unchanged is nothing to write, and a slot already in the saved state exposes
    /// nothing the backup hides.
    func testRestoreDoesNotSendDormantValuesTheSlotAlreadyHolds() {
        typealias P = FujiPTP.PresetProp
        let saved = [P.filmSimulation.rawValue: FujiEncoding.packU16(4),
                     P.whiteBalance.rawValue: FujiEncoding.packU16(2),
                     P.colorTemp.rawValue: FujiEncoding.packU16(5300),
                     P.monochromaticWC.rawValue: FujiEncoding.packI16(0),
                     P.monochromaticMG.rawValue: FujiEncoding.packI16(0)]
        var exposedButEqual = saved
        exposedButEqual[P.filmSimulation.rawValue] = FujiEncoding.packU16(0x0C)
        exposedButEqual[P.whiteBalance.rawValue] = FujiEncoding.packU16(FujiEncoding.wbColorTempValue)
        for current in [saved, exposedButEqual] {
            let plan = FujiPresetCodec.encodeRestore(from: saved, model: model, current: current)
            let codes = Set(plan.writes.map(\.code))
            XCTAssertFalse(codes.contains(P.colorTemp.rawValue))
            XCTAssertFalse(codes.contains(P.monochromaticWC.rawValue))
            XCTAssertFalse(codes.contains(P.monochromaticMG.rawValue))
            XCTAssertTrue(plan.fidelity.restoredWhileActive.isEmpty)
            XCTAssertFalse(plan.fidelity.hasNotes)
        }
    }

    func testRestoreRetainsColorWriteWhenCurrentOrTargetStateIsUnknown() {
        typealias P = FujiPTP.PresetProp
        let color = FujiEncoding.packI16(-10)
        let saved = [P.filmSimulation.rawValue: FujiEncoding.packU16(0x0C), P.color.rawValue: color]
        let withoutCurrent = FujiPresetCodec.encodeRestore(from: saved, model: model)
        XCTAssertEqual(withoutCurrent.writes.first { $0.code == P.color.rawValue }?.bytes, color)
        let unreadColor = [P.filmSimulation.rawValue: FujiEncoding.packU16(0x14)]
        let withoutColor = FujiPresetCodec.encodeRestore(from: saved, model: model, current: unreadColor)
        XCTAssertEqual(withoutColor.writes.first { $0.code == P.color.rawValue }?.bytes, color)
        for target in [[P.color.rawValue: color],
                       [P.filmSimulation.rawValue: FujiEncoding.packU16(0x7FFF), P.color.rawValue: color]] {
            let unknownTarget = FujiPresetCodec.encodeRestore(from: target, model: model, current: target)
            XCTAssertEqual(unknownTarget.writes.first { $0.code == P.color.rawValue }?.bytes, color,
                           "missing or unrecognised film simulation does not establish an inactive Color")
        }
    }

    func testRestoreStillWritesUnchangedColorForColorTarget() {
        typealias P = FujiPTP.PresetProp
        let saved = [P.filmSimulation.rawValue: FujiEncoding.packU16(0x14),
                     P.color.rawValue: FujiEncoding.packI16(-10)]
        let plan = FujiPresetCodec.encodeRestore(from: saved, model: model, current: saved)
        XCTAssertEqual(plan.writes.first { $0.code == P.color.rawValue }?.bytes, saved[P.color.rawValue])
    }

    /// A restore must not narrow a slot to the fields the recipe model happens to carry. The
    /// housekeeping run has no `RecipeField` at all, so routing a restore through `RecipeSettings`
    /// would silently drop it.
    func testHousekeepingPropertiesSurviveARestore() async throws {
        let manager = await connected()
        let saved = try XCTUnwrap(manager.slotReader.slots.first { $0.index == 1 }?.rawProperties)
        let (writes, _) = FujiPresetCodec.encodeRestore(from: saved, model: model)
        let codes = Set(writes.map(\.code))
        XCTAssertTrue(codes.contains(FujiPTP.PresetProp.imageSize.rawValue), "D18E is not a recipe field")
        XCTAssertTrue(codes.contains(FujiPTP.PresetProp.colorSpace.rawValue), "nor is D1A4")
    }

    // MARK: Round trip against the camera

    func testPushThenRestorePutsTheSlotBack() async throws {
        let manager = await connected()
        let backup = try XCTUnwrap(manager.slotReader.slotBackup)
        let original = try XCTUnwrap(backup.properties(forSlot: 1))

        // A colour sim on purpose: pushing a monochrome one drops Color and Monochromatic Color by
        // design, which lands as `partiallyApplied` and would be testing the push's conditional
        // rules rather than the restore.
        var overwrite = RecipeSettings.neutral
        overwrite.filmSimulation = .velvia
        overwrite.grain = GrainEffect(strength: .strong, size: .large)
        // `neutral` carries an exposure bias, which the demo model doesn't support — it lands as a
        // pre-flight rejection and makes the push `partiallyApplied` for reasons unrelated to this test.
        overwrite.exposureBias = nil
        let pushed = await manager.slotWriter.push(settings: overwrite, name: "Overwritten", toSlot: 1)
        XCTAssertEqual(pushed.outcome, .applied)
        XCTAssertEqual(manager.slotReader.slots.first { $0.index == 1 }?.settings?.filmSimulation, .velvia)

        let restored = await manager.slotWriter.restore(original, name: "Sunny 16", toSlot: 1)
        XCTAssertEqual(restored.outcome, .applied)

        let now = try XCTUnwrap(manager.slotReader.slots.first { $0.index == 1 })
        let before = FujiPresetCodec.decode(original, name: nil, model: model).settings
        XCTAssertEqual(now.settings?.filmSimulation, before.filmSimulation,
                       "semantically back to where it started")
        XCTAssertEqual(now.settings?.grain, before.grain)
        XCTAssertEqual(now.resolvedName, "Sunny 16")
    }

    /// D191 is refused at base ISO even when the write changes nothing, and it is a recipe field,
    /// so a restore that replayed it unconditionally would score every undo at base ISO as "Partly
    /// written" over a bank that was already exactly right. The mock refusing D191 stands in for
    /// the ISO gate.
    func testAnUndoAtBaseISODoesNotResendThePriorityTheBankAlreadyHolds() async throws {
        var faults = MockCameraFaults()
        faults.isInstant = true
        faults.invalidValueWriteCodes = [FujiPTP.PresetProp.dRangePriority.rawValue]
        let manager = CameraServices()
        await manager.connector.connectDemo(using: MockCameraTransport(faults: faults))
        let original = try XCTUnwrap(manager.slotReader.slotBackup?.properties(forSlot: 1))
        XCTAssertNotNil(original[FujiPTP.PresetProp.dRangePriority.rawValue], "precondition: seeded Off")

        var overwrite = RecipeSettings.neutral
        overwrite.filmSimulation = .velvia
        overwrite.exposureBias = nil
        let pushed = await manager.slotWriter.push(settings: overwrite, name: "Overwritten", toSlot: 1)
        XCTAssertEqual(pushed.outcome, .applied, "the push already skips a no-op D191")

        let restored = await manager.slotWriter.restore(original, name: "Sunny 16", toSlot: 1)
        XCTAssertEqual(restored.outcome, .applied, "and so must the restore")
        XCTAssertFalse(restored.fields.contains { $0.code == FujiPTP.PresetProp.dRangePriority.rawValue },
                       "a D191 the bank already holds is not sent")
    }

    /// The other half: a D191 that genuinely differs is still put back, and if the camera refuses
    /// that one the refusal is real — the undo could not restore it — so it is reported.
    func testAnUndoStillSendsAPriorityThatActuallyChanged() throws {
        let xt50 = try XCTUnwrap(CameraModelRegistry.shared.model(withID: "X-T50"))
        var current = xt50SlotBefore
        current[FujiPTP.PresetProp.dRangePriority.rawValue] = FujiEncoding.packU16(2)   // bank now Strong
        let codes = Set(FujiPresetCodec.encodeRestore(from: xt50SlotBefore, model: xt50, current: current)
            .writes.map(\.code))
        XCTAssertTrue(codes.contains(FujiPTP.PresetProp.dRangePriority.rawValue),
                      "saved Off, bank Strong — that write is the whole point of the undo")

        let unchanged = Set(FujiPresetCodec.encodeRestore(from: xt50SlotBefore, model: xt50,
                                                          current: xt50SlotBefore).writes.map(\.code))
        XCTAssertFalse(unchanged.contains(FujiPTP.PresetProp.dRangePriority.rawValue),
                       "saved Off, bank Off — nothing to put back")
        // Without `current` (a caller that hasn't read the slot) the old behaviour stands: replay.
        XCTAssertTrue(Set(FujiPresetCodec.encodeRestore(from: xt50SlotBefore, model: xt50).writes.map(\.code))
                        .contains(FujiPTP.PresetProp.dRangePriority.rawValue))
    }

    /// A restore is recorded as a restore. Two writes to one slot otherwise look alike in the
    /// report, and telling the accident from the repair is the first thing a reader needs.
    func testARestoreIsTaggedInTheReport() async throws {
        let manager = await connected()
        let saved = try XCTUnwrap(manager.slotReader.slotBackup?.properties(forSlot: 1))
        _ = await manager.slotWriter.restore(saved, name: "Sunny 16", toSlot: 1)

        let record = manager.reports.report?.pushes?.last
        XCTAssertEqual(record?.kind, "restore")
        XCTAssertTrue(manager.reports.report!.textRendering.contains("restore"))
    }

    // MARK: The empty slot

    func testAnEmptySlotHasNothingToRestore() async throws {
        let manager = await connected()
        let backup = try XCTUnwrap(manager.slotReader.slotBackup)
        let empty = try XCTUnwrap(backup.slots.first { !$0.occupied })
        XCTAssertNil(backup.properties(forSlot: empty.index),
                     "no clearing operation is known, so seeding it would invent an entry, not restore one")
    }

    // MARK: The free undo, and what takes it away

    func testTheUndoComesFromTheLastPushAndClearDiagnosticsRemovesIt() async {
        let manager = await connected()
        XCTAssertNil(manager.reports.history.lastPushPriorBytes(forSlot: 1), "nothing pushed yet, nothing to undo")

        var settings = RecipeSettings.neutral
        settings.filmSimulation = .acros
        _ = await manager.slotWriter.push(settings: settings, name: "Overwritten", toSlot: 1)
        XCTAssertNotNil(manager.reports.history.lastPushPriorBytes(forSlot: 1), "the push recorded what was there")

        // What Clear Diagnostics does to the report the undo lives in.
        manager.reports.clear()
        XCTAssertNil(manager.reports.history.lastPushPriorBytes(forSlot: 1),
                     "so the UI must stop offering an undo it can no longer perform")
    }

    func testGuidedRestoreRequiresOriginalNameAndEverySavedSetting() {
        let code = FujiPTP.PresetProp.filmSimulation.rawValue
        let saved = [code: FujiEncoding.packU16(0x0B)]
        let result = SlotWriteResult(slot: 1, outcome: .applied, nameWritten: true, nameApplied: "Original",
                                     clampedFields: [], fields: [], errorMessage: nil)
        let current = CameraSlot(index: 1, label: "C1", name: "Original", isOccupied: true, settings: nil,
                                 rawProperties: saved, unsupportedFields: [:])
        XCTAssertEqual(RestoreView.verifyRestore(result, saved: saved, current: current, fidelity: .init(),
                                                     cameraReady: true, expectedName: "Original").outcome, .applied)
        XCTAssertEqual(RestoreView.verifyRestore(result, saved: saved, current: current, fidelity: .init(),
                                                     cameraReady: false, expectedName: "Original").outcome, .couldNotVerify)
        XCTAssertEqual(RestoreView.verifyRestore(result, saved: saved, current: current, fidelity: .init(),
                                                     cameraReady: true, expectedName: "Other name").outcome, .partiallyApplied)
        XCTAssertEqual(RestoreView.verifyRestore(result, saved: [code: FujiEncoding.packU16(1)], current: current,
                                                     fidelity: .init(), cameraReady: true, expectedName: "Original").outcome, .partiallyApplied)
        XCTAssertEqual(RestoreView.verifyRestore(result, saved: saved, current: current,
                                                     fidelity: .init(notWritable: ["Grain"]), cameraReady: true,
                                                     expectedName: "Original").outcome, .applied,
                       "a skipped command does not invalidate an exact, freshly verified original")
    }

    func testGuidedRestoreDistinguishesGrainMeaningFromExactRestoration() {
        let code = FujiPTP.PresetProp.grain.rawValue
        let saved = [code: FujiEncoding.packU16(6)]
        var result = SlotWriteResult(slot: 1, outcome: .applied, nameWritten: true, nameApplied: "Original",
                                     clampedFields: [], fields: [], errorMessage: nil)
        let current = CameraSlot(index: 1, label: "C1", name: "Original", isOccupied: true, settings: nil,
                                 rawProperties: [code: FujiEncoding.packU16(1)], unsupportedFields: [:])
        XCTAssertEqual(RestoreView.verifyRestore(result, saved: saved, current: current,
                                                     fidelity: .init(reEncoded: ["Grain"]), cameraReady: true,
                                                     expectedName: "Original").outcome, .partiallyApplied)
        result.outcome = .unknown
        XCTAssertEqual(RestoreView.verifyRestore(result, saved: saved, current: current,
                                                     fidelity: .init(), cameraReady: true,
                                                     expectedName: "Original").outcome, .couldNotVerify)
        result.outcome = .partiallyApplied
        XCTAssertEqual(RestoreView.verifyRestore(result, saved: saved, current: current,
                                                     fidelity: .init(), cameraReady: true,
                                                     expectedName: "Original").outcome, .partiallyApplied,
                       "command acceptance and the verified final original state are separate findings")
    }

    /// A name the sanitizer would change cannot be written exactly; matching what was written instead
    /// is not the original back.
    func testAFallbackNameDoesNotVerifyRestorationOfAnUnrepresentableOriginalName() {
        let code = FujiPTP.PresetProp.filmSimulation.rawValue
        let saved = [code: FujiEncoding.packU16(0x0B)]
        let result = SlotWriteResult(slot: 1, outcome: .applied, nameWritten: true, nameApplied: "C1",
                                     clampedFields: [], fields: [], errorMessage: nil)
        let current = CameraSlot(index: 1, label: "C1", name: "C1", isOccupied: true, settings: nil,
                                 rawProperties: saved, unsupportedFields: [:])
        XCTAssertEqual(RestoreView.verifyRestore(result, saved: saved, current: current,
                                                     fidelity: .init(), cameraReady: true, expectedName: "C1",
                                                     originalNameRestorable: false).outcome, .partiallyApplied,
                       "matching the fallback does not recreate an absent or unrepresentable original name")
    }

    // The X-T50 refuses DR and tones while Priority is on. Replay against that measured interlock,
    // independently of the codec's order, to catch a restore-only ordering regression.
    private func replayWithPriorityInterlock(_ writes: [(code: UInt16, bytes: Data)],
                                             current: [UInt16: Data])
        -> (values: [UInt16: Data], rejected: [UInt16]) {
        typealias P = FujiPTP.PresetProp
        var values = current
        var rejected: [UInt16] = []
        let locked = Set([P.dynamicRange.rawValue, P.highlightTone.rawValue, P.shadowTone.rawValue])
        for write in writes {
            let priority = values[P.dRangePriority.rawValue].flatMap(FujiEncoding.decodeUInt16) ?? 0
            if priority != 0 && locked.contains(write.code) { rejected.append(write.code) }
            else { values[write.code] = write.bytes }
        }
        return (values, rejected)
    }

    func testRestoreTurnsPriorityOffBeforeRestoringChangedOrUnchangedDynamicRange() {
        typealias P = FujiPTP.PresetProp
        let saved = [P.dRangePriority.rawValue: FujiEncoding.packU16(0),
                     P.dynamicRange.rawValue: FujiEncoding.packU16(400),
                     P.highlightTone.rawValue: FujiEncoding.packI16(-15),
                     P.shadowTone.rawValue: FujiEncoding.packI16(-10)]
        for previousDR in [100, 400] {
            var current = saved
            current[P.dRangePriority.rawValue] = FujiEncoding.packU16(0x8000)
            current[P.dynamicRange.rawValue] = FujiEncoding.packU16(previousDR)
            current[P.highlightTone.rawValue] = FujiEncoding.packI16(20)
            let plan = FujiPresetCodec.encodeRestore(from: saved, model: model, current: current)
            let replay = replayWithPriorityInterlock(plan.writes, current: current)
            XCTAssertTrue(replay.rejected.isEmpty, "turning priority off releases DR and tone writes")
            XCTAssertEqual(replay.values, saved, "the original DR must actually return when it changed")
        }
    }

    func testRestoreRecoversInactiveValuesBeforeEnablingSavedPriority() {
        typealias P = FujiPTP.PresetProp
        let saved = [P.dRangePriority.rawValue: FujiEncoding.packU16(0x8000),
                     P.dynamicRange.rawValue: FujiEncoding.packU16(400),
                     P.highlightTone.rawValue: FujiEncoding.packI16(-15),
                     P.shadowTone.rawValue: FujiEncoding.packI16(-10)]
        var current = saved
        current[P.dRangePriority.rawValue] = FujiEncoding.packU16(0)
        current[P.dynamicRange.rawValue] = FujiEncoding.packU16(100)
        current[P.shadowTone.rawValue] = FujiEncoding.packI16(20)
        let plan = FujiPresetCodec.encodeRestore(from: saved, model: model, current: current)
        let replay = replayWithPriorityInterlock(plan.writes, current: current)
        XCTAssertTrue(replay.rejected.isEmpty)
        XCTAssertEqual(replay.values, saved)
        XCTAssertEqual(plan.writes.last?.code, P.dRangePriority.rawValue)
    }

    func testRestoreDoesNotInventPriorityOffToChangeInactiveOriginalValues() {
        typealias P = FujiPTP.PresetProp
        let saved = [P.dRangePriority.rawValue: FujiEncoding.packU16(0x8000),
                     P.dynamicRange.rawValue: FujiEncoding.packU16(400),
                     P.highlightTone.rawValue: FujiEncoding.packI16(-15)]
        var current = saved
        current[P.dRangePriority.rawValue] = FujiEncoding.packU16(2)
        current[P.dynamicRange.rawValue] = FujiEncoding.packU16(100)
        let plan = FujiPresetCodec.encodeRestore(from: saved, model: model, current: current)
        XCTAssertEqual(plan.writes.count, 1, "only the saved priority value is sent")
        XCTAssertEqual(plan.writes.first?.bytes, FujiEncoding.packU16(0x8000))
        XCTAssertEqual(plan.fidelity.withheldWhilePriorityActive, ["Dynamic Range"])
        let replay = replayWithPriorityInterlock(plan.writes, current: current)
        XCTAssertTrue(replay.rejected.isEmpty)
        let slot = CameraSlot(index: 1, label: "C1", name: "Original", isOccupied: true, settings: nil,
                              rawProperties: replay.values, unsupportedFields: [:])
        let result = SlotWriteResult(slot: 1, outcome: .applied, nameWritten: true, nameApplied: "Original",
                                     clampedFields: [], fields: [], errorMessage: nil)
        let verification = RestoreView.verifyRestore(result, saved: saved, current: slot,
            fidelity: plan.fidelity, cameraReady: true, expectedName: "Original")
        XCTAssertEqual(verification.outcome, .partiallyApplied, "inactive originals still count toward exact restoration")
        XCTAssertTrue(verification.reasons.contains { $0.contains("0xD190") && $0.contains("9001") })
        let unreadPlan = FujiPresetCodec.encodeRestore(from: saved, model: model)
        XCTAssertFalse(unreadPlan.writes.contains { $0.code == P.dynamicRange.rawValue },
                       "an unread current priority does not justify an invented Off write either")
    }

    func testRestoreVerificationPreservesRefusalWhenOriginalStateIsVerified() throws {
        let code = FujiPTP.PresetProp.dynamicRange.rawValue
        let saved = [code: FujiEncoding.packU16(400)]
        let result = SlotWriteResult(slot: 1, outcome: .partiallyApplied, nameWritten: true, nameApplied: "Original",
            clampedFields: [], fields: [.init(code: code, field: "Dynamic Range", isRecipeField: true,
                                             outcome: .rejected(code: 0x201C), wrote: saved[code])], errorMessage: nil)
        let slot = CameraSlot(index: 1, label: "C1", name: "Original", isOccupied: true, settings: nil,
                              rawProperties: saved, unsupportedFields: [:])
        let at = Date(timeIntervalSince1970: 100)
        let verification = RestoreView.verifyRestore(result, saved: saved, current: slot,
            fidelity: .init(), cameraReady: true, expectedName: "Original", readAt: at, at: at)
        XCTAssertEqual(verification.outcome, .applied)
        XCTAssertEqual(verification.commandOutcome, .partiallyApplied)
        XCTAssertTrue(verification.freshReadSucceeded)
        XCTAssertEqual(verification.fields.first?.original, "9001")
        XCTAssertEqual(verification.fields.first?.current, "9001")
        XCTAssertEqual(verification.nameMatches, true)
        XCTAssertEqual(verification.readAt, at)
        XCTAssertTrue(verification.reasons.contains { $0.contains("0x201C") })
        XCTAssertEqual(try JSONDecoder().decode(RestoreVerification.self,
            from: JSONEncoder().encode(verification)), verification)
        XCTAssertEqual(RestoreView.verifyRestore(result, saved: saved, current: slot,
            fidelity: .init(), cameraReady: false, expectedName: "Original").outcome, .couldNotVerify)
    }

    /// Camera Test sessions store verifications as JSON, written as plain strings since build 10.
    /// A stored one must still load, and re-saving it must write the same strings.
    func testAStoredRestoreVerificationStillDecodes() throws {
        let stored = Data("""
        {"at":0,"outcome":"couldNotVerify","commandOutcome":"partiallyApplied","freshReadSucceeded":false,\
        "originalNameRestorable":true,"fields":[],"reasons":[]}
        """.utf8)
        let verification = try JSONDecoder().decode(RestoreVerification.self, from: stored)
        XCTAssertEqual(verification.outcome, .couldNotVerify)
        XCTAssertEqual(verification.commandOutcome, .partiallyApplied)
        let resaved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(verification)) as? [String: Any])
        XCTAssertEqual(resaved["outcome"] as? String, "couldNotVerify")
        XCTAssertEqual(resaved["commandOutcome"] as? String, "partiallyApplied")
    }

    func testEveryStoredOutcomeNameStillDecodes() {
        XCTAssertEqual(["applied", "partiallyApplied", "couldNotVerify", "notWritten"]
            .compactMap(RestoreVerification.Outcome.init(rawValue:)).count, 4)
        XCTAssertEqual(["applied", "partiallyApplied", "notWritten", "unknown"]
            .compactMap(SlotOutcome.init(rawValue:)).count, 4)
    }

    func testRestoreDispositionsKeepTheirStoredNames() {
        XCTAssertEqual(GuidedRestoreStep.disposition(for: .verified(.applied)), .restored)
        XCTAssertEqual(GuidedRestoreStep.disposition(for: .verified(.partiallyApplied)), .partiallyApplied)
        XCTAssertEqual(GuidedRestoreStep.disposition(for: .verified(.couldNotVerify)), .couldNotVerify)
        XCTAssertEqual(GuidedRestoreStep.disposition(for: .canceled), .canceled)
    }

    func testRestoreVerificationDistinguishesUnreadableFromChangedOriginals() {
        let code = FujiPTP.PresetProp.dynamicRange.rawValue
        let saved = [code: FujiEncoding.packU16(400)]
        let result = SlotWriteResult(slot: 1, outcome: .applied, nameWritten: true, nameApplied: "Original",
                                     clampedFields: [], fields: [], errorMessage: nil)
        for readable in [false, true] {
            let slot = CameraSlot(index: 1, label: "C1", name: "Original", isOccupied: true, settings: nil,
                rawProperties: readable ? [code: FujiEncoding.packU16(100)] : [:], unsupportedFields: [:])
            let verification = RestoreView.verifyRestore(result, saved: saved, current: slot,
                fidelity: .init(), cameraReady: true, expectedName: "Original")
            XCTAssertEqual(verification.outcome, readable ? .partiallyApplied : .couldNotVerify)
            XCTAssertEqual(verification.freshReadSucceeded, readable)
            XCTAssertEqual(verification.fields.first?.matches, false)
        }
    }

    func testRestoreVerificationRecordsTheUnsanitizedOriginalName() {
        let code = FujiPTP.PresetProp.filmSimulation.rawValue
        let saved = [code: FujiEncoding.packU16(0x0B)]
        let result = SlotWriteResult(slot: 1, outcome: .applied, nameWritten: true, nameApplied: "Original",
                                     clampedFields: [], fields: [], errorMessage: nil)
        let slot = CameraSlot(index: 1, label: "C1", name: "Original", isOccupied: true, settings: nil,
                              rawProperties: saved, unsupportedFields: [:])
        let verification = RestoreView.verifyRestore(result, saved: saved, current: slot,
            fidelity: .init(), cameraReady: true, expectedName: "Original",
            originalNameRestorable: false, originalName: "Original ☀️")
        XCTAssertEqual(verification.originalName, "Original ☀️")
        XCTAssertEqual(verification.expectedName, "Original")
        XCTAssertEqual(verification.currentName, "Original")
        XCTAssertEqual(verification.nameMatches, false)
        XCTAssertEqual(verification.outcome, .partiallyApplied)
    }
    func testEvidencedBodiesReconstructBothOffGrainSizes() async throws {
        let code = FujiPTP.PresetProp.grain.rawValue
        for modelID in ["X-T50", "GFX100S"] {
            let model = try XCTUnwrap(CameraModelRegistry.shared.model(withID: modelID))
            for original in [6, 7] {
                let saved = [code: FujiEncoding.packU16(original)]
                let plan = FujiPresetCodec.encodeRestore(from: saved, model: model)
                XCTAssertEqual(plan.writes.map(\.bytes), [FujiEncoding.packU16(original == 6 ? 2 : 5), FujiEncoding.packU16(1)])
                XCTAssertTrue(plan.fidelity.reEncoded.isEmpty)
                var faults = MockCameraFaults(); faults.isInstant = true; faults.productName = "FUJIFILM " + modelID
                let transport = MockCameraTransport(faults: faults)
                let manager = CameraServices(); await manager.connector.connectDemo(using: transport)
                try await transport.writeProperty(FujiPTP.Prop.slotSelector, FujiEncoding.packU16(1))
                try await transport.writeProperty(code, FujiEncoding.packU16(original == 6 ? 5 : 2))
                let result = await manager.slotWriter.restore(saved, name: "Original", toSlot: 1)
                XCTAssertEqual(result.outcome, .applied)
                XCTAssertEqual(result.fields.filter { $0.code == code }.count, 1, "one result for the sequence")
                let actual = await transport.storedProperty(code, slot: 1)
                XCTAssertEqual(actual, saved[code])
            }
        }
    }

    func testOtherBodiesKeepSemanticOnlyGrainPlanExplicit() throws {
        let model = try XCTUnwrap(CameraModelRegistry.shared.model(withID: "X-S10"))
        let plan = FujiPresetCodec.encodeRestore(from: [FujiPTP.PresetProp.grain.rawValue: FujiEncoding.packU16(6)], model: model)
        XCTAssertEqual(plan.writes.map(\.bytes), [FujiEncoding.packU16(1)])
        XCTAssertFalse(plan.fidelity.reEncoded.isEmpty)
        let code = FujiPTP.PresetProp.grain.rawValue
        let result = SlotWriteResult(slot: 1, outcome: .applied, nameWritten: true, nameApplied: "Original", clampedFields: [], fields: [])
        let current = CameraSlot(index: 1, label: "C1", name: "Original", isOccupied: true, settings: nil,
                                 rawProperties: [code: FujiEncoding.packU16(7)], unsupportedFields: [:])
        let check = RestoreView.verifyRestore(result, saved: [code: FujiEncoding.packU16(6)], current: current,
                                             fidelity: plan.fidelity, cameraReady: true, expectedName: "Original")
        XCTAssertEqual(check.outcome, .partiallyApplied)
        XCTAssertEqual(check.fields.first?.matches, false)
        XCTAssertTrue(check.reasons.contains { $0.contains("restored semantically") })
    }

    func testRestoreKelvinPrecedesBothShiftsEvenWhenKelvinResetsThem() async throws {
        typealias P = FujiPTP.PresetProp
        let saved = [P.whiteBalance.rawValue: FujiEncoding.packU16(FujiEncoding.wbColorTempValue),
                     P.colorTemp.rawValue: FujiEncoding.packU16(5600),
                     P.wbShiftR.rawValue: FujiEncoding.packI16(3), P.wbShiftB.rawValue: FujiEncoding.packI16(-5)]
        let model = try XCTUnwrap(CameraModelRegistry.shared.model(withID: "X-S10"))
        let codes = FujiPresetCodec.encodeRestore(from: saved, model: model).writes.map(\.code)
        XCTAssertEqual(codes, [P.whiteBalance.rawValue, P.colorTemp.rawValue, P.wbShiftR.rawValue, P.wbShiftB.rawValue])
        var faults = MockCameraFaults(); faults.isInstant = true; faults.kelvinResetsShifts = true
        let transport = MockCameraTransport(faults: faults)
        let manager = CameraServices(); await manager.connector.connectDemo(using: transport)
        let result = await manager.slotWriter.restore(saved, name: "Kelvin restored", toSlot: 1)
        XCTAssertEqual(result.outcome, .applied)
        for (code, expected) in saved {
            let actual = await transport.storedProperty(code, slot: 1)
            XCTAssertEqual(actual, expected)
        }
    }

}

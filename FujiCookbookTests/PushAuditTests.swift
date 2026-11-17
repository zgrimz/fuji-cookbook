import XCTest
@testable import FujiCookbook

/// Drives the real connect → identify → read → push path through each way it can go wrong, and
/// checks two things per case: what the camera physically holds afterwards, and what the app says
/// about it. Where those diverge, the app is telling someone something untrue about their own
/// camera, which is the bug these cases exist to catch.
///
/// | Case | Fault injected | Camera holds afterwards | Outcome |
/// |---|---|---|---|
/// | (h) | none — the control | name + requested settings | `.applied` |
/// | (a) | unknown body (`X-T99`) | nothing | `.notWritten`, naming the unsupported model |
/// | (b/c) | X-T30 III asked for REALA ACE | name + requested settings, REALA ACE | `.applied`, as the X-T30 III |
/// | (d) | Clarity answers `0x200A`; the recipe carries a clarity | nothing — the slot isn't even renamed | `.notWritten`, naming Clarity; all seven slots still read |
/// | (d′) | the X100V's four housekeeping properties answer `0x200A` | name + requested settings; nothing for the four | `.applied`; the result names the four |
/// | (e) | a five-slot body | name + requested settings | `.applied`; five slots kept |
/// | (f) | film simulation is refused | original film simulation + other requested settings | `.partiallyApplied`; Film Simulation refused |
/// | (g) | session dropped after four properties | new name + first four writes, remaining originals | `.unknown`; the rest not attempted |
///
/// The invariants behind those rows:
/// 1. "Unchanged" is said only when the camera is unchanged. The slot's base is read before the name
///    is written, so a push that fails early changes nothing; a push that changed the camera says so.
/// 2. A property a body lacks is recorded, not fatal — it costs that property, not the slot read,
///    and not the push unless the recipe carries a value for it, which no push writes without an
///    original to put back.
/// 3. The slot count comes from probing, not a constant.
/// 4. Verification covers what the recipe asked for, so a refused field can't hide under a
///    "verified" result.
/// 5. A disconnect is reported as "not attempted", never as missing camera features.
/// 6. Every property code has its own name, so a refusal says exactly which one.
/// 7. The pre-push warning and the write agree: a film simulation the body lacks is not written.
/// 8. An identified but unsupported body is told so, not asked to connect a camera.
/// 9. An exact match names the body the user owns, never its near-miss sibling.
///
/// Menu facts for bodies the record leaves out (film lists, bank counts, controls) are the registry's,
/// which names the Fujifilm manual or firmware note behind each entry; the older bodies' manuals are
/// linked in `docs/supported-cameras.md#sources-for-older-bodies`.
///
/// Camera facts in these tests are from zgrimz/fujifilm-ptp-reference:
/// `docs/03-encodings.md#0xd195-grain-effect`, `docs/04-custom-slots.md#how-many-banks`,
/// `docs/04-custom-slots.md#why-a-write-is-refused`, `docs/04-custom-slots.md#persistence-and-the-red-dot`,
/// `docs/07-cameras.md#gfx100s`, `docs/07-cameras.md#x-m5`, and
/// `docs/07-cameras.md#effect-controls-in-the-menus`.
@MainActor
final class PushAuditTests: XCTestCase {

    /// `CameraReportStore` is a real file in the App Group, and a report now adopts the push history
    /// of the last one describing the same body — so without this, one test's pushes show up in the
    /// next test's report.
    override func setUp() {
        super.setUp()
        CameraReportStore.deleteLatest()
    }

    // MARK: Harness

    /// Ground truth: what the camera actually holds in `slot`, read straight off the transport,
    /// bypassing everything the app believes.
    private func cameraHolds(_ transport: MockCameraTransport, slot: Int) async -> (name: String?, props: Int, filmSim: FilmSimulation?) {
        try? await transport.writeProperty(FujiPTP.Prop.slotSelector, FujiEncoding.packU16(slot))
        // `try?` on a throwing call that already returns an optional flattens to one level, so `d`
        // here is a plain `Data` — both "threw" and "answered nothing" collapse into no iteration.
        // An unnamed bank answers the count and the NUL, which parses to "": no name, as nil.
        let name = (try? await transport.readProperty(FujiPTP.Prop.presetName))
            .flatMap(FujiEncoding.parsePTPString).flatMap { $0.isEmpty ? nil : $0 }
        var count = 0
        var sim: FilmSimulation?
        for prop in FujiPTP.PresetProp.allCases {
            if let d = try? await transport.readProperty(prop.rawValue) {
                count += 1
                if prop == .filmSimulation, let raw = FujiEncoding.decodeInt16(d) {
                    sim = FujiEncoding.byteToFilmSim[raw]
                }
            }
        }
        return (name, count, sim)
    }

    private var recipe: RecipeSettings {
        RecipeSettings(
            filmSimulation: .classicNeg,
            grain: GrainEffect(strength: .weak, size: .large),
            colorChromeEffect: .strong, colorChromeFXBlue: .weak,
            whiteBalance: WhiteBalance(mode: .daylight, shiftRed: 2, shiftBlue: -3, kelvin: nil),
            dynamicRange: .dr400,
            highlightTone: -0.5, shadowTone: 1.0, color: 2, sharpness: -1, highISONR: -3, clarity: 1)
    }

    private func connect(_ faults: MockCameraFaults) async -> (CameraServices, MockCameraTransport) {
        var faults = faults
        faults.isInstant = true
        let transport = MockCameraTransport(faults: faults)
        let manager = CameraServices()
        await manager.connector.connectDemo(using: transport)
        return (manager, transport)
    }

    private func refusesFilmSimulation(productName: String? = nil) -> MockCameraFaults {
        var faults = MockCameraFaults()
        if let productName { faults.productName = productName }
        faults.invalidValueWriteCodes = [FujiPTP.PresetProp.filmSimulation.rawValue]
        return faults
    }

    // MARK: (h) Control — everything works

    func testCaseH_happyPath() async {
        let (m, t) = await connect(MockCameraFaults())
        let r = await m.slotWriter.push(settings: recipe, name: "Audit H", toSlot: 1)
        let truth = await cameraHolds(t, slot: 1)
        XCTAssertEqual(r.outcome, .applied)
        XCTAssertEqual(truth.filmSim, .classicNeg, "the baseline every other case is diffed against")
        XCTAssertEqual(truth.name, "Audit H")
    }

    // MARK: (a) Unknown body

    func testCaseA_unknownBody() async {
        let (m, t) = await connect(.unknownBody)
        let r = await m.slotWriter.push(settings: recipe, name: "Audit A", toSlot: 3)
        let truth = await cameraHolds(t, slot: 3)
        XCTAssertEqual(truth.props, 0, "nothing may be written to a body we could not identify")
        XCTAssertEqual(r.outcome, .notWritten, "and \"unchanged\" is a true statement here")
        // Invariant 8: an identified-but-unknown body isn't told to connect the camera it already
        // connected.
        XCTAssertEqual(r.errorMessage,
                       CameraError.unsupportedModel(name: "FUJIFILM X-T99").errorDescription)
    }

    // MARK: (b)(c) Wrongly matched — the X-T30 III

    func testCaseBC_wronglyMatchedBody() async {
        let (m, t) = await connect(.xT30III)
        var wanted = recipe
        wanted.filmSimulation = .realaAce   // ships on the real X-T30 III; absent from X-T30 II
        let r = await m.slotWriter.push(settings: wanted, name: "Audit C", toSlot: 1)
        let truth = await cameraHolds(t, slot: 1)
        // Invariant 9: the body is itself, not the X-T30 II — the warning, the dial reminder and the
        // block reason all name the right camera.
        XCTAssertEqual(m.session.connected?.model?.id, "X-T30 III")
        XCTAssertEqual(m.session.connected?.identification.confidence, "exact")
        // Invariant 7: REALA ACE is on this body's list, so nothing warns about it — and on a body
        // that lacks it, `clamped` drops it so the slot keeps its own (see the probe below).
        XCTAssertTrue(RecipeCompatibility.analyze(wanted, for: m.session.connected!.model!).isEmpty)
        // The X-T30 III is writable (CameraModelRegistry, X-Processor 5 / X-Trans IV group), so
        // REALA ACE reaching the slot proves the app resolved this body to its own entry: the
        // X-T30 II, whose name it nearly matches, has no such simulation to write.
        XCTAssertEqual(r.outcome, .applied)
        XCTAssertEqual(truth.filmSim, .realaAce, "the simulation only this body's entry allows")
        XCTAssertNil(r.errorMessage)
    }

    // MARK: (d) Known body missing a property the recipe carries

    /// Clarity answers `0x200A` and the recipe carries a clarity. The push's read records the
    /// property as absent and goes on, as the walk's does; what refuses the push is the originals
    /// guard, because a value the recipe carries is planned whatever the read said, and no write is
    /// made without an original to put back. Case (d′) is the body whose absent properties the plan
    /// never carries.
    func testCaseD_missingProperty() async {
        var f = MockCameraFaults()
        f.unsupportedReadCodes = [FujiPTP.PresetProp.clarity.rawValue]
        let (m, t) = await connect(f)
        // C1, which the mock seeds: an unseeded slot would be refused for every field, not for Clarity.
        let before = await cameraHolds(t, slot: 1)
        let r = await m.slotWriter.push(settings: recipe, name: "Audit D", toSlot: 1)
        let truth = await cameraHolds(t, slot: 1)
        // Invariant 2: a property the body lacks is recorded, not fatal — all seven slots are read,
        // each missing just that one property.
        XCTAssertEqual(m.slotReader.slots.count, 7, "one 0x200A doesn't lose the other slots")
        XCTAssertEqual(m.reports.report?.unsupportedPropertyCodes, ["0xD1A2"])
        // Invariant 1: `base` is read before the name write, so the push fails before it changes
        // anything, the slot is untouched, and "unchanged" is true.
        XCTAssertFalse(r.nameWritten, "the name isn't written ahead of the base read")
        XCTAssertEqual(truth.name, before.name, "slot never renamed")
        XCTAssertEqual(truth.filmSim, before.filmSim, "slot never written")
        XCTAssertEqual(truth.props, before.props)
        XCTAssertEqual(r.outcome, .notWritten, "and the app may truthfully say so")
        // The refusal says what the body said, not to reconnect: reconnecting changes nothing.
        XCTAssertEqual(r.errorMessage, "This camera doesn't have Clarity (0x200A), and this push writes it, so there is no original to put back. Nothing was written.")
    }

    /// The two reasons an original can be missing read differently: a read that answered nothing
    /// usable is worth a reconnect, a `0x200A` is the body saying it lacks the property. Both at
    /// once, or a missing name, keep the reconnect and add what the body said.
    func testTheOriginalsRefusalIsPhrasedByCause() {
        XCTAssertEqual(SlotWriter.unrecoverableOriginalsMessage(unread: [], lacking: ["Clarity", "Grain Effect"], nameMissing: false),
                       "This camera doesn't have Clarity, Grain Effect (0x200A), and this push writes them, so there is no original to put back. Nothing was written.")
        XCTAssertEqual(SlotWriter.unrecoverableOriginalsMessage(unread: ["Film Simulation"], lacking: [], nameMissing: false),
                       "The original bank settings could not be preserved (Film Simulation). Nothing was written. Reconnect and read the bank again.")
        XCTAssertEqual(SlotWriter.unrecoverableOriginalsMessage(unread: ["Film Simulation"], lacking: ["Clarity"], nameMissing: true),
                       "The original bank settings could not be preserved (Film Simulation); its original name is unavailable. Nothing was written. Reconnect and read the bank again. This camera doesn't have Clarity (0x200A), and this push writes it, so there is no original to put back.")
        XCTAssertEqual(SlotWriter.unrecoverableOriginalsMessage(unread: [], lacking: [], nameMissing: true),
                       "The original bank settings could not be preserved; its original name is unavailable. Nothing was written. Reconnect and read the bank again.")
    }

    // MARK: (d′) Known body missing properties the plan passes through

    /// The record's X100V answers `0x200A` to four housekeeping properties on every bank
    /// (`MockCameraFaults.x100V`). The read records them as absent, the plan passes a housekeeping
    /// property through only from the bytes the slot gave, so nothing is planned for them, and the
    /// push lands with the 19 the body has.
    func testCaseDPrime_bodyLackingPassthroughProperties() async {
        AppLog.clear(.camera)
        let (m, t) = await connect(.x100V)
        let r = await m.slotWriter.push(settings: recipe, name: "Audit D2", toSlot: 1)
        let truth = await cameraHolds(t, slot: 1)
        XCTAssertEqual(r.outcome, .applied, r.errorMessage ?? "")
        XCTAssertEqual(truth.name, "Audit D2")
        XCTAssertEqual(truth.filmSim, .classicNeg)
        // Nothing planned for the four: no row, and no write on the wire.
        let absent = MockCameraFaults.x100VAbsentProperties
        XCTAssertTrue(r.fields.allSatisfy { !absent.contains($0.code) },
                      "no row for a property the body lacks: \(r.fields.map(\.field))")
        let absentCodes = absent.map(PTPHex.code)
        let writesToAbsent = m.reports.report?.transactions.filter {
            $0.operation == "0x1016" && $0.parameters.first.map(absentCodes.contains) == true
        } ?? []
        XCTAssertTrue(writesToAbsent.isEmpty, "no write is sent for a property the body lacks: \(writesToAbsent)")
        // The result says so, once; the report carries the codes, as it does for the walk.
        XCTAssertEqual(r.notes.first, "Image Size, Image Quality, Lens Modulation Optimizer, Color Space: this camera doesn't have them (0x200A), so nothing was written for them.")
        XCTAssertEqual(m.reports.report?.unsupportedPropertyCodes, ["0xD18E", "0xD18F", "0xD1A3", "0xD1A4"])
        // A `0x200A` is not an unanswered read, and is not called one.
        XCTAssertFalse(AppLog.reportText(in: .camera).contains("read returned nothing for"))
        XCTAssertFalse(m.reports.report?.notes.contains { $0.contains("base read missing") } ?? true)
    }

    // MARK: (e) Fewer slots than assumed

    func testCaseE_fewerSlots() async {
        let (m, t) = await connect(.fiveSlots)
        let r = await m.slotWriter.push(settings: recipe, name: "Audit E", toSlot: 1)
        let truth = await cameraHolds(t, slot: 1)
        // Invariant 3: the slot count comes from probing. C6's refusal ends the read with five slots
        // kept and the session still connected, not an error under a success sheet.
        XCTAssertEqual(r.outcome, .applied)
        XCTAssertEqual(truth.props, FujiPTP.PresetProp.allCases.count, "C1 retains its complete bank snapshot")
        XCTAssertEqual(m.slotReader.slots.count, 5, "C1–C5 read fine and are kept")
        XCTAssertEqual(m.slotReader.probedSlotCount, 5)
        XCTAssertEqual(m.session.status, .connected, "no error under the success sheet")
    }

    // MARK: (f) Write rejected partway through the loop

    func testCaseF_writeRejectedPartway() async {
        let (m, t) = await connect(refusesFilmSimulation())
        let r = await m.slotWriter.push(settings: recipe, name: "Audit F", toSlot: 1)
        let truth = await cameraHolds(t, slot: 1)
        // Invariant 4: the film simulation remains unchanged, so the new recipe must not
        // be reported as verified.
        XCTAssertEqual(truth.filmSim, .classicChrome, "the refused write leaves the original film simulation")
        XCTAssertEqual(r.outcome, .partiallyApplied)
        XCTAssertEqual(r.rejected.map(\.field), ["Film Simulation"])
        XCTAssertTrue(r.plainLanguageState.contains("holds a mix"),
                      "the screen states what the slot holds: \(r.plainLanguageState)")
    }

    // MARK: (g) Session dropped mid-push

    func testCaseG_sessionDroppedMidPush() async {
        let (m, t) = await connect(.dropMidPush)
        let r = await m.slotWriter.push(settings: recipe, name: "Audit G", toSlot: 1)
        // The transport is dropped; reopen to see what the camera kept.
        try? await t.open()
        let truth = await cameraHolds(t, slot: 1)
        // Invariant 1: the writes landed, and the app says so.
        XCTAssertEqual(r.fields.filter { $0.outcome == .unverified }.count, 4, "four properties were accepted before the drop")
        XCTAssertEqual(truth.props, FujiPTP.PresetProp.allCases.count, "the bank retains its original fields through a partial push")
        XCTAssertEqual(truth.name, "Audit G", "and the slot carries the new name")
        XCTAssertEqual(r.outcome, .unknown, "not .notWritten — the camera was changed")
        XCTAssertTrue(r.plainLanguageState.contains("may have changed"),
                      "the screen doesn't claim otherwise: \(r.plainLanguageState)")
        // Invariant 5: a disconnect isn't reported as missing camera features.
        XCTAssertTrue(r.rejected.isEmpty, "nothing was refused — the cable came out")
        XCTAssertFalse(r.notAttempted.isEmpty, "the rest were never attempted, and say so")
        // Invariant 6: every property is named unambiguously.
        let wbNames = Set((r.rejected + r.notAttempted).map(\.field).filter { $0.contains("WB") || $0.contains("White") || $0.contains("Color Temp") })
        XCTAssertTrue(wbNames.count >= 2, "white-balance codes are distinguishable now: \(wbNames)")
    }

    // MARK: The push in the report, and the backup that precedes it

    /// The compatibility report captures what a push did, not only the camera as it was before one:
    /// a diffable artifact that left the single most consequential event in the session to the log
    /// alone would be silent about it.
    func testPushOutcomeReachesTheCompatibilityReport() async {
        let (m, _) = await connect(refusesFilmSimulation())
        _ = await m.slotWriter.push(settings: recipe, name: "Audit R", toSlot: 1)

        let push = m.reports.report?.pushes?.first
        XCTAssertEqual(m.reports.report?.pushes?.count, 1)
        XCTAssertEqual(push?.slot, 1)
        XCTAssertEqual(push?.outcome, .partiallyApplied)
        XCTAssertEqual(push?.modelID, CameraModelRegistry.demoModelID)
        XCTAssertEqual(push?.firmwareVersion, "1.00", "a rejection is dated to a firmware or it can't be compared")

        let rejected = push?.fields.filter { $0.outcome == "rejected" } ?? []
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?.responseCode, "0x201C", "the camera's own answer is the finding")
        XCTAssertNotNil(rejected.first?.code, "and which property it refused")

        XCTAssertTrue(m.reports.report!.textRendering.contains("Pushes      1"),
                      "the text and the JSON stay one account")
    }

    /// Every push is recorded, and the cap drops the oldest rather than stopping at the newest.
    func testRepeatedPushesAreAllRecorded() async {
        let (m, _) = await connect(MockCameraFaults())
        for slot in 1...3 { _ = await m.slotWriter.push(settings: recipe, name: "Audit \(slot)", toSlot: slot) }

        XCTAssertEqual(m.reports.report?.pushes?.map(\.slot), [1, 2, 3])
        XCTAssertNil(m.reports.report?.pushesDropped)
    }

    /// The one slot a push can damage, captured from the read the push already performs to build
    /// its patch. Cheaper than a separate backup file and it lands in the artifact the tester
    /// sends anyway.
    func testThePrePushBytesOfTheTargetSlotAreRecorded() async {
        let (m, _) = await connect(MockCameraFaults(productName: "FUJIFILM X-T5"))
        XCTAssertEqual(m.session.connected?.model?.verification, .community,
                       "a published bench, not a write through this app — still a body whose pre-push bytes matter")
        let slotAsRead = m.slotReader.slots.first { $0.index == 1 }?.rawProperties ?? [:]
        let before = slotAsRead[FujiPTP.PresetProp.filmSimulation.rawValue]

        // C1 holds "Sunny 16" — push over it, which is exactly what a tester risks.
        _ = await m.slotWriter.push(settings: recipe, name: "Audit B", toSlot: 1)

        let recorded = m.reports.report?.pushes?.first?.slotBefore
        XCTAssertEqual(recorded?.count, slotAsRead.count,
                       "every property the slot answered, not just the fields the recipe touched")
        XCTAssertGreaterThan(slotAsRead.count, 1, "precondition: the slot actually held something")
        XCTAssertEqual(recorded?["0xD192"], before.map { $0.map { String(format: "%02X", $0) }.joined() },
                       "the film simulation as it was, not as the push left it")
    }

    /// A push that never reaches the camera has nothing to record — and `notWritten` is the state
    /// in which "your slot is unchanged" is true, so an absent `slotBefore` is correct rather than
    /// missing data.
    func testAPushThatWritesNothingRecordsNoPriorBytes() async {
        let (m, _) = await connect(.noSlotProtocolBody)
        XCTAssertFalse(m.session.connected?.isWritable ?? true, "precondition: the X-T20 is blocked")

        let r = await m.slotWriter.push(settings: recipe, name: "Audit RO", toSlot: 1)

        XCTAssertEqual(r.outcome, .notWritten)
        XCTAssertNil(m.reports.report?.pushes?.first?.slotBefore)
    }

    // MARK: The slot walk against Fujifilm's manual (documentedSlotCount, 2026-09-16)

    /// An X-S20 whose mock refuses C5 — exactly where the manual says its mode dial ends.
    private func xS20(refusingAbove max: Int?) -> MockCameraFaults {
        var f = MockCameraFaults(productName: "FUJIFILM X-S20", firmwareVersion: nil)
        f.maxSelectableSlot = max
        return f
    }

    /// A refusal at the documented boundary is the prediction confirmed. It used to produce an
    /// error-level log line and a note phrased as a discovery, on every connect and every push,
    /// on exactly the bodies whose reports get read most carefully.
    func testARefusalAtTheDocumentedBoundaryIsRecordedAsExpected() async {
        let (m, _) = await connect(xS20(refusingAbove: 4))
        XCTAssertEqual(m.session.model?.documentedSlotCount, 4, "precondition")
        XCTAssertEqual(m.reports.report?.slots.probedSlotCount, 4)
        XCTAssertEqual(m.reports.report?.slots.documentedSlotCount, 4)
        XCTAssertEqual(m.slotReader.slots.count, 4)
        let notes = m.reports.report?.notes ?? []
        XCTAssertTrue(notes.contains { $0.contains("expected") && $0.contains("4 banks") },
                      "the note says this is the manual confirmed, not a finding: \(notes)")
        XCTAssertFalse(notes.contains { $0.contains("Fewer than documented") })
        XCTAssertFalse(notes.contains { $0.contains("exposes more than the menu") })
    }

    /// A refusal short of the documented count is a real finding and must not be filed as expected.
    func testARefusalShortOfTheDocumentedCountIsAFinding() async {
        let (m, _) = await connect(xS20(refusingAbove: 2))
        XCTAssertEqual(m.reports.report?.slots.probedSlotCount, 2)
        let notes = m.reports.report?.notes ?? []
        XCTAssertTrue(notes.contains { $0.contains("Fewer than documented") && $0.contains("manual says 4") },
                      "\(notes)")
        XCTAssertFalse(notes.contains { $0.contains("expected:") })
    }

    /// A walk that runs past the documented count is the case a lowered `slotCount` would have
    /// hidden forever, and the one worth the loudest line in the report. The mock's seven banks
    /// all take the select; the manual says four.
    func testAWalkPastTheDocumentedCountIsTheLoudestNote() async {
        let (m, _) = await connect(xS20(refusingAbove: nil))
        XCTAssertEqual(m.reports.report?.slots.probedSlotCount, 7)
        XCTAssertEqual(m.slotReader.slots.count, 7, "the ceiling stayed at 7 so the extra banks were found")
        let notes = m.reports.report?.notes ?? []
        XCTAssertTrue(notes.contains { $0.contains("exposes more than the menu") && $0.contains("7 slot") },
                      "\(notes)")
    }

    /// A body with no documented count gets exactly what it always got.
    func testABodyWithNoDocumentedCountKeepsTheOldRefusalNote() async {
        let (m, _) = await connect(.fiveSlots)
        XCTAssertNil(m.session.model?.documentedSlotCount, "precondition: the demo body carries no manual entry")
        let notes = m.reports.report?.notes ?? []
        XCTAssertTrue(notes.contains { $0.contains("this body has 5 slots") }, "\(notes)")
        XCTAssertFalse(notes.contains { $0.contains("manual") })
    }

    // MARK: The selected bank is put back

    /// `0xD18C` chooses the bank the host edits — it isn't the camera's bank switch
    /// (zgrimz/fujifilm-ptp-reference `docs/04-custom-slots.md`) — and every Part One operation that
    /// selects banks in turn would otherwise leave it wherever it finished.
    private func selectorNow(_ t: MockCameraTransport) async -> Int? {
        ((try? await t.readProperty(FujiPTP.Prop.slotSelector)) ?? nil)
            .flatMap(FujiEncoding.decodeUInt16).map(Int.init)
    }

    /// The connect walk selects C1…C5 on a five-slot body, which would leave the camera on C5.
    func testTheSlotWalkPutsTheSelectedBankBack() async {
        let (m, t) = await connect(.fiveSlots)
        XCTAssertEqual(m.slotReader.slots.count, 5, "precondition: the walk ran to the body's last bank")
        let now = await selectorNow(t)
        XCTAssertEqual(now, 1, "the mock starts on C1; the walk ended on C5; it was put back")
        XCTAssertEqual(m.reports.report?.slots.selectorBeforeRead, 1)
        XCTAssertEqual(m.reports.report?.slots.selectorRestored, true)
    }

    /// The stronger case: a push lands on C2 and the walk that follows it re-selects every bank.
    /// Afterwards the camera should be on C2 — the bank the tester just wrote and expects to be
    /// on — not on the last bank the walk touched.
    func testThePostPushWalkRestoresToThePushedBank() async {
        let (m, t) = await connect(MockCameraFaults())
        _ = await m.slotWriter.push(settings: recipe, name: "Selector", toSlot: 2)
        let now = await selectorNow(t)
        XCTAssertEqual(now, 2, "the push selected C2; the walk after it must not move off it")
        XCTAssertEqual(m.reports.report?.slots.selectorBeforeRead, 2, "what the walk found on arrival")
        XCTAssertEqual(m.reports.report?.slots.selectorRestored, true)
    }

    /// The property report selects the slot the tester asked about, reads it, and puts the bank
    /// back. The report it produces still names the slot it read.
    func testThePropertyReportPutsTheSelectedBankBack() async throws {
        let (m, t) = await connect(MockCameraFaults())
        let before = await selectorNow(t)
        let result = try await m.diagnostics.probeProperties(slot: 2)
        XCTAssertEqual(result.slot, 2, "it read the slot it was asked to")
        let now = await selectorNow(t)
        XCTAssertEqual(now, before, "and the camera is back on the bank it was on")
    }

    /// The grain probe selects a slot, writes candidates, restores the property — and now the bank.
    func testTheGrainProbePutsTheSelectedBankBack() async throws {
        let (m, t) = await connect(MockCameraFaults())
        let before = await selectorNow(t)
        let entries = try await m.diagnostics.probeWriteValues(slot: 2, property: FujiPTP.PresetProp.grain, candidates: [1, 2])
        XCTAssertFalse(entries.isEmpty, "precondition: the probe ran")
        let now = await selectorNow(t)
        XCTAssertEqual(now, before)
    }

    /// The durability bug the separate backup file was covering for, fixed where it actually
    /// mattered: `begin` makes a fresh report on every connect and the store keeps only the newest,
    /// so someone who pushed, unplugged and plugged back in would lose the record of what the
    /// camera refused — which is the most valuable thing an untested body produces.
    func testPushHistorySurvivesAReconnectToTheSameBody() async {
        let (m, _) = await connect(refusesFilmSimulation(productName: "FUJIFILM X-T5"))
        _ = await m.slotWriter.push(settings: recipe, name: "Audit 1", toSlot: 1)
        XCTAssertEqual(m.reports.report?.pushes?.count, 1)
        await m.connector.disconnect()

        let (m2, _) = await connect(refusesFilmSimulation(productName: "FUJIFILM X-T5"))

        XCTAssertEqual(m2.reports.report?.pushes?.count, 1, "the earlier push came forward")
        XCTAssertEqual(m2.reports.report?.pushes?.first?.outcome, .partiallyApplied)
        XCTAssertEqual(m2.reports.report?.pushes?.first?.fields.first { $0.outcome == "rejected" }?.responseCode,
                       "0x201C", "with the code the camera answered")

        _ = await m2.slotWriter.push(settings: recipe, name: "Audit 2", toSlot: 2)
        XCTAssertEqual(m2.reports.report?.pushes?.map(\.slot), [1, 2], "oldest first")
    }

    /// And it must not adopt another camera's history. The mock reports one fixed serial, so both
    /// bodies hash identically — exactly the contradiction (`hash agrees, name doesn't`) the matcher
    /// resolves by refusing.
    func testPushHistoryIsNotCarriedToADifferentBody() async {
        let (m, _) = await connect(MockCameraFaults(productName: "FUJIFILM X-T5"))
        _ = await m.slotWriter.push(settings: recipe, name: "Audit 1", toSlot: 1)
        await m.connector.disconnect()

        let (m2, _) = await connect(MockCameraFaults(productName: "FUJIFILM X-H2"))

        XCTAssertNil(m2.reports.report?.pushes, "a different body starts with no history")
    }

    /// A fully-applied push used to log nothing at all, so a shared report showed a session where
    /// the camera connected and then, as far as the log was concerned, nothing happened.
    func testACleanPushStillWritesALogLine() async {
        AppLog.clear(.camera)
        let (m, _) = await connect(MockCameraFaults())

        _ = await m.slotWriter.push(settings: recipe, name: "Audit L", toSlot: 1)

        let log = AppLog.reportText(in: .camera)
        XCTAssertTrue(log.contains("Push:"), "no push line at all in: \(log)")
        XCTAssertTrue(log.contains("C1"))
        XCTAssertTrue(log.contains("applied"))
    }

    /// Rejection logging used to be gated on `isRecipeField`. A real X-T50 refused `0x201C` on D18E
    /// Image Size — a housekeeping property — while writing back the slot's own current value, and
    /// the only trace was a context-free transport error naming neither the property nor the push.
    func testAHousekeepingRejectionIsLoggedWithItsCode() async {
        AppLog.clear(.camera)
        var faults = MockCameraFaults()
        faults.unsupportedWriteCodes = [FujiPTP.PresetProp.imageSize.rawValue]
        let (m, _) = await connect(faults)

        let r = await m.slotWriter.push(settings: recipe, name: "Audit H", toSlot: 1)

        XCTAssertEqual(r.outcome, .applied, "a housekeeping refusal must not change the headline")
        let log = AppLog.reportText(in: .camera)
        XCTAssertTrue(log.contains("D18E"), "the property code is the finding; got: \(log)")
        XCTAssertTrue(log.contains("Image Size"))
    }

    // MARK: The trace covers the push

    /// A body with no slot protocol is refused at the allowlist, before any of the push machinery
    /// runs — so the refusal costs the camera nothing, not even the select that would open a push.
    func testPushIsRefusedOnANoSlotProtocolBody() async {
        let (m, t) = await connect(.noSlotProtocolBody)
        XCTAssertEqual(m.session.model?.id, "X-T20")
        XCTAssertFalse(m.session.canPush)
        let before = await t.totalWriteCount

        let r = await m.slotWriter.push(settings: recipe, name: "Nope", toSlot: 1)

        XCTAssertEqual(r.outcome, .notWritten)
        XCTAssertTrue(r.errorMessage?.contains("bank protocol") ?? false, "got: \(r.errorMessage ?? "nil")")
        let after = await t.totalWriteCount
        XCTAssertEqual(after, before, "nothing reached the camera")
    }

    /// The recorder used to be disarmed at the end of connect and never re-armed, so no push had
    /// ever been in a report: the one refusal that mattered had no timing and no neighbours. The
    /// push is traced now; the re-read of every slot that follows it is not — `slots.reads`
    /// already carries that result, and ~190 near-identical reads per push would crowd out the
    /// writes.
    func testPushTransactionsReachTheTrace() async {
        let (m, _) = await connect(MockCameraFaults())
        func writes(of prop: String, in t: [PTPTransaction]) -> Int {
            t.filter { $0.operation == "0x1016" && $0.parameters.first == prop }.count
        }
        let scan = m.reports.report!.transactions
        XCTAssertEqual(writes(of: "0xD18D", in: scan), 0, "the connect scan writes no names")
        let scanSelects = writes(of: "0xD18C", in: scan)
        XCTAssertGreaterThan(scanSelects, 0, "but it does select every slot")

        _ = await m.slotWriter.push(settings: recipe, name: "Traced", toSlot: 1)

        let after = m.reports.report!.transactions
        XCTAssertEqual(writes(of: "0xD18D", in: after), 1, "the push's name write is in the trace")
        XCTAssertEqual(writes(of: "0xD192", in: after), 1, "and its film simulation write")
        XCTAssertEqual(writes(of: "0xD18C", in: after), scanSelects + 1,
                       "one select for the push; the post-push re-read of every slot is not traced")
        XCTAssertEqual(m.reports.report!.transactionsDropped, 0)
        XCTAssertEqual(CameraReportStore.loadLatest()?.transactions.count, after.count, "and it is on disk")
    }

    // MARK: A refusal that is about the bank, not the recipe

    /// The X-T50 signature, verified 2026-09-06: D18E refused 0x201C on every push to C1 while
    /// C2–C7 took the same byte — because C1 had SPORTS FINDER MODE on. The results screen never
    /// showed the refusal (Image Size isn't a recipe field); now it says what the refusal means.
    func testImageSizeRefusalIsExplainedAsABankSetting() async {
        AppLog.clear(.camera)
        var faults = MockCameraFaults()
        faults.invalidValueWriteCodes = [FujiPTP.PresetProp.imageSize.rawValue]
        let (m, _) = await connect(faults)

        let r = await m.slotWriter.push(settings: recipe, name: "Sports", toSlot: 1)

        XCTAssertEqual(r.outcome, .applied, "the recipe landed; the headline says so")
        XCTAssertTrue(r.imageSizeFixedByBank)
        let bankNotes = r.notes.filter { $0.contains("Sports Finder Mode") }
        XCTAssertEqual(bankNotes.count, 1, "\(r.notes)")
        XCTAssertTrue(r.rejected.isEmpty, "not a recipe field — it was never on the refused list, and still isn't")
        XCTAssertTrue(AppLog.reportText(in: .camera).contains("the bank fixes Image Size"))
        XCTAssertTrue(m.reports.report!.notes.contains { $0.contains("fixes Image Size") },
                      "the report carries the interpretation next to the fact")
    }

    /// `0x200A` on D18E says the operation isn't supported in the current context
    /// (zgrimz/fujifilm-ptp-reference `docs/01-transport.md#response-codes`) — a different statement,
    /// not this one.
    func testImageSizeNoteNeedsTheExactResponseCode() async {
        var faults = MockCameraFaults()
        faults.unsupportedWriteCodes = [FujiPTP.PresetProp.imageSize.rawValue]
        let (m, _) = await connect(faults)

        let r = await m.slotWriter.push(settings: recipe, name: "Other", toSlot: 2)

        XCTAssertFalse(r.imageSizeFixedByBank)
        XCTAssertFalse(r.notes.contains { $0.contains("Image Size") }, "\(r.notes)")
    }

    // MARK: The red dot a push leaves on the camera

    /// Every property write leaves a red dot on the written items in EDIT/SAVE CUSTOM SETTING, which
    /// a user reads as "not saved" and may answer with RESET THE CHANGES — which does not undo a
    /// push (X-T50 fw 1.32, 2026-10-16). An applied push says so before they get there.
    func testAnAppliedPushExplainsTheRedDot() async {
        let (m, _) = await connect(MockCameraFaults())

        let r = await m.slotWriter.push(settings: recipe, name: "Dot", toSlot: 2)

        XCTAssertEqual(r.outcome, .applied)
        XCTAssertTrue(r.notes.contains { $0.contains("red dot") && $0.contains("Undo Last Push") }, "\(r.notes)")
    }

    /// A refusal with nothing else written is a failed push, not a bank setting.
    func testImageSizeSignatureNeedsTheRecipeWritten() {
        let size = FieldResult(code: FujiPTP.PresetProp.imageSize.rawValue, field: "Image Size",
                               isRecipeField: false, outcome: .rejected(code: FujiPTP.responseInvalidDevicePropValue))
        let sim = FieldResult(code: FujiPTP.PresetProp.filmSimulation.rawValue, field: "Film Simulation",
                              isRecipeField: true, outcome: .notAttempted)
        let failed = SlotWriteResult(slot: 1, outcome: .notWritten, nameWritten: false, nameApplied: nil,
                                     clampedFields: [], fields: [size, sim], errorMessage: nil)
        XCTAssertFalse(failed.imageSizeFixedByBank)

        var landed = failed
        landed.fields[1].outcome = .written
        XCTAssertTrue(landed.imageSizeFixedByBank)
    }

    // MARK: The slot select, verified before anything is written

    /// The failure this whole guard exists for: a body that answers OK to the select and stays put.
    /// Everything downstream — the base read, the name, the writes, the read-back — then addresses
    /// the same wrong slot and agrees with itself, so without the guard the push would report
    /// `.applied` for a slot it never touched.
    func testASilentlyIgnoredSelectRefusesThePush() async {
        AppLog.clear(.camera)
        var faults = MockCameraFaults.selectorIgnoresWrites
        faults.isInstant = true
        let transport = MockCameraTransport(faults: faults)
        let m = CameraServices()
        await m.connector.connectDemo(using: transport)

        let r = await m.slotWriter.push(settings: recipe, name: "Audit S", toSlot: 3)

        XCTAssertEqual(r.outcome, .notWritten, "nothing had been written when the select was checked")
        XCTAssertTrue(r.fields.isEmpty, "the push never reached the encode set")
        XCTAssertTrue(r.errorMessage?.contains("C3") ?? false, "the message names the slot asked for")

        // The assertion that matters: the slot the body is *actually* on is untouched. Selecting C1
        // is a no-op on a camera already there, so this reads the real contents — and they are still
        // the mock's originals, not the recipe the push was carrying.
        let landed = await cameraHolds(transport, slot: 1)
        XCTAssertEqual(landed.name, "Sunny 16", "the recipe did not land in the slot the camera was on")
        XCTAssertEqual(landed.filmSim, .classicChrome, "nor did its film simulation")

        let log = AppLog.reportText(in: .camera)
        XCTAssertTrue(log.contains("select refused"), "got: \(log)")
    }

    /// And the report says so, which is what lets a tester's push be trusted at all.
    func testTheSelectorReadBackIsRecorded() async {
        let (m, _) = await connect(MockCameraFaults())

        _ = await m.slotWriter.push(settings: recipe, name: "Audit V", toSlot: 2)

        XCTAssertEqual(m.reports.report?.pushes?.first?.selectorReadBack, 2,
                       "a healthy push proves which slot it addressed")
        XCTAssertFalse(m.reports.report!.textRendering.contains("selector read back as"),
                       "and stays quiet about it when it agrees")
    }

    /// A slot read must stop rather than file one slot's values under another's number — that
    /// fiction would feed the Import screen and the push screen's overwrite warnings.
    func testAnIgnoredSelectStopsTheSlotReadInsteadOfMisattributingIt() async {
        var faults = MockCameraFaults.selectorIgnoresWrites
        faults.isInstant = true
        let m = CameraServices()
        await m.connector.connectDemo(using: MockCameraTransport(faults: faults))

        // C1 is honest: the body was already on slot 1, so that select *did* take. C2 is where the
        // lie would have started, and the read stops there rather than filing C1's values under C2.
        XCTAssertEqual(m.slotReader.slots.map(\.index), [1], "one truthful slot, not seven identical ones")
        XCTAssertEqual(m.reports.report?.slots.probedSlotCount, 1)
        XCTAssertTrue(m.reports.report!.notes.contains { $0.contains("did not take") },
                      "and the report says why: \(m.reports.report!.notes)")
    }

    // MARK: Film simulation, end to end

    /// Every simulation through a real push: encode → mock write → read-back → refresh → decode.
    /// The codec round-trip proves the table; this proves the slot ends up holding what the recipe
    /// said, that the results screen can name it, and that the report recorded the byte.
    func testEveryFilmSimulationPushesAndReadsBack() async {
        for sim in FilmSimulation.allCases {
            let (m, _) = await connect(MockCameraFaults())
            var settings = recipe
            settings.filmSimulation = sim
            if sim.isMonochrome { settings.color = nil; settings.monochromaticColorWC = 1 }

            let r = await m.slotWriter.push(settings: settings, name: sim.displayName, toSlot: 1)

            XCTAssertEqual(r.outcome, .applied, "\(sim)")
            XCTAssertEqual(r.filmSimulationReadBack, sim, "\(sim): the results screen can't name what landed")
            XCTAssertEqual(m.slotReader.slots.first { $0.index == 1 }?.settings?.filmSimulation, sim, "\(sim): the slot holds something else")
            let wrote = m.reports.report?.pushes?.last?.fields
                .first { $0.code == PTPHex.code(FujiPTP.PresetProp.filmSimulation.rawValue) }?.wrote
            XCTAssertEqual(wrote, PTPHex.bytes(FujiEncoding.packU16(FujiEncoding.filmSimToByte[sim]!)),
                           "\(sim): the report doesn't say what D192 got")
            await m.connector.disconnect()
        }
    }

    /// The one write the push makes on the user's behalf. A recipe that leaves D-Range Priority
    /// unset is pushed with the default, Off — and the migration storing that default is lazy, so a
    /// library recipe nobody has re-saved still holds nil. The codec clears the bank's priority
    /// either way; the message used to fire only when the recipe also set a dynamic range.
    func testClearingABanksPriorityIsSaidEvenWhenTheRecipeSetsNoDynamicRange() async {
        AppLog.clear(.camera)
        let (m, _) = await connect(MockCameraFaults())
        // Put the priority on first (the mock doesn't model the ISO gate, so this lands).
        _ = await m.slotWriter.push(settings: RecipeSettings(filmSimulation: .classicChrome, dRangePriority: .strong),
                         name: "Priority On", toSlot: 1)

        var neither = recipe
        neither.dynamicRange = nil
        neither.dRangePriority = nil
        let r = await m.slotWriter.push(settings: neither, name: "Neither", toSlot: 1)

        XCTAssertEqual(r.outcome, .applied)
        XCTAssertEqual(r.fields.first { $0.code == FujiPTP.PresetProp.dRangePriority.rawValue }?.wrote,
                       FujiEncoding.packU16(0), "cleared to Off")
        XCTAssertTrue(r.advisories.contains { $0.contains("D-Range Priority was Strong") },
                      "and said out loud, not left as a 'written' row: \(r.advisories)")
        XCTAssertFalse(r.advisories.contains { $0.contains("Dynamic Range take effect") },
                       "with no dynamic range in the recipe, that clause is not the reason")
        XCTAssertTrue(AppLog.reportText(in: .camera).contains("D-Range Priority Strong → Off"))
    }

    /// A warning that reaches the pre-push screen and vanishes before the results is how "Written
    /// and verified" ends up over a slot that didn't get what was asked — which is the whole reason
    /// `preflight.advisories` exists; the D-Range Priority test above pins the channel. The
    /// magenta–green axis warning used to be its live instance, raised on the X100V by a processor
    /// rule. The X100V has both axes (Fujifilm's manual), so a push carrying an MG value writes it
    /// with no advisory at all.
    func testAnX100VPushWritesTheMagentaGreenAxisWithoutAWarning() async {
        let (m, transport) = await connect(MockCameraFaults(productName: "FUJIFILM X100V"))
        let model = m.session.connected?.model
        XCTAssertEqual(model?.processor, .xProcessor4)
        XCTAssertEqual(model?.hasMagentaGreenAxis, true, "the X100V's manual documents both axes")

        let mono = RecipeSettings(filmSimulation: .acros, monochromaticColorWC: 2, monochromaticColorMG: 3)
        let r = await m.slotWriter.push(settings: mono, name: "Mono MG", toSlot: 2)

        XCTAssertEqual(r.outcome, .applied)
        XCTAssertFalse(r.advisories.contains { $0.contains("magenta–green") },
                       "a body with the axis has nothing to warn about: \(r.advisories)")
        let storedMG = await transport.storedProperty(FujiPTP.PresetProp.monochromaticMG.rawValue, slot: 2)
        XCTAssertEqual(storedMG, FujiEncoding.packI16(30), "the value is written, not warned about")
    }

    /// "The slot's read returned nothing for X" has to mean that and only that. A push also leaves
    /// properties out because nothing changes — `D191` when the recipe's D-Range Priority already
    /// matches the bank's, `D190` whenever that priority will be on — and those must not be logged or
    /// noted as properties the bank failed to answer.
    func testAPropertyOmittedBecauseNothingChangedIsNotCalledUnanswered() async {
        AppLog.clear(.camera)
        let (m, _) = await connect(MockCameraFaults())

        // The mock's banks answer for D191 and hold Off; the recipe's default is Off too, so the
        // codec has nothing to write and omits it.
        var settings = recipe
        settings.dRangePriority = .off
        let r = await m.slotWriter.push(settings: settings, name: "No Change", toSlot: 1)

        XCTAssertEqual(r.outcome, .applied)
        XCTAssertFalse(r.fields.contains { $0.code == FujiPTP.PresetProp.dRangePriority.rawValue },
                       "precondition: nothing to change, so nothing was sent")
        XCTAssertFalse(AppLog.reportText(in: .camera).contains("returned nothing for D-Range Priority"),
                       "the bank answered; only the write was unnecessary")
    }

    /// The converse, so the message still fires where it is true.
    func testAPropertyTheSlotNeverReportedIsStillCalledUnanswered() async {
        AppLog.clear(.camera)
        let (m, _) = await connect(.silentFilmSimulationRead)

        var settings = recipe
        settings.filmSimulation = nil
        _ = await m.slotWriter.push(settings: settings, name: "Silent D192", toSlot: 1)

        XCTAssertTrue(AppLog.reportText(in: .camera).contains("returned nothing for Film Simulation"),
                      "this one really did answer nothing")
    }

    /// A recipe with no film simulation, pushed over an occupied slot: the slot keeps its own, the
    /// push says so on the way in (advisory), on the way through (log), and on the way out (value).
    /// Keeping the slot's own simulation would make one recipe produce a different look on every bank
    /// it touched, with the push reporting "written and verified" over the difference. So PROVIA is
    /// written — the same value an empty bank is seeded with — and the advisory still fires, because
    /// the recipe did not ask for it.
    func testANilFilmSimulationPushWritesProviaAndSaysSo() async {
        AppLog.clear(.camera)
        let (m, _) = await connect(MockCameraFaults())
        let before = m.slotReader.slots.first { $0.index == 1 }?.settings?.filmSimulation
        XCTAssertNotNil(before, "precondition: C1 is occupied")
        XCTAssertNotEqual(before, .provia, "precondition: and holds something else")
        var settings = recipe
        settings.filmSimulation = nil

        let r = await m.slotWriter.push(settings: settings, name: "No Sim", toSlot: 1)

        XCTAssertEqual(r.outcome, .applied)
        XCTAssertEqual(r.filmSimulationReadBack, .provia, "the recipe's absence resolved to PROVIA")
        XCTAssertTrue(r.advisories.contains { $0.contains("no film simulation") }, "advisory: \(r.advisories)")
        XCTAssertTrue(AppLog.reportText(in: .camera).contains("writing PROVIA / Standard"),
                      "the substitution is logged")
    }

    /// An unanswered bank cannot supply the originals required for a recoverable write.
    func testMissingBankReadsDoNotAuthorizeProviaSeeding() async {
        let (manager, transport) = await connect(MockCameraFaults())
        let result = await manager.slotWriter.push(settings: RecipeSettings(), name: "No Sim", toSlot: 5)
        XCTAssertEqual(result.outcome, .notWritten)
        XCTAssertFalse(result.nameWritten)
        let actual = await stored(transport, .filmSimulation, slot: 5)
        XCTAssertNil(actual)
    }

    // MARK: A read that answers OK with nothing

    /// Ground truth for the tests below: what the slot physically holds, taken straight off the
    /// mock's storage rather than through `readProperty` — which is the thing being made to lie.
    private func stored(_ t: MockCameraTransport, _ prop: FujiPTP.PresetProp, slot: Int) async -> FilmSimulation? {
        await t.storedProperty(prop.rawValue, slot: slot)
            .flatMap(FujiEncoding.decodeInt16).flatMap { FujiEncoding.byteToFilmSim[$0] }
    }

    /// End to end, for a body that answers `0x2001 OK` with no data phase for D192 (no recorded body
    /// does; the fault models the case): `readProperty` hands back nil without throwing and the
    /// property is absent from the base read, which looks like an empty slot. Writing PROVIA there
    /// would read back as verified over a Classic Chrome recipe the user never asked to change.
    func testAnUnreportedFilmSimulationIsNotReplacedWithProvia() async {
        AppLog.clear(.camera)
        let (m, t) = await connect(.silentFilmSimulationRead)
        let before = await stored(t, .filmSimulation, slot: 1)
        XCTAssertEqual(before, .classicChrome, "precondition: C1 really holds Classic Chrome")

        var settings = recipe
        settings.filmSimulation = nil
        let r = await m.slotWriter.push(settings: settings, name: "Silent D192", toSlot: 1)

        let after = await stored(t, .filmSimulation, slot: 1)
        XCTAssertEqual(after, .classicChrome, "the slot kept the simulation its own read never mentioned")
        XCTAssertFalse(r.fields.contains { $0.code == FujiPTP.PresetProp.filmSimulation.rawValue },
                       "and the push never claimed to write one")
        // The log must not claim a write that was declined. It did for a day: "writing PROVIA"
        // fired on the recipe alone, while the advisory on the same push said the default wasn't
        // written. One push, two contradictory messages — and this test had been rewritten to
        // assert the false one.
        XCTAssertFalse(AppLog.reportText(in: .camera).contains("writing PROVIA / Standard"),
                       "nothing was written, so nothing may claim it was")
        XCTAssertTrue(r.advisories.contains { $0.contains("Film Simulation") && $0.contains("wasn't written") },
                      "the declined default is what gets said: \(r.advisories)")
        XCTAssertTrue(r.recipeFields.contains { $0.outcome == .written }, "the rest of the recipe still landed")
    }

    /// The same fault on a housekeeping property, which has no recipe field to notice it. The push
    /// must leave it alone and say so — not write the codec's seed value and verify it against
    /// itself.
    func testAnUnreportedHousekeepingPropertyIsOmittedAndReported() async {
        AppLog.clear(.camera)
        var faults = MockCameraFaults()
        faults.emptyReadCodes = [FujiPTP.PresetProp.colorSpace.rawValue,
                                 FujiPTP.PresetProp.imageSize.rawValue]
        let (m, _) = await connect(faults)

        let r = await m.slotWriter.push(settings: recipe, name: "Silent D1A4", toSlot: 1)

        XCTAssertEqual(r.outcome, .applied, "the recipe itself is unaffected")
        for prop in [FujiPTP.PresetProp.colorSpace, .imageSize] {
            XCTAssertFalse(r.fields.contains { $0.code == prop.rawValue },
                           "\(prop.debugName) was written from a read that answered nothing")
        }
        let log = AppLog.reportText(in: .camera)
        XCTAssertTrue(log.contains("read returned nothing for"), "the skip is stated in the log")
        XCTAssertTrue(log.contains("Color Space (D1A4)"), log)
        XCTAssertTrue(m.reports.report?.notes.contains { $0.contains("base read missing") } ?? false,
                      "and in the report a tester shares: \(m.reports.report?.notes ?? [])")
    }

    /// Missing bank reads provide no evidence that the bank is empty or safe to seed.
    func testAnUnreportedBankIsNeverSeededWithDefaults() async {
        let (manager, transport) = await connect(MockCameraFaults())
        let result = await manager.slotWriter.push(settings: recipe, name: "Seeded", toSlot: 6)
        XCTAssertEqual(result.outcome, .notWritten)
        XCTAssertFalse(result.nameWritten)
        let actual = await stored(transport, .filmSimulation, slot: 6)
        XCTAssertNil(actual)
    }

    /// A bank's film simulation can change between sessions after a push verified — an X-T50's C2
    /// went from ASTIA to PRO Neg. Hi (zgrimz/fujifilm-ptp-reference
    /// `docs/04-custom-slots.md#bodies-with-a-film-simulation-dial`) — so a reconnect compares what it
    /// reads with what was written. Both values are already in the report.
    func testAFilmSimulationThatChangedSinceThePushIsDetectedOnReconnect() async {
        AppLog.clear(.camera)
        let (m, _) = await connect(MockCameraFaults())
        var settings = recipe
        settings.filmSimulation = .classicNeg
        let r = await m.slotWriter.push(settings: settings, name: "Drift", toSlot: 1)
        XCTAssertEqual(r.outcome, .applied, "precondition: the push applied")
        XCTAssertTrue(m.slotReader.filmSimulationDrift.isEmpty, "nothing has drifted yet")
        await m.connector.disconnect()

        // The camera comes back with every D192 reading PROVIA — the seam that makes the mock
        // answer a value our own encoder never wrote.
        var faults = MockCameraFaults()
        faults.rawReadValues = [FujiPTP.PresetProp.filmSimulation.rawValue: FujiEncoding.packU16(0x01)]
        faults.isInstant = true
        let m2 = CameraServices()
        await m2.connector.connectDemo(using: MockCameraTransport(faults: faults))

        XCTAssertEqual(m2.slotReader.filmSimulationDrift.map(\.slot), [1], "only the slot with an applied push is compared")
        let drift = m2.slotReader.filmSimulationDrift.first
        XCTAssertEqual(drift?.wrote, .classicNeg)
        XCTAssertEqual(drift?.holds, .provia)
        XCTAssertTrue(drift?.summary.contains("C1 was written as Classic Neg") ?? false, drift?.summary ?? "nil")
        XCTAssertTrue(m2.reports.report!.notes.contains { $0.hasPrefix("drift:") }, "\(m2.reports.report!.notes)")
        XCTAssertTrue(AppLog.reportText(in: .camera).contains("Drift: C1"))
    }

    /// Push, share, Clear Diagnostics, change a slot on the camera, reconnect. Clear has to keep the
    /// baseline report the drift detector compares against, or the detector goes blind.
    func testDriftIsStillDetectedAfterClearDiagnostics() async {
        let (m, _) = await connect(MockCameraFaults())
        var settings = recipe
        settings.filmSimulation = .classicNeg
        _ = await m.slotWriter.push(settings: settings, name: "Kept", toSlot: 1)
        await m.connector.disconnect()

        // What Clear Diagnostics does now.
        CameraReportStore.stripLatestToDriftBaseline()
        let stripped = CameraReportStore.loadLatest()
        XCTAssertNotNil(stripped, "the baseline survives")
        XCTAssertTrue(stripped!.slots.reads.isEmpty, "slot contents do not")
        XCTAssertNil(stripped!.deviceInfo)
        XCTAssertTrue(stripped!.transactions.isEmpty)
        XCTAssertNil(stripped!.pushes?.first?.slotBefore, "nor the recipe bytes")
        XCTAssertNil(stripped!.pushes?.first?.nameApplied, "nor the name")
        XCTAssertEqual(stripped!.pushes?.first?.fields.count, 1, "one field: the film simulation")
        XCTAssertEqual(stripped!.pushes?.first?.baselineOnly, true)
        XCTAssertTrue(stripped!.textRendering.contains("baseline only"), stripped!.textRendering)

        // The camera comes back with C1 changed.
        var faults = MockCameraFaults()
        faults.rawReadValues = [FujiPTP.PresetProp.filmSimulation.rawValue: FujiEncoding.packU16(0x04)]
        faults.isInstant = true
        let m2 = CameraServices()
        await m2.connector.connectDemo(using: MockCameraTransport(faults: faults))

        XCTAssertEqual(m2.slotReader.filmSimulationDrift.map(\.slot), [1], "detected, with the baseline Clear left behind")
        XCTAssertEqual(m2.slotReader.filmSimulationDrift.first?.wrote, .classicNeg)
        XCTAssertEqual(m2.slotReader.filmSimulationDrift.first?.holds, .proNegHi)
    }

    /// The control: a body whose slots still hold what was pushed reports no drift.
    func testNoDriftWhenTheSlotStillHoldsWhatWasPushed() async {
        let (m, transport) = await connect(MockCameraFaults())
        var settings = recipe
        settings.filmSimulation = .classicNeg
        _ = await m.slotWriter.push(settings: settings, name: "Stable", toSlot: 1)
        await m.connector.disconnect()

        let m2 = CameraServices()
        await m2.connector.connectDemo(using: transport)

        XCTAssertTrue(m2.slotReader.filmSimulationDrift.isEmpty)
    }

    /// Pre-flight "this model has no such control" entries used to render under "Refused by the
    /// camera". The camera never saw them. Tested on the result type directly: every writable
    /// model today shares one field set (`fieldsIVLate` *is* `fieldsV`), so no real push can
    /// produce the entry — which is exactly why the accessor has to be right when one does.
    func testUnsupportedOnModelIsNotACameraRefusal() {
        var r = SlotWriteResult(slot: 1, outcome: .partiallyApplied, nameWritten: true, nameApplied: "x",
                                clampedFields: [], fields: [], errorMessage: nil)
        r.fields = [
            FieldResult(code: 0xD1A2, field: "Clarity", isRecipeField: true, outcome: .rejected(code: 0x201C)),
            FieldResult(code: 0, field: "Monochromatic Color", isRecipeField: true, outcome: .rejected(code: nil)),
        ]

        XCTAssertEqual(r.rejected.map(\.field), ["Clarity"], "only what the camera answered")
        XCTAssertEqual(r.unsupportedOnModel.map(\.field), ["Monochromatic Color"], "what never reached it")
    }

    /// …and it still has to be *counted*. An unsupported field is excluded from `rejected` and is
    /// the one thing that can make `outcome(for:)` fall to `.partiallyApplied` on its own, so a
    /// push carrying nothing else wrong announced "0 settings didn't make it" — a sentence that
    /// cannot be true, on a screen whose whole job is saying what the slot holds. Reachable today:
    /// `exposureBias` and `noiseReduction` are in `RecipeField.allCases` and in no model's field
    /// set; the share extension's editor offers the first, and a recipe decoded with both noise
    /// names keeps the second.
    func testEverySettingThatDidNotMakeItIsCounted() {
        var r = SlotWriteResult(slot: 1, outcome: .partiallyApplied, nameWritten: true, nameApplied: "x",
                                clampedFields: [], fields: [], errorMessage: nil)
        r.fields = [
            FieldResult(code: 0xD192, field: "Film Simulation", isRecipeField: true, outcome: .written),
            FieldResult(code: 0, field: "Exposure Bias", isRecipeField: true, outcome: .rejected(code: nil)),
        ]
        XCTAssertTrue(r.plainLanguageState.contains("1 setting didn't make it"),
                      "the field the body hasn't got is one of them: \(r.plainLanguageState)")
        XCTAssertFalse(r.plainLanguageState.contains("0 settings"),
                       "and a mix of old and new always has at least one: \(r.plainLanguageState)")

        // All four kinds at once, with no double counting between `rejected` and `unsupportedOnModel`.
        r.fields += [
            FieldResult(code: 0xD1A2, field: "Clarity", isRecipeField: true, outcome: .rejected(code: 0x201C)),
            FieldResult(code: 0xD190, field: "Dynamic Range", isRecipeField: true, outcome: .notAttempted),
            FieldResult(code: 0xD195, field: "Grain Effect", isRecipeField: true,
                        outcome: .mismatched(wrote: Data([1, 0]), read: Data([6, 0]))),
        ]
        XCTAssertTrue(r.plainLanguageState.contains("4 settings didn't make it"),
                      r.plainLanguageState)
    }

    /// The registry's own claims, asserted rather than trusted: exactly one body is `.hardware`,
    /// and the write allowlist is wider than it.
    func testOnlyTheXT50IsHardwareVerified() {
        let writable = CameraModelRegistry.shared.models
            .filter { $0.allowsWrite && $0.id != CameraModelRegistry.demoModelID }

        XCTAssertEqual(writable.filter { $0.verification == .hardware }.map(\.id), ["X-T50"])
        XCTAssertEqual(writable.filter { $0.verification == .ownerReport }.map(\.id), ["X-M5", "GFX100S"],
                       "two bodies have had a write confirmed by somebody other than us, each on its "
                       + "owner's own write pass through the app — the GFX100S (fw 2.13, 2026-09-15) "
                       + "and the X-M5 (fw 1.30, 2026-10-31): pushed, power-cycled, still there, "
                       + "confirmed against the camera's menu and a photograph, restored. `.hardware` "
                       + "stays with the body that can be re-driven here on demand, which is what "
                       + "makes that level worth more than a report")
        XCTAssertEqual(Set(writable.filter { $0.verification == .community }.map(\.id)),
                       ["X100V", "X100VI", "X-H2", "X-T5", "X-E5", "X-S20", "X-S10", "X-T30 II", "GFX100RF"],
                       "nine rest on somebody else's published or community report "
                       + "(zgrimz/fujifilm-ptp-reference docs/07-cameras.md#summary). None is a write "
                       + "through this app, which is what keeps them below `.ownerReport`")
        XCTAssertEqual(Set(writable.filter { $0.verification == .inferred }.map(\.id)),
                       ["X-T4", "X-E4", "X-H2S", "X-T30 III", "GFX100", "GFX50S II"],
                       "six bodies accept writes with no report of their own. Three are pure "
                       + "architecture inference; the X-T30 III shares the X-T50's processor; "
                       + "the GFX100 and GFX 50S II share the GFX100S's own registry entry — same "
                       + "fields, film list, ranges and processor as the body that came back from a "
                       + "clean end-to-end write pass. `.inferred` is still the honest label for all "
                       + "six: no level exists for a body promoted on a sibling's report, and "
                       + "inventing one would say more than anybody has measured. The X-Pro3 left the "
                       + "list on a published report that every bank operation fails on it")
        XCTAssertTrue(writable.filter { $0.verification != .hardware }
            .allSatisfy { $0.verification.testerNote != nil },
                      "and the Camera Test tells each of their testers what their report adds to")
        XCTAssertEqual(Set(writable.filter { $0.verification.pushCaveat != nil }.map(\.id)),
                       Set(writable.filter { $0.verification == .inferred }.map(\.id)),
                       "the push screen flags exactly the bodies nobody has reported a write to")
    }

    // MARK: (i) A refused D-Range Priority takes three more fields with it

    /// Reads `D190` straight off the transport, bypassing anything the app believes.
    private func cameraDynamicRange(_ transport: MockCameraTransport, slot: Int) async -> Int? {
        try? await transport.writeProperty(FujiPTP.Prop.slotSelector, FujiEncoding.packU16(slot))
        return (try? await transport.readProperty(FujiPTP.PresetProp.dynamicRange.rawValue))
            .flatMap(FujiEncoding.decodeInt16)
    }

    private var priorityRecipe: RecipeSettings {
        var s = recipe                 // already carries DR400 and both tones
        s.dRangePriority = .strong
        return s
    }

    /// The control. The priority lands, so the body really does drive Dynamic Range and both tones,
    /// they are correctly not sent, and the advisory says so.
    func testCaseI_control_aPriorityThatLandsStillWithholdsTheThreeItDrives() async {
        let (m, _) = await connect(MockCameraFaults())
        let r = await m.slotWriter.push(settings: priorityRecipe, name: "Audit I0", toSlot: 1)

        XCTAssertTrue(r.rejected.isEmpty, "nothing was refused")
        for prop in [FujiPTP.PresetProp.dynamicRange, .highlightTone, .shadowTone] {
            XCTAssertNil(r.fields.first { $0.code == prop.rawValue },
                         "\(prop.debugName) is the camera's while the priority is on")
        }
        XCTAssertTrue(r.advisories.contains { $0.contains("Dynamic Range") && $0.contains("won't be written") },
                      "and the advisory is true, so it stays: \(r.advisories)")
    }

    /// `D191` is ISO-gated, and a bank at base ISO refuses every write to it
    /// (zgrimz/fujifilm-ptp-reference `docs/04-custom-slots.md#iso-gating`). When the priority does
    /// not land, the three fields withheld on the strength of it landing have to be sent after all,
    /// and every refusal counted.
    func testCaseI_aRefusedPriorityReleasesTheThreeFieldsItWasWithholding() async {
        var faults = MockCameraFaults()
        faults.invalidValueWriteCodes = [FujiPTP.PresetProp.dRangePriority.rawValue]
        let (m, t) = await connect(faults)
        let r = await m.slotWriter.push(settings: priorityRecipe, name: "Audit I", toSlot: 1)

        XCTAssertEqual(r.rejected.map(\.code), [FujiPTP.PresetProp.dRangePriority.rawValue],
                       "the priority is the one the camera refused")

        // The three are written after all: the bank's own priority is off, so nothing is driving
        // them and they are the recipe's to set.
        for prop in [FujiPTP.PresetProp.dynamicRange, .highlightTone, .shadowTone] {
            XCTAssertEqual(r.fields.first { $0.code == prop.rawValue }?.outcome, .written,
                           "\(prop.debugName) had nothing overriding it after all")
        }
        let heldDR = await cameraDynamicRange(t, slot: 1)
        XCTAssertEqual(heldDR, 400,
                       "and the camera holds the recipe's dynamic range, not the bank's old one")

        // The advisory that said they would not be written is now false, so it goes.
        XCTAssertFalse(r.advisories.contains { $0.contains("won't be written") },
                       "the refusal made those three sentences untrue: \(r.advisories)")
        XCTAssertTrue(r.notes.contains { $0.contains("sent after all") },
                      "and the results screen says why they were sent: \(r.notes)")

        XCTAssertEqual(r.outcome, .partiallyApplied)
        XCTAssertTrue(r.plainLanguageState.contains("1 setting didn't make it"),
                      "one thing failed — the priority — and it is the only one counted: "
                      + r.plainLanguageState)
    }

    /// And when the bank really is holding a priority, the camera refuses those three too. Three
    /// named rows and a count of four beats three fields nobody mentioned.
    func testCaseI_aBankStillHoldingThePriorityRefusesThemAndSaysSo() async {
        var faults = MockCameraFaults()
        faults.invalidValueWriteCodes = [FujiPTP.PresetProp.dRangePriority.rawValue,
                                         FujiPTP.PresetProp.dynamicRange.rawValue,
                                         FujiPTP.PresetProp.highlightTone.rawValue,
                                         FujiPTP.PresetProp.shadowTone.rawValue]
        let (m, _) = await connect(faults)
        let r = await m.slotWriter.push(settings: priorityRecipe, name: "Audit I2", toSlot: 1)

        XCTAssertEqual(Set(r.rejected.map(\.code)),
                       Set([FujiPTP.PresetProp.dRangePriority, .dynamicRange,
                            .highlightTone, .shadowTone].map(\.rawValue)),
                       "every one of them is named rather than silently absent")
        XCTAssertTrue(r.plainLanguageState.contains("4 settings didn't make it"),
                      r.plainLanguageState)
    }

    // MARK: (j) A reconnect whose selector cannot be put back

    /// A selector restore that fails must not crash the reconnect. `SlotReader.refresh()` files the
    /// selector restore into the report as two statements: the restore returns, then
    /// `reports.update` records it. Written as one `update` with the `await` inside it, the
    /// `modify` access opens before the right-hand side is
    /// evaluated and stays open across the `await`, and every failure branch of
    /// `SlotSelector.restore` calls `reports.noteOnce` — a second modify inside the first, which
    /// Swift's exclusivity check answers by aborting the process. A healthy connect never takes a
    /// failure branch, so it only fires on a reconnect to a just-replugged camera.
    ///
    /// A selector that reads back nothing takes the `guard let before` branch. If the bug comes back,
    /// this test doesn't fail — the test process aborts.
    func testCaseJ_aSelectorThatCannotBeRestoredIsANoteNotACrash() async {
        var faults = MockCameraFaults()
        faults.emptyReadCodes = [FujiPTP.Prop.slotSelector]
        let (m, _) = await connect(faults)

        XCTAssertTrue(m.reports.report?.notes.contains {
            $0.contains("could not read the selected bank beforehand")
        } == true, "the failed restore is a note in the report: \(m.reports.report?.notes ?? [])")
        XCTAssertNil(m.reports.report?.slots.selectorRestored,
                     "and the slot read files it as unknown, which is what the branch returns")
    }
    func testMissingOrMalformedTouchedOriginalAbortsBeforeNameOrSettings() async {
        let code = FujiPTP.PresetProp.filmSimulation.rawValue
        for original: Data? in [nil, Data(), Data([11]), Data([11, 0, 0])] {
            let (manager, transport) = await connect(MockCameraFaults())
            let before = await transport.storedProperty(code, slot: 1)
            await transport.queueRead(.value(original), for: code)
            let result = await manager.slotWriter.push(settings: recipe, name: "Must not rename", toSlot: 1)
            XCTAssertEqual(result.outcome, .notWritten)
            XCTAssertFalse(result.nameWritten)
            XCTAssertTrue(result.fields.isEmpty)
            XCTAssertEqual(manager.slotReader.slots.first { $0.index == 1 }?.name, "Sunny 16")
            let after = await transport.storedProperty(code, slot: 1)
            XCTAssertEqual(after, before)
        }
    }

    func testUnreadableOrTruncatedOriginalNameAbortsBeforeSettings() async {
        for original: Data? in [nil, Data(), Data([8, 65, 0])] {
            let (manager, transport) = await connect(MockCameraFaults())
            await transport.queueRead(.value(original), for: FujiPTP.Prop.presetName)
            let result = await manager.slotWriter.push(settings: recipe, name: "Must not rename", toSlot: 1)
            XCTAssertEqual(result.outcome, .notWritten)
            XCTAssertFalse(result.nameWritten)
            XCTAssertTrue(result.fields.isEmpty)
        }
    }

    func testIgnoredNameIsNotReportedAsVerified() async {
        var faults = MockCameraFaults()
        faults.silentlyIgnoredWriteCodes = [FujiPTP.Prop.presetName]
        let (manager, _) = await connect(faults)
        let result = await manager.slotWriter.push(settings: recipe, name: "Ignored name", toSlot: 1)
        XCTAssertEqual(result.outcome, .partiallyApplied)
        XCTAssertTrue(result.nameWritten, "the command was accepted")
        guard case .mismatched = result.nameOutcome else { return XCTFail("name readback must differ") }
        XCTAssertEqual(manager.slotReader.slots.first { $0.index == 1 }?.name, "Sunny 16")
    }

    func testMissingNameReadbackIsUnavailable() async {
        let (manager, transport) = await connect(MockCameraFaults())
        await transport.queueRead(.normal, for: FujiPTP.Prop.presetName)
        await transport.queueRead(.value(nil), for: FujiPTP.Prop.presetName)
        let result = await manager.slotWriter.push(settings: recipe, name: "Verified?", toSlot: 1)
        XCTAssertEqual(result.nameOutcome, .unverified)
        XCTAssertEqual(result.outcome, .unknown)
    }

    func testLostPropertyReplyIsUnknownAndStopsTheRemainingWrites() async {
        var faults = MockCameraFaults()
        let code = FujiPTP.PresetProp.filmSimulation.rawValue
        faults.lostWriteResponseCodes = [code]
        let (manager, transport) = await connect(faults)
        var wanted = recipe; wanted.filmSimulation = .velvia
        let result = await manager.slotWriter.push(settings: wanted, name: "Lost reply", toSlot: 1)
        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertEqual(result.fields.first { $0.code == code }?.outcome, .outcomeUnknown)
        XCTAssertEqual(result.fields.first { $0.code == FujiPTP.PresetProp.grain.rawValue }?.outcome, .notAttempted)
        let actual = await transport.storedProperty(code, slot: 1)
        XCTAssertEqual(actual, FujiEncoding.packU16(FujiEncoding.filmSimToByte[.velvia]!))
    }

    func testLostNameReplyIsUnknownBeforeAnyPresetWrite() async {
        var faults = MockCameraFaults(); faults.lostWriteResponseCodes = [FujiPTP.Prop.presetName]
        let (manager, _) = await connect(faults)
        let result = await manager.slotWriter.push(settings: recipe, name: "Lost name reply", toSlot: 1)
        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertEqual(result.nameOutcome, .outcomeUnknown)
        XCTAssertTrue(result.fields.allSatisfy { $0.outcome == .notAttempted })
    }

    func testMissingAcceptedPropertyReadbackIsUnavailableNotMismatch() async {
        let code = FujiPTP.PresetProp.filmSimulation.rawValue
        let (manager, transport) = await connect(MockCameraFaults())
        await transport.queueRead(.normal, for: code)
        await transport.queueRead(.value(nil), for: code)
        let result = await manager.slotWriter.push(settings: recipe, name: "Missing verification", toSlot: 1)
        XCTAssertEqual(result.fields.first { $0.code == code }?.outcome, .unverified)
        XCTAssertEqual(result.outcome, .unknown)
    }

    func testMalformedGrainReadbackCannotVerifyAnOffWrite() {
        let code = FujiPTP.PresetProp.grain.rawValue
        XCTAssertFalse(SlotWriteVerification.readBackMatches(code, wrote: FujiEncoding.packU16(1), read: Data([6, 0, 0])))
        XCTAssertTrue(SlotWriteVerification.readBackMatches(code, wrote: FujiEncoding.packU16(1), read: FujiEncoding.packU16(6)))
    }

    func testBatchStopsBeforeTheNextBankAfterAnUnconfirmedNameOrPropertyWrite() async {
        for code in [FujiPTP.Prop.presetName, FujiPTP.PresetProp.filmSimulation.rawValue] {
            var faults = MockCameraFaults()
            faults.lostWriteResponseCodes = [code]
            let (manager, transport) = await connect(faults)
            let before = await transport.storedProperty(FujiPTP.PresetProp.filmSimulation.rawValue, slot: 2)
            let results = await manager.slotWriter.pushBatch([
                (settings: recipe, name: "Unconfirmed", slot: 1),
                (settings: recipe, name: "Must not start", slot: 2)
            ])
            let after = await transport.storedProperty(FujiPTP.PresetProp.filmSimulation.rawValue, slot: 2)
            let selected = await transport.currentSlot
            XCTAssertEqual(results.count, 2, "every requested bank has an explicit result")
            XCTAssertEqual(results[0].outcome, .unknown)
            XCTAssertEqual(results[1].outcome, .notWritten)
            XCTAssertFalse(results[1].nameWritten)
            XCTAssertTrue(results[1].fields.isEmpty)
            XCTAssertTrue(results[1].errorMessage?.contains("not started") == true)
            XCTAssertEqual(after, before)
            XCTAssertEqual(selected, 1, "no selector write for the second bank may follow an unconfirmed send")
            XCTAssertEqual(manager.slotWriter.lastWriteResults.count, 2)
        }
    }

}

// MARK: - Supplementary probes for invariants 7 and 9

@MainActor
final class PushAuditProbes: XCTestCase {

    /// (b/c) follow-up, invariant 7: the pre-push warning says the body will keep its current film
    /// simulation, so the write must not carry one. On an X-T30 II (no REALA ACE) the clamped recipe
    /// has no film simulation and the codec passes the slot's own D192 through.
    func testAnUnsupportedFilmSimulationIsWarnedAboutAndNotWritten() {
        let xT30II = CameraModelRegistry.shared.model(withID: "X-T30 II")!
        var wanted = RecipeSettings(filmSimulation: .realaAce, dynamicRange: .dr400)
        wanted.clarity = 1

        let issues = RecipeCompatibility.analyze(wanted, for: xT30II)
        XCTAssertTrue(issues.contains { $0.kind == .filmSimulationUnsupported && $0.field == .filmSimulation })

        // The push keeps the unsupported sim and lets the codec recognise it; dropping it here
        // would leave the encoder unable to tell "the body can't do this" from "the recipe said
        // nothing", and those now have opposite answers.
        let clamped = RecipeCompatibility.clamped(wanted, to: xT30II,
                                                  droppingUnsupportedFilmSimulation: false)
        XCTAssertEqual(clamped.filmSimulation, .realaAce, "kept, for the codec to rule on")

        let base: FujiPresetCodec.Props = [FujiPTP.PresetProp.filmSimulation.rawValue: FujiEncoding.packU16(11)]
        let encoded = FujiPresetCodec.encode(clamped, model: xT30II, slot: .holds(base))
        let sim = encoded.first { $0.code == FujiPTP.PresetProp.filmSimulation.rawValue }
        XCTAssertEqual(sim?.bytes, FujiEncoding.packU16(11), "the slot keeps its current film simulation")
    }

}

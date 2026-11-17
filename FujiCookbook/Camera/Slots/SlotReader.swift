import Foundation
import Observation

/// Reads the camera's custom slots (C1…) and holds what it found, for import, push previews and
/// backups. Reading moves the slot selector; a walk that finishes puts it back, and one that fails
/// does not. Bodies the registry blocks, bodies nobody recognizes, and bodies whose selector doesn't
/// answer a bank number get the read-only sweep instead.
@MainActor
@Observable
final class SlotReader {

    /// How this session's slot walk ended, which decides the slot count the app can stand behind.
    enum Walk: Equatable {
        /// Nothing read yet this session, or a read-only sweep that did not complete.
        case notWalked
        /// The walk ran to its end: `slotCount` slots accepted a select.
        case finished(slotCount: Int)
        /// The walk stopped on an error, so how many slots the body has is unknown.
        case failed
        /// The body took the read-only sweep instead, and it completed. There are no slots to count.
        case sweptReadOnly
    }

    /// Whether this session has read what the body offers: a walk that finished, or a sweep. A
    /// walk that failed has not.
    var hasRead: Bool {
        switch walk {
        case .finished, .sweptReadOnly: return true
        case .notWalked, .failed: return false
        }
    }

    private(set) var slots: [CameraSlot] = []
    private(set) var walk: Walk = .notWalked
    /// Slots that accepted a select during the last walk. Nil until a walk finishes, and after one
    /// that failed.
    var probedSlotCount: Int? {
        guard case .finished(let slotCount) = walk else { return nil }
        return slotCount
    }
    /// Where the last push-capable body is remembered (`RememberedCamera`). Swappable so a test's
    /// connect doesn't overwrite the app's own.
    @ObservationIgnored var rememberedCameraDefaults: UserDefaults = .standard
    /// Slots whose film simulation changed since the last push that applied to them, found on
    /// connect by comparing the carried-forward push history against the fresh slot read. Empty on
    /// a body that was never written to.
    private(set) var filmSimulationDrift: [FilmSimulationDrift] = []

    private let session: CameraSession
    private let reports: CompatibilityReportRecorder
    private let gate: CameraOperationGate

    init(session: CameraSession, reports: CompatibilityReportRecorder, gate: CameraOperationGate) {
        self.session = session
        self.reports = reports
        self.gate = gate
    }

    /// The slot count the UI should offer: what the walk found, else what the registry assumes
    /// until a walk has run on a body the app selects slots on, else none. A five-slot body is not
    /// offered a C6 and C7 it will refuse, and an X-T20 is not offered the seven the registry assumes
    /// for bodies that have any. This reads zero rather than `probedSlotCount` deliberately: nothing
    /// was probed, and the report's "probed —" line depends on `nil` and `0` staying different things.
    ///
    /// None after a walk that failed, either: the count is unknown, and the registry's assumption
    /// would offer an X-M5, whose mode dial has four banks, seven.
    var effectiveSlotCount: Int {
        switch walk {
        case .finished(let slotCount): return slotCount
        case .failed, .sweptReadOnly: return 0
        case .notWalked: return session.maySelectSlots ? session.model?.slotCount ?? 0 : 0
        }
    }

    /// A backup of every slot the app has read, ready to export. Nil until a read has happened.
    ///
    /// Pure — no camera traffic. `refresh()` already did all of it, and `rawProperties` on each
    /// slot is the same hex the compatibility report carries; this is a second consumer of one read,
    /// not a second read.
    ///
    /// The serial hash comes with the report's scheme beside it, `SerialHash.keyedScheme` when it
    /// is keyed, so an export can tell it from an unkeyed one (`CameraBackup.forSharing`).
    var slotBackup: CameraBackup? {
        guard let connected = session.connected, !slots.isEmpty else { return nil }
        let reported = reports.report?.camera
        return CameraBackup.capture(slots: slots,
                                    productName: connected.productName,
                                    modelID: connected.registryModel?.id,
                                    firmwareVersion: connected.firmwareVersion,
                                    serialHash: reported?.serialHash,
                                    serialHashScheme: reported?.serialHashScheme)
    }

    /// Pull-to-refresh, the read that follows a connect, and any other re-read. Refused while
    /// something else is talking to the camera — `connect` sets `status = .connected` before it
    /// awaits its own slot read, so the Camera tab is pullable while that read is still walking the
    /// slots, and the gate is what keeps a second walk, a push or a probe out of it.
    /// Nil when no transport is attached, and throws `CameraBusy` when the gate was held; either
    /// way nothing was read.
    @discardableResult
    func requestRefresh() async throws(CameraBusy) -> WalkResult? {
        try await gate.run("refresh slots") {
            guard self.session.transport != nil else { return nil }
            return await self.refresh()
        }
    }

    @discardableResult
    func refresh() async -> WalkResult {
        guard let transport = session.transport else { return WalkResult() }
        // Two bodies take the read-only sweep before anything is read: one nobody recognizes, which
        // has no model to decode a bank with, and one the registry blocks on a recorded failure,
        // such as the X-T20. A `0xD18C` write to the second is refused, and the refusal would read
        // as a failure for a fact the registry already holds.
        guard let connected = session.connected, let model = connected.model,
              Self.walkIsAllowed(for: connected) else {
            return await sweepReadOnly(transport, model: session.model)
        }
        // Belt and braces for the loop below: `1...0` is a runtime trap, not an empty range, so a
        // future registry entry with no slots must not depend on the branch above to stay safe.
        guard model.slotCount > 0 else {
            return await sweepReadOnly(transport, model: model)
        }
        var result: [CameraSlot] = []
        var reads: [CameraCompatibilityReport.SlotRead] = []
        var probed = 0
        var diverged = 0
        var selectIgnoredAt: Int?
        let selector = SlotSelector(transport: transport, reports: reports)
        let selectorRead = await selector.read()
        let selectorBefore = selectorRead.value
        var evidence = WalkResult(selector: selectorRead)
        reports.update { $0.slots.selectorBeforeRead = selectorBefore }
        // The one read that shows the bank block is there. A body the registry doesn't vouch for is
        // walked on that answer alone: a bank number says the block answers, `0x200A` says it isn't
        // there in this context, and a failure says nothing about it, so the last two take the
        // sweep, which writes nothing.
        if !Self.walksWhateverTheSelectorAnswers(connected), selectorRead.value == nil {
            let swept = await sweepReadOnly(transport, model: model)
            evidence.walk = swept.walk
            return evidence
        }
        do {
            for index in 1...model.slotCount {
                session.setStatus(.working("Reading slot C\(index)…"))
                do {
                    try await transport.writeProperty(FujiPTP.Prop.slotSelector, FujiEncoding.packU16(index))
                } catch CameraError.disconnectedDuringOperation {
                    throw CameraError.disconnectedDuringOperation
                } catch {
                    // C1 refusing a select is a dead session, a body without the slot protocol, or a
                    // body too busy to take commands — fatal, and the error carries the camera's
                    // answer so the message can say which. A later slot refusing is a body with
                    // fewer slots than the registry assumed: keep what was read, record where it
                    // stopped, and stay connected.
                    guard index > 1 else { throw CameraError.slotSelectFailed(index, after: error) }
                    let detail = error.cameraLogDescription
                    reads.append(CameraCompatibilityReport.SlotRead(slot: index, selected: false, selectError: detail))
                    // Three different facts. A refusal exactly where Fujifilm's manual says the banks
                    // end is the registry's prediction coming true — it goes in the report as
                    // confirmation, at info level, so an X-M5 owner's every report does not open
                    // with a line that looks like a fault. A refusal short of the documented count
                    // is a real finding. And a body with no documented count gets the plain note.
                    let found = index - 1
                    if let documented = model.documentedSlotCount, found == documented {
                        reports.noteOnce("C\(index): slot select refused (\(detail)) — expected: Fujifilm's manual gives this body \(documented) banks, and the walk confirmed it")
                        CameraLog.info("Slots: C\(index) select refused as documented; this body has \(found) slots")
                    } else if let documented = model.documentedSlotCount {
                        reports.noteOnce("C\(index): slot select refused (\(detail)) — this body answered \(found) slots, but Fujifilm's manual says \(documented). Fewer than documented is a finding")
                        CameraLog.error("Slots: C\(index) select refused (\(detail)); \(found) slots where the manual says \(documented)")
                    } else {
                        reports.noteOnce("C\(index): slot select refused (\(detail)) — this body has \(found) slots")
                        CameraLog.error("Slots: C\(index) select refused (\(detail)); treating this body as having \(found) slots")
                    }
                    break
                }
                // Same verification the push does, for the same reason: a select that is answered OK
                // and ignored would give N identical reads filed under N different slots, and that
                // fiction feeds the Import screen, the push screen's "Currently:" warnings and this
                // report's slot section. Stop rather than record something untrue.
                let selected = await selector.read().value
                guard selected == index else {
                    let detail = "asked for C\(index), camera reports \(selected.map { "C\($0)" } ?? "nothing")"
                    reads.append(CameraCompatibilityReport.SlotRead(slot: index, selected: false, selectError: detail))
                    reports.noteOnce("C\(index): slot select answered OK but did not take (\(detail)) — the read stopped here rather than attribute another slot's values to it")
                    CameraLog.error("Slots: C\(index) select answered OK but did not take (\(detail)); stopping the read")
                    selectIgnoredAt = index
                    break
                }
                probed = index
                var read = CameraCompatibilityReport.SlotRead(slot: index, selected: true)
                var name: String?
                do {
                    name = try await transport.readProperty(FujiPTP.Prop.presetName).flatMap(FujiEncoding.parsePTPString)
                } catch CameraError.disconnectedDuringOperation {
                    throw CameraError.disconnectedDuringOperation
                } catch {
                    read.properties.append(CameraCompatibilityReport.propertyRead(code: FujiPTP.Prop.presetName, value: nil, error: error))
                }
                read.name = name
                let props = try await readPresetProps(transport)
                read.properties += props.records
                let occupied = props.values[FujiPTP.PresetProp.filmSimulation.rawValue] != nil
                read.occupied = occupied
                if occupied {
                    let decoded = FujiPresetCodec.decode(props.values, name: name, model: model)
                    // One line per divergence, at error level so it stands out in a report skimmed
                    // for a reason. These reach `current.log` and therefore the shared `.txt`, the
                    // only channel for a body the project has no hardware for.
                    for divergence in decoded.divergences {
                        if case .cameraOnly = divergence.kind {
                            // A setting the app knows and a recipe can't carry (Custom white
                            // balance). Worth its line in the report; not an error, nothing was
                            // misread.
                            CameraLog.info("Slots: C\(index) \(divergence.summary) — \(divergence.consequence)")
                        } else {
                            CameraLog.error("Slots: C\(index) \(divergence.summary) — \(divergence.consequence)")
                        }
                    }
                    read.divergences = decoded.divergences.isEmpty ? nil
                        : decoded.divergences.map(CameraCompatibilityReport.divergenceRecord)
                    diverged += decoded.divergences.filter { divergence in
                        if case .cameraOnly = divergence.kind { return false }
                        return true
                    }.count
                    result.append(CameraSlot(index: index, label: "C\(index)", name: decoded.name,
                                             isOccupied: true, settings: decoded.settings,
                                             rawProperties: decoded.rawProperties,
                                             unsupportedFields: decoded.unsupportedFields,
                                             cameraOnlyFields: decoded.cameraOnlyFields))
                } else {
                    result.append(CameraSlot(index: index, label: "C\(index)", name: nil,
                                             isOccupied: false, settings: nil,
                                             rawProperties: props.values, unsupportedFields: [:]))
                }
                reads.append(read)
            }
            slots = result
            walk = .finished(slotCount: probed)
            evidence.walk = selectIgnoredAt.map { .stopped(selectIgnoredAt: $0) }
                ?? .finished(banks: probed, allRead: Self.everySelectedBankRead(reads))
            reports.update { $0.slots.probedSlotCount = probed }
            rememberCameraIfWritable()
            if let documented = model.documentedSlotCount, probed > documented {
                reports.noteOnce("This body accepted \(probed) slot selects, but Fujifilm's manual gives it \(documented) banks — the USB protocol exposes more than the menu does. First evidence of that on any body; worth a registry entry")
                CameraLog.error("Slots: \(probed) selectable where the manual documents \(documented) — USB exposes banks the menu does not")
            }
            // The walk has left the selector on the last bank it selected. Put it back where the
            // walk found it.
            //
            // Two statements, and they must stay two: the restore returns, then its result goes
            // into the report. Written as one modify of the report with the `await` inside it, the
            // `modify` access opens first and stays open across the await; every failure branch of
            // `SlotSelector.restore` then notes into the report, a second modify inside the first, and
            // Swift's exclusivity check aborts the process. Only a selector that will not read or go
            // back takes a failure branch, which a just-replugged GFX100S does.
            // `PushAuditTests.testCaseJ_…` aborts the test run if it regresses.
            let restored = await selector.restore(to: selectorBefore, after: "slot read")
            evidence.selectorRestored = restored
            reports.update { $0.slots.selectorRestored = restored }
            reports.update { $0.slots.reads = reads }
            reports.update { $0.slots.readAt = CameraCompatibilityReport.timestamp() }
            reports.update { $0.touch() }
            reports.persist()
            if let codes = reports.report?.unsupportedPropertyCodes, !codes.isEmpty {
                CameraLog.info("Slots: \(probed) read; properties answering 0x200A: \(codes.joined(separator: " "))")
            }
            // A note as well as the per-slot lines: `textRendering` prints notes near the top, so
            // the headline is visible without reading down to the slot blocks to find it.
            if diverged > 0 {
                reports.noteOnce("\(diverged) value(s) across \(result.filter { !$0.unsupportedFields.isEmpty }.count) slot(s) did not match this app's encodings — see the ! lines per slot")
                reports.update { $0.touch() }
                reports.persist()
            }
            session.setStatus(.connected)
        } catch {
            // The selector stays where the walk left it. A refused C1 select never moved it, a
            // disconnect leaves nothing to write it back to, and after a timeout the camera isn't
            // answering, so a restore would wait out two more transaction timeouts and then fail.
            // On the bodies measured the selector is a host-side cursor that changes nothing on the
            // body (zgrimz/fujifilm-ptp-reference `docs/04-custom-slots.md`).
            walk = .failed
            evidence.walk = .failed(error.cameraLogDescription)
            reports.update { $0.slots.reads = reads }
            reports.update { $0.slots.readAt = CameraCompatibilityReport.timestamp() }
            reports.noteOnce("slot read aborted: \(error.cameraLogDescription)")
            reports.persist()
            session.setStatus(.failed((error as? CameraError)?.errorDescription ?? error.localizedDescription))
        }
        return evidence
    }

    /// Remember this body for the Chapter screen when it is one the app writes to and the walk
    /// counted its slots. Runs at the end of every walk, and again from the connector once the
    /// connect has decided write access, which for a body the registry doesn't vouch for happens
    /// after the walk.
    func rememberCameraIfWritable() {
        guard case .finished(let count) = walk, let model = session.model,
              session.connected?.isWritable == true, session.connected?.isDemo == false else { return }
        RememberedCamera(displayName: model.displayName, slotCount: count)?.save(to: rememberedCameraDefaults)
    }

    /// Whether the walk may select slots on this body at all: not on a `.blocked` entry, whose
    /// recorded failure the registry already holds, and not without a model to decode a bank with.
    private static func walkIsAllowed(for connected: ConnectedCamera) -> Bool {
        guard let model = connected.model else { return false }
        if case .blocked = model.writeSupport { return false }
        return true
    }

    /// A trusted `.readWrite` entry walks on the registry's word, whatever the selector read
    /// answered: a just-replugged GFX100S has answered neither that read nor its restore and still
    /// taken every select. Every other body — an `.untested` entry, a heuristic match — walks only
    /// when the selector answered a bank number (`SelectorRead`); `0x200A` is the record's "not
    /// supported in this context" (zgrimz/fujifilm-ptp-reference `docs/01-transport.md#response-codes`).
    private static func walksWhateverTheSelectorAnswers(_ connected: ConnectedCamera) -> Bool {
        guard connected.identification.isTrusted, let model = connected.model else { return false }
        return model.allowsWrite
    }

    /// Whether every bank that accepted a select answered every property read, `0x200A` aside: that
    /// code says the property is absent on the body, not that the read failed.
    private static func everySelectedBankRead(_ reads: [CameraCompatibilityReport.SlotRead]) -> Bool {
        let absent = PTPHex.code(FujiPTP.responseDevicePropNotSupported)
        return reads.filter(\.selected).allSatisfy { read in
            read.properties.allSatisfy { $0.error == nil || $0.responseCode == absent }
        }
    }


    /// Compare each slot's film simulation against the last push that applied to it.
    ///
    /// Only runs at connect, only for slots with an applied push in the carried-forward history —
    /// a push in *this* session ends with a refresh that matches by construction. Comparison is on
    /// the raw D192 bytes; decoding is for the message. A changed slot is logged, noted in the
    /// report, and surfaced on the Camera tab, so the next time this happens it is a timestamped
    /// event rather than something reconstructed from two reports.
    func detectFilmSimulationDrift() {
        let code = FujiPTP.PresetProp.filmSimulation.rawValue
        var found: [FilmSimulationDrift] = []
        for slot in slots where slot.isOccupied {
            guard let push = reports.report?.pushes?.last(where: { $0.slot == slot.index && $0.outcome == .applied }),
                  let wroteHex = push.fields.first(where: { $0.code == PTPHex.code(code) })?.wrote,
                  let now = slot.rawProperties[code] else { continue }
            let nowHex = PTPHex.bytes(now)
            guard wroteHex != nowHex else { continue }
            func sim(_ hex: String) -> FilmSimulation? {
                guard hex.count == 4, let lo = UInt8(hex.prefix(2), radix: 16) else { return nil }
                return FujiEncoding.byteToFilmSim[Int(lo)]
            }
            let drift = FilmSimulationDrift(slot: slot.index, wrote: sim(wroteHex), holds: sim(nowHex), pushedAt: push.at)
            found.append(drift)
            CameraLog.error("Drift: \(drift.summary) — Fuji Cookbook did not write this; most likely the film simulation was changed on the camera while it was on this bank and not saved, which the USB block reflects")
            reports.note("drift: \(drift.summary) (wrote \(wroteHex), holds \(nowHex))")
        }
        filmSimulationDrift = found
        if !found.isEmpty { reports.update { $0.touch() } }
    }

    func portableRecipe(for slot: CameraSlot) -> PortableRecipe? {
        guard slot.isOccupied, let settings = slot.settings else { return nil }
        let onCameraName = slot.resolvedName
        let name = onCameraName ?? "\(session.model?.displayName ?? "Camera") \(slot.label)"
        // Seed the recipe's camera-slot name from what's actually on the camera (already slot-valid).
        return PortableRecipe(name: name, cameraName: onCameraName,
                              authoredForModel: session.connected?.registryModel?.id,
                              notes: nil, tags: nil, settings: settings,
                              unsupportedFields: slot.unsupportedFields.isEmpty ? nil : slot.unsupportedFields)
    }

    func clearSlots() {
        slots = []
    }

    func discardProbedSlotCount() {
        walk = .notWalked
    }

    func reset() {
        slots = []
        walk = .notWalked
        filmSimulationDrift = []
    }

    // MARK: - Reads

    /// Every preset property of the selected slot, one read each, with a failure recorded per
    /// property rather than aborting the slot: a body that lacks 0xD1A2 still yields the others,
    /// and the slots after it are still read. Only a dead session — disconnect or
    /// timeout — stops the loop.
    private func readPresetProps(_ transport: CameraTransport) async throws
        -> (values: [UInt16: Data], records: [CameraCompatibilityReport.PropertyRead]) {
        var values: [UInt16: Data] = [:]
        var records: [CameraCompatibilityReport.PropertyRead] = []
        for p in FujiPTP.PresetProp.allCases {
            do {
                let d = try await transport.readProperty(p.rawValue)
                if let d { values[p.rawValue] = d }
                records.append(CameraCompatibilityReport.propertyRead(code: p.rawValue, value: d, error: nil))
            } catch CameraError.disconnectedDuringOperation {
                throw CameraError.disconnectedDuringOperation
            } catch CameraError.timeout {
                throw CameraError.timeout
            } catch {
                if case CameraError.ptpError(let code) = error, code == FujiPTP.responseDevicePropNotSupported {
                    reports.update { $0.noteUnsupported(code: p.rawValue) }
                }
                records.append(CameraCompatibilityReport.propertyRead(code: p.rawValue, value: nil, error: error))
            }
        }
        return (values, records)
    }

    private func sweepReadOnly(_ transport: CameraTransport, model: CameraModel?) async -> WalkResult {
        let sweep = ReadOnlyPropertySweep(transport: transport, session: session, reports: reports)
        guard await sweep.run(model: model) else { return WalkResult() }
        slots = []
        walk = .sweptReadOnly
        return WalkResult(walk: .sweptReadOnly)
    }
}

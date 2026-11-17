import Foundation
import Observation

/// Writes recipes and backups into the camera's custom slots.
///
/// Every write runs one sequence: select the slot and confirm it took, read what the slot holds,
/// write the name, write each property, then read the slot back and compare. Only bodies the app
/// is allowed to write to get any of it. A write doesn't put the slot selector back afterwards
/// (`SlotSelector`).
@MainActor
@Observable
final class SlotWriter {

    private(set) var lastWriteResults: [SlotWriteResult] = []
    /// Live progress through a `pushBatch`; nil when no batch is in flight.
    private(set) var pushProgress: BatchProgress?
    /// The destination slot's bytes as `performSlotWrite` read them, before it wrote anything.
    ///
    /// Held here rather than returned because `performSlotWrite` returns from several places and
    /// only some of them get this far; the push and restore wrappers clear it before each write and
    /// fold it into the report afterwards. It is the one slot a write can damage, captured from the
    /// read the write already makes to build its patch.
    private var prePushSlotBytes: [UInt16: Data]?
    /// The name the slot had before the push, read in the same breath as `prePushSlotBytes`.
    private var prePushSlotName: String?
    /// The write path's verdict on whether the slot held anything, so the undo uses the same answer
    /// rather than re-deriving one from the bytes. The property path can't tell an empty slot from
    /// an occupied one, so this is `false` when the film simulation was read and nil otherwise.
    private var prePushSlotWasEmpty: Bool?
    /// What the camera said the selector held after the push selected it. Recorded alongside the
    /// push so a report proves which slot was addressed rather than asserting it.
    private var selectorReadBack: Int?

    private let session: CameraSession
    private let reports: CompatibilityReportRecorder
    private let gate: CameraOperationGate
    private let slotReader: SlotReader

    init(session: CameraSession, reports: CompatibilityReportRecorder, gate: CameraOperationGate,
         slotReader: SlotReader) {
        self.session = session
        self.reports = reports
        self.gate = gate
        self.slotReader = slotReader
    }

    /// Whether a push or a restore may be offered: the body takes writes (`CameraSession.canPush`)
    /// and this session's slot walk didn't fail. After a failed walk the slot count is unknown, so
    /// there is no honest set of slots to offer. The one gate every push entry point uses, so no two
    /// screens disagree about whether a push can happen.
    var canPush: Bool { session.canPush && slotReader.walk != .failed }

    /// Why `canPush` is false, in one sentence, when there is a reason to give.
    var pushBlockReason: String? {
        guard session.canPush else { return session.pushBlockReason }
        guard slotReader.walk == .failed else { return nil }
        return "The camera's slots couldn't be read, so Fuji Cookbook doesn't know which ones it has. Pull down on the Camera tab to read them again, or reconnect."
    }

    func reset() {
        lastWriteResults = []
        pushProgress = nil
        prePushSlotBytes = nil
        prePushSlotName = nil
        prePushSlotWasEmpty = nil
        selectorReadBack = nil
    }

    /// Writes a recipe to one slot under the operation gate and records the push in the report.
    ///
    /// `progress` is an optional prefix like "(2 of 5) " so a batch push can report position in the
    /// live status messages. The report entry is made once, in `pushExclusively`, however
    /// `performPush` returns; the early returns are the paths most worth recording.
    @discardableResult
    func push(settings: RecipeSettings, name: String, toSlot slot: Int,
              progress: String = "") async -> SlotWriteResult {
        do throws(CameraBusy) {
            return try await gate.run("push to C\(slot)") {
                await self.pushExclusively(settings: settings, name: name, toSlot: slot, progress: progress)
            }
        } catch {
            return .refused(slot: slot, by: error)
        }
    }

    /// `push` minus the gate, so `pushBatch` can hold it across the whole batch rather than
    /// re-taking it per slot — a batch is one operation from the camera's point of view.
    @discardableResult
    private func pushExclusively(settings: RecipeSettings, name: String, toSlot slot: Int,
                                 progress: String = "") async -> SlotWriteResult {
        prePushSlotBytes = nil
        prePushSlotName = nil
        prePushSlotWasEmpty = nil
        selectorReadBack = nil
        // Stamped before, not after: `performSlotWrite` ends by re-reading every slot, so a timestamp
        // taken on the way out would sit later than `slots.readAt` and invert the one ordering the
        // two fields exist to establish.
        let startedAt = CameraCompatibilityReport.timestamp()
        let sessionEpoch = session.epoch.current
        reports.isTracing = true
        let result = await performPush(settings: settings, name: name, toSlot: slot, startedAt: startedAt,
                                       progress: progress)
        // The session is over: the cable came out, or a reconnect replaced it. The entry
        // `performSlotWrite` appended before the first write is this push's record, and nothing is
        // added to a report once its session has ended.
        guard session.operationIsCurrent(sessionEpoch) else { return result }
        reports.isTracing = false
        log(push: result)
        reports.update { $0.record(push: result, at: startedAt, modelID: session.connected?.registryModel?.id,
                                   firmwareVersion: session.connected?.firmwareVersion,
                                   slotBefore: prePushSlotBytes, nameBefore: prePushSlotName,
                                   slotWasEmpty: prePushSlotWasEmpty,
                                   selectorReadBack: selectorReadBack) }
        reports.persist()
        return result
    }

    /// Put one slot back the way a backup says it was.
    ///
    /// One slot per call. A restore runs the same sequence as a push (select, name-first write,
    /// property writes, read-back), so it carries the same risk, and it is usually wanted after
    /// something has already gone wrong; restoring every slot at once multiplies that exposure. A
    /// push touches one slot, so one slot is what a restore needs to repair.
    ///
    /// The values are the camera's own, so they are in range except where the read set and the
    /// write set diverge. `FujiPresetCodec.encodeRestore` reports those through `RestoreFidelity`,
    /// which `RestoreView` shows before the user confirms.
    @discardableResult
    func restore(_ saved: [UInt16: Data], name: String, toSlot slot: Int) async -> SlotWriteResult {
        do throws(CameraBusy) {
            return try await gate.run("restore C\(slot)") {
                await self.restoreExclusively(saved, name: name, toSlot: slot)
            }
        } catch {
            return .refused(slot: slot, by: error)
        }
    }

    private func restoreExclusively(_ saved: [UInt16: Data], name: String,
                                    toSlot slot: Int) async -> SlotWriteResult {
        do {
            let maximum = session.canPush ? slotReader.effectiveSlotCount : CameraBackupValidation.slotRange.upperBound
            try CameraBackupValidation.restore(saved, slot: slot, maximum: maximum)
        } catch {
            return SlotWriteResult(slot: slot, outcome: .notWritten, nameWritten: false, nameApplied: nil,
                                   clampedFields: [], fields: [], errorMessage: error.localizedDescription)
        }
        prePushSlotBytes = nil
        prePushSlotName = nil
        prePushSlotWasEmpty = nil
        selectorReadBack = nil
        let startedAt = CameraCompatibilityReport.timestamp()
        let sessionEpoch = session.epoch.current
        reports.isTracing = true
        var result: SlotWriteResult
        switch writableTarget() {
        case .blocked(let reason):
            result = SlotWriteResult(slot: slot, outcome: .notWritten, nameWritten: false, nameApplied: nil,
                                     clampedFields: [], fields: [], errorMessage: reason)
        case .ready(let target):
            result = await performSlotWrite(on: target, toSlot: slot, name: name, progress: "",
                                            kind: .restore, preflight: Preflight(),
                                            startedAt: startedAt) { base, _, model in
                // `base` is the slot as it is right now, read by `performSlotWrite` before anything is
                // written. `encodeRestore` uses it to skip an unchanged D-Range Priority or an
                // unchanged Color value that the restored monochrome simulation would refuse, and to
                // put back first the saved values the slot exposes now but the backup hides.
                let (writes, fidelity) = FujiPresetCodec.encodeRestore(from: saved, model: model, current: base)
                if !fidelity.isPerfect {
                    // Said here as well as on the confirmation screen, because the report is what gets
                    // read months later by someone asking why a restored slot didn't match byte for byte.
                    let reEncoded = fidelity.reEncoded.joined(separator: ", ")
                    CameraLog.info("Restore: C\(slot) re-encoded \(reEncoded.isEmpty ? "nothing" : reEncoded)"
                                   + (fidelity.notWritable.isEmpty ? "" : "; could not write \(fidelity.notWritable.joined(separator: ", "))"))
                }
                if !fidelity.restoredWhileActive.isEmpty {
                    CameraLog.info("Restore: C\(slot) writes \(fidelity.restoredWhileActive.joined(separator: ", ")) first, while the slot's current state still accepts them, then the setting that hides them")
                }
                // No late advisories: a restore replays the bytes a backup holds, so there is no
                // default for the codec to decline and nothing that only the slot's read could reveal.
                return (writes, [])
            }
        }
        guard session.operationIsCurrent(sessionEpoch) else { return result }   // its provisional entry stands
        reports.isTracing = false
        // A restore that put back exactly what was there is not a mismatch to chase later, so the
        // note says which write this was. Without it a reader of `pushes[]` sees two writes to the
        // same slot and no way to tell the accident from the repair.
        result.notes.append("This was a restore of C\(slot) from a saved copy, not a new recipe.")
        log(push: result)
        reports.update { $0.record(push: result, at: startedAt, modelID: session.connected?.registryModel?.id,
                                   firmwareVersion: session.connected?.firmwareVersion,
                                   slotBefore: prePushSlotBytes, nameBefore: prePushSlotName,
                                   slotWasEmpty: prePushSlotWasEmpty,
                                   selectorReadBack: selectorReadBack,
                                   kind: Kind.restore.rawValue) }
        reports.persist()
        return result
    }

    /// One line per push, whatever happened.
    ///
    /// `pushes[]` carries the detail; this is so the half of the report a human actually skims says
    /// a push occurred, to which slot, and how it ended — rather than showing a session where the
    /// camera was connected and then nothing happened.
    private func log(push result: SlotWriteResult) {
        let model = session.connected?.model?.id ?? "camera"
        let firmware = session.connected?.firmwareVersion.map { " fw \($0)" } ?? ""
        var line = "Push: \(model)\(firmware) C\(result.slot) — \(Self.outcomeWord(result.outcome))"
        let written = result.fields.filter { $0.outcome == .written }.count
        line += ", \(written) of \(result.fields.count) properties written"
        if !result.rejected.isEmpty { line += ", \(result.rejected.count) refused" }
        if !result.mismatches.isEmpty { line += ", \(result.mismatches.count) read back different" }
        if !result.notAttempted.isEmpty { line += ", \(result.notAttempted.count) never attempted" }
        if let error = result.errorMessage { line += " — \(error)" }
        if case .applied = result.outcome { CameraLog.info(line) } else { CameraLog.error(line) }
    }

    private static func outcomeWord(_ outcome: SlotOutcome) -> String {
        switch outcome {
        case .applied: return "applied"
        case .partiallyApplied: return "partly applied"
        case .notWritten: return "nothing written"
        case .unknown: return "written, unverified"
        }
    }

    /// The connected body, when it is one this app may write to.
    ///
    /// What a write needs in hand before it starts: the transport, the model whose field knowledge
    /// encodes the recipe, and the permission the session granted. `performSlotWrite` takes one, so
    /// no write runs without a permission.
    private struct WritableTarget {
        let transport: CameraTransport
        let model: CameraModel
        let permission: WritePermission
    }

    /// Both write paths need the same three guards and the same three distinctions between them:
    /// no camera at all, a camera we don't recognise, and a camera we recognise but won't write to.
    private enum WritableTargetCheck {
        case ready(WritableTarget)
        case blocked(reason: String?)
    }

    private func writableTarget() -> WritableTargetCheck {
        guard let transport = session.transport else { return .blocked(reason: CameraError.noDeviceConnected.errorDescription) }
        // Distinct from "no camera": the body is connected and answering, we just don't know it.
        // Reporting `noDeviceConnected` here would tell testers to plug in a camera that is already
        // plugged in.
        guard let connected = session.connected, let model = connected.model else {
            return .blocked(reason: CameraError.unsupportedModel(name: session.connected?.productName ?? "camera").errorDescription)
        }
        // No permission — refused, or the slot read that decides hasn't finished — means no write,
        // whatever the model says.
        guard let permission = connected.writePermission else {
            return .blocked(reason: connected.writeBlockReason ?? CameraError.writeBlocked(reason: "").errorDescription)
        }
        return .ready(WritableTarget(transport: transport, model: model, permission: permission))
    }

    /// What a caller knows before the slot is even selected — clamps and advisories are properties of
    /// the recipe and the model, not of the write, so they belong on the result even when the select
    /// fails and nothing is attempted.
    struct Preflight {
        var clampedFields: [String] = []
        var advisories: [String] = []
        var unsupported: [RecipeField] = []
        /// The subset of `advisories` that says Dynamic Range, Highlight Tone or Shadow Tone is not
        /// being written because this recipe's D-Range Priority will be on. Carried separately, and
        /// duplicated rather than moved, because that sentence is only true while the `D191` write
        /// lands: when the camera refuses it, `performSlotWrite` sends all three after all and these
        /// three advisories are removed from the result by exact match.
        var priorityOverrides: [String] = []
    }

    /// Which kind of write this is. A restore takes the same path through the camera as a push; the
    /// kind changes what is logged and reported, and lets a restore write an empty name back.
    enum Kind: String {
        case push
        case restore
    }

    private func performPush(settings: RecipeSettings, name: String, toSlot slot: Int,
                             startedAt: Date, progress: String = "") async -> SlotWriteResult {
        let target: WritableTarget
        switch writableTarget() {
        case .ready(let t):
            target = t
        case .blocked(let reason):
            return SlotWriteResult(slot: slot, outcome: .notWritten, nameWritten: false,
                                   nameApplied: nil, clampedFields: [], fields: [],
                                   errorMessage: reason)
        }
        let model = target.model

        // Report what gets clamped and compute the values actually written. Fields the
        // model doesn't support never enter the encode set, so they're recorded up front rather
        // than inferred from a write that never happens.
        let issues = RecipeCompatibility.analyze(settings, for: model)
        var preflight = Preflight()
        preflight.clampedFields = issues.compactMap { issue in
            switch issue.kind {
            case .valueClamped, .magentaGreenClamped: return issue.subject
            default: return nil
            }
        }
        preflight.unsupported = issues.compactMap { if case .fieldUnsupported = $0.kind { return $0.field } else { return nil } }
        preflight.priorityOverrides = issues.compactMap { if case .notWritten = $0.kind { return $0.message } else { return nil } }
        // The kinds that change what is written without the camera refusing anything, carried to the
        // results so "Written and verified" cannot sit over a slot whose film simulation the push
        // quietly did not touch.
        //
        // `.magentaGreenAxisUnsupported` may also be refused. Nobody has reported what a
        // single-axis body does with a `D194` write. If it accepts and ignores it, every row reads
        // `written` over toning that did nothing, and this advisory is the only trace; if it
        // refuses, the advisory explains the rejected Monochromatic MG row.
        preflight.advisories = issues.compactMap { issue in
            switch issue.kind {
            case .filmSimulationUnset, .filmSimulationUnsupported, .ignoredForMonochrome,
                 .ignoredForFixedToning, .notWritten, .magentaGreenAxisUnsupported: return issue.message
            default: return nil
            }
        }
        let clamped = RecipeCompatibility.clamped(settings, to: model,
                                                  droppingUnsupportedFilmSimulation: false)

        return await performSlotWrite(
            on: target, toSlot: slot, name: name, progress: progress, kind: .push, preflight: preflight,
            startedAt: startedAt,
            withheldOnPriorityRefusal: { base, slotIsEmpty, model in
                FujiPresetCodec.dRangePriorityWithheld(clamped, model: model,
                                                       slot: slotIsEmpty ? .empty : .holds(base))
            }
        ) { base, slotIsEmpty, model in
            let codecSlot: FujiPresetCodec.Slot = slotIsEmpty ? .empty : .holds(base)
            var late: [String] = []

            // Everything said in this closure is derived from what `encode` will actually do with
            // *this* slot — never re-derived from the recipe alone.
            let unsent = FujiPresetCodec.defaultsNotWrittenForSilentRead(clamped, model: model, slot: codecSlot)

            // No film simulation: PROVIA is written. Not said when the slot never reported D192,
            // because then it isn't written and the advisory below says that instead.
            if clamped.filmSimulation == nil, !unsent.contains(.filmSimulation) {
                CameraLog.error("Push: \(model.id) C\(slot) — recipe has no film simulation; writing PROVIA / Standard")
            }

            // The one write this push makes on the user's behalf rather than at their request. A
            // recipe that leaves D-Range Priority unset is pushed with the default, Off — and the
            // migration that stores that default is lazy, so most library recipes still hold nil.
            // So whenever the bank has the priority on, the recipe doesn't say, and the bank reported
            // the property (or `emitDefault` declines), the codec turns it off. That deserves more
            // than a "D-Range Priority: written" row, whether or not a dynamic range is involved.
            if clamped.dRangePriority == nil, model.supports(.dRangePriority),
               let held = base[FujiPTP.PresetProp.dRangePriority.rawValue]
                   .flatMap(FujiEncoding.decodeUInt16)
                   .flatMap({ FujiEncoding.valueToDRangePriority[Int($0)] }),
               held != .off {
                let alsoDR = clamped.dynamicRange != nil
                    ? " That's also what lets this recipe's Dynamic Range take effect." : ""
                late.append("D-Range Priority was \(held.displayName) on this slot and the recipe leaves it "
                            + "unset, so it was turned off — a recipe's default is Off.\(alsoDR)")
                CameraLog.info("Push: \(model.id) C\(slot) — D-Range Priority \(held.displayName) → Off: the recipe leaves it unset, and a recipe's default is Off")
                self.reports.note("C\(slot): D-Range Priority \(held.displayName) → Off (recipe unset; default Off)")
            }

            // A *housekeeping* property the bank didn't report is harmless — nobody chose it and the
            // slot keeps its own. A recipe field the codec would have defaulted and couldn't is the
            // recipe's look not reaching the camera, and unlike every other way that can happen it
            // leaves no row on the results screen to say so. So it is said here.
            if !unsent.isEmpty {
                let list = unsent.map { $0.recipeField?.displayName ?? $0.debugName }
                    .joined(separator: ", ")
                late.append("\(list): this camera didn't say what the slot holds, so the recipe's "
                            + "default wasn't written and the slot keeps what it has.")
                CameraLog.error("Push: \(model.id) C\(slot) — \(list) defaulted but not written; the slot's read answered nothing for them")
            }
            return (FujiPresetCodec.encode(clamped, model: model, slot: codecSlot), late)
        }
    }

    /// Why the originals guard refused, for the user. `unread` names the planned properties whose
    /// read answered nothing usable; `lacking` names the ones the body answered `0x200A` to. When
    /// every missing original is one the body lacks and the name read, reconnecting changes nothing,
    /// so the message says what the body said instead of asking for a retry.
    static func unrecoverableOriginalsMessage(unread: [String], lacking: [String], nameMissing: Bool) -> String {
        let pronoun = lacking.count == 1 ? "it" : "them"
        let lacks = "This camera doesn't have \(lacking.joined(separator: ", ")) (0x200A), and this push writes "
            + "\(pronoun), so there is no original to put back."
        if unread.isEmpty, !nameMissing, !lacking.isEmpty {
            return lacks + " Nothing was written."
        }
        var message = "The original bank settings could not be preserved"
            + (unread.isEmpty ? "" : " (\(unread.joined(separator: ", ")))")
            + (nameMissing ? "; its original name is unavailable" : "")
            + ". Nothing was written. Reconnect and read the bank again."
        if !lacking.isEmpty { message += " " + lacks }
        return message
    }

    /// Select a slot, write its name, write an ordered property list, and verify by reading back.
    ///
    /// Push and restore both run this sequence and differ only in the bytes `encode` returns, so
    /// the selector read-back, the base read before the name write, the name-first write,
    /// per-property refusal handling, the bank-lock annotation and the `.unknown` outcome on a
    /// throw live in one place.
    ///
    /// `encode` receives the slot's bytes, the empty-slot flag and the model, and returns the
    /// ordered `(code, bytes)` list plus advisories only the slot's read can reveal. The flag is
    /// always false: unavailable reads never authorize seeds.
    ///
    /// `withheldOnPriorityRefusal` is the second, contingent list: what `encode` left out because
    /// this recipe's D-Range Priority was going to be on. It is written only if the `D191` write
    /// comes back refused, which cannot be known until the loop has run — see
    /// `FujiPresetCodec.dRangePriorityWithheld`. A restore has no recipe intent to be wrong about,
    /// so it passes nothing.
    private func performSlotWrite(on target: WritableTarget, toSlot slot: Int, name: String, progress: String,
                                  kind: Kind, preflight: Preflight, startedAt: Date,
                                  withheldOnPriorityRefusal: (([UInt16: Data], Bool, CameraModel)
                                      -> [(code: UInt16, bytes: Data)])? = nil,
                                  encode: ([UInt16: Data], Bool, CameraModel)
                                      -> (writes: [(code: UInt16, bytes: Data)], advisories: [String])
    ) async -> SlotWriteResult {
        var result = SlotWriteResult(slot: slot, outcome: .notWritten, nameWritten: false,
                                     nameApplied: nil, clampedFields: [], fields: [],
                                     errorMessage: nil)
        let transport = target.transport
        let model = target.model

        let sessionEpoch = session.epoch.current
        func checkSession() throws {
            guard session.operationIsCurrent(sessionEpoch) else { throw CameraError.disconnectedDuringOperation }
        }
        func finishSession(refresh: Bool = true) async {
            guard session.operationIsCurrent(sessionEpoch) else { return }
            session.setStatus(.connected)
            reports.isTracing = false
            if refresh { await slotReader.refresh() }
        }

        result.clampedFields = preflight.clampedFields
        result.advisories = preflight.advisories
        let unsupported = preflight.unsupported

        // 1. Select destination slot — fatal, and nothing has been written, so `.notWritten` stands.
        do {
            session.setStatus(.working("\(progress)Selecting slot C\(slot)…"))
            try await transport.writeProperty(FujiPTP.Prop.slotSelector, FujiEncoding.packU16(slot))
            try checkSession()
        } catch {
            result.errorMessage = CameraError.slotSelectFailed(slot, after: error).errorDescription
            await finishSession(refresh: false); return result
        }

        // 1b. Read the selector back before trusting it.
        //
        //     This is the write that decides where all the others land. A Fuji body can answer OK
        //     to `SetDevicePropValue` and keep its old value (see `probeProperties`, which exists
        //     to catch exactly that) — and if it does so here, the base read, the name write, the
        //     parameter writes *and* the read-back all address the same wrong slot. Every field
        //     then verifies, the outcome is `.applied`, and the results screen tells the user a
        //     slot holds a recipe that went somewhere else. Nothing has been written yet, so
        //     refusing here is free.
        let selected = await SlotSelector(transport: transport, reports: reports).read().value
        guard session.operationIsCurrent(sessionEpoch) else {
            result.errorMessage = CameraError.disconnectedDuringOperation.errorDescription
            return result
        }
        selectorReadBack = selected
        guard selected == slot else {
            CameraLog.error("\(kind.rawValue.capitalized): \(model.id) select refused — asked for C\(slot), camera reports \(selected.map { "C\($0)" } ?? "nothing"); nothing written")
            result.errorMessage = CameraError.slotSelectIgnored(asked: slot, got: selected).errorDescription
            await finishSession(); return result
        }

        // 2. Read the slot's current bytes and name before anything is written: they are the
        //    recovery copy Undo needs, and the originals the guard below requires for every
        //    planned write. A property the body lacks (`0x200A`) is absent from both. The plan
        //    passes a housekeeping property through only from the bytes the slot gave, so the push
        //    goes on without it; a recipe value the plan carries anyway meets the guard below.
        let base: [UInt16: Data]
        let absent: [FujiPTP.PresetProp]
        do {
            // An unmeasured allowance after the select, not a measured need. The record has no
            // settle requirement: X RAW Studio's X-T50 save sends the next command 0.385 ms after
            // the selector's response, and the clients that wait 50–100 ms report no failure
            // without it (zgrimz/fujifilm-ptp-reference `docs/04-custom-slots.md#reading-a-bank`,
            // `docs/errata.md#a-settle-delay-after-selecting-a-bank-is-a-precaution-not-a-measured-need`).
            // Whether any body needs a wait is untested; an X-T50 push run without this sleep,
            // every field compared, would settle it for that body.
            try? await Task.sleep(nanoseconds: 120_000_000)
            try checkSession()
            let read = try await transport.readAllPresetProperties()
            base = read.values
            absent = read.unsupported
            try checkSession()
            let originalName = try? await transport.readProperty(FujiPTP.Prop.presetName)
                .flatMap(Self.completePresetName)
            try checkSession()
            // The recovery copy, taken from the read the patch already needs. Everything after this
            // line can change the slot; nothing before it did.
            prePushSlotBytes = base
            // The name too. It is not a `PresetProp`, so it is not in `base`, and an undo without it
            // puts a slot's settings back under the name that replaced them.
            prePushSlotName = originalName
        } catch {
            result.errorMessage = error.cameraLogDescription
            await finishSession(); return result
        }

        // The property path has no characterized empty/occupied representation. Missing reads
        // never authorize factory seeds; every planned content write requires its original below.
        let slotIsEmpty = false
        prePushSlotWasEmpty = base[FujiPTP.PresetProp.filmSimulation.rawValue] == nil ? nil : false

        // The recovery copy goes into the report, and to disk, before the first write. A push the
        // cable or the app cuts off otherwise leaves a part-written slot and no record of what it
        // held, and Undo Last Push is missing for exactly the push that needs it. The finished
        // record replaces this entry by its start time when the push returns.
        reports.update { $0.beginPush(at: startedAt, slot: slot, modelID: session.connected?.registryModel?.id,
                                      firmwareVersion: session.connected?.firmwareVersion,
                                      slotBefore: base, nameBefore: prePushSlotName,
                                      slotWasEmpty: prePushSlotWasEmpty, selectorReadBack: selectorReadBack,
                                      kind: kind == .restore ? Kind.restore.rawValue : nil) }
        reports.persist()

        // The closure returns advisories as well as writes because some of them cannot be known
        // until the slot has been read — a default the codec declined to write because the bank
        // never reported the property is the case this exists for, and `preflight` is computed
        // before the camera is touched.
        let (encoded, lateAdvisories) = encode(base, slotIsEmpty, model)
        result.advisories.append(contentsOf: lateAdvisories)

        // Every planned write needs a recoverable original, including the name. Do this for the
        // complete plan before the first content write; nil, empty and malformed reads are not
        // permission to overwrite a value the recovery copy cannot reconstruct. Nor is a `0x200A`:
        // the body lacks the property, and a plan that writes it anyway (a recipe field the model
        // lists) stops here and is told that, not to reconnect.
        let contingentWrites = withheldOnPriorityRefusal?(base, slotIsEmpty, model) ?? []
        let missingOriginals = Set((encoded + contingentWrites).map(\.code)).filter { base[$0]?.count != 2 }
        let absentCodes = Set(absent.map(\.rawValue))
        guard !base.isEmpty, missingOriginals.isEmpty,
              !model.supportsSlotNaming || prePushSlotName != nil else {
            let names = { (codes: Set<UInt16>) in codes.sorted().map(SlotWriteVerification.propertyName) }
            result.errorMessage = Self.unrecoverableOriginalsMessage(
                unread: names(missingOriginals.subtracting(absentCodes)),
                lacking: names(missingOriginals.intersection(absentCodes)),
                nameMissing: model.supportsSlotNaming && prePushSlotName == nil)
            session.setStatus(.connected)
            return result
        }

        // Properties that carry a seed value and that this write skips because the slot's read
        // returned nothing for them. Nothing is written for them, and the omission is logged and
        // noted rather than left to be inferred from a row missing off the results screen.
        let attempting = Set(encoded.map(\.code))
        // Withheld properties are not unanswered ones: the read answered and the app chose not to
        // write them (`FujiPresetCodec.unwritableProperties`).
        let withheld = FujiPresetCodec.unwritableProperties(on: model)
        // Nor is a property the plan leaves out because there is nothing to change: `D191` when the
        // recipe's D-Range Priority already matches the bank's, `D190` whenever that priority will
        // be on. Nor one the body answered `0x200A` to: that read did answer, and what it said is
        // recorded below. So the test is the one the message states: `base` has no bytes for it.
        let skipped = FujiPresetCodec.seedValues.keys
            .filter { !attempting.contains($0.rawValue) && !withheld.contains($0)
                      && base[$0.rawValue] == nil && !absentCodes.contains($0.rawValue) }
            .sorted { $0.rawValue < $1.rawValue }
        if !withheld.isEmpty {
            let ordered = withheld.sorted { $0.rawValue < $1.rawValue }
            let list = ordered.map { "\($0.debugName) (\(PTPHex.code($0.rawValue)))" }.joined(separator: ", ")
            CameraLog.info("\(kind.rawValue.capitalized): \(model.id) C\(slot) — \(list) not written; this body refuses them and the slot keeps the value it already holds")
            reports.noteOnce("C\(slot): \(ordered.map { PTPHex.code($0.rawValue) }.joined(separator: " ")) withheld — this body answers 0x201C to them, and they carry the slot's own value")
        }
        if !skipped.isEmpty {
            let list = skipped.map { "\($0.debugName) (\(PTPHex.propertyLabel($0.rawValue)))" }
                .joined(separator: ", ")
            CameraLog.error("\(kind.rawValue.capitalized): \(model.id) C\(slot) — the slot's read returned nothing for \(list); not written, so the slot keeps whatever it holds")
            reports.noteOnce("C\(slot): base read missing \(skipped.map { PTPHex.code($0.rawValue) }.joined(separator: " ")) — omitted from the write rather than defaulted")
        }
        // Properties the body lacks. The recovery copy holds nothing for them and the plan carries
        // nothing for them, so no field row would say so; the result does, and the report gets the
        // codes through the call the walk records them with.
        if !absent.isEmpty {
            let list = absent.map { "\($0.debugName) (\(PTPHex.propertyLabel($0.rawValue)))" }.joined(separator: ", ")
            let pronoun = absent.count == 1 ? "it" : "them"
            CameraLog.info("\(kind.rawValue.capitalized): \(model.id) C\(slot) — \(list) answered 0x200A; this body doesn't have \(pronoun), so nothing was written for \(pronoun)")
            result.notes.append("\(absent.map(\.debugName).joined(separator: ", ")): this camera doesn't have \(pronoun) (0x200A), so nothing was written for \(pronoun).")
            reports.update { report in
                for prop in absent { report.noteUnsupported(code: prop.rawValue) }
            }
        }
        // Grain restoration can require two consecutive writes to one property. Each run of writes
        // to one property gets one field result, verified against its final value, and a refusal
        // stops that run.
        var writeGroups: [[(code: UInt16, bytes: Data)]] = []
        for prop in encoded {
            if writeGroups.last?.last?.code == prop.code { writeGroups[writeGroups.count - 1].append(prop) }
            else { writeGroups.append([prop]) }
        }
        // Every property this write intends to set, pending until proven otherwise. Fields the
        // model doesn't support are rows too, rejected before the loop starts, so the results
        // screen accounts for the whole recipe rather than only the parts that reached the camera.
        var fields = writeGroups.compactMap(\.last).map { prop in
            FieldResult(code: prop.code, field: SlotWriteVerification.propertyName(for: prop.code),
                        isRecipeField: SlotWriteVerification.isRecipeField(prop.code), outcome: .notAttempted,
                        wrote: prop.bytes)
        }
        for field in unsupported {
            fields.append(FieldResult(code: 0, field: field.displayName, isRecipeField: true,
                                      outcome: .rejected(code: nil)))
        }
        func mark(_ code: UInt16, _ outcome: FieldOutcome) {
            if let i = fields.firstIndex(where: { $0.code == code }) { fields[i].outcome = outcome }
        }
        // Set by the contingent pass below. Read once, at the end, to drop the three advisories
        // that the refusal made untrue.
        var wroteWithheldAfterPriorityRefusal = false

        do {
            // 2b. The staged first write, on a push to a body no push has been read back on
            //     (`WritePermission.Stage.unverified`): one bank property, written and read back on
            //     its own before anything else changes, so a body whose bank path isn't what the
            //     codec assumes shows it on one setting rather than on twenty-three. A stop puts
            //     that one setting back and ends the push; `0x201C` is the value, not the protocol,
            //     and the push goes on as it does past any such refusal. App policy, not a protocol
            //     fact: see `StagedWrite`.
            var written: [(code: UInt16, bytes: Data)] = []
            var stagedCode: UInt16?
            if kind == .push, target.permission.stage == .unverified,
               let staged = StagedWrite.pick(encoded: encoded, base: base) {
                stagedCode = staged.code
                let name = SlotWriteVerification.propertyName(for: staged.code)
                session.setStatus(.working("\(progress)Checking that C\(slot) takes a write…"))
                try checkSession()
                mark(staged.code, .outcomeUnknown)
                switch await stageFirstWrite(staged, base: base, on: transport) {
                case .written:
                    mark(staged.code, .written)
                    written.append(staged)
                    result.firstWrite = .written(property: staged.code)
                    CameraLog.info("\(kind.rawValue.capitalized): \(model.id) C\(slot) staged \(name) — written and read back; writing the rest")
                case .invalidValue(let code):
                    mark(staged.code, .rejected(code: code))
                    result.firstWrite = .invalidValue(property: staged.code, code: code)
                    CameraLog.error("\(kind.rawValue.capitalized): \(model.id) C\(slot) staged \(name) — refused \(PTPHex.code(code)), the value rather than the protocol; writing the rest")
                case .stopped(let outcome):
                    result.firstWrite = outcome
                    if case .refused(_, let code, _) = outcome { mark(staged.code, .rejected(code: code)) }
                    if case .mismatched(_, let read, _) = outcome { mark(staged.code, .mismatched(wrote: staged.bytes, read: read)) }
                    result.fields = fields
                    result.outcome = StagedWrite.outcomeAfterStop(outcome)
                    result.errorMessage = outcome.stopMessage(slot: slot)
                    CameraLog.error("\(kind.rawValue.capitalized): \(model.id) C\(slot) staged \(name) — stopped: \(result.errorMessage ?? "")")
                    session.recordFirstWrite(outcome)
                    await finishSession()
                    return result
                case .lost(let outcome, let error):
                    // The field stays `.outcomeUnknown`; the catch below files the push as unknown.
                    result.firstWrite = outcome
                    session.recordFirstWrite(outcome)
                    CameraLog.error("\(kind.rawValue.capitalized): \(model.id) C\(slot) staged \(name) — no response; stopped")
                    throw error
                }
                try checkSession()
            }

            // 3. Name. The bank's name and nothing more: on an X-T50 property writes take effect
            //    at once and persist on their own, with or without it (fw 1.32, 2026-10-15/16;
            //    zgrimz/fujifilm-ptp-reference `docs/04-custom-slots.md`). Written first because
            //    that is X RAW Studio's order, except on a staged first push, where the staged
            //    property precedes it (app policy, `StagedWrite`); written last works as well.
            //    Best-effort.
            if model.supportsSlotNaming {
                try checkSession()
                // A restore of a slot that had no name writes the empty name back, in the bank's
                // own unnamed form (`FujiEncoding.packPTPString`). A push never does:
                // `sanitizedSlotName` turns an empty recipe name into "Recipe".
                let applied = kind == .restore && name.isEmpty ? "" : model.sanitizedSlotName(from: name)
                result.nameApplied = applied
                result.nameOutcome = .outcomeUnknown
                do {
                    try await transport.writeProperty(FujiPTP.Prop.presetName, FujiEncoding.packPTPString(applied))
                    try checkSession()
                    result.nameWritten = true
                    result.nameOutcome = .unverified
                } catch CameraError.ptpError(let code) {
                    result.nameWritten = false
                    result.nameOutcome = .rejected(code: code)
                } catch {
                    throw error
                }
            }

            // 4. Write each property; per-property rejections are non-fatal (some are read-only).
            session.setStatus(.working("\(progress)Writing slot C\(slot)…"))
            for group in writeGroups {
                guard let prop = group.last, prop.code != stagedCode else { continue }
                do {
                    try checkSession()
                    mark(prop.code, .outcomeUnknown)
                    for step in group {
                        try checkSession()
                        try await transport.writeProperty(step.code, step.bytes)
                        try checkSession()
                    }
                    written.append(prop)
                    mark(prop.code, .unverified)   // provisional until the read-back confirms it
                } catch CameraError.ptpError(let code) {
                    mark(prop.code, .rejected(code: code))
                    // Every rejection, housekeeping props included: a refused housekeeping property
                    // can be the only trace of a bank setting the 23 bank properties don't carry — see
                    // `SlotWriteResult.imageSizeFixedByBank` — and the transport's own
                    // `Transport: PTP error 0x201C` line doesn't know which property or which push
                    // it belonged to.
                    CameraLog.error("\(kind.rawValue.capitalized): \(model.id) rejected \(SlotWriteVerification.propertyName(for: prop.code)) (\(PTPHex.propertyLabel(prop.code))) — \(PTPHex.code(code))")
                } catch {
                    // A submitted command without a valid completion may already have landed.
                    // Do not continue or replay it as though the camera had refused it.
                    throw error
                }
            }

            // 4b. D-Range Priority refused. `encode` left out Dynamic Range and both tones because
            //     the priority write was going to land; it didn't, so the bank keeps its own
            //     priority and those three are written after all. This needs the camera's answer to
            //     D191, so it can't join the list above. It runs whatever the bank's priority is:
            //     if that is off they land, and if it is on, any refusal shows as a named row on the
            //     results screen rather than three fields nobody mentioned.
            let priorityRefused = fields.contains { field in
                guard field.code == FujiPTP.PresetProp.dRangePriority.rawValue,
                      case .rejected = field.outcome else { return false }
                return true
            }
            let withheldByPriority = priorityRefused ? contingentWrites : []
            if !withheldByPriority.isEmpty {
                wroteWithheldAfterPriorityRefusal = true
                CameraLog.info("\(kind.rawValue.capitalized): \(model.id) C\(slot) — D-Range Priority refused, so the \(withheldByPriority.count) propert\(withheldByPriority.count == 1 ? "y" : "ies") it would have driven are being written after all")
                for prop in withheldByPriority {
                    fields.append(FieldResult(code: prop.code,
                                              field: SlotWriteVerification.propertyName(for: prop.code),
                                              isRecipeField: SlotWriteVerification.isRecipeField(prop.code),
                                              outcome: .notAttempted, wrote: prop.bytes))
                    do {
                        try checkSession()
                        mark(prop.code, .outcomeUnknown)
                        try await transport.writeProperty(prop.code, prop.bytes)
                        try checkSession()
                        written.append(prop)
                        mark(prop.code, .unverified)
                    } catch CameraError.ptpError(let code) {
                        mark(prop.code, .rejected(code: code))
                        CameraLog.error("\(kind.rawValue.capitalized): \(model.id) rejected \(SlotWriteVerification.propertyName(for: prop.code)) (\(PTPHex.propertyLabel(prop.code))) — \(PTPHex.code(code))")
                    } catch {
                        throw error
                    }
                }
                result.notes.append("C\(slot) kept the D-Range Priority it already had, so this recipe's Dynamic Range, Highlight Tone and Shadow Tone were sent after all rather than left to the priority. Their rows below say how each one landed.")
            }

            // 5. Verify by reading back what we wrote. A throw here means the writes
            //    landed and we simply can't confirm them — `.unknown`, never `.notWritten`.
            session.setStatus(.working("\(progress)Verifying slot C\(slot)…"))
            try checkSession()
            let readBack = try await transport.readAllPresetProperties().values
            try checkSession()
            result.filmSimulationReadBack = readBack[FujiPTP.PresetProp.filmSimulation.rawValue]
                .flatMap(FujiEncoding.decodeInt16).flatMap { FujiEncoding.byteToFilmSim[$0] }
            result.dynamicRangeReadBack = readBack[FujiPTP.PresetProp.dynamicRange.rawValue]
                .flatMap(FujiEncoding.decodeInt16)
                .flatMap { $0 == FujiEncoding.drAutoSlotValue ? .auto : FujiEncoding.percentToDR[$0] }
            for prop in written {
                if SlotWriteVerification.readBackMatches(prop.code, wrote: prop.bytes, read: readBack[prop.code]) {
                    mark(prop.code, .written)
                } else if readBack[prop.code]?.count == 2 {
                    mark(prop.code, .mismatched(wrote: prop.bytes, read: readBack[prop.code]))
                } else {
                    mark(prop.code, .unverified)
                }
            }
            if result.nameWritten, let applied = result.nameApplied {
                let nameBytes = try await transport.readProperty(FujiPTP.Prop.presetName)
                try checkSession()
                if let nameBytes, let readName = Self.completePresetName(nameBytes) {
                    result.nameOutcome = readName == applied ? .written
                        : .mismatched(wrote: FujiEncoding.packPTPString(applied), read: nameBytes)
                } else {
                    result.nameOutcome = .unverified
                }
            }
            result.fields = fields
            if wroteWithheldAfterPriorityRefusal {
                result.advisories.removeAll { preflight.priorityOverrides.contains($0) }
            }
            // A write the camera accepted and then didn't hold. Distinct from a rejection, and the
            // more dangerous of the two: nothing failed loudly enough to name.
            for mismatch in result.mismatches {
                CameraLog.error("\(kind.rawValue.capitalized): \(model.id) accepted \(mismatch.field) (\(PTPHex.propertyLabel(mismatch.code))) but the read-back didn't match")
            }
            result.outcome = fields.contains { $0.outcome == .outcomeUnknown } ? .unknown
                : SlotWriteVerification.outcome(for: result.recipeFields, nameWritten: result.nameWritten, nameOutcome: result.nameOutcome)
            annotateBankLocks(&result)
            annotateCameraFlag(&result)
            if let first = result.mismatches.first {
                result.errorMessage = CameraError.readBackMismatch(field: first.field).errorDescription
            }
            if let firstWrite = result.firstWrite { session.recordFirstWrite(firstWrite) }
            // The transition is the session's to make; the writer only reports what the read-back
            // showed. A restore never promotes: it replays the body's own bytes.
            if kind == .push, target.permission.stage == .unverified, StagedWrite.provesBankPath(result) {
                session.markWriteVerified()
                reports.update { $0.camera.writeAccess = session.connected?.writeAccess.reportLabel }
            }
            await finishSession()
        } catch {
            // Whatever threw, the fields already written are on the camera.
            result.fields = fields
            if wroteWithheldAfterPriorityRefusal {
                result.advisories.removeAll { preflight.priorityOverrides.contains($0) }
            }
            result.outcome = fields.contains { $0.outcome == .outcomeUnknown } ? .unknown
                : SlotWriteVerification.outcome(for: result.recipeFields, nameWritten: result.nameWritten, nameOutcome: result.nameOutcome)
            annotateBankLocks(&result)
            annotateCameraFlag(&result)
            result.errorMessage = error.cameraLogDescription
            await finishSession(refresh: false)
        }
        return result
    }

    /// What the camera shows after a push, said before a user reads it as "not saved". On an X-T50
    /// every property write leaves a red dot on the written item in EDIT/SAVE CUSTOM SETTING (not
    /// in the Q menu), with SAVE THE CHANGES and RESET THE CHANGES offered. The dot is cosmetic: the
    /// write took effect at once, survives a power cycle and a bank change, and RESET THE CHANGES
    /// leaves it in place — it reverts changes made on the body, not over USB. No order or timing of
    /// writes avoids it, the name write included; a power cycle, or opening the item on the camera,
    /// clears it (fw 1.32, 2026-10-16; zgrimz/fujifilm-ptp-reference `docs/04-custom-slots.md`).
    private func annotateCameraFlag(_ result: inout SlotWriteResult) {
        switch result.outcome {
        case .applied, .partiallyApplied: break
        default: return
        }
        result.notes.append("The camera may now show a red dot on C\(result.slot)'s changed settings in EDIT/SAVE CUSTOM SETTING. That's cosmetic: the push is saved and survives a restart, and the camera's RESET THE CHANGES won't undo it — Undo Last Push will. The dot clears the next time the camera is switched off and on.")
    }

    /// A refusal that is about the bank, not the recipe. Image Size isn't a recipe field, so without
    /// this the log's `rejected Image Size (D18E)` line is the only trace, and a bank with a setting
    /// that fixes Image Size looks like a firmware quirk (`SlotWriteResult.imageSizeFixedByBank`,
    /// which says how much of the cause is measured). Three places learn the meaning: the results
    /// screen, the log, and the compatibility report.
    private func annotateBankLocks(_ result: inout SlotWriteResult) {
        guard result.imageSizeFixedByBank else { return }
        result.notes.append("C\(result.slot) has a setting that fixes Image Size, such as Sports Finder Mode or Digital Tele-Converter. The camera kept the size it had; the recipe isn't affected.")
        CameraLog.info("Push: C\(result.slot) refused Image Size (D18E) 0x201C while the recipe wrote — the bank fixes Image Size (Sports Finder Mode or Digital Tele-Converter, by the X-T50 evidence); harmless")
        reports.noteOnce("C\(result.slot): D18E refused 0x201C with the recipe written — the bank has a setting that fixes Image Size (Sports Finder Mode was on in the X-T50 banks that refused; Digital Tele-Converter refused then accepted the same bytes across an on/off comparison; HDR untested)")
    }

    /// Holds the gate across the whole batch: slots written in sequence are one operation as far as
    /// the camera is concerned, and letting anything else select a slot between items is the interleave
    /// this gate exists to prevent. A batch the gate refuses answers one refused result per item.
    func pushBatch(_ items: [(settings: RecipeSettings, name: String, slot: Int)]) async -> [SlotWriteResult] {
        do throws(CameraBusy) {
            return try await gate.run("push to \(items.count) slot(s)") {
                await self.pushBatchExclusively(items)
            }
        } catch {
            return items.map { .refused(slot: $0.slot, by: error) }
        }
    }

    private func pushBatchExclusively(_ items: [(settings: RecipeSettings, name: String, slot: Int)]) async
        -> [SlotWriteResult] {
        let sessionEpoch = self.session.epoch.current
        var results: [SlotWriteResult] = []
        let total = items.count
        self.pushProgress = BatchProgress(completed: 0, total: total)
        for (i, item) in items.enumerated() {
            let progress = total > 1 ? "(\(i + 1) of \(total)) " : ""
            let result = await self.pushExclusively(settings: item.settings, name: item.name,
                                                   toSlot: item.slot, progress: progress)
            results.append(result)
            func remaining(_ reason: String) -> [SlotWriteResult] {
                items.dropFirst(i + 1).map {
                    SlotWriteResult(slot: $0.slot, outcome: .notWritten, nameWritten: false,
                                    nameApplied: nil, clampedFields: [], fields: [], errorMessage: reason)
                }
            }
            guard self.session.operationIsCurrent(sessionEpoch) else {
                return results + remaining("The camera session changed before this bank was started. Nothing was written to it.")
            }
            // A command without a valid completion may have changed the camera. Do not
            // resume mutations at the next bank. An accepted write whose read-back alone
            // is unavailable remains a separate, unverified observation.
            if result.nameOutcome == .outcomeUnknown || result.fields.contains(where: { $0.outcome == .outcomeUnknown }) {
                results += remaining("An earlier bank has an unconfirmed write. This bank was not started; reconnect and check the earlier bank before trying again.")
                break
            }
            self.pushProgress = BatchProgress(completed: i + 1, total: total)
        }
        self.lastWriteResults = results
        self.pushProgress = nil
        return results
    }

    // MARK: - The staged first write

    private enum StageResult {
        case written
        case invalidValue(code: UInt16)
        case stopped(FirstWriteOutcome)
        /// The write got no response. The restore has been attempted and recorded; the caller
        /// rethrows `error` so the push ends as any lost response does.
        case lost(FirstWriteOutcome, Error)
    }

    /// Write the staged property and read it back. On a refusal other than `0x201C`, on a read-back
    /// that differs, or on a lost response, put the property back (`restoreStaged`) and say how
    /// that went.
    private func stageFirstWrite(_ staged: (code: UInt16, bytes: Data), base: [UInt16: Data],
                                 on transport: CameraTransport) async -> StageResult {
        let code = staged.code
        do {
            try await transport.writeProperty(code, staged.bytes)
        } catch CameraError.ptpError(let response) where response == FujiPTP.responseInvalidDevicePropValue {
            return .invalidValue(code: response)
        } catch CameraError.ptpError(let response) {
            // The camera answered, so it took nothing; the read after confirms the bank is as it was.
            let restore = await restoreStaged(code, to: base[code], on: transport)
            return .stopped(.refused(property: code, code: response, restore: restore))
        } catch {
            // A send with no response may have landed. One read says whether the bank changed.
            let restore = await restoreStaged(code, to: base[code], on: transport)
            return .lost(.unknown(property: code, restore: restore), error)
        }
        let read: Data?
        do {
            read = try await transport.readProperty(code)
        } catch {
            return .lost(.unknown(property: code, restore: .restoreUnknown), error)
        }
        guard SlotWriteVerification.readBackMatches(code, wrote: staged.bytes, read: read) else {
            let restore = await restoreStaged(code, to: base[code], on: transport)
            return .stopped(.mismatched(property: code, read: read, restore: restore))
        }
        return .written
    }

    /// Put the staged property back to the recovery copy: read first, write only on a difference,
    /// read back. The same rule `SlotSelector.restore` follows, for the same reason: a no-op write
    /// can itself be refused (zgrimz/fujifilm-ptp-reference `docs/04-custom-slots.md#why-a-write-is-refused`).
    private func restoreStaged(_ code: UInt16, to original: Data?,
                               on transport: CameraTransport) async -> FirstWriteOutcome.Restore {
        // Every planned write had its original in the recovery copy (the guard before the first
        // write), so a missing one here is an outcome nothing can confirm.
        guard let original else { return .restoreUnknown }
        let current: Data?
        do { current = try await transport.readProperty(code) } catch { return .restoreUnknown }
        if current == original { return .unchanged }
        do {
            try await transport.writeProperty(code, original)
        } catch CameraError.ptpError(let response) {
            return .restoreRefused(code: response)
        } catch {
            return .restoreUnknown
        }
        guard let after = try? await transport.readProperty(code) else { return .restoreUnknown }
        return after == original ? .restored : .restoreMismatch
    }

    // MARK: - Helpers

    /// A partial string must not become the recovery name or a successful name verification.
    ///
    /// An unnamed bank answers `01 00 00`, the count and the NUL (X-T50; fw 1.31 in a published log,
    /// zgrimz/fujifilm-ptp-reference `docs/07-cameras.md#bank-behavior`, and fw 1.32 after an
    /// empty-name write, 2026-10-19). That is a complete empty name, and the form
    /// the app writes for one.
    nonisolated static func completePresetName(_ data: Data) -> String? {
        guard let count = data.first, data.count == 1 + Int(count) * 2 else { return nil }
        if count == 0 { return "" }
        guard data.suffix(2) == Data([0, 0]) else { return nil }
        if count == 1 { return "" }
        guard let name = FujiEncoding.parsePTPString(data), FujiEncoding.packPTPString(name) == data else { return nil }
        return name
    }

}

import Foundation

/// Diagnostics a tester runs from the property report: what each property holds and accepts, and
/// which values a slot property really takes when written.
@MainActor
final class CameraDiagnostics {

    /// Values to try against D195, ordered so that 1 (write-side Off) lands right after an accepted
    /// on-value each time. The camera normalizes a write of 1 to read-side 6 or 7 (see the grain notes
    /// in `FujiEncoding`), so the read-back changes; a silent discard would leave the prior value.
    /// The interleave is what tells the two apart.
    ///
    /// Here rather than on the diagnostic screen, because the guided test runs the same probe and
    /// two lists that drifted apart would make two testers' answers to the same question
    /// incomparable.
    static let grainProbeCandidates = [0, 2, 1, 3, 6, 4, 7, 5, 1, 8]

    /// Values to try against D190, to find out **which dynamic ranges a slot will actually accept**.
    ///
    /// A slot answers `0x201C Invalid DeviceProp Value` to a DR the camera will not currently allow.
    /// DR200 and DR400 are gated on the slot's own ISO, which none of the 23 bank properties carries,
    /// so a refused write is the only way to learn where a body stands; see the Dynamic Range notes
    /// in `FujiEncoding` for the evidence and for the D-Range Priority gate.
    ///
    /// 100 is interleaved between the gated values because it should never be refused: it is the
    /// control. A 100 that goes through either side of a refused 200 proves the property still takes
    /// writes and the refusal is about *that value*, not a wedged slot. DR Auto (`0xFFFF`, packed
    /// from −1) goes last because it has no ISO gate, so a body that refuses 200 and 400 and still
    /// takes Auto shows the refusals are the ISO gate.
    static let dynamicRangeProbeCandidates = [100, 200, 100, 400, 100, FujiEncoding.drAutoSlotValue]

    private let session: CameraSession
    private let reports: CompatibilityReportRecorder
    private let gate: CameraOperationGate

    init(session: CameraSession, reports: CompatibilityReportRecorder, gate: CameraOperationGate) {
        self.session = session
        self.reports = reports
        self.gate = gate
    }

    /// Ask the camera to describe every preset property of one slot: what it holds and, where the
    /// body answers `GetDevicePropDesc`, which values it will accept. Records the sweep in the
    /// compatibility report. A body that refuses descriptors (X-T50) needs `probeWriteValues` to
    /// learn its writable set.
    ///
    /// Read-only apart from the slot select and its restore, which follow `maySelectSlots`, the rule
    /// the slot read uses. On a body that has no slot protocol, or that nobody recognizes, it writes
    /// nothing: `ReadOnlyPropertySweep` promises those bodies nothing was written, as does the card
    /// that offers their report. It degrades instead of refusing, reading whichever slot the camera
    /// already had selected.
    ///
    /// Returns the slot it actually read, which is not always the one it was asked for. The probes
    /// are empty, beside the requested slot, when no camera is connected or the slot select failed.
    /// Throws `CameraBusy`, having sent nothing, when another operation held the gate.
    func probeProperties(slot: Int) async throws(CameraBusy) -> (slot: Int, probes: [PropertyProbe]) {
        try await gate.run("property report") { await self.probePropertiesExclusively(slot: slot) }
    }

    private func probePropertiesExclusively(slot: Int) async -> (slot: Int, probes: [PropertyProbe]) {
        guard let transport = session.transport else { return (slot, []) }
        let maySelect = session.maySelectSlots
        session.setStatus(.working("Reading property report…"))
        reports.isTracing = true
        defer { reports.isTracing = false }

        func message(_ error: Error) -> String {
            (error as? CameraError)?.errorDescription ?? error.localizedDescription
        }

        var codes: [(code: UInt16, name: String)] = [(FujiPTP.Prop.slotSelector, "Slot Selector"),
                                                     (FujiPTP.Prop.presetName, "Preset Name")]
        codes += FujiPTP.PresetProp.allCases.map { ($0.rawValue, $0.debugName) }
        // The RAW-conversion properties. Not slot-scoped; included because no slot read captures the
        // D185 blob, and only a real dump checks the layout `FujiRawConvProfile` assumes.
        // Meaningful only with the camera in USB RAW Conv./Backup Restore mode, and D185 reflects a
        // photo's as-shot values only after a RAF has been uploaded.
        codes += [(FujiPTP.Prop.rawConvProfile, "RAW Conv. Profile (D185)"),
                  (FujiPTP.Prop.startRawConversion, "Start RAW Conversion (D183)")]
        // ISO, in case it tracks the slot ISO that gates D190: if it did, the app could warn before a
        // push instead of reporting a refusal after one. Read on every body because a recorded
        // refusal is itself the finding; see the Dynamic Range notes in `FujiEncoding` for which
        // bodies have answered. Standard PTP, so it says nothing about the slot protocol either way.
        codes += [(FujiPTP.Prop.exposureIndex, "ISO (0x500F, standard PTP)")]

        let selectorBefore: Int? = maySelect ? await readSelector(transport) : nil
        let probedSlot: Int
        if maySelect {
            do {
                try await transport.writeProperty(FujiPTP.Prop.slotSelector, FujiEncoding.packU16(slot))
            } catch {
                session.setStatus(.failed(CameraError.slotSelectFailed(slot, after: error).errorDescription
                                          ?? message(error)))
                return (slot, [])
            }
            // Verified, for the reason the slot walk verifies it: a select answered OK and ignored
            // would file one slot's values under another slot's name, and the report would agree
            // with itself while doing it. Here that degrades rather than fails — the values are
            // still worth having, labelled with the slot the camera says they came from.
            let landed = await readSelector(transport)
            if let landed, landed != slot {
                CameraLog.error("Property report: asked for C\(slot), camera reports C\(landed) — reporting it as C\(landed)")
                reports.note("property report: slot select answered OK but did not take (asked C\(slot), camera reports C\(landed)); the report below describes C\(landed)")
            }
            probedSlot = landed ?? slot
        } else {
            probedSlot = await readSelector(transport) ?? slot
            CameraLog.info("Property report: \(session.connected?.productName ?? "this body") has no USB slot protocol, so no slot was selected — reading C\(probedSlot), the slot it already has")
        }

        var probes: [PropertyProbe] = []
        for (code, name) in codes {
            var value: Data?, valueError: String?
            do { value = try await transport.readProperty(code) } catch { valueError = message(error) }

            var descriptor: FujiPTP.PropertyDescriptor?, descriptorError: String?
            do {
                if let raw = try await transport.readPropertyDescriptor(code) {
                    descriptor = FujiPTP.parsePropertyDescriptor(raw)
                    if descriptor == nil { descriptorError = "unparseable descriptor (\(raw.count) bytes)" }
                }
            } catch CameraError.ptpError(let code) {
                // Some bodies (X-T50) refuse GetDevicePropDesc wholesale — keep the row compact.
                descriptorError = String(format: "no descriptor (camera answered 0x%04X %@)",
                                         code, FujiPTP.responseName(code) ?? "")
            } catch {
                descriptorError = message(error)
            }

            probes.append(PropertyProbe(code: code, name: name, value: value, descriptor: descriptor,
                                        valueError: valueError, descriptorError: descriptorError))
        }
        // The property report is the same sweep with a slot select in front of it: it belongs in
        // the compatibility report too, so a tester who ran it doesn't have to paste it separately.
        let sweepRecord = CameraCompatibilityReport.PropertySweep(
            // `readOnly` is the report's claim that nothing was written during the sweep. The slot
            // select is a write, so it is only true where no select was sent.
            slot: probedSlot, readOnly: !maySelect,
            entries: probes.map { p in
                var entry = CameraCompatibilityReport.PropertyProbeRecord(code: PTPHex.code(p.code), name: p.name)
                if let v = p.value { entry.value = PTPHex.bytes(v); if v.count == 2 { entry.decoded = FujiEncoding.decodeInt16(v) } }
                entry.valueError = p.valueError
                entry.descriptor = p.descriptor.map(CameraCompatibilityReport.descriptorRecord)
                entry.descriptorError = p.descriptorError
                return entry
            })
        reports.update { report in
            report.propertySweep = sweepRecord
            report.propertySweep?.capturedAt = CameraCompatibilityReport.timestamp()
            report.propertySweep?.evidenceID = UUID().uuidString
            report.touch()
        }
        reports.persist()
        let answered = probes.filter { $0.value != nil }.count
        let described = probes.filter { $0.descriptor != nil }.count
        CameraLog.info("Property report: C\(probedSlot) — \(answered) of \(probes.count) values read, \(described) descriptors")
        session.setStatus(.connected)
        if maySelect {
            await restoreSelector(transport, to: selectorBefore, after: "property report")
        }
        return (probedSlot, probes)
    }

    /// Map a property's writable value set the hard way: write each candidate, read back, restore.
    /// Needed because some bodies (X-T50) reject `GetDevicePropDesc`, and because a Fuji body can
    /// accept a write, reject it with an error, or answer OK and discard or normalize the value;
    /// only a read-back distinguishes the last two.
    ///
    /// Refuses a body the app doesn't write to. Verifies the selected bank and requires a usable
    /// original before trying candidates; an unreadable original aborts rather than being taken
    /// for an empty bank. Restores the original and the selected bank afterwards, and notes any
    /// doubt about either in the report.
    ///
    /// Returns one entry per candidate tried. Empty means no candidate was written: the body was
    /// refused or a precondition failed (the report notes which). Throws `CameraBusy`, having sent
    /// nothing, when another operation held the gate.
    func probeWriteValues(slot: Int, property: FujiPTP.PresetProp,
                          candidates: [Int]) async throws(CameraBusy) -> [WriteProbeEntry] {
        try await gate.run("\(property.debugName) write probe") {
            // Refused, not degraded as the property report is: this writes real candidate values to
            // a real slot, and without the check a diagnostic tool would issue writes to any body
            // that happened to be plugged in, including one the app had just told the user it would
            // not write to.
            guard let transport = self.session.transport,
                  let permission = self.session.connected?.writePermission else {
                CameraLog.error("Write probe refused: \(self.session.connected?.productName ?? "this camera") isn't a body this app writes to")
                return []
            }
            return await self.probeWriteValuesExclusively(on: transport, permission: permission, slot: slot,
                                                          property: property, candidates: candidates)
        }
    }

    /// `permission` is what makes a write probe legitimate; `probeWriteValues` is the only caller.
    private func probeWriteValuesExclusively(on transport: CameraTransport, permission: WritePermission,
                                             slot: Int, property: FujiPTP.PresetProp,
                                             candidates: [Int]) async -> [WriteProbeEntry] {
        let sessionEpoch = session.epoch.current
        session.setStatus(.working("Probing \(property.debugName) on C\(slot)…"))
        // Traced, like the property report, the push and the develop. The summary line below says
        // what each candidate did; the trace says what went over the wire to produce it — and this
        // probe exists precisely for the body whose encoding is *not* the one the summary assumes,
        // where "reads back 6" is a decoded guess and the bytes are the evidence. Twenty-odd
        // transactions against a 1200 cap.
        reports.isTracing = true
        defer { if session.operationIsCurrent(sessionEpoch) { reports.isTracing = false } }

        func message(_ error: Error) -> String {
            if case CameraError.ptpError(let code) = error {
                return "\(PTPHex.code(code)) \(FujiPTP.responseName(code) ?? "")"
            }
            return (error as? CameraError)?.errorDescription ?? error.localizedDescription
        }

        let selectorBefore = await readSelector(transport)
        func abort(_ reason: String, restoreSelection: Bool = true) async -> [WriteProbeEntry] {
            guard session.operationIsCurrent(sessionEpoch) else { return [] }
            let detail = "write probe \(property.debugName) C\(slot): aborted — \(reason). No candidate values were written."
            CameraLog.error(detail)
            reports.note(detail)
            // A select can have taken effect even if its response/read-back failed. Restoring the
            // bank and recording that result is separate from claiming no property candidates ran.
            if restoreSelection { await restoreSelector(transport, to: selectorBefore, after: "\(property.debugName) probe") }
            guard session.operationIsCurrent(sessionEpoch) else { return [] }
            reports.persist()
            session.setStatus(.connected)
            return []
        }
        guard selectorBefore != nil else {
            return await abort("the selected bank could not be read before the check")
        }
        do {
            try await transport.writeProperty(FujiPTP.Prop.slotSelector, FujiEncoding.packU16(slot))
        } catch CameraError.ptpError(let code) {
            return await abort("selecting C\(slot) failed (\(message(CameraError.ptpError(code: code))))")
        } catch {
            return await abort("selecting C\(slot) has an unknown outcome (\(message(error))); reconnect before recovery", restoreSelection: false)
        }
        guard session.operationIsCurrent(sessionEpoch) else { return [] }
        let selected = await readSelector(transport)
        guard session.operationIsCurrent(sessionEpoch) else { return [] }
        guard selected == slot else {
            return await abort("asked for C\(slot), but the selected bank reads \(selected.map { "C\($0)" } ?? "nothing")")
        }

        let original: Data?
        do {
            original = try await transport.readProperty(property.rawValue)
        } catch {
            return await abort("the original \(property.debugName) could not be read (\(message(error)))")
        }
        guard session.operationIsCurrent(sessionEpoch) else { return [] }
        if let original {
            guard original.count == 2, let value = FujiEncoding.decodeInt16(original),
                  property != .grain || FujiEncoding.flatToGrain(value) != nil else {
                return await abort("the original \(property.debugName) is not a usable value to restore")
            }
        } else {
            return await abort("the original \(property.debugName) is missing; an empty read does not establish an empty bank")
        }

        var entries: [WriteProbeEntry] = []
        var uncertainSend = false
        for (step, value) in candidates.enumerated() {
            guard session.operationIsCurrent(sessionEpoch) else { return entries }
            var writeError: String?
            do {
                try await transport.writeProperty(property.rawValue, FujiEncoding.packU16(value))
            } catch CameraError.ptpError(let code) {
                writeError = message(CameraError.ptpError(code: code))
            } catch {
                uncertainSend = true
                entries.append(WriteProbeEntry(step: step, wrote: value, writeError: message(error),
                                               readBack: nil, completionUnknown: true))
                break
            }
            guard session.operationIsCurrent(sessionEpoch) else { return entries }
            let readBack = try? await transport.readProperty(property.rawValue)
                .flatMap { $0.count == 2 ? FujiEncoding.decodeInt16($0) : nil }
            guard session.operationIsCurrent(sessionEpoch) else { return entries }
            entries.append(WriteProbeEntry(step: step, wrote: value, writeError: writeError, readBack: readBack))
        }
        guard session.operationIsCurrent(sessionEpoch) else { return entries }

        // The probe's findings outlive the screen that ran it: one log line, one report note.
        let summary = entries.map { "\($0.wrote)→\($0.outcome)" }.joined(separator: ", ")
        CameraLog.info("Write probe: \(property.debugName) on C\(slot) — \(summary)")
        reports.note("write probe \(property.debugName) C\(slot): \(summary)")

        if uncertainSend {
            reports.note("write probe \(property.debugName) C\(slot): stopped after an unconfirmed send. Recovery and selector restoration were not attempted; reconnect before recovering original bytes \(original.map(PTPHex.bytes) ?? "unavailable").")
            reports.persist()
            session.setStatus(.connected)
            return entries
        }

        if let original {
            do {
                // Re-establish the target before cleanup, even though the operation gate also
                // excludes this process's other selector users: the record's client chapter has
                // every bank-content write follow a verified selection, and the gate cannot exclude
                // what is outside this process. A GFX100RF is reported to reset the selector to the
                // body's bank after a bank change on the body; an X-T50 keeps the host's value
                // through one (zgrimz/fujifilm-ptp-reference
                // `docs/11-client-implementation.md#lock-a-whole-operation`, `docs/04-custom-slots.md`).
                try await transport.writeProperty(FujiPTP.Prop.slotSelector, FujiEncoding.packU16(slot))
                guard session.operationIsCurrent(sessionEpoch) else { return entries }
                guard await readSelector(transport) == slot else { throw CameraError.slotSelectIgnored(asked: slot, got: nil) }
                guard session.operationIsCurrent(sessionEpoch) else { return entries }
                if property == .grain, let raw = FujiEncoding.decodeInt16(original),
                   let grain = FujiEncoding.flatToGrain(raw), let model = session.connected?.model {
                    let values = FujiPresetCodec.exactGrainRestore(raw: raw, model: model)
                        ?? [FujiEncoding.grainToFlat(grain)]
                    for value in values {
                        guard session.operationIsCurrent(sessionEpoch) else { return entries }
                        try await transport.writeProperty(property.rawValue, FujiEncoding.packU16(value))
                    }
                } else {
                    try await transport.writeProperty(property.rawValue, original)
                }
            } catch CameraError.ptpError(let code) {
                reports.note("write probe \(property.debugName) C\(slot): restore refused — \(message(CameraError.ptpError(code: code)))")
            } catch {
                guard session.operationIsCurrent(sessionEpoch) else { return entries }
                reports.note("write probe \(property.debugName) C\(slot): restoration outcome unknown — \(message(error)). No further writes were attempted; reconnect before recovering original bytes \(PTPHex.bytes(original)).")
                reports.persist()
                session.setStatus(.connected)
                return entries
            }
            guard session.operationIsCurrent(sessionEpoch) else { return entries }
            let after = try? await transport.readProperty(property.rawValue)
            guard session.operationIsCurrent(sessionEpoch) else { return entries }
            if after != original {
                let semanticOnly = SlotWriteVerification.readBackMatches(property.rawValue, wrote: original, read: after)
                reports.note("write probe \(property.debugName) C\(slot): \(semanticOnly ? "semantic-only restoration; original bytes differ" : "exact restoration could not be verified")")
            }
        }
        // Persist after both restoration attempts so the report includes their read-backs and any
        // uncertainty about the property or selected bank that remains.
        await restoreSelector(transport, to: selectorBefore, after: "\(property.debugName) probe")
        guard session.operationIsCurrent(sessionEpoch) else { return entries }
        reports.persist()
        session.setStatus(.connected)
        return entries
    }

    // MARK: - The selector

    /// The selector's value; see `SlotSelector.current`.
    private func readSelector(_ transport: CameraTransport) async -> Int? {
        await SlotSelector(transport: transport, reports: reports).read().value
    }

    /// Puts the selector back; see `SlotSelector.restore`.
    @discardableResult
    private func restoreSelector(_ transport: CameraTransport, to before: Int?, after what: String) async -> Bool? {
        await SlotSelector(transport: transport, reports: reports).restore(to: before, after: what)
    }

}

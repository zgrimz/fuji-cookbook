import Foundation

/// The guided test's hands: the only part of it that talks to the camera.
///
/// Everything here exists to turn a `CameraServices` call into one of the states a step can be in,
/// and the classification is the hard part. `probeProperties` answers `(slot, [])` both when the
/// slot select failed, which is a fact about the body, and when there is no transport, which is not;
/// it throws `CameraBusy` when the concurrency gate refused it. So nothing here judges an outcome by
/// an empty result: it checks that the camera is ready before calling, takes a refusal from the error
/// the gate throws, and checks the connection after.
@MainActor
enum GuidedTestRunner {

    /// Whether a camera step can proceed, and if not, what the tester should be offered instead.
    enum CameraGate: Equatable {
        case ready
        /// Something else is talking to the camera. Retryable, and nothing to do with this body.
        case busy(String)
        /// The session dropped and the app is trying to get it back by itself.
        case reconnecting
        /// It was connected and isn't any more.
        case lost(String)
        case disconnected

        var isReady: Bool { self == .ready }
    }

    static func gate(status: CameraSession.Status, isConnected: Bool,
                     isRecovering: Bool = false, isDeciding: Bool = false) -> CameraGate {
        switch status {
        case .connecting:
            return .busy("Connecting…")
        case .working(let message):
            // Recovery publishes itself through the same status as an ordinary operation; the
            // difference matters, because one is worth waiting out and the other means the cable.
            // Decided by `CameraConnector.isRecovering`, not by the status text: a substring match on
            // "reconnect" would file an expected removal's "Waiting for the camera to come back…"
            // as an operation.
            return isRecovering ? .reconnecting : .busy(message)
        case .failed(let message):
            return isConnected ? .busy(message) : .lost(message)
        case .connected:
            // The connect reports `.connected` before the slot read that decides write access, and
            // again after it, a moment before the decision is filed. A step that read the badge or
            // the write access in either gap would record a decision not yet made.
            guard isConnected else { return .disconnected }
            return isDeciding ? .busy("Reading the camera's slots…") : .ready
        case .disconnected:
            return .disconnected
        }
    }

    static func gate(_ camera: CameraServices) -> CameraGate {
        gate(status: camera.session.status, isConnected: camera.session.isConnected,
             isRecovering: camera.connector.isRecovering,
             isDeciding: camera.session.connected?.writeAccess == .undecided)
    }

    /// The camera services' state as the flow's rules see it.
    static func facts(_ camera: CameraServices) -> CameraFacts {
        let connected = camera.session.connected
        let model = connected?.model
        return CameraFacts(
            isConnected: camera.session.isConnected,
            isRecognized: connected.map { !$0.isUnsupported } ?? false,
            hasSlotProtocol: camera.session.maySelectSlots,
            canWrite: connected?.isWritable ?? false,
            canConvert: camera.session.canConvert,
            canHarvestProfile: camera.conversion.canHarvestProfile,
            hasOccupiedSlots: camera.slotReader.slots.contains(where: \.isOccupied),
            hasFilmSimulationDial: model?.hasFilmSimulationDial ?? false,
            // The report is authoritative about the transport while something is attached —
            // `model?.id == demoModelID` misses a faulted demo carrying a real body's product name.
            //
            // With nothing attached it is authoritative about the *last* camera, which is a
            // different claim: the stored report outlives the connection, so a phone that once
            // tried the Demo Camera would report "demo" for every later session until a real
            // connect rewrote it. Both of these describe the camera in hand; there isn't one.
            transport: camera.session.isConnected ? camera.reports.report?.camera.transport : nil,
            productName: connected?.productName,
            modelID: connected?.registryModel?.id,
            identification: connected?.identification.reportLabel,
            verification: model?.verification.reportLabel,
            firmwareVersion: connected?.firmwareVersion,
            serialHash: camera.session.isConnected ? camera.reports.report?.camera.serialHash : nil,
            badge: connected?.capabilityBadge.text)
    }

    // MARK: Steps

    /// Make sure the slots are read, without re-reading them for the sake of it.
    ///
    /// Gated on `SlotReader.hasRead`, not on `slots.isEmpty`: an empty slot list is also what a body
    /// with no slot protocol always has, and its completed sweep counts as the read. A failed walk
    /// is read again.
    @discardableResult
    static func ensureSlots(_ camera: CameraServices) async -> CameraGate {
        let gate = gate(camera)
        guard gate.isReady else { return gate }
        guard !camera.slotReader.hasRead else { return .ready }
        do throws(CameraBusy) {
            try await camera.slotReader.requestRefresh()
        } catch {
            return .busy("Another camera operation is still running.")
        }
        return Self.gate(camera)
    }

    /// Retain the read-stage evidence before any camera mutation. Never relabel a later
    /// post-write snapshot as the initial state when reopening a completed step.
    static func captureReadEvidence(_ camera: CameraServices, session: inout GuidedTestSession) {
        guard GuidedTestFlow.describesSameBody(stored: session, facts: facts(camera)),
              session.writePass?.trials.contains(where: { $0.pushedAt != nil }) != true,
              session.grainProbe == nil || session.grainProbe?.state == .notRun,
              let report = camera.reports.report else { return }
        if session.initialSlots == nil, session.propertyReport?.state == .ran {
            session.initialSlots = report.slots
        }
        if let sweep = report.propertySweep, let evidenceID = sweep.evidenceID,
           session.propertyReport?.evidenceID == evidenceID {
            session.propertySweep = sweep
        }
    }

    /// Capture the original once, before any slot mutation, and verify it is on disk. A legacy
    /// session that has already written cannot safely call today's contents its original.
    static func prepareRecovery(_ camera: CameraServices,
                                session: inout GuidedTestSession) -> String? {
        guard gate(camera).isReady else { return "Reconnect the camera and wait for its readings to finish." }
        if let failure = slotReadFailure(camera.reports.report?.slots, model: camera.session.model,
                                       maySelectSlots: camera.session.maySelectSlots) { return failure }
        let currentFacts = facts(camera)
        guard GuidedTestFlow.describesSameBody(stored: session, facts: currentFacts) else {
            return "Reconnect the camera this test started with."
        }
        let key = session.recoveryBaselineID ?? session.id
        if let existing = GuidedRecoveryStore.load(sessionID: key) {
            guard existing.matches(currentFacts) else { return "The saved original belongs to a different camera." }
            session.recoveryBaselineID = key
            return GuidedTestStore.save(session) == nil ? "The test could not be saved. Nothing will be written." : nil
        }
        guard session.recoveryBaselineID == nil else {
            return "The original recovery copy is unavailable. Use your exported backup; today's settings cannot replace the original."
        }
        if GuidedRecoveryStore.unresolvedRecords().contains(where: {
            $0.sessionID != session.id && $0.matches(currentFacts)
        }) {
            return "An earlier test still has camera changes to resolve. Restore or explicitly keep those changes before starting another writing test."
        }
        let previousWrites = session.writePass?.trials.contains(where: { $0.pushedAt != nil || $0.outcome != nil }) == true
        guard !previousWrites, session.grainProbe?.state != .ran, session.grainProbe?.state != .failed else {
            return "This older test already attempted a write. Its current settings cannot be saved as the original; use the pre-test backup."
        }
        guard let backup = camera.slotReader.slotBackup else { return "Read the camera's slots before saving their originals." }
        if let reason = GuidedTestFlow.readCheckpointBlockReason(session: session,
                                                                 hasOccupiedSlots: backup.slots.contains(where: \.occupied)) {
            return reason
        }
        let record = GuidedRecoveryRecord(sessionID: session.id, backup: backup, transport: currentFacts.transport)
        guard GuidedRecoveryStore.create(record) else { return "The recovery copy could not be saved. Nothing will be written." }
        session.recoveryBaselineID = session.id
        guard GuidedTestStore.save(session) != nil else { return "The test could not be saved. Nothing will be written." }
        return nil
    }

    enum MutationKind { case grainProbe, recipeWrite }

    /// A navigation shortcut must never bypass this operation-time check.
    static func mutationBlockReason(_ camera: CameraServices, session: GuidedTestSession?,
                                    slot: Int, kind: MutationKind) -> String? {
        guard let session else { return "Open the Camera Test and complete its preparation before writing." }
        guard gate(camera).isReady else { return "The camera is not ready. Nothing was written." }
        let currentFacts = facts(camera)
        guard currentFacts.canWrite else { return "Writing is not enabled for this camera." }
        if let failure = slotReadFailure(camera.reports.report?.slots, model: camera.session.model,
                                       maySelectSlots: camera.session.maySelectSlots) { return failure }
        guard GuidedTestFlow.describesSameBody(stored: session, facts: currentFacts) else {
            return "Reconnect the camera this test started with."
        }
        guard slot > 0, camera.slotReader.slots.contains(where: { $0.index == slot }) else { return "Choose an available camera slot first." }
        if currentFacts.modelID == "X-M5", !session.hasConfirmedStillBank(slot) {
            return "Confirm that C\(slot) is assigned to STILL in the camera's CUSTOM MODE SETTING before changing that bank."
        }
        guard let key = session.recoveryBaselineID,
              let recovery = GuidedRecoveryStore.load(sessionID: key), recovery.sessionID == session.id else {
            return "Save the original recovery copy before writing."
        }
        guard recovery.matches(currentFacts), recovery.backup.slots.contains(where: { $0.index == slot }) else {
            return "The original recovery copy does not match this camera and slot."
        }
        if let reason = GuidedTestFlow.readCheckpointBlockReason(session: session,
                                                                 hasOccupiedSlots: recovery.backup.slots.contains(where: \.occupied)) {
            return reason
        }
        guard session.writePass?.consentAt != nil else { return "Confirm the writing step before changing camera settings." }
        if currentFacts.hasFilmSimulationDial, session.writePass?.dialConfirmed != true {
            return "Set the Film Simulation dial to C and confirm it before writing."
        }
        if kind == .grainProbe, session.grainConsentAt == nil { return "Choose Check Grain Settings before the temporary write." }
        if kind == .grainProbe,
           session.writePass?.trials.contains(where: { $0.pushedAt != nil || $0.hasAcceptedWrite }) == true {
            return "This test has already written a recipe. Finish recovery and start a new test to check grain."
        }
        if kind == .grainProbe,
           let original = recovery.backup.slots.first(where: { $0.index == slot }), original.occupied,
           original.properties[PTPHex.code(FujiPTP.PresetProp.grain.rawValue)]
            .flatMap(Data.init(hexString:)).flatMap(FujiEncoding.decodeInt16).flatMap(FujiEncoding.flatToGrain) == nil {
            return "The original grain setting wasn't read successfully. Read the camera again before checking grain."
        }
        if kind == .recipeWrite, session.grainProbe?.state == .failed {
            return "The grain check couldn't confirm restoration. Review recovery options before another write."
        }
        if kind == .recipeWrite, session.isContinuous, session.grainProbe?.state != .ran {
            return "Complete Check Grain Settings before writing a test recipe."
        }
        return nil
    }

    private static func recordMutationIntent(session: GuidedTestSession?, slot: Int) -> Bool {
        guard let session, let key = session.recoveryBaselineID,
              GuidedTestStore.save(session) != nil else { return false }
        return GuidedRecoveryStore.markTouched(sessionID: key, slot: slot)
    }

    /// The property report: what this body holds for every preset property, and — where it answers
    /// `GetDevicePropDesc` — which values it says it will accept.
    static func runPropertyReport(_ camera: CameraServices,
                                  slot: Int) async -> GuidedTestSession.ProbeOutcome {
        guard gate(camera).isReady else {
            return .init(state: .refused, detail: "The camera was busy. Nothing was read.")
        }
        let previousSweepID = camera.reports.report?.propertySweep?.evidenceID
        let result: (slot: Int, probes: [PropertyProbe])
        do throws(CameraBusy) {
            result = try await camera.diagnostics.probeProperties(slot: slot)
        } catch {
            var refused = GuidedTestSession.ProbeOutcome(state: .refused,
                                                         detail: "Another camera operation was still running. Nothing was read.")
            refused.evidenceID = nil   // nothing was swept, so no sweep is this attempt's evidence
            return refused
        }
        func recorded(_ outcome: GuidedTestSession.ProbeOutcome) -> GuidedTestSession.ProbeOutcome {
            var outcome = outcome
            if let sweep = camera.reports.report?.propertySweep,
               let id = sweep.evidenceID, id != previousSweepID {
                outcome.capturedAt = sweep.capturedAt ?? outcome.capturedAt
                outcome.evidenceID = id
            } else {
                outcome.evidenceID = nil
            }
            return outcome
        }
        if let failure = failureDetail(camera) {
            return recorded(.init(state: .failed, slot: result.slot, detail: failure))
        }
        // Reached only with no transport while the session still reads as connected: a refused
        // select sets the session's status, which `failureDetail` reports above.
        guard !result.probes.isEmpty else {
            return recorded(.init(state: .failed, slot: result.slot,
                                  detail: "The camera returned nothing for the property report."))
        }
        let count = result.probes.filter { $0.value != nil }.count
        if let failure = slotReadFailure(camera.reports.report?.slots, model: camera.session.model,
                                       maySelectSlots: camera.session.maySelectSlots)
            ?? propertyReadFailure(result.probes) {
            return recorded(.init(state: .failed, slot: result.slot, count: count, detail: failure))
        }
        if camera.session.maySelectSlots {
            guard result.slot == slot,
                  result.probes.first(where: { $0.code == FujiPTP.Prop.slotSelector })?.value
                    .flatMap(FujiEncoding.decodeUInt16).map(Int.init) == slot else {
                return recorded(.init(state: .failed, slot: result.slot, count: count,
                             detail: "The property report could not verify that the requested slot was selected."))
            }
        }
        return recorded(.init(state: .ran, slot: result.slot,
                     count: count,
                     readOnly: camera.reports.report?.propertySweep?.readOnly))
    }

    /// A connected status only proves the session is open. The walk can stop early or continue
    /// after a property error, and those findings must not authorize a guided write.
    static func slotReadFailure(_ summary: CameraCompatibilityReport.SlotSummary?,
                                model: CameraModel?, maySelectSlots: Bool) -> String? {
        guard maySelectSlots else { return nil }
        guard let summary, let found = summary.probedSlotCount else {
            return "The camera's slots have not been read successfully."
        }
        let documented = model?.documentedSlotCount ?? summary.documentedSlotCount
        if let documented, found != documented {
            return "The camera answered \(found) slots; this model documents \(documented). Share this unexpected reading before writing."
        }
        if summary.selectorRestored == false {
            return "The slot read could not restore the camera's selected bank. Share this finding before writing."
        }
        for read in summary.reads {
            if !read.selected {
                let boundaryCode = responseCode(in: read.selectError)
                let expectedBoundary = documented.map { found == $0 && read.slot == $0 + 1 } == true
                    && (boundaryCode == 0x200A || boundaryCode == 0x201C)
                if !expectedBoundary {
                    return "C\(read.slot) could not be selected and verified: \(read.selectError ?? "no verified reading")."
                }
            }
            for property in read.properties where property.error != nil {
                let response = responseCode(in: property.responseCode)
                if response != 0x200A && response != 0x2005 {
                    return "C\(read.slot) could not read \(property.name ?? property.code): \(property.error ?? "read failed")."
                }
            }
        }
        return nil
    }

    /// Unsupported properties are useful findings. A failed actual value read is incomplete
    /// evidence. Descriptor discovery is best-effort: multiple bodies refuse it wholesale, and
    /// its failure must not invalidate successfully read settings. The report retains it separately.
    static func propertyReadFailure(_ probes: [PropertyProbe]) -> String? {
        for probe in probes {
            if let error = probe.valueError {
                let response = responseCode(in: error)
                // D183 is a conversion trigger, not a saved recipe value. X-T50 fw 1.32
                // refuses its diagnostic GetValue with 0x2002, just as D185 can refuse before
                // a RAF upload. Keep both refusals in the report without failing clean slot
                // reads. This exception does not apply to writes, timeouts or recipe fields.
                let conversionControl = probe.code == FujiPTP.Prop.rawConvProfile
                    || probe.code == FujiPTP.Prop.startRawConversion
                let expected = response == 0x200A || response == 0x2005
                    || (conversionControl && response == 0x2002)
                if !expected { return "Could not read \(probe.name): \(error)" }
            }
        }
        return nil
    }

    /// Every error string this parses — a slot read's `selectError`, a property read's
    /// `responseCode`, a probe's `valueError` — includes the exact hexadecimal response. No prose
    /// matching is used to turn an arbitrary failure into an expected unsupported-property response.
    private static func responseCode(in message: String?) -> UInt16? {
        guard let message, let marker = message.range(of: "0x", options: .caseInsensitive) else { return nil }
        let digits = message[marker.upperBound...].prefix(4)
        guard digits.count == 4 else { return nil }
        return UInt16(digits, radix: 16)
    }

    /// The profile harvest: send one RAF the camera shot, read what it says about it, stop.
    ///
    /// `.failed` for a refused upload rather than `.ran`, because the one cause the app can name
    /// — a RAF from another body — is the tester's to fix, and a step that ends on "try again"
    /// is worth more than one that files it as a finding.
    static func runProfileHarvest(_ camera: CameraServices, raf: Data) async -> GuidedTestSession.ProbeOutcome {
        guard camera.conversion.canHarvestProfile else {
            return .init(state: .notWritable, detail: "This body can't be sent a RAF.")
        }
        guard gate(camera).isReady else {
            return .init(state: .refused, detail: "The camera was busy. Nothing was sent.")
        }
        let harvested: RawConversionService.ProfileHarvestOutcome?
        do throws(CameraBusy) {
            harvested = try await camera.conversion.harvestConversionProfile(raf: raf)
        } catch {
            return .init(state: .refused, detail: "Another camera operation was still running. Nothing was sent.")
        }
        if let failure = failureDetail(camera) {
            return .init(state: .failed, detail: failure)
        }
        // Not expected: the harvest answers nil only when `canHarvestProfile` is false, which the
        // guard at the top of this function has just ruled out.
        guard let outcome = harvested else {
            return .init(state: .notWritable, detail: "This body can't be sent a RAF.")
        }
        if outcome.record.uploadOutcome != "accepted" {
            return .init(state: .failed, detail: outcome.summary)
        }
        return .init(state: .ran, detail: outcome.summary)
    }

    /// The D195 grain probe: a temporary write, and the only thing that settles whether this body's
    /// grain read-back means what the X-T50's does.
    static func runGrainProbe(_ camera: CameraServices,
                              slot: Int, session: GuidedTestSession? = nil) async -> GuidedTestSession.ProbeOutcome {
        if let refused = GuidedTestFlow.grainProbeState(facts: facts(camera)) { return refused }
        guard gate(camera).isReady else {
            return .init(state: .refused, detail: "The camera was busy. Nothing was written.")
        }
        if let reason = mutationBlockReason(camera, session: session, slot: slot, kind: .grainProbe) {
            return .init(state: .refused, slot: slot, detail: reason)
        }
        guard recordMutationIntent(session: session, slot: slot) else {
            return .init(state: .refused, slot: slot, detail: "The recovery record could not be saved. Nothing was written.")
        }
        let notesBefore = camera.reports.report?.notes.count ?? 0
        let entries: [WriteProbeEntry]
        do throws(CameraBusy) {
            entries = try await camera.diagnostics.probeWriteValues(
                slot: slot, property: .grain, candidates: CameraDiagnostics.grainProbeCandidates)
        } catch {
            return .init(state: .refused, slot: slot, detail: "The camera was busy. Nothing was written.")
        }
        if let failure = failureDetail(camera) {
            return .init(state: .failed, slot: slot, detail: failure)
        }
        guard !entries.isEmpty else {
            // An aborted probe leaves a note saying why; a precondition that stopped it before any
            // candidate may not.
            let abortNote = (camera.reports.report?.notes ?? []).dropFirst(notesBefore)
                .first(where: { $0.hasPrefix("write probe ") && $0.contains(": aborted — ") })
            return .init(state: .failed, slot: slot,
                         detail: abortNote ?? "The grain probe stopped before writing any value. Reconnect the camera and try again.")
        }
        let restoreNotes = Array((camera.reports.report?.notes ?? []).dropFirst(notesBefore))
        // The probe's own verdict on its cleanup, in the words `probeWriteValues` notes it in. A
        // semantic-only restoration (grain Off written as 1, read back as 6 or 7) is not a problem.
        let restoreProblems = ["restore refused", "restoration outcome unknown",
                               "exact restoration could not be verified", "stopped after an unconfirmed send"]
        if let problem = restoreNotes.first(where: { note in restoreProblems.contains { note.contains($0) } }) {
            return .init(state: .failed, slot: slot, count: entries.count, detail: problem)
        }
        // A new slot read verifies the grain restoration independently of the probe's optimistic
        // completion. A camera that disappears here leaves recovery pending, never green.
        let readStartedAt = CameraCompatibilityReport.timestamp()
        let read = try? await camera.slotReader.requestRefresh()
        guard read != nil, gate(camera).isReady,
              camera.reports.report?.slots.readAt.map({ $0 >= readStartedAt }) == true,
              slotReadFailure(camera.reports.report?.slots, model: camera.session.model,
                                       maySelectSlots: camera.session.maySelectSlots) == nil else {
            return .init(state: .failed, slot: slot, count: entries.count,
                         detail: "The grain probe ran, but its restoration could not be checked.")
        }
        guard let session, let key = session.recoveryBaselineID,
              let recovery = GuidedRecoveryStore.load(sessionID: key), recovery.sessionID == session.id,
              recovery.matches(facts(camera)), GuidedTestFlow.describesSameBody(stored: session, facts: facts(camera)),
              let original = recovery.backup.slots.first(where: { $0.index == slot }) else {
            return .init(state: .failed, slot: slot, count: entries.count,
                         detail: "The original backup could not be verified. Review recovery options before continuing.")
        }
        let code = FujiPTP.PresetProp.grain.rawValue
        let expected = original.properties[PTPHex.code(code)].flatMap(Data.init(hexString:))
        let actual = camera.slotReader.slots.first(where: { $0.index == slot })?.rawProperties[code]
        let restored = original.occupied
            ? expected.map { SlotWriteVerification.readBackMatches(code, wrote: $0, read: actual) } == true
            : camera.slotReader.slots.first(where: { $0.index == slot })?.isOccupied == false
        guard restored else {
            return .init(state: .failed, slot: slot, count: entries.count,
                         detail: "The original grain setting could not be verified after the probe. Recovery is still available.")
        }
        guard GuidedRecoveryStore.recordDisposition(sessionID: key, slot: slot, outcome: .restored) else {
            return .init(state: .failed, slot: slot, count: entries.count,
                         detail: "The original grain setting was read back, but the recovery result could not be saved.")
        }
        return .init(state: .ran, slot: slot, count: entries.count,
                     detail: entries.map { "\($0.wrote)→\($0.outcome)" }.joined(separator: ", "))
    }

    /// Write one test recipe, and capture what the camera accepted for every property.
    ///
    /// The `wrote` map is copied out of the push record here rather than read back at the power
    /// cycle, because the power cycle recreates the report — `adoptGuidedTests` restores it, but the
    /// comparison that decides whether a tester's recipe survived should not depend on a carry
    /// forward having worked.
    ///
    /// Only what the camera took goes into it. A property it refused, or read back as something
    /// else, is a finding the push record already carries; checking it again after the power cycle
    /// would report the same refusal a second time as "did not persist", which is a different claim
    /// about the body — and the likely one on a fresh bank, where the ISO floor refuses CT Colour's
    /// DR200. `unverified` stays: the camera accepted it and nothing has read it back yet, so the
    /// power-cycle read is its first check.
    ///
    /// Returns the trial *and* the raw result: `push` records the result in the report, but only
    /// `pushBatch` publishes `lastWriteResults`, so a single push has nowhere else to hand the
    /// per-field table the results screen renders.
    static func runPush(_ camera: CameraServices, recipe: GuidedTestRecipes.TestRecipe,
                        slot: Int, session: GuidedTestSession? = nil) async -> (trial: GuidedTestSession.PushTrial, result: SlotWriteResult?) {
        var trial = GuidedTestSession.PushTrial(recipe: recipe.id, recipeName: recipe.name, slot: slot)
        trial.id = UUID().uuidString
        trial.recipeVersion = 1
        trial.recipeSettings = recipe.settings
        // The slot preparation was answered at Choose a slot, on the trial this value replaces.
        // It describes that slot, so it travels only when this push is for the same one.
        if let prepared = session?.writePass?.trial, prepared.slot == slot {
            trial.preparation = prepared.preparation
            trial.preparationConfirmedAt = prepared.preparationConfirmedAt
        }
        if let reason = mutationBlockReason(camera, session: session, slot: slot, kind: .recipeWrite) {
            trial.outcome = .notWritten
            trial.refusalReason = reason
            return (trial, nil)
        }
        guard recordMutationIntent(session: session, slot: slot) else {
            trial.outcome = .notWritten
            trial.refusalReason = "The recovery record could not be saved. Nothing was written."
            return (trial, nil)
        }
        let pushedAt = CameraCompatibilityReport.timestamp()
        let connectionStartedAt = camera.reports.report?.generatedAt
        let connectionID = camera.reports.report?.connectionID
        let name = camera.session.model.map { recipe.slotName(for: $0) } ?? recipe.name
        let result = await camera.slotWriter.push(settings: recipe.settings, name: name, toSlot: slot)
        // A push the operation gate refused sent nothing, so it is filed like the refusals above:
        // no push time, which keeps the recipe retryable and the slot out of what was written.
        if let busy = result.refusedBy {
            trial.outcome = .notWritten
            trial.refusalReason = busy.localizedDescription
            return (trial, nil)
        }
        trial.pushedAt = pushedAt
        trial.connectionStartedAt = connectionStartedAt
        trial.connectionID = connectionID

        trial.outcome = result.outcome
        trial.nameApplied = result.nameWritten ? result.nameApplied : nil
        trial.refusalReason = result.errorMessage
        // The returned result belongs to this attempt. Looking up "the latest push to this slot"
        // can accidentally adopt an older successful write when the concurrency gate refused this
        // call without appending a report entry.
        for field in result.fields where field.code != 0 {
            guard field.outcome == .written || field.outcome == .unverified,
                  let wrote = field.wrote else { continue }
            trial.wrote[PTPHex.code(field.code)] = PTPHex.bytes(wrote)
        }
        return (trial, result)
    }

    /// Re-establish the session the power-cycle step asked the tester to break.
    static func reconnect(_ camera: CameraServices, transport: String?) async {
        if transport == "demo" {
            await camera.connector.connectDemo()
        } else {
            await camera.connector.connectHardware()
        }
    }

    /// Fold the session into the report the tester sends.
    ///
    /// Called at step boundaries rather than on every keystroke: the recorder's `persist()`
    /// re-encodes the whole document, up to twelve hundred traced transactions of it, and the
    /// session has its own much cheaper file for the fine-grained saves.
    static func project(_ session: GuidedTestSession, into camera: CameraServices) {
        camera.reports.recordGuidedTest(session, connectedProductName: camera.session.connected?.productName)
    }

    // MARK: Helpers

    /// The message when the camera went away under an operation, or nil when it is still there.
    private static func failureDetail(_ camera: CameraServices) -> String? {
        if case .failed(let message) = camera.session.status { return message }
        return camera.session.isConnected ? nil : "The camera disconnected."
    }
}

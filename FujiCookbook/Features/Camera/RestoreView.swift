import SwiftUI

/// Put one slot back, with the difference shown first.
///
/// The confirmation is not ceremony. A restore takes the identical path through the camera as a
/// push — same select, same name write first, same writes, same read-back — so it carries the same
/// risk on a body whose read/write symmetry nobody has confirmed, and it is invoked at the moment
/// something has already gone wrong. The user is entitled to see exactly what it will write, and
/// entitled to be told where it cannot be faithful.
struct RestoreView: View {
    @Environment(CameraServices.self) private var camera
    @Environment(\.dismiss) private var dismiss

    /// Where the bytes came from. The two differ in how long they last, which is the thing the user
    /// needs to understand, so they are labelled rather than merged.
    enum Source: Equatable {
        /// `pushes[].slotBefore` — free, immediate, and discarded by Clear Diagnostics.
        case lastPush
        /// An exported `CameraBackup` the user holds.
        case backup(name: String)
    }

    /// How a restore ended, for `onFinish`.
    enum Completion: Equatable {
        /// It ran, and this is what the fresh reading found.
        case verified(RestoreVerification.Outcome)
        /// The user left without restoring.
        case canceled
    }

    let slot: Int
    let slotName: String
    let saved: [UInt16: Data]
    let source: Source
    /// What the restore did, for a caller that has to record it — the Camera Test's `restores[]`.
    var onFinish: ((Completion) -> Void)?
    /// Called with `true` as the write starts and `false` when it ends.
    var onWritingChanged: ((Bool) -> Void)?
    /// Checked before the write and again for the final comparison; `false` refuses the restore.
    /// The Camera Test passes whether the connected body is the one it backed up and is ready.
    var canRestore: (() -> Bool)?
    /// False when the original name can't be written exactly: the screen says so, and the result
    /// can only be partial.
    var originalNameRestorable = true
    /// The slot's original name for the final comparison. Nil means `slotName` when the name is
    /// restorable, and no name to compare when it isn't.
    var originalName: String?
    /// The final original-versus-current comparison, for a caller that records it.
    var onVerification: ((RestoreVerification) -> Void)?

    @State private var result: SlotWriteResult?
    @State private var isWriting = false
    @State private var hasReportedOutcome = false
    @State private var blockedMessage: String?

    private var model: CameraModel? { camera.session.model }

    private var plan: (writes: [(code: UInt16, bytes: Data)], fidelity: FujiPresetCodec.RestoreFidelity)? {
        guard let model else { return nil }
        return FujiPresetCodec.encodeRestore(from: saved, model: model,
                                             current: camera.slotReader.slots.first { $0.index == slot }?.rawProperties)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    if !originalNameRestorable {
                        GuidedNoticeCard(title: "The original name cannot be restored",
                                         systemImage: "exclamationmark.circle", tint: Theme.warning,
                                         message: "The settings can be restored, but the slot will be named “\(model?.sanitizedSlotName(from: slotName) ?? slotName)”. The original name cannot be written exactly, so this will remain a partial restoration.")
                    }
                    if let plan, plan.fidelity.hasNotes { fidelityCard(plan.fidelity) }
                    if let plan { changesCard(plan.writes) }
                    if let blockedMessage { Text(blockedMessage).font(.caption).foregroundStyle(Theme.warning) }
                    writeButton
                }
                .padding(18)
            }
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle("Restore C\(slot)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { recordCancellation(); dismiss() }.disabled(isWriting)
                }
            }
            // Dismissing the results ends the restore, so the setter closes this screen too.
            .sheet(item: Binding(get: { result },
                                 set: { if $0 == nil { result = nil; dismiss() } })) { written in
                PushResultsView(results: [written])
            }
        }
        .interactiveDismissDisabled(isWriting)
        .onDisappear { if !isWriting { recordCancellation() } }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sourceHeadline).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            Text(sourceExplanation).font(.caption).foregroundStyle(Theme.ink2)
            Text("This writes to C\(slot) the same way pushing a recipe does. It's the same sequence and the same risk — the difference is that these are the camera's own values.")
                .font(.caption).foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .themedCard(cornerRadius: 16)
    }

    private var sourceHeadline: String {
        switch source {
        case .lastPush: return "Undo the last push to C\(slot)"
        case .backup(let name): return "Restore C\(slot) from \(name)"
        }
    }

    private var sourceExplanation: String {
        switch source {
        case .lastPush:
            return "These are the settings C\(slot) held immediately before Fuji Cookbook last wrote to it. They're remembered on this phone until you use Clear Diagnostics, which erases them — an exported backup is the copy that lasts."
        case .backup:
            return "These are the settings C\(slot) held when you saved this backup."
        }
    }

    /// Names, before anything is written, each place the restore can't put back exactly what was
    /// saved, so a read-back difference afterwards reads as expected rather than as a camera bug.
    private func fidelityCard(_ fidelity: FujiPresetCodec.RestoreFidelity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Restore verification notes", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            if !fidelity.reEncoded.isEmpty {
                Text("\(fidelity.reEncoded.joined(separator: ", ")): this body has no verified sequence for restoring the saved bytes, so Fuji Cookbook restores the visible setting. Remembered values may differ; the final comparison reports that as a partial restoration.")
                    .font(.caption).foregroundStyle(Theme.ink2)
            }
            if !fidelity.notWritable.isEmpty {
                Text("\(fidelity.notWritable.joined(separator: ", ")): saved in a form this app doesn't recognise, so it won't be written at all rather than guessed at. C\(slot) keeps whatever it currently has for those.")
                    .font(.caption).foregroundStyle(Theme.ink2)
            }
            if !fidelity.withheldWhilePriorityActive.isEmpty {
                Text("\(fidelity.withheldWhilePriorityActive.joined(separator: ", ")): these stored values are inactive while D-Range Priority is on. The app will not temporarily turn it off to change them. The final check will report any difference from your original settings.")
                    .font(.caption).foregroundStyle(Theme.ink2)
            }
            if !fidelity.restoredWhileActive.isEmpty {
                Text("\(fidelity.restoredWhileActive.joined(separator: ", ")): the original settings hide these values, but C\(slot) currently exposes them and the camera accepts the write. Fuji Cookbook puts them back first, then restores the setting that hides them, so the slot's stored values match the original.")
                    .font(.caption).foregroundStyle(Theme.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .themedCard(cornerRadius: 16)
    }

    private func changesCard(_ writes: [(code: UInt16, bytes: Data)]) -> some View {
        let current = camera.slotReader.slots.first { $0.index == slot }?.rawProperties ?? [:]
        let changing = writes.filter { current[$0.code] != $0.bytes }
        return VStack(alignment: .leading, spacing: 8) {
            Theme.SectionLabel("What changes").padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 6) {
                if changing.isEmpty {
                    Text("Nothing — C\(slot) already matches this copy.")
                        .font(.caption).foregroundStyle(Theme.ink2)
                } else {
                    ForEach(changing.indices, id: \.self) { index in
                        let write = changing[index]
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(FujiPTP.PresetProp(rawValue: write.code)?.debugName
                                 ?? String(format: "0x%04X", write.code))
                                .font(.caption)
                            Spacer(minLength: 8)
                            Text("\(PTPHex.bytes(current[write.code] ?? Data())) → \(PTPHex.bytes(write.bytes))")
                                .font(.caption2.monospaced()).foregroundStyle(Theme.ink3)
                        }
                    }
                }
                Text("\(writes.count) setting write\(writes.count == 1 ? "" : "s") will be sent; \(slotName.isEmpty ? "the slot's name is cleared first, since the original had none" : "the name “\(slotName)” goes first"), as X RAW Studio writes it.")
                    .font(.caption2).foregroundStyle(Theme.ink3).padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .themedCard(cornerRadius: 16)
        }
    }

    private var writeButton: some View {
        Button {
            Task {
                guard !isWriting, GuidedTestRunner.gate(camera).isReady,
                      camera.slotWriter.canPush, let currentPlan = plan, canRestore?() != false else {
                    blockedMessage = "The original cannot be restored to this camera right now. Reconnect the correct camera and try again."
                    return
                }
                isWriting = true
                onWritingChanged?(true)
                blockedMessage = nil
                let beganAt = CameraCompatibilityReport.timestamp()
                let outcome = await camera.slotWriter.restore(saved, name: slotName, toSlot: slot)
                let finalReadSucceeded = GuidedTestRunner.gate(camera).isReady && canRestore?() != false
                    && GuidedTestRunner.slotReadFailure(camera.reports.report?.slots, model: camera.session.model,
                                       maySelectSlots: camera.session.maySelectSlots) == nil
                    && camera.reports.report?.slots.readAt.map { $0 >= beganAt } == true
                let verification = Self.verifyRestore(
                    outcome, saved: saved, current: camera.slotReader.slots.first { $0.index == slot },
                    fidelity: currentPlan.fidelity,
                    cameraReady: finalReadSucceeded,
                    expectedName: camera.session.model?.supportsSlotNaming == true
                        ? (slotName.isEmpty ? "" : camera.session.model?.sanitizedSlotName(from: slotName)) : nil,
                    originalNameRestorable: originalNameRestorable,
                    originalName: originalName ?? (originalNameRestorable ? slotName : nil),
                    readAt: camera.reports.report?.slots.readAt)
                let completion = verification.outcome
                hasReportedOutcome = true
                onVerification?(verification)
                onFinish?(.verified(completion))
                isWriting = false
                onWritingChanged?(false)
                var displayed = outcome
                if outcome.outcome == .applied, completion != .applied {
                    displayed.outcome = completion == .couldNotVerify ? .unknown : .partiallyApplied
                    displayed.errorMessage = completion == .couldNotVerify
                        ? "The restore ran, but a fresh reading of the original settings could not be verified."
                        : "Some original settings or the original slot name could not be restored and verified."
                } else if completion == .applied, outcome.outcome == .partiallyApplied {
                    // The property rows preserve their command refusals. The headline describes
                    // the independently verified original state, rather than a refused no-op.
                    displayed.outcome = .applied
                    displayed.errorMessage = nil
                    displayed.notes.append("Every original setting and the original name were verified after restoring. Some commands were refused; their results remain listed below.")
                }
                result = displayed
            }
        } label: {
            Label(isWriting ? "Restoring…" : "Restore C\(slot)", systemImage: "arrow.uturn.backward")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent))
        }
        .buttonStyle(.plain)
        .disabled(isWriting || !GuidedTestRunner.gate(camera).isReady || !camera.slotWriter.canPush || plan == nil || canRestore?() == false)
    }

    private func recordCancellation() {
        guard !hasReportedOutcome, !isWriting else { return }
        hasReportedOutcome = true
        onFinish?(.canceled)
    }

    /// Command acceptance and restoration are separate evidence: even a refused write may leave
    /// the saved value in place. Require a fresh, complete original-vs-current comparison to pass.
    nonisolated static func verifyRestore(_ result: SlotWriteResult, saved: [UInt16: Data],
                                          current: CameraSlot?, fidelity: FujiPresetCodec.RestoreFidelity,
                                          cameraReady: Bool, expectedName: String?,
                                          originalNameRestorable: Bool = true,
                                          originalName: String? = nil, readAt: Date? = nil,
                                          at: Date = CameraCompatibilityReport.timestamp()) -> RestoreVerification {
        let originalName = originalName ?? (originalNameRestorable ? expectedName : nil)
        let fresh = cameraReady && current != nil && !saved.isEmpty
        let fields = saved.keys.sorted().map { code -> RestoreVerification.Field in
            let bytes = saved[code]!
            let read = current?.rawProperties[code]
            return .init(code: PTPHex.code(code), original: PTPHex.bytes(bytes),
                         current: read.map(PTPHex.bytes), matches: read == bytes)
        }
        // An unnamed slot reads back with no resolved name, which is what an empty original asks for.
        let nameMatches: Bool? = expectedName != nil && originalName != nil && fresh
            ? (current?.resolvedName ?? "") == originalName : nil
        var reasons: [String] = []
        for field in result.fields {
            switch field.outcome {
            case .rejected(let code):
                let response = code.map { " (\(PTPHex.code($0)))" } ?? ""
                reasons.append("\(field.field) \(PTPHex.code(field.code)) write was refused\(response).")
            case .mismatched(let wrote, let read):
                reasons.append("\(field.field) command read-back differed: wrote \(PTPHex.bytes(wrote)), read \(read.map(PTPHex.bytes) ?? "nothing").")
            case .unverified:
                reasons.append("\(field.field) command read-back was unverified.")
            case .outcomeUnknown:
                reasons.append("\(field.field) was submitted without a confirmed command outcome.")
            case .notAttempted:
                reasons.append("\(field.field) write was not attempted.")
            case .written: break
            }
        }
        for name in fidelity.notWritable {
            reasons.append("\(name) was not written because its saved encoding is unknown; the final bytes are checked separately.")
        }
        for name in fidelity.withheldWhilePriorityActive {
            reasons.append("\(name) was not written while D-Range Priority was active; the final bytes are checked separately.")
        }
        let outcome: RestoreVerification.Outcome
        if result.outcome == .notWritten {
            outcome = .notWritten
            reasons.append(result.errorMessage ?? "The restore did not write to the camera.")
        } else if !fresh || result.outcome == .unknown || fields.contains(where: { $0.current == nil }) {
            outcome = .couldNotVerify
            reasons.append("A fresh, complete reading after the restore could not be verified.")
            for field in fields where field.current == nil { reasons.append("\(field.code) could not be read after the restore.") }
        } else {
            for field in fields where !field.matches {
                reasons.append("\(field.code): original \(field.original), now \(field.current ?? "unreadable").")
            }
            let grainCode = FujiPTP.PresetProp.grain.rawValue
            if let original = saved[grainCode], let now = current?.rawProperties[grainCode],
               original != now, SlotWriteVerification.readBackMatches(grainCode, wrote: original, read: now) {
                reasons.append("Grain was restored semantically, but its remembered size differs from the saved bank. Exact restoration was not verified.")
            }
            let originalNameVerified = expectedName == nil ? originalNameRestorable : nameMatches == true
            if !originalNameVerified {
                reasons.append(originalName == nil
                    ? "The original slot name was unavailable and cannot be verified."
                    : "The current slot name does not match the original name.")
            }
            outcome = fields.allSatisfy(\.matches) && originalNameVerified ? .applied : .partiallyApplied
            if outcome == .applied, result.outcome != .applied {
                reasons.append("Despite the command outcome, every original setting and the original name that can be checked match the fresh reading.")
            }
        }
        return .init(at: at, readAt: readAt, outcome: outcome, commandOutcome: result.outcome,
                     freshReadSucceeded: fresh && result.outcome != .unknown && result.outcome != .notWritten
                        && !fields.contains(where: { $0.current == nil }),
                     originalName: originalName, expectedName: expectedName, currentName: current?.resolvedName,
                     nameMatches: nameMatches, originalNameRestorable: originalNameRestorable,
                     fields: fields, reasons: reasons)
    }
}

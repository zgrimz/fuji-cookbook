import SwiftUI
import UIKit

/// The camera's own account of one slot: for every preset property, the value it holds and, where
/// the body answers `GetDevicePropDesc`, the values it says it accepts.
///
/// The value encodings are reverse-engineered and per-model (zgrimz/fujifilm-ptp-reference
/// `docs/03-encodings.md`), so this screen reads the evidence off the hardware instead of inferring
/// it. Many bodies, the X-T50 among them, refuse `GetDevicePropDesc` for bank settings; the grain
/// and Dynamic Range write probes below answer the accepted-values question for those by writing
/// and reading back. Copy and Share produce a plain-text report for an issue.
struct CameraPropertyReportView: View {
    @Environment(CameraServices.self) private var camera
    @Environment(\.dismiss) private var dismiss

    /// The last property read, with the slot `probeProperties` reported back: the picked slot when
    /// the app selected it, and the camera's own selection when it didn't.
    struct Read {
        let slot: Int
        let probes: [PropertyProbe]
    }

    /// One write probe's results, with the slot it ran on.
    struct ProbeRun {
        let slot: Int
        let entries: [WriteProbeEntry]
    }

    @State private var slot: Int = 1
    @State private var lastRead: Read?
    @State private var isRunning = false

    @State private var grainProbe: ProbeRun?
    @State private var isProbingGrain = false

    @State private var drProbe: ProbeRun?
    @State private var isProbingDR = false

    /// The last run the operation gate refused, which sent the camera nothing.
    @State private var refusal: CameraBusy?

    /// Nil when the app has no idea how many slots this body has — the unrecognized-body state,
    /// where a picker would offer slots that may not exist on a camera the app never selects a slot
    /// on.
    private var slotCount: Int? { camera.slotReader.effectiveSlotCount > 0 ? camera.slotReader.effectiveSlotCount : nil }

    /// Whether this body is one the app writes *recipes* to. Gates both write probes: they write
    /// real values into a property whose encoding is the thing in question.
    private var mayWrite: Bool { camera.session.connected?.isWritable ?? false }

    /// Whether the app may put the camera on a chosen slot. A wider set than `mayWrite`: a
    /// read-only body that has slots still gets them read that way, so the report can aim at one.
    /// Only a body with no slot protocol — or none the app recognizes — degrades to whichever slot
    /// the camera already had.
    private var maySelect: Bool { camera.session.maySelectSlots }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let refusal {
                    Text(refusal.localizedDescription)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink2)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .themedCard(cornerRadius: 16)
                }
                if let lastRead, !isRunning {
                    if lastRead.probes.isEmpty {
                        Text("The camera returned nothing. If the session dropped, reconnect and try again.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink2)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .themedCard(cornerRadius: 16)
                    } else {
                        resultsCard(lastRead)
                        exportButtons(lastRead)
                    }
                }
                grainProbeCard
                dynamicRangeProbeCard
            }
            .padding(18)
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Property Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
        }
        .onAppear {
            // Default to a slot that has something in it — an empty slot's descriptors say little.
            if let firstOccupied = camera.slotReader.slots.first(where: { $0.isOccupied })?.index { slot = firstOccupied }
        }
    }

    // MARK: Controls

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(maySelect
                 ? "Reads every preset property of one slot and asks the camera which values it accepts. Nothing is written except the slot selection."
                 : "This camera doesn't offer its custom slots over USB, so the slot selector is left alone — this reads whichever slot the camera currently has selected, and writes nothing at all.")
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)

            if maySelect, let slotCount {
                Picker("Slot", selection: $slot) {
                    ForEach(1...slotCount, id: \.self) { index in
                        Text("C\(index)").tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isRunning || isProbingGrain || isProbingDR)
            }

            Button {
                readProperties()
            } label: {
                HStack(spacing: 8) {
                    if isRunning { ProgressView().tint(.white) }
                    Text(isRunning ? "Reading…"
                         : (maySelect ? (lastRead != nil ? "Read Slot C\(slot) Again" : "Read Slot C\(slot)")
                            : (lastRead != nil ? "Read the Selected Slot Again" : "Read the Selected Slot")))
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent))
            }
            .buttonStyle(.plain)
            // Both probes included: a read during a probe would move the slot selector out from
            // under a loop mid-way through writing real values, and the probe's "restore" would
            // land in whichever slot this had selected. `CameraOperationGate` refuses it outright;
            // this stops the app offering it in the first place.
            .disabled(isRunning || isProbingGrain || isProbingDR || !camera.session.isConnected)
            .opacity(camera.session.isConnected ? 1 : 0.45)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(cornerRadius: 16)
    }

    // MARK: Results

    private func resultsCard(_ read: Read) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.SectionLabel("Slot C\(read.slot)")
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(read.probes) { probe in
                    if probe.id != read.probes.first?.id {
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                    row(probe)
                }
            }
            .themedCard(cornerRadius: 16)
        }
    }

    private func row(_ probe: PropertyProbe) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(probe.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(PTPHex.propertyLabel(probe.code))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.ink3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("holds")
                    .font(.caption)
                    .foregroundStyle(Theme.ink3)
                Text(probe.valueSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(probe.currentValueIsOutOfSet ? Theme.warning : Theme.ink2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("accepts")
                    .font(.caption)
                    .foregroundStyle(Theme.ink3)
                Text(probe.allowedSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let descriptor = probe.descriptor {
                Text("\(descriptor.dataTypeName) · \(descriptor.isWritable ? "read/write" : "read-only")")
                    .font(.caption2)
                    .foregroundStyle(Theme.ink3)
            }
            if probe.currentValueIsOutOfSet {
                Text("The value it holds isn’t in the set it says it accepts — our encoding for this field is likely wrong.")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Export

    private func exportButtons(_ read: Read) -> some View {
        CopyShareButtons(copyTitle: "Copy Report", text: Self.reportText(camera: camera.session.connected, read: read))
    }

    /// Plain-text form of the report, for pasting into the protocol notes or an issue.
    nonisolated static func reportText(camera connected: ConnectedCamera?, read: Read) -> String {
        var lines: [String] = ["Fuji Cookbook — camera property report"]
        if let connected {
            lines.append("Camera: \(connected.productName)"
                         + (connected.model.map { " · model \($0.id)" } ?? " · unrecognized model")
                         + (connected.firmwareVersion.map { " · firmware \($0)" } ?? ""))
        }
        lines.append("Slot: C\(read.slot)")
        lines.append("")
        for probe in read.probes {
            lines.append(String(format: "%@  %@", PTPHex.propertyLabel(probe.code), probe.name))
            lines.append("      holds:   \(probe.valueSummary)")
            lines.append("      accepts: \(probe.allowedSummary)")
            if let descriptor = probe.descriptor {
                var meta = "\(descriptor.dataTypeName) · \(descriptor.isWritable ? "read/write" : "read-only")"
                if let factory = descriptor.factoryDefault { meta += " · default \(factory)" }
                if let current = descriptor.current { meta += " · descriptor current \(current)" }
                lines.append("      \(meta)")
            }
            if probe.currentValueIsOutOfSet { lines.append("      ! held value is outside the accepted set") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Grain write probe (D195)

    /// Replaced by an explanation on a body the app doesn't write to. The probe issues real
    /// `SetDevicePropValue`s, so offering the button there would contradict the sentence at the top
    /// of this very screen. Its result is the evidence for whether comparing D195 by decoded meaning
    /// (`SlotWriteVerification.readBackMatches`) holds on a body, which is why it can be shared as
    /// well as copied.
    @ViewBuilder
    private var grainProbeCard: some View {
        if !mayWrite {
            Text("The grain write probe is only offered on cameras Fuji Cookbook writes to. It works by writing real values and reading back what stuck, which isn't something to do to a body whose encodings aren't known.")
                .font(.caption)
                .foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        } else {
            WriteProbeCard(
                title: "Grain Write Probe (D195)",
                explanation: "Writes each value 0–8 to Grain Effect on the selected slot and reads back what stuck. Runs in the slot's edit buffer — the slot itself isn't committed (no name write) and the original value is restored afterwards.",
                buttonTitle: "Probe Grain Values on C\(slot)",
                isProbing: isProbingGrain,
                isDisabled: isProbingGrain || isProbingDR || isRunning || !camera.session.isConnected,
                entries: grainProbe?.entries ?? [],
                exportText: grainProbe.map { Self.grainProbeText(camera: camera.session.connected, run: $0) }
                    ?? "",
                run: runGrainProbe)
        }
    }

    nonisolated static func grainProbeText(camera connected: ConnectedCamera?, run: ProbeRun) -> String {
        var lines = ["Fuji Cookbook — D195 grain write probe", "Slot: C\(run.slot)"]
        if let connected { lines.insert("Camera: \(connected.productName)", at: 1) }
        lines += run.entries.map { "wrote \($0.wrote): \($0.outcome)" }
        return lines.joined(separator: "\n")
    }

    private func runGrainProbe() {
        guard !isProbingGrain else { return }
        isProbingGrain = true
        let probedSlot = slot
        refusal = nil
        Task {
            do throws(CameraBusy) {
                let entries = try await camera.diagnostics.probeWriteValues(
                    slot: probedSlot, property: .grain, candidates: CameraDiagnostics.grainProbeCandidates)
                grainProbe = ProbeRun(slot: probedSlot, entries: entries)
            } catch {
                grainProbe = nil
                refusal = error
            }
            isProbingGrain = false
        }
    }

    // MARK: Dynamic range write probe (D190)

    /// Same gate and same shape as the grain probe, for a different question. Grain asks what a
    /// value *means* on this body; this asks which values the slot will take at all. On the X-T50,
    /// DR200 and DR400 need the slot's ISO at 2× and 4× base, and D-Range Priority blocks Dynamic
    /// Range outright (zgrimz/fujifilm-ptp-reference `docs/04-custom-slots.md#iso-gating`,
    /// `#the-d-range-priority-interlock`); a push can't tell the user which of those it ran into.
    @ViewBuilder
    private var dynamicRangeProbeCard: some View {
        if mayWrite {
            WriteProbeCard(
                title: "Dynamic Range Write Probe (D190)",
                explanation: "Writes DR100, DR200, DR400 and DR Auto to the selected slot and reads back what stuck. A refusal is the finding, not a fault: the camera turns DR200 and DR400 down unless that slot's own ISO is high enough (2× and 4× base), and refuses every DR while D-Range Priority is on (that one is readable, at D191). DR100 is tried between the others as a control. Runs in the slot's edit buffer — nothing is committed and the original value is restored afterwards.",
                buttonTitle: "Probe Dynamic Range on C\(slot)",
                isProbing: isProbingDR,
                isDisabled: isProbingDR || isProbingGrain || isRunning || !camera.session.isConnected,
                entries: drProbe?.entries ?? [],
                valueLabel: Self.drLabel,
                exportText: drProbe.map { Self.dynamicRangeProbeText(camera: camera.session.connected, run: $0) }
                    ?? "",
                run: runDynamicRangeProbe)
        }
    }

    /// `-1` is DR Auto on the wire (`0xFFFF`; zgrimz/fujifilm-ptp-reference `docs/03-encodings.md`),
    /// and reading "wrote -1" off a shared report is a puzzle nobody should have to solve twice.
    nonisolated private static func drLabel(_ value: Int) -> String {
        value == FujiEncoding.drAutoSlotValue ? "DR Auto" : "DR\(value)"
    }

    nonisolated static func dynamicRangeProbeText(camera connected: ConnectedCamera?, run: ProbeRun) -> String {
        var lines = ["Fuji Cookbook — D190 dynamic range write probe", "Slot: C\(run.slot)"]
        if let connected { lines.insert("Camera: \(connected.productName)", at: 1) }
        lines += run.entries.map { "wrote \(drLabel($0.wrote)): \($0.outcome)" }
        lines.append("Note: the slot's own ISO and D-Range Priority decide which of these are allowed. D-Range Priority is D191, above; the ISO is not readable over USB — record it from the camera's menu.")
        return lines.joined(separator: "\n")
    }

    private func runDynamicRangeProbe() {
        guard !isProbingDR else { return }
        isProbingDR = true
        let probedSlot = slot
        refusal = nil
        Task {
            do throws(CameraBusy) {
                let entries = try await camera.diagnostics.probeWriteValues(
                    slot: probedSlot, property: .dynamicRange, candidates: CameraDiagnostics.dynamicRangeProbeCandidates)
                drProbe = ProbeRun(slot: probedSlot, entries: entries)
            } catch {
                drProbe = nil
                refusal = error
            }
            isProbingDR = false
        }
    }

    private func readProperties() {
        guard !isRunning else { return }
        isRunning = true
        refusal = nil
        Task {
            do throws(CameraBusy) {
                let result = try await camera.diagnostics.probeProperties(slot: slot)
                lastRead = Read(slot: result.slot, probes: result.probes)
            } catch {
                lastRead = nil
                refusal = error
            }
            isRunning = false
        }
    }
}

/// One write probe: what it does, the button that runs it, and what stuck. Grain and Dynamic Range
/// ask different questions of the same mechanism, so they read as the same card.
private struct WriteProbeCard: View {
    let title: String
    let explanation: String
    let buttonTitle: String
    let isProbing: Bool
    let isDisabled: Bool
    let entries: [WriteProbeEntry]
    var valueLabel: (Int) -> String = { "\($0)" }
    let exportText: String
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.SectionLabel(title)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 12) {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(Theme.ink2)

                Button(action: run) {
                    HStack(spacing: 8) {
                        if isProbing { ProgressView() }
                        Text(isProbing ? "Probing…" : buttonTitle)
                    }
                }
                .buttonStyle(.outline)
                .disabled(isDisabled)

                if !entries.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entries) { entry in
                            Text("wrote \(valueLabel(entry.wrote)): \(entry.outcome)")
                                .font(.caption.monospaced())
                                .foregroundStyle(entry.outcome == "ACCEPTED" ? Theme.accent : Theme.ink2)
                        }
                    }
                    CopyShareButtons(text: exportText, layout: .inline)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedCard(cornerRadius: 16)
        }
    }
}

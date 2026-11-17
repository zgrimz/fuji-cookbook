import PhotosUI
import SwiftUI
import SwiftData

/// Dispatches to the screen for one step, and gives every camera step the same gate card above it.
struct GuidedTestStepHost: View {
    let step: GuidedTestStep
    @Binding var session: GuidedTestSession
    @Binding var isRunning: Bool
    let onAdvance: () -> Void
    /// For the two steps that know their own destination — a connect that failed, and the write
    /// pass's "push another". Everything else uses `onAdvance` and lets `GuidedTestFlow` decide.
    let onAdvanceTo: (GuidedTestStep) -> Void
    let onFinish: () -> Void
    let onOpenKitchen: (String) -> Void
    /// Open one slot's comparison screen. `recheck` is the write pass's second look at a slot it
    /// just wrote to.
    let onOpenComparison: (Int, Bool) -> Void
    let onShowGuide: () -> Void
    var previousRecoveries: [GuidedRecoveryRecord] = []
    var onReviewRecovery: (GuidedRecoveryRecord) -> Void = { _ in }

    @Environment(CameraServices.self) private var camera

    var body: some View {
        Group {
            switch step {
            case .intro:
                GuidedIntroStep(session: $session, onAdvance: onAdvance,
                                previousRecoveries: previousRecoveries, onReviewRecovery: onReviewRecovery)
            case .connect:
                GuidedConnectStep(session: $session, isRunning: $isRunning,
                                  onAdvanceTo: onAdvanceTo, onShowGuide: onShowGuide)
            case .noCamera:
                GuidedNoCameraStep(session: $session, onAdvance: onAdvance)
            case .confirmIdentity:
                GuidedIdentityStep(session: $session, onAdvance: onAdvance)
            case .readSlots:
                GuidedReadSlotsStep(session: $session, isRunning: $isRunning, onAdvance: onAdvance)
            case .compareSlots:
                GuidedCompareStep(session: $session, onAdvance: onAdvance,
                                  onOpenComparison: { onOpenComparison($0, false) })
            case .propertyReport, .grainProbe:
                GuidedProbeStep(step: step, session: $session, isRunning: $isRunning,
                                onAdvance: onAdvance)
            case .develop:
                if camera.session.canConvert || session.identifiedModelID.flatMap({ CameraModelRegistry.shared.model(withID: $0) })?.supportsRawConversion == true {
                    GuidedKitchenStep(session: $session, isRunning: isRunning,
                                      onAdvance: onAdvance, onOpen: onOpenKitchen)
                } else {
                    GuidedDevelopStep(session: $session, onAdvance: onAdvance)
                }
            case .review:
                GuidedReviewStep(session: $session, onAdvance: onFinish)
            case .send:
                GuidedSendStep(session: $session, onFinish: onFinish)
            default:
                GuidedWriteStepHost(step: step, session: $session, isRunning: $isRunning,
                                    onAdvance: onAdvance, onAdvanceTo: onAdvanceTo,
                                    onOpenComparison: { onOpenComparison($0, true) })
            }
        }
        // The title and toolbar are the root's to set: they carry the tester's position among the
        // stages and the two recovery actions, both of which are the flow's business, not a step's.
    }
}

/// The gate card, wired to `CameraServices` — every camera step opens with it.
struct GuidedGate: View {
    @Binding var session: GuidedTestSession
    var unplugExpected = false
    var onShowGuide: (() -> Void)?

    @Environment(CameraServices.self) private var camera

    var body: some View {
        CameraGateCard(gate: GuidedTestRunner.gate(camera),
                       isDemo: session.transport == "demo",
                       unplugExpected: unplugExpected,
                       onReconnect: {
                           Task { await GuidedTestRunner.reconnect(camera, transport: session.transport) }
                       },
                       onHelp: { onShowGuide?() })
    }
}

// MARK: - Intro

struct GuidedIntroStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void
    var previousRecoveries: [GuidedRecoveryRecord] = []
    var onReviewRecovery: (GuidedRecoveryRecord) -> Void = { _ in }

    @Environment(CameraServices.self) private var camera
    /// The check icons' column, scaled with the text so large sizes don't crowd the titles.
    @ScaledMetric(relativeTo: .caption) private var checkIconWidth: CGFloat = 20

    private var setupModelID: String? {
        camera.session.isConnected ? camera.session.connected?.registryModel?.id : session.identifiedModelID
    }

    private struct CoverageRow: Hashable {
        let systemImage: String
        let title: String
        let detail: String
    }

    private static func row(for check: GuidedTestFlow.CoverageCheck) -> CoverageRow {
        switch check {
        case .reading:
            return CoverageRow(systemImage: "eye", title: "Reading",
                               detail: "Your saved slots, compared with the camera's own menu.")
        case .saving:
            return CoverageRow(systemImage: "tray.and.arrow.down", title: "Saving",
                               detail: "A test recipe written to a slot you choose, checked again after a restart. You can put your settings back at the end.")
        case .developing:
            return CoverageRow(systemImage: "photo", title: "Developing",
                               detail: "One of your RAW files turned into a JPEG by the camera.")
        case .rawSettings:
            return CoverageRow(systemImage: "doc.text.magnifyingglass", title: "RAW settings",
                               detail: "Instead of developing, the camera describes its conversion settings from one of your RAW files.")
        }
    }

    /// For the connected camera, else the body the session saved: the model `GuidedTestRunner.facts`
    /// judges by, provisional for an unlisted body, so the card promises what the flow will offer.
    private var coverage: GuidedTestFlow.Coverage {
        if let connected = camera.session.connected {
            return GuidedTestFlow.coverage(for: connected.model, unlisted: connected.identification.isUnlisted)
        }
        return GuidedTestFlow.coverage(for: session.cameraModel, unlisted: session.identification == "unlisted")
    }

    private var coverageCard: some View {
        let coverage = coverage
        return VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("What you'll check").foregroundStyle(Theme.ink)
            } icon: {
                Image(systemName: "checklist").foregroundStyle(Theme.accent)
            }
            .font(.subheadline.weight(.semibold))
            ForEach(coverage.checks.map(Self.row(for:)), id: \.self) { check in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: check.systemImage)
                        .foregroundStyle(Theme.accent)
                        .frame(width: checkIconWidth)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text(check.detail)
                            .font(.caption)
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.caption)
            }
            if let note = coverage.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .themedCard(cornerRadius: 16)
    }

    var body: some View {
        GuidedStepLayout(title: "How your camera talks to Fuji Cookbook",
                         subtitle: "Every Fujifilm model and firmware handles recipes a little differently. This guided test checks yours, and your results help improve support for everyone who owns one.") {
            if !previousRecoveries.isEmpty {
                GuidedNoticeCard(title: "Settings from an earlier test", systemImage: "arrow.uturn.backward",
                    message: "Your previous backup is saved. Before writing to that camera again, restore its original settings or choose to keep the changes.")
                ForEach(previousRecoveries) { record in
                    Button("Review \(record.backup.camera.productName) settings") { onReviewRecovery(record) }
                        .font(.subheadline.weight(.semibold))
                }
            }
            coverageCard
            GuidedNoticeCard(title: "Before you begin", systemImage: "cable.connector",
                message: "Use a USB data cable and a charged battery. Have one RAW file (.raf) taken with this camera in Photos or Files on your phone. We'll tell you when to unplug for menu checks and a photo. You can pause and return later.\n\n" + CameraTestSetup.usbInstructions)
            if setupModelID == "X-M5" {
                GuidedNoticeCard(title: "Two different dials", systemImage: "dial.medium",
                    message: "Set the Film Simulation dial to C. The mode dial's C1–C4 positions select your custom banks. Use a bank assigned to STILL in IQ → CUSTOM MODE SETTING for this test.")
            }
            GuidedPlanChoices(session: $session)
            Text("If something doesn't work, you can still share what you have. Nothing leaves your phone until you choose to share it.")
                .font(.caption).foregroundStyle(Theme.ink2)
        } actions: {
            GuidedPrimaryButton(title: "Begin", systemImage: "arrow.right", action: onAdvance)
        }
    }
}

// MARK: - Connect

struct GuidedConnectStep: View {
    @Binding var session: GuidedTestSession
    @Binding var isRunning: Bool
    /// Always explicit: where this step goes depends on whether the connect failed, which is
    /// exactly what `GuidedTestFlow.next(after: .connect)` cannot see.
    let onAdvanceTo: (GuidedTestStep) -> Void
    let onShowGuide: () -> Void

    @Environment(CameraServices.self) private var camera
    @AppStorage(DiagnosticMode.key) private var diagnosticMode = false

    var body: some View {
        GuidedStepLayout(title: "Connect your camera",
                         subtitle: "Plug it in with a USB data cable, then tap Connect.") {
            GuidedNoticeCard(
                title: "On the camera",
                systemImage: "camera",
                message: CameraTestSetup.usbInstructions + " iOS asks for Camera and Files and Folders access. Allow both.")
            if case .failed(let message) = camera.session.status {
                GuidedNoticeCard(title: "The app couldn't reach it", systemImage: "exclamationmark.triangle.fill",
                                 tint: Theme.warning, message: message)
            }
            if camera.session.isConnected, let connected = camera.session.connected {
                GuidedNoticeCard(title: "Connected", systemImage: "checkmark.circle.fill",
                                 message: "\(connected.model?.displayName ?? connected.productName) is connected.")
            }
        } actions: {
            if camera.session.isConnected {
                GuidedPrimaryButton(title: "Continue", systemImage: "arrow.right",
                                    action: { onAdvanceTo(resolvedNext()) })
            } else {
                GuidedPrimaryButton(title: "Connect Camera (USB)", systemImage: "cable.connector",
                                    busy: isRunning) {
                    Task {
                        isRunning = true
                        await camera.connector.connectHardware()
                        isRunning = false
                        session.adopt(camera: GuidedTestRunner.facts(camera))
                        onAdvanceTo(resolvedNext())
                    }
                }
                if diagnosticMode {
                    GuidedSecondaryButton(title: "Connect Demo Camera") {
                        Task {
                            isRunning = true
                            await camera.connector.connectDemo()
                            isRunning = false
                            session.adopt(camera: GuidedTestRunner.facts(camera))
                            onAdvanceTo(resolvedNext())
                        }
                    }
                }
            }
            GuidedSecondaryButton(title: "It isn't connecting", action: { onAdvanceTo(.noCamera) })
            GuidedSecondaryButton(title: "Connection help", action: onShowGuide)
        }
    }

    /// A failed connect goes to the questions the app cannot answer for itself; everything else
    /// follows the ordinary rules.
    func resolvedNext() -> GuidedTestStep {
        GuidedTestFlow.stepAfterConnect(status: camera.session.status,
                                        facts: GuidedTestRunner.facts(camera))
    }
}

// MARK: - No camera

/// The most common failure on a new body, and the worst-instrumented one. `connectionFailures[]`
/// records the two permission states and the stage that failed; everything that separates a
/// charge-only cable from the wrong USB mode has to be asked.
struct GuidedNoCameraStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void

    @State private var answers = GuidedTestSession.NoCameraAnswers()

    var body: some View {
        GuidedStepLayout(title: "What happened",
                         subtitle: "Add what you can so we can investigate the connection problem.") {
            VStack(alignment: .leading, spacing: 14) {
                GuidedTextField(label: "Camera model printed on the camera",
                                placeholder: "FUJIFILM X-T30 III",
                                text: binding(\.modelAsPrinted))
                GuidedTextField(label: "Firmware version shown on the camera",
                                placeholder: "1.02", text: binding(\.firmwareFromMenu))
                GuidedTextField(label: "USB setting selected on the camera",
                                placeholder: "USB RAW CONV./BACKUP RESTORE", axis: .vertical,
                                text: binding(\.usbModeWording))
                GuidedTextField(label: "Cable and any adapter or hub",
                                placeholder: "The one that came with the camera", axis: .vertical,
                                text: binding(\.cable))
                GuidedTextField(label: "Message shown in the app", axis: .vertical,
                                text: binding(\.appSaid))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedCard(cornerRadius: 16)

            GuidedAnswerPicker(question: "Did iOS ask for Camera permission?",
                               answer: Binding(get: { answers.cameraPromptSeen },
                                               set: { answers.cameraPromptSeen = $0; store() }))
            GuidedAnswerPicker(question: "Did iOS ask for Files and Folders permission?",
                               answer: Binding(get: { answers.filesPromptSeen },
                                               set: { answers.filesPromptSeen = $0; store() }))
            // Not an iOS quirk: the one sighting was a stuck per-bundle-id permission record on one
            // phone (see `CameraDeviceBrowser.ensureAuthorized()`). Nobody should see this, which is exactly why
            // someone who does is worth hearing from.
            GuidedNoticeCard(
                title: "If Files and Folders won't stay on",
                systemImage: "folder.badge.questionmark",
                message: "Mention it above and share the results. The report includes the permission responses to help us investigate.")
        } actions: {
            GuidedPrimaryButton(title: "Continue", systemImage: "arrow.right", action: onAdvance)
        }
        .onAppear { answers = session.noCamera ?? GuidedTestSession.NoCameraAnswers() }
    }

    private func binding(_ key: WritableKeyPath<GuidedTestSession.NoCameraAnswers, String?>) -> Binding<String> {
        Binding(get: { answers[keyPath: key] ?? "" },
                set: { answers[keyPath: key] = $0.isEmpty ? nil : $0; store() })
    }

    private func store() {
        session.noCamera = answers
        session.touch()
    }
}

// MARK: - Identity

/// A body resolved to the wrong registry entry reads and writes a field set that isn't its own — and
/// says nothing about having guessed. This is the only question that catches it.
struct GuidedIdentityStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void

    @Environment(CameraServices.self) private var camera
    @State private var correction = ""
    @State private var answer: GuidedTestSession.Answer?

    var body: some View {
        GuidedStepLayout(title: "Confirm your camera",
                         subtitle: "Check that the app has identified the connected camera correctly.") {
            GuidedGate(session: $session)
            if let connected = camera.session.connected {
                VStack(alignment: .leading, spacing: 10) {
                    Text(connected.model?.displayName ?? connected.productName)
                        .font(Theme.serif(22))
                        .foregroundStyle(Theme.ink)
                    Label(connected.capabilityBadge.text, systemImage: connected.capabilityBadge.symbol)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.ink2)
                    if let firmware = connected.firmwareVersion {
                        Text("Firmware \(firmware)").font(.footnote).foregroundStyle(Theme.ink3)
                    }
                    Text("Name reported by the camera: \(connected.productName)")
                        .font(.caption)
                        .foregroundStyle(Theme.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .themedCard(cornerRadius: 16)

                if let banner = connected.identification.guessBanner(productName: connected.productName) {
                    GuidedNoticeCard(title: "Model not confirmed", systemImage: "questionmark.diamond.fill",
                                     tint: Theme.warning, message: banner)
                }
            }
            GuidedAnswerPicker(question: "Is this the camera you've connected?",
                               answer: Binding(get: { answer }, set: { answer = $0; store() }))
            if answer == .no {
                GuidedTextField(label: "Camera model printed on the camera",
                                placeholder: "FUJIFILM X-T30 III",
                                text: Binding(get: { correction }, set: { correction = $0; store() }))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themedCard(cornerRadius: 16)
            }
        } actions: {
            GuidedPrimaryButton(title: "Continue", systemImage: "arrow.right",
                                enabled: answer != nil, action: onAdvance)
        }
        .onAppear {
            answer = session.identity?.confirmed.map { $0 ? .yes : .no }
            correction = session.identity?.correction ?? ""
        }
    }

    private func store() {
        session.identity = .init(confirmed: answer.map { $0 == .yes },
                                 correction: correction.isEmpty ? nil : correction)
        session.adopt(camera: GuidedTestRunner.facts(camera))
    }
}

// MARK: - Read slots

struct GuidedReadSlotsStep: View {
    @Binding var session: GuidedTestSession
    @Binding var isRunning: Bool
    let onAdvance: () -> Void

    @Environment(CameraServices.self) private var camera

    private var occupied: [CameraSlot] { camera.occupiedSlots }
    private var divergent: [CameraSlot] { camera.slotReader.slots.filter { !$0.unsupportedFields.isEmpty } }
    /// No range when the slot count is unknown: a failed read leaves nothing to name.
    private var subtitle: String {
        let count = camera.slotReader.effectiveSlotCount
        return count > 0 ? "What the app found in C1–C\(count)." : "What the app found in your slots."
    }

    var body: some View {
        GuidedStepLayout(title: "Read your slots", subtitle: subtitle) {
            GuidedGate(session: $session)
            if camera.slotReader.slots.isEmpty {
                GuidedNoticeCard(title: "Nothing read yet", systemImage: "tray",
                                 message: "Tap Read Slots below.")
            } else {
                VStack(spacing: 0) {
                    ForEach(camera.slotReader.slots) { slot in
                        SlotRow(slot: slot)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        if slot.index != camera.slotReader.slots.last?.index {
                            Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 14)
                        }
                    }
                }
                .themedCard(cornerRadius: 16)

                if !divergent.isEmpty {
                    let count = divergent.reduce(0) { $0 + $1.unsupportedFields.count }
                    GuidedNoticeCard(
                        title: "Some settings didn't read cleanly",
                        systemImage: "exclamationmark.triangle.fill", tint: Theme.warning,
                        message: "The app couldn't interpret \(count) setting\(count == 1 ? "" : "s") on \(divergent.map(\.label).joined(separator: ", ")). They're left blank for you to check in the camera's menu next.")
                }
                if occupied.isEmpty {
                    GuidedNoticeCard(
                        title: "Every slot is empty", systemImage: "tray",
                        message: "There is no existing recipe to compare. The test supplies a recipe and asks you to check its settings after writing it.")
                }
            }
            if let report = session.propertyReport, report.state == .failed || report.state == .refused {
                GuidedNoticeCard(title: "The camera reading needs another try", systemImage: "exclamationmark.triangle",
                                 tint: Theme.warning,
                                 message: report.detail ?? "The reading didn't finish. Reconnect if needed, then try again before writing a recipe.")
            }
        } actions: {
            if camera.slotReader.slots.isEmpty {
                GuidedPrimaryButton(title: "Read Slots", systemImage: "arrow.down.doc", busy: isRunning) {
                    Task {
                        isRunning = true
                        // A refused read leaves the slots unread; `readCamera` reads them again through
                        // `ensureSlots`, which reports a refusal.
                        _ = try? await camera.slotReader.requestRefresh()
                        session.propertyReport = nil
                        await readCamera()
                        isRunning = false
                    }
                }
            } else {
                GuidedPrimaryButton(title: isRunning ? "Reading camera settings…" : "Continue",
                                    systemImage: "arrow.right", enabled: session.propertyReport != nil,
                                    busy: isRunning, action: onAdvance)
                if session.propertyReport?.state == .failed || session.propertyReport?.state == .refused {
                    GuidedSecondaryButton(title: "Retry camera reading") {
                        Task { await readCamera() }
                    }
                    .disabled(isRunning)
                }
            }
        }
        .task { await readCamera() }
    }

    private func readCamera() async {
        isRunning = true
        let ready = await GuidedTestRunner.ensureSlots(camera)
        if ready.isReady {
            session.slotComparisons = GuidedTestFlow.seedComparisons(into: session.slotComparisons,
                slots: camera.slotReader.slots, model: camera.session.model)
        }
        if session.propertyReport == nil || session.propertyReport?.state == .failed || session.propertyReport?.state == .refused {
            switch ready {
            case .ready:
                session.propertyReport = await GuidedTestRunner.runPropertyReport(camera, slot: camera.slotReader.slots.first?.index ?? 1)
            case .busy:
                session.propertyReport = .init(state: .refused, detail: "The camera was busy. Nothing was read.")
            case .reconnecting, .lost, .disconnected:
                session.propertyReport = .init(state: .failed, detail: "The slot read did not finish. Reconnect and retry.")
            }
            GuidedTestRunner.captureReadEvidence(camera, session: &session)
            session.touch()
        }
        isRunning = false
    }
}

// MARK: - Compare

/// The step the whole test is built around.
struct GuidedCompareStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void
    let onOpenComparison: (Int) -> Void

    @Environment(CameraServices.self) private var camera

    private var comparisons: [GuidedTestSession.SlotComparison] { session.slotComparisons }
    private var checkedCount: Int { comparisons.filter { $0.checkedAt != nil }.count }
    private var storedModel: CameraModel? {
        session.identifiedModelID.flatMap { CameraModelRegistry.shared.model(withID: $0) }
    }

    var body: some View {
        GuidedStepLayout(title: session.plan?.optionalChecks.contains(.secondSlotComparison) == true ? "Check two slots against the camera" : "Check one slot against the camera",
                         subtitle: "Compare the settings shown here with the camera's own menu.") {
            GuidedGate(session: $session, unplugExpected: !comparisons.isEmpty)
            // The flow routes past this step when there is nothing to compare, but the hub lists
            // every main-line step and a tester can tap in anyway.
            if comparisons.isEmpty {
                GuidedNoticeCard(
                    title: "Nothing to compare",
                    systemImage: "tray",
                    message: "No occupied slots were read, so an existing-recipe comparison is unavailable. After a test recipe is written, you can compare that slot against the camera menu.")
            } else {
            GuidedNoticeCard(
                title: "Why compare?",
                systemImage: "eye",
                message: "This confirms the app is reading your saved settings correctly. The camera's menu is the reference.")
            GuidedNoticeCard(
                title: "Unplug the camera first",
                systemImage: "cable.connector.slash",
                message: "Unplug the USB cable to use the camera's menus. On the camera, open MENU → IQ → the custom slot. Choose the same slot below and compare each setting. Your answers are saved as you go.")
            if storedModel?.hasFilmSimulationDial == true {
                GuidedNoticeCard(
                    title: "Check the saved slot",
                    systemImage: "dial.medium",
                    message: "Compare the slot’s saved entry in the IQ menu. Before the write test, set the Film Simulation dial to C so the dial does not override the recipe.")
                if storedModel?.id == "X-M5" {
                    GuidedNoticeCard(title: "Use a still-photography bank", systemImage: "camera",
                        message: "The X-M5's C1–C4 mode-dial banks can hold still or movie settings. Check a still-photography bank. The Film Simulation dial's C position is separate from those C1–C4 positions.")
                }
                if session.writePass?.dialConfirmed == true {
                    Label("Film Simulation dial confirmed on C", systemImage: "checkmark.circle")
                        .font(.subheadline).foregroundStyle(Theme.ink2)
                } else {
                    Button("The Film Simulation dial is on C") { recordDial(true) }
                        .font(.subheadline.weight(.semibold))
                    Button("I can't set the dial right now") { recordDial(false) }
                        .font(.subheadline)
                    if session.writePass?.dialConfirmed == false {
                        Text("Recorded. The write checks will stay paused until the dial can be set to C.")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                }
            }
            VStack(spacing: 0) {
                ForEach(comparisons) { comparison in
                    Button { onOpenComparison(comparison.slot) } label: {
                        HStack(spacing: 12) {
                            verdictIcon(for: comparison.slot)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(comparison.label) · \(comparison.displayName)")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.ink)
                                Text(verdictNote(for: comparison.slot))
                                    .font(.caption)
                                    .foregroundStyle(Theme.ink3)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.ink3)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if comparison.slot != comparisons.last?.slot {
                        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 46)
                    }
                }
            }
            .themedCard(cornerRadius: 16)
            Text(session.plan?.optionalChecks.contains(.secondSlotComparison) == true ? "Check two slots, preferably with different settings." : "Check one slot. You can check more if you'd like.")
                .font(.caption)
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, 4)
            }
        } actions: {
            GuidedPrimaryButton(title: "Continue", systemImage: "arrow.right",
                                enabled: comparisons.isEmpty || checkedCount >= min(comparisons.count, session.plan?.optionalChecks.contains(.secondSlotComparison) == true ? 2 : 1), action: onAdvance)
            if checkedCount > 0, !camera.session.isConnected {
                Text("Plug the camera back in — the next step needs it.")
                    .font(.caption)
                    .foregroundStyle(Theme.ink3)
            }
            if checkedCount == 0, !comparisons.isEmpty {
                GuidedSecondaryButton(title: "I can't check this now", action: onAdvance)
            }
        }
        // Snapshot every occupied slot now, while the camera is still attached. The tester is about
        // to unplug it, and `disconnect()` empties `camera.slotReader.slots`.
        .task {
            let seeded = GuidedTestFlow.seedComparisons(into: session.slotComparisons,
                                                        slots: camera.slotReader.slots,
                                                        model: camera.session.model)
            guard seeded != session.slotComparisons else { return }
            session.slotComparisons = seeded
            session.touch()
        }
    }

    private func recordDial(_ confirmed: Bool) {
        var pass = session.writePass ?? .init()
        pass.dialConfirmed = confirmed
        session.writePass = pass
        session.touch()
    }

    @ViewBuilder
    private func verdictIcon(for slot: Int) -> some View {
        switch session.slotComparisons.first(where: { $0.slot == slot })?.verdict {
        case "differs"?, "unverified"?:
            Image(systemName: "exclamationmark.circle.fill").font(.title3).foregroundStyle(Theme.warning)
        case "matches"?:
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Theme.accent)
        default:
            Image(systemName: "circle").font(.title3).foregroundStyle(Theme.ink3.opacity(0.6))
        }
    }

    private func verdictNote(for slot: Int) -> String {
        guard let comparison = session.slotComparisons.first(where: { $0.slot == slot }),
              comparison.checkedAt != nil else { return "Not checked yet" }
        if comparison.verdict == "unverified" { return "Some settings could not be verified" }
        let differing = comparison.rows.filter(\.differs).count
        return differing == 0 ? "Matches the camera" : guidedSettingsDiffer(differing)
    }
}

// MARK: - Probes

/// The property report and the grain probe: two diagnostics the flow runs so a tester never has to
/// find Diagnostic Mode, which they were never going to.
struct GuidedProbeStep: View {
    let step: GuidedTestStep
    @Binding var session: GuidedTestSession
    @Binding var isRunning: Bool
    let onAdvance: () -> Void

    @Environment(CameraServices.self) private var camera

    private var isGrain: Bool { step == .grainProbe }
    private var storedModel: CameraModel? {
        session.identifiedModelID.flatMap { CameraModelRegistry.shared.model(withID: $0) }
    }
    private var bodyAllowsWrites: Bool {
        camera.session.isConnected ? camera.session.connected?.isWritable == true : storedModel?.allowsWrite == true
    }
    private var needsProbe: Bool {
        outcome == nil || outcome?.state == .notRun || outcome?.state == .refused
            || (isGrain && (outcome?.state == .skipped || outcome?.state == .notWritable && bodyAllowsWrites))
    }
    private var outcome: GuidedTestSession.ProbeOutcome? {
        isGrain ? session.grainProbe : session.propertyReport
    }
    /// The slot the tester compared, so both probes run against something they have seen — else any
    /// slot with a recipe in it. Nil on a camera where nothing is programmed.
    ///
    /// Not `?? 1`: an empty camera would then have both probes describe C1 as though it held a
    /// recipe and report a near-zero count that reads as a camera failure rather than an empty
    /// slot. Both probes are about the *property*, not the recipe, so they still run — they just say
    /// what they are actually doing.
    private var occupiedSlot: Int? {
        session.slotComparisons.first { $0.checkedAt != nil }?.slot
            ?? camera.slotReader.slots.first { $0.isOccupied }?.index
    }

    /// Where the probe is pointed. C1 when nothing is programmed — a slot has to be selected either
    /// way — but `occupiedSlot` is what decides how it is described and recorded.
    private var slot: Int { occupiedSlot ?? camera.slotReader.slots.first?.index ?? 1 }

    var body: some View {
        GuidedStepLayout(title: step.title, subtitle: subtitle) {
            GuidedGate(session: $session,
                       unplugExpected: isGrain && storedModel?.id == "X-M5" && !isRunning)
            GuidedNoticeCard(title: explanationTitle, systemImage: isGrain ? "pencil.and.outline" : "list.bullet.rectangle",
                             message: explanation)
            if isGrain, !camera.session.isConnected, bodyAllowsWrites {
                GuidedNoticeCard(title: "Reconnect for the grain check", systemImage: "cable.connector",
                                 message: "Plug the camera back in to continue. This check is required before writing a test recipe.")
            } else if isGrain, !bodyAllowsWrites {
                GuidedNoticeCard(
                    title: "Grain check unavailable",
                    systemImage: "lock.fill",
                    message: "Writing isn't enabled for this camera, so the grain check can't run. You can still share the other results.")
            }
            if !isGrain, camera.session.isConnected, camera.session.canConvert == false {
                GuidedNoticeCard(
                    title: "Checking RAW support",
                    systemImage: "photo.stack",
                    message: "The app will also collect information that may help us add RAW development for this camera. No RAW file is needed for this check.")
            }
            if let outcome, outcome.state != .notRun {
                resultCard(outcome)
            }
            if isGrain, bodyAllowsWrites, needsProbe || outcome?.state == .failed {
                GuidedStillBankConfirmation(session: $session, slot: slot,
                                            modelID: storedModel?.id, isRunning: isRunning)
            }
        } actions: {
            if isGrain, !camera.session.isConnected, bodyAllowsWrites, needsProbe || outcome?.state == .failed {
                GuidedPrimaryButton(title: "Reconnect the test camera", systemImage: "cable.connector", busy: isRunning) {
                    Task {
                        isRunning = true
                        await GuidedTestRunner.reconnect(camera, transport: session.transport)
                        isRunning = false
                    }
                }
                if outcome?.state == .failed {
                    GuidedSecondaryButton(title: "Review Recovery Options", action: onAdvance)
                }
            } else if needsProbe {
                if isGrain, bodyAllowsWrites {
                    GuidedPrimaryButton(title: "Check Grain Settings", systemImage: "play.fill",
                                        enabled: GuidedTestRunner.gate(camera).isReady
                                            && (storedModel?.id != "X-M5" || session.hasConfirmedStillBank(slot)),
                                        busy: isRunning) {
                        run()
                    }
                } else if isGrain {
                    GuidedPrimaryButton(title: "Continue", systemImage: "arrow.right") {
                        session.grainProbe = GuidedTestFlow.grainProbeState(facts: GuidedTestRunner.facts(camera))
                            ?? .init(state: .notRun)
                        session.touch()
                        onAdvance()
                    }
                } else {
                    GuidedPrimaryButton(title: "Read Camera Settings", systemImage: "play.fill", busy: isRunning) { run() }
                    GuidedSecondaryButton(title: "Skip") {
                        session.propertyReport = .init(state: .skipped, detail: "skipped by the tester")
                        session.touch()
                        onAdvance()
                    }
                }
            } else {
                GuidedPrimaryButton(title: isGrain && outcome?.state == .failed ? "Review Recovery Options" : "Continue",
                                    systemImage: "arrow.right", action: onAdvance)
                if outcome?.state == .failed {
                    GuidedSecondaryButton(title: "Try again", action: run)
                }
            }
        }
    }

    private var subtitle: String {
        isGrain ? "Check how your camera saves Grain Effect before writing a recipe."
                : "Read the camera's settings and the values it supports."
    }

    private var explanationTitle: String {
        isGrain ? "A temporary settings check" : "What the app reads"
    }

    private var explanation: String {
        isGrain
            ? (occupiedSlot == nil
               ? "The app will try ten Grain Effect values on empty slot C\(slot), then check that the slot is still empty. Your original settings are backed up first.\n\nKeep the USB cable connected until the check finishes. Values the camera rejects are useful results too."
               : "The app will try ten Grain Effect values on C\(slot), then restore and check the original grain setting. Your original settings are backed up first.\n\nKeep the USB cable connected until the check finishes. Values the camera rejects are useful results too.")
            : (occupiedSlot == nil
               ? "Your slots are empty. The app will ask which settings and values your camera supports. Some cameras provide less detail than others; the report records what is available."
               : "The app will read C\(slot) and ask which values the camera supports for each setting. This helps us check compatibility without changing your saved recipe.")
    }

    @ViewBuilder
    private func resultCard(_ outcome: GuidedTestSession.ProbeOutcome) -> some View {
        switch outcome.state {
        case .ran:
            GuidedNoticeCard(
                title: "Done", systemImage: "checkmark.circle.fill",
                message: isGrain
                    ? "\(outcome.count ?? 0) grain values checked on C\(outcome.slot ?? slot). \(occupiedSlot == nil ? "The slot is still empty." : "The original grain setting is restored.") Results are saved in the report."
                    : "\(outcome.count ?? 0) settings read from C\(outcome.slot ?? slot)\(outcome.readOnly == true ? ", without selecting a slot" : "")"
                        + (occupiedSlot == nil ? ", which is empty — a low count is expected. " : ". ")
                        + "It's in the report.")
        case .refused:
            GuidedNoticeCard(title: "The check could not start", systemImage: "clock",
                             tint: Theme.warning, message: outcome.detail ?? "Try again in a moment.")
        case .failed:
            GuidedNoticeCard(title: "That didn't finish", systemImage: "exclamationmark.triangle.fill",
                             tint: Theme.warning, message: outcome.detail ?? "The camera stopped answering.")
        case .skipped, .notWritable, .notRun:
            EmptyView()
        }
    }

    private func run() {
        Task {
            isRunning = true
            if isGrain {
                session.grainConsentAt = CameraCompatibilityReport.timestamp()
                var current = session
                if let problem = GuidedTestRunner.prepareRecovery(camera, session: &current) {
                    session.grainProbe = .init(state: .refused, detail: problem)
                    isRunning = false
                    return
                }
                session = current
                var outcome = await GuidedTestRunner.runGrainProbe(camera, slot: slot, session: current)
                if occupiedSlot == nil, outcome.state == .ran {
                    outcome.detail = [outcome.detail, "the slot was empty, so there was no original value to put back"]
                        .compactMap { $0 }.joined(separator: " · ")
                }
                session.grainProbe = outcome
            } else {
                var outcome = await GuidedTestRunner.runPropertyReport(camera, slot: slot)
                // Without this a reader sees "ran on C1 — 6 properties" and reads a broken camera.
                if occupiedSlot == nil, outcome.state == .ran, outcome.detail == nil {
                    outcome.detail = "the slot was empty — nothing had been programmed into it"
                }
                session.propertyReport = outcome
                GuidedTestRunner.captureReadEvidence(camera, session: &session)
            }
            session.touch()
            isRunning = false
        }
    }
}

// MARK: - Develop

struct GuidedDevelopStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void

    private enum RAWSource { case photos, rawPairs, files }

    @Environment(CameraServices.self) private var camera
    @Environment(\.photoLibrary) private var library
    @State private var showingFilePicker = false
    @State private var showingPhotoPicker = false
    @State private var showingPairPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    /// So "Choose another RAW file" reopens wherever the last one came from.
    @State private var lastSource = RAWSource.photos
    @State private var photoProblem: PhotoLibraryRAW.Import.Problem?
    @State private var isHarvesting = false
    /// The photo chosen with Choose RAW+JPEG Photos while its RAF downloads; the download runs in
    /// a task the step owns, so leaving the step cancels it and removes what it copied.
    @State private var pairDownload: PairDownload?

    private struct PairDownload: Equatable {
        let id = UUID()
        let ids: [String]
    }

    /// A body the app doesn't develop on, but can send a RAF to. The harvest is the only way to
    /// find out whether it should — see `RawConversionService.harvestConversionProfile`.
    private var offersHarvest: Bool {
        GuidedTestFlow.offersProfileHarvest(facts: GuidedTestRunner.facts(camera))
    }
    private var harvest: GuidedTestSession.ProbeOutcome? { session.profileHarvest }
    private var harvestCanRun: Bool {
        guard let harvest else { return true }
        return harvest.state == .notRun || harvest.state == .refused
    }
    /// The full record, for the result card: the session only keeps the one-line outcome.
    private var latestHarvest: CameraCompatibilityReport.ProfileHarvestRecord? {
        camera.reports.report?.profileHarvests?.last
    }

    var body: some View {
        GuidedStepLayout(title: "Develop a RAW file",
                         subtitle: "Turn one RAW file (.raf) from this camera into a JPEG.") {
            GuidedGate(session: $session)
            if offersHarvest {
                // The one thing that can settle whether this body converts: 0xD185 only holds a
                // profile once the camera has a RAF to describe, and every path that sends one
                // sits behind the gate the answer would open. So this step sends one, reads, stops.
                GuidedNoticeCard(
                    title: "Check RAW conversion support",
                    systemImage: "lock.open",
                    message: "Choose a RAW file (.raf) taken with this camera. The app uploads it and reads the camera's conversion information for the report. This check does not develop a JPEG or change your custom slots. Keep the app open until it finishes.")
                if let harvest, harvest.state != .notRun {
                    harvestResultCard(harvest)
                }
            } else {
                GuidedNoticeCard(
                    title: "Not available on this camera",
                    systemImage: "lock.fill",
                    message: "RAW conversion is unavailable for this camera. The app also cannot run the support check because the camera's identity is not confirmed. This is recorded in the report.")
            }
        } actions: {
            if offersHarvest, harvestCanRun {
                GuidedPrimaryButton(title: "Choose from Photos", systemImage: "photo",
                                    busy: isHarvesting) { choose(.photos) }
                GuidedSecondaryButton(title: "Choose RAW+JPEG Photos…", enabled: !isHarvesting) { choose(.rawPairs) }
                GuidedSecondaryButton(title: "Browse Files…", enabled: !isHarvesting) { choose(.files) }
                GuidedSecondaryButton(title: "I don't have a RAW file") {
                    session.profileHarvest = .init(state: .skipped,
                                                   detail: "no RAF from this camera was available")
                    session.touch()
                    onAdvance()
                }
            } else {
                GuidedPrimaryButton(title: "Continue", systemImage: "arrow.right", action: onAdvance)
                if offersHarvest, harvest?.state == .failed {
                    GuidedSecondaryButton(title: "Choose another RAW file") { choose(lastSource) }
                }
            }
        }
        .sheet(isPresented: $showingFilePicker) {
            ContentPicker(contentTypes: [.rawImage], allowsMultiple: false) { urls in
                runHarvest(urls)
            }
            .ignoresSafeArea()
        }
        // `.current` hands over the RAW as stored; a compatible encoding may transcode it.
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoSelection,
                      maxSelectionCount: 1, matching: .images,
                      preferredItemEncoding: .current,
                      photoLibrary: .shared())
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []   // clear immediately so the picker dismisses cleanly, per FrameAndFitView
            runHarvest(items)
        }
        .rawPairPicker(isPresented: $showingPairPicker, limit: 1,
                       onPick: { pairDownload = PairDownload(ids: $0) },
                       onFullAccess: { showingPhotoPicker = true },
                       onBrowseFiles: { choose(.files) })
        .alert(photoProblem?.title ?? "", isPresented: Binding(isPresent: $photoProblem)) {
            if photoProblem?.offersRAWPairs == true {
                Button("Choose RAW+JPEG Photos…") { choose(.rawPairs) }
            }
            Button("OK", role: .cancel) {}
        } message: { Text(photoProblem?.message ?? "") }
        .task(id: pairDownload?.id) { await downloadPair() }
        .onAppear {
            if session.develop == nil, let notApplicable = GuidedTestFlow.developState(facts: GuidedTestRunner.facts(camera)) {
                session.develop = notApplicable
            }
        }
    }

    private func choose(_ source: RAWSource) {
        lastSource = source
        switch source {
        case .photos: showingPhotoPicker = true
        case .rawPairs: showingPairPicker = true
        case .files: showingFilePicker = true
        }
    }

    /// Stage the picked file the way the Kitchen does — the picker's copy lands in an Inbox iOS
    /// empties — then send it.
    private func runHarvest(_ urls: [URL]) {
        guard let picked = urls.first else { return }
        let staged = PickedRAFStore.stage([picked])
        Task {
            isHarvesting = true
            defer { isHarvesting = false }
            await harvest(staged)
        }
    }

    /// A photo's RAW is copied out of the library first. A photo without one, or one that won't
    /// copy, is reported on screen and records nothing: no file reached the camera.
    private func runHarvest(_ items: [PhotosPickerItem]) {
        Task {
            isHarvesting = true
            defer { isHarvesting = false }
            let copied = await PhotoLibraryRAW.copy(items, library: library)
            guard let picked = copied.urls.first else {
                photoProblem = copied.problem
                return
            }
            await harvest(PickedRAFStore.stage([picked]))
        }
    }

    /// A photo chosen with Choose RAW+JPEG Photos: its RAF is copied out of the library first, then
    /// sent as a Files pick is. A copy that fails is reported on screen and records nothing.
    private func downloadPair() async {
        guard let pending = pairDownload else { return }
        isHarvesting = true
        let copied = await RAWPhotoCopy().copy(pending.ids, from: library)
        isHarvesting = false
        guard !Task.isCancelled else { return }
        pairDownload = nil
        guard let picked = copied.urls.first else {
            photoProblem = copied.problem
            return
        }
        runHarvest([picked])
    }

    /// Read the staged file off the main actor, let the copy go, and send the bytes.
    private func harvest(_ staged: [URL]) async {
        let data = try? await CookHarness.prepareRAFs(staged).rafs.first?.load()
        PickedRAFStore.discard(staged)
        guard let data else {
            session.profileHarvest = .init(state: .failed, detail: "That file couldn't be read.")
            session.touch()
            return
        }
        session.profileHarvest = await GuidedTestRunner.runProfileHarvest(camera, raf: data)
        session.touch()
    }

    @ViewBuilder
    private func harvestResultCard(_ harvest: GuidedTestSession.ProbeOutcome) -> some View {
        switch harvest.state {
        case .ran:
            // The record, not the one-line outcome, decides which of three things happened —
            // and all three are worth having.
            if let record = latestHarvest, record.layoutBase != nil {
                GuidedNoticeCard(
                    title: "Conversion information recorded", systemImage: "checkmark.circle.fill",
                    message: "The camera returned conversion information the app recognises. It is saved in the report for review; RAW conversion is still unavailable in this build.")
            } else if let record = latestHarvest, record.profileLength != nil {
                GuidedNoticeCard(
                    title: "New conversion information recorded",
                    systemImage: "exclamationmark.circle", tint: Theme.warning,
                    message: "The camera returned information the app doesn't yet understand. It is saved in the report for review.")
            } else {
                GuidedNoticeCard(
                    title: "No conversion information returned",
                    systemImage: "exclamationmark.circle", tint: Theme.warning,
                    message: "The camera accepted the file but returned no conversion information. This result is saved in the report.")
            }
        case .failed:
            GuidedNoticeCard(
                title: "The check did not finish", systemImage: "exclamationmark.triangle.fill", tint: Theme.warning,
                message: (harvest.detail ?? "The upload was refused.")
                    + " Use a RAW file taken with this same camera. You can retry or continue with the failure recorded.")
        case .skipped:
            GuidedNoticeCard(title: "Skipped", systemImage: "forward.fill",
                             message: "No RAW file was available. You can continue.")
        case .refused:
            GuidedNoticeCard(title: "The camera was busy", systemImage: "clock", tint: Theme.warning,
                             message: harvest.detail ?? "Try again in a moment.")
        case .notWritable, .notRun:
            EmptyView()
        }
    }
}

// MARK: - Review and send

struct GuidedReviewStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void

    var body: some View {
        GuidedStepLayout(title: "Review your results",
                         subtitle: "Completed checks, findings and anything still unknown.") {
            CameraTestSummaryView(session: session)
            GuidedTextField(label: "Anything else worth sharing?", axis: .vertical,
                text: Binding(get: { session.freeText ?? "" }, set: { session.freeText = $0.isEmpty ? nil : $0 }))
        } actions: {
            GuidedPrimaryButton(title: "Review & Share Test Results", systemImage: "square.and.arrow.up", action: onAdvance)
        }
    }
}

struct GuidedSendStep: View {
    @Binding var session: GuidedTestSession
    let onFinish: () -> Void

    var body: some View {
        GuidedStepLayout(title: "Share your results",
                         subtitle: "Review the report, then choose how to share it.") {
            GuidedNoticeCard(
                title: "Every result helps",
                systemImage: "checklist",
                message: "Please share your results even if everything worked. Incomplete checks help us too.")
            GuidedNoticeCard(
                title: "What's in it",
                systemImage: "doc.text",
                message: "The report includes device and app details, camera settings, diagnostic logs and your answers. Photos and file names aren't included. The camera's serial number is replaced by a hash.")
            GuidedNoticeCard(
                title: "Nothing is sent automatically",
                systemImage: "hand.raised",
                message: "You can review the files before sharing. Nothing is sent until you choose to share it.")
        } actions: {
            GuidedPrimaryButton(title: "Open the Report", systemImage: "square.and.arrow.up",
                                action: onFinish)
        }
    }
}

/// Uses the production Kitchen with supplied test recipes; observations stay attached to the exact run.
struct GuidedKitchenStep: View {
    @Binding var session: GuidedTestSession
    let isRunning: Bool
    let onAdvance: () -> Void
    let onOpen: (String) -> Void
    @Environment(CameraServices.self) private var camera
    @State private var referenceActive = false
    @State private var savedResult: Identified<UUID>?

    private var cases: [(id: String, title: String)] {
        var result = [("develop", "Develop with CT Colour")]
        let extras = session.plan?.optionalChecks ?? []
        if extras.contains(.testKitchen) { result.append(("testKitchen", "Compare colour and monochrome")) }
        if extras.contains(.expandedKitchen) { result.append(("expandedKitchen", "Compare several RAW files")) }
        if extras.contains(.dynamicRange) {
            result += [("dr-100", "Develop at DR100"), ("dr-200", "Develop at DR200"),
                       ("dr-400", "Develop at DR400"), ("dr-auto", "Develop at DR Auto")]
        }
        return result
    }

    var body: some View {
        GuidedStepLayout(title: "Develop and compare", subtitle: "Use a RAW file (.raf) taken with this camera. The test recipes are ready.") {
            GuidedGate(session: $session, unplugExpected: referenceActive)
            GuidedNoticeCard(title: "Develop, then inspect the photo", systemImage: "photo",
                message: "Open a check below, choose your RAW file from Photos or Files, then tap Develop. View the result and return here to record what you saw. Appearance checks are observations; the report records the camera's setting checks separately.")
            if session.plan?.optionalChecks.contains(.dynamicRange) == true {
                GuidedNoticeCard(title: "For the extra Dynamic Range checks", systemImage: "slider.horizontal.3",
                    message: "Use RAW files taken with D-Range Priority OFF. To test DR200 or DR400, use a file shot at that range or higher. Choose a different source file for each check if needed.\n\nThe app cannot raise a file above its original Dynamic Range or switch off its captured Priority setting. Any reduction is shown with the result and is expected.")
            }
            ForEach(cases, id: \.id) { test in
                caseCard(test.id, title: test.title)
            }
            if session.plan?.optionalChecks.contains(.cameraReference) == true,
               let completion = session.kitchenCompletions?.last(where: { $0.run.caseID == "develop" && $0.hasSuccessfulOutput }) {
                referenceCard(completion)
            }
        } actions: {
            GuidedPrimaryButton(title: "Continue to restore or keep settings", systemImage: "arrow.right",
                                enabled: !isRunning) {
                stopReference()
                if session.develop == nil { session.develop = .init(state: .skipped, detail: "Develop was not attempted") }
                onAdvance()
            }
        }
        .onAppear { if referenceActive { camera.connector.expectRemoval(true) } }
        .onDisappear {
            // Do not clear an expectation already armed by the root for a different step.
            if referenceActive, session.step == .develop { camera.connector.expectRemoval(false) }
        }
        .sheet(item: $savedResult) { result in
            NavigationStack {
                SavedComparisonsView(batchID: result.value)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Back to Camera Test") { savedResult = nil }
                        }
                    }
            }
        }
    }

    private func caseCard(_ id: String, title: String) -> some View {
        let run = session.kitchenRuns?.last { $0.caseID == id }
        let completion = session.kitchenCompletions?.last { $0.run.id == run?.id }
        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let completion {
                let produced = completion.cells.filter(\.succeeded).count
                Text(completion.hasSuccessfulOutput ? "\(produced) photo\(produced == 1 ? "" : "s") ready to review\(completion.hasFailures ? "; some versions failed" : "")" : "No usable photo was produced. The failure is recorded.")
                    .font(.subheadline).foregroundStyle(completion.hasFailures ? Theme.warning : Theme.ink2)
                if completion.saveFailed {
                    Text("The photos could not be saved on this device. The report still records the attempt.")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                if let batchID = completion.savedBatchID {
                    Button("View photos") { savedResult = Identified(value: batchID) }
                }
                if completion.hasSuccessfulOutput {
                    ForEach(completion.run.recipes) { recipe in
                        Text("\(recipe.name): \(GuidedTestRecipes.observationGuidance(for: recipe.settings))")
                            .font(.caption).foregroundStyle(Theme.ink2)
                    }
                    GuidedAnswerPicker(question: produced == 1 ? "Does the photo open normally and look as described?" : "Do the photos open normally and look as described?",
                        answer: observation(completion.run.id.uuidString))
                }
            } else if run != nil {
                Text("This attempt has no saved result. Try again when ready; the earlier attempt stays in the report.")
                    .font(.caption).foregroundStyle(Theme.warning)
            } else {
                Text("Ready to try").font(.caption).foregroundStyle(Theme.ink3)
            }
            Button(completion == nil ? (id == "testKitchen" || id == "expandedKitchen" ? "Open Test Kitchen" : "Open Develop") : "Try again") {
                stopReference()
                onOpen(id)
            }
                .font(.subheadline.weight(.semibold))
                .disabled(isRunning)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).themedCard(cornerRadius: 16)
    }

    private func referenceCard(_ completion: GuidedKitchenCompletion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GuidedNoticeCard(title: "Compare with a JPEG made on the camera", systemImage: "camera",
                message: "1. Tap Start below, then unplug the USB cable.\n2. On the camera, use RAW Conversion on the same frame with the settings below. Apply any Dynamic Range adjustment shown here.\n3. Compare that JPEG with the app's saved photo. Colour and tone should be similar; grain can vary.\n4. Reconnect before another develop or restoring settings.\n\nChoose Didn't check if you cannot make or view the reference JPEG.")
            if referenceActive {
                Label("You can unplug now to use the camera's menus", systemImage: "cable.connector.slash")
                    .font(.caption).foregroundStyle(Theme.ink2)
                Button("Finish reference check", action: stopReference)
            } else {
                Button("Start reference check") {
                    referenceActive = true
                    camera.connector.expectRemoval(true)
                }
            }
            if let cell = completion.cells.first(where: \.succeeded) {
                Text(referenceRangeText(cell, recipe: completion.run.recipes.first))
                    .font(.subheadline)
                if !cell.clampedFields.isEmpty {
                    Text("Adjusted settings: \(cell.clampedFields.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(Theme.ink2)
                }
                ForEach(cell.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(Theme.ink2)
                }
            }
            if let recipe = completion.run.recipes.first {
                SettingsTable(rows: RecipeSettingsFormatter.rows(for: recipe.settings,
                    model: session.identifiedModelID.flatMap { CameraModelRegistry.shared.model(withID: $0) }))
            }
            GuidedAnswerPicker(question: "Do the two JPEGs have similar colour and tone?",
                answer: observation("reference:" + completion.run.id.uuidString))
        }
    }

    private func referenceRangeText(_ cell: GuidedKitchenCell, recipe: GuidedKitchenRecipe?) -> String {
        switch cell.dynamicRange {
        case "applied":
            return "Dynamic Range: \(recipe?.settings.dynamicRange?.displayName ?? "recipe setting")."
        case "untouched":
            return "Dynamic Range kept at the file's original setting."
        case nil:
            return "Dynamic Range was not recorded. Check the saved photo's details before comparing."
        default:
            return "Dynamic Range was adjusted. Use the value in the note below."
        }
    }

    private func stopReference() {
        guard referenceActive else { return }
        referenceActive = false
        camera.connector.expectRemoval(false)
    }

    private func observation(_ key: String) -> Binding<GuidedTestSession.Answer?> {
        Binding(get: { session.kitchenObservations?[key] }, set: { answer in
            var observations = session.kitchenObservations ?? [:]
            observations[key] = answer
            session.kitchenObservations = observations
            if let latest = session.kitchenCompletions?.last(where: { $0.run.caseID == "develop" }), latest.run.id.uuidString == key {
                session.develop?.jpegMatchesRecipe = answer
            }
            session.touch()
        })
    }
}

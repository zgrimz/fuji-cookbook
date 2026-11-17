import SwiftUI

/// The write pass: back up, push a recipe the app supplies, power-cycle the camera, and check what
/// actually survived.
struct GuidedWriteStepHost: View {
    let step: GuidedTestStep
    @Binding var session: GuidedTestSession
    @Binding var isRunning: Bool
    let onAdvance: () -> Void
    /// Explicitly declining or skipping writes bypasses the selected checks in the normal flow.
    let onAdvanceTo: (GuidedTestStep) -> Void
    let onOpenComparison: (Int) -> Void

    var body: some View {
        switch step {
        case .writeIntro: GuidedWriteIntroStep(session: $session, onAdvance: onAdvance, onDecline: { onAdvanceTo(.develop) })
        case .backup: GuidedBackupStep(session: $session, onAdvance: onAdvance)
        case .dialCheck: GuidedDialStep(session: $session, onAdvance: onAdvance, onDecline: { onAdvanceTo(.develop) })
        case .chooseRecipe: GuidedChooseRecipeStep(session: $session, onAdvance: onAdvance)
        case .chooseSlot: GuidedChooseSlotStep(session: $session, onAdvance: onAdvance)
        case .push: GuidedPushStep(session: $session, isRunning: $isRunning, onAdvance: onAdvance)
        case .powerCycle: GuidedPowerCycleStep(session: $session, isRunning: $isRunning, onAdvance: onAdvance)
        case .recheckSlot: GuidedRecheckStep(session: $session, onAdvance: onAdvance,
                                             onOpenComparison: onOpenComparison)
        case .photoCheck: GuidedPhotoCheckStep(session: $session, onAdvance: onAdvance)
        case .moreTrials: GuidedMoreTrialsStep(session: $session, onAdvance: onAdvance,
                                               onSkipRemaining: { onAdvanceTo(session.isContinuous ? .develop : .restoreOffer) })
        case .restoreOffer: GuidedRestoreStep(session: $session, isRunning: $isRunning, onAdvance: onAdvance)
        default: EmptyView()
        }
    }
}

// MARK: - Consent

struct GuidedWriteIntroStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void
    let onDecline: () -> Void

    @Environment(CameraServices.self) private var camera

    var body: some View {
        GuidedStepLayout(title: "Check writing recipes",
                         subtitle: "You'll choose a custom slot for the test recipe.") {
            GuidedGate(session: $session)
            if let note = camera.session.connected?.testerNote {
                GuidedNoticeCard(title: "Help confirm this camera model",
                                 systemImage: "info.circle", message: note)
            }
            GuidedNoticeCard(
                title: "What happens",
                systemImage: "square.and.arrow.up",
                message: "The app saves your original slot settings on this phone before writing. It then checks grain, writes a test recipe to your chosen slot, and checks the recipe after a restart. At the end, you can restore the originals or keep the test recipe. You can also export a backup copy.")
            GuidedNoticeCard(
                title: "The app brings the recipes",
                systemImage: "list.bullet.rectangle",
                message: "You don't need to find a recipe. The app supplies test recipes suited to your camera and shows the settings it will write. CT Priority checks REALA ACE and D-Range Priority on the X-T30 III and X-M5.")
            GuidedNoticeCard(
                title: "Your slot during the test",
                systemImage: "arrow.uturn.backward",
                message: "The grain check briefly changes the grain setting, then checks that the original setting is back. A recipe write replaces settings in the slot you choose. If a setting cannot be written or restored, the results name it and the original copy stays available.\n\nAn empty slot will keep a recipe afterwards. A slot with no name is restored without one.")
        } actions: {
            GuidedPrimaryButton(title: "Continue to writing checks", systemImage: "arrow.right") {
                var pass = session.writePass ?? .init()
                pass.consentAt = CameraCompatibilityReport.timestamp()
                session.writePass = pass
                onAdvance()
            }
            GuidedSecondaryButton(title: "Skip writing checks", action: onDecline)
        }
    }
}

// MARK: - Backup

struct GuidedBackupStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void
    @Environment(CameraServices.self) private var camera
    @State private var sharing = false
    @State private var problem: String?

    private var recovery: GuidedRecoveryRecord? { GuidedRecoveryStore.load(sessionID: session.id) }
    var body: some View {
        GuidedStepLayout(title: "Save your original settings",
                         subtitle: "This recovery copy stays the same throughout the test.") {
            GuidedGate(session: $session)
            if let recovery {
                GuidedNoticeCard(title: "Recovery settings saved", systemImage: "checkmark.shield",
                    message: "The original settings of \(recovery.backup.slots.count) slots are saved on this phone. This copy stays available when you reconnect or try another recipe, and is the copy used to restore your slots at the end.")
                Button("Export a backup copy") { sharing = true }
            } else {
                GuidedNoticeCard(title: "Recovery copy needed", systemImage: "externaldrive",
                    message: problem ?? "Connect the same camera to save its original settings before the first test write.")
            }
        } actions: {
            if recovery != nil {
                GuidedPrimaryButton(title: "Continue", systemImage: "arrow.right", action: onAdvance)
            } else {
                GuidedPrimaryButton(title: "Save recovery settings", systemImage: "externaldrive", enabled: GuidedTestRunner.gate(camera).isReady, action: prepare)
            }
        }
        .task { if recovery == nil { prepare() } }
        .sheet(isPresented: $sharing) {
            if let recovery { ShareBundle.backupShareSheet(recovery.backup) }
        }
    }
    private func prepare() {
        var current = session
        problem = GuidedTestRunner.prepareRecovery(camera, session: &current)
        if problem == nil { session = current }
    }
}

// MARK: - Dial

struct GuidedDialStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void
    let onDecline: () -> Void

    var body: some View {
        GuidedStepLayout(title: "Set the dial to C",
                         subtitle: "Your camera has a physical Film Simulation dial.") {
            GuidedGate(session: $session)
            GuidedNoticeCard(
                title: "Turn it to C, and leave it there",
                systemImage: "dial.medium",
                message: "Set the Film Simulation dial to C so the camera uses the simulation saved in each custom slot. Leave it on C through the menu and photo checks.")
        } actions: {
            GuidedPrimaryButton(title: "The dial is on C", systemImage: "checkmark") {
                var pass = session.writePass ?? .init()
                pass.dialConfirmed = true
                session.writePass = pass
                onAdvance()
            }
            GuidedSecondaryButton(title: "I can't set it right now") {
                var pass = session.writePass ?? .init()
                pass.dialConfirmed = false
                session.writePass = pass
                onDecline()
            }
        }
    }
}

// MARK: - Choose

/// Bank mode is a human check: USB does not tell the app whether an X-M5 bank is STILL or MOVIE.
/// Reused by the grain check and recipe chooser, which may target different banks.
struct GuidedStillBankConfirmation: View {
    @Binding var session: GuidedTestSession
    let slot: Int
    let modelID: String?
    var isRunning = false

    var body: some View {
        if modelID == "X-M5" {
            VStack(alignment: .leading, spacing: 12) {
                Text("Use a still-photography bank").font(.headline)
                Text("On the camera, check IQ → CUSTOM MODE SETTING and make sure C\(slot) is assigned to STILL. Unplug to use the camera's menus if needed, then reconnect. The Film Simulation dial's C position is a separate setting.")
                    .font(.subheadline).foregroundStyle(Theme.ink2)
                Toggle("I checked that C\(slot) is assigned to STILL", isOn: Binding(
                    get: { session.hasConfirmedStillBank(slot) },
                    set: { session.setStillBankConfirmation(slot, confirmed: $0) }))
                    .font(.subheadline).disabled(isRunning)
                Text("The report records your confirmation; the app cannot detect this setting.")
                    .font(.caption).foregroundStyle(Theme.ink3)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).themedCard(cornerRadius: 16)
        }
    }
}

/// Prepare the write slot so the gated writes are tested rather than refused.
///
/// Dynamic Range and D-Range Priority are refused below an ISO threshold (2× and 4× base ISO on
/// the bodies measured) and Clarity on a HEIF bank, and none of that state is among the 23
/// readable properties. Left alone, the mandatory CT Priority trial's defining write is refused on
/// most spare banks and never tests the encoding. Either answer is recorded; "left as it was" makes
/// the refusals that follow expected rather than findings. Not a write gate, deliberately: see
/// `GuidedTestRunner.mutationBlockReason`.
struct GuidedSlotPreparation: View {
    @Binding var session: GuidedTestSession
    let slot: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prepare C\(slot) for the test").font(.headline)
            Text("Unplug the camera. In EDIT/SAVE CUSTOM SETTING → EDIT/CHECK → C\(slot), set ISO to 800 or higher (1600 is a safe choice) and make sure the image format is JPEG, not HEIF. Then plug the camera back in.")
                .font(.subheadline).foregroundStyle(Theme.ink2)
            Text("The camera refuses Dynamic Range and D-Range Priority below an ISO threshold, and Clarity on a HEIF bank. Preparing the slot lets the test write them. The app doesn't restore ISO or image format afterwards.")
                .font(.caption).foregroundStyle(Theme.ink3)
            GuidedChoiceRow<GuidedTestSession.SlotPreparation>(
                choices: [.init(value: .setForTest, label: "I've set it"),
                          .init(value: .leftUnchanged, label: "I left it as it was")],
                selection: Binding(get: { session.writePass?.trial?.preparation }, set: { record($0) }))
            Text("The report records your answer; the app cannot read these settings.")
                .font(.caption).foregroundStyle(Theme.ink3)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).themedCard(cornerRadius: 16)
    }

    private func record(_ value: GuidedTestSession.SlotPreparation?) {
        guard var pass = session.writePass, let index = pass.currentTrial else { return }
        pass.trials[index].preparation = value
        pass.trials[index].preparationConfirmedAt = value == nil ? nil : CameraCompatibilityReport.timestamp()
        session.writePass = pass
        session.touch()
    }
}

struct GuidedChooseRecipeStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void

    @State private var chosen: String?

    private var recipes: [GuidedTestRecipes.TestRecipe] {
        GuidedTestFlow.writeRecipes(session: session)
    }

    /// The one they haven't pushed yet, so a second trial doesn't repeat the first.
    private var suggested: String? {
        GuidedTestFlow.suggestedWriteRecipe(session: session)?.id
    }

    var body: some View {
        GuidedStepLayout(title: "Choose a test recipe",
                         subtitle: "Each recipe checks a different set of camera settings.") {
            GuidedGate(session: $session)
            VStack(spacing: 0) {
                ForEach(Array(recipes.enumerated()), id: \.element.id) { index, recipe in
                    Button { chosen = recipe.id } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: chosen == recipe.id ? "largecircle.fill.circle" : "circle")
                                .font(.title3)
                                .foregroundStyle(chosen == recipe.id ? Theme.accent : Theme.ink3.opacity(0.6))
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    FilmSwatch(simulation: recipe.settings.filmSimulation, size: 12)
                                    Text(recipe.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                    if alreadyPushed(recipe.id) {
                                        BadgeTag(text: "pushed")
                                    }
                                }
                                Text(recipe.purpose)
                                    .font(.caption)
                                    .foregroundStyle(Theme.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < recipes.count - 1 {
                        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 46)
                    }
                }
            }
            .themedCard(cornerRadius: 16)

            if let recipe = recipes.first(where: { $0.id == chosen }), let model = session.cameraModel {
                Text("What gets written")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 4)
                SettingsTable(rows: RecipeSettingsFormatter.rows(for: recipe.settings, model: model))
            }
        } actions: {
            GuidedPrimaryButton(title: "Continue", systemImage: "arrow.right", enabled: chosen != nil) {
                guard let id = chosen, let recipe = recipes.first(where: { $0.id == id }) else { return }
                var pass = session.writePass ?? .init()
                let trial = GuidedTestSession.PushTrial(recipe: recipe.id, recipeName: recipe.name, slot: session.selectedWriteSlot ?? 0)
                if let index = pass.currentTrial, pass.trials.indices.contains(index), pass.trials[index].outcome == nil {
                    pass.trials[index] = trial
                } else {
                    pass.trials.append(trial)
                    pass.currentTrial = pass.trials.count - 1
                }
                session.writePass = pass
                onAdvance()
            }
        }
        .onAppear { chosen = chosen ?? suggested }
    }

    private func alreadyPushed(_ id: String) -> Bool {
        (session.writePass?.trials ?? []).contains { $0.recipe == id && $0.pushedAt != nil }
    }
}

struct GuidedChooseSlotStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void

    @Environment(CameraServices.self) private var camera
    @State private var chosen: Int?
    @State private var lastReadSlots: [CameraSlot] = []

    /// Keep the choices visible while the tester unplugs to inspect CUSTOM MODE SETTING.
    /// These are presentation snapshots only; the runner checks the live body and slot again.
    private var displayedSlots: [CameraSlot] {
        GuidedTestFlow.describesSameBody(stored: session, facts: GuidedTestRunner.facts(camera))
            && !camera.slotReader.slots.isEmpty ? camera.slotReader.slots : lastReadSlots
    }

    /// See `GuidedTestFlow.suggestedWriteSlot` — the rule lives there so it can be tested.
    private var suggestedSlot: Int? { GuidedTestFlow.suggestedWriteSlot(in: displayedSlots, session: session) }

    var body: some View {
        GuidedStepLayout(title: "Choose a slot",
                         subtitle: "Choose which slot may hold the test recipe.") {
            // Preparing the slot (and, on an X-M5, checking CUSTOM MODE SETTING) needs the camera's
            // menu, so an unplug is expected once there is a slot to prepare. After a relaunch there
            // may be no choices yet, so keep the gate's Reconnect action available to read them.
            GuidedGate(session: $session, unplugExpected: chosen != nil)
            if displayedSlots.isEmpty {
                Text("Reconnect the test camera to read the available slots. Your earlier answers and original settings remain saved.")
                    .font(.subheadline).foregroundStyle(Theme.ink2)
            }
            VStack(spacing: 0) {
                ForEach(displayedSlots) { slot in
                    Button { chosen = slot.index } label: {
                        HStack(spacing: 12) {
                            Image(systemName: chosen == slot.index ? "largecircle.fill.circle" : "circle")
                                .font(.title3)
                                .foregroundStyle(chosen == slot.index ? Theme.accent : Theme.ink3.opacity(0.6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slot.label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                // A bank nobody has named is very often a bank nobody has used —
                                // and on a body where no slot ever reads as empty, telling the
                                // tester it "holds PROVIA" in orange is a warning about nothing.
                                Text(slot.isOccupied
                                     ? (slot.resolvedName == nil
                                        ? "Unnamed · \(slot.displayName)"
                                        : "Currently \(slot.displayName)")
                                     : "Empty")
                                    .font(.caption)
                                    .foregroundStyle(slot.isOccupied && slot.resolvedName != nil
                                                     ? Theme.warning : Theme.ink3)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if slot.index != displayedSlots.last?.index {
                        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 46)
                    }
                }
            }
            .themedCard(cornerRadius: 16)

            if let chosen {
                GuidedStillBankConfirmation(session: $session, slot: chosen, modelID: session.identifiedModelID)
                GuidedSlotPreparation(session: $session, slot: chosen)
            }

            // An empty slot risks none of the tester's work, which is why it is preferred — but it
            // is also the only slot the test cannot put back, and saying so is the difference
            // between an informed choice and a surprise.
            if let chosen, displayedSlots.first(where: { $0.index == chosen })?.isOccupied == false {
                GuidedNoticeCard(
                    title: "C\(chosen) will still have a recipe in it afterwards",
                    systemImage: "info.circle",
                    message: "\(CameraBackup.slotCannotBeEmptied) You can keep the test recipe in C\(chosen), or replace it with another recipe later.")
            }
            // Two different warnings, because they are two different situations. A bank with a
            // name is someone's work. A bank without one is, on every body seen so far, the
            // camera's own defaults — and on a body where no slot ever reads as empty, that is the
            // *only* safe choice available.
            if let chosen, let slot = displayedSlots.first(where: { $0.index == chosen }),
               slot.isOccupied {
                let backedUp = GuidedRecoveryStore.load(sessionID: session.id) != nil
                let fallback = backedUp
                    ? "Its original settings are saved. The test offers to restore them at the end."
                    : "Save the original recovery settings before writing."
                if slot.resolvedName == nil {
                    GuidedNoticeCard(
                        title: "C\(chosen) has no name on the camera",
                        systemImage: "info.circle",
                        message: "An unnamed slot can still contain your settings. \(fallback) Restoring it puts it back with no name.")
                } else {
                    GuidedNoticeCard(
                        title: "The test recipe will replace C\(chosen)'s settings",
                        systemImage: "arrow.uturn.backward",
                        message: fallback)
                }
            }
        } actions: {
            GuidedPrimaryButton(title: "Continue", systemImage: "arrow.right",
                                enabled: chosen.map {
                                    (session.identifiedModelID != "X-M5" || session.hasConfirmedStillBank($0))
                                        && session.writePass?.trial?.preparation != nil
                                } == true) {
                guard let chosen, var pass = session.writePass, let index = pass.currentTrial else { return }
                pass.trials[index].slot = chosen
                session.selectedWriteSlot = chosen
                session.writePass = pass
                onAdvance()
            }
        }
        .onAppear { retainSlotChoices(); chosen = chosen ?? suggestedSlot }
        .onChange(of: camera.slotReader.slots) { _, _ in
            retainSlotChoices()
            if chosen == nil { chosen = suggestedSlot }
        }
        .onChange(of: chosen) { previous, _ in
            // An answer describes the slot it was given for. Changing slots after answering would
            // file one bank's preparation under another. The first assignment, from nil, is the
            // screen restoring a stored choice, whose answer still stands.
            guard previous != nil, var pass = session.writePass, let index = pass.currentTrial,
                  pass.trials[index].preparation != nil else { return }
            pass.trials[index].preparation = nil
            pass.trials[index].preparationConfirmedAt = nil
            session.writePass = pass
            session.touch()
        }
    }

    private func retainSlotChoices() {
        guard GuidedTestFlow.describesSameBody(stored: session, facts: GuidedTestRunner.facts(camera)),
              !camera.slotReader.slots.isEmpty else { return }
        lastReadSlots = camera.slotReader.slots
    }
}

// MARK: - Push

struct GuidedPushStep: View {
    @Binding var session: GuidedTestSession
    @Binding var isRunning: Bool
    let onAdvance: () -> Void

    @Environment(CameraServices.self) private var camera
    @State private var results: [SlotWriteResult] = []
    @State private var showingResults = false
    @State private var showingConfirm = false

    /// Deliberately the slot-checked accessor: reached from the hub without the chooser, the
    /// trial's slot is still 0 and this screen would offer to write to C0.
    private var trial: GuidedTestSession.PushTrial? { session.writePass?.trialWithASlot }

    var body: some View {
        GuidedStepLayout(title: "Write it to the camera",
                         subtitle: trial.map { "\($0.recipeName) → C\($0.slot)" }) {
            GuidedGate(session: $session)
            if let trial, trial.pushedAt != nil, let outcome = trial.outcome {
                GuidedNoticeCard(
                    title: outcomeTitle(outcome),
                    systemImage: outcome == .applied ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    tint: outcome == .applied ? Theme.accent : Theme.warning,
                    message: "The report records the camera's response for each setting. The remaining checks show what was saved and how it looks on the camera.")
            } else {
                GuidedNoticeCard(
                    title: "Leave the cable connected",
                    systemImage: "cable.connector",
                    message: "Don't unplug the camera while the app writes and checks the recipe. Wait for the results before continuing.")
            }
        } actions: {
            if trial?.outcome != nil {
                GuidedPrimaryButton(title: "Continue", systemImage: "arrow.right", action: onAdvance)
                GuidedSecondaryButton(title: "See what the camera said",
                                      enabled: !results.isEmpty) { showingResults = true }
            } else {
                let blockReason = GuidedTestRunner.mutationBlockReason(camera, session: session, slot: trial?.slot ?? 0, kind: .recipeWrite)
                if let blockReason {
                    Text(blockReason).font(.caption).foregroundStyle(Theme.warning)
                }
                GuidedPrimaryButton(title: "Write to C\(trial?.slot ?? 0)", systemImage: "square.and.arrow.up",
                                    enabled: blockReason == nil,
                                    busy: isRunning) { showingConfirm = true }
            }
        }
        .confirmationDialog("Write \(trial?.recipeName ?? "this recipe") to C\(trial?.slot ?? 0)?",
                            isPresented: $showingConfirm, titleVisibility: .visible) {
            Button("Write", role: .destructive) { push() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every setting is read back from the camera and checked against what was sent.")
        }
        .sheet(isPresented: $showingResults) { PushResultsView(results: results) }
    }

    private func outcomeTitle(_ outcome: SlotOutcome) -> String {
        switch outcome {
        case .applied: return "Written and verified"
        case .partiallyApplied: return "Partly written"
        case .unknown: return "Couldn't confirm what was saved"
        case .notWritten: return "Not written"
        }
    }

    private func push() {
        guard let model = camera.session.model, var pass = session.writePass, let index = pass.currentTrial,
              let recipe = GuidedTestRecipes.recipe(id: pass.trials[index].recipe, for: model)
        else { return }
        Task {
            isRunning = true
            let outcome = await GuidedTestRunner.runPush(camera, recipe: recipe,
                                                         slot: pass.trials[index].slot, session: session)
            pass.trials[index] = outcome.trial
            session.writePass = pass
            session.touch()
            if let result = outcome.result { results = [result] }
            isRunning = false
        }
    }
}

// MARK: - Power cycle

/// There is a failure where a write reports success, reads back correctly, and then quietly isn't
/// there after the camera has been switched off and on. Nothing in the app can see it — the
/// read-back happens while the value is still there — so this step is the only thing that catches it.
struct GuidedPowerCycleStep: View {
    @State private var sawDisconnect = false
    @Binding var session: GuidedTestSession
    @Binding var isRunning: Bool
    let onAdvance: () -> Void

    @Environment(CameraServices.self) private var camera

    private var trial: GuidedTestSession.PushTrial? { session.writePass?.trial }
    private var persistence: GuidedTestSession.Persistence? { trial?.persistence }

    var body: some View {
        GuidedStepLayout(title: "Switch the camera off and on",
                         subtitle: "Check that the recipe stays saved after a restart.") {
            GuidedGate(session: $session, unplugExpected: true)
            GuidedNoticeCard(
                title: "What to do",
                systemImage: "power",
                message: "Turn the camera off, wait a few seconds, then turn it back on. Reconnect if the app asks. Once it's connected, tap the button below to read the slot again.")
            GuidedNoticeCard(
                title: "What this checks",
                systemImage: "questionmark.circle",
                message: "Reading the slot after a restart confirms whether the camera saved the recipe, including its name. Before the restart, a red dot on the pushed settings in EDIT/SAVE CUSTOM SETTING is expected and harmless; it clears when the camera comes back on. Your progress is saved on this phone.")
            if let persistence {
                resultCard(persistence)
            }
        } actions: {
            if persistence == nil {
                // `isConnected` is not enough, and the difference decides whether this step can
                // lie. A dropped session leaves `connected` and `slots` in place while recovery
                // runs — only the transport is nil — so a button tappable mid-recovery would have
                // `check()` compare the *pre-power-cycle* slot reads and record "the recipe
                // survived". On the one step whose entire purpose is catching a recipe that didn't.
                GuidedPrimaryButton(title: "I've switched it off and on",
                                    systemImage: "arrow.clockwise",
                                    enabled: GuidedTestRunner.gate(camera).isReady && GuidedTestFlow.describesSameBody(stored: session, facts: GuidedTestRunner.facts(camera)),
                                    busy: isRunning) { check() }
                if !camera.session.isConnected {
                    GuidedSecondaryButton(title: "Reconnect") {
                        Task {
                            isRunning = true
                            await GuidedTestRunner.reconnect(camera, transport: session.transport)
                            isRunning = false
                        }
                    }
                }
            } else {
                GuidedPrimaryButton(title: "Continue", systemImage: "arrow.right", action: onAdvance)
            }
        }
        .onChange(of: camera.connector.isRecovering) { _, recovering in if recovering { sawDisconnect = true } }
        .onChange(of: camera.session.isConnected) { _, connected in if !connected { sawDisconnect = true } }
    }

    private func resultCard(_ persistence: GuidedTestSession.Persistence) -> some View {
        let state = persistence.evidenceState
        return GuidedNoticeCard(title: state == .passed ? "Settings stayed saved" : state == .issueFound ? "A setting or name changed" : "Couldn't verify the saved settings",
            systemImage: state == .passed ? "checkmark.circle" : "exclamationmark.circle",
            tint: state == .passed ? Theme.accent : Theme.warning,
            message: "Settings: \(verificationLabel(persistence.settingsState)). Name: \(verificationLabel(persistence.nameState)). "
                + (persistence.differences.isEmpty ? "" : "Differences: \(persistence.differences.map(\.field).joined(separator: ", ")). ")
                + "The report keeps the write result and this fresh read separately.")
    }

    private func verificationLabel(_ state: GuidedTestSession.VerificationState?) -> String {
        switch state {
        case .passed?: return "verified"
        case .issueFound?: return "issue found"
        case .couldNotVerify?: return "could not verify"
        case .notTested?, nil: return "not tested"
        }
    }

    private func check() {
        guard GuidedTestRunner.gate(camera).isReady,
              GuidedTestFlow.describesSameBody(stored: session, facts: GuidedTestRunner.facts(camera)),
              var pass = session.writePass, let index = pass.currentTrial else { return }
        Task {
            isRunning = true
            // Not `ensureSlots`: it short-circuits once `SlotReader.hasRead`, so after a
            // reconnect it returns ready without reading anything, and this step would judge
            // persistence from whatever the last read left behind. The whole question here is what
            // the camera holds *now*.
            let readStartedAt = CameraCompatibilityReport.timestamp()
            let read = try? await camera.slotReader.requestRefresh()
            let trial = pass.trials[index]
            let slot = camera.slotReader.slots.first { $0.index == trial.slot }
            let freshReadSucceeded = read != nil && GuidedTestRunner.gate(camera).isReady
                && GuidedTestFlow.describesSameBody(stored: session, facts: GuidedTestRunner.facts(camera))
                && GuidedTestRunner.slotReadFailure(camera.reports.report?.slots, model: camera.session.model,
                                       maySelectSlots: camera.session.maySelectSlots) == nil
                && camera.reports.report?.slots.readAt.map { $0 >= readStartedAt } == true
            pass.trials[index].persistence = GuidedTestFlow.persistence(
                trial: trial, slot: slot, nameApplied: trial.nameApplied,
                freshReadSucceeded: freshReadSucceeded, restartConfirmed: true,
                connectionChanged: GuidedTestFlow.connectionChanged(for: trial,
                    currentID: camera.reports.report?.connectionID,
                    currentStartedAt: camera.reports.report?.generatedAt, observedDisconnect: sawDisconnect),
                readAt: camera.reports.report?.slots.readAt,
                connectionStartedAt: camera.reports.report?.generatedAt,
                connectionID: camera.reports.report?.connectionID)
            // Snapshot the slot for the menu check here rather than on that step: this is the last
            // point the camera is guaranteed attached (the button above requires it), and the next
            // step asks the tester to unplug again to read the camera's own menu.
            if freshReadSucceeded, let slot, trial.menuComparison == nil {
                pass.trials[index].menuComparison = GuidedTestFlow.comparison(for: slot, model: camera.session.model)
            }
            session.writePass = pass
            session.touch()
            isRunning = false
        }
    }
}

// MARK: - Recheck, photo, more

struct GuidedRecheckStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void
    let onOpenComparison: (Int) -> Void

    @Environment(CameraServices.self) private var camera

    private var trial: GuidedTestSession.PushTrial? { session.writePass?.trial }

    var body: some View {
        GuidedStepLayout(title: "Check the slot again",
                         subtitle: "Same comparison as before, on the slot you just wrote to.") {
            GuidedGate(session: $session, unplugExpected: true)
            GuidedNoticeCard(
                title: "What to look for",
                systemImage: "eye",
                message: "Open C\(trial?.slot ?? 0) in the camera's Image Quality (IQ) menu. Compare its settings with the app's list from the restart check. This confirms that the app and camera use the same meanings for the settings.")
            GuidedNoticeCard(
                title: "Unplug the camera first",
                systemImage: "cable.connector.slash",
                message: "The camera's menus are locked while the cable is in, so unplug it now — and leave it out for the photo on the next step. The app already has what it read; this comparison works disconnected.")
            autoUpdateCard
            if let comparison = trial?.menuComparison, comparison.checkedAt != nil {
                GuidedNoticeCard(
                    title: comparison.verdict == "matches" ? "It matched" : "Comparison needs review",
                    systemImage: comparison.verdict == "matches" ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    tint: comparison.verdict == "matches" ? Theme.accent : Theme.warning,
                    message: comparison.verdict == "differs"
                        ? "\(comparison.rows.filter(\.differs).count) setting(s) differ from what the camera shows. That's in the report."
                        : comparison.verdict == "matches" ? "What the app read agrees with the camera's own menu." : "Some settings could not be read. Your camera-menu observations are retained separately.")
            }
        } actions: {
            // Before the comparison the step's work is comparing; after it, the work is done and
            // moving on is the main line. "Continue" as a secondary read as an unlabelled skip.
            if trial?.menuComparison?.checkedAt != nil {
                GuidedPrimaryButton(title: "Continue", systemImage: "arrow.right", action: onAdvance)
                GuidedSecondaryButton(title: "Compare C\(trial?.slot ?? 0) again",
                                      enabled: trial?.slot != nil) {
                    if let index = trial?.slot { onOpenComparison(index) }
                }
            } else {
                GuidedPrimaryButton(title: "Compare C\(trial?.slot ?? 0)", systemImage: "list.bullet",
                                    enabled: trial?.slot != nil) {
                    if let index = trial?.slot { onOpenComparison(index) }
                }
                GuidedSecondaryButton(title: "Skip — I can't check the camera now", action: onAdvance)
            }
        }
        // Snapshot the pushed slot while the camera is still attached — the power cycle has just
        // reconnected it, and the tester is about to unplug again to read the menu.
        .task { seed() }
    }

    /// Camera-wide, asked here because the tester is already in EDIT/SAVE CUSTOM SETTING for the
    /// written bank, and asked on every run: the protocol record's persistence results are all
    /// conditional on this state because no passing run recorded it either.
    private var autoUpdateCard: some View {
        let selection = Binding(get: { session.writePass?.autoUpdateCustomSetting },
                                set: { recordAutoUpdate($0) })
        return VStack(alignment: .leading, spacing: 10) {
            Text("While you're there: what is AUTO UPDATE CUSTOM SETTING set to?")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("It's in the same EDIT/SAVE CUSTOM SETTING menu. It decides whether changes made on the camera save to the bank automatically, and every restart result is read against it.")
                .font(.caption).foregroundStyle(Theme.ink2)
            GuidedChoiceRow<GuidedTestSession.AutoUpdateAnswer>(
                choices: [.init(value: .enable, label: "Enable"), .init(value: .disable, label: "Disable")],
                selection: selection)
            GuidedChoiceRow<GuidedTestSession.AutoUpdateAnswer>(
                choices: [.init(value: .notInMenu, label: "Not in this camera's menu"),
                          .init(value: .notChecked, label: "Didn't check")],
                selection: selection)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).themedCard(cornerRadius: 16)
    }

    private func recordAutoUpdate(_ value: GuidedTestSession.AutoUpdateAnswer?) {
        var pass = session.writePass ?? .init()
        pass.autoUpdateCustomSetting = value
        session.writePass = pass
        session.touch()
    }

    /// The pushed slot as the app read it back, stored on the trial before the cable comes out.
    private func seed() {
        guard var pass = session.writePass, let index = pass.currentTrial,
              pass.trials[index].menuComparison == nil,
              let slot = camera.slotReader.slots.first(where: { $0.index == pass.trials[index].slot })
        else { return }
        pass.trials[index].menuComparison = GuidedTestFlow.comparison(for: slot, model: camera.session.model)
        session.writePass = pass
        session.touch()
    }
}

struct GuidedPhotoCheckStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void

    @State private var answer: GuidedTestSession.Answer?
    @State private var note = ""

    private var trial: GuidedTestSession.PushTrial? { session.writePass?.trial }
    private var expectedSettings: RecipeSettings? {
        if let saved = trial?.recipeSettings { return saved }
        guard let trial, let model = session.cameraModel else { return nil }
        return GuidedTestRecipes.recipe(id: trial.recipe, for: model)?.settings
    }

    private var shootingInstructions: String {
        var message = "With the cable unplugged, select C\(trial?.slot ?? 0)"
        if let name = trial?.nameApplied { message += ", named “\(name)”" }
        message += "."
        if let simulation = expectedSettings?.filmSimulation {
            message += " Confirm that the camera displays \(simulation.displayName)."
        }
        return message + " Take one photo with some light and dark areas, then open it on the camera's playback screen. An everyday scene is fine."
    }

    var body: some View {
        GuidedStepLayout(title: "Take one photo",
                         subtitle: "See how \(trial?.recipeName ?? "the test recipe") looks in a photo.") {
            GuidedNoticeCard(
                title: "What to do",
                systemImage: "camera.shutter.button",
                message: shootingInstructions)
            if let settings = expectedSettings {
                GuidedNoticeCard(title: "What to look for", systemImage: "eye",
                    message: GuidedTestRecipes.observationGuidance(for: settings))
            } else {
                GuidedNoticeCard(title: "What to look for", systemImage: "eye",
                    message: "Check that the photo opens normally, with no missing areas, stripes or obvious image corruption. The saved recipe details are unavailable for this older test, so you don't need to judge its exact colours.")
            }
            GuidedAnswerPicker(question: "Does the photo open normally and look as described?",
                               answer: Binding(get: { answer }, set: { answer = $0; store() }))
            if answer == .no {
                GuidedTextField(label: "What did you notice?",
                                placeholder: "For example: the photo has stripes, or is monochrome instead of colour",
                                axis: .vertical,
                                text: Binding(get: { note }, set: { note = $0; store() }))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themedCard(cornerRadius: 16)
            }
        } actions: {
            GuidedPrimaryButton(title: "Continue", systemImage: "arrow.right", action: onAdvance)
        }
        .onAppear {
            answer = trial?.photoMatchesRecipe
            note = trial?.photoNote ?? ""
        }
    }

    private func store() {
        guard var pass = session.writePass, let index = pass.currentTrial else { return }
        pass.trials[index].photoMatchesRecipe = answer
        pass.trials[index].photoNote = note.isEmpty ? nil : note
        session.writePass = pass
        session.touch()
    }
}

struct GuidedMoreTrialsStep: View {
    @Binding var session: GuidedTestSession
    let onAdvance: () -> Void
    let onSkipRemaining: () -> Void

    private var remaining: [GuidedTestRecipes.TestRecipe] {
        GuidedTestFlow.remainingWriteRecipes(session: session)
    }

    var body: some View {
        GuidedStepLayout(title: "Additional write checks",
                         subtitle: "CT Colour is the first extra; each recipe adds different coverage.") {
            GuidedPlanChoices(session: $session)
            if remaining.isEmpty {
                GuidedNoticeCard(title: "No additional writes remaining", systemImage: "checklist",
                                 message: "Continue, or select another recipe above. The report keeps each completed trial and any omitted checks separate.")
            } else {
                ForEach(remaining) { recipe in
                    GuidedNoticeCard(title: recipe.name, systemImage: "plus.circle",
                                     message: recipe.purpose)
                }
            }
        } actions: {
            if !remaining.isEmpty, let next = GuidedTestFlow.suggestedWriteRecipe(session: session) {
                GuidedPrimaryButton(title: "Continue with \(next.name)", systemImage: "arrow.right",
                                    action: onAdvance)
                GuidedSecondaryButton(title: "Skip remaining writes", action: onSkipRemaining)
            } else {
                GuidedPrimaryButton(title: session.isContinuous ? "Continue to Develop" : "Continue to Restore",
                                    systemImage: "arrow.right", action: onAdvance)
            }
        }
    }
}

// MARK: - Restore

struct GuidedRestoreStep: View {
    @Binding var session: GuidedTestSession
    @Binding var isRunning: Bool
    let onAdvance: () -> Void
    @Environment(CameraServices.self) private var camera
    @State private var restoring: RestoreTarget?
    @State private var error: String?
    @State private var revision = 0

    private struct RestoreTarget: Identifiable {
        let slot: Int
        let name: String
        let saved: [UInt16: Data]
        let originalNameRestorable: Bool
        let originalName: String?
        var id: Int { slot }
    }
    private var recovery: GuidedRecoveryRecord? { GuidedRecoveryStore.load(sessionID: session.id) }
    private var touchedSlots: [Int] {
        _ = revision
        return recovery?.touchedSlots ?? Array(Set((session.writePass?.trials ?? []).filter { $0.pushedAt != nil }.map(\.slot))).sorted()
    }
    private var sameBody: Bool { recovery?.matches(GuidedTestRunner.facts(camera)) == true }

    var body: some View {
        GuidedStepLayout(title: "Restore your original settings", subtitle: "Or choose to keep the test recipe.") {
            GuidedGate(session: $session)
            if touchedSlots.isEmpty {
                GuidedNoticeCard(title: "No slots to restore", systemImage: "checkmark.circle",
                    message: "No test recipe was written. Continue to review the results.")
            }
            if let error { Text(error).foregroundStyle(Theme.warning) }
            ForEach(touchedSlots, id: \.self) { slot in
                slotCard(slot)
            }
            if recovery == nil && !touchedSlots.isEmpty {
                GuidedNoticeCard(title: "Original recovery copy unavailable", systemImage: "exclamationmark.circle",
                    tint: Theme.warning, message: "This test has no saved original settings on this phone. If you exported a backup, use Restore a Slot on the Camera screen to put those settings back.")
            }
        } actions: {
            GuidedPrimaryButton(title: "Review results", systemImage: "arrow.right", enabled: !isRunning, action: onAdvance)
        }
        .sheet(item: $restoring, onDismiss: { isRunning = false }) { target in
            RestoreView(slot: target.slot, slotName: target.name, saved: target.saved,
                        source: .backup(name: "Camera Test original settings"),
                        onFinish: { completion in record(target.slot, outcome: Self.disposition(for: completion)) },
                        onWritingChanged: { isRunning = $0 },
                        canRestore: { sameBody && GuidedTestRunner.gate(camera).isReady },
                        originalNameRestorable: target.originalNameRestorable,
                        originalName: target.originalName,
                        onVerification: { verification in recordVerification(target.slot, verification: verification) })
        }
    }

    private func slotCard(_ slot: Int) -> some View {
        let original = recovery?.backup.slots.first { $0.index == slot }
        let disposition = recovery?.dispositions[String(slot)]
        return VStack(alignment: .leading, spacing: 12) {
            Text("C\(slot) · \(disposition == .restored ? "Restored and verified" : disposition?.isKeptByChoice == true ? "Kept by choice" : "Needs attention")").font(.headline)
            if (session.writePass?.trials ?? []).contains(where: { $0.slot == slot && $0.preparation == .setForTest }) {
                Text("You set this slot's ISO and image format for the test. The app doesn't restore them; put them back in the camera's menu.")
                    .font(.caption).foregroundStyle(Theme.ink3)
            }
            if original?.occupied == false {
                Text("This slot was empty. \(CameraBackup.slotCannotBeEmptied)").font(.caption)
                Button("Keep the test recipe in C\(slot)") { record(slot, outcome: .emptyKept) }
            } else {
                Text(original.map { "Original: \($0.name.flatMap { $0.isEmpty ? nil : $0 } ?? "no name (CUSTOM \(slot))")" } ?? "Original settings unavailable")
                    .font(.caption).foregroundStyle(Theme.ink2)
                Button("Restore original C\(slot)") { openRestore(slot) }
                    .disabled(!sameBody || recovery?.backup.properties(forSlot: slot) == nil || isRunning)
                Button("Keep current settings in C\(slot)") { record(slot, outcome: .kept) }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).themedCard(cornerRadius: 16)
    }

    private func openRestore(_ slot: Int) {
        guard sameBody, let record = recovery, let saved = record.backup.properties(forSlot: slot),
              let original = record.backup.slots.first(where: { $0.index == slot }) else { return }
        // An empty original name is written back as the empty name the camera accepts; a name the
        // sanitizer would change cannot be written exactly, so the restore says so.
        let name = original.name ?? ""
        let nameRestorable = camera.session.model?.supportsSlotNaming != true
            || name.isEmpty || camera.session.model?.sanitizedSlotName(from: name) == name
        restoring = .init(slot: slot, name: name, saved: saved,
                          originalNameRestorable: nameRestorable, originalName: name)
        self.record(slot, outcome: .offered)
    }

    private func record(_ slot: Int, outcome: RestoreDisposition) {
        guard recovery == nil || GuidedRecoveryStore.recordDisposition(sessionID: session.id, slot: slot, outcome: outcome) else {
            error = "The camera outcome could not be saved. Your recovery copy is still retained."
            return
        }
        var pass = session.writePass ?? .init()
        // onVerification arrives immediately before onFinish. Keep its evidence when the
        // final disposition is saved; opening a new attempt or choosing Keep clears it.
        let verification = [.offered, .kept, .emptyKept, .canceled].contains(outcome) ? nil
            : pass.restores.last(where: { $0.slot == slot })?.verification
        pass.restores.removeAll { $0.slot == slot }
        pass.restores.append(.init(slot: slot, outcome: outcome, verification: verification))
        session.writePass = pass
        session.touch()
        revision += 1
    }

    /// The disposition for a finished restore: a verified one is `restored`, any other keeps its
    /// verification outcome.
    static func disposition(for completion: RestoreView.Completion) -> RestoreDisposition {
        switch completion {
        case .verified(.applied): return .restored
        case .verified(let outcome): return RestoreDisposition(outcome)
        case .canceled: return .canceled
        }
    }

    private func recordVerification(_ slot: Int, verification: RestoreVerification) {
        var pass = session.writePass ?? .init()
        pass.restores.removeAll { $0.slot == slot }
        pass.restores.append(.init(slot: slot, outcome: RestoreDisposition(verification.outcome), verification: verification))
        session.writePass = pass
        session.touch()
    }
}

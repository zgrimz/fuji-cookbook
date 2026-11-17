import SwiftUI

/// Where a guided Camera Test can be.
///
/// The steps are one case rather than many, so the stack only ever holds one — pushing replaces
/// rather than appends, and Back always lands on the checklist. A tester who wanders off mid-test
/// and comes back should not have to unwind six screens to see where they are.
enum GuidedTestRoute: Hashable {
    case step(GuidedTestStep)
    /// One slot, open for comparison against the camera's own menu. `recheck` distinguishes the
    /// write pass's second look — same screen, different place to record the answer.
    ///
    /// A route rather than a `navigationDestination(item:)` on the step itself: an item- or
    /// isPresented-form destination shares one presentation slot per stack with the typed one at the
    /// root, and the typed one wins — so the row simply did nothing when tapped. The Kitchen hit the
    /// same wall from the other direction (`KitchenView.path`).
    case compare(slot: Int, recheck: Bool)
    case kitchenCase(String)
    /// Report a Problem, which the test ends on.
    case report
}

/// The guided **Camera Test**.
///
/// The Camera Test's whole job is to bring back facts about bodies this app has never run against,
/// and the two most valuable ones are things only a person can see: whether what the app displays
/// matches what the camera's own menu says, and whether a recipe is still there after the camera
/// has been switched off and on. This asks for them in order, runs the diagnostics itself, and
/// finishes on the screen that sends the report.
///
/// Nothing is transmitted. The test writes into the same compatibility report everything else does,
/// and the tester shares it by their own hand, as ever.
struct GuidedTestView: View {
    /// Where to start, when something specific opened the flow — a failed connect goes straight to
    /// the questions about it.
    var entry: GuidedTestStep?
    /// 1 for the read pass, 2 for the write pass.
    var wave: Int = 1
    var sessionID: String?

    @Environment(CameraServices.self) private var camera
    @Environment(\.dismiss) private var dismiss

    @State private var session: GuidedTestSession?
    @State private var path: [GuidedTestRoute] = []
    /// True only while a camera operation this flow started is in flight. Interactive dismissal is
    /// disabled for exactly that long — a probe writing real values should not be interrupted by a
    /// downward swipe, and nothing else here is worth trapping someone in a sheet for.
    @State private var isRunning = false
    @State private var resume: GuidedTestFlow.ResumeDecision = .fresh
    @State private var showingGuide = false
    @State private var showingStartOverConfirm = false
    @State private var previousRecovery: GuidedRecoveryRecord?
    @State private var saveError: String?
    @State private var pickedRAFs: [URL] = []

    private var facts: CameraFacts { GuidedTestRunner.facts(camera) }
    private var previousRecoveries: [GuidedRecoveryRecord] {
        GuidedRecoveryStore.unresolvedRecords().filter { $0.sessionID != session?.id }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let session {
                    GuidedTestHubView(session: session,
                                      resume: resume,
                                      onOpen: { open($0) },
                                      onStartOver: { showingStartOverConfirm = true },
                                      onSendWhatIHave: { sendWhatIHave() },
                                      onClose: { close() })
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.paper.ignoresSafeArea())
                }
            }
            .navigationTitle("Camera Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // "Done", on the right, because leaving is not abandoning: the session stays on
                // disk and the Camera screen offers to resume it. A left-hand Cancel read as discard.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { close() }.disabled(isRunning)
                }
            }
            .navigationDestination(for: GuidedTestRoute.self) { route in
                destination(route)
            }
        }
        .interactiveDismissDisabled(isRunning)
        .sheet(isPresented: $showingGuide) { ConnectionGuideView() }
        .sheet(item: $previousRecovery) { record in GuidedRecoveryView(record: record) }
        .confirmationDialog("Start the test over?", isPresented: $showingStartOverConfirm,
                            titleVisibility: .visible) {
            Button("Start Over", role: .destructive) { startOver() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll start a new test from the beginning. Previous results and backups stay saved. Starting over doesn't change camera settings; you can review earlier changes separately before writing again.")
        }
        .alert("Couldn’t save the test", isPresented: Binding(isPresent: $saveError)) {
            Button("OK", role: .cancel) {}
        } message: { Text(saveError ?? "") }
        .task { begin() }
        // One place, because the step host is replaced on every advance and NavigationStack makes
        // no promise that the outgoing host's `onDisappear` runs before the incoming one's
        // `onAppear` — arming from the host would race itself. Cleared when the flow goes away,
        // which covers Done, swipe-dismiss and abandonment; deliberately *not* on backgrounding, so
        // the expectation survives the tester putting the phone down mid-power-cycle.
        .onChange(of: session?.step) { _, _ in armRemovalExpectation() }
        .onChange(of: session?.outcome) { _, _ in armRemovalExpectation() }
        .onChange(of: path) { _, _ in armRemovalExpectation() }
        .onChange(of: isRunning) { _, _ in armRemovalExpectation() }
        .onDisappear { camera.connector.expectRemoval(false) }
    }

    /// Tell `CameraConnector` whether the tester has been asked to unplug at this step, so a
    /// deliberate disconnect is waited out rather than treated as a fault.
    private func armRemovalExpectation() {
        guard let session, session.isLive, !isRunning else {
            camera.connector.expectRemoval(false)
            return
        }
        switch path.last {
        case .step(let visible)?:
            // The X-M5's STILL check at the grain probe. Choosing a slot asks every body for the
            // menu now, and is in `expectsUnplug`.
            let inspectingBank = session.identifiedModelID == "X-M5" && visible == .grainProbe
            camera.connector.expectRemoval(visible.expectsUnplug || inspectingBank)
        case .compare?: camera.connector.expectRemoval(true)
        default: camera.connector.expectRemoval(false)
        }
    }

    // MARK: Routing

    @ViewBuilder
    private func destination(_ route: GuidedTestRoute) -> some View {
        switch route {
        case .step(let step):
            stepView(step)
        case .compare(let slot, let recheck):
            comparisonView(slot: slot, recheck: recheck)
        case .kitchenCase(let id):
            kitchenWorkspace(id)
        case .report:
            DiagnosticsReportView(presentation: .cameraTest,
                snapshot: session?.reportSnapshot,
                sessionID: session?.id,
                summary: session.map { CameraTestSummary.lines($0) } ?? [],
                note: Binding(get: { session?.freeText ?? "" }, set: { value in
                    updateSession { $0.freeText = value.isEmpty ? nil : value }
                }),
                onSnapshot: { snapshot in updateSession { $0.reportSnapshot = snapshot } },
                onShareOutcome: { outcome in
                    updateSession { current in
                        var events = current.shareEvents ?? []
                        events.append(.init(at: CameraCompatibilityReport.timestamp(), outcome: outcome))
                        current.shareEvents = events
                    }
                })
        }
    }

    @ViewBuilder
    private func stepView(_ step: GuidedTestStep) -> some View {
        if let binding = sessionBinding {
            GuidedTestStepHost(step: step, session: binding, isRunning: $isRunning,
                               onAdvance: { advance(from: step) },
                               onAdvanceTo: { advance(from: step, to: $0) },
                               onFinish: { finish() },
                               onOpenKitchen: { path.append(.kitchenCase($0)) },
                               onOpenComparison: { slot, recheck in
                                   path.append(.compare(slot: slot, recheck: recheck))
                               },
                               onShowGuide: { showingGuide = true },
                               previousRecoveries: previousRecoveries,
                               onReviewRecovery: { previousRecovery = $0 })
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { stepToolbar(step) }
                .navigationBarBackButtonHidden(isRunning)
        }
    }

    /// What every step carries in its bar: where the tester is, and the way out.
    ///
    /// The root's `Close` sits on the hub, and `path` never holds more than one route — so without
    /// this the screen a tester spends the whole test on has a back chevron and nothing else. "Send
    /// what I have" in particular belongs here: it is wanted at the moment something goes strange,
    /// which is the moment the hub is furthest away.
    @ToolbarContentBuilder
    private func stepToolbar(_ step: GuidedTestStep) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button { path = [] } label: {
                HStack(spacing: 5) {
                    Text(positionLabel(step))
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "list.bullet")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Theme.ink)
            }
            .accessibilityLabel("\(positionLabel(step)). Show the checklist.")
            .disabled(isRunning)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { path = [] } label: { Label("Checklist", systemImage: "list.bullet") }
                Button { showingGuide = true } label: {
                    Label("Connection Help", systemImage: "questionmark.circle")
                }
                ForEach(previousRecoveries) { record in
                    Button { previousRecovery = record } label: {
                        Label("Review \(record.backup.camera.productName) settings", systemImage: "arrow.uturn.backward")
                    }
                }
                Divider()
                Button { sendWhatIHave() } label: {
                    Label("Share Progress", systemImage: "paperplane")
                }
                Button(role: .destructive) { showingStartOverConfirm = true } label: {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(isRunning)
            .accessibilityLabel("Test options")
        }
    }

    /// The comparison screen, wired to wherever this session records that slot's answer.
    ///
    /// Both bindings live here rather than in the step views because the root owns the session, and
    /// because the write pass's recheck writes into the current trial rather than the top-level list.
    ///
    /// Everything is resolved from the session's snapshot, never from `camera.slotReader.slots`. This screen is
    /// read with the cable *out* — a camera in `USB RAW Conv./Backup Restore` has handed its display
    /// to the host, so its IQ menu is unreachable while connected — and `disconnect()` empties the
    /// live slots. Keyed off those, the screen would blank the moment the tester did as it asked.
    @ViewBuilder
    private func comparisonView(slot index: Int, recheck: Bool) -> some View {
        if let snapshot = resolvedComparison(slot: index, recheck: recheck) {
            SlotComparisonView(comparison: recheck ? recheckBinding(index) : compareBinding(index),
                               slotLabel: snapshot.label,
                               slotName: snapshot.displayName)
        }
    }

    /// The answers already recorded for this slot, else a fresh snapshot for a tester who somehow
    /// reached the screen before their step seeded one.
    private func resolvedComparison(slot index: Int, recheck: Bool) -> GuidedTestSession.SlotComparison? {
        if recheck {
            if let existing = session?.writePass?.trial?.menuComparison, existing.slot == index {
                return existing
            }
        } else if let existing = session?.slotComparisons.first(where: { $0.slot == index }) {
            return existing
        }
        return camera.slotReader.slots.first { $0.index == index }
            .map { GuidedTestFlow.comparison(for: $0, model: camera.session.model) }
    }

    private func compareBinding(_ index: Int) -> Binding<GuidedTestSession.SlotComparison> {
        Binding(
            get: { resolvedComparison(slot: index, recheck: false) ?? .init(slot: index) },
            set: { updated in
                guard var current = session else { return }
                if let position = current.slotComparisons.firstIndex(where: { $0.slot == index }) {
                    current.slotComparisons[position] = updated
                } else {
                    current.slotComparisons.append(updated)
                }
                current.touch()
                current.reportSnapshot = nil
                session = current
                if GuidedTestStore.save(current) == nil { saveError = "The comparison could not be saved. Please try again." }
            })
    }

    private func recheckBinding(_ index: Int) -> Binding<GuidedTestSession.SlotComparison> {
        Binding(
            get: { resolvedComparison(slot: index, recheck: true) ?? .init(slot: index) },
            set: { updated in
                guard var current = session, var pass = current.writePass,
                      let index = pass.currentTrial else { return }
                pass.trials[index].menuComparison = updated
                current.writePass = pass
                current.touch()
                current.reportSnapshot = nil
                session = current
                if GuidedTestStore.save(current) == nil { saveError = "The comparison could not be saved. Please try again." }
            })
    }

    private var sessionBinding: Binding<GuidedTestSession>? {
        guard session != nil else { return nil }
        return Binding(get: { session ?? GuidedTestSession.begin(wave: wave, step: .intro) },
                       set: { updated in
                           var updated = updated
                           updated.reportSnapshot = nil
                           session = updated
                           if GuidedTestStore.save(updated) == nil { saveError = "Your latest answers could not be saved. Free some storage and try again before writing." }
                       })
    }

    // MARK: Lifecycle

    private func begin() {
        guard session == nil else { return }
        if let sessionID, let saved = GuidedTestStore.loadHistory().last(where: { $0.id == sessionID }) {
            var saved = saved
            if saved.reportSnapshot == nil {
                saved.reportSnapshot = .forSession(saved, report: camera.reports.report ?? CameraReportStore.loadLatest())
                if !GuidedTestStore.archive(saved) { saveError = "The report could not be saved. Please try again." }
            }
            session = saved
            path = []
            return
        }
        if var stored = GuidedTestStore.load(), stored.isLive {
            let next = GuidedTestFlow.writePrerequisiteStep(for: stored.step, session: stored)
            if next != stored.step {
                stored.step = next
                stored.touch()
                if GuidedTestStore.save(stored) == nil { saveError = "Your place could not be saved. Please try again." }
            }
            session = stored
            resume = GuidedTestFlow.resumeDecision(stored: stored, facts: facts)
            path = [.step(stored.step)]
            return
        }
        var fresh = GuidedTestSession.beginContinuous(step: entry ?? .intro)
        fresh.adopt(camera: facts)
        session = fresh
        if GuidedTestStore.save(fresh) == nil { saveError = "The test could not be saved. Free some storage and try again." }
        path = [.step(fresh.step)]
    }

    private func positionLabel(_ step: GuidedTestStep) -> String {
        guard let session else { return "Camera Test" }
        return GuidedTestFlow.positionLabel(of: step, in: session)
    }

    private func open(_ step: GuidedTestStep) {
        guard let current = session, !isRunning else { return }
        guard current.isLive else { sendWhatIHave(); return }
        guard step == current.step || current.completedSteps.contains(step) else { return }
        path = [.step(step)]
    }

    /// Leave the step the tester just finished, and go wherever this camera's answers lead.
    ///
    /// `destination` is for the steps that know something the flow's rules don't — a connect that
    /// failed, a tester asking for a second push.
    private func advance(from step: GuidedTestStep, to destination: GuidedTestStep? = nil) {
        guard !isRunning, var current = session else { return }
        // Reviewing an earlier answer must not mark the actual unfinished step complete or rewind
        // the session's progress. Continue returns to that unfinished step.
        guard step == current.step else { path = [.step(current.step)]; return }
        current.adopt(camera: facts)
        let requested = destination ?? GuidedTestFlow.next(after: step, session: current, facts: facts)
        let next = GuidedTestFlow.writePrerequisiteStep(for: requested, session: current)
        current.advance(to: next)
        current.reportSnapshot = nil
        guard GuidedTestStore.save(current) != nil else {
            saveError = "The next step could not be saved. Please try again."
            return
        }
        session = current
        // At the boundary, not on every keystroke: the report re-encodes its whole self, trace
        // included, and the session has its own much cheaper file for the fine-grained saves.
        GuidedTestRunner.project(current, into: camera)
        path = [.step(next)]
    }

    private func finish() {
        guard var current = session else { return }
        current.reportSnapshot = nil
        let evidence = DiagnosticsReportSnapshot.forSession(current, report: camera.reports.report ?? CameraReportStore.loadLatest())
        current.outcome = .completed
        current.touch()
        current.reportSnapshot = .refreshing(session: current, reportSnapshot: evidence)
        GuidedTestRunner.project(current, into: camera)
        guard GuidedTestStore.archive(current) else {
            saveError = "The finished results could not be saved. Your progress is still available; try again."
            return
        }
        session = current
        path = [.report]
    }

    /// Sharing a snapshot never changes test progress.
    private func sendWhatIHave() {
        guard var current = session else { return }
        if current.isLive { GuidedTestRunner.project(current, into: camera) }
        current.reportSnapshot = .forSession(current, report: camera.reports.report ?? CameraReportStore.loadLatest())
        let saved = current.isLive ? GuidedTestStore.save(current) != nil : GuidedTestStore.archive(current)
        guard saved else { saveError = "The report could not be saved. Your test progress is still available; please try again."; return }
        session = current
        path = [.report]
    }

    private func startOver() {
        var previous = session
        if let current = previous {
            previous?.reportSnapshot = .forSession(current, report: camera.reports.report ?? CameraReportStore.loadLatest())
        }
        do {
            session = try GuidedTestStore.startOver(replacing: previous, facts: facts)
            resume = .fresh
            pickedRAFs = []
            path = [.step(.intro)]
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func updateSession(_ edit: (inout GuidedTestSession) -> Void) {
        guard var current = session else { return }
        edit(&current)
        current.touch()
        let saved = current.isLive ? GuidedTestStore.save(current) != nil : GuidedTestStore.archive(current)
        if saved { session = current }
        else { saveError = "Your latest result could not be saved. Please try again." }
    }

    @ViewBuilder
    private func kitchenWorkspace(_ caseID: String) -> some View {
        if let current = session,
           let model = CameraModelRegistry.shared.model(withID: current.identifiedModelID ?? "") {
            let config = kitchenConfiguration(caseID: caseID, model: model)
            if caseID == "testKitchen" || caseID == "expandedKitchen" {
                TestKitchenView(guided: config)
                    .navigationBarBackButtonHidden(isRunning)
            } else {
                DevelopView(presentation: .cameraTest, guided: config)
                    .navigationBarBackButtonHidden(isRunning)
            }
        } else {
            ContentUnavailableView("Connect the test camera", systemImage: "camera",
                                   description: Text("Return to the test and reconnect the camera before developing."))
        }
    }

    private func kitchenConfiguration(caseID: String, model: CameraModel) -> GuidedKitchenConfiguration {
        let canonical = GuidedTestRecipes.canonical(for: model)
        var recipes = canonical.filter { $0.id == "colour" }.map {
            GuidedKitchenRecipe(id: $0.id, name: $0.name, settings: $0.settings)
        }
        if caseID == "testKitchen" || caseID == "expandedKitchen" {
            let ids = caseID == "testKitchen" ? ["colour", "mono"] : ["colour", "mono", "kelvin"]
            recipes = ids.compactMap { id in canonical.first(where: { $0.id == id }) }
                .map { .init(id: $0.id, name: $0.name, settings: $0.settings) }
        } else if caseID.hasPrefix("dr-"), !recipes.isEmpty {
            recipes[0].id = caseID
            recipes[0].name = caseID.replacingOccurrences(of: "dr-", with: "DR ")
            recipes[0].settings.dRangePriority = .off
            switch caseID {
            case "dr-100": recipes[0].settings.dynamicRange = .dr100
            case "dr-200": recipes[0].settings.dynamicRange = .dr200
            case "dr-400": recipes[0].settings.dynamicRange = .dr400
            default: recipes[0].settings.dynamicRange = .auto
            }
        }
        return GuidedKitchenConfiguration(caseID: caseID, recipes: recipes,
            maxFiles: caseID == "expandedKitchen" ? 3 : 1, initialRAFs: pickedRAFs,
            onFilesSelected: { pickedRAFs = $0 },
            onStart: { run in
                // Reserve the shared flow before the workspace schedules its conversion task.
                // A second callback must not start another upload, even before SwiftUI redraws.
                guard !isRunning, var current = session, current.isLive,
                      GuidedTestFlow.describesSameBody(stored: current, facts: facts),
                      current.identity?.confirmed == true else { return false }
                current.kitchenRuns = (current.kitchenRuns ?? []) + [run]
                current.reportSnapshot = nil
                guard GuidedTestStore.save(current) != nil else { return false }
                session = current
                isRunning = true
                return true
            },
            onComplete: { result in
                isRunning = false
                guard var current = session else { return false }
                var completions = current.kitchenCompletions ?? []
                completions.removeAll { $0.run.id == result.run.id }
                completions.append(result)
                current.kitchenCompletions = completions
                if result.run.caseID == "develop" {
                    current.develop = .init(state: result.hasSuccessfulOutput ? .ran : .failed,
                        detail: result.hasSuccessfulOutput ? "JPEG produced; your image check is saved separately" : "The camera did not produce a usable JPEG")
                }
                current.reportSnapshot = nil
                guard GuidedTestStore.save(current) != nil else { return false }
                session = current
                GuidedTestRunner.project(current, into: camera)
                return true
            },
            onContinue: { isRunning = false; path = [.step(.develop)] },
            onReport: { isRunning = false; sendWhatIHave() })
    }

    /// Closing is not abandoning: the session stays on disk and the Camera tab offers to resume it.
    private func close() {
        if let session, session.isLive { GuidedTestRunner.project(session, into: camera) }
        dismiss()
    }
}

/// Recovery remains reachable even when its ordinary test history has been evicted. The original
/// backup is the authority; this presentation never creates a new baseline or replaces a live test.
struct GuidedRecoveryView: View {
    let record: GuidedRecoveryRecord
    @Environment(\.dismiss) private var dismiss
    @State private var session: GuidedTestSession
    @State private var isRunning = false
    @State private var exporting = false
    @State private var saveError = false

    init(record: GuidedRecoveryRecord) {
        self.record = record
        var saved = GuidedTestStore.load().flatMap { $0.id == record.sessionID ? $0 : nil }
            ?? GuidedTestStore.loadHistory().last { $0.id == record.sessionID }
            ?? GuidedTestSession.beginContinuous(step: .restoreOffer)
        saved.id = record.sessionID
        saved.cameraProductName = record.backup.camera.productName
        saved.identifiedModelID = record.backup.camera.modelID
        saved.serialHash = record.backup.camera.serialHash
        saved.transport = record.transport
        saved.recoveryBaselineID = record.sessionID
        _session = State(initialValue: saved)
    }

    var body: some View {
        NavigationStack {
            GuidedRestoreStep(session: Binding(get: { session }, set: { updated in
                var updated = updated
                if let snapshot = session.reportSnapshot {
                    updated.reportSnapshot = .refreshing(session: updated, reportSnapshot: snapshot)
                }
                session = updated
                if let live = GuidedTestStore.load(), live.id == updated.id {
                    saveError = GuidedTestStore.save(updated) == nil
                } else if GuidedTestStore.loadHistory().contains(where: { $0.id == updated.id }) {
                    saveError = !GuidedTestStore.archive(updated)
                }
            }), isRunning: $isRunning, onAdvance: { dismiss() })
            .navigationTitle("Restore Camera Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(isRunning) }
                ToolbarItem(placement: .confirmationAction) { Button("Export Backup") { exporting = true }.disabled(isRunning) }
            }
        }
        .interactiveDismissDisabled(isRunning)
        .sheet(isPresented: $exporting) { ShareBundle.backupShareSheet(record.backup) }
        .alert("Couldn’t update test history", isPresented: $saveError) {
            Button("OK", role: .cancel) {}
        } message: { Text("Your original settings backup is still saved. Try again before clearing diagnostics.") }
    }
}

// MARK: - The checklist

/// What the test covers, what has been answered, and where to pick it back up.
struct GuidedTestHubView: View {
    let session: GuidedTestSession
    let resume: GuidedTestFlow.ResumeDecision
    let onOpen: (GuidedTestStep) -> Void
    let onStartOver: () -> Void
    let onSendWhatIHave: () -> Void
    let onClose: () -> Void

    private var steps: [GuidedTestStep] { GuidedTestFlow.mainLine(session: session) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !session.isLive { finishedCard }
                if case .differentBody(let stored) = resume {
                    GuidedNoticeCard(
                        title: "This is a different camera",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: Theme.warning,
                        message: "This test belongs to \(stored ?? "another camera"). Reconnect that camera to continue, or start a new test for the connected camera.")
                }
                if session.transport == "demo" {
                    GuidedNoticeCard(
                        title: "Demo camera",
                        systemImage: "play.circle",
                        message: "You’re trying the test with a simulated camera. The report will label these as demo results.")
                }
                if session.isLive { checklist }
                CameraTestSummaryView(session: session)
                actions
            }
            .padding(18)
        }
        .background(Theme.paper.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Camera Test").font(Theme.serif(24)).foregroundStyle(Theme.ink)
            Text(session.isLive ? "Your progress is saved. Continue the test, or share what you have so far."
                 : "Your test results are saved. Review them below or share the report.")
                .font(.subheadline).foregroundStyle(Theme.ink2)
        }
    }

    private var finishedCard: some View {
        GuidedNoticeCard(title: "Results saved", systemImage: "doc.text",
            message: "Review what worked and anything that needs attention below, then share your results.")
    }

    private var checklist: some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                Button { onOpen(step) } label: {
                    HStack(spacing: 12) {
                        icon(for: step)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title(in: session))
                                .font(.subheadline.weight(step == session.step ? .semibold : .regular))
                                .foregroundStyle(Theme.ink)
                            if let note = note(for: step) {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(Theme.ink3)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Theme.ink3)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(step != session.step && !session.completedSteps.contains(step))
                if index < steps.count - 1 {
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 46)
                }
            }
        }
        .themedCard(cornerRadius: 16)
    }

    @ViewBuilder
    private func icon(for step: GuidedTestStep) -> some View {
        if session.completedSteps.contains(step) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
        } else if step == session.step {
            Image(systemName: "circle.dotted")
                .font(.title3)
                .foregroundStyle(Theme.accent)
        } else {
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(Theme.ink3.opacity(0.6))
        }
    }

    /// The one-line answer a finished step left behind, so the checklist doubles as a summary.
    private func note(for step: GuidedTestStep) -> String? {
        switch step {
        case .confirmIdentity:
            guard let identity = session.identity else { return nil }
            if identity.confirmed == false { return "Different camera — \(identity.correction ?? "reported")" }
            return identity.confirmed == true ? "Confirmed" : nil
        case .compareSlots:
            let checked = session.slotComparisons.filter { $0.checkedAt != nil }
            guard !checked.isEmpty else { return nil }
            if checked.contains(where: { $0.verdict == "unverified" }) { return "Some settings could not be verified" }
            let differing = checked.filter { $0.verdict == "differs" }
            return differing.isEmpty
                ? (checked.count == 1 ? "1 slot matches the camera" : "\(checked.count) slots match the camera")
                : (differing.count == 1 ? "1 slot differs from the camera"
                                        : "\(differing.count) slots differ from the camera")
        case .propertyReport:
            return session.propertyReport.map(summary)
        case .grainProbe:
            return session.grainProbe.map(summary)
        case .develop:
            // On a body the app doesn't develop on, what happened at this step is the harvest, and
            // "RAW conversion isn't enabled for this body" would hide it.
            if let harvest = session.profileHarvest {
                switch harvest.state {
                case .ran: return "RAW conversion details saved"
                case .failed: return "The camera did not accept the RAW file"
                case .skipped: return "Skipped — no RAW file"
                case .refused: return "The camera was busy"
                case .notWritable, .notRun: break
                }
            }
            guard let develop = session.develop else { return nil }
            switch develop.jpegMatchesRecipe {
            case .yes?: return "You reported that the photo looked right"
            case .no?: return "You reported that the photo looked different"
            case .notChecked?: return "Image not checked"
            case nil: return develop.state == .ran ? "Developed" : develop.detail
            }
        case .push:
            guard let trial = session.writePass?.trial else { return nil }
            return trial.outcome.map { outcome in
                let result: String
                switch outcome {
                case .applied: result = "Recipe saved"
                case .partiallyApplied: result = "Some settings were not saved"
                case .notWritten: result = "Recipe was not written"
                case .unknown: result = "Check the write result"
                }
                return "C\(trial.slot): \(result)"
            }
        case .powerCycle:
            guard let persistence = session.writePass?.trial?.persistence else { return nil }
            return persistence.persisted ? "The settings matched after restart" : "The settings were not confirmed after restart"
        default:
            return nil
        }
    }

    private func summary(_ probe: GuidedTestSession.ProbeOutcome) -> String {
        switch probe.state {
        case .ran: return probe.count.map { "\($0) check results saved" } ?? "Results saved"
        case .skipped: return "Skipped"
        case .notWritable: return "Unavailable for this camera"
        case .refused: return "The camera was busy — try again"
        case .failed: return "Didn't complete"
        case .notRun: return "Not run"
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            if session.isLive {
                GuidedPrimaryButton(title: session.completedSteps.isEmpty ? "Start" : "Continue",
                                    systemImage: "arrow.right") {
                    onOpen(session.step)
                }
                // Reachable from the hub, which every step's Back button lands on — a tester who hits
                // something strange halfway through must not have to finish the test to report it.
                GuidedSecondaryButton(title: "Share Progress", action: onSendWhatIHave)
            } else {
                // A finished test: the two things that come next.
                GuidedPrimaryButton(title: "Close the Test", systemImage: "checkmark", action: onClose)
                GuidedSecondaryButton(title: "Review & Share Test Results", action: onSendWhatIHave)
            }
            if !session.completedSteps.isEmpty {
                GuidedSecondaryButton(title: "Start over", action: onStartOver)
            }
        }
    }
}

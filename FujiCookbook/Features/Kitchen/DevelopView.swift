import SwiftUI
import SwiftData
import UIKit

/// **Develop**: the Kitchen's main pathway — develop RAW (RAF) files into JPEGs using the connected
/// camera's own processor, applying a recipe from the Library or a camera slot (the FUJIFILM X RAW
/// Studio flow). The camera does the rendering; the app uploads the RAF, patches the conversion
/// profile, and retrieves the JPEG. Reuses the single `CameraServices` session shared with
/// the Camera tab.
///
/// The Kitchen's camera chrome — connection status, the not-connected banner, the unsupported
/// notice — is on this screen and Test Kitchen rather than the Kitchen hub, because they are the
/// only parts of the Kitchen that need a camera. Connection help and Disconnect are here alone.
struct DevelopView: View {
    /// Where this screen is being shown from.
    ///
    /// Two pieces of its chrome are wrong inside the guided Camera Test: Disconnect, which would
    /// break the session the test is mid-way through using, and the Report a Problem row, which
    /// would send a tester off to the end of a flow they haven't finished.
    /// Everything else about the screen is exactly what that step wants, so it is borrowed rather
    /// than reimplemented.
    enum Presentation { case standalone, cameraTest }

    var presentation: Presentation = .standalone
    var guided: GuidedKitchenConfiguration?

    @Environment(CameraServices.self) private var camera
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(Recipe.listFetch(sortBy: [SortDescriptor(\Recipe.name)])) private var recipes: [Recipe]

    @State private var pickedRAFs: [URL] = []
    /// The chosen recipe — a Library entry or a camera slot. One field rather than a source switch
    /// plus two optionals: which of the two a recipe lives in is a detail of the row you picked, not
    /// a decision to make before you can start looking.
    @State private var selectedRef: RecipeRef?
    @State private var showRecipePicker = false

    @State private var showGuide = false
    @AppStorage(DiagnosticMode.key) private var diagnosticMode = false
    /// Output of the D185 dynamic-range probe. Diagnostic Mode only — see `probeDynamicRange`.
    @State private var probeReport: String?
    @State private var isProbing = false
    @State private var showResults = false
    /// The run just filed, which pushes its Recent Results; see `cook`.
    @State private var developedRun: DevelopRun?
    @State private var showingProblemReport = false
    @State private var isCooking = false
    /// The alert for a run that went wrong, so a dead end is never silent. See `CookFailure`.
    @State private var failure: CookFailure?
    @State private var completedResults: [ConversionResult] = []
    @State private var resultsSaveFailed = false
    @State private var pendingCompletion: GuidedKitchenCompletion?
    @State private var completionSaved = false

    /// The recipe to cook with: the Camera Test's, or the one chosen here. Nil until one is chosen,
    /// or once it has gone away; the slots clear whenever the camera disconnects.
    private var resolvedRecipe: ResolvedRecipe? {
        guided?.recipes.first?.resolved ?? selectedRef?.resolve(recipes: recipes, camera: camera)
    }

    private var recipeChoices: [RecipeChoice] { RecipeChoice.choices(camera: camera, recipes: recipes) }

    private var canCook: Bool {
        camera.session.canConvert && !pickedRAFs.isEmpty && resolvedRecipe != nil && !isCooking && !isProbing
            && (pendingCompletion == nil || completionSaved)
    }

    private var guidedResultLabels: [UUID: String] {
        guard let recipe = guided?.recipes.first else { return [:] }
        return Dictionary(uniqueKeysWithValues: completedResults.map { ($0.id, recipe.name) })
    }

    private var guidedResultGuidance: [UUID: String] {
        guard let recipe = guided?.recipes.first else { return [:] }
        let guidance = GuidedTestRecipes.observationGuidance(for: recipe.settings)
        return Dictionary(uniqueKeysWithValues: completedResults.map { ($0.id, guidance) })
    }

    var body: some View {
        List {
            CookStatusSection(camera: camera,
                              notConnectedMessage: guided == nil
                                  ? "Developing happens on the camera itself. Pick your files and recipe now, then connect a camera to develop."
                                  : "Choose your RAW file, then reconnect the test camera to develop it.",
                              onShowGuide: { showGuide = true })
                .cardRowBackground()
            // Connected to a body that can't convert: no workspace, since nothing here could be developed.
            // Otherwise show it either way — connected and ready, or not connected yet, so files and
            // a recipe can be staged before plugging in. The cook action itself gates on the camera.
            if !(camera.session.isConnected && !camera.session.canConvert) {
                filesSection.cardRowBackground()
                recipeSection.cardRowBackground()
                cookSection.cardRowBackground()
            }
            helpSection.cardRowBackground()
        }
        .paperBackground()
        .navigationTitle("Develop")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if camera.session.isConnected, presentation == .standalone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Disconnect") { Task { await camera.connector.disconnect() } }
                        .disabled(isCooking)
                }
            }
        }
        .navigationDestination(item: $developedRun) { run in
            SavedComparisonsView(run: run)
        }
        .sheet(isPresented: $showGuide) { ConnectionGuideView() }
        .sheet(isPresented: $showingProblemReport) {
            NavigationStack { DiagnosticsReportView() }
        }
        .sheet(isPresented: $showRecipePicker) {
            RecipePickerSheet(title: "Choose Recipe",
                              choices: recipeChoices,
                              mode: .single,
                              initialSelection: selectedRef.map { [$0] } ?? [],
                              emptyMessage: "Add a recipe to your library, or program a camera slot.") { picked in
                selectedRef = picked.first
            }
        }
        .sheet(isPresented: $showResults) {
            NavigationStack {
                KitchenResultView(results: completedResults,
                                  onContinueTest: guided?.onContinue,
                                  onReportTest: guided.map { config in { showResults = false; config.onReport() } },
                                  savedBatchID: pendingCompletion?.savedBatchID,
                                  saveFailed: pendingCompletion?.saveFailed ?? resultsSaveFailed,
                                  resultLabels: guidedResultLabels,
                                  resultGuidance: guidedResultGuidance,
                                  onRetryTest: guided.map { _ in { showResults = false } })
            }
        }
        .cookFailureAlert($failure)
        .seedingGuidedFiles(guided, into: $pickedRAFs)
        .onAppear(perform: applySeed)
    }

    /// Starts on the recipe the Kitchen's viewer handed over. Only the standalone screen takes it: a
    /// Camera Test step brings its own recipe.
    private func applySeed() {
        guard presentation == .standalone, guided == nil, let seed = router.developSeed else { return }
        router.developSeed = nil
        selectedRef = .library(seed.recipeUUID)
    }

    // MARK: Sections

    private var filesSection: some View {
        RAFPickerSection(pickedRAFs: $pickedRAFs,
                         maxFiles: guided?.maxFiles,
                         header: pickedRAFs.count > 1 ? "RAW Files (\(pickedRAFs.count))" : "RAW Files",
                         footer: guided == nil
                             ? "Each file is developed with the recipe below."
                             : "Choose one RAW file (.RAF) from Photos or Files, taken with this same camera.",
                         step: 1)
    }

    @ViewBuilder
    private var recipeSection: some View {
        Section {
            if let supplied = guided?.recipes.first {
                ChosenRecipeRow(name: supplied.name, filmSimulation: supplied.settings.filmSimulation,
                                badge: "Camera Test")
                Text(GuidedTestRecipes.observationGuidance(for: supplied.settings))
                    .font(.caption).foregroundStyle(Theme.ink2)
            } else if recipeChoices.isEmpty {
                Text("No recipes in your Library and no programmed camera slots yet.")
                    .foregroundStyle(Theme.ink2)
            } else {
                if let resolved = resolvedRecipe {
                    ChosenRecipeRow(name: resolved.displayName,
                                    filmSimulation: resolved.settings.filmSimulation,
                                    badge: camera.slotLabel(for: selectedRef))
                } else if selectedRef != nil {
                    // The slots clear whenever the camera disconnects. Say so rather than silently
                    // resetting to "nothing chosen" and leaving the Develop button dead.
                    Text("That recipe is no longer available. Choose another.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink2)
                }
                Button { showRecipePicker = true } label: {
                    Label(resolvedRecipe == nil ? "Choose Recipe…" : "Change Recipe…",
                          systemImage: "magnifyingglass")
                }
            }
        } header: {
            Theme.StepHeader(number: 2, title: "Recipe")
                .textCase(nil)
        }
    }

    private var cookSection: some View {
        Section {
            CookButton(title: isCooking ? "Developing…" : "Develop \(pickedRAFs.count > 1 ? "\(pickedRAFs.count) Files" : "File")",
                       systemImage: "wand.and.stars",
                       enabled: canCook,
                       blockedReason: CookPrerequisite.missing(hasFiles: !pickedRAFs.isEmpty,
                                                               hasRecipe: resolvedRecipe != nil,
                                                               cameraCanConvert: camera.session.canConvert)?
                           .message(for: .develop),
                       action: cook)
            if diagnosticMode { probeRow }
        } header: {
            Theme.StepHeader(number: 3, title: "Develop")
                .textCase(nil)
        } footer: {
            Text(guided == nil
                 ? "Developed at full resolution and saved to Recent Results. Keep the app open and the camera awake until it finishes: leaving the app can drop the USB connection."
                 : "Keep the app open and the USB cable connected until the photo appears. The full-resolution JPEG is saved in Kitchen → Recent Results. Any Dynamic Range adjustment is shown with the photo.")
        }
    }

    /// Writes candidate values straight into the conversion profile's Dynamic Range cell to find out
    /// what the camera accepts there, including D190's DR Auto value (`FujiEncoding.drAutoSlotValue`).
    /// The X-T50 result is recorded on `FujiRawConvProfile.autoCeiling`.
    ///
    /// Develops the picked RAF up to four times at preview resolution and restores the profile
    /// afterwards; the report says when it couldn't. Diagnostic Mode only, and deliberately not part
    /// of the Develop button: it is a measurement, not a way to get a photo.
    ///
    /// The previews are filed to Recent Results so the *look* can be judged too. The report only
    /// carries what the camera stored and what the output JPEG's EXIF claimed, and some questions
    /// need eyes on the picture: whether DR400 on a DR200 frame still renders the green cast
    /// `FujiRawConvProfile` describes is one.
    @ViewBuilder
    private var probeRow: some View {
        // A note in place of the button, because a disabled tinted row still reads as tappable.
        if let reason = probeBlockedReason {
            Text(reason)
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Button {
                probeDynamicRange()
            } label: {
                Label(isProbing ? "Probing…" : "Probe D185 Dynamic Range", systemImage: "stethoscope")
                    .font(.callout)
            }
            // Only while a probe or a develop is running, which the label or the cook row shows.
            .disabled(isProbing || isCooking)
        }
        if let probeReport {
            Text(probeReport)
                .diagnosticText()
            // The run's summary already reaches Report a Problem twice over — `AppLog(.kitchen)` and
            // a compatibility-report note — but the per-candidate lines live only here, so they need
            // a way off the phone as well as onto the pasteboard.
            CopyShareButtons(text: probeReport, layout: .inline)
        }
    }

    /// Why the probe can't run, or nil when the row is live. Files first, the way the screen reads.
    private var probeBlockedReason: String? {
        if pickedRAFs.count != 1 { return "Pick exactly one RAF to probe D185 Dynamic Range." }
        if !camera.session.isConnected { return "Connect a camera to probe D185 Dynamic Range." }
        return nil
    }

    private func probeDynamicRange() {
        guard let url = pickedRAFs.first else { return }
        Task {
            isProbing = true
            defer { isProbing = false }
            guard let raf = CookHarness.prepareRAFs([url]).rafs.first, let data = try? await raf.load() else {
                probeReport = "Couldn't read that file."
                return
            }
            let run: RawConversionService.ConversionProbeRun
            do throws(CameraBusy) {
                run = try await camera.conversion.probeConversionDynamicRange(raf: data, filename: raf.filename)
            } catch {
                probeReport = "D185 DR probe wasn't started. \(error.localizedDescription)"
                return
            }
            probeReport = run.report
            // Preview resolution, so `fullResolution: false` — the versions are labelled
            // "Comparison preview" in the viewer, which is what they are.
            if let comparison = run.comparison {
                do {
                    try await CookStore.persistChecked([comparison], fullResolution: false, into: modelContext)
                } catch {
                    probeReport = run.report + "\n\nThe probe's previews couldn't be saved to Recent Results. Recovery copies are kept in Files → Fuji Cookbook → Recovered Develops."
                }
            }
        }
    }

    private var helpSection: some View {
        Section {
            Button { showGuide = true } label: {
                Label("Connection Help & Requirements", systemImage: "questionmark.circle")
            }
            if guided == nil { recipeApplicationNote }
            // An action, not a push: this stack declares `.navigationDestination(item:)` above, and a
            // destination-form `NavigationLink` shares its presentation slot and pushes the wrong
            // screen.
            if presentation == .standalone {
                ReportProblemRow(prompt: ReportProblemRow.kitchenPrompt) { showingProblemReport = true }
            }
            if presentation == .cameraTest {
                Text("View the photo, then tap Continue Camera Test to record your observation.")
                    .font(.caption)
                    .foregroundStyle(Theme.ink3)
            }
            if pendingCompletion != nil, !completionSaved, guided != nil {
                Button("Retry saving test result", action: saveCompletion)
            }
        }
    }

    /// How the camera follows a recipe where the RAW limits it. Behind a disclosure: it answers a
    /// question asked after a develop looks different from the recipe, not before every develop,
    /// and the result names any Dynamic Range it reduced.
    private var recipeApplicationNote: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("The recipe's white balance is applied, including a color temperature in Kelvin. A recipe with no white balance set keeps the one the photo was shot at.")
                Text("Dynamic Range is capped to what the RAW was shot at. A higher setting, like DR400 on a DR200 file, has no exposure headroom to develop, so it is reduced, and the result says so.")
            }
            .font(.footnote)
            .foregroundStyle(Theme.ink2)
            .padding(.vertical, 4)
        } label: {
            Label("How a Recipe Is Applied", systemImage: "info.circle")
        }
    }

    // MARK: Cook

    private func cook() {
        guard canCook else { return }
        let urls = pickedRAFs
        guard let resolved = resolvedRecipe, !urls.isEmpty else { return }
        let run = guided?.run(fullResolution: true)
        if let run, guided?.onStart(run) != true {
            failure = .checkCouldNotStart
            return
        }
        // Set this synchronously so repeated taps cannot queue two tasks before either starts.
        isCooking = true
        Task {
            defer { isCooking = false }
            await CookHarness.run {
                let load = CookHarness.prepareRAFs(urls)
                // An unreadable file must not end the run silently — no sheet, no error, no change
                // in status reads as a broken button. Say what happened, and don't develop a
                // smaller batch than the one listed on screen.
                guard load.unreadable.isEmpty else {
                    if let run {
                        let results = urls.map { ConversionResult.unreadableFile(named: $0.lastPathComponent) }
                        complete(run: run, results: results, batchID: nil, saveFailed: false)
                        return
                    }
                    failure = .unreadable(load.unreadable, ofTotal: urls.count)
                    return
                }
                let items = load.rafs.map { CookItem(raf: $0, settings: resolved.settings) }
                let results = await camera.conversion.cookBatch(items, recordContext: run?.recordContexts.first)
                // File the developed JPEGs before showing them, so closing the results sheet keeps
                // the work — they join the Test Kitchen's runs in Recent Results.
                let comparisons = CookStore.comparisons(from: results, recipe: resolved)
                if let run {
                    do {
                        let batchID = try await CookStore.persistChecked(comparisons, fullResolution: true,
                                                                        into: modelContext)
                        complete(run: run, results: results, batchID: batchID, saveFailed: false)
                    } catch {
                        complete(run: run, results: results, batchID: nil, saveFailed: true)
                    }
                } else {
                    // A filed run opens in Recent Results, where Test Kitchen's runs land too. The sheet
                    // stays for the two outcomes with nothing filed to show: every develop failed, or
                    // the store refused the batch and only the recovery copies are left to export.
                    do {
                        if let batchID = try await CookStore.persistChecked(comparisons, fullResolution: true,
                                                                           into: modelContext) {
                            developedRun = DevelopRun(batchID: batchID, results: results)
                            return
                        }
                        resultsSaveFailed = false
                    } catch {
                        resultsSaveFailed = true
                    }
                    completedResults = results
                    showResults = true
                }
            }
        }
    }

    private func complete(run: GuidedKitchenRun, results: [ConversionResult], batchID: UUID?, saveFailed: Bool) {
        completedResults = results
        pendingCompletion = GuidedKitchenCompletion(run: run,
            cells: results.enumerated().map { .init(result: $0.element, recipeID: run.recipes[0].id, fileIndex: $0.offset) },
            savedBatchID: batchID, saveFailed: saveFailed)
        completionSaved = false
        saveCompletion()
    }

    private func saveCompletion() {
        guard let pendingCompletion, let guided else { return }
        completionSaved = guided.onComplete(pendingCompletion)
        if completionSaved {
            showResults = true
        } else {
            failure = .testResultNotSaved(plural: false)
        }
    }
}

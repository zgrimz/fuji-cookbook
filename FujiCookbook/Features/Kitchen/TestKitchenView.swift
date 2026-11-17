import SwiftUI
import SwiftData
import UIKit

/// **Test Kitchen**: develop up to 3 RAW files against up to 3 recipes at once, then compare the
/// resulting versions of each photo side by side. A discovery/experimentation surface on top of the
/// Kitchen's in-camera RAW-conversion flow — same session, same converter, just a matrix instead of
/// one recipe. Pushed from `KitchenView`, and from a Camera Test step with `guided` set.
struct TestKitchenView: View {
    var guided: GuidedKitchenConfiguration?
    @Environment(CameraServices.self) private var camera
    @Environment(\.modelContext) private var modelContext
    @Query(Recipe.listFetch(sortBy: [SortDescriptor(\Recipe.name)])) private var recipes: [Recipe]

    static let maxFiles = 3
    static let maxRecipes = 3

    @State private var pickedRAFs: [URL] = []
    /// Ordered, not a Set: selection order is the order versions are developed, saved and swiped.
    @State private var selectedRefs: [RecipeRef] = []
    @State private var showRecipePicker = false
    @State private var showingProblemReport = false
    @State private var isCooking = false
    /// The batch just developed — drives the push to its saved results.
    @State private var cookedBatchID: UUID?
    /// The alert for a run that went wrong, so a total failure isn't silent. See `CookFailure`.
    @State private var failure: CookFailure?
    /// The D185 profile dump behind a total failure. Kept separate from `failure` so it
    /// outlives the alert — a hex dump belongs in a copyable disclosure, not an alert body.
    @State private var failureDiagnostics: String?
    @State private var completedComparisons: [TestKitchenComparison] = []
    @State private var pendingCompletion: GuidedKitchenCompletion?
    @State private var completionSaved = false
    @State private var showingGuidedResults = false

    /// Gates the raw D185 profile dump — see `DiagnosticMode`.
    @AppStorage(DiagnosticMode.key) private var diagnosticMode = false

    /// The selected recipes, resolved and in selection order, for `cookMatrix`.
    private var resolvedRecipes: [ResolvedRecipe] {
        guided?.recipes.map(\.resolved) ?? selectedRefs.compactMap { $0.resolve(recipes: recipes, camera: camera) }
    }

    private var totalVersions: Int { pickedRAFs.count * resolvedRecipes.count }

    private var recipeChoices: [RecipeChoice] { RecipeChoice.choices(camera: camera, recipes: recipes) }

    private var canCook: Bool {
        camera.session.canConvert && !pickedRAFs.isEmpty && !resolvedRecipes.isEmpty && !isCooking
            && (pendingCompletion == nil || completionSaved)
    }

    private var guidedResultGuidance: [UUID: String] {
        guard let guided else { return [:] }
        let guidance: [(UUID, String)] = completedComparisons.flatMap(\.versions).compactMap { version in
            guard let recipe = guided.recipes.first(where: { $0.name == version.recipeName }) else { return nil }
            return (version.result.id, GuidedTestRecipes.observationGuidance(for: recipe.settings))
        }
        return Dictionary(uniqueKeysWithValues: guidance)
    }

    var body: some View {
        List {
            CookStatusSection(camera: camera,
                              notConnectedMessage: guided == nil
                                  ? "Comparing develops each version on the camera itself. Pick your files and recipes now, then connect a camera to develop."
                                  : "Choose your RAW file, then reconnect the test camera to create the comparison photos.")
                .cardRowBackground()
            filesSection.cardRowBackground()
            recipesSection.cardRowBackground()
            cookSection.cardRowBackground()
            diagnosticsSection.cardRowBackground()
        }
        .paperBackground()
        .navigationTitle("Test Kitchen")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $cookedBatchID) { id in
            SavedComparisonsView(batchID: id)
        }
        .cookFailureAlert($failure)
        .sheet(isPresented: $showingProblemReport) {
            NavigationStack { DiagnosticsReportView() }
        }
        .sheet(isPresented: $showingGuidedResults) {
            NavigationStack {
                KitchenResultView(results: completedComparisons.flatMap(\.versions).map(\.result),
                                  onContinueTest: guided?.onContinue,
                                  onReportTest: guided.map { config in { showingGuidedResults = false; config.onReport() } },
                                  savedBatchID: pendingCompletion?.savedBatchID,
                                  saveFailed: pendingCompletion?.saveFailed ?? false,
                                  resultLabels: Dictionary(uniqueKeysWithValues: completedComparisons.flatMap(\.versions).map { ($0.result.id, $0.recipeName) }),
                                  resultGuidance: guidedResultGuidance,
                                  onRetryTest: guided.map { _ in { showingGuidedResults = false } })
            }
        }
        .sheet(isPresented: $showRecipePicker) {
            RecipePickerSheet(title: "Choose Recipes",
                              choices: recipeChoices,
                              mode: .multiple(limit: Self.maxRecipes),
                              initialSelection: selectedRefs,
                              emptyMessage: "Add a recipe to your library, or program a camera slot.") { picked in
                selectedRefs = picked
            }
        }
        .seedingGuidedFiles(guided, into: $pickedRAFs)
    }

    /// The Camera Test's retry, and after a total failure the camera's D185 profile as it was then,
    /// with a way to report it. Error text alone leaves a layout failure with no evidence at all;
    /// the Develop flow has the same disclosure in `KitchenResultView`.
    @ViewBuilder
    private var diagnosticsSection: some View {
        if pendingCompletion != nil, !completionSaved, guided != nil {
            Section {
                Button("Retry saving test result", action: saveCompletion)
            }
        }
        if let text = failureDiagnostics {
            Section("Last Failure") {
                // The D185 hex stays behind Diagnostic Mode; the *route* to Report a Problem does
                // not. A tester will never find that toggle, and the report already carries the log
                // this failure wrote, so gating it would hide the way out of a failure.
                if diagnosticMode {
                    DiagnosticsDisclosure(text: text)
                }
                // An action, not a push: this stack declares `.navigationDestination(item:)` above,
                // and a destination-form `NavigationLink` shares its presentation slot and pushes
                // the wrong screen.
                ReportProblemRow(
                    prompt: guided == nil ? ReportProblemRow.kitchenPrompt : "Something went wrong with this check?",
                    actionTitle: guided == nil ? "Report a Problem" : "Share Camera Test progress"
                ) {
                    if let guided { guided.onReport() } else { showingProblemReport = true }
                }
            }
        }
    }

    // MARK: Sections

    private var filesSection: some View {
        RAFPickerSection(pickedRAFs: $pickedRAFs,
                         maxFiles: guided?.maxFiles ?? Self.maxFiles,
                         header: pickedRAFs.isEmpty ? "RAW Files" : "RAW Files (\(pickedRAFs.count) of \(guided?.maxFiles ?? Self.maxFiles))",
                         footer: guided == nil
                             ? "Pick up to \(Self.maxFiles) .RAF files. Each is developed with every recipe you choose below."
                             : "Choose RAW files (.RAF) taken with this same camera. Each recipe creates a separate preview of each file.")
    }

    /// Only the chosen recipes appear here. Printing the entire Library plus every camera slot
    /// inline would push the Develop button below dozens of rows and offer no way to search for
    /// anything.
    @ViewBuilder
    private var recipesSection: some View {
        Section {
            if let guided {
                ForEach(guided.recipes) { recipe in
                    ChosenRecipeRow(name: recipe.name, filmSimulation: recipe.settings.filmSimulation,
                                    badge: "Camera Test")
                    Text(GuidedTestRecipes.observationGuidance(for: recipe.settings))
                        .font(.caption).foregroundStyle(Theme.ink2)
                }
            } else if recipeChoices.isEmpty {
                Text("No recipes in your Library and no programmed camera slots yet.")
                    .foregroundStyle(Theme.ink2)
            } else {
                ForEach(selectedRefs, id: \.self) { ref in
                    if let resolved = ref.resolve(recipes: recipes, camera: camera) {
                        ChosenRecipeRow(name: resolved.displayName,
                                        filmSimulation: resolved.settings.filmSimulation,
                                        badge: camera.slotLabel(for: ref)) {
                            selectedRefs.removeAll { $0 == ref }
                        }
                    }
                }
                Button { showRecipePicker = true } label: {
                    Label(selectedRefs.isEmpty ? "Choose Recipes…" : "Change Recipes…",
                          systemImage: "magnifyingglass")
                }
            }
        } header: {
            Text(guided == nil ? (selectedRefs.isEmpty ? "Recipes" : "Recipes (\(selectedRefs.count) of \(Self.maxRecipes))") : "Supplied test recipes")
        } footer: {
            Text(guided == nil
                 ? "Choose up to \(Self.maxRecipes) recipes to compare. Library recipes and programmed camera slots can be mixed."
                 : "The test recipes are ready. Compare their colour and monochrome previews of the same scene.")
        }
    }

    private var cookSection: some View {
        Section {
            CookButton(title: cookButtonTitle, systemImage: "square.grid.2x2",
                       enabled: canCook, action: cook)
        } footer: {
            Text(guided == nil
                 ? "Develops a grid of \(pickedRAFs.count) file\(pickedRAFs.count == 1 ? "" : "s") × \(resolvedRecipes.count) recipe\(resolvedRecipes.count == 1 ? "" : "s"), saved to Recent Results in the Kitchen.\n\nVersions are developed at reduced resolution — they're for judging a recipe, not for keeping. Develop the winner on its own for the full-resolution file.\n\nKeep the app in the foreground and the camera awake — each version is a separate on-camera conversion."
                 : "Keep the app open and the USB cable connected until all previews appear. These smaller JPEGs are saved in Kitchen → Recent Results. View each recipe's version, then tap Continue Camera Test to record your observation.")
        }
    }

    private var cookButtonTitle: String {
        if isCooking { return "Developing…" }
        guard totalVersions > 0 else { return "Develop Versions" }
        return "Develop \(totalVersions) Version\(totalVersions == 1 ? "" : "s")"
    }

    // MARK: Actions

    private func cook() {
        guard canCook else { return }
        let urls = pickedRAFs
        let recipesToCook = resolvedRecipes
        guard !urls.isEmpty, !recipesToCook.isEmpty else { return }
        let run = guided?.run(fullResolution: false)
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
                // Stop on any unreadable file, not just on all of them — dropping one and
                // developing the rest makes a batch shrink with nothing said about it.
                guard load.unreadable.isEmpty else {
                    if let run {
                        let comparisons = urls.map { url in
                            TestKitchenComparison(sourceFilename: url.lastPathComponent, versions: recipesToCook.map { recipe in
                                TestKitchenVersion(recipeName: recipe.displayName, filmSimulation: recipe.filmSimulation,
                                                   result: .unreadableFile(named: url.lastPathComponent))
                            })
                        }
                        complete(run: run, comparisons: comparisons, batchID: nil, saveFailed: false)
                        return
                    }
                    failure = .unreadable(load.unreadable, ofTotal: urls.count)
                    return
                }
                let grid = recipesToCook.map { (settings: $0.settings, displayName: $0.displayName,
                                                filmSimulation: $0.filmSimulation) }
                let comparisons = await camera.conversion.cookMatrix(rafs: load.rafs, recipes: grid,
                                                         recordContexts: run?.recordContexts ?? [])
                if let run {
                    do {
                        let batchID = try await CookStore.persistChecked(comparisons, fullResolution: false,
                                                                        into: modelContext)
                        complete(run: run, comparisons: comparisons, batchID: batchID, saveFailed: false)
                    } catch {
                        complete(run: run, comparisons: comparisons, batchID: nil, saveFailed: true)
                    }
                    return
                }
                // Comparison versions are downscaled previews — recorded as such so history can't
                // pass one off as the full-resolution file a Develop run produces.
                do {
                    if let batchID = try await CookStore.persistChecked(comparisons, fullResolution: false,
                                                                       into: modelContext) {
                        cookedBatchID = batchID
                    } else {
                        // Every cell failed. Report the camera's reason rather than doing nothing, and
                        // keep the profile dump so a layout failure can actually be characterised.
                        let failed = comparisons.flatMap(\.versions).map(\.result)
                        failure = .nothingDeveloped(failed.compactMap(\.errorMessage).first)
                        failureDiagnostics = failed.compactMap(\.diagnostics).first
                    }
                } catch {
                    // The camera did its part; the local store didn't. Saying "nothing developed"
                    // here would blame the camera for a SwiftData failure.
                    failure = CookFailure(title: "Couldn't save the comparison",
                                          message: "The previews were developed but could not be saved to Recent Results. Recovery copies are kept in Files → Fuji Cookbook → Recovered Develops.")
                }
            }
        }
    }

    private func complete(run: GuidedKitchenRun, comparisons: [TestKitchenComparison], batchID: UUID?, saveFailed: Bool) {
        completedComparisons = comparisons
        let cells = comparisons.enumerated().flatMap { fileIndex, comparison in
            comparison.versions.enumerated().map { recipeIndex, version in
                GuidedKitchenCell(result: version.result, recipeID: run.recipes[recipeIndex].id, fileIndex: fileIndex)
            }
        }
        pendingCompletion = GuidedKitchenCompletion(run: run, cells: cells, savedBatchID: batchID, saveFailed: saveFailed)
        completionSaved = false
        saveCompletion()
    }

    private func saveCompletion() {
        guard let pendingCompletion, let guided else { return }
        completionSaved = guided.onComplete(pendingCompletion)
        if completionSaved {
            showingGuidedResults = true
        } else {
            failure = .testResultNotSaved(plural: true)
        }
    }
}

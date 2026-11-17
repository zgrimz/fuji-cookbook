import SwiftUI
import SwiftData
import PhotosUI

/// The recipe inventory — fully usable with no camera connected.
///
/// Compact widths push detail onto a stack; regular widths (iPad) show a list + detail
/// `NavigationSplitView`, which combines with the sidebar-adaptable tab bar into a three-column
/// layout — "pick on the left, read on the right, no push/pop."
///
/// On the phone the search field and the sort/filter menu sit in a bar at the bottom of the list
/// (`LibrarySearchBar`), within reach of the thumb; the iPad column keeps the system search field
/// under its title.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(ImportCoordinator.self) private var importCoordinator
    @Environment(AISettings.self) private var aiSettings
    @Environment(OwnedCameras.self) private var ownedCameras
    @Query(Recipe.listFetch(sortBy: [SortDescriptor(\Recipe.updatedAt, order: .reverse)]))
    private var recipes: [Recipe]

    /// What the list shows. This view only hands them down as bindings and never reads them: a read
    /// here would re-run the whole body, and every sheet, alert and control it hosts, on each
    /// keystroke. `LibraryRecipeRows` and the search field are what read them. On iPad the system
    /// field is applied by `SearchableColumn`, not here, for the same reason.
    @State private var filter = RecipeFilter()
    @State private var searchText = ""
    @State private var splitSelection: PersistentIdentifier?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selection = Set<PersistentIdentifier>()
    @State private var editMode: EditMode = .inactive

    /// The phone stack's pushes, as values — and the search field's focus, which is owned here
    /// rather than inside `LibrarySearchBar`: the field lives in the stack root's bottom safe-area
    /// inset, so focus that outlives a push is restored during the pop, into a layout that settled
    /// without the keyboard. The keyboard then comes back over a bar that is no longer being lifted
    /// by it, and the bar is left underneath it. Dropping focus as the stack grows is the fix.
    @State private var path: [Recipe] = []
    @FocusState private var searchFocused: Bool

    @State private var editTarget: Identified<Recipe>?
    @State private var showingImporter = false
    @State private var showingTextImport = false
    /// Held until the text sheet has gone, so the review sheet isn't presented over it.
    @State private var pastedRecipe: PastedRecipe?
    @State private var shareItem: ShareItem?
    @State private var exportError: String?
    @State private var pendingExport: PendingExport?
    @State private var exportRunner = RecipeExportRunner()
    @State private var isAddingStarter = false
    @State private var starterError: String?

    // AI screenshot scanning
    @State private var showingSettings = false
    @State private var showingScanPicker = false
    @State private var scanPickerItem: PhotosPickerItem?
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var showingAISetupPrompt = false

    private var isSplit: Bool { horizontalSizeClass == .regular }

    var body: some View {
        if isSplit {
            // Balanced + visible-at-launch so the list is side by side with the detail even on
            // the narrowest iPads (mini portrait) instead of hiding behind the sidebar toggle.
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SearchableColumn(searchText: $searchText) { libraryColumn }
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380)
                    // iPadOS 26 floats this toggle as its own glass capsule at the column
                    // boundary, right where the sidebar-adaptable tab pill sits — so it ends up
                    // covered and untappable. It's also redundant here: `columnVisibility` is
                    // pinned to `.all` on purpose (see above), and the tab pill has its own
                    // sidebar control.
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                detailColumn
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack(path: $path) {
                libraryColumn
            }
            // Drop the keyboard as the stack grows, for the reason on `path` above. The explicit
            // path is what makes the push observable at all: it comes from a transparent
            // `NavigationLink` inside a row, which has no action of its own to hang this on.
            .onChange(of: path.count) { _, depth in
                if depth > 0 { searchFocused = false }
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let id = splitSelection, let recipe = recipes.first(where: { $0.persistentModelID == id }) {
            NavigationStack { RecipeDetailView(recipe: recipe) }
        } else {
            ContentUnavailableView {
                Label("Select a Recipe", systemImage: "book.pages")
            } description: {
                Text("Pick a recipe on the left to read it here.")
            }
            .background(Theme.paper.ignoresSafeArea())
        }
    }

    private var libraryColumn: some View {
        Group {
            if recipes.isEmpty {
                emptyState
            } else {
                recipeList
            }
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Recipes")
        .toolbar { toolbarContent }
        .settingsToolbarItem(isPresented: $showingSettings)
        .environment(\.editMode, $editMode)
        // Stable wrapper id so autosave flipping the new recipe's persistentModelID (e.g. while
        // typing its name) doesn't dismiss the editor sheet mid-edit.
        .sheet(item: $editTarget) { target in
            NavigationStack {
                RecipeEditorView(recipe: target.value, isNew: true)
            }
        }
        .sheet(isPresented: $showingImporter) {
            DocumentPicker { urls in
                for url in urls { importCoordinator.load(url: url) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingTextImport, onDismiss: reviewPastedRecipe) {
            RecipeTextImportView { pastedRecipe = $0 }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.urls)
        }
        .confirmationDialog("Share Recipes", isPresented: Binding(isPresent: $pendingExport),
                            titleVisibility: .visible, presenting: pendingExport) { pending in
            Button("Include Sample Photos") { performExport(pending, includePhotos: true) }
            Button("Recipes Only") { performExport(pending, includePhotos: false) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Embedding photos makes the shared file larger.")
        }
        .alert("Export Failed", isPresented: Binding(isPresent: $exportError)) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
        .alert("Couldn't Add \(StarterRecipe.name)", isPresented: Binding(isPresent: $starterError)) {
            Button("OK", role: .cancel) {}
        } message: { Text(starterError ?? "") }
        .exportProgress(exportRunner)
        // iCloud sync can bring another device's copy of the starter in at any moment after launch.
        // This query is what sees it arrive, so the collapse rides on it rather than on a second,
        // filtered query of its own.
        .onChange(of: starterCopyCount, initial: true) { _, count in
            if count > 1 { collapseStarterCopies() }
        }
        .photosPicker(isPresented: $showingScanPicker, selection: $scanPickerItem, matching: .images)
        .onChange(of: scanPickerItem) { _, item in
            guard let item else { return }
            Task { await runScan(item) }
        }
        .blockingProgress("Sending to \(aiSettings.provider.displayName) with your key…", isPresented: isScanning)
        .alert("Scan Failed", isPresented: Binding(isPresent: $scanError)) {
            Button("OK", role: .cancel) {}
        } message: { Text(scanError ?? "") }
        .alert("AI Scanning Isn't Set Up", isPresented: $showingAISetupPrompt) {
            Button("Open Settings") { showingSettings = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turn on AI Features in Settings, add your \(aiSettings.provider.displayName) API key, and pick a model for scanning.")
        }
    }

    // MARK: Derived data

    private var starterCopyCount: Int { recipes.count { $0.uuid == StarterRecipe.uuid } }

    /// The user's cameras for the chips, and every body for the menu.
    private var filterCameras: RecipeFilterCameras {
        RecipeFilterCameras(owned: ownedCameras.models, all: ownedCameras.selectable)
    }

    // MARK: List

    private var recipeList: some View {
        List(selection: $selection) {
            filterChipRow
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))

            LibraryRecipeRows(recipes: recipes, searchText: $searchText, filter: $filter) { recipe in
                recipeCard(for: recipe)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .tag(recipe.persistentModelID)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { delete(recipe) } label: {
                            Label("Delete", systemImage: "trash")
                        }.tint(.red)
                        Button { toggleFavorite(recipe) } label: {
                            Label("Favorite", systemImage: recipe.isFavorite ? "star.slash" : "star")
                        }.tint(Theme.star)
                    }
            }
        }
        .listStyle(.plain)
        .paperBackground()
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(for: Recipe.self) { RecipeDetailView(recipe: $0) }
        .safeAreaInset(edge: .bottom) { bottomAccessory }
    }

    /// One recipe card row. In a stack, a transparent NavigationLink keeps navigation without the
    /// system chevron breaking the card silhouette; in the split layout tapping drives the detail
    /// pane and the chosen card gets an accent ring.
    @ViewBuilder
    private func recipeCard(for recipe: Recipe) -> some View {
        if isSplit {
            Button { splitSelection = recipe.persistentModelID } label: {
                RecipeRow(recipe: recipe)
            }
            .buttonStyle(.plain)
            .overlay {
                if splitSelection == recipe.persistentModelID {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                }
            }
        } else {
            RecipeRow(recipe: recipe)
                .overlay {
                    NavigationLink(value: recipe) { EmptyView() }.opacity(0)
                }
        }
    }

    /// The filter chips at the top of the list, the same row the recipe picker sheet shows. On the
    /// phone the search field sits at the bottom instead (`LibrarySearchBar`).
    private var filterChipRow: some View {
        RecipeFilterChipRow(filter: $filter,
                            availableFilmSimulations: recipes.availableFilmSimulations,
                            cameras: filterCameras,
                            totalCount: recipes.count)
    }

    private var selectionBar: some View {
        HStack {
            Button {
                exportSelected()
            } label: {
                Label("Export \(selection.count)", systemImage: "square.and.arrow.up")
            }
            Spacer()
            Button(role: .destructive) {
                deleteSelected()
            } label: {
                Label("Delete \(selection.count)", systemImage: "trash")
            }
        }
        .padding()
        .background(.bar)
    }

    /// The bottom safe-area slot has one occupant: the selection bar while editing with something
    /// ticked, the search bar on the phone otherwise, nothing on iPad (its search is under the
    /// column title) or while editing with nothing ticked. Removing the search bar while editing
    /// also drops the keyboard.
    @ViewBuilder
    private var bottomAccessory: some View {
        if editMode == .active {
            if !selection.isEmpty { selectionBar }
        } else if !isSplit {
            LibrarySearchBar(searchText: $searchText,
                             filter: $filter,
                             availableFilmSimulations: recipes.availableFilmSimulations,
                             cameras: filterCameras,
                             isFocused: $searchFocused) {
                filterMenuExtras
            }
        }
    }

    /// The Library's own section on the sort/filter menu, shared by the iPad toolbar button and the
    /// phone's bottom bar so "Export All" lives in one place.
    @ViewBuilder
    private var filterMenuExtras: some View {
        if !recipes.isEmpty {
            Section {
                Button { exportAll() } label: {
                    Label("Export All (\(recipes.count))", systemImage: "square.and.arrow.up.on.square")
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Recipes Yet", systemImage: "tray")
        } description: {
            Text("Create a recipe, import a .fujirecipe file, paste one as text, or read recipes from your camera. Or add \(StarterRecipe.name), a recipe by the app's creator.")
        } actions: {
            Button("New Recipe") { createRecipe() }
                .buttonStyle(.borderedProminent)
                .prominentOnAccentLabel()
            Button("Import from File") { showingImporter = true }
            Button("Import from Text") { showingTextImport = true }
            Button("Add \(StarterRecipe.name)") { addStarterRecipe() }
                .disabled(isAddingStarter)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // Multi-select edit mode is a stack-layout affordance; the split list selects instead.
            if !isSplit && !recipes.isEmpty { EditButton() }
        }
        // On the phone the sort/filter menu sits in `LibrarySearchBar`, beside the search field.
        if isSplit {
            ToolbarItem(placement: .topBarTrailing) {
                RecipeFilterMenu(filter: $filter,
                                 availableFilmSimulations: recipes.availableFilmSimulations,
                                 cameras: filterCameras) {
                    filterMenuExtras
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { createRecipe() } label: { Label("New Recipe", systemImage: "plus") }
                Button { showingImporter = true } label: { Label("Import from File", systemImage: "square.and.arrow.down") }
                Button { showingTextImport = true } label: { Label("Import from Text", systemImage: "doc.on.clipboard") }
                Button { startScan() } label: { Label("Scan Screenshot (AI)", systemImage: "text.viewfinder") }
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    // MARK: Actions

    private func createRecipe() {
        let recipe = Recipe(name: "New Recipe")
        modelContext.insert(recipe)
        editTarget = Identified(value: recipe)
    }

    private func reviewPastedRecipe() {
        guard let pasted = pastedRecipe else { return }
        pastedRecipe = nil
        importCoordinator.review(pasted)
    }

    /// Disabled while it runs, so a second tap doesn't decode the bundled file and its photos again.
    private func addStarterRecipe() {
        isAddingStarter = true
        Task {
            defer { isAddingStarter = false }
            do {
                try await StarterRecipe.add(to: modelContext)
            } catch {
                AppLog.error(.importExport, "Adding the starter recipe failed — \(AppLog.bounded(error))")
                starterError = error.localizedDescription
            }
        }
    }

    /// Silent on failure: the duplicate stays on screen for the user to delete, and the next copy
    /// that arrives tries again.
    private func collapseStarterCopies() {
        do {
            try StarterRecipe.collapseCopies(in: modelContext)
        } catch {
            AppLog.error(.data, "Collapsing starter recipe copies failed — \(AppLog.bounded(error))")
        }
    }

    /// Entry point for AI screenshot import: gate on configuration, then present the photo picker.
    private func startScan() {
        if aiSettings.isConfigured { showingScanPicker = true }
        else { showingAISetupPrompt = true }
    }

    /// Load the picked screenshot, extract a recipe via the selected AI provider, and open it in
    /// the editor for review.
    @MainActor
    private func runScan(_ item: PhotosPickerItem) async {
        defer { scanPickerItem = nil }
        isScanning = true
        defer { isScanning = false }

        guard let data = try? await item.loadTransferable(type: Data.self) else {
            scanError = "That image couldn't be read."
            return
        }
        do {
            let portable = try await RecipeScanner.scan(imageData: data,
                                                        provider: aiSettings.provider,
                                                        apiKey: aiSettings.apiKey,
                                                        modelID: aiSettings.modelID)
            let recipe = RecipePortability.makeRecipe(from: portable)
            modelContext.insert(recipe)
            editTarget = Identified(value: recipe)   // present editor for review (cancel discards)
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func toggleFavorite(_ recipe: Recipe) {
        recipe.isFavorite.toggle()
        recipe.touch()
    }

    private func delete(_ recipe: Recipe) {
        modelContext.delete(recipe)
    }

    private func deleteSelected() {
        for recipe in recipes where selection.contains(recipe.persistentModelID) {
            modelContext.delete(recipe)
        }
        selection.removeAll()
        editMode = .inactive
    }

    private func exportSelected() {
        let chosen = recipes.filter { selection.contains($0.persistentModelID) }
        startExport(chosen, fileName: "Fuji Recipes")
    }

    private func exportAll() {
        startExport(recipes, fileName: "Fuji Cookbook Library")
    }

    /// Begin an export: if any recipe carries sample photos, ask whether to embed them; otherwise
    /// export straight away.
    private func startExport(_ toExport: [Recipe], fileName: String) {
        guard !toExport.isEmpty else { return }
        let pending = PendingExport(recipes: toExport, fileName: fileName)
        if toExport.contains(where: { !$0.sortedPhotos.isEmpty }) {
            pendingExport = pending
        } else {
            performExport(pending, includePhotos: false)
        }
    }

    private func performExport(_ pending: PendingExport, includePhotos: Bool) {
        let single = pending.recipes.count == 1
        let snapshot: RecipeExportSnapshot = single
            ? .single(pending.recipes[0], includePhotos: includePhotos)
            : .many(pending.recipes, includePhotos: includePhotos)
        exportRunner.start(snapshot, named: single ? pending.recipes[0].name : pending.fileName) { result in
            switch result {
            case .success(let url): shareItem = ShareItem(url: url)
            case .failure(let error): exportError = error.localizedDescription
            }
        }
    }
}

/// The iPad column, with the system search field applied to it.
///
/// Its own view so that a keystroke re-runs this body and not `LibraryView`'s: the view that applies
/// `.searchable` re-runs whenever its text changes, without reading it (iOS 26.5), so applied by
/// `LibraryView` it would re-run that body, and every sheet, alert and control it hosts, on every
/// keystroke. `content` is built by `LibraryView` and passed through as it is.
private struct SearchableColumn<Content: View>: View {
    @Binding var searchText: String
    @ViewBuilder let content: Content

    var body: some View {
        content.searchable(text: $searchText, prompt: "Search recipes")
    }
}

/// A library export awaiting the user's "include photos?" choice.
private struct PendingExport: Identifiable {
    let id = UUID()
    let recipes: [Recipe]
    let fileName: String
}


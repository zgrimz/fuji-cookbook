import SwiftUI
import SwiftData
import UIKit

/// Browse the developed photos saved in the app, from Develop and Test Kitchen runs alike, as a
/// gallery of recipe-labelled cards grouped by run. Two modes: scoped to a single batch (where
/// Develop and Test Kitchen land after a cook, with that run's failures and Save All) or the full
/// history, which can be narrowed to one recipe. Tap a card to open its versions in
/// `ComparisonViewer`.
struct SavedComparisonsView: View {
    @Environment(\.modelContext) private var modelContext

    /// One fixed query for both modes, declared inline so its fetch descriptor is built once.
    ///
    /// Not a `Query(filter: #Predicate { $0.batchID == batchID })` built inside `init`: `init` runs
    /// again every time the view is rebuilt, and a fresh `#Predicate` closure never compares equal
    /// to the last one, so SwiftData treats each rebuild as a new descriptor and refetches.
    /// Fetching materialises the results, materialising writes each model's backing store, and that
    /// write invalidates the view — which rebuilds, refetches, and so on until the main thread pins
    /// at 100% in `AG::Subgraph::update` on the screen pushed straight after a Test Kitchen cook.
    /// Scoping in memory keeps the descriptor constant; the table is small enough that filtering
    /// here costs nothing.
    @Query(CookedPhoto.historyFetch(sortBy: [SortDescriptor(\CookedPhoto.createdAt, order: .reverse),
                                             SortDescriptor(\CookedPhoto.sortOrder)]))
    private var allPhotos: [CookedPhoto]

    private let batchID: UUID?
    /// The run's develops that produced no photo; only a cook that just ran knows them.
    private let failures: [FailedDevelop]

    /// The recipe the history is narrowed to; nil shows every version.
    @State private var recipeFilter: String?
    @State private var pendingDelete: ResultPhoto?
    @State private var loader: DevelopedImageLoader?
    @State private var saver = ImageSaver()
    @State private var isSavingAll = false
    @State private var savedConfirmation: String?
    @State private var saveError: String?

    /// `DiagnosticMode` gates the conversion-profile report on a failure.
    @AppStorage(DiagnosticMode.key) private var diagnosticMode = false

    init(batchID: UUID? = nil) {
        self.batchID = batchID
        failures = []
    }

    /// The run a cook just filed, with the develops in it that failed.
    init(run: DevelopRun) {
        batchID = run.batchID
        failures = run.failures
    }

    var body: some View {
        // Read every relationship once per pass, into values: touching a SwiftData relationship
        // repeatedly while rendering faults objects back in mid-pass, and a fault's write
        // invalidates the view. See `ComparisonViewer.versions`.
        let gallery = ResultsGallery(photos: allPhotos.map(ResultPhoto.init),
                                     scope: batchID.map(ResultsGallery.Scope.batch) ?? .all)
        let recipes = gallery.recipeNames
        let filter = recipeFilter.flatMap { recipes.contains($0) ? $0 : nil }
        let models = Dictionary(allPhotos.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return Group {
            if gallery.isEmpty && failures.isEmpty {
                ContentUnavailableView("No Results Yet", systemImage: "photo.stack",
                                       description: Text("Photos you develop in the Kitchen are kept here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let filter { activeFilter(filter) }
                        ForEach(gallery.runs(recipe: filter)) { run in
                            runSection(run, models: models, filter: filter)
                        }
                        if !failures.isEmpty { failuresSection }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(batchID == nil ? "Recent Results" : "Results")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if batchID == nil, recipes.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { recipeMenu(recipes, selected: filter) }
            }
            if batchID != nil, !gallery.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    let versions = gallery.runs(recipe: nil).flatMap(\.entries).flatMap(\.versions).map(\.id)
                    Button(versions.count == 1 ? "Save to Photos" : "Save All to Photos",
                           systemImage: "square.and.arrow.down.on.square") { saveAll(versions) }
                        .disabled(isSavingAll || loader == nil)
                }
            }
        }
        .confirmationToast($savedConfirmation)
        .alert("Save to Photos", isPresented: Binding(isPresent: $saveError)) {
            Button("OK", role: .cancel) {}
        } message: { Text(saveError ?? "") }
        .task { loader = DevelopedImageLoader(modelContainer: modelContext.container) }
        .confirmationDialog(deleteTitle, isPresented: Binding(isPresent: $pendingDelete),
                            titleVisibility: .visible, presenting: pendingDelete) { photo in
            Button("Delete", role: .destructive) { delete(photo.id, models: models) }
        } message: { photo in
            Text(deleteMessage(photo))
        }
    }

    // MARK: Sections

    /// The recipe filter, behind the same toolbar icon as the Library's. A menu rather than a row of
    /// chips: every recipe ever developed is a choice here, and a list of them scrolls down instead
    /// of off the edge of the screen. Most recently developed first.
    private func recipeMenu(_ recipes: [String], selected: String?) -> some View {
        Menu {
            Picker("Recipe", selection: Binding(get: { selected }, set: { recipeFilter = $0 })) {
                Text("All Recipes").tag(String?.none)
                ForEach(recipes, id: \.self) { Text($0).tag(String?.some($0)) }
            }
        } label: {
            Image(systemName: selected == nil ? "line.3.horizontal.decrease.circle"
                                              : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter by Recipe")
        .accessibilityValue(selected ?? "All Recipes")
    }

    /// Names the recipe the history is narrowed to, and clears it, so a filtered gallery never
    /// passes for the whole history.
    private func activeFilter(_ recipe: String) -> some View {
        Button { recipeFilter = nil } label: {
            HStack(spacing: 6) {
                Text(recipe).lineLimit(1)
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Showing \(recipe) only")
        .accessibilityHint("Shows every recipe again.")
    }

    private func runSection(_ run: ResultsGallery.Run, models: [UUID: CookedPhoto], filter: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if batchID == nil {
                Theme.SectionLabel(Self.runTitle(run)).padding(.horizontal, 4).padding(.top, 6)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(run.entries) { entry in
                    if let model = models[entry.id] {
                        NavigationLink {
                            ComparisonViewer(photo: model,
                                             initialVersionID: filter == nil ? nil : entry.versions.first?.id)
                        } label: {
                            ResultCard(entry: entry, loader: loader)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDelete = entry.photo
                            }
                        }
                    }
                }
            }
        }
    }

    /// "Nov 13, 11:48 PM · 2 photos", with the year only when it isn't this one.
    private static func runTitle(_ run: ResultsGallery.Run) -> String {
        let sameYear = Calendar.current.isDate(run.date, equalTo: .now, toGranularity: .year)
        let format = sameYear ? Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
                              : Date.FormatStyle.dateTime.year().month(.abbreviated).day().hour().minute()
        let count = run.entries.count
        return "\(run.date.formatted(format)) · \(count) photo\(count == 1 ? "" : "s")"
    }

    /// The develops that produced no photo, at the foot of the run, with the way to report them:
    /// this is where someone is standing when a develop fails, and the report already carries the
    /// log the failure wrote.
    private var failuresSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.SectionLabel("Couldn't Develop").padding(.horizontal, 4).padding(.top, 6)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(failures) { failure in
                    VStack(alignment: .leading, spacing: 3) {
                        Label {
                            Text(failure.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        }
                        Text(failure.message)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        if diagnosticMode, let diagnostics = failure.diagnostics {
                            DiagnosticsDisclosure(text: diagnostics)
                        }
                    }
                    .padding(14)
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
                ReportProblemRow(prompt: ReportProblemRow.kitchenPrompt)
                    .padding(14)
            }
            .themedCard(cornerRadius: 16)
        }
    }

    // MARK: Save

    /// Saves each version's developed JPEG, EXIF included, one at a time so only one is in memory.
    /// The task outlives the screen on purpose: a save someone started should finish if they leave.
    private func saveAll(_ versionIDs: [UUID]) {
        guard let loader, !isSavingAll else { return }
        isSavingAll = true
        Task {
            defer { isSavingAll = false }
            var saved = 0
            for id in versionIDs {
                guard let data = await loader.jpeg(for: id) else { continue }
                let error: Error? = await withCheckedContinuation { continuation in
                    saver.save(data: data) { continuation.resume(returning: $0) }
                }
                if let error {
                    saveError = ImageSaver.message(for: error)
                    return
                }
                saved += 1
            }
            if saved == 0 {
                saveError = "None of these photos could be read from the app's library."
            } else if saved < versionIDs.count {
                savedConfirmation = "Saved \(saved) of \(versionIDs.count) photos to Photos"
            } else {
                savedConfirmation = saved == 1 ? "Saved to Photos" : "Saved \(saved) photos to Photos"
            }
        }
    }

    // MARK: Delete

    private var deleteTitle: String {
        guard let photo = pendingDelete else { return "" }
        return photo.versions.count > 1 ? "Delete \(photo.versions.count) Versions?" : "Delete This Photo?"
    }

    private func deleteMessage(_ photo: ResultPhoto) -> String {
        let what = photo.versions.count > 1
            ? "Every version of \(photo.sourceFilename) developed in this run is removed from the app."
            : "This develop of \(photo.sourceFilename) is removed from the app."
        return what + " Copies saved to Photos or shared elsewhere stay."
    }

    private func delete(_ id: UUID, models: [UUID: CookedPhoto]) {
        guard let model = models[id] else { return }
        modelContext.delete(model)
        do {
            try modelContext.save()
        } catch {
            AppLog.error(.kitchen, "Recent Results: the delete did not save — \(AppLog.bounded(error))")
        }
    }
}

private extension ResultPhoto {
    init(_ photo: CookedPhoto) {
        self.init(id: photo.uuid, batchID: photo.batchID, createdAt: photo.createdAt,
                  sortOrder: photo.sortOrder, sourceFilename: photo.sourceFilename,
                  versions: photo.sortedVersions.map {
                      ResultVersion(id: $0.uuid, recipeName: $0.recipeName, filmSimulation: $0.filmSimulation,
                                    isComparisonPreview: $0.isComparisonPreview, thumbnailData: $0.thumbnailData)
                  })
    }
}

import SwiftUI
import SwiftData
import UIKit

/// Browse the developed photos saved in the app, from Develop and Test Kitchen runs alike, as a
/// gallery of recipe-labelled cards grouped by run. Two modes: scoped to a single batch (the
/// destination right after a cook) or the full history, which can be narrowed to one recipe. Tap a
/// card to open its versions in `ComparisonViewer`.
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

    /// The recipe the history is narrowed to; nil shows every version.
    @State private var recipeFilter: String?
    @State private var pendingDelete: ResultPhoto?
    @State private var loader: DevelopedImageLoader?

    init(batchID: UUID? = nil) {
        self.batchID = batchID
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
            if gallery.isEmpty {
                ContentUnavailableView("No Results Yet", systemImage: "photo.stack",
                                       description: Text("Photos you develop in the Kitchen are kept here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if batchID == nil, recipes.count > 1 {
                            recipeChips(recipes, selected: filter)
                        }
                        ForEach(gallery.runs(recipe: filter)) { run in
                            runSection(run, models: models, filter: filter)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(batchID == nil ? "Recent Results" : "Results")
        .navigationBarTitleDisplayMode(.inline)
        .task { loader = DevelopedImageLoader(modelContainer: modelContext.container) }
        .confirmationDialog(deleteTitle, isPresented: Binding(isPresent: $pendingDelete),
                            titleVisibility: .visible, presenting: pendingDelete) { photo in
            Button("Delete", role: .destructive) { delete(photo.id, models: models) }
        } message: { photo in
            Text(deleteMessage(photo))
        }
    }

    // MARK: Sections

    private func recipeChips(_ recipes: [String], selected: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All Recipes", selected: selected == nil) { recipeFilter = nil }
                ForEach(recipes, id: \.self) { name in
                    FilterChip(label: name, selected: selected == name) {
                        recipeFilter = selected == name ? nil : name
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
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

import SwiftUI
import SwiftData
import UIKit

/// Browse the developed photos saved in the app, from Develop and Test Kitchen runs alike. Two
/// modes: scoped to a single batch (the destination right after a cook) or the full history
/// grouped by run. Tap a photo to swipe through its versions in `ComparisonViewer`.
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

    init(batchID: UUID? = nil) {
        self.batchID = batchID
    }

    private var scopedToBatch: Bool { batchID != nil }

    /// The rows this screen shows: one run when scoped, the whole history otherwise.
    private var photos: [CookedPhoto] {
        guard let batchID else { return allPhotos }
        return allPhotos.filter { $0.batchID == batchID }
                        .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        let photos = self.photos
        return List {
            if photos.isEmpty {
                ContentUnavailableView("No Results Yet", systemImage: "photo.stack",
                                       description: Text("Photos you develop in the Kitchen are kept here."))
                    .cardRowBackground()
            } else if scopedToBatch {
                Section { rows(photos) }.cardRowBackground()
            } else {
                ForEach(batches) { batch in
                    Section(batch.title) { rows(batch.photos) }
                }
                .cardRowBackground()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(scopedToBatch ? "Results" : "Recent Results")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Rows

    private func rows(_ photos: [CookedPhoto]) -> some View {
        ForEach(photos) { photo in
            NavigationLink { ComparisonViewer(photo: photo) } label: { row(photo) }
        }
        .onDelete { offsets in delete(offsets, in: photos) }
    }

    private func row(_ photo: CookedPhoto) -> some View {
        // Read the relationship *once* per row, for `filmstrip`, the count and the badge alike:
        // repeatedly touching a SwiftData relationship during rendering can fault objects back in
        // mid-pass — a fault writes to the model, the write invalidates the view, and the view
        // re-renders. See `ComparisonViewer.versions`.
        let versions = photo.sortedVersions
        return HStack(spacing: 12) {
            filmstrip(versions)
            VStack(alignment: .leading, spacing: 2) {
                Text(photo.sourceFilename).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(versions.count) version\(versions.count == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(.secondary)
                // Comparison runs develop downscaled — say so, so a preview isn't mistaken for the
                // full-resolution file a Develop run produces.
                if versions.contains(where: \.isComparisonPreview) {
                    BadgeTag(text: "Comparison preview")
                }
            }
        }
    }

    /// Every version's thumbnail, not just the first. The row is the only view of a run you get
    /// before tapping into it, and a single cover image would say nothing about what was compared.
    /// These are the inline 240px thumbnails, so showing three costs no more than showing one.
    private func filmstrip(_ versions: [CookedVersion]) -> some View {
        HStack(spacing: 3) {
            if versions.isEmpty {
                thumbnail(nil, size: 56)
            } else {
                ForEach(versions.prefix(3)) { version in
                    thumbnail(version, size: versions.count > 1 ? 44 : 56)
                }
            }
        }
    }

    private func thumbnail(_ version: CookedVersion?, size: CGFloat) -> some View {
        Group {
            // Cached by uuid so the JPEG decode doesn't repeat on every body evaluation while scrolling.
            if let version, let image = ThumbnailCache.thumbnail(uuid: version.uuid, data: version.thumbnailData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Grouping (history mode)

    private struct Batch: Identifiable {
        let id: UUID
        let title: String
        let photos: [CookedPhoto]
    }

    private var batches: [Batch] {
        Dictionary(grouping: photos, by: { $0.batchID })
            .map { id, group in
                let sorted = group.sorted { $0.sortOrder < $1.sortOrder }
                let date = sorted.first?.createdAt ?? .distantPast
                let count = sorted.count
                let title = "\(date.formatted(date: .abbreviated, time: .shortened)) · \(count) photo\(count == 1 ? "" : "s")"
                return Batch(id: id, title: title, photos: sorted)
            }
            .sorted { ($0.photos.first?.createdAt ?? .distantPast) > ($1.photos.first?.createdAt ?? .distantPast) }
    }

    // MARK: Delete

    private func delete(_ offsets: IndexSet, in list: [CookedPhoto]) {
        for index in offsets { modelContext.delete(list[index]) }
        do {
            try modelContext.save()
        } catch {
            AppLog.error(.kitchen, "Recent Results: the delete did not save — \(AppLog.bounded(error))")
        }
    }
}

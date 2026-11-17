import Foundation

/// One developed photo as plain values: what Recent Results shows, read from SwiftData once.
struct ResultPhoto: Identifiable, Equatable {
    let id: UUID
    let batchID: UUID
    let createdAt: Date
    let sortOrder: Int
    let sourceFilename: String
    /// In the order their recipes were chosen.
    let versions: [ResultVersion]
}

/// One recipe's version of a `ResultPhoto`.
struct ResultVersion: Identifiable, Equatable {
    let id: UUID
    let recipeName: String
    let filmSimulation: String?
    let isComparisonPreview: Bool
    /// The inline thumbnail, shown until a sharper image is decoded.
    let thumbnailData: Data
}

/// Recent Results' contents: the developed photos grouped into the runs that made them, newest run
/// first, optionally narrowed to one recipe.
struct ResultsGallery {
    enum Scope: Equatable {
        /// Every run.
        case all
        /// The one run a cook just filed, as Test Kitchen and the results sheet open it.
        case batch(UUID)
    }

    /// The photos of one run, in the order their files were picked.
    struct Run: Identifiable, Equatable {
        let id: UUID
        let date: Date
        let entries: [Entry]
    }

    /// A photo as the gallery shows it: every version, or only those made with the filter's recipe.
    struct Entry: Identifiable, Equatable {
        let photo: ResultPhoto
        let versions: [ResultVersion]
        var id: UUID { photo.id }
    }

    private let photos: [ResultPhoto]

    init(photos: [ResultPhoto], scope: Scope) {
        switch scope {
        case .all: self.photos = photos
        case .batch(let batchID): self.photos = photos.filter { $0.batchID == batchID }
        }
    }

    var isEmpty: Bool { photos.isEmpty }

    /// Every recipe name in scope, once each, the most recently used first.
    var recipeNames: [String] {
        var seen = Set<String>()
        return photos.sorted(by: Self.newestFirst)
            .flatMap(\.versions)
            .map(\.recipeName)
            .filter { seen.insert($0).inserted }
    }

    /// The runs to show. With `recipe` set, each photo keeps only that recipe's versions and a photo
    /// with none is left out, as is a run left empty.
    func runs(recipe: String?) -> [Run] {
        Dictionary(grouping: photos, by: \.batchID)
            .compactMap { batchID, group -> Run? in
                let entries = group.sorted { $0.sortOrder < $1.sortOrder }.compactMap { photo -> Entry? in
                    let versions = recipe.map { name in photo.versions.filter { $0.recipeName == name } }
                        ?? photo.versions
                    return versions.isEmpty ? nil : Entry(photo: photo, versions: versions)
                }
                guard let date = group.map(\.createdAt).min(), !entries.isEmpty else { return nil }
                return Run(id: batchID, date: date, entries: entries)
            }
            .sorted { $0.date > $1.date }
    }

    private static func newestFirst(_ lhs: ResultPhoto, _ rhs: ResultPhoto) -> Bool {
        lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.sortOrder < rhs.sortOrder
    }
}

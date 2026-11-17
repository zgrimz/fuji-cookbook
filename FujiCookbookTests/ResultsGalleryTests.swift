import XCTest
@testable import FujiCookbook

final class ResultsGalleryTests: XCTestCase {
    private let earlierRun = UUID()
    private let laterRun = UUID()

    private func version(_ recipe: String) -> ResultVersion {
        ResultVersion(id: UUID(), recipeName: recipe, filmSimulation: nil, isComparisonPreview: false,
                      thumbnailData: Data())
    }

    private func photo(_ file: String, run: UUID, at minutes: Double, order: Int = 0,
                       recipes: [String]) -> ResultPhoto {
        ResultPhoto(id: UUID(), batchID: run, createdAt: Date(timeIntervalSince1970: minutes * 60),
                    sortOrder: order, sourceFilename: file, versions: recipes.map(version))
    }

    private var photos: [ResultPhoto] {
        [photo("A.RAF", run: earlierRun, at: 0, recipes: ["Kodachrome"]),
         photo("C.RAF", run: laterRun, at: 10, order: 1, recipes: ["Portra", "Tri-X"]),
         photo("B.RAF", run: laterRun, at: 10, order: 0, recipes: ["Portra", "Kodachrome"])]
    }

    func testRunsAreNewestFirstWithPhotosInPickOrder() {
        let runs = ResultsGallery(photos: photos, scope: .all).runs(recipe: nil)
        XCTAssertEqual(runs.map(\.id), [laterRun, earlierRun])
        XCTAssertEqual(runs[0].entries.map(\.photo.sourceFilename), ["B.RAF", "C.RAF"])
        XCTAssertEqual(runs[0].entries[0].versions.map(\.recipeName), ["Portra", "Kodachrome"])
    }

    func testRecipeNamesAreUniqueAndMostRecentFirst() {
        let gallery = ResultsGallery(photos: photos, scope: .all)
        XCTAssertEqual(gallery.recipeNames, ["Portra", "Kodachrome", "Tri-X"])
    }

    func testRecipeFilterKeepsOnlyThatRecipesVersions() {
        let runs = ResultsGallery(photos: photos, scope: .all).runs(recipe: "Kodachrome")
        XCTAssertEqual(runs.map(\.id), [laterRun, earlierRun])
        XCTAssertEqual(runs[0].entries.map(\.photo.sourceFilename), ["B.RAF"])
        XCTAssertEqual(runs.flatMap(\.entries).flatMap(\.versions).map(\.recipeName), ["Kodachrome", "Kodachrome"])
    }

    func testRecipeFilterDropsRunsWithNoMatch() {
        let runs = ResultsGallery(photos: photos, scope: .all).runs(recipe: "Tri-X")
        XCTAssertEqual(runs.map(\.id), [laterRun])
        XCTAssertEqual(runs[0].entries.map(\.photo.sourceFilename), ["C.RAF"])
    }

    func testBatchScopeShowsOnlyThatRun() {
        let gallery = ResultsGallery(photos: photos, scope: .batch(earlierRun))
        XCTAssertEqual(gallery.runs(recipe: nil).map(\.id), [earlierRun])
        XCTAssertEqual(gallery.recipeNames, ["Kodachrome"])
    }

    func testEmptyHistory() {
        let gallery = ResultsGallery(photos: [], scope: .all)
        XCTAssertTrue(gallery.isEmpty)
        XCTAssertEqual(gallery.runs(recipe: nil), [])
    }
}

import XCTest
@testable import FujiCookbook

@MainActor
final class ImportCoordinatorTests: XCTestCase {
    private func data(_ name: String) throws -> Data {
        try ImportTestFixtures.data([PortableRecipe(name: name, settings: .neutral)])
    }

    func testPreparationRunsOffMainActorAndCancellationDoesNotPublishACompletedResult() async throws {
        let entered = expectation(description: "background preparation")
        let release = DispatchSemaphore(value: 0)
        let bytes = try data("Cancelled")
        let coordinator = ImportCoordinator { input, progress in
            XCTAssertFalse(Thread.isMainThread)
            let result = try RecipeImportPreparation.prepare(input, progress: progress)
            entered.fulfill()
            _ = release.wait(timeout: .now() + 10)
            return result // deliberately ignores cancellation to exercise the publication guard
        }
        let task = coordinator.load(data: bytes, sourceName: "Cancelled")
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(coordinator.isPreparingImport)
        coordinator.cancelImport()
        XCTAssertFalse(coordinator.isPreparingImport)
        release.signal()
        await task.value
        XCTAssertNil(coordinator.pendingImport)
        XCTAssertNil(coordinator.importError)
    }

    func testNewerImportWinsWhenOlderWorkerFinishesLast() async throws {
        let oldEntered = expectation(description: "old prepared")
        let release = DispatchSemaphore(value: 0)
        let oldData = try data("Old"), newData = try data("New")
        let coordinator = ImportCoordinator { input, progress in
            let result = try RecipeImportPreparation.prepare(input, progress: progress)
            if result.recipes.first?.recipe.name == "Old" {
                oldEntered.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
            return result
        }
        let oldTask = coordinator.load(data: oldData, sourceName: "Old")
        await fulfillment(of: [oldEntered], timeout: 5)
        await coordinator.load(data: newData, sourceName: "New").value
        XCTAssertEqual(coordinator.pendingImport?.recipes.first?.name, "New")
        release.signal()
        await oldTask.value
        XCTAssertEqual(coordinator.pendingImport?.recipes.first?.name, "New")
        XCTAssertFalse(coordinator.isPreparingImport)
        XCTAssertNil(coordinator.importError)
    }

    func testValidationFailureHasNoPendingReview() async {
        let coordinator = ImportCoordinator()
        let data = Data(#"{"schema":"fuji-recipe","version":1,"recipe":{"name":"Invalid","settings":{"highlightTone":1e100}}}"#.utf8)
        await coordinator.load(data: data, sourceName: "Invalid").value
        XCTAssertNil(coordinator.pendingImport)
        XCTAssertTrue(coordinator.importError?.contains("highlightTone") == true)
        XCTAssertFalse(coordinator.isPreparingImport)
    }

    // MARK: Pasted text

    func testPastedTextOpensTheReview() throws {
        let coordinator = ImportCoordinator()
        coordinator.importError = "An earlier failure"
        let pasted = try ImportCoordinator.readPastedText("Morning Light\nFilm Simulation: ASTIA\nColor: +1")
        coordinator.review(pasted)
        XCTAssertEqual(coordinator.pendingImport?.recipes.map(\.name), ["Morning Light"])
        XCTAssertEqual(coordinator.pendingImport?.sourceName, ImportCoordinator.pastedTextSourceName)
        XCTAssertNil(coordinator.importError)
    }

    /// The parser reads any number of digits; the import's own bounds still apply to what it read,
    /// reported in words about text rather than a file.
    func testPastedTextIsCheckedLikeAFile() {
        XCTAssertThrowsError(try ImportCoordinator.readPastedText("Color: +9999999999")) { error in
            XCTAssertEqual(error as? RecipeTextParseError, .unsafeNumber(field: "color"))
        }
    }

    func testPastedTextDoesNotReplaceAReviewAlreadyOpen() throws {
        let coordinator = ImportCoordinator()
        coordinator.review(try ImportCoordinator.readPastedText("First\nColor: 0"))
        coordinator.review(try ImportCoordinator.readPastedText("Second\nColor: 1"))
        XCTAssertEqual(coordinator.pendingImport?.recipes.map(\.name), ["First"])
        XCTAssertNotNil(coordinator.importError)
    }

    func testPastedTextWithoutARecipeThrowsTheParseError() {
        XCTAssertThrowsError(try ImportCoordinator.readPastedText("Lovely light today.")) { error in
            XCTAssertEqual(error as? RecipeTextParseError, .noRecipe)
        }
    }

    func testPastedTextReviewSupersedesAFileStillPreparing() async throws {
        let entered = expectation(description: "file preparation")
        let release = DispatchSemaphore(value: 0)
        let coordinator = ImportCoordinator { input, progress in
            let result = try RecipeImportPreparation.prepare(input, progress: progress)
            entered.fulfill()
            _ = release.wait(timeout: .now() + 10)
            return result
        }
        let fileTask = coordinator.load(data: try data("From File"), sourceName: "From File")
        await fulfillment(of: [entered], timeout: 5)
        coordinator.review(try ImportCoordinator.readPastedText("From Text\nColor: 0"))
        release.signal()
        await fileTask.value
        XCTAssertEqual(coordinator.pendingImport?.recipes.map(\.name), ["From Text"])
        XCTAssertFalse(coordinator.isPreparingImport)
    }
}

import XCTest
@testable import FujiCookbook

final class CookPrerequisiteTests: XCTestCase {
    func testNamesWhatTheFormStillNeedsInTheOrderItIsFilledIn() {
        XCTAssertEqual(CookPrerequisite.missing(hasFiles: false, hasRecipe: false, cameraCanConvert: false),
                       .filesAndRecipe)
        XCTAssertEqual(CookPrerequisite.missing(hasFiles: false, hasRecipe: true, cameraCanConvert: true), .files)
        XCTAssertEqual(CookPrerequisite.missing(hasFiles: true, hasRecipe: false, cameraCanConvert: false), .recipe)
        XCTAssertEqual(CookPrerequisite.missing(hasFiles: true, hasRecipe: true, cameraCanConvert: false), .camera)
    }

    func testNothingMissingOnceTheFormIsReady() {
        XCTAssertNil(CookPrerequisite.missing(hasFiles: true, hasRecipe: true, cameraCanConvert: true))
    }

    func testEachScreenSaysItInItsOwnTerms() {
        XCTAssertEqual(CookPrerequisite.filesAndRecipe.message(for: .develop),
                       "Choose a RAW file and a recipe to develop.")
        XCTAssertEqual(CookPrerequisite.filesAndRecipe.message(for: .testKitchen),
                       "Choose RAW files and recipes to compare.")
    }
}

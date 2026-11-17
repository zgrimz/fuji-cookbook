import XCTest
@testable import FujiCookbook

final class VersionRecipeTests: XCTestCase {
    func testMatchesTheOneRecipeWithThatName() {
        let portra = Recipe(name: "Portra 400")
        XCTAssertTrue([Recipe(name: "Kodachrome 64"), portra].uniqueRecipe(named: "Portra 400") === portra)
    }

    func testNoMatchWhenNoRecipeHasThatName() {
        XCTAssertNil([Recipe(name: "Kodachrome 64")].uniqueRecipe(named: "Portra 400"))
    }

    func testNoMatchWhenTwoRecipesShareTheName() {
        XCTAssertNil([Recipe(name: "Portra 400"), Recipe(name: "Portra 400")].uniqueRecipe(named: "Portra 400"))
    }
}

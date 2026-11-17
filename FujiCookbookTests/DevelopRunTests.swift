import XCTest
@testable import FujiCookbook

final class DevelopRunTests: XCTestCase {
    private func result(_ file: String, success: Bool, error: String? = nil) -> ConversionResult {
        var result = ConversionResult(sourceFilename: file, success: success, clampedFields: [])
        result.errorMessage = error
        return result
    }

    func testDevelopRunListsOnlyFailuresByFileName() {
        let run = DevelopRun(batchID: UUID(), results: [result("A.RAF", success: true),
                                                        result("B.RAF", success: false, error: "Refused")])
        XCTAssertEqual(run.failures.map(\.title), ["B.RAF"])
        XCTAssertEqual(run.failures.map(\.message), ["Refused"])
    }

    func testTestKitchenRunNamesEachFailureByRecipeAndFile() {
        let comparison = TestKitchenComparison(sourceFilename: "A.RAF", versions: [
            TestKitchenVersion(recipeName: "Portra 400", filmSimulation: nil, result: result("A.RAF", success: true)),
            TestKitchenVersion(recipeName: "Tri-X Push", filmSimulation: nil, result: result("A.RAF", success: false)),
        ])
        let run = DevelopRun(batchID: UUID(), comparisons: [comparison])
        XCTAssertEqual(run.failures.map(\.title), ["Tri-X Push · A.RAF"])
        XCTAssertEqual(run.failures.map(\.message), ["Unknown error"])
    }
}

import XCTest
@testable import FujiCookbook

final class KitchenResultTitleTests: XCTestCase {
    func testResultSheetTitleSaysWhenARunWasPartial() {
        XCTAssertEqual(KitchenResultView.title(developed: 0, of: 2), "Develop failed")
        XCTAssertEqual(KitchenResultView.title(developed: 1, of: 1), "Developed")
        XCTAssertEqual(KitchenResultView.title(developed: 3, of: 3), "3 Developed")
        XCTAssertEqual(KitchenResultView.title(developed: 2, of: 3), "2 of 3 Developed")
    }
}

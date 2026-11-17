import XCTest
@testable import FujiCookbook

final class VersionAdjustmentsTests: XCTestCase {
    func testRecipeAppliedAsWrittenHasNoAdjustments() {
        XCTAssertEqual(VersionSnapshot.adjustments(clampedFields: [], notes: []), [])
    }

    func testClampedFieldsComeFirstAsOneLineThenEachNote() {
        let adjustments = VersionSnapshot.adjustments(clampedFields: ["Dynamic Range", "Grain"],
                                                      notes: ["First note.", "Second note."])
        XCTAssertEqual(adjustments, ["Adjusted before developing: Dynamic Range, Grain",
                                     "First note.",
                                     "Second note."])
    }

    func testNotesAloneStillCountAsAdjusted() {
        XCTAssertEqual(VersionSnapshot.adjustments(clampedFields: [], notes: ["A note."]), ["A note."])
    }
}

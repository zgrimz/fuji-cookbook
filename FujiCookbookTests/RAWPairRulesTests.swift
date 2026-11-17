import Photos
import XCTest
@testable import FujiCookbook

/// The RAW+JPEG route's decisions: which screen each state of access opens, which of a photo's
/// files is the RAF, and how a choice of shared photos behaves.
final class RAWPairRulesTests: XCTestCase {

    // MARK: Route

    func testEachStateOfAccessOpensItsOwnScreen() {
        XCTAssertEqual(RAWPairRoute(.notDetermined), .explainer, "explain before the one-time prompt")
        XCTAssertEqual(RAWPairRoute(.limited), .sharedPhotos)
        XCTAssertEqual(RAWPairRoute(.full), .photoPicker)
        XCTAssertEqual(RAWPairRoute(.denied), .accessDenied)
        XCTAssertEqual(RAWPairRoute(.restricted), .accessRestricted)
    }

    func testPhotoKitStatusesMapToAccess() {
        XCTAssertEqual(PhotoAccess(.notDetermined), .notDetermined)
        XCTAssertEqual(PhotoAccess(.limited), .limited)
        XCTAssertEqual(PhotoAccess(.authorized), .full)
        XCTAssertEqual(PhotoAccess(.denied), .denied)
        XCTAssertEqual(PhotoAccess(.restricted), .restricted)
        XCTAssertTrue(PhotoAccess.limited.canRead)
        XCTAssertTrue(PhotoAccess.full.canRead)
        XCTAssertFalse(PhotoAccess.notDetermined.canRead)
        XCTAssertFalse(PhotoAccess.denied.canRead)
    }

    // MARK: Resource choice

    private let jpeg = PhotoResource(role: .photo, typeIdentifier: "public.jpeg", originalFileName: "DSCF0926.JPG")
    private let alternateRAF = PhotoResource(role: .alternatePhoto, typeIdentifier: "com.fuji.raw-image",
                                             originalFileName: "DSCF0926.RAF")

    /// The resources an X-T50 pair imported by Photos lists (iPhone 14 Pro, 2026-11-13).
    func testAPairsRAFIsItsAlternatePhoto() {
        XCTAssertEqual(RAWResourceChoice.verdict(for: [jpeg, alternateRAF]), .pair(raf: alternateRAF))
    }

    /// The RAW may sit in either slot: a RAF main photo with a JPEG alternate is a pair too.
    func testARAFMainPhotoWithAJPEGAlternateIsAPair() {
        let mainRAF = PhotoResource(role: .photo, typeIdentifier: "com.fuji.raw-image", originalFileName: "DSCF0361.RAF")
        let alternateJPEG = PhotoResource(role: .alternatePhoto, typeIdentifier: "public.jpeg", originalFileName: "DSCF0361.JPG")
        XCTAssertEqual(RAWResourceChoice.verdict(for: [mainRAF, alternateJPEG]), .pair(raf: mainRAF))
    }

    func testARAWOnlyPhotosRAFIsItsMainPhoto() {
        let raf = PhotoResource(role: .photo, typeIdentifier: "com.fuji.raw-image", originalFileName: "DSCF4072.RAF")
        XCTAssertEqual(RAWResourceChoice.verdict(for: [raf]), .rawOnly(raf: raf))
    }

    func testAJPEGAloneHasNoRAF() {
        XCTAssertEqual(RAWResourceChoice.verdict(for: [jpeg]), .noRAW)
        XCTAssertEqual(RAWResourceChoice.verdict(for: []), .noRAW)
    }

    /// The camera develops only its own format, so an iPhone ProRAW DNG is no RAW here.
    func testAnotherMakersRAWIsNotARAF() {
        let proRAW = PhotoResource(role: .photo, typeIdentifier: "com.adobe.raw-image", originalFileName: "IMG_0001.DNG")
        XCTAssertEqual(RAWResourceChoice.verdict(for: [proRAW]), .noRAW)
        XCTAssertEqual(RAWResourceChoice.verdict(for: [jpeg, proRAW]), .noRAW)
    }

    func testEditsAndOtherResourcesAreNeverTheRAF() {
        let edit = PhotoResource(role: .other, typeIdentifier: "com.fuji.raw-image", originalFileName: "FullSizeRender.RAF")
        XCTAssertEqual(RAWResourceChoice.verdict(for: [jpeg, edit]), .noRAW)
    }

    /// Two RAWs: which one the user meant can't be told, so it's an error, never a guess.
    func testTwoRAWOriginalsAreInvalid() {
        let mainRAF = PhotoResource(role: .photo, typeIdentifier: "com.fuji.raw-image", originalFileName: "DSCF0001.RAF")
        XCTAssertEqual(RAWResourceChoice.verdict(for: [mainRAF, alternateRAF]), .invalid)
        let proRAW = PhotoResource(role: .photo, typeIdentifier: "com.adobe.raw-image", originalFileName: "IMG_0001.DNG")
        XCTAssertEqual(RAWResourceChoice.verdict(for: [proRAW, alternateRAF]), .invalid)
    }

    func testTwoJPEGOriginalsAreInvalid() {
        let alternateJPEG = PhotoResource(role: .alternatePhoto, typeIdentifier: "public.jpeg", originalFileName: "DSCF0926 2.JPG")
        XCTAssertEqual(RAWResourceChoice.verdict(for: [jpeg, alternateJPEG]), .invalid)
    }

    // MARK: Selection

    func testTapsChooseInOrderAndASecondTapUnchooses() {
        var selection = RAWPairSelection(limit: nil)
        selection.toggle("a")
        selection.toggle("b")
        selection.toggle("c")
        XCTAssertEqual(selection.chosen, ["a", "b", "c"])
        XCTAssertEqual(selection.position(of: "b"), 2)
        selection.toggle("b")
        XCTAssertEqual(selection.chosen, ["a", "c"])
        XCTAssertNil(selection.position(of: "b"))
    }

    func testATapPastTheLimitIsRefusedAndChangesNothing() {
        var selection = RAWPairSelection(limit: 2)
        selection.toggle("a")
        selection.toggle("b")
        XCTAssertEqual(selection.toggle("c"), .limitReached(2))
        XCTAssertEqual(selection.chosen, ["a", "b"])
    }

    func testWithALimitOfOneATapReplacesTheChoice() {
        var selection = RAWPairSelection(limit: 1)
        selection.toggle("a")
        XCTAssertNil(selection.toggle("b"))
        XCTAssertEqual(selection.chosen, ["b"])
    }

    func testNewlySharedPhotosAreChosenWhileThereIsRoom() {
        var selection = RAWPairSelection(limit: 3)
        selection.toggle("a")
        selection.chooseNewlyShared(["a", "x", "y", "z"])
        XCTAssertEqual(selection.chosen, ["a", "x", "y"], "already chosen stays put; the rest fill the room in order")
    }

    func testWithoutALimitEveryNewlySharedPhotoIsChosen() {
        var selection = RAWPairSelection(limit: nil)
        selection.chooseNewlyShared(["x", "y"])
        XCTAssertEqual(selection.chosen, ["x", "y"])
    }

    func testWithALimitOfOneTheFirstNewlySharedPhotoReplacesTheChoice() {
        var selection = RAWPairSelection(limit: 1)
        selection.toggle("a")
        selection.chooseNewlyShared(["x", "y"])
        XCTAssertEqual(selection.chosen, ["x"])
    }

    func testPhotosNoLongerSharedLeaveTheChoice() {
        var selection = RAWPairSelection(limit: nil)
        selection.chooseNewlyShared(["a", "b", "c"])
        selection.keepOnly(["a", "c"])
        XCTAssertEqual(selection.chosen, ["a", "c"])
    }
}

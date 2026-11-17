import PhotosUI
import SwiftUI
import XCTest
@testable import FujiCookbook

/// The RAW+JPEG sheet across the answers a user can give, against a library with no Photos behind it.
@MainActor
final class RAWPairPickerModelTests: XCTestCase {
    private func photo(_ id: String, _ kind: SharedRAWPhoto.Kind = .pair) -> SharedRAWPhoto {
        SharedRAWPhoto(id: id, creationDate: nil, kind: kind)
    }

    func testTheExplainerComesBeforeTheOneTimePrompt() {
        let model = RAWPairPickerModel(library: FakePhotoLibrary(access: .notDetermined), limit: nil)
        XCTAssertEqual(model.screen, .explainer)
    }

    /// The prompt's own selection reports nothing, but every photo shared then was chosen a moment
    /// ago, so they arrive chosen.
    func testLimitAccessShowsThePhotosJustSelectedChosen() async {
        let library = FakePhotoLibrary(access: .notDetermined, accessAfterRequest: .limited)
        library.shared = SharedRAWPhotos(photos: [photo("a"), photo("b")])
        let model = RAWPairPickerModel(library: library, limit: nil)

        await model.requestAccess()

        XCTAssertEqual(library.requests, 1)
        XCTAssertEqual(model.screen, .sharedPhotos)
        XCTAssertEqual(model.selection.chosen, ["a", "b"])
    }

    func testPhotosThatDontFitTheLimitArriveUnchosen() async {
        let library = FakePhotoLibrary(access: .notDetermined, accessAfterRequest: .limited)
        library.shared = SharedRAWPhotos(photos: [photo("a"), photo("b")])
        let model = RAWPairPickerModel(library: library, limit: 1)

        await model.requestAccess()

        XCTAssertEqual(model.selection.chosen, [], "choosing one of two for the user would be a guess")
    }

    func testFullAccessHandsOverToTheRegularPicker() async {
        let library = FakePhotoLibrary(access: .notDetermined, accessAfterRequest: .full)
        let model = RAWPairPickerModel(library: library, limit: nil)

        await model.requestAccess()

        XCTAssertEqual(model.outcome, .useRegularPicker)
    }

    func testDontAllowShowsTheWayBack() async {
        let library = FakePhotoLibrary(access: .notDetermined, accessAfterRequest: .denied)
        let model = RAWPairPickerModel(library: library, limit: nil)

        await model.requestAccess()

        XCTAssertEqual(model.screen, .accessDenied)
        XCTAssertNil(model.outcome)
    }

    /// Back from the Settings app with access granted, the sheet moves on without being reopened.
    func testAccessGrantedInSettingsIsPickedUpOnReturn() async {
        let library = FakePhotoLibrary(access: .denied)
        library.shared = SharedRAWPhotos(photos: [photo("a")])
        let model = RAWPairPickerModel(library: library, limit: nil)
        XCTAssertEqual(model.screen, .accessDenied)

        library.access = .limited
        await model.refreshAccess()

        XCTAssertEqual(model.screen, .sharedPhotos)
        XCTAssertEqual(model.shared.photos.map(\.id), ["a"])
    }

    /// The system prompt sends the app inactive and back; that return must not re-route the sheet
    /// under the request still in flight.
    func testARefreshWhileTheRequestIsInFlightChangesNothing() async {
        let library = FakePhotoLibrary(access: .notDetermined, accessAfterRequest: .limited)
        library.holdsAccessRequest = true
        let model = RAWPairPickerModel(library: library, limit: nil)

        let request = Task { @MainActor in await model.requestAccess() }
        while !library.isHoldingAccessRequest { await Task.yield() }
        XCTAssertTrue(model.isRequestingAccess)
        library.access = .denied
        await model.refreshAccess()
        XCTAssertEqual(model.screen, .explainer, "the in-flight request decides, not the refresh")

        library.releaseAccessRequest()
        await request.value
        XCTAssertEqual(model.screen, .sharedPhotos)
    }

    /// Full access granted in Settings hands over to the regular picker on return.
    func testFullAccessGrantedInSettingsHandsOverOnReturn() async {
        let library = FakePhotoLibrary(access: .denied)
        let model = RAWPairPickerModel(library: library, limit: nil)

        library.access = .full
        await model.refreshAccess()

        XCTAssertEqual(model.outcome, .useRegularPicker)
    }

    func testRestrictedAccessStaysOnItsScreen() async {
        let library = FakePhotoLibrary(access: .restricted)
        let model = RAWPairPickerModel(library: library, limit: nil)
        XCTAssertEqual(model.screen, .accessRestricted)

        await model.refreshAccess()

        XCTAssertEqual(model.screen, .accessRestricted)
        XCTAssertNil(model.outcome)
    }

    /// A change to what the app can see, such as a deselection in Settings, reloads the photos.
    func testAChangeInTheLibraryReloadsThePhotos() async {
        let library = FakePhotoLibrary(access: .limited)
        library.shared = SharedRAWPhotos(photos: [photo("a")])
        let model = RAWPairPickerModel(library: library, limit: nil)
        await model.load()

        let following = Task { @MainActor in await model.followChanges() }
        while !library.isFollowingChanges { await Task.yield() }
        library.shared = SharedRAWPhotos(photos: [photo("a"), photo("b")])
        library.announceChange()
        while model.shared.photos.count < 2 { await Task.yield() }
        following.cancel()

        XCTAssertEqual(model.shared.photos.map(\.id), ["a", "b"])
    }

    /// Apple's screen reports every photo newly selected; only those with a RAF can be chosen.
    func testNewlySharedPhotosWithARAFAreChosen() async {
        let library = FakePhotoLibrary(access: .limited)
        library.shared = SharedRAWPhotos(photos: [photo("old"), photo("new")], withoutRAW: 1)
        let model = RAWPairPickerModel(library: library, limit: nil)

        await model.choose(newlyShared: ["new", "plain-jpeg"])

        XCTAssertEqual(model.selection.chosen, ["new"])
        XCTAssertEqual(model.shared.withoutRAW, 1)
    }

    func testATapPastTheLimitSaysSoUntilATapWorks() async {
        let library = FakePhotoLibrary(access: .limited)
        library.shared = SharedRAWPhotos(photos: [photo("a"), photo("b"), photo("c")])
        let model = RAWPairPickerModel(library: library, limit: 2)
        await model.load()

        model.toggle("a")
        model.toggle("b")
        model.toggle("c")
        XCTAssertEqual(model.refusal, .limitReached(2))
        model.toggle("a")
        XCTAssertNil(model.refusal)
        XCTAssertEqual(model.selection.chosen, ["b"])
    }

    /// A photo removed from the user's selection elsewhere leaves the choice when the sheet reloads.
    func testAPhotoNoLongerSharedLeavesTheChoice() async {
        let library = FakePhotoLibrary(access: .limited)
        library.shared = SharedRAWPhotos(photos: [photo("a"), photo("b")])
        let model = RAWPairPickerModel(library: library, limit: nil)
        await model.load()
        model.toggle("a")
        model.toggle("b")

        library.shared = SharedRAWPhotos(photos: [photo("b")])
        await model.load()

        XCTAssertEqual(model.selection.chosen, ["b"])
    }

    func testAddEndsWithTheChoiceInTapOrder() async {
        let library = FakePhotoLibrary(access: .limited)
        library.shared = SharedRAWPhotos(photos: [photo("a"), photo("b")])
        let model = RAWPairPickerModel(library: library, limit: nil)
        await model.load()
        model.toggle("b")
        model.toggle("a")

        model.add()

        XCTAssertEqual(model.outcome, .picked(["b", "a"]))
    }

    // MARK: The regular picker with access already granted

    /// With access, a pick the picker offers only a JPEG for is read through the library.
    func testAPickedPairIsReadThroughTheLibraryWhenTheAppHasAccess() async {
        let library = FakePhotoLibrary(access: .limited)
        library.outcomes = ["pair": .raf("DSCF0926.RAF")]

        let result = await PhotoLibraryRAW.copy([PhotosPickerItem(itemIdentifier: "pair")], library: library)

        XCTAssertEqual(result.urls.map(\.lastPathComponent), ["DSCF0926.RAF"])
        XCTAssertNil(result.problem)
        result.urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
    }

    /// Without access the library is never touched, and the photo counts as without a RAW.
    func testWithoutAccessAPickedJPEGIsCountedAndTheLibraryUntouched() async {
        let library = FakePhotoLibrary(access: .notDetermined)

        let result = await PhotoLibraryRAW.copy([PhotosPickerItem(itemIdentifier: "pair")], library: library)

        XCTAssertEqual(result.withoutRAW, 1)
        XCTAssertTrue(library.copied.isEmpty)
        XCTAssertEqual(library.requests, 0, "the regular picker never asks for access")
    }

    /// Full access: the library looked inside and found no RAW, so the photo counts as checked and
    /// the alert doesn't send the user back to the same picker.
    func testAPickTheLibraryConfirmsHasNoRAWCountsAsChecked() async {
        let library = FakePhotoLibrary(access: .full)
        library.outcomes = ["jpeg": .fails(RAWCopyError.noRAW)]

        let result = await PhotoLibraryRAW.copy([PhotosPickerItem(itemIdentifier: "jpeg")], library: library)

        XCTAssertEqual(result.checkedWithoutRAW, 1)
        XCTAssertEqual(result.withoutRAW, 0)
        XCTAssertEqual(result.problem?.offersRAWPairs, false)
    }

    /// Limited access to other photos: a pick outside the selection fetches nothing.
    func testAPickOutsideTheLimitedSelectionCountsAsWithoutARAW() async {
        let library = FakePhotoLibrary(access: .limited)

        let result = await PhotoLibraryRAW.copy([PhotosPickerItem(itemIdentifier: "elsewhere")], library: library)

        XCTAssertEqual(result.withoutRAW, 1)
        XCTAssertEqual(result.failed, 0)
    }
}

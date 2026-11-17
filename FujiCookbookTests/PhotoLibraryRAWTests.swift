import UniformTypeIdentifiers
import XCTest
@testable import FujiCookbook

/// Picking RAW files from Photos: which photos count as carrying a RAW, and what the picker says
/// about the ones that didn't arrive.
final class PhotoLibraryRAWTests: XCTestCase {

    private let raf = URL(fileURLWithPath: "/tmp/DSCF0001.RAF")

    func testAFujifilmRAFCountsAsARAW() throws {
        let fujiRAW = try XCTUnwrap(UTType("com.fuji.raw-image"), "the system declares Fujifilm's RAW type")
        XCTAssertTrue(PhotoLibraryRAW.carriesRAW([fujiRAW]))
    }

    func testAJPEGOrHEICAloneIsNotARAW() {
        XCTAssertFalse(PhotoLibraryRAW.carriesRAW([.jpeg]))
        XCTAssertFalse(PhotoLibraryRAW.carriesRAW([.heic]))
        XCTAssertFalse(PhotoLibraryRAW.carriesRAW([]))
    }

    func testARAWAmongOtherTypesCountsAsARAW() throws {
        let fujiRAW = try XCTUnwrap(UTType("com.fuji.raw-image"))
        XCTAssertTrue(PhotoLibraryRAW.carriesRAW([.jpeg, fujiRAW]))
    }

    func testACleanImportHasNoProblem() {
        XCTAssertNil(PhotoLibraryRAW.Import(urls: [raf]).problem)
        XCTAssertNil(PhotoLibraryRAW.Import().problem, "cancelling the picker picks nothing and says nothing")
    }

    /// The fact first, then the pair route — conditional, since a plain JPEG has no RAW to reach —
    /// then the plain .RAF. A tester who picked a plain JPEG read an older wording as Photos hiding
    /// a RAW from the app.
    func testOnePhotoWithoutARAWSaysSoAndOffersThePairRoute() throws {
        let problem = try XCTUnwrap(PhotoLibraryRAW.Import(withoutRAW: 1).problem)
        XCTAssertEqual(problem.title, "Couldn't Use That Photo")
        XCTAssertTrue(problem.offersRAWPairs)
        XCTAssertEqual(problem.message, "That photo came without a RAW file. If you shot RAW+JPEG, use Choose RAW+JPEG Photos: Photos keeps the RAW behind the JPEG, where the photo picker can't reach it. Otherwise, pick the .RAF itself, from Photos or with Browse Files.")
    }

    func testEveryPhotoWithoutARAWSaysNone() throws {
        let problem = try XCTUnwrap(PhotoLibraryRAW.Import(withoutRAW: 3).problem)
        XCTAssertEqual(problem.title, "Couldn't Use Those Photos")
        XCTAssertEqual(problem.message, "None of those photos came with a RAW file. If you shot RAW+JPEG, use Choose RAW+JPEG Photos: Photos keeps the RAW behind the JPEG, where the photo picker can't reach it. Otherwise, pick the .RAF itself, from Photos or with Browse Files.")
    }

    func testSomePhotosWithoutARAWAreCountedAgainstThePick() throws {
        let one = try XCTUnwrap(PhotoLibraryRAW.Import(urls: [raf, raf], withoutRAW: 1).problem)
        XCTAssertEqual(one.title, "Some Photos Weren't Added")
        XCTAssertEqual(one.message, "1 of the 3 photos came without a RAW file. If you shot RAW+JPEG, use Choose RAW+JPEG Photos: Photos keeps the RAW behind the JPEG, where the photo picker can't reach it. Otherwise, pick the .RAF itself, from Photos or with Browse Files.")

        let two = try XCTUnwrap(PhotoLibraryRAW.Import(urls: [raf], withoutRAW: 2).problem)
        XCTAssertEqual(two.message, "2 of the 3 photos came without a RAW file. If you shot RAW+JPEG, use Choose RAW+JPEG Photos: Photos keeps the RAW behind the JPEG, where the photo picker can't reach it. Otherwise, pick the .RAF itself, from Photos or with Browse Files.")
    }

    func testAFailedCopyAsksToTryAgain() throws {
        let single = try XCTUnwrap(PhotoLibraryRAW.Import(failed: 1).problem)
        XCTAssertEqual(single.title, "Couldn't Use That Photo")
        XCTAssertFalse(single.offersRAWPairs, "a copy that failed has a RAW; the pair route wouldn't help")
        XCTAssertEqual(single.message, "Couldn't copy that photo from your library. Try again.")

        let all = try XCTUnwrap(PhotoLibraryRAW.Import(failed: 2).problem)
        XCTAssertEqual(all.title, "Couldn't Use Those Photos")
        XCTAssertEqual(all.message, "Couldn't copy those photos from your library. Try again.")

        let some = try XCTUnwrap(PhotoLibraryRAW.Import(urls: [raf], failed: 1).problem)
        XCTAssertEqual(some.message, "1 of the 2 photos couldn't be copied from your library. Try picking it again.")
    }

    /// A photo the library looked inside and found no RAW in isn't offered Choose RAW+JPEG Photos,
    /// which would find nothing either: under full access it reopens the same picker.
    func testAPhotoConfirmedToHaveNoRAWIsNotOfferedThePairRoute() throws {
        let problem = try XCTUnwrap(PhotoLibraryRAW.Import(checkedWithoutRAW: 1).problem)
        XCTAssertFalse(problem.offersRAWPairs)
        XCTAssertEqual(problem.message, "That photo came without a RAW file. Pick the .RAF itself, from Photos or with Browse Files.")
    }

    /// One unchecked photo among checked ones is enough to offer the route.
    func testAnUncheckedPhotoAmongCheckedOnesStillOffersThePairRoute() throws {
        let problem = try XCTUnwrap(PhotoLibraryRAW.Import(withoutRAW: 1, checkedWithoutRAW: 1).problem)
        XCTAssertTrue(problem.offersRAWPairs)
        XCTAssertTrue(problem.message.hasPrefix("None of those photos came with a RAW file. If you shot RAW+JPEG"))
    }

    /// A photo holding two RAWs or two JPEGs is an error the user can act on, not a failed copy.
    func testAPhotoWithTwoRAWsOrTwoJPEGsSaysWhy() throws {
        let one = try XCTUnwrap(PhotoLibraryRAW.Import(unusable: 1).problem)
        XCTAssertEqual(one.title, "Couldn't Use That Photo")
        XCTAssertEqual(one.message, "That photo holds two RAW files or two JPEG files, so the app can't tell which one to develop.")
        XCTAssertFalse(one.offersRAWPairs)

        let some = try XCTUnwrap(PhotoLibraryRAW.Import(urls: [raf], unusable: 1).problem)
        XCTAssertEqual(some.message, "1 of the 2 photos holds two RAW files or two JPEG files, so the app can't tell which one to develop.")
    }

    func testAMixedPickNamesBothProblems() throws {
        let problem = try XCTUnwrap(PhotoLibraryRAW.Import(urls: [raf], withoutRAW: 1, failed: 2).problem)
        XCTAssertEqual(problem.title, "Some Photos Weren't Added")
        XCTAssertEqual(problem.message, "1 of the 4 photos came without a RAW file. If you shot RAW+JPEG, use Choose RAW+JPEG Photos: Photos keeps the RAW behind the JPEG, where the photo picker can't reach it. Otherwise, pick the .RAF itself, from Photos or with Browse Files. 2 of the 4 photos couldn't be copied from your library. Try picking them again.")
    }
}

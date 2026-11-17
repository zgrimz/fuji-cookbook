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

    // MARK: - A RAW that isn't a RAF

    private static let rafSignature = Array("FUJIFILMCCD-RAW 0201".utf8)
    /// Little-endian TIFF, as a DNG starts (X-T30 III owner's report, 2026-11-16: the Photos picker
    /// handed over a RAW that the upload refused as `tiff`).
    private static let tiffSignature: [UInt8] = [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]

    /// A copy laid out as `ReceivedRAW` makes one: a file in a directory of its own.
    private func makeCopy(named name: String, bytes: [UInt8]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(name)
        try Data(bytes + [UInt8](repeating: 0, count: 64)).write(to: file)
        return file
    }

    func testACopiedRAFIsKept() throws {
        let copy = try makeCopy(named: "DSCF0001.RAF", bytes: Self.rafSignature)
        var result = PhotoLibraryRAW.Import()
        try PhotoLibraryRAW.admit(copy, into: &result)
        XCTAssertEqual(result, PhotoLibraryRAW.Import(urls: [copy]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    func testACopiedDNGIsRefusedAndRemoved() throws {
        let copy = try makeCopy(named: "IMG_0001.DNG", bytes: Self.tiffSignature)
        var result = PhotoLibraryRAW.Import()
        try PhotoLibraryRAW.admit(copy, into: &result)
        XCTAssertEqual(result, PhotoLibraryRAW.Import(notRAF: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path),
                       "the refused copy's directory is removed")
    }

    /// The file's name is no evidence: a DNG renamed .RAF is still refused.
    func testTheBytesDecideNotTheName() throws {
        let copy = try makeCopy(named: "DSCF0001.RAF", bytes: Self.tiffSignature)
        var result = PhotoLibraryRAW.Import()
        try PhotoLibraryRAW.admit(copy, into: &result)
        XCTAssertEqual(result.notRAF, 1)
        XCTAssertTrue(result.urls.isEmpty)
    }

    func testAnUnreadableCopyThrowsAndIsRemoved() throws {
        let copy = try makeCopy(named: "DSCF0001.RAF", bytes: Self.rafSignature)
        try FileManager.default.removeItem(at: copy)
        var result = PhotoLibraryRAW.Import()
        XCTAssertThrowsError(try PhotoLibraryRAW.admit(copy, into: &result))
        XCTAssertEqual(result, PhotoLibraryRAW.Import())
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
    }

    func testOnePhotoWhoseRAWIsNotARAFSaysSo() throws {
        let problem = try XCTUnwrap(PhotoLibraryRAW.Import(notRAF: 1).problem)
        XCTAssertEqual(problem.title, "Couldn't Use That Photo")
        XCTAssertFalse(problem.offersRAWPairs, "the photo had a RAW; the pair route wouldn't find a RAF")
        XCTAssertEqual(problem.message, "That photo's RAW isn't a Fujifilm .RAF file. The camera can develop only a .RAF it shot. An iPhone's ProRAW photos, for one, are DNG files.")
    }

    func testEveryOrSomePhotosWhoseRAWIsNotARAFAreCounted() throws {
        let all = try XCTUnwrap(PhotoLibraryRAW.Import(notRAF: 2).problem)
        XCTAssertEqual(all.title, "Couldn't Use Those Photos")
        XCTAssertTrue(all.message.hasPrefix("None of those photos' RAWs is a Fujifilm .RAF file. "))

        let one = try XCTUnwrap(PhotoLibraryRAW.Import(urls: [raf, raf], notRAF: 1).problem)
        XCTAssertEqual(one.title, "Some Photos Weren't Added")
        XCTAssertTrue(one.message.hasPrefix("1 of the 3 photos has a RAW that isn't a Fujifilm .RAF file. "))

        let two = try XCTUnwrap(PhotoLibraryRAW.Import(urls: [raf], notRAF: 2).problem)
        XCTAssertTrue(two.message.hasPrefix("2 of the 3 photos have RAWs that aren't Fujifilm .RAF files. "))
    }

    func testAMixedPickNamesBothProblems() throws {
        let problem = try XCTUnwrap(PhotoLibraryRAW.Import(urls: [raf], withoutRAW: 1, failed: 2).problem)
        XCTAssertEqual(problem.title, "Some Photos Weren't Added")
        XCTAssertEqual(problem.message, "1 of the 4 photos came without a RAW file. If you shot RAW+JPEG, use Choose RAW+JPEG Photos: Photos keeps the RAW behind the JPEG, where the photo picker can't reach it. Otherwise, pick the .RAF itself, from Photos or with Browse Files. 2 of the 4 photos couldn't be copied from your library. Try picking them again.")
    }
}

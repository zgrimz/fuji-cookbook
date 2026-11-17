import XCTest
@testable import FujiCookbook

@MainActor
final class RAWPhotoCopyTests: XCTestCase {
    func testRAFsCopyInTheOrderGivenUnderTheirOriginalNames() async throws {
        let library = FakePhotoLibrary()
        library.outcomes = ["b": .raf("DSCF0002.RAF"), "a": .raf("DSCF0001.RAF")]
        let copy = RAWPhotoCopy()

        let result = await copy.copy(["b", "a"], from: library)

        XCTAssertEqual(result.urls.map(\.lastPathComponent), ["DSCF0002.RAF", "DSCF0001.RAF"])
        XCTAssertEqual(library.copied, ["b", "a"])
        XCTAssertNil(result.problem)
        XCTAssertNil(copy.progress, "progress clears when the copy ends")
        result.urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
    }

    /// One photo failing never stops the rest; each outcome is counted where it belongs.
    func testAPhotoWithoutARAFAndAFailedCopyAreCountedSeparately() async {
        let library = FakePhotoLibrary()
        library.outcomes = ["ok": .raf("DSCF0001.RAF"), "jpeg": .fails(RAWCopyError.noRAW),
                            "gone": .fails(RAWCopyError.notVisible)]

        let result = await RAWPhotoCopy().copy(["jpeg", "gone", "ok"], from: library)

        XCTAssertEqual(result.urls.count, 1)
        XCTAssertEqual(result.checkedWithoutRAW, 1)
        XCTAssertEqual(result.failed, 1)
        result.urls.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
    }

    /// Cancelled before it starts, the copy asks the library for nothing.
    func testACopyCancelledBeforeItStartsCopiesNothing() async {
        let library = FakePhotoLibrary()
        library.outcomes = ["a": .raf("DSCF0001.RAF")]
        let copy = RAWPhotoCopy()

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await copy.copy(["a"], from: library)
        }
        let result = await task.value

        XCTAssertEqual(result, PhotoLibraryRAW.Import())
        XCTAssertTrue(library.copied.isEmpty, "a cancelled task starts no copy")
    }

    /// Cancelled while the second file downloads, the copy removes the first and returns nothing.
    func testACopyCancelledMidwayRemovesWhatItCopied() async throws {
        let library = FakePhotoLibrary()
        library.outcomes = ["a": .raf("DSCF0001.RAF"), "b": .holdsUntilCancelled]
        let copy = RAWPhotoCopy()

        let task = Task { @MainActor in await copy.copy(["a", "b"], from: library) }
        while library.copied.count < 2 { await Task.yield() }
        XCTAssertEqual(copy.progress?.file, 2)
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, PhotoLibraryRAW.Import())
        let first = try XCTUnwrap(library.written.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the finished copy is removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        XCTAssertNil(copy.progress)
    }
}

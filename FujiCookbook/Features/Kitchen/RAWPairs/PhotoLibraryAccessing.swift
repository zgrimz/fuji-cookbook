import SwiftUI
import UIKit

/// The photo library, as the RAW+JPEG route reads it. Production is `PhotoKitLibrary`; tests use a
/// double, so the route's decisions run without a Photos library.
///
/// Nothing here asks for access except `requestAccess()`, and nothing reads a photo the user hasn't
/// shared with the app.
protocol PhotoLibraryAccessing: AnyObject {
    var access: PhotoAccess { get }

    /// Shows the system prompt if the app hasn't asked before, and returns the answer.
    func requestAccess() async -> PhotoAccess

    /// Every photo the app can see, newest first, split by whether it carries a RAF. Meant for
    /// limited access, where that is the user's own selection.
    func sharedRAWPhotos() async -> SharedRAWPhotos

    func thumbnail(for id: String, side: CGFloat) async -> UIImage?

    /// Copies the photo's RAF into a directory of its own in the temporary directory, under its
    /// original name, and returns the file. Downloads it from iCloud when the phone doesn't hold the
    /// original; `progress` reports that download from 0 to 1.
    func copyRAF(of id: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL

    /// Yields each time the photos the app can see change: a new selection, an edit, a deletion.
    func changes() -> AsyncStream<Void>

    /// Shows Apple's limited-library selection screen over `controller` and reports the
    /// identifiers of the photos newly selected in it, on the main queue. The screen shows only
    /// while access is limited, and photos already selected are never reported.
    func presentSelection(from controller: UIViewController, completion: @escaping ([String]) -> Void)
}

/// Why a photo's RAF couldn't be copied.
enum RAWCopyError: Error, Equatable {
    /// The photo isn't one the app can see, or was deleted.
    case notVisible
    /// The photo carries no Fujifilm RAW.
    case noRAW
    /// The photo's originals are two RAWs or two non-RAW images, so which one to develop can't be
    /// told; see `RAWResourceChoice.Verdict.invalid`.
    case invalidOriginals
}

private struct PhotoLibraryKey: EnvironmentKey {
    static let defaultValue: any PhotoLibraryAccessing = PhotoKitLibrary()
}

extension EnvironmentValues {
    var photoLibrary: any PhotoLibraryAccessing {
        get { self[PhotoLibraryKey.self] }
        set { self[PhotoLibraryKey.self] = newValue }
    }
}

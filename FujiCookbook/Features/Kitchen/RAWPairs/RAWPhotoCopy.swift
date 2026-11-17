import Foundation

/// Copies the RAFs of shared photos out of the library, one at a time in the order given, and
/// publishes how far it has got so the Kitchen can show it.
@MainActor
@Observable
final class RAWPhotoCopy {
    /// Which file is copying, and how much of its iCloud download has arrived; nil when the phone
    /// holds the original and there's nothing to download, or before Photos reports any.
    struct Progress: Equatable {
        let file: Int
        let count: Int
        var download: Double?
    }

    private(set) var progress: Progress?

    /// The RAFs copied into the temporary directory, with the photos that had none or failed
    /// counted. A cancelled copy removes what it copied and returns nothing.
    func copy(_ ids: [String], from library: any PhotoLibraryAccessing) async -> PhotoLibraryRAW.Import {
        var result = PhotoLibraryRAW.Import()
        defer { progress = nil }
        for (index, id) in ids.enumerated() {
            guard !Task.isCancelled else { break }
            let file = index + 1
            progress = Progress(file: file, count: ids.count)
            do {
                let url = try await library.copyRAF(of: id) { [weak self] fraction in
                    // Fire and forget: PhotoKit reports from its own queue, and a late or lost
                    // update only holds the bar back until the next one. `report` drops updates
                    // for a file that is no longer copying.
                    Task { @MainActor in self?.report(download: fraction, file: file) }
                }
                result.urls.append(url)
            } catch RAWCopyError.noRAW {
                result.checkedWithoutRAW += 1
            } catch RAWCopyError.invalidOriginals {
                result.unusable += 1
            } catch {
                // A cancelled download ends in PhotoKit's own error; the cancellation, not the
                // error, is what happened.
                guard !Task.isCancelled else { break }
                result.failed += 1
                AppLog.error(.kitchen, "Couldn't copy a shared photo's RAW out of the library — \(AppLog.bounded(error))")
            }
        }
        guard !Task.isCancelled else {
            result.discardCopies()
            return PhotoLibraryRAW.Import()
        }
        return result
    }

    private func report(download fraction: Double, file: Int) {
        guard progress?.file == file else { return }
        progress?.download = fraction
    }

}

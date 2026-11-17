import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Copies the RAW file out of photos picked from the photo library, so a pick from Photos reaches
/// `PickedRAFStore` as a file URL, the way a pick from Files does.
///
/// Each item is loaded through a `Transferable` that imports a RAW image and nothing else, so a
/// photo's JPEG or HEIC can never stand in for the RAF the camera is about to develop. The picker
/// offers any RAW under that type, an iPhone's ProRAW DNG among them, so each copy is kept only if
/// its bytes start with the RAF signature, the check the upload makes. A photo without a RAW
/// resource, or with one that isn't a RAF, is counted rather than dropped, so the picker can say
/// what it left out.
///
/// The picker shares a RAW-only photo's RAF — a RAF the Fujifilm app downloaded to the phone is one
/// (X-T50 owner, 2026-10-31). A RAW+JPEG pair held as one photo is different: the picker offers
/// `public.jpeg` and two private thumbnail types, and asking it for a RAW fails (iPhone 14 Pro,
/// iOS 27.0.1, 2026-11-13). Its RAF is reachable only with photo library access, so a pair is
/// copied through `PhotoLibraryAccessing` when the user has already granted it, and otherwise
/// counted as a photo without a RAW. This never asks for access; Choose RAW+JPEG Photos does.
enum PhotoLibraryRAW {
    /// What copying a selection produced: the RAW files now in the app's temporary directory, and
    /// how many picked photos didn't yield one.
    struct Import: Equatable {
        var urls: [URL] = []
        /// Photos the picker shares no RAW for and the app couldn't look inside: a JPEG or HEIC with
        /// nothing attached, which is the usual case, or a RAW+JPEG pair held as one photo.
        var withoutRAW = 0
        /// Photos the app looked inside through photo library access and found no Fujifilm RAW in,
        /// so Choose RAW+JPEG Photos wouldn't find one either.
        var checkedWithoutRAW = 0
        /// Photos that offer a RAW but couldn't be copied out of the library.
        var failed = 0
        /// Photos whose originals are two RAWs or two non-RAW images, so which to develop can't be
        /// told; see `RAWResourceChoice.Verdict.invalid`.
        var unusable = 0
        /// Photos whose RAW was copied and turned out not to be a RAF: an iPhone's ProRAW DNG or
        /// another maker's RAW. The copy is removed.
        var notRAF = 0
    }

    /// Whether a picked photo offers a RAW resource, judged from its content types before anything
    /// is loaded, so "no RAW here" stays distinct from "the copy failed".
    static func carriesRAW(_ types: [UTType]) -> Bool {
        types.contains { $0.conforms(to: .rawImage) }
    }

    /// Copy each picked photo's RAW file into the app, in the order picked. A cancelled copy stops
    /// early, removes what it copied and returns nothing.
    static func copy(_ items: [PhotosPickerItem], library: any PhotoLibraryAccessing) async -> Import {
        var result = Import()
        for item in items {
            guard !Task.isCancelled else { break }
            guard carriesRAW(item.supportedContentTypes) else {
                await copyThroughLibrary(item, from: library, into: &result)
                continue
            }
            do {
                if let raw = try await item.loadTransferable(type: ReceivedRAW.self) {
                    try admit(raw.url, into: &result)
                } else {
                    result.failed += 1
                }
            } catch {
                result.failed += 1
                AppLog.error(.kitchen, "Couldn't copy a picked photo's RAW out of the library — \(AppLog.bounded(error))")
            }
        }
        guard !Task.isCancelled else {
            result.discardCopies()
            return Import()
        }
        return result
    }

    /// Keep a copied RAW if it is a RAF; otherwise remove the copy and count it as `notRAF`.
    /// Throws when the copy can't be read, having removed it; the caller counts a failed copy.
    static func admit(_ copy: URL, into result: inout Import) throws {
        let directory = copy.deletingLastPathComponent()
        let kind: FileKind
        do {
            kind = try FileKind.detect(head(of: copy))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        guard kind == .raf else {
            try? FileManager.default.removeItem(at: directory)
            result.notRAF += 1
            AppLog.error(.kitchen, "Refused a picked RAW with no RAF header (\(kind.rawValue))")
            return
        }
        result.urls.append(copy)
    }

    /// Enough of a file's start for `FileKind.detect` to tell every kind it knows.
    private static func head(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: 16) ?? Data()
    }
}

extension PhotoLibraryRAW {
    /// A photo the picker offers no RAW for: its RAF read by identifier when the app already has
    /// photo library access to it, else counted as without a RAW. With limited access a pick outside
    /// the user's selection fetches nothing and counts as without.
    private static func copyThroughLibrary(_ item: PhotosPickerItem, from library: any PhotoLibraryAccessing,
                                           into result: inout Import) async {
        guard library.access.canRead, let id = item.itemIdentifier else {
            result.withoutRAW += 1
            return
        }
        do {
            result.urls.append(try await library.copyRAF(of: id) { _ in })
        } catch RAWCopyError.notVisible {
            result.withoutRAW += 1
        } catch RAWCopyError.noRAW {
            result.checkedWithoutRAW += 1
        } catch RAWCopyError.invalidOriginals {
            result.unusable += 1
        } catch {
            guard !Task.isCancelled else { return }
            result.failed += 1
            AppLog.error(.kitchen, "Couldn't copy a picked photo's RAW out of the library — \(AppLog.bounded(error))")
        }
    }
}

extension PhotoLibraryRAW.Import {
    /// Removes the copied files. Each copy sits in a temporary directory of its own, so removing
    /// the directory removes the copy.
    func discardCopies() {
        for url in urls {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    /// What to tell the user about the photos that didn't make it into the selection.
    struct Problem: Equatable {
        let title: String
        let message: String
        /// Whether the alert offers Choose RAW+JPEG Photos: a photo came without a RAW, and it may be
        /// a pair whose RAW the picker can't share.
        var offersRAWPairs = false
    }

    /// Nil when every picked photo arrived as a RAF.
    var problem: Problem? {
        let noRAW = withoutRAW + checkedWithoutRAW
        guard noRAW + notRAF + failed + unusable > 0 else { return nil }
        let total = urls.count + noRAW + notRAF + failed + unusable
        var sentences: [String] = []
        if noRAW > 0 {
            // The plain fact first: what arrived had no RAW, which for a JPEG is simply what it is.
            // Where the app couldn't look inside a photo, it can't tell a plain JPEG from a pair, so
            // the pair route is offered conditionally, and the way in for a plain .RAF comes after
            // it. A photo the library confirmed has no RAW gets only the plain .RAF route.
            if total == 1 {
                sentences.append("That photo came without a RAW file.")
            } else if noRAW == total {
                sentences.append("None of those photos came with a RAW file.")
            } else {
                sentences.append("\(noRAW) of the \(total) photos came without a RAW file.")
            }
            if withoutRAW > 0 {
                sentences.append("If you shot RAW+JPEG, use Choose RAW+JPEG Photos: Photos keeps the RAW behind the JPEG, where the photo picker can't reach it.")
                sentences.append("Otherwise, pick the .RAF itself, from Photos or with Browse Files.")
            } else {
                sentences.append("Pick the .RAF itself, from Photos or with Browse Files.")
            }
        }
        if notRAF > 0 {
            sentences.append(notRAFSentence(total: total))
            sentences.append("The camera can develop only a .RAF it shot. An iPhone's ProRAW photos, for one, are DNG files.")
        }
        if unusable > 0 {
            let reason = "so the app can't tell which one to develop."
            if total == 1 {
                sentences.append("That photo holds two RAW files or two JPEG files, \(reason)")
            } else if unusable == total {
                sentences.append("Those photos each hold two RAW files or two JPEG files, \(reason)")
            } else {
                sentences.append("\(unusable) of the \(total) photos \(unusable == 1 ? "holds" : "hold") two RAW files or two JPEG files, \(reason)")
            }
        }
        if failed > 0 {
            if total == 1 {
                sentences.append("Couldn't copy that photo from your library. Try again.")
            } else if failed == total {
                sentences.append("Couldn't copy those photos from your library. Try again.")
            } else {
                sentences.append("\(failed) of the \(total) photos couldn't be copied from your library. Try picking \(failed == 1 ? "it" : "them") again.")
            }
        }
        let title: String
        if total == 1 {
            title = "Couldn't Use That Photo"
        } else if urls.isEmpty {
            title = "Couldn't Use Those Photos"
        } else {
            title = "Some Photos Weren't Added"
        }
        return Problem(title: title, message: sentences.joined(separator: " "), offersRAWPairs: withoutRAW > 0)
    }

    private func notRAFSentence(total: Int) -> String {
        if total == 1 {
            return "That photo's RAW isn't a Fujifilm .RAF file."
        } else if notRAF == total {
            return "None of those photos' RAWs is a Fujifilm .RAF file."
        } else if notRAF == 1 {
            return "1 of the \(total) photos has a RAW that isn't a Fujifilm .RAF file."
        }
        return "\(notRAF) of the \(total) photos have RAWs that aren't Fujifilm .RAF files."
    }
}

/// A picked photo's RAW file, copied out of the picker's hands. The file `received` points at is
/// the system's and lasts only as long as the import closure, so the copy is made there.
private struct ReceivedRAW: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .rawImage) { received in
            // A directory per copy keeps the original name without two picks colliding.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ReceivedRAW(url: destination)
        }
    }
}

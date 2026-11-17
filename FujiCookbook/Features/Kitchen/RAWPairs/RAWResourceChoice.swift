import UniformTypeIdentifiers

/// One file Photos keeps for a photo, as `PHAssetResource` describes it.
struct PhotoResource: Equatable {
    enum Role: Equatable {
        /// The photo's main file: the JPEG of a RAW+JPEG pair, the RAF of a RAW-only photo.
        case photo
        /// The second file of a pair: the RAF of a camera-imported RAW+JPEG.
        case alternatePhoto
        /// Edits, Live Photo video and the rest; never the RAF the camera wrote.
        case other
    }

    let role: Role
    let typeIdentifier: String
    /// The name the file had when Photos imported it, `DSCF0926.RAF`. Shown on screen only.
    let originalFileName: String
}

/// Which of a photo's files is the RAF to develop.
///
/// Only a Fujifilm RAW counts, as in the Kitchen's Browse Files: the camera develops only its own
/// format, so a ProRAW DNG or another maker's RAW alone is no RAW here. A camera-imported pair holds
/// the RAF as its alternate photo (iPhone 14 Pro, iOS 27.0.1, 2026-11-13: `photo public.jpeg` +
/// `alternatePhoto com.fuji.raw-image`), but the RAF may sit in either slot, so a pair is any photo
/// whose two originals are one RAF and one non-RAW image. Two RAWs or two non-RAW originals are an
/// error, never a guess at which file was meant.
enum RAWResourceChoice {
    enum Verdict: Equatable {
        /// One RAF and one non-RAW image, in either slot.
        case pair(raf: PhotoResource)
        /// The RAF is the photo's only original.
        case rawOnly(raf: PhotoResource)
        /// No Fujifilm RAW among the originals.
        case noRAW
        /// Two RAW originals, two non-RAW originals, or more than two: which file is the one to
        /// develop can't be told.
        case invalid
    }

    static func verdict(for resources: [PhotoResource]) -> Verdict {
        let originals = resources.filter { $0.role != .other }
        guard originals.count <= 2 else { return .invalid }
        let raws = originals.filter { isRAW($0.typeIdentifier) }
        let others = originals.filter { !isRAW($0.typeIdentifier) }
        if raws.count > 1 || others.count > 1 { return .invalid }
        guard let raw = raws.first, isFujifilmRAW(raw.typeIdentifier) else { return .noRAW }
        return others.isEmpty ? .rawOnly(raf: raw) : .pair(raf: raw)
    }

    static func isFujifilmRAW(_ typeIdentifier: String) -> Bool {
        guard let type = UTType(typeIdentifier) else { return false }
        return type.conforms(to: RAFPickerSection.fileContentTypes[0])
    }

    private static func isRAW(_ typeIdentifier: String) -> Bool {
        guard let type = UTType(typeIdentifier) else { return false }
        return type.conforms(to: .rawImage) || isFujifilmRAW(typeIdentifier)
    }
}

/// A photo the app can see that carries a RAF.
struct SharedRAWPhoto: Identifiable, Equatable {
    enum Kind: Equatable {
        case pair
        case rawOnly
    }

    /// The photo's local identifier in the user's library.
    let id: String
    let creationDate: Date?
    let kind: Kind
}

/// The photos the app can see, split into those with a RAF and counts of those without one.
struct SharedRAWPhotos: Equatable {
    var photos: [SharedRAWPhoto] = []
    /// Photos shared with the app that carry no RAF: a plain JPEG or HEIC, or another maker's RAW.
    var withoutRAW = 0
    /// Photos whose originals are two RAWs or two non-RAW images; see `RAWResourceChoice.Verdict`.
    var invalid = 0
}

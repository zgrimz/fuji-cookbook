import Foundation

/// What the key of a pasted recipe line names.
enum RecipeTextKey: Equatable {
    /// A setting `RecipeSettings` holds.
    case setting(RecipeField)
    /// Grain size on a line of its own, joined to the Grain line's strength.
    case grainSize
    /// White balance shifts on a line of their own, joined to the White Balance line's mode.
    case whiteBalanceShift
    case name
    case credit
    /// ISO or exposure compensation: kept in the notes as written, because recipes state them as
    /// ranges and conditions ("+1/3 to +1 (typically)") rather than as one value.
    case shootingNote
    /// A camera setting this version doesn't model, kept in `unsupportedFields`.
    case unmodelled(Unmodelled)

    /// Camera settings recipes list that `RecipeSettings` has no field for. The raw value is the
    /// `unsupportedFields` key.
    enum Unmodelled: String, CaseIterable {
        case smoothSkinEffect
        case longExposureNR
        case lensModulationOptimizer
        case colorSpace
    }

    /// The key a line's text names, matched without regard to case, spacing, punctuation or the
    /// British "colour"; nil for a key this parser doesn't know.
    init?(rawKey: String) {
        guard let key = Self.aliases[RecipeTextValue.compact(rawKey)] else { return nil }
        self = key
    }

    /// Whether reading the value can fail, which is what lets a key be recognised at the start of
    /// a line with no delimiter: a value that doesn't read sends the line on as text.
    var validatesValue: Bool {
        switch self {
        case .setting, .grainSize, .whiteBalanceShift: return true
        case .name, .credit, .shootingNote, .unmodelled: return false
        }
    }

    private static let aliases: [String: RecipeTextKey] = {
        let pairs = spellings.flatMap { spelling in
            spelling.names.map { (RecipeTextValue.compact($0), spelling.key) }
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }()

    /// The names a key goes by in pasted recipes.
    struct Spelling {
        let key: RecipeTextKey
        let names: [String]

        init(_ key: RecipeTextKey, _ names: [String]) {
            self.key = key
            self.names = names
        }
    }

    /// Every spelling seen for each key. Exposure bias is absent on purpose: it is a shooting note.
    static let spellings: [Spelling] = [
        Spelling(.setting(.filmSimulation), ["Film Simulation", "Film Sim", "Film", "Simulation", "Sim"]),
        Spelling(.setting(.monochromaticColor), ["Monochromatic Color", "Monochrome Color", "Mono Color"]),
        Spelling(.setting(.grain), ["Grain", "Grain Effect", "Grain Strength", "Grain Effect Strength"]),
        Spelling(.grainSize, ["Grain Size", "Grain Effect Size", "Grain Roughness", "Grain Effect Roughness"]),
        Spelling(.setting(.colorChromeEffect),
                 ["Color Chrome Effect", "Color Chrome", "Color Chrome FX", "CCE", "CC Effect"]),
        Spelling(.setting(.colorChromeFXBlue),
                 ["Color Chrome FX Blue", "Color Chrome Effect Blue", "Color Chrome Blue", "CC FX Blue", "CCFXB",
                  "CC Blue", "CCB"]),
        Spelling(.setting(.whiteBalance), ["White Balance", "WB", "White Bal"]),
        Spelling(.whiteBalanceShift,
                 ["White Balance Shift", "WB Shift", "WB Fine Tune", "White Balance Fine Tune", "WB Adjustment",
                  "Shift"]),
        Spelling(.setting(.dynamicRange), ["Dynamic Range", "DR"]),
        Spelling(.setting(.dRangePriority), ["D-Range Priority", "DR Priority", "DRP", "Dynamic Range Priority"]),
        Spelling(.setting(.highlightTone), ["Highlight", "Highlights", "Highlight Tone"]),
        Spelling(.setting(.shadowTone), ["Shadow", "Shadows", "Shadow Tone"]),
        Spelling(.setting(.color), ["Color", "Saturation", "Color Saturation"]),
        Spelling(.setting(.sharpness), ["Sharpness", "Sharp", "Sharpening"]),
        Spelling(.setting(.highISONR),
                 ["High ISO NR", "High ISO Noise Reduction", "Noise Reduction", "Noise Red.", "NR", "ISO NR"]),
        Spelling(.setting(.clarity), ["Clarity"]),
        Spelling(.shootingNote,
                 ["ISO", "Exposure Compensation", "Exposure Comp", "Exp Comp", "Exposure", "EC", "Exposure Bias",
                  "EV"]),
        Spelling(.name, ["Name", "Title", "Recipe", "Recipe Name"]),
        Spelling(.credit, ["Credit", "Author", "By", "Recipe By", "Created By", "Made By"]),
        Spelling(.unmodelled(.smoothSkinEffect), ["Smooth Skin Effect", "Smooth Skin"]),
        Spelling(.unmodelled(.longExposureNR), ["Long Exposure NR", "Long Exposure Noise Reduction"]),
        Spelling(.unmodelled(.lensModulationOptimizer), ["Lens Modulation Optimizer", "LMO"]),
        Spelling(.unmodelled(.colorSpace), ["Color Space"]),
    ]
}

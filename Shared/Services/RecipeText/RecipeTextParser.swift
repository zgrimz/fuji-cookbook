import Foundation

/// Why pasted text produced no recipe.
enum RecipeTextParseError: LocalizedError, Equatable {
    /// No line set a recipe setting. ISO, exposure compensation and settings this version doesn't
    /// model are recognised but don't count: on their own they aren't a recipe.
    case noRecipe
    case tooLong(limit: Int)
    /// A number the import's checks refuse (`RecipeImportValidation`), by its portable field name.
    case unsafeNumber(field: String)

    var errorDescription: String? {
        switch self {
        case .noRecipe:
            return "We couldn't detect a Fuji recipe in this text."
        case .tooLong(let limit):
            return "This text is too long to be a recipe. Paste at most \(limit.formatted()) characters."
        case .unsafeNumber(let field):
            return "The \(field) value in this text is too large to keep."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noRecipe:
            return "Paste a recipe with one setting per line, such as “Film Simulation: Classic Chrome”."
        case .tooLong:
            return "Copy only the recipe's settings, not the whole page."
        case .unsafeNumber:
            return "Correct the number and try again."
        }
    }
}

/// Reads one recipe out of plain text copied from a blog, a forum post or a message.
///
/// Each line holds settings (`Highlight: -1`, `- **WB:** Auto, +2 Red & -4 Blue`,
/// `Highlight: -1 | Shadow: +1`), a film simulation on its own (`Classic Negative`), or text. The
/// first line is the recipe's name when it is a single piece of text that is neither. Text the
/// parser can't place goes to the notes, and so does a setting whose value says more than the
/// parser read, so no setting text is lost; ISO and exposure compensation go there too. Notes keep
/// a line's words with list markers and Markdown emphasis removed; a line with no letter or digit
/// is dropped. Settings this version doesn't model, such as Smooth Skin Effect, go to
/// `unsupportedFields`.
///
/// The result holds what the text says, not what a camera accepts: camera ranges are applied when
/// a recipe is pushed, and the import's own checks (`RecipeImportValidation`) still run, as they do
/// for a file.
enum RecipeTextParser {
    static let defaultName = "Imported Recipe"
    /// Several times the longest recipe write-up, notes included, while keeping a whole pasted web
    /// page out of a synchronous parse.
    static let maxCharacters = 50_000

    static func parse(_ text: String) throws -> PortableRecipe {
        try checkLength(text)
        let lines = text.split(whereSeparator: \.isNewline)
            .map { RecipeTextLine.sanitized(String($0)) }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
        var draft = RecipeTextDraft()
        for (index, line) in lines.enumerated() {
            let segments = RecipeTextLine.segments(line)
            for segment in segments {
                draft.read(segment, isFirst: index == 0 && segments.count == 1)
            }
        }
        return try draft.recipe()
    }

    /// Throws ``RecipeTextParseError/tooLong(limit:)`` for text over ``maxCharacters``.
    static func checkLength(_ text: String) throws {
        guard text.count <= maxCharacters else {
            throw RecipeTextParseError.tooLong(limit: maxCharacters)
        }
    }
}

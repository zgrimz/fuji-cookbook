import Foundation

/// A line's key and value, either side of its delimiter.
struct RecipeTextEntry: Equatable {
    let key: String
    let value: String
}

/// A recognised key at the start of a line with no delimiter, and the rest of the line.
struct RecipeTextLeadingEntry: Equatable {
    let key: RecipeTextKey
    let value: String
}

/// Splitting one line of pasted text into a key and a value.
enum RecipeTextLine {
    /// The line with list markers, headings, block quotes and Markdown emphasis removed.
    static func sanitized(_ raw: String) -> String {
        var line = raw.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
        while let stripped = withoutLeadingMarker(line) {
            line = stripped
        }
        return line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// The settings on one line. A comma, `|` or `;` separates two only where a recognised key and
    /// its delimiter follow it ("Highlight: -1, Shadow: +1"), so the commas inside a value ("Auto,
    /// +2 Red & -4 Blue", "Weak, Small") stay put.
    static func segments(_ line: String) -> [String] {
        var segments: [String] = []
        var start = line.startIndex
        for index in line.indices where segmentSeparators.contains(line[index]) {
            let rest = line[line.index(after: index)...]
            guard let entry = split(String(rest)), RecipeTextKey(rawKey: entry.key) != nil else { continue }
            segments.append(String(line[start..<index]))
            start = rest.startIndex
        }
        segments.append(String(line[start...]))
        return segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The key and value either side of the line's delimiter, or nil when it has none.
    ///
    /// A colon or equals sign wins wherever it is. Otherwise a dash is the delimiter only where it
    /// can't be a sign or a hyphen: a hyphen-minus needs whitespace on both sides, and an en or em
    /// dash must not be directly followed by a digit (`Highlight –1` is a minus sign).
    static func split(_ line: String) -> RecipeTextEntry? {
        guard let delimiter = colonOrEquals(in: line) ?? dash(in: line) else { return nil }
        let key = line[..<delimiter.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return RecipeTextEntry(key: key,
                               value: line[delimiter.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    /// A key at the start of a line with no delimiter (`Highlight -1`, `Grain Effect Weak Small`)
    /// and the rest of the line. Only keys whose value is checked as it is read qualify, so a line
    /// of prose that happens to start with "Name" or "ISO" isn't taken for a setting.
    static func leadingEntry(_ line: String) -> RecipeTextLeadingEntry? {
        let words = line.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return nil }
        for length in stride(from: min(maxKeyWords, words.count - 1), through: 1, by: -1) {
            guard let key = RecipeTextKey(rawKey: words[..<length].joined(separator: " ")),
                  key.validatesValue else { continue }
            return RecipeTextLeadingEntry(key: key, value: words[length...].joined(separator: " "))
        }
        return nil
    }

    /// The most words any alias spans ("Color Chrome Effect Blue").
    private static let maxKeyWords = 4

    private static let segmentSeparators: Set<Character> = [",", "|", ";"]
    private static let bullets: Set<Character> = ["-", "*", "+", "•", "·", "‣", "▪", "◦", "–", "—"]
    private static let separatorDashes: Set<Character> = ["–", "—", "‒", "―"]

    private static func withoutLeadingMarker(_ line: String) -> String? {
        guard let first = line.first else { return nil }
        if first == "#" || first == ">" {
            return String(line.drop { $0 == "#" || $0 == ">" }).trimmingCharacters(in: .whitespaces)
        }
        if bullets.contains(first), line.dropFirst().first?.isWhitespace == true {
            return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        let rest = line.dropFirst(digits.count)
        if !digits.isEmpty, let marker = rest.first, marker == "." || marker == ")",
           rest.dropFirst().first?.isWhitespace == true {
            return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func colonOrEquals(in line: String) -> Range<String.Index>? {
        guard let index = line.firstIndex(where: { $0 == ":" || $0 == "=" || $0 == "：" }) else { return nil }
        return index..<line.index(after: index)
    }

    private static func dash(in line: String) -> Range<String.Index>? {
        var previous: Character?
        for index in line.indices {
            let character = line[index]
            let next = line.index(after: index) < line.endIndex ? line[line.index(after: index)] : nil
            defer { previous = character }
            let isSpacedHyphen = character == "-" && previous?.isWhitespace == true && next?.isWhitespace == true
            let isSeparatorDash = separatorDashes.contains(character) && next?.isNumber != true && next != "."
            if isSpacedHyphen || (isSeparatorDash && previous != nil) {
                return index..<line.index(after: index)
            }
        }
        return nil
    }
}

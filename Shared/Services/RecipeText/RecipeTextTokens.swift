import Foundation

/// One piece of a pasted value: a lowercased word, a number with its sign, or a number written in
/// a way the reader doesn't take (`- 1`, `1½`).
enum RecipeTextToken: Equatable {
    case word(String)
    case number(Double)
    /// Stands in for a number, so it is never read as a different one: a sign separated from its
    /// digits, or a digit with a vulgar fraction.
    case unreadable

    var asWord: String? {
        if case .word(let word) = self { return word }
        return nil
    }

    var asNumber: Double? {
        if case .number(let number) = self { return number }
        return nil
    }
}

/// A value read from text, and whether the text said anything beyond it.
struct RecipeTextReading<Value> {
    let value: Value
    /// False when the text carries more than the value (an alternative, a remark, another
    /// setting), so the caller keeps the whole line in the notes as well.
    let isComplete: Bool
}

/// Splitting a pasted value into tokens.
enum RecipeTextTokenizer {
    /// Words and signed numbers in reading order; other punctuation separates them.
    ///
    /// A dash of any kind, or a plus, directly before a digit is the number's sign; one followed by
    /// a space and then a digit is unreadable rather than dropped, so `- 1` never reads as +1.
    /// "5200K" is a number and a word, and "+2R" a number and a word. A decimal point needs a digit
    /// after it; a comma counts as one only before a single digit ("-0,5"), so "R+2,B-4" stays two
    /// numbers. "-1/2" is a fraction, -0.5.
    static func tokens(_ text: String) -> [RecipeTextToken] {
        let characters = Array(text.lowercased().replacingOccurrences(of: "colour", with: "color"))
        var tokens: [RecipeTextToken] = []
        var index = 0
        while index < characters.count {
            if characters[index].isLetter {
                let end = characters[index...].firstIndex { !$0.isLetter } ?? characters.count
                tokens.append(.word(String(characters[index..<end])))
                index = end
            } else if let number = number(in: characters, at: index) {
                tokens.append(number.token)
                index = number.end
            } else {
                if isDanglingSign(characters, at: index) || isOtherNumeral(characters[index]) {
                    tokens.append(.unreadable)
                }
                index += 1
            }
        }
        return tokens
    }

    private static func number(in characters: [Character], at start: Int) -> (token: RecipeTextToken, end: Int)? {
        var index = start
        var sign = 1.0
        if isSign(characters[index]) {
            guard index + 1 < characters.count, isDigit(characters[index + 1]) else { return nil }
            sign = isMinus(characters[index]) ? -1 : 1
            index += 1
        }
        guard isDigit(characters[index]) else { return nil }
        var digits = digitRun(in: characters, from: &index)
        if index + 1 < characters.count, isDecimalSeparator(characters, at: index) {
            index += 1
            digits += "." + digitRun(in: characters, from: &index)
        } else if index + 1 < characters.count, characters[index] == "/", isDigit(characters[index + 1]) {
            index += 1
            let denominator = Double(digitRun(in: characters, from: &index)) ?? 0
            guard denominator != 0, let numerator = Double(digits) else { return (.unreadable, index) }
            return (.number(sign * numerator / denominator), index)
        }
        if index < characters.count, isOtherNumeral(characters[index]) {
            return (.unreadable, index + 1)
        }
        guard let magnitude = Double(digits) else { return nil }
        return (.number(sign * magnitude), index)
    }

    private static func digitRun(in characters: [Character], from index: inout Int) -> String {
        var digits = ""
        while index < characters.count, isDigit(characters[index]) {
            digits.append(characters[index])
            index += 1
        }
        return digits
    }

    private static func isDecimalSeparator(_ characters: [Character], at index: Int) -> Bool {
        guard isDigit(characters[index + 1]) else { return false }
        if characters[index] == "." { return true }
        guard characters[index] == "," else { return false }
        return index + 2 >= characters.count || !isDigit(characters[index + 2])
    }

    /// A sign with whitespace and then a digit after it.
    private static func isDanglingSign(_ characters: [Character], at index: Int) -> Bool {
        guard isSign(characters[index]) else { return false }
        let rest = characters[(index + 1)...]
        guard rest.first?.isWhitespace == true else { return false }
        return rest.first { !$0.isWhitespace }.map(isDigit) ?? false
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// A numeral other than an ASCII digit, such as "½" or "²".
    private static func isOtherNumeral(_ character: Character) -> Bool {
        character.isNumber && !character.isASCII
    }

    private static func isSign(_ character: Character) -> Bool {
        isMinus(character) || character == "+" || character == "＋"
    }

    /// Hyphen-minus, the minus sign, the dashes and their small and full-width forms: pasted text
    /// writes negative values with any of them.
    private static func isMinus(_ character: Character) -> Bool {
        ["-", "−", "–", "—", "‒", "﹣", "－"].contains(character)
    }
}

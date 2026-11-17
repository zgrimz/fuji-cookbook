import Foundation

/// Reading a pasted White Balance value: a mode, a Kelvin value in Color Temperature mode, and the
/// Red and Blue shifts, all from one line ("Auto, +2 Red & -4 Blue", "5200K, R+1 B-3").
enum RecipeTextWhiteBalance {
    struct Shift: Equatable {
        var red: Int
        var blue: Int
    }

    /// The mode named first, with its Kelvin value and the shifts. Another mode named later
    /// ("Auto, +2 Red & -4 Blue (Daylight works too)") or a word that is neither a label nor filler
    /// makes the reading incomplete. Nil when no mode is named, or when a number is left over that
    /// isn't a shift, a Kelvin value or a fluorescent type: the line is then kept as text rather
    /// than read partly.
    static func whiteBalance(_ text: String) -> RecipeTextReading<WhiteBalance>? {
        var tokens = RecipeTextTokenizer.tokens(text)
        guard !tokens.contains(.unreadable), let mode = takeMode(from: &tokens),
              let shift = shift(in: tokens) else { return nil }
        let balance = WhiteBalance(mode: mode.mode, shiftRed: shift.red, shiftBlue: shift.blue, kelvin: mode.kelvin)
        return RecipeTextReading(value: balance, isComplete: mode.isOnlyMode && wordsAreRead(tokens))
    }

    /// Shifts alone, from a line such as "WB Shift: R+2 B-4". Nil when there are none to read.
    static func shiftLine(_ text: String) -> RecipeTextReading<Shift>? {
        let tokens = RecipeTextTokenizer.tokens(text)
        guard tokens.contains(where: { $0.asNumber != nil }), let shift = shift(in: tokens) else { return nil }
        return RecipeTextReading(value: shift, isComplete: wordsAreRead(tokens))
    }

    private static func shift(in tokens: [RecipeTextToken]) -> Shift? {
        guard let values = RecipeTextValue.labelledIntegers(in: tokens, labels: channelLabels) else { return nil }
        return Shift(red: values[.red] ?? 0, blue: values[.blue] ?? 0)
    }

    /// Whether every word left after the mode is a shift label or a word that says nothing more.
    private static func wordsAreRead(_ tokens: [RecipeTextToken]) -> Bool {
        tokens.compactMap(\.asWord).allSatisfy { channelLabels[$0] != nil || fillerWords.contains($0) }
    }

    private enum Channel { case red, blue }

    private static let channelLabels: [String: Channel] = ["red": .red, "r": .red, "blue": .blue, "b": .blue]
    private static let fillerWords: Set<String> = ["and", "wb", "white", "balance", "shift", "fine", "tune"]

    /// A Kelvin value has four or five digits and a shift one, which is what tells "6500 Kelvin,
    /// +2 Red" apart from "Kelvin, +2 Red".
    private static let smallestKelvin = 1000.0

    private struct ModeReading {
        var mode: WhiteBalanceMode
        var kelvin: Int?
        /// False when the text names another mode as well.
        var isOnlyMode: Bool
    }

    private struct ModeMatch {
        var range: Range<Int>
        var mode: WhiteBalanceMode
        var kelvin: Int?
    }

    /// The mode named first, with every mode mention removed from the tokens so none is read as a
    /// shift.
    private static func takeMode(from tokens: inout [RecipeTextToken]) -> ModeReading? {
        let matches = modeMatches(in: tokens)
        guard let first = matches.min(by: { ($0.range.lowerBound, -$0.range.count)
                                            < ($1.range.lowerBound, -$1.range.count) }) else { return nil }
        let mentioned = matches.reduce(into: IndexSet()) { $0.insert(integersIn: $1.range) }
        let isOnlyMode = matches.allSatisfy { $0.range.overlaps(first.range) }
        for index in mentioned.reversed() { tokens.remove(at: index) }
        return ModeReading(mode: first.mode, kelvin: first.kelvin, isOnlyMode: isOnlyMode)
    }

    /// Every place the tokens name a mode: the first occurrence of each phrase, every "5200K", and
    /// every fluorescent type.
    private static func modeMatches(in tokens: [RecipeTextToken]) -> [ModeMatch] {
        var matches: [ModeMatch] = []
        for (index, token) in tokens.enumerated() {
            if let value = token.asNumber, tokens.indices.contains(index + 1), tokens[index + 1] == .word("k"),
               let kelvin = Int(exactly: value) {
                matches.append(ModeMatch(range: index..<(index + 2), mode: .kelvin, kelvin: kelvin))
            }
            if token == .word("fluorescent"), let match = fluorescent(at: index, in: tokens) {
                matches.append(match)
            }
        }
        for (phrase, mode) in modePhrases {
            guard let range = range(of: phrase, in: tokens) else { continue }
            matches.append(mode == .kelvin ? kelvinPhrase(at: range, in: tokens) : ModeMatch(range: range, mode: mode))
        }
        return matches
    }

    /// "Fluorescent 2" or "Fluorescent Light 2". A bare "Fluorescent" names none of the three.
    private static func fluorescent(at start: Int, in tokens: [RecipeTextToken]) -> ModeMatch? {
        var end = start + 1
        if end < tokens.count, tokens[end] == .word("light") { end += 1 }
        let modes: [Double: WhiteBalanceMode] = [1: .fluorescent1, 2: .fluorescent2, 3: .fluorescent3]
        guard end < tokens.count, let number = tokens[end].asNumber, let mode = modes[number] else { return nil }
        return ModeMatch(range: start..<(end + 1), mode: mode)
    }

    /// "Kelvin" or "Color Temperature" with the Kelvin value before it ("6500 Kelvin") or after it
    /// ("Kelvin 6500"), when there is one.
    private static func kelvinPhrase(at range: Range<Int>, in tokens: [RecipeTextToken]) -> ModeMatch {
        for index in [range.lowerBound - 1, range.upperBound] where tokens.indices.contains(index) {
            guard let value = tokens[index].asNumber, value >= smallestKelvin,
                  let kelvin = Int(exactly: value) else { continue }
            return ModeMatch(range: min(index, range.lowerBound)..<max(index + 1, range.upperBound),
                             mode: .kelvin, kelvin: kelvin)
        }
        return ModeMatch(range: range, mode: .kelvin)
    }

    private static func range(of phrase: [String], in tokens: [RecipeTextToken]) -> Range<Int>? {
        let words = phrase.map(RecipeTextToken.word)
        guard tokens.count >= words.count else { return nil }
        return (0...(tokens.count - words.count))
            .first { Array(tokens[$0..<($0 + words.count)]) == words }
            .map { $0..<($0 + words.count) }
    }

    /// Where two phrases start at the same token, the longer one is the mode ("Auto White Priority"
    /// over "Auto").
    private static let modePhrases: [([String], WhiteBalanceMode)] = [
        (["auto", "white", "priority"], .autoWhitePriority),
        (["white", "priority"], .autoWhitePriority),
        (["auto", "ambience", "priority"], .autoAmbiencePriority),
        (["auto", "ambiance", "priority"], .autoAmbiencePriority),
        (["ambience", "priority"], .autoAmbiencePriority),
        (["ambiance", "priority"], .autoAmbiencePriority),
        (["daylight"], .daylight),
        (["sunny"], .daylight),
        (["shade"], .shade),
        (["incandescent"], .incandescent),
        (["tungsten"], .incandescent),
        (["underwater"], .underwater),
        (["color", "temperature"], .kelvin),
        (["color", "temp"], .kelvin),
        (["kelvin"], .kelvin),
        (["auto"], .auto),
        (["awb"], .auto),
    ]
}

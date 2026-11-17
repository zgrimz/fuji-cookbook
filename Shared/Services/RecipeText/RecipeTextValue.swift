import Foundation

/// Reading the value half of a pasted recipe line into the app's types. Each reader returns nil
/// when the value doesn't say what the setting needs, and the caller keeps the line as text. A
/// reading that leaves part of the value unread is marked incomplete, and the caller keeps the line
/// in the notes as well.
enum RecipeTextValue {
    /// Lowercased letters and digits only, with "colour" spelled "color": how keys and film
    /// simulation names are compared.
    static func compact(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "colour", with: "color")
            .filter { $0.isLetter || $0.isNumber }
    }

    /// The number a value starts with ("-1", "+1 (or +2)"), or nil when it starts with a word or
    /// an unreadable number.
    static func number(_ text: String) -> RecipeTextReading<Double>? {
        let tokens = RecipeTextTokenizer.tokens(text)
        guard let value = tokens.first?.asNumber else { return nil }
        return RecipeTextReading(value: value, isComplete: tokens.count == 1)
    }

    /// ``number(_:)`` when it is a whole number.
    static func integer(_ text: String) -> RecipeTextReading<Int>? {
        guard let reading = number(text), let value = Int(exactly: reading.value) else { return nil }
        return RecipeTextReading(value: value, isComplete: reading.isComplete)
    }

    /// The first word naming one of `Option`'s cases, by display name or raw value.
    static func option<Option: RecipeOption>(_ text: String, as type: Option.Type) -> RecipeTextReading<Option>? {
        let tokens = RecipeTextTokenizer.tokens(text)
        guard let match = firstOption(in: tokens, as: type) else { return nil }
        return RecipeTextReading(value: match, isComplete: tokens.count == 1)
    }

    /// Strength and, unless it is Off, size, in either order ("Weak, Small", "Strong/Large").
    static func grain(_ text: String) -> RecipeTextReading<GrainEffect>? {
        let tokens = RecipeTextTokenizer.tokens(text)
        guard let strength = firstOption(in: tokens, as: GrainStrength.self) else { return nil }
        let size = firstOption(in: tokens, as: GrainSize.self)
        let grain = GrainEffect(strength: strength, size: strength == .off ? nil : size)
        let wordsRead = grain.size == nil ? 1 : 2
        return RecipeTextReading(value: grain, isComplete: tokens.count == wordsRead && size == grain.size)
    }

    /// "DR400", "DR 400", "400%", "Auto" or "DR-Auto"; the first one named wins.
    static func dynamicRange(_ text: String) -> RecipeTextReading<DynamicRange>? {
        let tokens = RecipeTextTokenizer.tokens(text)
        for (index, token) in tokens.enumerated() {
            let range: DynamicRange
            switch token {
            case .word("auto"): range = .auto
            case .number(100): range = .dr100
            case .number(200): range = .dr200
            case .number(400): range = .dr400
            default: continue
            }
            let prefixed = index > 0 && tokens[index - 1] == .word("dr")
            return RecipeTextReading(value: range, isComplete: tokens.count == (prefixed ? 2 : 1))
        }
        return nil
    }

    /// A film simulation the whole text names, by raw value, display name or a common spelling
    /// ("Classic Negative", "Acros + R", "Reala").
    static func filmSimulation(named text: String) -> FilmSimulation? {
        let key = compact(text)
        return filmSimulationNames.first { $0.name == key }?.simulation
    }

    /// The film simulation a value starts with. More text after the name ("Classic Chrome (or
    /// Classic Neg.)") makes the reading incomplete; the longest name that starts the value wins.
    static func filmSimulation(_ text: String) -> RecipeTextReading<FilmSimulation>? {
        if let exact = filmSimulation(named: text) {
            return RecipeTextReading(value: exact, isComplete: true)
        }
        let key = compact(text)
        guard !key.isEmpty, let match = filmSimulationNames.first(where: { key.hasPrefix($0.name) }) else {
            return nil
        }
        return RecipeTextReading(value: match.simulation, isComplete: false)
    }

    /// Monochromatic Color's two axes: "WC +2 MG -1", "+2 WC", or a lone number for Warm–Cool.
    static func monochromaticColor(_ text: String) -> RecipeTextReading<MonochromaticColor>? {
        let tokens = RecipeTextTokenizer.tokens(text)
        let labels: [String: MonochromaticColor.Axis] = ["wc": .warmCool, "mg": .magentaGreen]
        let labelCount = tokens.filter { labels[$0.asWord ?? ""] != nil }.count
        guard labelCount > 0 else {
            let numbers = tokens.compactMap(\.asNumber)
            guard numbers.count == 1, let warmCool = Int(exactly: numbers[0]) else { return nil }
            return RecipeTextReading(value: MonochromaticColor(warmCool: warmCool, magentaGreen: nil),
                                     isComplete: tokens.count == 1)
        }
        guard let values = labelledIntegers(in: tokens, labels: labels), !values.isEmpty else { return nil }
        return RecipeTextReading(value: MonochromaticColor(warmCool: values[.warmCool],
                                                           magentaGreen: values[.magentaGreen]),
                                 isComplete: tokens.count == labelCount + values.count)
    }

    struct MonochromaticColor: Equatable {
        enum Axis { case warmCool, magentaGreen }
        var warmCool: Int?
        var magentaGreen: Int?
    }

    /// Numbers paired with the labels beside them, in whichever order the text uses: label first
    /// ("R+2 B-4") or number first ("+2 Red & -4 Blue"), decided by which comes first. Words that
    /// aren't labels are skipped; no labels and no numbers is an empty result. Nil when a number has
    /// no label, a label has no number, a label repeats, a number isn't whole or a number is
    /// unreadable: the caller then keeps the line as text rather than guess.
    static func labelledIntegers<Label: Hashable>(in tokens: [RecipeTextToken],
                                                  labels: [String: Label]) -> [Label: Int]? {
        guard !tokens.contains(.unreadable) else { return nil }
        let parts: [LabelledPart<Label>] = tokens.compactMap { token in
            if let value = token.asNumber { return .number(value) }
            return token.asWord.flatMap { labels[$0] }.map { .label($0) }
        }
        guard parts.count.isMultiple(of: 2), let first = parts.first else { return parts.isEmpty ? [:] : nil }
        let labelFirst: Bool
        if case .label = first { labelFirst = true } else { labelFirst = false }
        var result: [Label: Int] = [:]
        for start in stride(from: 0, to: parts.count, by: 2) {
            let (labelPart, numberPart) = labelFirst ? (parts[start], parts[start + 1])
                                                     : (parts[start + 1], parts[start])
            guard case .label(let label) = labelPart, case .number(let value) = numberPart,
                  result[label] == nil, let integer = Int(exactly: value) else { return nil }
            result[label] = integer
        }
        return result
    }

    private static func firstOption<Option: RecipeOption>(in tokens: [RecipeTextToken],
                                                          as type: Option.Type) -> Option? {
        for word in tokens.compactMap(\.asWord) {
            let match = Option.allCases.first { compact($0.displayName) == word || compact($0.rawValue) == word }
            if let match { return match }
        }
        return nil
    }

    /// Longest first, so a prefix match takes "Classic Negative" over "Classic Neg." and
    /// "ACROS + R" over "ACROS".
    private static let filmSimulationNames: [(name: String, simulation: FilmSimulation)] = {
        let own = FilmSimulation.allCases.flatMap { [(compact($0.rawValue), $0), (compact($0.displayName), $0)] }
        let common = filmSimulationSpellings.flatMap { simulation, names in names.map { (compact($0), simulation) } }
        return (own + common).sorted { $0.0.count > $1.0.count }.map { (name: $0.0, simulation: $0.1) }
    }()

    private static let filmSimulationSpellings: [(FilmSimulation, [String])] = [
        (.provia, ["Standard"]),
        (.velvia, ["Vivid"]),
        (.astia, ["Soft"]),
        (.proNegHi, ["PRO Negative Hi", "PRO Neg High", "PRO Negative High"]),
        (.proNegStd, ["PRO Negative Standard", "PRO Neg Standard", "PRO Negative Std"]),
        (.classicNeg, ["Classic Negative"]),
        (.nostalgicNeg, ["Nostalgic Negative"]),
        (.eterna, ["Cinema"]),
        (.eternaBleachBypass, ["Bleach Bypass"]),
        (.realaAce, ["Reala"]),
        (.acrosYe, ["ACROS Y", "ACROS Yellow", "ACROS Yellow Filter"]),
        (.acrosR, ["ACROS Red", "ACROS Red Filter"]),
        (.acrosG, ["ACROS Green", "ACROS Green Filter"]),
        (.monochromeYe, ["Monochrome Y", "Monochrome Yellow", "Monochrome Yellow Filter"]),
        (.monochromeR, ["Monochrome Red", "Monochrome Red Filter"]),
        (.monochromeG, ["Monochrome Green", "Monochrome Green Filter"]),
    ]
}

/// A token ``RecipeTextValue/labelledIntegers(in:labels:)`` pairs: a number, or a word that is one
/// of the caller's labels.
private enum LabelledPart<Label> {
    case number(Double)
    case label(Label)
}

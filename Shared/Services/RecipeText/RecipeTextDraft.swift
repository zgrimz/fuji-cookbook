import Foundation

/// The recipe being read from pasted text, one setting at a time.
///
/// The first value read for a setting is the one kept; a later line for the same setting goes to
/// the notes, so a recipe that lists alternatives keeps both readable. A line whose value says more
/// than the setting ("Color: +2 (+3 for portraits)") sets it and is kept in the notes as well.
struct RecipeTextDraft {
    private var settings = RecipeSettings()
    private var assigned: Set<RecipeField> = []
    private var name: String?
    private var credit: String?
    private var notes: [String] = []
    private var unsupported: [String: JSONValue] = [:]
    /// Values on lines of their own that join another line's setting once every line is read.
    private var grainSize: (size: GrainSize, line: String)?
    private var shift: (shift: RecipeTextWhiteBalance.Shift, line: String)?
    /// A film simulation named on a line of its own. A "Film Simulation:" line takes precedence.
    private var bareFilmSimulation: (simulation: FilmSimulation, line: String)?
    /// The line being read, which an incomplete reading keeps in the notes.
    private var currentLine = ""

    /// Reads one setting: a whole line, or one of several on a line (``RecipeTextLine/segments(_:)``).
    /// `isFirst` is true only for a lone setting on the first line, which may be the name.
    mutating func read(_ line: String, isFirst: Bool) {
        currentLine = line
        if let entry = RecipeTextLine.split(line) {
            guard let key = RecipeTextKey(rawKey: entry.key), apply(key, value: entry.value, line: line) else {
                notes.append(line)
                return
            }
            return
        }
        if let entry = RecipeTextLine.leadingEntry(line), apply(entry.key, value: entry.value, line: line) {
            return
        }
        if bareFilmSimulation == nil, let simulation = RecipeTextValue.filmSimulation(named: line) {
            bareFilmSimulation = (simulation, line)
        } else if isFirst {
            name = line
        } else {
            notes.append(line)
        }
    }

    /// The recipe, once every line is read. Throws ``RecipeTextParseError/noRecipe`` when no line
    /// set a recipe setting.
    func recipe() throws -> PortableRecipe {
        var draft = self
        draft.joinLoneValues()
        guard draft.settings != RecipeSettings() else { throw RecipeTextParseError.noRecipe }
        return PortableRecipe(name: draft.name ?? RecipeTextParser.defaultName,
                              credit: draft.credit,
                              notes: draft.notes.isEmpty ? nil : draft.notes.joined(separator: "\n"),
                              settings: draft.settings,
                              unsupportedFields: draft.unsupported.isEmpty ? nil : draft.unsupported)
    }

    /// Whether the line was placed; false sends it to the notes.
    private mutating func apply(_ key: RecipeTextKey, value: String, line: String) -> Bool {
        switch key {
        case .setting(let field):
            guard !assigned.contains(field), assign(field, from: value) else { return false }
            assigned.insert(field)
            return true
        case .grainSize:
            guard grainSize == nil, let reading = RecipeTextValue.option(value, as: GrainSize.self) else { return false }
            grainSize = (reading.value, line)
            keepIfIncomplete(reading)
            return true
        case .whiteBalanceShift:
            guard shift == nil, let reading = RecipeTextWhiteBalance.shiftLine(value) else { return false }
            shift = (reading.value, line)
            keepIfIncomplete(reading)
            return true
        case .name:
            guard name == nil, !value.isEmpty else { return false }
            name = value
            return true
        case .credit:
            guard credit == nil, !value.isEmpty else { return false }
            credit = value
            return true
        case .shootingNote:
            notes.append(line)
            return true
        case .unmodelled(let setting):
            guard unsupported[setting.rawValue] == nil, !value.isEmpty else { return false }
            unsupported[setting.rawValue] = .string(value)
            return true
        }
    }

    /// Whether `value` read as `field` and was stored.
    private mutating func assign(_ field: RecipeField, from value: String) -> Bool {
        switch field {
        case .filmSimulation:
            return store(RecipeTextValue.filmSimulation(value), at: \.filmSimulation)
        case .monochromaticColor:
            guard let reading = RecipeTextValue.monochromaticColor(value) else { return false }
            settings.monochromaticColorWC = reading.value.warmCool
            settings.monochromaticColorMG = reading.value.magentaGreen
            keepIfIncomplete(reading)
            return true
        case .grain:
            return store(RecipeTextValue.grain(value), at: \.grain)
        case .colorChromeEffect:
            return store(RecipeTextValue.option(value, as: EffectStrength.self), at: \.colorChromeEffect)
        case .colorChromeFXBlue:
            return store(RecipeTextValue.option(value, as: EffectStrength.self), at: \.colorChromeFXBlue)
        case .whiteBalance:
            return store(RecipeTextWhiteBalance.whiteBalance(value), at: \.whiteBalance)
        case .dynamicRange:
            return store(RecipeTextValue.dynamicRange(value), at: \.dynamicRange)
        case .dRangePriority:
            return store(RecipeTextValue.option(value, as: DRangePriority.self), at: \.dRangePriority)
        case .highlightTone:
            return store(RecipeTextValue.number(value), at: \.highlightTone)
        case .shadowTone:
            return store(RecipeTextValue.number(value), at: \.shadowTone)
        case .color:
            return store(RecipeTextValue.integer(value), at: \.color)
        case .sharpness:
            return store(RecipeTextValue.integer(value), at: \.sharpness)
        case .highISONR:
            return store(RecipeTextValue.integer(value), at: \.highISONR)
        case .clarity:
            return store(RecipeTextValue.integer(value), at: \.clarity)
        case .exposureBias, .noiseReduction:
            // No alias names these: exposure is a shooting note, and Noise Reduction is read as
            // High ISO NR.
            return false
        }
    }

    private mutating func store<Value>(_ reading: RecipeTextReading<Value>?,
                                       at keyPath: WritableKeyPath<RecipeSettings, Value?>) -> Bool {
        guard let reading else { return false }
        settings[keyPath: keyPath] = reading.value
        keepIfIncomplete(reading)
        return true
    }

    private mutating func keepIfIncomplete<Value>(_ reading: RecipeTextReading<Value>) {
        if !reading.isComplete { notes.append(currentLine) }
    }

    /// Joins the values that came on lines of their own, or keeps those lines as notes when there
    /// is nothing for them to join.
    private mutating func joinLoneValues() {
        if let bare = bareFilmSimulation {
            if settings.filmSimulation == nil { settings.filmSimulation = bare.simulation }
            else { notes.append(bare.line) }
        }
        if let grainSize {
            if let grain = settings.grain, grain.strength != .off, grain.size == nil {
                settings.grain?.size = grainSize.size
            } else {
                notes.append(grainSize.line)
            }
        }
        if let shift {
            if let balance = settings.whiteBalance, balance.shiftRed == 0, balance.shiftBlue == 0 {
                settings.whiteBalance?.shiftRed = shift.shift.red
                settings.whiteBalance?.shiftBlue = shift.shift.blue
            } else {
                notes.append(shift.line)
            }
        }
    }
}

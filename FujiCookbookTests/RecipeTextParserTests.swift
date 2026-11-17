import XCTest
@testable import FujiCookbook

final class RecipeTextParserTests: XCTestCase {

    // MARK: Community samples

    /// The shape Fuji X Weekly posts use: film simulation on its own line, then one setting per
    /// line, ending with shooting suggestions.
    func testFujiXWeeklyStyleList() throws {
        let recipe = try RecipeTextParser.parse("""
        Classic Negative
        Dynamic Range: DR400
        Highlight: -1
        Shadow: +1
        Color: +3
        Noise Reduction: -4
        Sharpening: -2
        Clarity: -2
        Grain Effect: Strong, Large
        Color Chrome Effect: Strong
        Color Chrome Effect Blue: Weak
        White Balance: Auto, +2 Red & -4 Blue
        ISO: Auto, up to ISO 6400
        Exposure Compensation: +1/3 to +1 (typically)
        """)

        XCTAssertEqual(recipe.name, RecipeTextParser.defaultName)
        let settings = recipe.settings
        XCTAssertEqual(settings.filmSimulation, .classicNeg)
        XCTAssertEqual(settings.dynamicRange, .dr400)
        XCTAssertEqual(settings.highlightTone, -1)
        XCTAssertEqual(settings.shadowTone, 1)
        XCTAssertEqual(settings.color, 3)
        XCTAssertEqual(settings.highISONR, -4)
        XCTAssertEqual(settings.sharpness, -2)
        XCTAssertEqual(settings.clarity, -2)
        XCTAssertEqual(settings.grain, GrainEffect(strength: .strong, size: .large))
        XCTAssertEqual(settings.colorChromeEffect, .strong)
        XCTAssertEqual(settings.colorChromeFXBlue, .weak)
        XCTAssertEqual(settings.whiteBalance, WhiteBalance(mode: .auto, shiftRed: 2, shiftBlue: -4, kelvin: nil))
        XCTAssertNil(settings.exposureBias)
        XCTAssertEqual(recipe.notes, """
        ISO: Auto, up to ISO 6400
        Exposure Compensation: +1/3 to +1 (typically)
        """)
        XCTAssertNil(recipe.unsupportedFields)
    }

    /// A Reddit-style post: a bold title, then a Markdown bullet list with bold keys.
    func testRedditStyleMarkdownBulletList() throws {
        let recipe = try RecipeTextParser.parse("""
        **Kodachrome Summer**

        - **Film Simulation:** Classic Chrome
        - **WB:** Daylight, R+3 B-5
        * **DR:** DR200
        * **Highlights:** +0.5
        * **Shadows:** -1.5
        • **Colour:** +2
        1. **Sharpness:** 0
        2) **NR:** -4
        - **Grain:** Weak, Small
        - **CCFXB:** Off
        """)

        XCTAssertEqual(recipe.name, "Kodachrome Summer")
        XCTAssertEqual(recipe.settings.filmSimulation, .classicChrome)
        XCTAssertEqual(recipe.settings.whiteBalance,
                       WhiteBalance(mode: .daylight, shiftRed: 3, shiftBlue: -5, kelvin: nil))
        XCTAssertEqual(recipe.settings.dynamicRange, .dr200)
        XCTAssertEqual(recipe.settings.highlightTone, 0.5)
        XCTAssertEqual(recipe.settings.shadowTone, -1.5)
        XCTAssertEqual(recipe.settings.color, 2)
        XCTAssertEqual(recipe.settings.sharpness, 0)
        XCTAssertEqual(recipe.settings.highISONR, -4)
        XCTAssertEqual(recipe.settings.grain, GrainEffect(strength: .weak, size: .small))
        XCTAssertEqual(recipe.settings.colorChromeFXBlue, .off)
        XCTAssertNil(recipe.notes)
    }

    func testOneLineGrain() throws {
        let recipe = try RecipeTextParser.parse("Grain: Weak, Small")
        XCTAssertEqual(recipe.settings.grain, GrainEffect(strength: .weak, size: .small))
        XCTAssertEqual(recipe.name, RecipeTextParser.defaultName)
    }

    func testGrainVariants() throws {
        XCTAssertEqual(try grain("Grain Effect: Strong/Large"), GrainEffect(strength: .strong, size: .large))
        XCTAssertEqual(try grain("Grain: Weak"), GrainEffect(strength: .weak, size: nil))
        XCTAssertEqual(try grain("Grain: Off, Small"), GrainEffect.off)
        XCTAssertEqual(try grain("Grain Effect: Weak\nGrain Size: Large"), GrainEffect(strength: .weak, size: .large))
    }

    // MARK: Title

    func testFirstLineWithoutDelimiterIsTheName() throws {
        let recipe = try RecipeTextParser.parse("""
        Pacific Blues
        Film Simulation: Classic Chrome
        """)
        XCTAssertEqual(recipe.name, "Pacific Blues")
        XCTAssertNil(recipe.notes)
    }

    func testFirstLineWithDelimiterIsNotTheName() throws {
        for delimiter in [":", "=", " - ", " – ", " — "] {
            let recipe = try RecipeTextParser.parse("Pacific Blues\(delimiter)Fuji X Weekly\nColor: +1")
            XCTAssertEqual(recipe.name, RecipeTextParser.defaultName, "delimiter \(delimiter)")
            XCTAssertEqual(recipe.notes, "Pacific Blues\(delimiter)Fuji X Weekly", "delimiter \(delimiter)")
        }
    }

    /// A hyphen inside a word is not a delimiter, so a hyphenated title stays a title.
    func testHyphenatedTitleIsTheName() throws {
        let recipe = try RecipeTextParser.parse("Kodachrome-ish\nColor: +1")
        XCTAssertEqual(recipe.name, "Kodachrome-ish")
    }

    func testFirstLineThatIsASettingIsNotTheName() throws {
        let recipe = try RecipeTextParser.parse("Highlight -1\nShadow +1")
        XCTAssertEqual(recipe.name, RecipeTextParser.defaultName)
        XCTAssertEqual(recipe.settings.highlightTone, -1)
        XCTAssertEqual(recipe.settings.shadowTone, 1)
    }

    func testExplicitNameAndCredit() throws {
        let recipe = try RecipeTextParser.parse("Name: Golden Hour\nRecipe by: Someone\nColor: 0")
        XCTAssertEqual(recipe.name, "Golden Hour")
        XCTAssertEqual(recipe.credit, "Someone")
    }

    // MARK: Keys

    func testHighISONRAliases() throws {
        for key in ["Noise Red.", "NR", "High ISO NR", "High-ISO Noise Reduction", "noise reduction"] {
            let recipe = try RecipeTextParser.parse("\(key): -2")
            XCTAssertEqual(recipe.settings.highISONR, -2, key)
        }
    }

    func testKeyAliasesAreCaseAndPunctuationInsensitive() throws {
        let recipe = try RecipeTextParser.parse("""
        FILM SIM = Reala Ace
        d-range priority: Auto
        colour chrome fx blue: Strong
        Monochromatic Colour: WC +2, MG -1
        """)
        XCTAssertEqual(recipe.settings.filmSimulation, .realaAce)
        XCTAssertEqual(recipe.settings.dRangePriority, .auto)
        XCTAssertEqual(recipe.settings.colorChromeFXBlue, .strong)
        XCTAssertEqual(recipe.settings.monochromaticColorWC, 2)
        XCTAssertEqual(recipe.settings.monochromaticColorMG, -1)
    }

    func testEveryAliasIsUnique() {
        let compacted = RecipeTextKey.spellings.flatMap { $0.names.map(RecipeTextValue.compact) }
        let repeated = Dictionary(grouping: compacted, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertEqual(Array(repeated), [])
    }

    func testFilmSimulationSpellings() {
        let cases: [(String, FilmSimulation)] = [
            ("Classic Neg.", .classicNeg), ("PRO Neg. Hi", .proNegHi), ("Pro Negative Standard", .proNegStd),
            ("ACROS + R", .acrosR), ("Acros+Ye Filter", .acrosYe), ("Monochrome", .monochrome),
            ("ETERNA Bleach Bypass", .eternaBleachBypass), ("Eterna", .eterna), ("Velvia/Vivid", .velvia),
            ("Nostalgic Negative", .nostalgicNeg), ("SEPIA", .sepia), ("PROVIA", .provia),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(RecipeTextValue.filmSimulation(named: text), expected, text)
        }
        let trailing = RecipeTextValue.filmSimulation("Classic Chrome (or Classic Neg.)")
        XCTAssertEqual(trailing?.value, .classicChrome)
        XCTAssertEqual(trailing?.isComplete, false)
        XCTAssertNil(RecipeTextValue.filmSimulation(named: "Classic Chrome (or Classic Neg.)"))
    }

    // MARK: White balance

    func testWhiteBalanceForms() throws {
        let cases: [(String, WhiteBalance)] = [
            ("Auto, +2 Red & -4 Blue", WhiteBalance(mode: .auto, shiftRed: 2, shiftBlue: -4, kelvin: nil)),
            ("5200K, +1 Red & -3 Blue", WhiteBalance(mode: .kelvin, shiftRed: 1, shiftBlue: -3, kelvin: 5200)),
            ("Kelvin 6500, R-1 B+2", WhiteBalance(mode: .kelvin, shiftRed: -1, shiftBlue: 2, kelvin: 6500)),
            ("Auto White Priority, -2 Red & +4 Blue",
             WhiteBalance(mode: .autoWhitePriority, shiftRed: -2, shiftBlue: 4, kelvin: nil)),
            ("Auto Ambience Priority",
             WhiteBalance(mode: .autoAmbiencePriority, shiftRed: 0, shiftBlue: 0, kelvin: nil)),
            ("Fluorescent 2, 0 Red & +1 Blue",
             WhiteBalance(mode: .fluorescent2, shiftRed: 0, shiftBlue: 1, kelvin: nil)),
            ("AWB (+2R, -4B)", WhiteBalance(mode: .auto, shiftRed: 2, shiftBlue: -4, kelvin: nil)),
            ("Shade", WhiteBalance(mode: .shade, shiftRed: 0, shiftBlue: 0, kelvin: nil)),
        ]
        for (value, expected) in cases {
            let recipe = try RecipeTextParser.parse("White Balance: \(value)")
            XCTAssertEqual(recipe.settings.whiteBalance, expected, value)
        }
    }

    func testWhiteBalanceShiftOnItsOwnLine() throws {
        let recipe = try RecipeTextParser.parse("WB: Daylight\nWB Shift: R+2 B-4")
        XCTAssertEqual(recipe.settings.whiteBalance,
                       WhiteBalance(mode: .daylight, shiftRed: 2, shiftBlue: -4, kelvin: nil))
        XCTAssertNil(recipe.notes)
    }

    func testWhiteBalanceWithUnlabelledNumberIsKeptAsText() throws {
        let recipe = try RecipeTextParser.parse("White Balance: Auto +2 -4\nColor: 0")
        XCTAssertNil(recipe.settings.whiteBalance)
        XCTAssertEqual(recipe.notes, "White Balance: Auto +2 -4")
    }

    // MARK: Unicode

    func testUnicodeDashesAsDelimitersAndSigns() throws {
        let recipe = try RecipeTextParser.parse("""
        Highlight – −1
        Shadow — +1
        Color –2
        Sharpness: −1
        Clarity: ‒3
        Grain Effect—Strong, Large
        White Balance – Auto, +1 Red & −2 Blue
        """)
        XCTAssertEqual(recipe.settings.highlightTone, -1)
        XCTAssertEqual(recipe.settings.shadowTone, 1)
        XCTAssertEqual(recipe.settings.color, -2)
        XCTAssertEqual(recipe.settings.sharpness, -1)
        XCTAssertEqual(recipe.settings.clarity, -3)
        XCTAssertEqual(recipe.settings.grain, GrainEffect(strength: .strong, size: .large))
        XCTAssertEqual(recipe.settings.whiteBalance, WhiteBalance(mode: .auto, shiftRed: 1, shiftBlue: -2, kelvin: nil))
        XCTAssertNil(recipe.notes)
    }

    func testWindowsLineEndingsAndNonBreakingSpaces() throws {
        let recipe = try RecipeTextParser.parse("Velvia Days\r\nFilm Simulation:\u{00A0}Velvia\r\nColor:\u{00A0}+4\r\n")
        XCTAssertEqual(recipe.name, "Velvia Days")
        XCTAssertEqual(recipe.settings.filmSimulation, .velvia)
        XCTAssertEqual(recipe.settings.color, 4)
    }

    // MARK: Notes and unsupported fields

    func testUnrecognisedLinesGoToNotesInOrder() throws {
        let recipe = try RecipeTextParser.parse("""
        Golden Hour
        This one is great for sunsets.
        Film Simulation: Kodak Gold
        Color: +1
        Camera: X-T5
        https://example.com/golden-hour
        Color: +2
        Highlight: plus one
        """)
        XCTAssertEqual(recipe.name, "Golden Hour")
        XCTAssertNil(recipe.settings.filmSimulation)
        XCTAssertEqual(recipe.settings.color, 1)
        XCTAssertNil(recipe.settings.highlightTone)
        XCTAssertEqual(recipe.notes, """
        This one is great for sunsets.
        Film Simulation: Kodak Gold
        Camera: X-T5
        https://example.com/golden-hour
        Color: +2
        Highlight: plus one
        """)
    }

    func testUnmodelledSettingsGoToUnsupportedFields() throws {
        let recipe = try RecipeTextParser.parse("""
        Film Simulation: ASTIA
        Smooth Skin Effect: Weak
        Long Exposure NR: Off
        Color Space: sRGB
        """)
        XCTAssertEqual(recipe.unsupportedFields, [
            "smoothSkinEffect": .string("Weak"),
            "longExposureNR": .string("Off"),
            "colorSpace": .string("sRGB"),
        ])
        XCTAssertNil(recipe.notes)
    }

    // MARK: Errors

    func testTextWithoutRecipeKeysThrowsFriendlyError() {
        let texts = [
            "Had a great time shooting downtown today!\nCheck out my gallery.",
            "ISO: 800\nExposure Compensation: +1/3",
            "Smooth Skin Effect: Off",
            "",
        ]
        for text in texts {
            XCTAssertThrowsError(try RecipeTextParser.parse(text), text) { error in
                XCTAssertEqual(error as? RecipeTextParseError, .noRecipe)
                XCTAssertEqual(error.localizedDescription, "We couldn't detect a Fuji recipe in this text.")
            }
        }
    }

    func testOverlongTextIsRefused() {
        let text = "Color: +1\n" + String(repeating: "x", count: RecipeTextParser.maxCharacters)
        XCTAssertThrowsError(try RecipeTextParser.parse(text)) { error in
            XCTAssertEqual(error as? RecipeTextParseError, .tooLong(limit: RecipeTextParser.maxCharacters))
        }
    }

    // MARK: Helpers

    private func grain(_ text: String) throws -> GrainEffect? {
        try RecipeTextParser.parse(text).settings.grain
    }

    // MARK: Text beyond the reading

    func testKelvinBeforeTheWordWithShifts() throws {
        let recipe = try RecipeTextParser.parse("White Balance: 6500 Kelvin, +2 Red & -4 Blue")
        XCTAssertEqual(recipe.settings.whiteBalance,
                       WhiteBalance(mode: .kelvin, shiftRed: 2, shiftBlue: -4, kelvin: 6500))
        XCTAssertNil(recipe.notes)
    }

    func testKelvinWithoutAValueDoesNotTakeAShift() throws {
        let recipe = try RecipeTextParser.parse("WB: Kelvin, +2 Red & -4 Blue")
        XCTAssertEqual(recipe.settings.whiteBalance,
                       WhiteBalance(mode: .kelvin, shiftRed: 2, shiftBlue: -4, kelvin: nil))
    }

    func testFirstWhiteBalanceModeNamedWins() throws {
        let cases: [(String, WhiteBalance)] = [
            ("Auto, +2 Red & -4 Blue (Daylight works too)",
             WhiteBalance(mode: .auto, shiftRed: 2, shiftBlue: -4, kelvin: nil)),
            ("Auto (or Shade in winter), +2R -4B", WhiteBalance(mode: .auto, shiftRed: 2, shiftBlue: -4, kelvin: nil)),
            ("Daylight (5200K), +1 Red & -2 Blue", WhiteBalance(mode: .daylight, shiftRed: 1, shiftBlue: -2, kelvin: nil)),
        ]
        for (value, expected) in cases {
            let line = "White Balance: \(value)"
            let recipe = try RecipeTextParser.parse(line)
            XCTAssertEqual(recipe.settings.whiteBalance, expected, value)
            XCTAssertEqual(recipe.notes, line, "the alternative is kept: \(value)")
        }
    }

    func testSeveralSettingsOnOneLine() throws {
        let recipe = try RecipeTextParser.parse("""
        Film Simulation: Classic Chrome | Highlight: -1 | Shadow: +1
        Color: +2, Sharpness: -1; Clarity: -2
        """)
        XCTAssertEqual(recipe.settings.filmSimulation, .classicChrome)
        XCTAssertEqual(recipe.settings.highlightTone, -1)
        XCTAssertEqual(recipe.settings.shadowTone, 1)
        XCTAssertEqual(recipe.settings.color, 2)
        XCTAssertEqual(recipe.settings.sharpness, -1)
        XCTAssertEqual(recipe.settings.clarity, -2)
        XCTAssertNil(recipe.notes)
        XCTAssertEqual(recipe.name, RecipeTextParser.defaultName)
    }

    func testCommaSeparatedSettingsSplitOnlyBeforeAKey() throws {
        let recipe = try RecipeTextParser.parse("Highlight: -1, Shadow: +1")
        XCTAssertEqual(recipe.settings.highlightTone, -1)
        XCTAssertEqual(recipe.settings.shadowTone, 1)
        XCTAssertNil(recipe.notes)
    }

    /// Whatever the parser doesn't read stays in the notes beside the value it did read.
    func testUnreadTextKeepsTheLineInNotes() throws {
        let cases: [(String, (RecipeSettings) -> Bool)] = [
            ("Highlight -1 Shadow +1", { $0.highlightTone == -1 }),
            ("Color Chrome Effect: Strong, Blue: Weak", { $0.colorChromeEffect == .strong }),
            ("Color: +2 (+3 for portraits)", { $0.color == 2 }),
            ("Film Simulation: Classic Chrome (or Classic Neg.)", { $0.filmSimulation == .classicChrome }),
            ("Dynamic Range: DR400 (DR200 in bright light)", { $0.dynamicRange == .dr400 }),
            ("Grain: Weak, Small (Strong for street)", { $0.grain == GrainEffect(strength: .weak, size: .small) }),
        ]
        for (line, check) in cases {
            let recipe = try RecipeTextParser.parse(line)
            XCTAssertTrue(check(recipe.settings), line)
            XCTAssertEqual(recipe.notes, line, line)
        }
    }

    func testNumbersWrittenInWaysTheReaderDoesNotTakeGoToNotes() throws {
        for line in ["Highlight: - 1", "Shadow: -1½", "Highlight: +2²"] {
            let recipe = try RecipeTextParser.parse("Color: 0\n\(line)")
            XCTAssertNil(recipe.settings.highlightTone, line)
            XCTAssertNil(recipe.settings.shadowTone, line)
            XCTAssertEqual(recipe.notes, line, line)
        }
    }

    func testFractionsRead() throws {
        let recipe = try RecipeTextParser.parse("Highlight: -1/2\nShadow: +3/2")
        XCTAssertEqual(recipe.settings.highlightTone, -0.5)
        XCTAssertEqual(recipe.settings.shadowTone, 1.5)
    }

    func testSettingsThatAlreadyReadStayPinned() throws {
        let recipe = try RecipeTextParser.parse("""
        Dynamic Range: DR-Auto
        D Range Priority: Weak
        Film Simulation: Acros+R
        Lens Modulation Optimizer: On
        """)
        XCTAssertEqual(recipe.settings.dynamicRange, .auto)
        XCTAssertEqual(recipe.settings.dRangePriority, .weak)
        XCTAssertEqual(recipe.settings.filmSimulation, .acrosR)
        XCTAssertEqual(recipe.unsupportedFields, ["lensModulationOptimizer": .string("On")])
        XCTAssertNil(recipe.notes)
    }
}

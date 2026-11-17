# Importing a recipe from text

**Library ▸ + ▸ Import from Text** reads one recipe out of plain text copied from a blog, a forum
post or a message. Paste it with the Paste button, or type it into the text box, and tap
**Review**. The recipe then goes through the same review and duplicate handling as a
[`.fujirecipe`](recipe-json-format.md) file (§7 there), after the same numeric checks. Nothing is
sent anywhere: the text is read on the device, with no AI involved.

The source of truth is `Shared/Services/RecipeText/`; `RecipeTextKey.swift` holds every key
spelling the reader accepts.

## What a line can be

Lines are read one at a time, after list markers (`-`, `*`, `•`, `1.`), headings, block quotes and
Markdown emphasis (`**bold**`) are removed. A line with no letter or digit, such as a Markdown rule
(`---`), is dropped.

- **A setting.** A key and a value either side of `:`, `=`, a spaced hyphen (` - `) or an en or em
  dash (`Highlight – -1`). A dash directly before a digit is a minus sign, never a delimiter. A
  setting's key can also lead a line with no delimiter (`Highlight -1`, `Grain Effect Weak Small`)
  when its value reads. One line can hold several settings separated by a comma, `|` or `;` where
  a key and its delimiter follow (`Highlight: -1, Shadow: +1`); the commas inside a value
  (`Auto, +2 Red & -4 Blue`) don't split it.
- **A film simulation on its own** (`Classic Negative`), as recipe blogs often list it. A
  `Film Simulation:` line takes precedence.
- **The name.** The first line, when it is a single piece of text that is neither of the above.
  Otherwise a `Name:` or `Title:` line sets it, and failing both the recipe is called "Imported
  Recipe".
- **Anything else** goes to the recipe's notes, with the markers above removed.

Keys are matched without regard to case, spacing, punctuation or the British "colour", and cover the
names in common use: `NR`, `Noise Red.` and `High ISO NR` all mean High ISO NR, `CCFXB` is Color
Chrome FX Blue, `DR` is Dynamic Range. `Credit:` or `Recipe by:` sets the credit.

## Values

| Setting | Accepted forms |
|---|---|
| Film simulation | Raw value or display name from [the JSON format](recipe-json-format.md#filmsimulation-allowed-values), and common spellings such as `Classic Negative`, `Acros + R`, `Reala`. The name may be followed by more text (`Classic Chrome (or Classic Neg.)`). |
| White balance | A mode (`Auto`, `Auto White Priority`, `Daylight`, `Fluorescent 2`, `5200K`, `6500 Kelvin`, …) and Red/Blue shifts in either order: `+2 Red & -4 Blue`, `R+2 B-4`, `+2R -4B`. The first mode named is the one read. Shifts can also come on their own line (`WB Shift: R+2 B-4`). |
| Grain | Strength (`Off`, `Weak`, `Strong`) and size (`Small`, `Large`) on one line: `Weak, Small`, `Strong/Large`. Size can also come on its own line (`Grain Size: Large`). |
| Dynamic range | `DR400`, `DR 400`, `400%`, `Auto`, `DR-Auto`. |
| Tones, color, sharpness, NR, clarity | The number the value starts with: `+1`, `-0.5`, `–2` (any dash or minus sign), `-0,5`, `-1/2`. A sign apart from its digits (`- 1`) or a fraction character (`-1½`) doesn't read. Color, sharpness, High ISO NR and clarity must be whole numbers. |
| Monochromatic Color | `WC +2 MG -1`, `+2 WC`, or one number for Warm–Cool. |

A value that doesn't read keeps its whole line in the notes, and so does a second line for a
setting already read. A value that says more than the setting (`Color: +2 (+3 for portraits)`,
`Auto, +2 Red & -4 Blue (Daylight works too)`) sets it and is kept in the notes as well, so the
rest isn't lost. A White Balance line with a number that is neither a shift, a Kelvin value nor a
fluorescent type is kept as text rather than read in part.

## Where the rest goes

- **ISO and exposure compensation** go to the notes as written, because recipes state them as
  ranges and conditions (`+1/3 to +1 (typically)`).
- **Camera settings the app doesn't model yet**, such as Smooth Skin Effect, Long Exposure NR, Lens
  Modulation Optimizer and Color Space, are kept in `unsupportedFields`
  ([§5](recipe-json-format.md#5-unsupportedfields-pass-through)), so they survive export.

## When nothing reads

Text with no recipe setting shows "We couldn't detect a Fuji recipe in this text." ISO, exposure
compensation and unmodelled settings on their own don't count as a recipe. Text over 50,000
characters is refused, and a pasted text that long doesn't replace what the text box holds. A number
too large to store is refused with the setting's name, as a file's is.

As with a file, values outside a camera's range are kept, for the compatibility warnings and
adjustments made when the recipe is used with a camera.

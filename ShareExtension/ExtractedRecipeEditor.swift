import SwiftUI

/// Inline correction for what the scan got wrong, covering every parameter a recipe has.
///
/// A field the screenshot didn't show reads "Not set" and stays unset until the user sets it, for
/// the ten fields that have no neutral value. A tone of 0 or a sharpness of 0 is a choice, not an
/// absence, and inventing it from a scan turns a six-field recipe into sixteen fields of zeros the
/// screenshot never contained; the develop path would then write them into the RAF conversion.
///
/// Six fields always carry a value: film simulation, dynamic range, grain, D-Range Priority and
/// the two Color Chrome effects default to PROVIA, Auto or Off. A recipe describes a look; left
/// out, these would inherit whatever the destination slot holds, so one recipe would produce two
/// looks on two cameras. They have no "Not set" here, show their default when the scan gave
/// nothing, and are settled to it when this editor appears, as `RecipeDraft.init(from:)` does in
/// the app, so the two screens mean the same thing.
struct ExtractedRecipeEditor: View {
    @Binding var recipe: PortableRecipe

    /// `RecipeDraft.init(from:)`'s coercion, for a screen that binds straight to the recipe and has
    /// no draft to do it in. Runs each time the form appears and fills only nil fields, so what is
    /// stored is what is shown.
    private func settleDefaults() {
        if recipe.settings.filmSimulation == nil { recipe.settings.filmSimulation = .provia }
        if recipe.settings.dynamicRange == nil { recipe.settings.dynamicRange = .auto }
        if recipe.settings.dRangePriority == nil { recipe.settings.dRangePriority = .off }
        if recipe.settings.grain == nil { recipe.settings.grain = .off }
        if recipe.settings.colorChromeEffect == nil { recipe.settings.colorChromeEffect = .off }
        if recipe.settings.colorChromeFXBlue == nil { recipe.settings.colorChromeFXBlue = .off }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group("Recipe") {
                textField("Name", text: $recipe.name)
                divider
                textField("Author", text: optional($recipe.credit))
                divider
                textField("Notes", text: optional($recipe.notes))
            }

            // The camera's IQ menu order, which `RecipeField`, the recipe screen and the app's editor
            // follow too.
            group("Film Simulation") {
                OptionRow(title: "Film Simulation", selection: binding(\.filmSimulation), settled: .provia)
            }

            if hasMonochromaticColor {
                group("Monochromatic Color") {
                    NumberRow(title: "Warm–Cool", value: intBinding(\.monochromaticColorWC),
                              range: DefaultRanges.range(for: .monochromaticColor), isInteger: true)
                    divider
                    NumberRow(title: "Magenta–Green", value: intBinding(\.monochromaticColorMG),
                              range: DefaultRanges.range(for: .monochromaticColor), isInteger: true)
                }
            }

            group("Effects") { effects }
            group("White Balance") { whiteBalance }

            // The main editor's interlock and wording. The rule and its hardware evidence are
            // `RecipeApplicability.priorityOverrides`.
            group("Dynamic Range") {
                OptionRow(title: "Dynamic Range", selection: binding(\.dynamicRange), settled: .auto)
                    .disabled(dRangePriorityIsOn)
                    .opacity(dRangePriorityIsOn ? 0.55 : 1)
                divider
                OptionRow(title: "D-Range Priority", selection: binding(\.dRangePriority), settled: .off)
                if dRangePriorityIsOn {
                    Text("The camera sets Dynamic Range while D-Range Priority is on — and Highlight Tone and Shadow Tone with it.")
                        .font(.caption)
                        .foregroundStyle(Theme.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }

            group("Tone & Detail") {
                // Dimmed under an active D-Range Priority, like Dynamic Range above: the camera
                // drives these two as well (see `RecipeApplicability.priorityOverrides`).
                NumberRow(title: "Highlight Tone", value: binding(\.highlightTone),
                          range: DefaultRanges.range(for: .highlightTone), isInteger: false)
                    .disabled(dRangePriorityIsOn)
                    .opacity(dRangePriorityIsOn ? 0.55 : 1)
                divider
                NumberRow(title: "Shadow Tone", value: binding(\.shadowTone),
                          range: DefaultRanges.range(for: .shadowTone), isInteger: false)
                    .disabled(dRangePriorityIsOn)
                    .opacity(dRangePriorityIsOn ? 0.55 : 1)
                divider
                NumberRow(title: "Color", value: intBinding(\.color),
                          range: DefaultRanges.range(for: .color), isInteger: true)
                divider
                NumberRow(title: "Sharpness", value: intBinding(\.sharpness),
                          range: DefaultRanges.range(for: .sharpness), isInteger: true)
                divider
                NumberRow(title: "High ISO NR", value: intBinding(\.highISONR),
                          range: DefaultRanges.range(for: .highISONR), isInteger: true)
                divider
                NumberRow(title: "Clarity", value: intBinding(\.clarity),
                          range: DefaultRanges.range(for: .clarity), isInteger: true)
                divider
                NumberRow(title: "Exposure Bias", value: binding(\.exposureBias),
                          range: NumericRange(min: -3, max: 3, step: 1.0 / 3.0), isInteger: false)
            }
        }
        .onAppear(perform: settleDefaults)
    }

    // MARK: Sections

    /// Whether the simulation exposes the toning axes at all — the monochrome family minus Sepia,
    /// whose toning is fixed and greyed on the camera (X-T50, 2026-09-20). Not `isMonochrome`:
    /// that includes Sepia, and would offer a control the app's own editor does not.
    private var hasMonochromaticColor: Bool { RecipeApplicability.hasMonochromaticColor(recipe.settings) }

    @ViewBuilder
    private var whiteBalance: some View {
        // The mode drives the whole struct: choosing one creates it, "Not set" removes it. The
        // shifts live inside `WhiteBalance` as non-optionals, so they only exist once it does.
        OptionRow(title: "Mode", selection: Binding(
            get: { recipe.settings.whiteBalance?.mode },
            set: { mode in
                guard let mode else { recipe.settings.whiteBalance = nil; return }
                var wb = recipe.settings.whiteBalance ?? .auto
                wb.mode = mode
                if !mode.usesKelvin { wb.kelvin = nil }
                recipe.settings.whiteBalance = wb
            }))
        if let wb = recipe.settings.whiteBalance {
            if wb.mode.usesKelvin {
                divider
                NumberRow(title: "Temperature",
                          value: Binding(get: { recipe.settings.whiteBalance?.kelvin.map(Double.init) },
                                         set: { recipe.settings.whiteBalance?.kelvin = $0.map { Int($0) } }),
                          range: CameraModelRegistry.kelvinRange, isInteger: true, suffix: " K", signed: false)
            }
            divider
            SliderRowAlways(title: "Shift Red–Cyan",
                            value: wbShift(\.shiftRed),
                            range: CameraModelRegistry.whiteBalanceShiftRange)
            divider
            SliderRowAlways(title: "Shift Blue–Amber",
                            value: wbShift(\.shiftBlue),
                            range: CameraModelRegistry.whiteBalanceShiftRange)
        }
    }

    @ViewBuilder
    private var effects: some View {
        OptionRow(title: "Grain Effect", selection: Binding(
            get: { recipe.settings.grain?.strength },
            set: { strength in
                guard let strength else { recipe.settings.grain = nil; return }
                var grain = recipe.settings.grain ?? .off
                grain.strength = strength
                if strength == .off { grain.size = nil }
                recipe.settings.grain = grain
            }), settled: .off)
        if let grain = recipe.settings.grain, grain.strength != .off {
            divider
            OptionRow(title: "Grain Size", selection: Binding(
                get: { recipe.settings.grain?.size },
                set: { recipe.settings.grain?.size = $0 }))
        }
        divider
        OptionRow(title: "Color Chrome Effect", selection: binding(\.colorChromeEffect), settled: .off)
        divider
        OptionRow(title: "Color Chrome FX Blue", selection: binding(\.colorChromeFXBlue), settled: .off)
    }

    // MARK: Bindings

    private func binding<T>(_ keyPath: WritableKeyPath<RecipeSettings, T?>) -> Binding<T?> {
        Binding(get: { recipe.settings[keyPath: keyPath] },
                set: { recipe.settings[keyPath: keyPath] = $0 })
    }

    /// `Int?` settings surfaced as `Double?` so one row type covers both.
    private func intBinding(_ keyPath: WritableKeyPath<RecipeSettings, Int?>) -> Binding<Double?> {
        Binding(get: { recipe.settings[keyPath: keyPath].map(Double.init) },
                set: { recipe.settings[keyPath: keyPath] = $0.map { Int($0.rounded()) } })
    }

    private func wbShift(_ keyPath: WritableKeyPath<WhiteBalance, Int>) -> Binding<Double> {
        Binding(get: { Double(recipe.settings.whiteBalance?[keyPath: keyPath] ?? 0) },
                set: { recipe.settings.whiteBalance?[keyPath: keyPath] = Int($0.rounded()) })
    }

    /// Text binding that treats an emptied field as absent, so clearing a credit removes it rather
    /// than storing "".
    private func optional(_ source: Binding<String?>) -> Binding<String> {
        Binding(get: { source.wrappedValue ?? "" },
                set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    // MARK: Chrome

    private var dRangePriorityIsOn: Bool { RecipeApplicability.priorityOverrides(recipe.settings, on: nil) }

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Theme.SectionLabel(title)
            VStack(spacing: 0) { content() }
                .padding(14)
                .themedCard(cornerRadius: 16)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 0.5)
    }

    private func textField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
                .frame(width: 64, alignment: .leading)
            TextField(label, text: text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
        }
        .padding(.vertical, 8)
    }

}

// MARK: - Rows

/// One optional enum parameter, chosen from a menu that offers "Not set" unless `settled` is set.
private struct OptionRow<T: RecipeOption>: View where T.AllCases: RandomAccessCollection {
    let title: String
    @Binding var selection: T?
    /// The value this field carries when the recipe says nothing. Non-nil means the field is one of
    /// the six that always has a value: "Not set" is not offered, and a nil selection is shown as
    /// this — matching what the push will write and what the app's editor shows for the same field.
    var settled: T? = nil

    private var shown: T? { selection ?? settled }

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
            Spacer(minLength: 12)
            Menu {
                ForEach(Array(T.allCases), id: \.self) { option in
                    Button(option.displayName) { selection = option }
                }
                if settled == nil {
                    Divider()
                    Button("Not set", role: .destructive) { selection = nil }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(shown?.displayName ?? "Not set")
                        .font(.subheadline.weight(shown == nil ? .regular : .medium))
                        .foregroundStyle(shown == nil ? Theme.ink3 : Theme.accent)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Theme.ink3)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// One optional numeric parameter. Absent until it's set, and clearable back to absent.
private struct NumberRow: View {
    let title: String
    @Binding var value: Double?
    let range: NumericRange
    let isInteger: Bool
    var suffix: String = ""
    var signed: Bool = true

    var body: some View {
        if let current = value {
            VStack(spacing: 8) {
                HStack {
                    Text(title).font(.subheadline).foregroundStyle(Theme.ink2)
                    Spacer(minLength: 12)
                    Text(format(current))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                    Button {
                        value = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.ink3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear \(title)")
                }
                Slider(value: Binding(get: { current }, set: { value = $0 }),
                       in: range.min...range.max,
                       step: range.step == 0 ? 1 : range.step)
            }
            .padding(.vertical, 6)
        } else {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.ink2)
                Spacer()
                Text("Not set").font(.subheadline).foregroundStyle(Theme.ink3)
                Button("Set") { value = defaultValue }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.leading, 8)
            }
            .padding(.vertical, 8)
        }
    }

    /// Zero where the range straddles it, otherwise the bottom of the range — so "Set" on a Kelvin
    /// row doesn't land on a temperature no camera offers.
    private var defaultValue: Double {
        (range.min...range.max).contains(0) ? 0 : range.min
    }

    private func format(_ value: Double) -> String {
        let text: String
        if isInteger {
            text = signed ? RecipeSettingsFormatter.signed(Int(value)) : "\(Int(value))"
        } else {
            text = signed ? RecipeSettingsFormatter.tone(value) : String(format: "%.1f", value)
        }
        return text + suffix
    }
}

/// A slider for a value that is always present because the struct holding it is — the white-balance
/// shifts, which exist exactly when a white balance does.
private struct SliderRowAlways: View {
    let title: String
    @Binding var value: Double
    let range: NumericRange

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.ink2)
                Spacer(minLength: 12)
                Text(RecipeSettingsFormatter.signed(Int(value)))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
            }
            Slider(value: $value, in: range.min...range.max, step: range.step == 0 ? 1 : range.step)
        }
        .padding(.vertical, 6)
    }
}

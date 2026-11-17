import SwiftUI
import SwiftData

/// Create or edit a recipe. The form only shows fields valid for the selected camera, or the full
/// superset in "Generic" mode, and says which fields a given camera will ignore.
///
/// All form fields live in a `RecipeDraft`, so nothing is written to the model until Save. The
/// editor holds the staged photos; `RecipePhotoSection` owns the photo picker.
struct RecipeEditorView: View {
    @Bindable var recipe: Recipe
    let isNew: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var draft: RecipeDraft
    @State private var photos: StagedPhotos
    @State private var showingDiscardConfirm = false
    /// What the field just refused, or nil. Held in state rather than recomputed in `body` so it
    /// reads as a response to the keystroke that caused it and clears on the next clean edit.
    @State private var slotNameRejection: String?
    /// The corrected text this view last wrote back into the field.
    ///
    /// Writing to the binding inside `onChange` re-enters `onChange` with the corrected value, which
    /// is by definition clean — so without this, the pass that fixes the text is immediately
    /// followed by one that erases the message explaining why it changed, and the field silently
    /// stops at `CameraSlotName.maxLength` characters with nothing said.
    @State private var lastCorrection: String?

    init(recipe: Recipe, isNew: Bool) {
        self._recipe = Bindable(wrappedValue: recipe)
        self.isNew = isNew
        _draft = State(initialValue: RecipeDraft(from: recipe))
        _photos = State(initialValue: StagedPhotos(PhotoDraft.drafts(for: recipe)))
    }

    private var fields: Set<RecipeField> { draft.fields }

    /// Whether closing the editor now would lose an edit.
    private var hasChanges: Bool { draft.hasChanges || photos.hasChanges }

    var body: some View {
        Form {
            metadataSection
            modelSection
            // The camera's IQ menu order, which `RecipeField` and the recipe screen follow too.
            filmSection
            effectsSection
            if fields.contains(.whiteBalance) { whiteBalanceSection }
            if fields.contains(.dynamicRange) || fields.contains(.dRangePriority) { dynamicRangeSection }
            toneSection
            RecipePhotoSection(photoDrafts: $photos.drafts)
            notesSection
            cameraNameSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(isNew ? "New Recipe" : "Edit Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { cancel() }
                    .confirmationDialog("Discard Changes?", isPresented: $showingDiscardConfirm,
                                        titleVisibility: .visible) {
                        Button("Discard", role: .destructive) { discard() }
                        Button("Keep Editing", role: .cancel) {}
                    }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!draft.canSave)
            }
        }
        // A new recipe is in the store before the editor opens and only Cancel deletes it, so a
        // swipe would leave it behind in the library. An existing recipe swipes away until it
        // holds an edit; from then on, Cancel is the way out and it asks first.
        .interactiveDismissDisabled(isNew || hasChanges)
    }

    // MARK: Sections

    private var metadataSection: some View {
        Section {
            TextField("Recipe Name", text: $draft.name)
            TextField("Author (optional)", text: $draft.credit)
                .textInputAutocapitalization(.words)
            Toggle(isOn: $draft.isFavorite) { Label("Favorite", systemImage: "star") }
        } footer: {
            Text("Who the recipe is by — a photographer, a blog, a YouTube channel. Shown on the recipe, on share cards, and in exported files. Leave blank for your own recipes.")
        }
    }

    /// The name the camera itself will show for this recipe.
    ///
    /// The field is bound to the *override* and is empty when the name is automatic, which puts the
    /// generated name in `prompt:` — SwiftUI draws a prompt in placeholder grey, so "this is a
    /// default" and "this is mine" are the field's two natural states rather than a colour someone
    /// has to maintain. Clearing the field goes back to automatic.
    private var cameraNameSection: some View {
        Section {
            TextField("Camera Slot Name",
                      text: $draft.cameraName,
                      prompt: Text(draft.generatedSlotName))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                // Keeps most illegal characters off the keyboard to begin with, and sidesteps input
                // methods entirely: an ASCII keyboard does no CJK composition, and filtering marked
                // text mid-composition is exactly what breaks one.
                .keyboardType(.asciiCapable)
                .onChange(of: draft.cameraName) { _, typed in
                    let filtered = CameraSlotName.filterForEntry(typed)
                    // Only touch the binding when the text actually differs. Reassigning on every
                    // keystroke re-enters this and throws the caret to the end of the field.
                    guard filtered != typed else {
                        // Leave the message up when this is our own correction echoing back; clear
                        // it only once the user has typed something that needed no fixing.
                        if typed != lastCorrection { slotNameRejection = nil }
                        lastCorrection = nil
                        return
                    }
                    slotNameRejection = CameraSlotName.firstDisallowed(in: typed)
                        .map { "“\($0)” isn't a character the camera can store." }
                        ?? "A camera slot name can be at most \(CameraSlotName.maxLength) characters."
                    lastCorrection = filtered
                    draft.cameraName = filtered
                }

            if !draft.cameraName.isEmpty {
                // A prompt can't be edited into, so tweaking a long default would otherwise mean
                // retyping all of it. This is the way back to automatic.
                Button("Use the default name") {
                    draft.cameraName = ""
                    slotNameRejection = nil
                    lastCorrection = nil
                }
            } else {
                // ...and the way to start from the default instead of a blank field.
                Button("Customize") {
                    draft.cameraName = CameraSlotName.filterForEntry(draft.generatedSlotName)
                    slotNameRejection = nil
                    lastCorrection = nil
                }
            }
        } header: {
            Text("Camera")
        } footer: {
            if let slotNameRejection {
                Text(slotNameRejection).foregroundStyle(Theme.warning)
            } else {
                Text("The name your camera shows for this slot. Leave it blank to use “\(draft.generatedSlotName)”, taken from the recipe name. Cameras store up to \(CameraSlotName.maxLength) characters, letters, numbers and punctuation only.")
            }
        }
    }

    private var modelSection: some View {
        Section {
            Picker("Camera Model", selection: $draft.modelID) {
                Text("Generic (all fields)").tag(String?.none)
                ForEach(CameraModelRegistry.shared.models.filter { $0.id != CameraModelRegistry.demoModelID }) { m in
                    Text(m.displayName).tag(String?.some(m.id))
                }
            }
        } header: {
            Text("Camera Profile")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.model.map { "Showing only fields supported by \($0.displayName)." }
                     ?? "Showing every parameter. Pick a model to show only the fields that body supports.")
                // What Save does to the values this profile hides or clamps, said before the Save:
                // the hidden rows cannot say it themselves.
                if let model = draft.model, !profileChanges.isEmpty {
                    Text("Saving with \(model.displayName) changes this recipe: "
                         + profileChanges.map(\.sentence).joined(separator: "; ") + ".")
                        .foregroundStyle(Theme.warning)
                }
            }
        }
    }

    private var profileChanges: [RecipeDraft.ProfileChange] { draft.changesOnSave() }

    /// A picklist rather than a horizontal swatch scroller: twenty simulations don't fit in one
    /// swipe lane, and every other enum on this form is a `Picker` row.
    private var filmSection: some View {
        Section {
            Picker("Film Simulation", selection: $draft.filmSim) {
                // No "Not set" row: a recipe always carries a film simulation, and
                // `RecipeDraft.init(from:)` supplies the default, so this picker always has a selection.
                ForEach(filmChoices, id: \.self) { sim in
                    filmRow(sim).tag(FilmSimulation?.some(sim))
                }
            }
            .pickerStyle(.navigationLink)

            if draft.showMonochromaticColor && fields.contains(.monochromaticColor) {
                OptionalIntSliderRow(title: "Monochromatic Color (WC)", value: $draft.monoWC, range: draft.range(.monochromaticColor))
                if draft.showMG {
                    OptionalIntSliderRow(title: "Monochromatic Color (MG)", value: $draft.monoMG, range: draft.range(.monochromaticColor))
                }
            }
        } header: {
            Text("Film Simulation")
        } footer: {
            // The editor's echo of what `RecipeCompatibility.analyze` will say at push time, worded
            // the same way so the two screens don't tell different stories.
            if let sim = draft.filmSim, let model = draft.model, !model.supports(filmSimulation: sim) {
                Text("“\(sim.displayName)” doesn't exist on \(model.displayName). The camera will keep its current film simulation for this slot.")
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    /// The camera's list, plus the recipe's own simulation when this body doesn't have it. A
    /// selection that disappears as you change camera model reads as a bug. The push keeps the
    /// bank's own simulation (`FujiPresetCodec.encode`), and the develop drops it
    /// (`RecipeCompatibility.clamped`).
    private var filmChoices: [FilmSimulation] {
        var list = draft.filmOptions
        if let sim = draft.filmSim, !list.contains(sim) { list.append(sim) }
        return list
    }

    /// Dimmed rather than hidden, for the same reason the Kitchen's canvas chips are: an option
    /// that vanishes when you change a setting above it reads as a bug. Swatch and name only:
    /// `.navigationLink` reuses this row as the collapsed row's trailing value, where anything
    /// extra wraps the name onto two lines.
    private func filmRow(_ sim: FilmSimulation) -> some View {
        HStack(spacing: 8) {
            FilmSwatch(simulation: sim, size: 12)
            Text(sim.displayName)
        }
        .opacity(draft.filmOptions.contains(sim) ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    /// The camera's own interlock, not the app's: with D-Range Priority on, the body drives Dynamic
    /// Range and refuses every write to it. Disabled rather than hidden, and the value is kept
    /// rather than cleared — turn D-Range Priority back off and the dynamic range you chose is
    /// still there. Same reasoning as the dimmed film-simulation rows: a control that vanishes when
    /// you change the setting above it reads as a bug, and the footer says why.
    ///
    /// The rule, including why a body without D-Range Priority never greys these rows, is
    /// `RecipeApplicability.priorityOverrides`.
    private var dRangePriorityIsOn: Bool {
        RecipeApplicability.priorityOverrides(draft.dRangePriority, on: draft.model)
    }

    private var dynamicRangeSection: some View {
        Section {
            if fields.contains(.dynamicRange) {
                settledPicker("Dynamic Range", $draft.dynamicRange)
                    .disabled(dRangePriorityIsOn)
                    .opacity(dRangePriorityIsOn ? 0.55 : 1)
            }
            if fields.contains(.dRangePriority) {
                settledPicker("D-Range Priority", $draft.dRangePriority)
            }
        } header: {
            Text("Dynamic Range")
        } footer: {
            // Worded after the notice `RecipeCompatibility.analyze` gives at push time, for the same
            // reason the film-simulation footer is: two screens, one story.
            if dRangePriorityIsOn && fields.contains(.dynamicRange) {
                Text("The camera sets Dynamic Range while D-Range Priority is on — and Highlight Tone and Shadow Tone with it.")
            }
        }
    }

    /// A picker over a parameter the recipe always carries a value for, so there is no "Not set"
    /// row. The binding stays optional because `RecipeSettings` models absence;
    /// `RecipeDraft.init(from:)` supplies the default.
    private func settledPicker<T: RecipeOption>(_ title: String, _ selection: Binding<T?>) -> some View
    where T.AllCases: RandomAccessCollection {
        Picker(title, selection: selection) {
            ForEach(Array(T.allCases), id: \.self) { Text($0.displayName).tag(T?.some($0)) }
        }
    }

    /// A picker over a parameter the recipe may leave unset, with "Not set" as a real choice.
    /// Binding straight to the optional makes "not set" a value the user picks rather than one the
    /// form invents.
    private func optionalPicker<T: RecipeOption>(_ title: String, _ selection: Binding<T?>) -> some View
    where T.AllCases: RandomAccessCollection {
        Picker(title, selection: selection) {
            Text("Not set").tag(T?.none)
            ForEach(Array(T.allCases), id: \.self) { Text($0.displayName).tag(T?.some($0)) }
        }
    }

    private var toneSection: some View {
        Section {
            // D-Range Priority is a highlight-and-shadow curve, so the camera drives these two as
            // well as Dynamic Range and refuses every write to them. Dimmed and kept, not cleared,
            // for the same reason as the Dynamic Range row: turn the priority back off and the
            // values you chose are still here. The other four rows are unaffected — measured, not
            // assumed (X-T50 fw 1.32, 2026-09-18).
            if fields.contains(.highlightTone) {
                OptionalDoubleSliderRow(title: "Highlight Tone", value: $draft.highlightTone, range: draft.range(.highlightTone))
                    .disabled(dRangePriorityIsOn)
                    .opacity(dRangePriorityIsOn ? 0.55 : 1)
            }
            if fields.contains(.shadowTone) {
                OptionalDoubleSliderRow(title: "Shadow Tone", value: $draft.shadowTone, range: draft.range(.shadowTone))
                    .disabled(dRangePriorityIsOn)
                    .opacity(dRangePriorityIsOn ? 0.55 : 1)
            }
            if fields.contains(.color) && !draft.isMono {
                OptionalIntSliderRow(title: "Color", value: $draft.color, range: draft.range(.color))
            }
            if fields.contains(.sharpness) {
                OptionalIntSliderRow(title: "Sharpness", value: $draft.sharpness, range: draft.range(.sharpness))
            }
            if fields.contains(.highISONR) {
                OptionalIntSliderRow(title: "High ISO NR", value: $draft.highISONR, range: draft.range(.highISONR))
            }
            if fields.contains(.clarity) {
                OptionalIntSliderRow(title: "Clarity", value: $draft.clarity, range: draft.range(.clarity))
            }
        } header: {
            Text("Tone & Detail")
        } footer: {
            if dRangePriorityIsOn && (fields.contains(.highlightTone) || fields.contains(.shadowTone)) {
                Text("The camera sets Highlight Tone and Shadow Tone while D-Range Priority is on.")
            }
        }
    }

    /// The mode drives the whole struct, as it does in the extension's editor: choosing one creates
    /// the `WhiteBalance`, "Not set" removes it. The temperature and the shifts live *inside* that
    /// struct as non-optionals, so they only have somewhere to be once it exists.
    private var whiteBalanceSection: some View {
        Section {
            optionalPicker("Mode", $draft.wbMode)
            if let mode = draft.wbMode {
                if mode.usesKelvin {
                    Stepper(value: $draft.kelvin, in: Int(CameraModelRegistry.kelvinRange.min)...Int(CameraModelRegistry.kelvinRange.max), step: 100) {
                        LabeledContent("Temperature", value: "\(draft.kelvin) K")
                    }
                }
                IntSliderRow(title: "Shift Red–Cyan", value: $draft.wbShiftR, range: CameraModelRegistry.whiteBalanceShiftRange)
                IntSliderRow(title: "Shift Blue–Amber", value: $draft.wbShiftB, range: CameraModelRegistry.whiteBalanceShiftRange)
            }
        } header: {
            Text("White Balance")
        } footer: {
            // The editor's echo of what `RecipeCompatibility.analyze` says at push time, in the
            // push's own words, as the film simulation footer does.
            if let mode = draft.unsupportedWhiteBalanceMode, let model = draft.model {
                Text(RecipeCompatibility.whiteBalanceModeMessage(mode, on: model))
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    private var effectsSection: some View {
        Section {
            if fields.contains(.grain) {
                settledPicker("Grain Effect", $draft.grainStrength)
                // Size is a property of a grain that exists; Off leaves it nowhere to live.
                if let strength = draft.grainStrength, strength != .off {
                    Picker("Grain Size", selection: $draft.grainSize) {
                        ForEach(GrainSize.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
            }
            if fields.contains(.colorChromeEffect) {
                settledPicker("Color Chrome Effect", $draft.colorChrome)
            }
            if fields.contains(.colorChromeFXBlue) {
                settledPicker("Color Chrome FX Blue", $draft.colorChromeFXBlue)
            }
        } header: {
            Text("Effects")
        }
    }

    private var notesSection: some View {
        Section {
            TextField("Tags (comma separated)", text: $draft.tagsText)
                .textInputAutocapitalization(.never)
            TextField("Notes", text: $draft.notes, axis: .vertical)
                .lineLimit(2...6)
        } header: {
            Text("Notes & Tags")
        } footer: {
            Text("e.g. “good for overcast”, a source URL, or tags like portrait, daylight.")
        }
    }

    // MARK: Save / cancel

    private func save() {
        draft.apply(to: recipe)
        PhotoDraft.commit(photos.drafts, to: recipe, in: modelContext)
        recipe.touch()
        dismiss()
    }

    private func cancel() {
        if hasChanges { showingDiscardConfirm = true } else { discard() }
    }

    private func discard() {
        if isNew { modelContext.delete(recipe) }
        dismiss()
    }
}

private extension RecipeDraft.ProfileChange {
    /// "Clarity +2 is dropped", "Highlight Tone +1.5 becomes +2" — words rather than an arrow, so
    /// VoiceOver reads the footer as a sentence.
    var sentence: String {
        switch self {
        case .dropped(let field, let value): return "\(field.displayName) \(value) is dropped"
        case .changed(let field, let from, let to): return "\(field.displayName) \(from) becomes \(to)"
        }
    }
}

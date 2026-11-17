import SwiftUI
import SwiftData

/// Two recipes, setting by setting: what separates a recipe from one re-scanned from the same post,
/// tweaked a notch and saved under a new name, or read back off the camera slot it was pushed to.
///
/// Three different kinds of nothing are reported differently, because the camera treats them
/// differently: "Not set" is a value the recipe declines to state, which the push omits so the
/// slot's own value survives; an em dash is a control the body or these settings switch off; and a
/// setting neither side has is not drawn at all. Collapsing the first two would hide the distinction
/// the push and the develop both act on.
struct RecipeCompareView: View {

    let recipeA: Recipe
    @State private var recipeB: Recipe?

    /// The comparison, computed when a side changes and never inside `body` (see `SettingsDiff`).
    /// Toggling the mode filters this rather than recomputing it.
    @State private var rows: [DiffRow] = []
    @State private var summary: DiffSummary?
    @State private var mode: Mode = .differences
    @State private var showingPicker = false

    private enum Mode: String, CaseIterable, Identifiable {
        case differences, all
        var id: String { rawValue }
        var title: String { self == .differences ? "Differences" : "All Settings" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if recipeB == nil {
                    chooseSecond
                } else if let summary {
                    summaryLine(summary)
                    ForEach(DiffGroup.allCases, id: \.self) { group in
                        let visible = visibleRows.filter { $0.group == group }
                        if !visible.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Theme.SectionLabel(group.displayName)
                                card(visible)
                            }
                        }
                    }
                    if visibleRows.isEmpty { nothingToShow(summary) }
                }
            }
            .padding(18)
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Compare Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if recipeB != nil {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingPicker = true } label: { Image(systemName: "arrow.left.arrow.right") }
                        .accessibilityLabel("Choose a different recipe to compare against")
                }
            }
        }
        .sheet(isPresented: $showingPicker) {
            ComparePickerSheet(excluding: recipeA.uuid) { picked in
                recipeB = picked
                recompute()
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            name(recipeA, align: .leading)
            Image(systemName: "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(Theme.ink3)
                .padding(.top, 6)
            name(recipeB, align: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recipeB.map { "Comparing \(recipeA.name) with \($0.name)" } ?? recipeA.name)
    }

    private func name(_ recipe: Recipe?, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 4) {
            // Serif on the names only: `Theme.serif` is fixed-point and doesn't scale with Dynamic
            // Type, so it never carries a value.
            Text(recipe?.name ?? "Choose a recipe")
                .font(Theme.serif(17))
                .foregroundStyle(recipe == nil ? Theme.ink3 : Theme.ink)
                .multilineTextAlignment(align == .leading ? .leading : .trailing)
            if let recipe {
                HStack(spacing: 5) {
                    FilmSwatch(simulation: recipe.settings.filmSimulation)
                    Text(recipe.settings.filmSimulation?.displayName ?? "No film simulation")
                        .font(.caption)
                        .foregroundStyle(Theme.ink3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
    }

    private var chooseSecond: some View {
        VStack(spacing: 12) {
            Text("Pick a second recipe to see what separates them.")
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
            Button { showingPicker = true } label: {
                Label("Choose Recipe", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .prominentOnAccentLabel()
            .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    /// Reads against `comparable`, never the row count — "3 of 19 differ" when four rows are
    /// mono-only is a sentence about nothing.
    private func summaryLine(_ s: DiffSummary) -> some View {
        // Counts and verbs agree — "1 of 11 differs", "3 of 11 differ" — the same care
        // `guidedSettingsDiffer(_:)` takes, on this screen's most prominent line.
        var parts = ["\(s.differing) of \(s.comparable) \(s.differing == 1 ? "differs" : "differ")"]
        if s.notApplicable > 0 {
            parts.append("\(s.notApplicable) \(s.notApplicable == 1 ? "doesn't" : "don't") apply to both")
        }
        return Text(parts.joined(separator: " · "))
            .font(.subheadline.weight(.medium))
            .foregroundStyle(s.differing == 0 ? Theme.accent : Theme.ink2)
            .accessibilityLabel(s.differing == 0
                                ? "These recipes agree on every setting that applies to both"
                                : parts.joined(separator: ", "))
    }

    private func nothingToShow(_ s: DiffSummary) -> some View {
        Text(s.differing == 0 && mode == .differences
             ? "Nothing differs. Switch to All Settings to see the full comparison."
             : "Nothing to compare.")
            .font(.subheadline)
            .foregroundStyle(Theme.ink3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private func card(_ rows: [DiffRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 14) }
                self.row(row)
            }
        }
        .themedCard(cornerRadius: 16)
    }

    private func row(_ row: DiffRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Shape first, then colour. A tint alone would leave the verdict unreadable to anyone
            // who can't separate the two hues, and unspoken to VoiceOver.
            Image(systemName: glyph(row.status))
                .font(.caption)
                .foregroundStyle(tint(row.status))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink2)
                if let note = footnote(row) {
                    Text(note).font(.caption2).foregroundStyle(Theme.ink3)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                sideText(row.a, emphasised: true)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Theme.ink3)
                sideText(row.b, emphasised: false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(row))
    }

    private func sideText(_ side: SideValue, emphasised: Bool) -> some View {
        Text(display(side))
            .font(.subheadline.weight(emphasised ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(side.presence == .set ? (emphasised ? Theme.ink : Theme.ink3) : Theme.ink3)
            .multilineTextAlignment(.trailing)
    }

    /// One side's text. "Not set" and the em dash stay distinct for the reason in the type's doc.
    private func display(_ side: SideValue) -> String {
        switch side.presence {
        case .set: return side.display ?? "—"
        case .unset: return "Not set"
        case .notApplicable: return "—"
        }
    }

    private func glyph(_ status: DiffStatus) -> String {
        switch status {
        case .same: return "checkmark.circle.fill"
        case .differs, .setOnlyInA, .setOnlyInB: return "exclamationmark.circle.fill"
        case .applicabilityDiffers: return "slash.circle"
        case .neitherSet, .neitherApplicable: return "circle"
        }
    }

    private func tint(_ status: DiffStatus) -> Color {
        switch status {
        case .same: return Theme.accent
        case .differs, .setOnlyInA, .setOnlyInB: return Theme.warning
        default: return Theme.ink3.opacity(0.6)
        }
    }

    /// The reason a control doesn't apply, in the row itself and in the row's accessibility label,
    /// because an em dash read aloud says nothing at all.
    private func footnote(_ row: DiffRow) -> String? {
        // Body-derived reasons name the recipe: the header shows names and film simulations, not
        // bodies, and a cross-body compare has two of them, so "this body" would not say which.
        let sides = [(row.a.presence, recipeA.name), (row.b.presence, recipeB?.name ?? "the other recipe")]
        for (presence, name) in sides {
            if case .notApplicable(let reason) = presence { return explain(reason, for: name) }
        }
        return nil
    }

    private func explain(_ reason: RecipeApplicability.Reason, for name: String) -> String {
        switch reason {
        case .monochrome: return "Doesn't apply on a monochrome film simulation"
        case .notMonochrome: return "Only applies on a monochrome film simulation"
        case .fixedToning: return "This film simulation is already toned"
        case .noMagentaGreenAxis: return "\(name) is authored for a body without a magenta–green axis"
        case .grainOff: return "Only applies when Grain Effect is on"
        case .noGrainSizeControl: return "\(name) is authored for a body with grain strength only"
        case .underPriority: return "The camera drives this while D-Range Priority is on"
        case .bodyLacksField: return "\(name) is authored for a body without this control"
        }
    }

    private func accessibilityLabel(_ row: DiffRow) -> String {
        let a = recipeA.name, b = recipeB?.name ?? "the other recipe"
        switch row.status {
        case .same: return "\(row.label), \(display(row.a)) on both"
        case .differs, .setOnlyInA, .setOnlyInB:
            return "\(row.label), \(display(row.a)) on \(a), \(display(row.b)) on \(b)"
        case .applicabilityDiffers:
            return "\(row.label), \(footnote(row) ?? "doesn't apply to both"). \(display(row.a)) on \(a), \(display(row.b)) on \(b)"
        case .neitherSet, .neitherApplicable:
            return "\(row.label), \(footnote(row) ?? "not set on either")"
        }
    }

    // MARK: Data

    private var visibleRows: [DiffRow] {
        rows.filter { mode == .all ? $0.status.isVisible : $0.status.isDifference }
    }

    private func recompute() {
        guard let recipeB else { rows = []; summary = nil; return }
        let computed = SettingsDiff.rows(side(recipeA), side(recipeB))
        rows = computed
        summary = SettingsDiff.summary(computed)
    }

    /// A library recipe is read against the body it was authored for — `nil` for a generic recipe,
    /// which is the common case and means every field applies.
    private func side(_ recipe: Recipe) -> DiffSide {
        DiffSide(settings: recipe.settings,
                 model: recipe.authoredForModel,
                 label: recipe.name,
                 origin: .recipe(recipe.uuid))
    }
}


/// The second side's picker, and the **only** thing here that queries the library.
///
/// It lives in its own view so that the query is created when the sheet is, not on every pass of the
/// parent's body. A `@Query` in `RecipeCompareView` hangs the app: `navigationDestination` builds its
/// destination eagerly, so the query would be registered and torn down on every body evaluation of
/// the detail screen, and the store's change notifications would feed straight back into it.
private struct ComparePickerSheet: View {
    let excluding: UUID
    let onPick: (Recipe) -> Void

    @Query(Recipe.listFetch(sortBy: [SortDescriptor(\Recipe.name)])) private var recipes: [Recipe]

    var body: some View {
        let others = recipes.filter { $0.uuid != excluding }
        RecipePickerSheet(title: "Compare With",
                          choices: others.map(RecipeChoice.init),
                          mode: .single,
                          emptyMessage: "Add a second recipe to compare against.") { picked in
            guard case .library(let uuid)? = picked.first,
                  let recipe = others.first(where: { $0.uuid == uuid }) else { return }
            onPick(recipe)
        }
    }
}

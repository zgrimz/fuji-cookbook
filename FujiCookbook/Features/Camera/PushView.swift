import SwiftUI
import SwiftData

/// Push recipes from the library to chosen custom slots, with an explicit overwrite confirmation and
/// per-field compatibility warnings. Supports assigning several recipes to several
/// slots in one session.
struct PushView: View {
    let preselectedRecipe: Recipe?
    /// Pre-filled slot → recipe assignments (used when pushing a whole Chapter). Slots outside the
    /// connected model's range or referencing a deleted recipe are dropped on appear; the first kind
    /// is named on screen (`slotsLeftOut`).
    var preassignedSlots: [Int: UUID] = [:]

    @Environment(CameraServices.self) private var camera
    @Environment(\.dismiss) private var dismiss
    @Query(Recipe.listFetch(sortBy: [SortDescriptor(\Recipe.name)])) private var recipes: [Recipe]

    /// Gates the Demo Camera shortcut in the empty state — see `DiagnosticMode`.
    @AppStorage(DiagnosticMode.key) private var diagnosticMode = false

    /// slot index → assigned recipe uuid (nil = leave slot unchanged).
    @State private var assignments: [Int: UUID] = [:]
    @State private var showingConfirm = false
    @State private var results: Identified<[SlotWriteResult]>?
    @State private var isPushing = false

    private var model: CameraModel? { camera.session.model }

    /// Every slot the connected body offers; at least C1, so the grid never collapses to nothing.
    private var slotRange: ClosedRange<Int> { 1...max(1, camera.slotReader.effectiveSlotCount) }

    /// The live step text `SlotWriter` publishes during a write, e.g. "(2 of 3) Writing slot C2…".
    private var statusMessage: String {
        if case .working(let message) = camera.session.status { return message }
        return "Preparing…"
    }

    var body: some View {
        Group {
            if !camera.session.isConnected {
                notConnected
            } else if let model, !camera.slotWriter.canPush {
                writeBlocked(model)
            } else if let model {
                // A single preselected recipe gets a focused "pick a destination slot" UI;
                // chapter / multi pushes use the full slot list.
                if let recipe = preselectedRecipe, preassignedSlots.isEmpty {
                    singleRecipeList(model, recipe: recipe)
                } else {
                    slotList(model)
                }
            }
        }
        .navigationTitle("Push to Camera")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isPushing { pushingOverlay } }
        .interactiveDismissDisabled(isPushing)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(isPushing)
            }
            if camera.session.isConnected, model != nil, camera.slotWriter.canPush {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Push (\(assignments.count))") { showingConfirm = true }
                        .disabled(assignments.isEmpty || isPushing)
                }
            }
        }
        .confirmationDialog("Write \(assignments.count) recipe\(assignments.count == 1 ? "" : "s") to the camera?",
                            isPresented: $showingConfirm, titleVisibility: .visible) {
            Button("Write & Overwrite", role: .destructive) { Task { await performPush() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .sheet(item: $results, onDismiss: { dismiss() }) { wrapper in
            PushResultsView(results: wrapper.value)
        }
        .onAppear(perform: applyPreselection)
    }

    // MARK: States

    private var notConnected: some View {
        ContentUnavailableView {
            Label("No Camera Connected", systemImage: "cable.connector.slash")
        } description: {
            Text(diagnosticMode
                 ? "Connect a camera on the Camera tab to push recipes. You can try the Demo Camera with no hardware."
                 : "Connect a camera on the Camera tab to push recipes.")
        } actions: {
            if diagnosticMode {
                Button("Connect Demo Camera") { Task { await camera.connector.connectDemo() } }
                    .buttonStyle(.borderedProminent)
                    .prominentOnAccentLabel()
            }
        }
    }

    /// Blocking progress overlay shown for the duration of the write, driven by the session's live
    /// status so each select/write/verify step is visible in real time.
    private var pushingOverlay: some View {
        BlockingProgressOverlay {
            if let progress = camera.slotWriter.pushProgress, progress.total > 1 {
                // Determinate bar for a batch (e.g. a whole Chapter): fills as slots complete.
                ProgressView(value: progress.fraction) {
                    Text("\(progress.completed) of \(progress.total) slots")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .progressViewStyle(.linear)
                .frame(width: 220)
                .animation(.default, value: progress)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(statusMessage)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .contentTransition(.numericText())
                .animation(.default, value: statusMessage)
            Text("Keep the camera connected.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pushing. \(statusMessage)")
    }

    private func writeBlocked(_ model: CameraModel) -> some View {
        ContentUnavailableView {
            Label("Writing Disabled", systemImage: "lock.fill")
        } description: {
            Text(camera.slotWriter.pushBlockReason ?? "Writing to \(model.displayName) isn't enabled yet.")
        }
    }

    private func slotList(_ model: CameraModel) -> some View {
        // Computed once per body pass and threaded down. Building it inside `slotWarnings` would
        // rebuild the whole map once per slot, each pass scanning the entire library per row.
        let collisions = Self.slotNameCollisions(assignments: assignments, recipes: recipes, model: model)
        return List {
            untestedNotice(camera.session.connected?.pushCaveat)
            leftOutNotice(model)
            if model.hasFilmSimulationDial { dialReminder(model) }
            ForEach(slotRange, id: \.self) { slot in
                slotSection(slot: slot, model: model, collisions: collisions)
            }
        }
    }

    @ViewBuilder
    private func slotSection(slot: Int, model: CameraModel, collisions: [String: [Int]]) -> some View {
        let assigned = assignments[slot].flatMap { id in recipes.first { $0.uuid == id } }
        Section {
            Picker("Recipe", selection: assignmentBinding(slot)) {
                Text("— Leave unchanged —").tag(UUID?.none)
                ForEach(recipes) {
                    Text("\($0.name) · \($0.settings.filmSimulation?.displayName ?? "no film simulation")")
                        .tag(UUID?.some($0.uuid))
                }
            }
            currentlyRow(slot: slot)
            if let assigned {
                filmSimulationChange(slot: slot, recipe: assigned, model: model)
                slotWarnings(slot: slot, recipe: assigned, model: model, collisions: collisions)
            }
        } header: {
            Text("Slot C\(slot)")
        }
    }

    /// Single-recipe push: choose which slot the recipe goes to, with live occupancy + warnings.
    private func singleRecipeList(_ model: CameraModel, recipe: Recipe) -> some View {
        let destination = assignments.keys.first ?? 1
        return List {
            untestedNotice(camera.session.connected?.pushCaveat)
            if model.hasFilmSimulationDial { dialReminder(model) }

            Section("Recipe") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(recipe.name).font(.headline)
                    Text(recipe.summary).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Slot", selection: singleDestinationBinding(recipe)) {
                    ForEach(slotRange, id: \.self) { slot in
                        Text(slotMenuLabel(slot)).tag(slot)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Push to Slot")
            } footer: {
                Text("Pick the custom slot to write this recipe to.")
            }

            Section {
                currentlyRow(slot: destination)
                filmSimulationChange(slot: destination, recipe: recipe, model: model)
                slotWarnings(slot: destination, recipe: recipe, model: model, collisions: [:])
            } header: {
                Text("Destination C\(destination)")
            }
        }
    }

    /// A body writable on shared architecture or on its own slot read alone, said before the user
    /// picks a slot.
    ///
    /// Only those bodies get it (`ConnectedCamera.pushCaveat`): nobody has reported a write to them
    /// anywhere. Saying so costs one section and buys an accurate expectation — and it
    /// names the mitigation, so the sentence isn't a warning with no answer attached.
    @ViewBuilder
    private func untestedNotice(_ caveat: String?) -> some View {
        if let caveat {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not tested on this camera yet").font(.subheadline.weight(.semibold))
                        Text(caveat).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.seal").foregroundStyle(Theme.warning)
                }
            }
        }
    }

    /// Chapter recipes in slots this body doesn't have, with the recipe each would have pushed.
    ///
    /// `applyPreselection` drops them, and the slot list only shows the slots the body has, so
    /// without this a seven-recipe chapter pushed to a four-bank X-M5 loses three recipes with
    /// nothing on screen saying so. A slot whose recipe was deleted isn't listed: the Chapter screen
    /// already shows it as missing, and there is no recipe to name.
    nonisolated static func slotsLeftOut(preassigned: [Int: UUID], slotCount: Int,
                                         recipes: [Recipe]) -> [(slot: Int, name: String)] {
        let byID = Dictionary(recipes.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return preassigned
            .filter { $0.key > max(1, slotCount) }
            .compactMap { slot, id in byID[id].map { (slot: slot, name: $0.name) } }
            .sorted { $0.slot < $1.slot }
    }

    private var leftOut: [(slot: Int, name: String)] {
        Self.slotsLeftOut(preassigned: preassignedSlots, slotCount: camera.slotReader.effectiveSlotCount, recipes: recipes)
    }

    @ViewBuilder
    private func leftOutNotice(_ model: CameraModel) -> some View {
        let leftOut = self.leftOut
        if !leftOut.isEmpty {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Chapter.slotRunLabel(leftOut.map(\.slot))) won't be pushed").font(.subheadline.weight(.semibold))
                        Text("The \(model.displayName) has \(camera.slotReader.effectiveSlotCount) custom slots. Left out of this push: \(leftOut.map { "\($0.name) (C\($0.slot))" }.formatted(.list(type: .and))).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                }
            }
        }
    }

    @ViewBuilder
    private func dialReminder(_ model: CameraModel) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set the Film Simulation dial to “C” first").font(.subheadline.weight(.semibold))
                    // An X-T50 (fw 1.32) showed the film simulation of five slots reset to PROVIA
                    // between sessions — every push had written the right value and verified it
                    // byte-for-byte, so the camera changed them afterwards.
                    Text("On the \(model.displayName), the physical Film Simulation dial sets the film simulation for the custom slot you're using — it can override what a recipe writes, and it can change a slot that was already correct. Turn it to the C (Custom) position before pushing, and leave it there while you shoot these recipes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "dial.medium").foregroundStyle(Theme.warning)
            }
        }
    }

    @ViewBuilder
    private func currentlyRow(slot: Int) -> some View {
        let current = camera.slotReader.slots.first { $0.index == slot }
        if let current, current.isOccupied {
            LabeledContent("Currently") {
                // Name *and* simulation. `displayName` falls back name → sim, and every pushed slot
                // has a name, so alone it would hide the one field a recipe is judged by.
                Text(Self.slotDescription(current))
                    .foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Currently", value: "Empty")
        }
    }

    /// `"Sunny 16 · Classic Chrome"`, or whichever half the slot has.
    private static func slotDescription(_ slot: CameraSlot) -> String {
        [slot.resolvedName, slot.settings?.filmSimulation?.displayName].compactMap { $0 }
            .joined(separator: " · ").nilIfEmpty ?? "Occupied"
    }

    /// What the film simulation is now, and what it will be.
    @ViewBuilder
    private func filmSimulationChange(slot: Int, recipe: Recipe, model: CameraModel) -> some View {
        let current = camera.slotReader.slots.first { $0.index == slot }
        LabeledContent("Film simulation") {
            Text(Self.filmSimulationPreview(slot: current, settings: recipe.settings, model: model))
                .foregroundStyle(recipe.settings.filmSimulation == nil ? Theme.warning : .secondary)
        }
    }

    /// `"Classic Chrome → PROVIA / Standard"`: the slot's film simulation as last read, and as the
    /// push leaves it on `model`.
    ///
    /// The second half follows `FujiPresetCodec.encode`. A recipe with a film simulation the body
    /// has writes it. One the body lacks (`model.supports(filmSimulation:)`, the question
    /// `RecipeCompatibility.analyze` warns about) is not substituted: the codec carries the slot's
    /// own D192 through (`passthrough`), so a slot whose read answered D192 is "unchanged" whether
    /// or not the app could name what it holds, and a slot whose read did not gets nothing. For a
    /// recipe with none the codec writes PROVIA / Standard (`0xD192 = 1`,
    /// zgrimz/fujifilm-ptp-reference `docs/03-encodings.md#0xd192-film-simulation`) into any slot
    /// whose read answered D192, and nothing into a slot whose read did not (`emitDefault`); the
    /// push's advisories say so. The reader calls a slot empty exactly when D192 was missing from
    /// its read, so that slot is "not written" in both cases; a slot it calls occupied but could
    /// not decode did answer, so PROVIA goes there too.
    ///
    /// Static and pure so it can be tested without a camera; `nonisolated` so the tests need not be
    /// on the main actor to call it.
    nonisolated static func filmSimulationPreview(slot: CameraSlot?, settings: RecipeSettings,
                                                  model: CameraModel) -> String {
        let answeredD192 = slot?.isOccupied == true
        let before = slot?.settings?.filmSimulation?.displayName ?? (answeredD192 ? "unreadable" : "empty")
        let after: String
        switch settings.filmSimulation {
        case let simulation? where model.supports(filmSimulation: simulation):
            after = simulation.displayName
        case .some:
            after = answeredD192 ? "unchanged" : "not written"
        case nil:
            after = answeredD192 ? FilmSimulation.provia.displayName : "not written"
        }
        return "\(before) → \(after)"
    }

    /// Applied slot names that two or more slots in this push would share, mapped to those slots.
    ///
    /// Keyed by the **applied** name — `model.sanitizedSlotName(from:)` — not the recipe's own. That
    /// is what the camera displays, and it is what makes the check worth having: two different
    /// recipe names that truncate to the same 25 characters collide on the camera while looking
    /// perfectly distinct in the library.
    ///
    /// Static and pure so it can be tested without a camera; `nonisolated` so the tests need not be
    /// on the main actor to call it.
    nonisolated static func slotNameCollisions(assignments: [Int: UUID],
                                               recipes: [Recipe],
                                               model: CameraModel) -> [String: [Int]] {
        guard model.supportsSlotNaming else { return [:] }
        // `uniquingKeysWith` rather than the throwing initializer: `Recipe.uuid` is not `.unique`
        // (CloudKit forbids unique constraints), so duplicates are possible and must not trap.
        let byID = Dictionary(recipes.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        var slotsByName: [String: [Int]] = [:]
        for (slot, id) in assignments {
            guard let recipe = byID[id] else { continue }
            let applied = model.sanitizedSlotName(from: recipe.effectiveCameraName)
            slotsByName[applied, default: []].append(slot)
        }
        return slotsByName.filter { $0.value.count > 1 }.mapValues { $0.sorted() }
    }

    /// "C2", "C2 and C5", "C2, C5 and C7".
    private static func slotLabels(_ slots: [Int]) -> String {
        slots.map { "C\($0)" }.formatted(.list(type: .and))
    }

    @ViewBuilder
    private func slotWarnings(slot: Int, recipe: Recipe, model: CameraModel,
                              collisions: [String: [Int]]) -> some View {
        let current = camera.slotReader.slots.first { $0.index == slot }
        let issues = RecipeCompatibility.analyze(recipe.settings, for: model)
        if current?.isOccupied ?? false {
            Label("This will overwrite C\(slot).", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Theme.warning)
        }
        ForEach(issues) { issue in
            // The two film-simulation kinds are the ones that change what the slot ends up
            // holding, unlike "your slot name will be shortened".
            let isFilmSim = issue.kind == .filmSimulationUnset || issue.kind == .filmSimulationUnsupported
            Label(issue.message, systemImage: isFilmSim ? "exclamationmark.triangle" : "info.circle")
                .font(.caption).foregroundStyle(isFilmSim ? Theme.warning : .secondary)
        }
        if model.supportsSlotNaming {
            let source = recipe.effectiveCameraName
            let applied = model.sanitizedSlotName(from: source)
            if applied != source {
                Label("Slot name will be saved as “\(applied)”.", systemImage: "textformat")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // The camera shows a slot's index and its name and nothing else, so two slots wearing
            // one name is an ambiguity the user cannot resolve while shooting. Worth saying here
            // rather than enforcing globally: the slot name is a label, not an identity — `uuid` is
            // the identity — and the library is allowed to hold as many "Velvia" recipes as it likes.
            let sameRecipe = assignments.filter { $0.key != slot && $0.value == recipe.uuid }
                .keys.sorted()
            let sameName = (collisions[applied] ?? [])
                .filter { $0 != slot && !sameRecipe.contains($0) }

            if !sameRecipe.isEmpty {
                // The specific diagnosis, which also suppresses the vaguer one below — the same
                // recipe in two slots would otherwise trip the name check too and say less.
                Label("This recipe is also going to \(Self.slotLabels(sameRecipe)).",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.warning)
            } else if !sameName.isEmpty {
                Label("\(Self.slotLabels(sameName)) will get this same name — the camera shows nothing else to tell them apart.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.warning)
            }

            // A slot this push isn't touching that already wears the name. Informational, not a
            // warning: nothing is being overwritten, the user just won't be able to tell the two
            // apart afterwards. This is the only collision case a single-recipe push can hit.
            let onCamera = camera.slotReader.slots.filter { other in
                other.index != slot
                    && assignments[other.index] == nil
                    && other.resolvedName.map { model.sanitizedSlotName(from: $0) } == applied
            }.map(\.index).sorted()
            if !onCamera.isEmpty {
                Label("\(Self.slotLabels(onCamera)) already has this name on the camera.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// "C2 · Velvia Daily" / "C3 · Empty" for the destination picker.
    private func slotMenuLabel(_ slot: Int) -> String {
        let current = camera.slotReader.slots.first { $0.index == slot }
        if let current, current.isOccupied {
            return "C\(slot) · \(Self.slotDescription(current))"
        }
        return "C\(slot) · Empty"
    }

    // MARK: Helpers

    private var confirmMessage: String {
        let model = camera.session.model
        let overwrites = assignments.keys.filter { slot in
            camera.slotReader.slots.first { $0.index == slot }?.isOccupied ?? false
        }.count
        var msg = "Parameters will be verified by reading the slot back afterward."
        if overwrites > 0 { msg = "\(overwrites) occupied slot\(overwrites == 1 ? "" : "s") will be overwritten. " + msg }
        let leftOut = self.leftOut
        if !leftOut.isEmpty {
            msg = "\(leftOut.map(\.name).formatted(.list(type: .and))) won't be pushed: this camera has \(camera.slotReader.effectiveSlotCount) custom slots. " + msg
        }
        if model?.hasFilmSimulationDial ?? false {
            msg = "Make sure the camera's Film Simulation dial is set to “C”, or the pushed film simulation won't apply. " + msg
        }
        if !(model?.supportsSlotNaming ?? false) {
            msg += " This model keeps its default slot labels (no slot naming)."
        } else if let model {
            // The last gate before writing, so the ambiguity gets named once more here rather than
            // only in a row the user may have scrolled past.
            let shared = Self.slotNameCollisions(assignments: assignments, recipes: recipes, model: model)
            if let worst = shared.max(by: { $0.value.count < $1.value.count }) {
                // No "all": the list is usually two slots, where it reads wrong.
                msg = "\(Self.slotLabels(worst.value)) will be named “\(worst.key)” on the camera. " + msg
            }
        }
        return msg
    }

    private func assignmentBinding(_ slot: Int) -> Binding<UUID?> {
        Binding(
            get: { assignments[slot] },
            set: { if let id = $0 { assignments[slot] = id } else { assignments.removeValue(forKey: slot) } }
        )
    }

    /// Single-recipe mode keeps exactly one assignment; changing the slot moves the recipe.
    private func singleDestinationBinding(_ recipe: Recipe) -> Binding<Int> {
        Binding(
            get: { assignments.keys.first ?? 1 },
            set: { assignments = [$0: recipe.uuid] }
        )
    }

    private func applyPreselection() {
        guard assignments.isEmpty, model != nil else { return }

        // Pushing a whole Chapter: honor its slot ordering, dropping anything the camera can't take.
        if !preassignedSlots.isEmpty {
            for (slot, id) in preassignedSlots
            where slotRange.contains(slot) && recipes.contains(where: { $0.uuid == id }) {
                assignments[slot] = id
            }
            return
        }

        guard let preselectedRecipe else { return }
        let firstEmpty = slotRange.first { slot in
            !(camera.slotReader.slots.first { $0.index == slot }?.isOccupied ?? false)
        }
        assignments[firstEmpty ?? 1] = preselectedRecipe.uuid
    }

    private func performPush() async {
        let batch: [(settings: RecipeSettings, name: String, slot: Int)] = assignments.compactMap { slot, id in
            guard let recipe = recipes.first(where: { $0.uuid == id }) else { return nil }
            return (recipe.settings, recipe.effectiveCameraName, slot)
        }
        .sorted { $0.slot < $1.slot }
        isPushing = true
        let written = await camera.slotWriter.pushBatch(batch)
        isPushing = false
        results = Identified(value: written)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

import SwiftUI
import SwiftData
import PhotosUI

/// **Read Recipe**: pick a JPEG straight off a Fujifilm camera and pull the recipe it was shot
/// with back out of its EXIF — the Fujifilm MakerNote carries the film simulation, tones, grain,
/// white balance and more, written at capture time. If a recipe in the library matches, this says
/// so; if none does, it offers to save what it read as a new one.
///
/// The deterministic counterpart to `LibraryView`'s "Scan Screenshot (AI)": that one sends a
/// picture of somebody else's recipe card to an LLM and guesses. This reads what the camera
/// recorded in the file, preserving ambiguities when the original recipe choice isn't recoverable.
///
/// No camera needed — like Frame & Fit, this is entirely on-device, which is why the Kitchen lists
/// it under that zone rather than with the cook pathways.
struct ReadRecipeView: View {
    private enum Stage {
        case empty
        case reading
        case read(PhotoRecipeReading)
        case failed(ExifError, source: Source)
    }
    private enum Source { case photos, files }

    @Environment(\.modelContext) private var modelContext
    @Query(Recipe.listFetch(sortBy: [SortDescriptor(\Recipe.updatedAt, order: .reverse)])) private var recipes: [Recipe]
    @AppStorage(DiagnosticMode.key) private var diagnosticMode = false

    @State private var stage: Stage = .empty
    @State private var match: RecipeMatchResult?
    /// Kept so Save as New Recipe can attach the frame itself, not just its settings.
    @State private var originalData: Data?
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var editTarget: Identified<Recipe>?
    @State private var pickError: String?

    var body: some View {
        List {
            switch stage {
            case .empty:
                emptyState
            case .reading:
                loadingState
            case .read(let reading):
                readSections(reading)
            case .failed(let error, let source):
                failureState(error, source: source)
            }
        }
        .listStyle(.plain)
        .paperBackground()
        .navigationTitle("Read Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .read = stage {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Read Another", systemImage: "arrow.triangle.2.circlepath") {
                        Button { showPhotoPicker = true } label: { Label("Choose a Photo", systemImage: "photo") }
                        Button { showFilePicker = true } label: { Label("Browse Files…", systemImage: "folder") }
                    }
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerSelection,
                      maxSelectionCount: 1, matching: .images,
                      preferredItemEncoding: .current,
                      photoLibrary: .shared())
        .onChange(of: pickerSelection) { _, items in
            guard let item = items.first else { return }
            // Cleared at once, so the picker opens empty next time and the same photo picked again
            // still changes the selection.
            pickerSelection = []
            Task { await read(item) }
        }
        .sheet(isPresented: $showFilePicker) {
            ContentPicker(contentTypes: [.jpeg], allowsMultiple: false) { urls in
                guard let url = urls.first else { return }
                Task { await read(url) }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $editTarget) { target in
            NavigationStack { RecipeEditorView(recipe: target.value, isNew: true) }
        }
        .alert("Couldn't Open Photo", isPresented: Binding(isPresent: $pickError)) {
            Button("OK", role: .cancel) {}
        } message: { Text(pickError ?? "") }
        .onAppear { if case .read(let reading) = stage { recomputeMatch(reading) } }
        .onChange(of: recipeStamp) { _, _ in
            if case .read(let reading) = stage { recomputeMatch(reading) }
        }
    }

    /// The latest edit across the library, so the verdict updates if the matched recipe changes in
    /// another tab while this screen is still showing it.
    private var recipeStamp: Date? { recipes.map(\.updatedAt).max() }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Read a Recipe", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Pick a JPEG straight from a Fujifilm camera and Read Recipe pulls the settings it was shot with out of the file, then tells you which recipe in your library that is.")
        } actions: {
            VStack(spacing: 10) {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Choose a Photo", systemImage: "photo")
                        .font(.headline)
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button("Browse Files…") { showFilePicker = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .font(.subheadline.weight(.medium))

                Text("The photo has to be the original off the camera — apps that re-save a photo throw the recipe away.")
                    .font(.footnote)
                    .foregroundStyle(Theme.ink3)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var loadingState: some View {
        HStack {
            Spacer()
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading…").font(.subheadline).foregroundStyle(Theme.ink2)
            }
            Spacer()
        }
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Failure state

    private func failureState(_ error: ExifError, source: Source) -> some View {
        ContentUnavailableView {
            Label(failureTitle(error), systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 6) {
                Text(failureMessage(error, source: source))
                if let extra = failureExtraMessage(error, source: source) {
                    Text(extra).foregroundStyle(Theme.ink3)
                }
            }
        } actions: {
            Button("Try Another Photo") {
                stage = .empty
                showPhotoPicker = source == .photos
                showFilePicker = source == .files
            }
            .buttonStyle(.borderedProminent)
            .prominentOnAccentLabel()
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func failureTitle(_ error: ExifError) -> String {
        switch error {
        case .notAJPEG(let kind):
            return kind == .heif ? "HEIF Isn't Supported Yet" : "Not a JPEG"
        case .unreadable: return "Couldn't Open This File"
        case .malformedJPEG: return "This File Couldn't Be Read"
        case .noExif: return "No EXIF in This Photo"
        case .noMakerNote: return "The Recipe Was Stripped"
        case .notFujifilm(_, let make): return make != nil ? "Not a Fujifilm Photo" : "Couldn't Read the Fujifilm Section"
        case .malformedTIFF, .malformedMakerNote: return "Couldn't Read the Fujifilm Section"
        }
    }

    private func failureMessage(_ error: ExifError, source: Source) -> String {
        switch error {
        case .notAJPEG(let kind) where kind == .heif:
            return "This is a HEIF file, and Read Recipe can only open JPEGs so far. Set the camera's image quality to FINE or NORMAL and shoot it again."
        case .notAJPEG(let kind):
            return "Read Recipe works on JPEGs from the camera. This is a \(kind.displayName). If you shot RAW, develop it in the Kitchen first and read the JPEG that comes out."
        case .unreadable:
            return "The file couldn't be opened. If it lives in iCloud Drive, download it first and try again."
        case .malformedJPEG:
            return "The file is damaged, or was only partly copied. Copy it off the card again and try once more."
        case .noExif:
            return "There's no EXIF in this file at all, so there's nothing to read. Screenshots and photos re-saved by an editor usually look like this. Pick the original off the camera."
        case .noMakerNote:
            return "The EXIF is still here, but the Fujifilm section — where the recipe lives — has been removed. Messages, WhatsApp and most editors do that. Use the original off the camera or the SD card, or AirDrop it: AirDrop keeps it."
        case .notFujifilm(_, let make):
            if let make { return "This was shot on a \(make). Read Recipe reads Fujifilm's own recipe settings, which only Fujifilm cameras write." }
            return "This is a Fujifilm photo, but the recipe section isn't in a shape this app knows. The file itself is fine — nothing was changed. Worth reporting."
        case .malformedTIFF, .malformedMakerNote:
            return "The metadata in this file isn't in a shape this app knows. The file itself is fine — nothing was changed."
        }
    }

    private func failureExtraMessage(_ error: ExifError, source: Source) -> String? {
        guard case .noMakerNote = error, source == .photos else { return nil }
        return "If you've edited this photo in Photos, the edited copy is what you picked. Revert it, or open the original with Browse Files."
    }

    // MARK: - Read sections

    @ViewBuilder
    private func readSections(_ reading: PhotoRecipeReading) -> some View {
        headerSection(reading)
        if reading.recipeStatus != .found {
            noRecipeSection(reading)
        } else {
            if !reading.warnings.isEmpty { warningsSection(reading) }
            if let match { matchSection(match, reading: reading) }
            settingsSection(reading)
        }
        cameraSection(reading)
        if reading.recipeStatus == .found {
            actionsSection(reading)
            if diagnosticMode { diagnosticsSection(reading) }
        }
    }

    /// A prominent, can't-miss-it flag that this photo has no Fujifilm recipe to read — never
    /// folded into the small inline warnings, because "there's nothing to compare against" is the
    /// headline fact about this photo, not a footnote under a Match section that isn't there.
    /// Camera & Exposure still renders below: that comes from ImageIO independently of this app's
    /// own MakerNote parsing, so there's no reason it should go missing along with the recipe.
    private func noRecipeSection(_ reading: PhotoRecipeReading) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(noRecipeTitle(reading.recipeStatus))
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text(noRecipeMessage(reading.recipeStatus))
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink2)
                }
            }
            .padding(14)
            .background(Theme.warningSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func noRecipeTitle(_ status: FujiRecipeStatus) -> String {
        switch status {
        case .found: return ""
        case .notFujifilm: return "Not a Fujifilm Photo"
        case .noMakerNote: return "No Fujifilm Recipe Found"
        case .unreadable: return "Recipe Section Unreadable"
        }
    }

    private func noRecipeMessage(_ status: FujiRecipeStatus) -> String {
        switch status {
        case .found: return ""
        case .notFujifilm(let make):
            if let make { return "This was shot on a \(make). Read Recipe reads Fujifilm's own recipe settings, which only Fujifilm cameras write." }
            return "This wasn't shot on a Fujifilm camera, so there's no recipe to look for."
        case .noMakerNote:
            return "The EXIF below is still intact, but the Fujifilm section — where the recipe lives — has been removed. Messages, WhatsApp and most editors do that. Use the original off the camera or the SD card, or AirDrop it: AirDrop keeps it."
        case .unreadable:
            return "This looks like a Fujifilm photo, but the recipe section isn't in a shape this app knows. The EXIF below is unaffected."
        }
    }

    private func headerSection(_ reading: PhotoRecipeReading) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    if let proxy = reading.proxy {
                        Image(uiImage: proxy)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if reading.recipeStatus == .found {
                            HStack(spacing: 6) {
                                FilmSwatch(simulation: reading.settings.filmSimulation, size: 12)
                                Text(reading.settings.filmSimulation?.displayName ?? "Film Simulation Unknown")
                                    .font(Theme.serif(19))
                                    .foregroundStyle(Theme.ink)
                            }
                        } else {
                            // No recipe to headline with — the camera/model is the identifying
                            // fact about this photo instead, matching what's actually in `camera`.
                            Text([reading.camera.make, reading.camera.model].compactMap { $0 }.joined(separator: " ").isEmpty
                                 ? "Recipe Unavailable" : [reading.camera.make, reading.camera.model].compactMap { $0 }.joined(separator: " "))
                                .font(Theme.serif(19))
                                .foregroundStyle(Theme.ink)
                        }
                        HStack(spacing: 6) {
                            if reading.recipeStatus == .found, let model = reading.camera.model { BadgeTag(text: model) }
                            if let date = reading.camera.captureDate {
                                Text(date, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(Theme.ink3)
                            }
                        }
                        if let filename = reading.filename {
                            Text(filename)
                                .font(.caption)
                                .foregroundStyle(Theme.ink3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .themedCard(cornerRadius: 16)
            .accessibilityElement(children: .combine)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func warningsSection(_ reading: PhotoRecipeReading) -> some View {
        Section {
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(reading.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                }
            }
        }
    }

    // MARK: - Match

    private func matchSection(_ match: RecipeMatchResult, reading: PhotoRecipeReading) -> some View {
        Section {
            Group {
                switch match.tier {
                case .none:
                    noMatchCard(match)
                case .exact, .close, .closest:
                    if let best = match.best { matchCard(match, best: best) }
                }
            }
        } header: {
            Theme.SectionLabel("Match")
        }
    }

    private func noMatchCard(_ match: RecipeMatchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if recipes.isEmpty {
                Text("You haven't saved any recipes yet, so there's nothing to compare against. Save this one and it becomes your first.")
            } else {
                Text("Nothing in your library matches.")
            }
            if !match.simulationNearMisses.isEmpty { simulationNearMissLine(match) }
        }
        .font(.subheadline)
        .foregroundStyle(Theme.ink2)
    }

    private func matchCard(_ match: RecipeMatchResult, best: RecipeMatch) -> some View {
        let (fill, tint, icon) = tierStyle(match.tier)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tierHeadline(match.tier, name: best.recipe.name))
                        .font(Theme.serif(19))
                        .foregroundStyle(Theme.ink)
                    if !match.tiedWithBest.isEmpty {
                        Text("Also matches: " + ([best.recipe] + match.tiedWithBest.map(\.recipe))
                            .dropFirst().map(\.name).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(Theme.ink3)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.ink3)
            }
            // Invisible NavigationLink overlay, not a wrapping label: a NavigationLink used directly
            // as the label adds iOS's own disclosure chevron alongside the one drawn above — see
            // the same trick in `LibraryView.recipeCard`.
            .overlay {
                NavigationLink { RecipeDetailView(recipe: best.recipe) } label: { EmptyView() }
                    .opacity(0)
            }

            if !best.differences.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(best.differences) { row in
                        diffRow(row)
                    }
                }
            }

            ForEach(match.runnersUp) { runner in
                Text("Also close: \(runner.recipe.name) — \(runner.differences.count) differ")
                    .font(.caption)
                    .foregroundStyle(Theme.ink3)
            }

            if !match.simulationNearMisses.isEmpty { simulationNearMissLine(match) }
        }
        .padding(14)
        .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func diffRow(_ row: FieldComparison) -> some View {
        HStack(spacing: 4) {
            Text(row.label).font(.caption.weight(.medium)).foregroundStyle(Theme.ink2)
            Text("·").foregroundStyle(Theme.ink3)
            Text(row.photoValue ?? "—").font(.caption).monospacedDigit().foregroundStyle(Theme.ink)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Theme.ink3)
            Text(row.recipeValue ?? "—").font(.caption).monospacedDigit().foregroundStyle(Theme.ink3)
        }
    }

    private func simulationNearMissLine(_ match: RecipeMatchResult) -> some View {
        let names = match.simulationNearMisses.map(\.recipe.name).joined(separator: ", ")
        let count = match.simulationNearMisses.count
        return Text("\(count) recipe\(count == 1 ? "" : "s") match everything except the film simulation: \(names).")
            .font(.caption)
            .foregroundStyle(Theme.ink3)
    }

    private func tierStyle(_ tier: RecipeMatchResult.Tier) -> (fill: Color, tint: Color, icon: String) {
        switch tier {
        case .exact: return (Theme.accentSoft, Theme.accent, "checkmark.seal.fill")
        case .close: return (Theme.warningSoft, Theme.warning, "checkmark.seal")
        case .closest, .none: return (Theme.paper2, Theme.ink2, "questionmark.circle")
        }
    }

    private func tierHeadline(_ tier: RecipeMatchResult.Tier, name: String) -> String {
        switch tier {
        case .exact: return "Shot with \(name)"
        case .close: return "Almost certainly \(name)"
        case .closest: return "The closest is \(name)"
        case .none: return name
        }
    }

    // MARK: - Settings table

    private func settingsSection(_ reading: PhotoRecipeReading) -> some View {
        Section {
            ForEach(RecipeSettingsFormatter.rows(for: reading.settings), id: \.field) { entry in
                HStack {
                    Circle()
                        .fill(dotColor(for: entry.field))
                        .frame(width: 6, height: 6)
                    SettingsRow(label: entry.field.displayName, value: entry.value)
                }
            }
        } header: {
            Theme.SectionLabel("Recipe Settings")
        }
    }

    /// Green when this field agrees with the matched recipe, warning when it differs, muted when
    /// there's no match to compare against (or the recipe doesn't set the field). One annotated
    /// table rather than a second, separate diff table — the diff card above is a summary of this
    /// one, not a duplicate of it.
    private func dotColor(for field: RecipeField) -> Color {
        guard let best = match?.best else { return Theme.ink3.opacity(0.3) }
        guard let row = best.rows.first(where: { rowMatches(field: field, rowID: $0.id) }) else {
            return Theme.ink3.opacity(0.3)
        }
        switch row.verdict {
        case .same: return Theme.accent
        case .different, .missingInRecipe: return Theme.warning
        case .missingInPhoto, .notCompared: return Theme.ink3.opacity(0.3)
        }
    }

    /// `RecipeField.whiteBalance` covers both matcher rows (`whiteBalance.mode` and
    /// `.shift`); either disagreeing is enough to flag the field in this single-row table.
    private func rowMatches(field: RecipeField, rowID: String) -> Bool {
        if field == .whiteBalance { return rowID.hasPrefix("whiteBalance.") }
        return rowID == field.rawValue
    }

    // MARK: - Camera & Exposure

    private func cameraSection(_ reading: PhotoRecipeReading) -> some View {
        Section {
            let camera = reading.camera
            if let make = camera.make { LabeledContent("Camera", value: [make, camera.model].compactMap { $0 }.joined(separator: " ")) }
            if let lens = camera.lens { LabeledContent("Lens", value: lens) }
            if let focal = camera.focalLength {
                let text = camera.focalLength35mm.map { "\(Int(focal))mm (\($0)mm equiv.)" } ?? "\(Int(focal))mm"
                LabeledContent("Focal Length", value: text)
            }
            if let fNumber = camera.fNumber { LabeledContent("Aperture", value: String(format: "ƒ/%.1f", fNumber)) }
            if let exposureTime = camera.exposureTime { LabeledContent("Shutter", value: shutterText(exposureTime)) }
            if let iso = camera.iso { LabeledContent("ISO", value: "\(iso)") }
            if let bias = camera.exposureBias, bias != 0 { LabeledContent("Exposure Comp.", value: String(format: "%+.1f EV", bias)) }
            if let width = camera.pixelWidth, let height = camera.pixelHeight { LabeledContent("Dimensions", value: "\(width) × \(height)") }
            ForEach(reading.extras, id: \.label) { extra in
                LabeledContent(extra.label, value: extra.value)
            }
        } header: {
            Theme.SectionLabel("Camera & Exposure")
        }
        .font(.subheadline)
        .monospacedDigit()
    }

    private func shutterText(_ seconds: Double) -> String {
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        let denominator = (1 / seconds).rounded()
        return "1/\(Int(denominator))"
    }

    // MARK: - Actions

    private func actionsSection(_ reading: PhotoRecipeReading) -> some View {
        Section {
            // Written as a switch over the unwrapped tier, not `match?.tier == .none`: with an
            // Optional<Tier> on the left, `.none` resolves to Optional's own nil case rather than
            // `Tier.none`, which would silently make that comparison redundant with the nil check.
            let suggestPrimary: Bool = {
                guard let tier = match?.tier else { return true }
                switch tier {
                case .closest, .none: return true
                case .exact, .close: return false
                }
            }()
            if suggestPrimary {
                CookButton(title: "Save as New Recipe", systemImage: "plus.circle.fill", enabled: true) {
                    saveAsNew(reading)
                }
            } else {
                Button("Save as New Recipe") { saveAsNew(reading) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
    }

    private func diagnosticsSection(_ reading: PhotoRecipeReading) -> some View {
        Section {
            ForEach(Array(reading.rawTags.enumerated()), id: \.offset) { _, tag in
                HStack {
                    Text(tag.label).font(.caption.monospaced()).foregroundStyle(Theme.ink3)
                    Spacer()
                    Text(tag.value).font(.caption.monospaced()).foregroundStyle(Theme.ink)
                }
            }
        } header: {
            Theme.SectionLabel("Raw MakerNote")
        } footer: {
            Text("Recipe tags and unknown tag identifiers for checking against exiftool. Serial numbers are excluded.")
        }
    }

    // MARK: - Reading

    @MainActor
    private func read(_ item: PhotosPickerItem) async {
        stage = .reading
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            pickError = "That photo couldn't be opened."
            stage = .empty
            return
        }
        await finishRead(data, filename: nil, source: .photos)
    }

    @MainActor
    private func read(_ url: URL) async {
        let filename = url.lastPathComponent
        stage = .reading
        await finishRead(nil, url: url, filename: filename, source: .files)
    }

    /// Everything expensive — the file read, the segment walk, the IFD walk, the ImageIO property
    /// copy, the thumbnail decode — runs off the main actor, so decoding a 15–25MB Fuji JPEG doesn't
    /// stall the UI while the picker sheet dismisses. `RecipeMatcher.match`, by contrast, stays on
    /// the main actor deliberately: it touches `Recipe`, a SwiftData model that isn't safe to use
    /// off its context's actor, and the comparison itself is microseconds of pure arithmetic —
    /// nothing is gained by moving it and a data race is what's risked.
    @MainActor
    private func finishRead(_ providedData: Data?, url: URL? = nil, filename: String?, source: Source) async {
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(Data, PhotoRecipeReading), ExifError> in
            let data: Data
            if let providedData {
                data = providedData
            } else if let url, let loaded = try? Data(contentsOf: url) {
                data = loaded
            } else {
                return .failure(.unreadable)
            }
            do {
                let reading = try PhotoRecipeReader.read(data, filename: filename)
                return .success((data, reading))
            } catch let error as ExifError {
                return .failure(error)
            } catch {
                return .failure(.malformedJPEG)
            }
        }.value

        switch outcome {
        case .success(let (data, reading)):
            originalData = data
            stage = .read(reading)
            recomputeMatch(reading)
        case .failure(let error):
            stage = .failed(error, source: source)
        }
    }

    private func recomputeMatch(_ reading: PhotoRecipeReading) {
        // Nothing to match without a decoded recipe — leave `match` nil rather than let a
        // Match section quietly compute and go unused (the view already skips it in this case).
        match = reading.recipeStatus == .found ? RecipeMatcher.match(photo: reading.settings, against: recipes) : nil
    }

    // MARK: - Save as New Recipe

    private func saveAsNew(_ reading: PhotoRecipeReading) {
        let portable = PortableRecipe(
            name: suggestedName(reading),
            uuid: nil,
            cameraName: nil,
            credit: nil,
            authoredForModel: reading.modelID,
            notes: provenanceNote(reading),
            tags: nil,
            settings: reading.settings,
            unsupportedFields: reading.preservedMetadata,
            photos: nil
        )
        let recipe = RecipePortability.makeRecipe(from: portable)
        if let originalData, let processed = PhotoProcessing.process(originalData) {
            recipe.photos = [RecipePhoto(imageData: processed.full, thumbnailData: processed.thumbnail, sortOrder: 0)]
        }
        modelContext.insert(recipe)
        editTarget = Identified(value: recipe)
    }

    private func suggestedName(_ reading: PhotoRecipeReading) -> String {
        let simName = reading.settings.filmSimulation?.displayName ?? "Read Recipe"
        let date = reading.camera.captureDate ?? Date()
        return "\(simName) — \(Self.nameDateFormatter.string(from: date))"
    }

    private func provenanceNote(_ reading: PhotoRecipeReading) -> String {
        var note = "Read from \(reading.filename ?? "a photo")"
        if let date = reading.camera.captureDate {
            note += ", shot \(Self.nameDateFormatter.string(from: date))"
        }
        if let model = reading.camera.model {
            note += " on \(model)"
        }
        return note + "."
    }

    private static let nameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

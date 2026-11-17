import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Building blocks shared by the Develop and Test Kitchen screens, which drive the same in-camera
// RAW-conversion session and differ in how many recipes they apply and at what resolution.
//
// Both screens pick recipes through `RecipePickerSheet`, Develop one and Test Kitchen up to three.
// Resolving a selection to settings, the camera status, the RAF picker, the cook button, failure
// reporting and saving what came back live here, so the two screens can't drift apart.

extension CameraServices {
    /// The camera's custom slots that actually hold a recipe.
    var occupiedSlots: [CameraSlot] { slotReader.slots.filter { $0.isOccupied } }

    /// The "C2" tag for a slot choice; nil for a Library recipe or a slot that has since emptied.
    func slotLabel(for ref: RecipeRef?) -> String? {
        guard case .slot(let index) = ref else { return nil }
        return occupiedSlots.first { $0.index == index }?.label
    }
}

extension RecipeChoice {
    /// A programmed camera slot as a picker row, so slots and library recipes can be searched
    /// together instead of behind a source switch. A slot has no favorite flag and no modified date,
    /// which is fine because slots get their own section, in slot order, whatever the sort.
    init(_ slot: CameraSlot) {
        self.init(ref: .slot(slot.index),
                  name: slot.resolvedName ?? slot.label,
                  filmSimulation: slot.settings?.filmSimulation,
                  summary: slot.settings?.filmSimulation?.displayName ?? "Occupied",
                  isFavorite: false,
                  badge: slot.label,
                  notes: "",
                  tags: [],
                  updatedAt: .distantPast,
                  settings: slot.settings)
    }

    /// Programmed camera slots and Library recipes, as one searchable list for the Kitchen's pickers.
    @MainActor
    static func choices(camera: CameraServices, recipes: [Recipe]) -> [RecipeChoice] {
        camera.occupiedSlots.map(RecipeChoice.init) + recipes.map(RecipeChoice.init)
    }
}

/// What a `RecipeRef` resolves to: the settings to develop with, and `displayName`, which the user
/// sees and a saved version is labeled with.
struct ResolvedRecipe {
    let settings: RecipeSettings
    let displayName: String
    var filmSimulation: String? { settings.filmSimulation?.displayName }
}

// What the Camera Test records about a Kitchen run: the recipes it supplies, the run, and the
// outcome of each file and recipe. None of these holds a file name or path, so they can go into
// diagnostics as they are; the picked files stay with the picker.

struct GuidedKitchenRecipe: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var settings: RecipeSettings

    var resolved: ResolvedRecipe {
        ResolvedRecipe(settings: settings, displayName: name)
    }
}

struct CookRecordContext: Codable, Equatable {
    var runID: UUID
    var caseID: String
    var recipeID: String
    var settings: RecipeSettings
}

struct GuidedKitchenRun: Codable, Equatable, Identifiable {
    var id = UUID()
    var caseID: String
    var startedAt = Date()
    var recipes: [GuidedKitchenRecipe]
    var fullResolution: Bool

    var recordContexts: [CookRecordContext] {
        recipes.map { .init(runID: id, caseID: caseID, recipeID: $0.id, settings: $0.settings) }
    }
}

struct GuidedKitchenCell: Codable, Equatable {
    var resultID: UUID
    var recipeID: String
    var fileIndex: Int
    var succeeded: Bool
    var clampedFields: [String]
    var notes: [String]
    var warnings: [String]
    var failureReason: String?
    var profileVerified: Bool?
    var dynamicRange: String?

    init(result: ConversionResult, recipeID: String, fileIndex: Int) {
        resultID = result.id
        self.recipeID = recipeID
        self.fileIndex = fileIndex
        succeeded = result.success && result.recoveryFileURL != nil
        clampedFields = result.clampedFields
        notes = result.notes
        warnings = result.warnings
        failureReason = result.evidence.failureReason
        profileVerified = result.evidence.profileVerified
        dynamicRange = result.evidence.dynamicRange
    }
}

struct GuidedKitchenCompletion: Codable, Equatable {
    var run: GuidedKitchenRun
    var cells: [GuidedKitchenCell]
    var savedBatchID: UUID?
    var saveFailed: Bool

    var hasSuccessfulOutput: Bool { cells.contains(where: \.succeeded) }
    var hasFailures: Bool { cells.contains { !$0.succeeded } }
}

/// How a Camera Test step drives a Kitchen screen.
///
/// `onStart` records the run before any file is sent; returning false stops the run with nothing
/// sent. `onComplete` records the outcome before the results are shown; returning false holds the
/// screen at a retry that saves the outcome without developing again.
struct GuidedKitchenConfiguration {
    var caseID: String
    var recipes: [GuidedKitchenRecipe]
    var maxFiles = 1
    var initialRAFs: [URL] = []
    var onFilesSelected: ([URL]) -> Void = { _ in }
    var onStart: (GuidedKitchenRun) -> Bool
    var onComplete: (GuidedKitchenCompletion) -> Bool
    var onContinue: () -> Void
    var onReport: () -> Void

    func run(fullResolution: Bool) -> GuidedKitchenRun {
        .init(caseID: caseID, recipes: recipes, fullResolution: fullResolution)
    }
}

extension RecipeRef {
    /// Resolve against the Library and the connected camera's slots. Returns nil if the recipe has
    /// been deleted or the slot no longer holds one; the slots clear whenever the camera disconnects.
    @MainActor
    func resolve(recipes: [Recipe], camera: CameraServices) -> ResolvedRecipe? {
        switch self {
        case .library(let id):
            guard let recipe = recipes.first(where: { $0.uuid == id }) else { return nil }
            return ResolvedRecipe(settings: recipe.settings, displayName: recipe.name)
        case .slot(let index):
            guard let slot = camera.occupiedSlots.first(where: { $0.index == index }),
                  let settings = slot.settings else { return nil }
            return ResolvedRecipe(settings: settings, displayName: slot.resolvedName ?? slot.label)
        }
    }
}

/// A recipe that has already been chosen, as it appears back on the Develop / Test Kitchen form.
/// Picking happens in a sheet, so these rows are all the form shows — and the cook button stays a
/// short scroll away no matter how large the library is.
struct ChosenRecipeRow: View {
    let name: String
    let filmSimulation: FilmSimulation?
    var badge: String?
    /// Supplied by Test Kitchen, which can hold three at once; Develop just swaps its one out.
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            FilmSwatch(simulation: filmSimulation, size: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(Theme.serif(16))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(filmSimulation?.displayName ?? "No film simulation set")
                    .font(.caption)
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let badge { BadgeTag(text: badge) }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(name)")
            }
        }
    }
}

/// The live "Developing…" rows: spinner + message, plus a determinate bar for multi-file batches.
struct CookingProgressRows: View {
    let message: String
    let progress: BatchProgress?

    var body: some View {
        HStack { ProgressView(); Text(message) }
        if let p = progress, p.total > 1 {
            ProgressView(value: p.fraction) { Text("\(p.completed) of \(p.total) developed") }
        }
    }
}

/// Routes to the Camera tab, where connecting is handled.
struct ConnectInCameraTabButton: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button {
            router.selectedTab = .camera
        } label: {
            Label("Connect in the Camera Tab", systemImage: "cable.connector")
        }
    }
}

/// The camera-state section both cook screens open with: in-flight progress, a connection failure,
/// the not-connected invitation, or the unsupported-body notice. Nothing renders when the camera is
/// connected and ready — at that point the screen is just the task.
///
/// `onShowGuide` is optional so a screen without its own connection-guide sheet simply omits the
/// help button rather than reimplementing the section.
struct CookStatusSection: View {
    let camera: CameraServices
    /// Copy for the not-connected case, which differs between a single cook and a comparison grid.
    let notConnectedMessage: String
    var onShowGuide: (() -> Void)?

    var body: some View {
        switch camera.session.status {
        case .connecting:
            Section {
                Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            }
        case .working(let message):
            Section { CookingProgressRows(message: message, progress: camera.conversion.conversionProgress) }
        case .failed(let message):
            Section {
                Label { Text(message) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
                if let onShowGuide {
                    Button("Connection Help") { onShowGuide() }
                }
            }
        case .connected, .disconnected:
            if !camera.session.isConnected {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No camera connected").font(.headline)
                            Text(notConnectedMessage)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    }
                    ConnectInCameraTabButton()
                }
            } else if !camera.session.canConvert {
                Section {
                    Label("RAW conversion isn't enabled for \(camera.session.connected?.model?.displayName ?? camera.session.connected?.productName ?? "this camera").",
                          systemImage: "lock.fill")
                        .foregroundStyle(Theme.warning)
                } footer: {
                    Text("The Kitchen can't develop RAW files with this camera yet. Camera Test can collect information to help us add support. You can still use the app's other available features.")
                }
            }
        }
    }
}

/// What a cook form still needs before it can develop, the first missing thing first.
enum CookPrerequisite: Equatable {
    case filesAndRecipe, files, recipe, camera

    enum Screen { case develop, testKitchen }

    /// Nil when files, a recipe and a camera that converts are all in place: whatever else holds
    /// the button (a run already going) is shown by the button itself.
    static func missing(hasFiles: Bool, hasRecipe: Bool, cameraCanConvert: Bool) -> CookPrerequisite? {
        switch (hasFiles, hasRecipe) {
        case (false, false): .filesAndRecipe
        case (false, true): .files
        case (true, false): .recipe
        case (true, true): cameraCanConvert ? nil : .camera
        }
    }

    func message(for screen: Screen) -> String {
        switch (self, screen) {
        case (.filesAndRecipe, .develop): "Choose a RAW file and a recipe to develop."
        case (.filesAndRecipe, .testKitchen): "Choose RAW files and recipes to compare."
        case (.files, .develop): "Choose a RAW file to develop."
        case (.files, .testKitchen): "Choose RAW files to compare."
        case (.recipe, .develop): "Choose a recipe to develop with."
        case (.recipe, .testKitchen): "Choose the recipes to compare."
        case (.camera, _): "Connect a camera to develop."
        }
    }
}

/// The Kitchen's "cook" action: full-width, amber, dimmed when it can't run, with the reason
/// beneath it. Both cook screens use it so developing looks like the same act whichever pathway
/// you came through.
struct CookButton: View {
    let title: String
    let systemImage: String
    let enabled: Bool
    /// What the form still needs, shown while the button is disabled.
    var blockedReason: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            button
            if !enabled, let blockedReason {
                Text(blockedReason)
                    .font(.footnote)
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private var button: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(Theme.onAmber)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Theme.amber, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// The RAF picker: Photos and Files as sources, the picked files (deletable), and the pickers.
/// With `step` set, the header renders as a numbered Kitchen step.
struct RAFPickerSection: View {
    /// What Browse Files lets the user pick: Fujifilm RAWs only, so a JPEG or another maker's RAW is
    /// greyed out there. Files types a file by its name, so a `.RAF` without RAF bytes still gets
    /// through; the upload reads the header and refuses it, and refuses a RAF another body shot.
    /// The system declares `com.fuji.raw-image`; the fallback keeps the picker usable if it ever
    /// stops, at the cost of offering every RAW.
    static let fileContentTypes: [UTType] = [UTType("com.fuji.raw-image") ?? .rawImage]

    @Binding var pickedRAFs: [URL]
    var maxFiles: Int?
    let header: String
    let footer: String
    var step: Int?

    @Environment(\.photoLibrary) private var library
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var showPairPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    /// The photos being copied out of the library; set only while that copy runs.
    @State private var photoImport: PhotoImport?
    @State private var photoProblem: PhotoLibraryRAW.Import.Problem?

    /// Where the photos being copied were picked.
    private enum PhotoImport {
        /// The photo picker: each photo's RAW if the picker offers one, else its RAF through photo
        /// library access when the app already has it.
        case picked([PhotosPickerItem])
        /// Choose RAW+JPEG Photos, by identifier, with a copy of its own so a cancelled import's
        /// progress can't reach the next one.
        case shared([String], RAWPhotoCopy)

        var isEmpty: Bool {
            switch self {
            case .picked(let items): items.isEmpty
            case .shared(let ids, _): ids.isEmpty
            }
        }

        /// The shared copy's progress; nil for a picker import, which reports none.
        @MainActor var progress: RAWPhotoCopy.Progress? {
            guard case .shared(_, let copy) = self else { return nil }
            return copy.progress
        }
    }

    var body: some View {
        Section {
            if let photoImport {
                importRow(photoImport)
            } else {
                // One row with the three sources behind it, each saying which photos it is for:
                // three equal rows read as three ways to do the same thing.
                Menu {
                    photosButton
                    pairsButton
                    filesButton
                } label: {
                    Label(pickedRAFs.isEmpty ? "Add RAW Files…" : "Change Selection…",
                          systemImage: pickedRAFs.isEmpty ? "plus.circle" : "photo.stack")
                }
            }
            ForEach(pickedRAFs, id: \.self) { url in
                Label(url.lastPathComponent, systemImage: "doc")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .onDelete { offsets in
                let removed = offsets.map { pickedRAFs[$0] }
                pickedRAFs.remove(atOffsets: offsets)
                PickedRAFStore.discard(removed)
            }
        } header: {
            // The pickers hang off the header because it is one view. Modifiers on a Section reach
            // each of its rows, so a photo picker there is set up once per row and none of them shows.
            presentingPickers(headerLabel)
        } footer: {
            Text(footer)
        }
    }

    @ViewBuilder
    private var headerLabel: some View {
        if let step {
            Theme.StepHeader(number: step, title: header)
                .textCase(nil)
        } else {
            Text(header)
        }
    }

    private func presentingPickers(_ anchor: some View) -> some View {
        anchor
            .sheet(isPresented: $showFilePicker) {
                ContentPicker(contentTypes: Self.fileContentTypes, allowsMultiple: maxFiles != 1) { urls in
                    replaceSelection(with: maxFiles.map { Array(urls.prefix($0)) } ?? urls)
                }
                .ignoresSafeArea()
            }
            // `.current` hands over the RAW as stored; a compatible encoding may transcode it.
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelection,
                          maxSelectionCount: maxFiles, matching: .images,
                          preferredItemEncoding: .current,
                          photoLibrary: .shared())
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                // Cleared at once, so the picker opens empty next time and the same photo picked
                // again still changes the selection.
                photoSelection = []
                startImport(.picked(items))
            }
            .rawPairPicker(isPresented: $showPairPicker, limit: maxFiles,
                           onPick: { startImport(.shared($0, RAWPhotoCopy())) },
                           onFullAccess: { showPhotoPicker = true },
                           onBrowseFiles: { showFilePicker = true })
            .alert(photoProblem?.title ?? "", isPresented: Binding(isPresent: $photoProblem)) {
                if photoProblem?.offersRAWPairs == true {
                    Button("Choose RAW+JPEG Photos…") { showPairPicker = true }
                }
                Button("OK", role: .cancel) {}
            } message: { Text(photoProblem?.message ?? "") }
    }

    // The menu items keep the names the photo-import messages send people to
    // (`PhotoLibraryRAW.Import.Problem`); the second line says which photos each is for.

    private var photosButton: some View {
        Button { showPhotoPicker = true } label: {
            Label("Choose from Photos…", systemImage: "photo")
            Text("Photos shot in RAW only")
        }
    }

    private var pairsButton: some View {
        Button { showPairPicker = true } label: {
            Label("Choose RAW+JPEG Photos…", systemImage: "photo.on.rectangle.angled")
            Text("Photos shot as RAW+JPEG")
        }
    }

    private var filesButton: some View {
        Button { showFilePicker = true } label: {
            Label("Browse Files…", systemImage: "folder")
            Text(".RAF files in Files")
        }
    }

    /// The pick replaces the selection now, not when the copy lands, so nothing can be developed
    /// from files that are about to be discarded.
    private func startImport(_ pending: PhotoImport) {
        guard !pending.isEmpty else { return }
        replaceSelection(with: [])
        photoImport = pending
    }

    /// Stands in for the source buttons while the copy runs, and owns it: leaving the screen or
    /// tapping Cancel cancels the copy, a cancelled copy selects nothing, and coming back starts it
    /// over.
    private func importRow(_ pending: PhotoImport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if pending.progress?.download == nil { ProgressView() }
                Text(importStatus(pending.progress))
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink2)
                Spacer()
                Button("Cancel") { photoImport = nil }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }
            if let download = pending.progress?.download {
                ProgressView(value: download)
                    .tint(Theme.accent)
                    .accessibilityLabel("Downloading from iCloud")
            }
        }
        .task {
            let copied = switch pending {
            case .picked(let items): await PhotoLibraryRAW.copy(items, library: library)
            case .shared(let ids, let copy): await copy.copy(ids, from: library)
            }
            guard !Task.isCancelled else { return }
            replaceSelection(with: copied.urls)
            photoProblem = copied.problem
            photoImport = nil
        }
    }

    /// "Copying from Photos…", with which file when there are several, and that it's coming from
    /// iCloud while Photos reports a download.
    private func importStatus(_ progress: RAWPhotoCopy.Progress?) -> String {
        guard let progress else { return "Copying from Photos…" }
        let source = progress.download == nil ? "Copying from Photos" : "Downloading from iCloud"
        return progress.count > 1 ? "\(source)… \(progress.file) of \(progress.count)" : "\(source)…"
    }

    /// Stage the picked files in `PickedRAFStore`, then discard the staged files they replace.
    private func replaceSelection(with picked: [URL]) {
        let previous = pickedRAFs
        pickedRAFs = PickedRAFStore.stage(picked)
        PickedRAFStore.discard(previous)
    }
}

/// A cook that went wrong, as both cook screens put it to the user: nothing developed, a Camera
/// Test run that couldn't start, or one whose record didn't save. One type, so the same problem
/// reads the same way on either screen.
struct CookFailure {
    let title: String
    let message: String

    /// Files in the selection couldn't be read. Nothing is developed either way: a batch that
    /// shrinks from three files to two on its own is its own wrong answer, so the run stops and
    /// names what to remove.
    static func unreadable(_ filenames: [String], ofTotal total: Int) -> CookFailure {
        guard filenames.count < total else {
            return CookFailure(title: "Nothing Developed",
                               message: total == 1 ? "Couldn't read the RAW file you picked."
                                                   : "Couldn't read the RAW files you picked.")
        }
        let listed = filenames.prefix(3).joined(separator: ", ")
        let names = filenames.count > 3 ? "\(listed) and \(filenames.count - 3) more" : listed
        let them = filenames.count == 1 ? "it" : "them"
        return CookFailure(title: "Some Files Couldn't Be Read",
                           message: "Couldn't read \(names), so nothing was developed. Remove \(them) from your selection, or pick your files again, then develop.")
    }

    /// The camera ran but handed nothing back.
    static func nothingDeveloped(_ reason: String?) -> CookFailure {
        CookFailure(title: "Nothing Developed",
                    message: reason ?? "The camera didn't return any developed versions.")
    }

    /// The Camera Test refused to record the run's start, so nothing was sent.
    static let checkCouldNotStart = CookFailure(
        title: "This check couldn't start",
        message: "Return to Camera Test, confirm the connected camera and resolve any save error, then try again. No file was sent.")

    /// The run finished but its record didn't save. Retrying saves the record without developing
    /// again, which is the thing a tester most needs to hear before tapping it. Develop has one
    /// photo and Test Kitchen several, so the wording follows the count.
    static func testResultNotSaved(plural: Bool) -> CookFailure {
        CookFailure(title: "Test result couldn't be saved",
                    message: plural
                        ? "Tap Retry saving test result to keep these outcomes in the report. This saves the results without developing the photos again."
                        : "Tap Retry saving test result to keep this attempt in the report. This saves the result without developing the photo again.")
    }
}

extension ConversionResult {
    /// The result a guided run records for a picked file it couldn't read, so the report shows the
    /// failure as a cell rather than as a run that never happened. Worded by the same error the
    /// service reports when a file goes away between that check and its upload.
    static func unreadableFile(named filename: String) -> ConversionResult {
        var result = ConversionResult(sourceFilename: filename, success: false, clampedFields: [],
                                      errorMessage: CameraError.rafUnreadable.message)
        result.evidence.failureReason = CameraError.rafUnreadable.diagnosticReason
        return result
    }
}

extension View {
    /// Starts a guided run with the files the Camera Test already chose, once, and reports every
    /// later pick back to it. The seed runs on first appearance only, so returning to the screen
    /// doesn't undo a change the tester made.
    func seedingGuidedFiles(_ guided: GuidedKitchenConfiguration?, into files: Binding<[URL]>) -> some View {
        modifier(GuidedFileSeeding(guided: guided, files: files))
    }
}

private struct GuidedFileSeeding: ViewModifier {
    let guided: GuidedKitchenConfiguration?
    @Binding var files: [URL]
    @State private var seeded = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !seeded else { return }
                seeded = true
                if let guided { files = Array(guided.initialRAFs.prefix(guided.maxFiles)) }
            }
            .onChange(of: files) { _, picked in guided?.onFilesSelected(picked) }
    }
}

extension View {
    /// The Kitchen's failure alert.
    func cookFailureAlert(_ failure: Binding<CookFailure?>) -> some View {
        alert(failure.wrappedValue?.title ?? "",
              isPresented: Binding(isPresent: failure)) {
            Button("OK", role: .cancel) { failure.wrappedValue = nil }
        } message: {
            Text(failure.wrappedValue?.message ?? "")
        }
    }
}

enum CookHarness {
    /// What preparing a selection produced: the files that can be read, and the names of the ones
    /// that can't. Dropping what can't be read would turn an unreadable file into a screen that
    /// does nothing — or, worse, a three-file batch that quietly develops two and never says which
    /// one went missing.
    struct PreparedRAFs {
        var rafs: [RAFSource] = []
        var unreadable: [String] = []
    }

    /// Check that the picked RAF URLs can be read, and hand them over as sources that read their
    /// file only when its upload runs. `PickedRAFStore` keeps the files inside the app's container,
    /// so the URLs are readable without security scoping.
    ///
    /// Nothing is read here: reading every file up front would hold the whole selection in memory,
    /// and Develop puts no limit on how many files are picked. Ten GFX100S files come to about 2 GB
    /// (`RAFSource` has the sizes). A file that can't be read now stops the batch before anything
    /// is sent; one that goes away between this check and its upload is reported for that file
    /// alone, in the same words, by the service.
    static func prepareRAFs(_ urls: [URL]) -> PreparedRAFs {
        var prepared = PreparedRAFs()
        for url in urls {
            if FileManager.default.isReadableFile(atPath: url.path) {
                prepared.rafs.append(RAFSource(filename: url.lastPathComponent) { try await read(url) })
            } else {
                prepared.unreadable.append(url.lastPathComponent)
            }
        }
        return prepared
    }

    /// Off the main actor: a synchronous read of a file this size freezes the UI for the length of it.
    private static func read(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
    }

    /// Run one develop pass with the screen kept awake (the OS can drop USB on sleep/background).
    @MainActor
    static func run(_ body: () async -> Void) async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        await body()
    }
}

/// The one place developed JPEGs become saved records. Both pathways go through it, so a photo
/// developed with a single recipe and one compared across three land in the same history with the
/// same shape — the only difference being how many versions hang off the photo, and whether those
/// versions are full-resolution deliverables or downscaled comparison previews.
@MainActor
enum CookStore {

    /// Adapt a single-recipe Develop run into the grouped shape `persist` stores: one photo per
    /// source file, each with exactly one version.
    static func comparisons(from results: [ConversionResult],
                            recipe: ResolvedRecipe) -> [TestKitchenComparison] {
        results.map { result in
            TestKitchenComparison(sourceFilename: result.sourceFilename,
                                  versions: [TestKitchenVersion(recipeName: recipe.displayName,
                                                                filmSimulation: recipe.filmSimulation,
                                                                result: result)])
        }
    }

    /// Save the developed versions (successes only — failures are reported live, not filed) and
    /// return the batch id so the caller can navigate to them. Returns nil when nothing succeeded.
    ///
    /// Each version's bytes come from its recovery file, one version at a time: read and
    /// thumbnailed off the main actor, handed to the store, and let go before the next file is
    /// opened, so a batch of N develops has one JPEG outside the store at any point. Only the
    /// inserts and the save itself run on the main actor.
    ///
    /// A recovery file that can't be read fails the save the way a store error does: nothing is
    /// saved, nothing of the batch stays pending in the context, and every recovery file is kept.
    ///
    /// The batch is one save. Filing one version at a time suspends between inserts, and the
    /// context's own autosave could otherwise file part of the batch in one of those gaps, so it
    /// is held off until this returns.
    ///
    /// `save` and `load` are seams for tests of the failure paths; production uses the defaults.
    @discardableResult
    static func persistChecked(_ comparisons: [TestKitchenComparison],
                               fullResolution: Bool,
                               into context: ModelContext,
                               save: (ModelContext) throws -> Void = { try $0.save() },
                               load: @escaping (URL) async throws -> Data = DevelopOutputRecovery.load)
        async throws -> UUID? {
        let autosaveWasEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosaveWasEnabled }

        var filing = Filing(context: context, fullResolution: fullResolution, load: load)
        do {
            for comparison in comparisons { try await filing.file(comparison) }
            guard filing.filedAnything else { return nil }
            try save(context)
        } catch {
            // The main context is shared, and its next save, or an autosave, would otherwise file
            // whatever was inserted before the failure while the caller reports nothing saved and
            // keeps every recovery file.
            filing.undo()
            throw error
        }
        for result in comparisons.flatMap({ $0.versions.map(\.result) }) where result.success {
            DevelopOutputRecovery.removeAfterLibrarySave(result.recoveryFileURL)
        }
        return filing.batchID
    }

    /// One batch on its way into the store, and everything it has inserted so far, so a failure
    /// part-way can take the batch back out.
    @MainActor
    private struct Filing {
        let context: ModelContext
        let fullResolution: Bool
        let load: (URL) async throws -> Data
        let batchID = UUID()
        private let createdAt = Date()
        private var photoOrder = 0
        private var inserted: [any PersistentModel] = []

        init(context: ModelContext, fullResolution: Bool, load: @escaping (URL) async throws -> Data) {
            self.context = context
            self.fullResolution = fullResolution
            self.load = load
        }

        var filedAnything: Bool { photoOrder > 0 }

        /// Insert one source file's successful versions. A source with none leaves no photo.
        mutating func file(_ comparison: TestKitchenComparison) async throws {
            let successes = comparison.versions.filter { $0.result.success && $0.result.recoveryFileURL != nil }
            guard !successes.isEmpty else { return }
            let photo = CookedPhoto(sourceFilename: comparison.sourceFilename, batchID: batchID,
                                    createdAt: createdAt, sortOrder: photoOrder)
            insert(photo)
            photoOrder += 1
            for (versionOrder, version) in successes.enumerated() {
                guard let url = version.result.recoveryFileURL else { continue }
                let jpeg = try await load(url)
                let thumbnail = await Task.detached(priority: .userInitiated) {
                    PhotoProcessing.thumbnail(from: jpeg) ?? Data()
                }.value
                let saved = CookedVersion(uuid: version.result.id, recipeName: version.recipeName,
                                          filmSimulation: version.filmSimulation,
                                          imageData: jpeg, thumbnailData: thumbnail,
                                          clampedFields: version.result.clampedFields,
                                          sortOrder: versionOrder,
                                          notes: version.result.notes + version.result.warnings,
                                          isFullResolution: fullResolution,
                                          diagnostics: version.result.diagnostics)
                saved.photo = photo
                insert(saved)
            }
        }

        private mutating func insert(_ model: some PersistentModel) {
            context.insert(model)
            inserted.append(model)
        }

        /// Take back everything inserted, versions before their photo.
        func undo() {
            for model in inserted.reversed() { context.delete(model) }
        }
    }

    /// The developed JPEG a result stands for, read when the results sheet asks for it: the
    /// library's copy once the batch has saved, else the recovery file the service wrote. Nil when
    /// neither holds it. Read on demand and let go, so a sheet listing a batch of full-resolution
    /// develops holds none of their bytes.
    ///
    /// `imageData` is read on the main actor the way `ComparisonImageStore` reads it: a model's
    /// attributes are the main context's to touch.
    static func developedJPEG(for result: ConversionResult, in context: ModelContext) async throws -> Data? {
        let id = result.id
        var saved = FetchDescriptor<CookedVersion>(predicate: #Predicate { $0.uuid == id })
        saved.fetchLimit = 1
        if let version = try context.fetch(saved).first, !version.imageData.isEmpty {
            return version.imageData
        }
        guard let url = result.recoveryFileURL else { return nil }
        return try await DevelopOutputRecovery.load(url)
    }
}

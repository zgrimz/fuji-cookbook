import SwiftData
import SwiftUI
import UIKit

/// Full-screen viewer for one photo's developed versions, in three modes:
///
/// * **Swipe** — one version at a time, best for reading detail.
/// * **A|B** — two versions in one frame behind a draggable divider, the classic before/after.
/// * **Tiled** — every version at once, stacked or in columns depending on what fits.
///
/// Swipe alone is a comparison feature you can't actually compare with — two recipes held in memory
/// across a swipe. Zoom and pan are shared by every pane on screen (`SyncedTransform`), so pinching
/// into one frame's shadows pinches all of them to the same place.
struct ComparisonViewer: View {
    let photo: CookedPhoto
    /// The version Swipe opens on, as when Recent Results is narrowed to one recipe; nil opens on
    /// the first.
    var initialVersionID: UUID?

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Query(Recipe.listFetch(sortBy: [SortDescriptor(\Recipe.name)])) private var recipes: [Recipe]
    /// The Library recipe Open Recipe is showing.
    @State private var openedRecipe: Recipe?

    @State private var mode: ComparisonMode = .swipe
    @State private var selection: Int = 0
    @State private var transform = SyncedTransform()
    /// Divider position for A|B, as a fraction of the width.
    @State private var curtainPosition: CGFloat = 0.5
    /// Which two versions the curtain is showing, as indices into `versions`.
    @State private var pair: (a: Int, b: Int) = (0, 1)
    @State private var store = ComparisonImageStore()

    /// Everything `body` needs about the versions, as plain values read once.
    ///
    /// Not a computed `photo.sortedVersions`, which `body` would call a dozen times a pass — for
    /// the item list, the current version, the caption, and the toolbar. Touching a SwiftData
    /// relationship that often during rendering faults objects back in *mid-render*, and faulting
    /// writes to the model's backing store; the write invalidates the view, the view re-renders,
    /// and it faults again — a main thread spinning in `AG::Subgraph::update` forever, right after
    /// a Test Kitchen cook, when the context is still settling and every read is a fault.
    /// Snapshotting breaks the cycle: `body` never touches SwiftData at all.
    @State private var versions: [VersionSnapshot] = []
    @State private var filename = ""

    /// Gates the raw D185 profile dump — see `DiagnosticMode`.
    @AppStorage(DiagnosticMode.key) private var diagnosticMode = false
    @State private var showDiagnostics = false
    /// Whether the card listing what the develop adjusted is open over the photo.
    @State private var showingAdjustments = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The profile report to show: the version on screen in swipe mode, else the first one that has
    /// it (in A|B and Tiled there's no single "current" version).
    private var diagnosticsText: String? {
        current?.diagnostics ?? versions.compactMap(\.diagnostics).first
    }

    private var hasChoice: Bool { versions.count > 1 }

    private var current: VersionSnapshot? {
        versions.indices.contains(selection) ? versions[selection] : nil
    }

    private var items: [ComparisonItem] {
        versions.map { ComparisonItem(id: $0.id, image: store.image(for: $0.id), label: $0.recipeName) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch mode {
                case .swipe: swipeBody
                case .curtain: curtainBody
                case .tiled: tiledBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { adjustmentsCard }

            bottomPanel
        }
        .onChange(of: selection) { showingAdjustments = false }
        .onChange(of: mode) { showingAdjustments = false }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(filename)
        .navigationBarTitleDisplayMode(.inline)
        // A full-screen comparison shouldn't give up its bottom inches to the tab bar, which
        // otherwise sits on top of the caption and clips the last tile.
        .toolbar(.hidden, for: .tabBar)
        .toolbar { toolbarContent }
        // Colour is judged against the black surround in either appearance, so the chrome on it is
        // dark too: in light mode the caption and pair chips would be light material over black.
        // Applied before the sheets, so the diagnostics sheet and alerts keep the app's appearance.
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task(id: photo.uuid) { await prepare() }
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
        .sheet(item: $openedRecipe) { recipe in
            NavigationStack {
                RecipeDetailView(recipe: recipe)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { openedRecipe = nil }
                        }
                    }
            }
        }
        .photoExportPresentation(share: $shareItem, message: $saveMessage)
        .confirmationToast($savedConfirmation)
    }

    @State private var saver = ImageSaver()
    @State private var saveMessage: String?
    @State private var savedConfirmation: String?
    @State private var shareItem: ShareItem?
    /// Reads developed JPEGs off the main actor, for the panes and for Save and Share.
    @State private var loader: DevelopedImageLoader?

    /// The one place that reads the model. Everything else works off `versions`.
    private func prepare() async {
        let loader = self.loader ?? DevelopedImageLoader(modelContainer: modelContext.container)
        self.loader = loader
        let models = photo.sortedVersions
        filename = photo.sourceFilename
        versions = models.map(VersionSnapshot.init)
        if let initialVersionID, let index = versions.firstIndex(where: { $0.id == initialVersionID }) {
            selection = index
        }
        if pair.b >= models.count { pair = (0, min(1, max(0, models.count - 1))) }
        store.prime(models)
        await store.load(versions.map(\.id), with: loader)
    }

    // MARK: Modes

    private var swipeBody: some View {
        TabView(selection: $selection) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ComparisonPane(image: item.image, transform: $transform, accessibilityName: item.label)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: hasChoice ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
    }

    @ViewBuilder
    private var curtainBody: some View {
        let list = items
        if list.indices.contains(pair.a), list.indices.contains(pair.b) {
            VStack(spacing: 0) {
                CurtainComparison(leading: list[pair.a],
                                  trailing: list[pair.b],
                                  transform: $transform,
                                  position: $curtainPosition)
                // With only two versions the pair is already settled; a chooser would be a row of
                // controls that can't change anything.
                if list.count > 2 { pairChips(list) }
            }
        }
    }

    private var tiledBody: some View {
        // Three landscape frames side by side on an upright phone would be about 130pt wide each —
        // so landscape photos stack and keep the full width, and only portrait ones go into columns.
        let aspect = store.aspectRatio ?? 1.5
        let stacked = aspect >= 1 && verticalSizeClass != .compact
        return TiledComparison(items: items, transform: $transform, stacked: stacked) { index in
            selection = index
            mode = .swipe
        }
    }

    /// Picks the two versions in the curtain. Tapping a third promotes it to B and slides the old B
    /// over to A, so repeated taps walk the comparison forward rather than needing two controls.
    private func pairChips(_ list: [ComparisonItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                    let role = index == pair.a ? "A" : (index == pair.b ? "B" : nil)
                    FilterChip(label: role.map { "\($0) · \(item.label)" } ?? item.label,
                               selected: role != nil) {
                        guard index != pair.a, index != pair.b else { return }
                        pair = (pair.b, index)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if diagnosticMode, diagnosticsText != nil {
                Button { showDiagnostics = true } label: { Image(systemName: "stethoscope") }
                    .accessibilityLabel("Conversion diagnostics")
            }
            versionAction(systemImage: "square.and.arrow.up", verb: "Share", action: share)
            versionAction(systemImage: "square.and.arrow.down", verb: "Save", action: save)
            moreMenu
        }
    }

    /// Where a version leads next: the recipe that made it, a share card of it, and for a
    /// comparison preview, the full-resolution develop the preview was for. In Swipe it acts on the
    /// version on screen; in A|B and Tiled each version gets its own section.
    @ViewBuilder
    private var moreMenu: some View {
        let targets = mode == .swipe ? [current].compactMap { $0 } : versions
        if !targets.isEmpty {
            Menu {
                if targets.count == 1, let version = targets.first {
                    nextActions(for: version)
                } else {
                    ForEach(targets) { version in
                        Section(version.recipeName) { nextActions(for: version) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    @ViewBuilder
    private func nextActions(for version: VersionSnapshot) -> some View {
        let recipe = recipes.uniqueRecipe(named: version.recipeName)
        if let recipe {
            Button("Open Recipe", systemImage: "book") { openedRecipe = recipe }
        }
        if store.isAvailable(version.id) {
            Button("Make Share Card", systemImage: "square.on.square.dashed") {
                router.frameSeed = FrameSeed(recipeUUID: recipe?.uuid, developedVersionID: version.id)
                router.selectedTab = .kitchen
            }
        }
        if version.isComparisonPreview, let recipe {
            Button("Develop at Full Resolution…", systemImage: "wand.and.stars") {
                router.developSeed = DevelopSeed(recipeUUID: recipe.uuid)
                router.selectedTab = .kitchen
            }
        }
    }

    /// The `0xD185` profile this version was developed with, base vs. patched. A sheet rather than a
    /// disclosure in the caption bar: it's thirty-odd monospaced lines, and it needs to be readable
    /// and copyable, not squeezed under the photo.
    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView {
                Text(diagnosticsText ?? "")
                    .diagnosticText()
                    .padding()
            }
            .navigationTitle("D185 Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy") { UIPasteboard.general.string = diagnosticsText }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showDiagnostics = false }
                }
            }
        }
    }

    /// In swipe mode the action is unambiguous — it's the version on screen. In A|B and Tiled it
    /// isn't, so the same button becomes a menu of the versions in play.
    @ViewBuilder
    private func versionAction(systemImage: String,
                               verb: String,
                               action: @escaping (VersionSnapshot) -> Void) -> some View {
        let usable = versions.filter { store.isAvailable($0.id) }
        if mode == .swipe || usable.count <= 1 {
            if let current, store.isAvailable(current.id) {
                Button { action(current) } label: { Image(systemName: systemImage) }
                    .accessibilityLabel("\(verb) \(current.recipeName)")
            }
        } else if !usable.isEmpty {
            Menu {
                ForEach(usable) { version in
                    Button(version.recipeName) { action(version) }
                }
            } label: {
                Image(systemName: systemImage)
            }
            .accessibilityLabel(verb)
        }
    }

    /// The caption, then the mode picker. The picker lives down here rather than in the navigation
    /// bar: beside the back button and three actions, a 393-point-wide iPhone truncates its labels.
    private var bottomPanel: some View {
        VStack(spacing: 12) {
            captionBar
            if hasChoice {
                Picker("View", selection: $mode) {
                    ForEach(ComparisonMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var captionBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch mode {
            case .swipe:
                if let version = current {
                    HStack(spacing: 8) {
                        Text(version.recipeName).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        adjustmentsButton(for: version)
                    }
                    detailLine(for: version, position: "\(selection + 1) of \(versions.count)")
                }
            case .curtain:
                if versions.indices.contains(pair.a), versions.indices.contains(pair.b) {
                    Text("\(versions[pair.a].recipeName)  |  \(versions[pair.b].recipeName)")
                        .font(.headline)
                }
                sharedDetailLine
            case .tiled:
                Text(filename).font(.headline).lineLimit(1).truncationMode(.middle)
                sharedDetailLine
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One line whatever the version, so the caption keeps its height and the photo above it
    /// doesn't jump as Swipe moves between versions; what the develop adjusted opens over the photo.
    private func detailLine(for version: VersionSnapshot, position: String?) -> some View {
        let parts = [version.filmSimulation,
                     versions.count > 1 ? position : nil,
                     version.isComparisonPreview ? "Comparison preview" : nil]
        return Text(parts.compactMap { $0 }.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Present on every version so the caption row is the same height either way, but visible and
    /// reachable only on a version the develop adjusted.
    private func adjustmentsButton(for version: VersionSnapshot) -> some View {
        let adjusted = !version.adjustments.isEmpty
        return Button {
            withAnimation(reduceMotion ? nil : .snappy) { showingAdjustments.toggle() }
        } label: {
            Label("Adjusted", systemImage: showingAdjustments ? "chevron.down" : "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .opacity(adjusted ? 1 : 0)
        .disabled(!adjusted)
        .accessibilityHidden(!adjusted)
        .accessibilityLabel("Develop adjustments")
        .accessibilityValue(showingAdjustments ? "Shown" : "Hidden")
    }

    /// What the develop changed on the recipe's behalf, over the foot of the photo rather than in
    /// the caption, so reading it never resizes the frame being judged. Tap to close.
    @ViewBuilder
    private var adjustmentsCard: some View {
        if mode == .swipe, showingAdjustments, let version = current, !version.adjustments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Adjustments")
                    .font(.subheadline.weight(.semibold))
                ForEach(version.adjustments, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(reduceMotion ? nil : .snappy) { showingAdjustments = false } }
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(named: "Close") { showingAdjustments = false }
        }
    }

    private var sharedDetailLine: some View {
        HStack(spacing: 8) {
            Text("\(versions.count) versions")
            if versions.contains(where: \.isComparisonPreview) { Text("Comparison preview") }
            if transform.isZoomed { Text("Double-tap to fit") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Actions

    private func outputFilename(_ version: VersionSnapshot) -> String {
        let base = (filename as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let recipe = version.recipeName.replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: allowed.inverted).joined()
        return "\(base.isEmpty ? "photo" : base)-\(recipe.isEmpty ? "recipe" : recipe).jpg"
    }

    /// The version's original developed JPEG, EXIF included, never the downsampled proxy the panes
    /// draw. Nil, with the reason in the alert, when the library no longer holds it.
    private func originalJPEG(_ version: VersionSnapshot) async -> Data? {
        guard let data = await loader?.jpeg(for: version.id) else {
            saveMessage = "This photo couldn't be read from the app's library."
            return nil
        }
        return data
    }

    private func save(_ version: VersionSnapshot) {
        Task {
            guard let data = await originalJPEG(version) else { return }
            saver.save(data: data) { error in
                if let error { saveMessage = ImageSaver.message(for: error) } else { savedConfirmation = "Saved to Photos" }
            }
        }
    }

    private func share(_ version: VersionSnapshot) {
        Task {
            guard let data = await originalJPEG(version) else { return }
            do {
                shareItem = try .temporaryFiles([(data, outputFilename(version))])
            } catch {
                saveMessage = ShareItem.preparationFailure(error)
            }
        }
    }
}

/// One developed version as plain values, so the viewer can render without touching SwiftData.
struct VersionSnapshot: Identifiable {
    let id: UUID
    let recipeName: String
    let filmSimulation: String?
    let clampedFields: [String]
    /// What the develop decided on the recipe's behalf — see `ConversionResult.notes`.
    let notes: [String]
    let isComparisonPreview: Bool
    let diagnostics: String?

    init(_ version: CookedVersion) {
        id = version.uuid
        recipeName = version.recipeName
        filmSimulation = version.filmSimulation
        clampedFields = version.clampedFields
        notes = version.notes
        isComparisonPreview = version.isComparisonPreview
        diagnostics = version.diagnostics
    }

    /// What the develop changed on the recipe's behalf, one line each: the fields it clamped,
    /// then its notes. Empty when it applied the recipe as written.
    var adjustments: [String] { Self.adjustments(clampedFields: clampedFields, notes: notes) }

    static func adjustments(clampedFields: [String], notes: [String]) -> [String] {
        let clamped = clampedFields.isEmpty
            ? []
            : ["Adjusted before developing: \(clampedFields.joined(separator: ", "))"]
        return clamped + notes
    }
}

/// How the versions are laid out.
enum ComparisonMode: String, CaseIterable, Identifiable {
    case swipe, curtain, tiled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .swipe: return "Swipe"
        case .curtain: return "A|B"
        case .tiled: return "Tiled"
        }
    }
}

/// Decoded images for a comparison, prepared once.
///
/// Reading `version.imageData` through the main context puts the full developed JPEG's read on the
/// main actor, and decoding it inside `body` repeats the decode on every pass. Each version is read
/// and decoded once by `DevelopedImageLoader`, off the main actor and straight to display size.
/// The inline 240px thumbnail stands in until the proxy lands.
@Observable
@MainActor
final class ComparisonImageStore {
    private var images: [UUID: UIImage] = [:]
    private var prepared: Set<UUID> = []
    /// Versions the library holds no displayable image for.
    private var unavailable: Set<UUID> = []

    /// Long edge of the display proxies. Comfortably above a phone's pixel width at full zoom, and
    /// far below a 40MP develop.
    nonisolated private static let proxyLongEdge: CGFloat = 2048

    func image(for id: UUID) -> UIImage? { images[id] }

    /// False once loading found no displayable image for the version; true until then, so Save
    /// and Share are offered while the proxy is still decoding.
    func isAvailable(_ id: UUID) -> Bool { !unavailable.contains(id) }

    /// Aspect ratio of the versions, for choosing a tiled layout. They are all the same frame, so
    /// the first one that has decoded speaks for the rest.
    var aspectRatio: CGFloat? {
        guard let size = images.values.first?.size, size.height > 0 else { return nil }
        return size.width / size.height
    }

    /// Show the cheap inline thumbnails immediately, so the first frame is never empty.
    func prime(_ versions: [CookedVersion]) {
        for version in versions where images[version.uuid] == nil {
            if let thumb = UIImage(data: version.thumbnailData) { images[version.uuid] = thumb }
        }
    }

    func load(_ ids: [UUID], with loader: DevelopedImageLoader) async {
        for id in ids where !prepared.contains(id) {
            prepared.insert(id)
            if let proxy = await loader.image(for: id, maxLongEdge: Self.proxyLongEdge) {
                images[id] = proxy
            } else {
                unavailable.insert(id)
            }
        }
    }
}

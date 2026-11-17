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

            captionBar
        }
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
        .photoExportPresentation(share: $shareItem, message: $saveMessage)
        .confirmationToast($savedConfirmation)
    }

    @State private var saver = ImageSaver()
    @State private var saveMessage: String?
    @State private var savedConfirmation: String?
    @State private var shareItem: ShareItem?

    /// The one place that reads the model. Everything else works off `versions`.
    private func prepare() async {
        let models = photo.sortedVersions
        filename = photo.sourceFilename
        versions = models.map(VersionSnapshot.init)
        if let initialVersionID, let index = versions.firstIndex(where: { $0.id == initialVersionID }) {
            selection = index
        }
        if pair.b >= models.count { pair = (0, min(1, max(0, models.count - 1))) }
        store.prime(models)
        await store.load(models)
    }

    // MARK: Modes

    private var swipeBody: some View {
        TabView(selection: $selection) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ComparisonPane(image: item.image, transform: $transform)
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
        if hasChoice {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(ComparisonMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if diagnosticMode, diagnosticsText != nil {
                Button { showDiagnostics = true } label: { Image(systemName: "stethoscope") }
                    .accessibilityLabel("Conversion diagnostics")
            }
            versionAction(systemImage: "square.and.arrow.up", verb: "Share", action: share)
            versionAction(systemImage: "square.and.arrow.down", verb: "Save", action: save)
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
        let usable = versions.filter(\.hasImage)
        if mode == .swipe || usable.count <= 1 {
            if let current, current.hasImage {
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

    @ViewBuilder
    private var captionBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch mode {
            case .swipe:
                if let version = current {
                    Text(version.recipeName).font(.headline)
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
        .padding()
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func detailLine(for version: VersionSnapshot, position: String?) -> some View {
        HStack(spacing: 8) {
            if let film = version.filmSimulation { Text(film) }
            if let position, versions.count > 1 { Text(position) }
            if version.isComparisonPreview { Text("Comparison preview") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        if !version.clampedFields.isEmpty {
            Text("Adjusted before developing: \(version.clampedFields.joined(separator: ", "))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        ForEach(version.notes, id: \.self) { note in
            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
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

    /// Resolve a snapshot back to its model. Only ever called from a button, never while rendering.
    private func model(for snapshot: VersionSnapshot) -> CookedVersion? {
        photo.sortedVersions.first { $0.uuid == snapshot.id }
    }

    private func outputFilename(_ version: VersionSnapshot) -> String {
        let base = (filename as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let recipe = version.recipeName.replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: allowed.inverted).joined()
        return "\(base.isEmpty ? "photo" : base)-\(recipe.isEmpty ? "recipe" : recipe).jpg"
    }

    private func save(_ version: VersionSnapshot) {
        // Save the original developed JPEG bytes so EXIF (camera, exposure, capture date…) is kept —
        // never the downsampled proxy the panes are drawn from.
        guard let data = model(for: version)?.imageData else { return }
        saver.save(data: data) { error in
            if let error { saveMessage = ImageSaver.message(for: error) } else { savedConfirmation = "Saved to Photos" }
        }
    }

    private func share(_ version: VersionSnapshot) {
        guard let data = model(for: version)?.imageData else { return }
        do {
            shareItem = try .temporaryFiles([(data, outputFilename(version))])
        } catch {
            saveMessage = ShareItem.preparationFailure(error)
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
    let hasImage: Bool
    let diagnostics: String?

    init(_ version: CookedVersion) {
        id = version.uuid
        recipeName = version.recipeName
        filmSimulation = version.filmSimulation
        clampedFields = version.clampedFields
        notes = version.notes
        isComparisonPreview = version.isComparisonPreview
        hasImage = !version.imageData.isEmpty
        diagnostics = version.diagnostics
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
/// Decoding `UIImage(data: version.imageData)` inside `body` puts the full developed JPEG on the
/// main actor on every body pass — survivable while exactly one is on screen, and not once three
/// are. Each version is decoded once, off the main actor, straight to display size by ImageIO
/// (`FrameRenderer.proxy`) rather than by materialising the full bitmap and throwing most of it
/// away. The inline 240px thumbnail stands in until the proxy lands.
@Observable
@MainActor
final class ComparisonImageStore {
    private var images: [UUID: UIImage] = [:]
    private var prepared: Set<UUID> = []

    /// Long edge of the display proxies. Comfortably above a phone's pixel width at full zoom, and
    /// far below a 40MP develop.
    nonisolated private static let proxyLongEdge: CGFloat = 2048

    func image(for id: UUID) -> UIImage? { images[id] }

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

    func load(_ versions: [CookedVersion]) async {
        for version in versions where !prepared.contains(version.uuid) {
            let id = version.uuid
            let data = version.imageData
            prepared.insert(id)
            guard !data.isEmpty else { continue }
            let proxy = await Task.detached(priority: .userInitiated) {
                FrameRenderer.proxy(from: data, maxLongEdge: Self.proxyLongEdge)
            }.value
            if let proxy { images[id] = proxy }
        }
    }
}

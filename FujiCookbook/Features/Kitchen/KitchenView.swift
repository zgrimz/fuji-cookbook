import SwiftUI
import SwiftData

/// The **Kitchen** hub: a launcher, but one that states its own structure.
///
/// Develop is the main pathway; Test Kitchen is a variant of it and Recent Results is its output;
/// Frame & Fit and Read Recipe have nothing to do with RAW, the camera, or cooking at all. Four
/// cards of near-identical weight would flatten those three relationships into one list of peers.
///
/// So: two zones. **Develop** holds the pathway with its variant and its results nested beneath it,
/// and **No camera needed** holds the two on-device tools, said once as a promise about a group
/// instead of twice as a caveat on individual cards.
///
/// The hub carries no camera *controls* — connecting, the not-connected banner and connection help
/// live in `DevelopView` and `TestKitchenView`, which are the only pathways that need a camera. It
/// does carry the camera's *state*, in one line, because speaking only with good news is worse
/// than silence: "Camera ready" when a camera is attached and nothing when one isn't makes the
/// first news of a missing camera an orange warning triangle on the next screen.
struct KitchenView: View {
    @Environment(CameraServices.self) private var camera
    @Environment(AppRouter.self) private var router

    @Environment(\.modelContext) private var modelContext

    /// How many photos have been developed, for the Recent Results count; nil until first counted.
    ///
    /// A `fetchCount` refreshed in `onAppear`, not a `@Query`: the query materialises every row, so
    /// its cost grows with each develop while the count's stays flat. iPhone 16 Pro, 2026-08-27,
    /// Release, median of 7, fresh context per rep:
    ///
    ///                     25 rows    250 rows
    ///     `@Query`         0.765ms    7.403ms
    ///     `fetchCount`     0.042ms    0.039ms
    ///
    /// `onAppear` fires on all three routes back to this hub — entering the tab, popping a pushed
    /// destination, and leaving the tab and returning — so a develop that finishes behind a push
    /// shows on the way back. A CloudKit sync that lands a photo while the hub is on screen shows at
    /// the next appearance.
    ///
    /// Nil is not zero: until the first count the row shows no badge and the subtitle for a
    /// non-empty history, so a full library never flashes the "nothing developed yet" copy.
    @State private var cookedCount: Int?

    /// Every push out of this hub, as values.
    ///
    /// Two independent entries for Frame & Fit — a `NavigationLink` on its card *and* a
    /// `navigationDestination(isPresented:)` for the share-card deep link — would stack a second
    /// copy when a deep link arrives while it is already pushed. A single `isPresented` flag is
    /// worse: an `isPresented` destination and a destination-form `NavigationLink` share one
    /// presentation slot per stack, so pushing Read Recipe and then leaving and re-entering the tab
    /// re-resolves that slot and puts **Frame & Fit** on screen instead. A typed path has neither
    /// failure: pushes are values, and the deep link assigns rather than appends.
    @State private var path: [Destination] = []

    private enum Destination: Hashable {
        case develop, testKitchen, recentResults, frameAndFit, readRecipe
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    zone("Develop") { developCard }
                    zone("No Camera Needed") { toolTiles }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle("Kitchen")
            .settingsToolbarItem()
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .develop: DevelopView()
                case .testKitchen: TestKitchenView()
                case .recentResults: SavedComparisonsView()
                case .frameAndFit: FrameAndFitView()
                case .readRecipe: ReadRecipeView()
                }
            }
            // The hub steps out of the way when a recipe asks for a share card: `onAppear` catches a
            // cold tab switch, `onChange` a warm one. `FrameAndFitView.applySeed` clears the seed.
            .onAppear {
                cookedCount = try? modelContext.fetchCount(FetchDescriptor<CookedPhoto>())
                if router.frameSeed != nil { openFrameAndFit() }
                if router.developSeed != nil { openDevelop() }
            }
            .onChange(of: router.frameSeed) { _, seed in
                if seed != nil { openFrameAndFit() }
            }
            .onChange(of: router.developSeed) { _, seed in
                if seed != nil { openDevelop() }
            }
        }
    }

    /// Land on Frame & Fit, replacing whatever the hub was showing rather than stacking onto it.
    /// The guard keeps a seed arriving while Frame & Fit is already open from rebuilding it and
    /// throwing away an in-progress composition.
    private func openFrameAndFit() {
        guard path.last != .frameAndFit else { return }
        path = [.frameAndFit]
    }

    /// Land on Develop, replacing whatever the hub was showing above it. `DevelopView` applies the
    /// seed when it appears, which includes being popped back to.
    private func openDevelop() {
        path = [.develop]
    }

    private func zone<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.SectionLabel(title).padding(.horizontal, 4)
            content()
        }
    }

    // MARK: Develop

    /// Develop, with its variant and its output nested inside the same card. Recent Results is
    /// where this pathway's work lands, not a fourth thing to do, and as a peer of Develop it would
    /// read like one.
    private var developCard: some View {
        VStack(spacing: 0) {
            NavigationLink(value: Destination.develop) {
                PathwayRow(icon: "wand.and.stars",
                           tint: Theme.amber,
                           tintSoft: Theme.amberSoft,
                           title: "Develop",
                           subtitle: "RAW files, developed on the camera itself.",
                           status: developStatus)
            }
            .buttonStyle(.plain)

            nestedDivider

            NavigationLink(value: Destination.testKitchen) {
                PathwayRow(icon: "square.grid.2x2",
                           tint: Theme.amber,
                           tintSoft: Theme.amberSoft,
                           title: "Test Kitchen",
                           subtitle: "Compare up to 3 recipes, side by side.",
                           nested: true)
            }
            .buttonStyle(.plain)

            nestedDivider

            NavigationLink(value: Destination.recentResults) {
                // Shown even with nothing developed, so the one place developed photos are kept can
                // be found before the first develop.
                PathwayRow(icon: "photo.stack",
                           tint: Theme.ink2,
                           tintSoft: Theme.paper2,
                           title: "Recent Results",
                           subtitle: cookedCount == 0 ? "Photos you develop land here."
                                                     : "Photos you've developed, newest first.",
                           count: cookedCount,
                           nested: true)
            }
            .buttonStyle(.plain)
        }
        .themedCard()
    }

    /// Indented past the parent row's icon tile, so the nesting is visible in the rule as well as in
    /// the text.
    private var nestedDivider: some View {
        Divider().overlay(Theme.line).padding(.leading, 50)
    }

    /// The camera, in one line, in every state — including the states that block a develop.
    private var developStatus: PathwayStatus {
        switch camera.session.status {
        case .connecting:
            return PathwayStatus(symbol: .icon("antenna.radiowaves.left.and.right"),
                                 tint: Theme.ink2, text: "Connecting…")
        case .working:
            return PathwayStatus(symbol: .icon("wand.and.stars"),
                                 tint: Theme.amber, text: "Developing…")
        case .connected, .failed, .disconnected:
            // A failed connection attempt leaves nothing connected, so it reads as "no camera"
            // rather than as an error the hub can do anything about — the reason and the retry both
            // live on the Develop screen and the Camera tab.
            guard camera.session.isConnected else {
                return PathwayStatus(symbol: .icon("cable.connector"),
                                     tint: Theme.ink2, text: "No camera connected")
            }
            let name = camera.session.connected?.model?.displayName
                ?? camera.session.connected?.productName ?? "Camera"
            guard camera.session.canConvert else {
                return PathwayStatus(symbol: .icon("lock.fill"),
                                     tint: Theme.amber,
                                     text: "RAW conversion isn't available for \(name)")
            }
            return PathwayStatus(symbol: .dot, tint: Theme.accent, text: "\(name) · Ready")
        }
    }

    // MARK: No camera needed

    private var toolTiles: some View {
        HStack(spacing: 10) {
            NavigationLink(value: Destination.frameAndFit) {
                ToolTile(icon: "square.on.square.dashed",
                         title: "Frame & Fit",
                         subtitle: "Borders, grids and carousels")
            }
            .buttonStyle(.plain)

            NavigationLink(value: Destination.readRecipe) {
                ToolTile(icon: "doc.text.magnifyingglass",
                         title: "Read Recipe",
                         subtitle: "The settings inside a JPEG")
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A pathway's current state, as one line under its subtitle.
///
/// Not a `note: String?` under one green checkmark — that can say "Camera ready" and nothing at all
/// about a camera that is missing.
private struct PathwayStatus {
    enum Symbol {
        case dot
        case icon(String)
    }

    let symbol: Symbol
    let tint: Color
    let text: String
}

/// One row in the Kitchen hub: icon tile, name, one line of what it's for, and an optional status
/// line or trailing count. `nested` renders the compact, indented variant used for a sub-pathway.
private struct PathwayRow: View {
    let icon: String
    let tint: Color
    let tintSoft: Color
    let title: String
    let subtitle: String
    var status: PathwayStatus?
    /// Trailing count, before the chevron. Omitted at zero — "0" is noise where absence says it.
    var count: Int?
    var nested = false

    private var tileSize: CGFloat { nested ? 32 : 44 }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: nested ? 9 : 12, style: .continuous)
                .fill(tintSoft)
                .frame(width: tileSize, height: tileSize)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: nested ? 14 : 19, weight: .medium))
                        .foregroundStyle(tint)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(nested ? .subheadline.weight(.semibold) : Theme.serif(.title3))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(nested ? .caption : .subheadline)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if let status { statusLine(status) }
            }

            Spacer(minLength: 4)

            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink3)
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, nested ? 12 : 16)
        // Indent past the parent's icon tile so a sub-pathway's text starts clear of its parent's.
        .padding(.leading, nested ? 34 : 0)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func statusLine(_ status: PathwayStatus) -> some View {
        HStack(spacing: 5) {
            switch status.symbol {
            case .dot:
                Circle()
                    .fill(status.tint)
                    .frame(width: 7, height: 7)
            case .icon(let name):
                Image(systemName: name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(status.tint)
            }
            Text(status.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(status.tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 1)
    }
}

/// One of the no-camera tools. Squarer and more prominent than a text row: Frame & Fit is the
/// largest thing in the Kitchen, and a text row would undersell it.
private struct ToolTile: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accentSoft)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.serif(.headline))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Both tiles fill the row's height so a two-line subtitle beside a one-line one doesn't
        // leave a short card next to a tall one.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .themedCard(cornerRadius: 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

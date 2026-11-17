import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// **Frame & Fit**: put a clean border around finished photos — a mat around one picture, a diptych
/// or grid of several, or a wide composition cut into carousel tiles.
///
/// The Kitchen's odd one out: no camera, no RAW, no recipe. It's here because it's the last step of
/// the same job — you develop a frame, then you frame it to post it.
///
/// Three deliberate calls about the shape of the screen:
///
/// - **No wizard.** How many photos and which ratio are both cheap to change and impossible to judge
///   without seeing them, so both live in the editor. Picking one photo or four is the same gesture
///   in the same picker.
/// - **The canvas is the primary control**, and "Simple" is the `.original` canvas rather than a
///   mode. Whether the border grows the canvas or eats into it is a consequence of the shape you
///   asked for, not a thing to understand up front.
/// - **Controls in tabs**, so the preview stays large. In a framing tool the canvas *is* the product.
///
/// The preview composites in SwiftUI from ~1600px proxies, so dragging a slider costs a relayout
/// rather than a re-render, and the full-resolution pass in `FrameRenderer` runs once, off the main
/// actor, only when the user exports.
struct FrameAndFitView: View {

    /// A picked photo: the original bytes (exported from, at full resolution), a small proxy the
    /// preview draws, and how the user has framed it inside its cell. The framing lives here rather
    /// than in `FrameOptions` so it travels with the photo when the set is reordered.
    private struct Source: Identifiable {
        let id = UUID()
        let data: Data
        let proxy: UIImage
        var slot: FrameRenderer.FrameSlot
    }

    /// Which control group the bottom panel is showing.
    ///
    /// One row, and it selects *which controls you are editing* — never what the canvas contains.
    /// A second row naming a mode (Frame / Recipe Card) would disagree with it about what
    /// the two are for: one switching the output, one switching the panel, and looking identical.
    /// The card is a control group like any other, and whether it is drawn is decided by the one
    /// thing that actually decides it — whether a recipe is chosen.
    private enum ControlTab: String, CaseIterable, Identifiable {
        case layout = "Layout"
        case style = "Style"
        case card = "Recipe Card"
        var id: String { rawValue }
    }

    /// What the next picker result should do with the photos it returns.
    private enum PickIntent: Equatable {
        case start          // first pick, from the empty state
        case add            // "+" in the photo strip
        case replace(Int)   // tapping an existing thumbnail
    }

    /// A gesture in flight, folded into the preview so it tracks the finger; the committed value
    /// only lands on gesture end. `index` is which photo the touch started on.
    private struct LiveGesture: Equatable {
        var index: Int
        var translation: CGSize = .zero
        var magnification: CGFloat = 1
    }

    /// The recipes a card can be built from. Frame & Fit is entered from the Kitchen with photographs
    /// and no recipe, so the card has to find one; a developed photo carries only its recipe's *name*
    /// (`CookedVersion.recipeName`), not its identity, so there is nothing to infer it from.
    @Query(Recipe.listFetch(sortBy: [SortDescriptor(\Recipe.updatedAt, order: .reverse)])) private var recipes: [Recipe]
    @Query private var chapters: [Chapter]
    @Environment(AppRouter.self) private var router

    @State private var sources: [Source] = []
    @State private var options = FrameOptions()
    @State private var controlTab: ControlTab = .layout

    /// The recipe card, if any. Lives here so the export has it without any editor being on screen.
    @State private var card = RecipeCard()

    // Resolved once per change by `refreshCard()`, never in `body` — see `resolveCardContent()`.
    @State private var cardContent: ShareCardContent?
    /// The recipe the card is on, held so the change-watcher below doesn't have to search the
    /// library for it on every pass through `body`.
    @State private var cardRecipeRef: Recipe?
    @State private var effectiveOptions = FrameOptions()
    @State private var styleFits: [ShareCardStyle: Bool] = [:]

    @State private var showPicker = false
    @State private var pickIntent: PickIntent = .start
    @State private var pickerSelection: [PhotosPickerItem] = []

    @State private var isLoading = false
    @State private var isExporting = false
    @State private var message: String?
    @State private var shareItem: ShareItem?
    @State private var saver = ImageSaver()

    @GestureState private var liveDrag: LiveGesture?
    @GestureState private var liveZoom: LiveGesture?

    /// How many photos the frame will take. A card with a plan may hold fewer than the frame itself
    /// does — Quarter Grid has three windows — and the picker shouldn't offer a fourth that has
    /// nowhere to go.
    private var photoCapacity: Int {
        min(FrameRenderer.maxPhotos, cardFramePlan?.photoCapacity ?? FrameRenderer.maxPhotos)
    }
    private var photosRemaining: Int { max(0, photoCapacity - sources.count) }

    var body: some View {
        Group {
            if sources.isEmpty {
                emptyState
            } else {
                editor
            }
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Frame & Fit")
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(isPresented: $showPicker,
                      selection: $pickerSelection,
                      maxSelectionCount: pickerLimit,
                      selectionBehavior: .ordered,
                      matching: .images,
                      photoLibrary: .shared())
        .onChange(of: pickerSelection) { _, items in
            guard !items.isEmpty else { return }
            let intent = pickIntent
            pickerSelection = []
            Task { await load(items, intent: intent) }
        }
        .photoExportPresentation(share: $shareItem, message: $message, title: "Frame & Fit")
    }

    /// The picker caps at what will still fit, so the user can't select more than the frame holds
    /// and then wonder which ones were dropped.
    private var pickerLimit: Int {
        switch pickIntent {
        case .start: return photoCapacity
        case .add: return max(1, photosRemaining)
        case .replace: return 1
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Frame a Photo", systemImage: "square.on.square.dashed")
        } description: {
            Text("Add a clean border, build a diptych, or split a wide photo across carousel tiles. Works with any photo — no camera needed.")
        } actions: {
            VStack(spacing: 10) {
                Button {
                    pickIntent = .start
                    showPicker = true
                } label: {
                    Label(isLoading ? "Loading…" : "Choose Photos", systemImage: "photo")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Theme.amber, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isLoading)

                Text("Pick up to \(photoCapacity) — they'll share one frame.")
                    .font(.footnote)
                    .foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            // The panel takes the height it needs and the preview gets the rest. Without the
            // priority the greedy preview squeezes the panel below its own minimum and the rows
            // start overlapping — on a smaller phone the controls are the thing that can't give.
            controls.layoutPriority(1)
        }
        // A thicker mat, a new ratio or a new arrangement all change how much crop there is to pan
        // across. Pull the stored offsets back in so the next drag doesn't start from a value the
        // layout is silently clamping.
        .onChange(of: options) { _, _ in
            reclampSlots()
            card.tile = card.tile.clamped(to: 0...max(0, options.tiles - 1))
            refreshCard()
        }
        .onChange(of: card) { _, _ in
            syncOptionsToCard()
            refreshCard()
            // The card may have changed which cells the photographs sit in.
            reclampSlots()
        }
        .onChange(of: cardRecipeStamp) { _, _ in refreshCard() }
        .onAppear {
            applySeed()
            refreshCard()
        }
        .onChange(of: sources.count) { _, _ in
            syncOptionsToPhotoCount()
            refreshCard()
        }
        .blockingProgress(isExporting ? "Rendering at full resolution…" : "Loading…",
                          isPresented: isLoading || isExporting)
    }

    /// The WYSIWYG canvas. `FrameRenderer.layout` is scale-invariant, so running it against the
    /// proxies' sizes and scaling the result to the available space gives exactly what will export.
    ///
    /// Laid out twice per frame: once from the committed slots, which fixes the canvas and the cell
    /// openings (neither depends on zoom or offset) and so gives the gesture a stable frame of
    /// reference, and once with the in-flight gesture folded in, which is what gets drawn.
    private var previewPane: some View {
        GeometryReader { geometry in
            let base = FrameRenderer.layout(slots: sources.map(\.slot), options: effectiveOptions)
            let available = CGSize(width: max(1, geometry.size.width), height: max(1, geometry.size.height))
            let scale = min(available.width / max(1, base.canvas.width),
                            available.height / max(1, base.canvas.height))
            let onScreen = CGSize(width: base.canvas.width * scale, height: base.canvas.height * scale)
            let live = FrameRenderer.layout(slots: liveSlots(base: base, scale: scale), options: effectiveOptions)

            canvasBody(layout: live, scale: scale)
                .overlay { cardLayer(layout: live, scale: scale) }
                .clipped()
                .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 0.5))
                .shadow(color: Color(red: 0.16, green: 0.13, blue: 0.06).opacity(0.18), radius: 10, y: 4)
                .contentShape(Rectangle())
                .gesture(repositionGesture(base: base, scale: scale, onScreen: onScreen))
                .frame(width: available.width, height: available.height)
        }
        .animation(.easeOut(duration: 0.18), value: options.canvas)
        .animation(.easeOut(duration: 0.18), value: options.tiles)
        .animation(.easeOut(duration: 0.18), value: options.arrangement)
    }

    private func canvasBody(layout: FrameRenderer.Layout, scale: CGFloat) -> some View {
        // The resolved background, not the user's: a paper card swaps the frame's own in, and on
        // Quarter Grid an empty window shows it, so the preview has to paint what the export will.
        FramePreview(proxies: sources.map(\.proxy), layout: layout, scale: scale,
                     background: effectiveOptions.background)
    }

    /// The recipe card in the preview: the same `ShareCardOverlay` the export rasterises, scaled to
    /// the screen, with hit-testing disabled so the drag underneath still pans the photograph.
    @ViewBuilder
    private func cardLayer(layout: FrameRenderer.Layout, scale: CGFloat) -> some View {
        if let active = activeCard,
           let content = cardContent,
           let metrics = ShareCardRenderer.metrics(card: active, content: content, layout: layout) {
            // The *same* rect the export draws into — the photo's opening for an overlay style, the
            // whole tile for a paper one. Taking the tile here while the metrics are resolved
            // against the opening makes the preview a lie: a card laid out for one box and centred
            // in a larger one, which floats the Story foot into the middle of the picture and puts
            // Plain's type out on the mat.
            let rect = ShareCardRenderer.rect(card: active, layout: layout)
            ShareCardOverlay(options: active.options, content: content, metrics: metrics)
                .equatable()
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: rect.width * scale, height: rect.height * scale, alignment: .topLeading)
                .position(x: (rect.midX) * scale, y: (rect.midY) * scale)
                .allowsHitTesting(false)
        }
    }

    // MARK: Reposition

    /// The committed slots with any in-flight gesture folded in. Translations are normalised by the
    /// on-screen size of the photo's *own cell*, so the stored offset is a resolution-independent
    /// fraction that means the same thing in a 2 × 2 grid as it does full-bleed.
    private func liveSlots(base: FrameRenderer.Layout, scale: CGFloat) -> [FrameRenderer.FrameSlot] {
        sources.enumerated().map { index, source in
            var slot = source.slot
            guard index < base.cells.count else { return slot }
            let opening = base.cells[index].opening
            if let drag = liveDrag, drag.index == index {
                slot.offset = CGSize(width: slot.offset.width + drag.translation.width / max(1, opening.width * scale),
                                     height: slot.offset.height + drag.translation.height / max(1, opening.height * scale))
            }
            if let zoom = liveZoom, zoom.index == index {
                slot.zoom = slot.zoom * zoom.magnification
            }
            return slot
        }
    }

    /// Drag to choose the crop, pinch to zoom into it — acting on whichever photo the touch landed
    /// on, so a grid needs no selection mode. The gesture is always live: `FrameRenderer` clamps the
    /// offset to exactly the crop that's hidden, which is zero when nothing is cropped, so at the
    /// `.original` canvas the photo simply doesn't move.
    private func repositionGesture(base: FrameRenderer.Layout, scale: CGFloat, onScreen: CGSize) -> some Gesture {
        let drag = DragGesture(minimumDistance: 2)
            .updating($liveDrag) { value, state, _ in
                guard let index = cellIndex(at: value.startLocation, base: base, scale: scale) else { return }
                state = LiveGesture(index: index, translation: value.translation)
            }
            .onEnded { value in
                guard let index = cellIndex(at: value.startLocation, base: base, scale: scale),
                      index < sources.count, index < base.cells.count else { return }
                let opening = base.cells[index].opening
                var slot = sources[index].slot
                slot.offset = CGSize(width: slot.offset.width + value.translation.width / max(1, opening.width * scale),
                                     height: slot.offset.height + value.translation.height / max(1, opening.height * scale))
                sources[index].slot = FrameRenderer.clamped(slot, opening: opening.size)
            }

        let magnify = MagnifyGesture()
            .updating($liveZoom) { value, state, _ in
                let point = CGPoint(x: value.startAnchor.x * onScreen.width,
                                    y: value.startAnchor.y * onScreen.height)
                guard let index = cellIndex(at: point, base: base, scale: scale) else { return }
                state = LiveGesture(index: index, magnification: value.magnification)
            }
            .onEnded { value in
                let point = CGPoint(x: value.startAnchor.x * onScreen.width,
                                    y: value.startAnchor.y * onScreen.height)
                guard let index = cellIndex(at: point, base: base, scale: scale),
                      index < sources.count, index < base.cells.count else { return }
                var slot = sources[index].slot
                slot.zoom = slot.zoom * value.magnification
                // A new zoom changes how far the photo may travel; re-clamp so the next drag doesn't
                // start from a value the layout is silently pulling back.
                sources[index].slot = FrameRenderer.clamped(slot, opening: base.cells[index].opening.size)
            }

        return SimultaneousGesture(drag, magnify)
    }

    /// Which photo a touch belongs to. A touch that lands on the mat rather than in an opening falls
    /// through to the nearest photo, so dragging near an edge still does the obvious thing.
    private func cellIndex(at point: CGPoint, base: FrameRenderer.Layout, scale: CGFloat) -> Int? {
        let cells = base.cells.prefix(sources.count)
        guard !cells.isEmpty else { return nil }

        func onScreen(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * scale, y: rect.minY * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }
        if let hit = cells.indices.first(where: { onScreen(cells[$0].opening).contains(point) }) {
            return hit
        }
        return cells.indices.min { a, b in
            distance(from: point, to: onScreen(cells[a].opening)) < distance(from: point, to: onScreen(cells[b].opening))
        }
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = point.x - rect.midX, dy = point.y - rect.midY
        return dx * dx + dy * dy
    }

    /// Pull every stored crop back inside what the current layout will honour.
    private func reclampSlots() {
        let layout = FrameRenderer.layout(slots: sources.map(\.slot), options: effectiveOptions)
        for index in sources.indices where index < layout.cells.count {
            sources[index].slot = FrameRenderer.clamped(sources[index].slot,
                                                        opening: layout.cells[index].opening.size)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            photoStrip

            Picker("Controls", selection: $controlTab) {
                ForEach(ControlTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            // A floor on the height so switching tabs doesn't bounce the preview above it.
            Group {
                switch controlTab {
                case .layout: layoutControls
                case .style: styleControls
                case .card: cardControls
                }
            }
            .frame(minHeight: 148, alignment: .top)

            outputRow

            HStack(spacing: 10) {
                Button { share() } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.paper2, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)

                Button { saveToPhotos() } label: {
                    Label(options.tiles > 1 ? "Save \(options.tiles) Images" : "Save to Photos",
                          systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.amber, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .disabled(isExporting)
            .opacity(isExporting ? 0.45 : 1)
        }
        .padding(16)
        .background(Theme.card.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    // MARK: Seeding

    /// Take up a request from the recipe screen, once.
    private func applySeed() {
        guard let seed = router.frameSeed else { return }
        router.frameSeed = nil
        card.recipeUUID = seed.recipeUUID
        controlTab = .card
    }

    /// When the card's recipe last changed, so an edit made elsewhere still redraws the card.
    /// Read from the held reference rather than by searching `recipes`: SwiftUI evaluates this on
    /// every pass to decide whether to fire, and a linear scan of the library there would put the
    /// whole store on the drag path.
    private var cardRecipeStamp: Date? { cardRecipeRef?.updatedAt }

    // MARK: Controls · Card tab

    /// The recipe on the card, resolved from its stable id.
    private var cardRecipe: Recipe? {
        guard let uuid = card.recipeUUID else { return nil }
        return recipes.first { $0.uuid == uuid }
    }

    /// What the card draws for the chosen recipe; nil when no recipe is chosen.
    ///
    /// `refreshCard()` holds the result in `cardContent`, along with `effectiveOptions` and
    /// `styleFits`, rather than `body` computing them on demand. These three are read several times
    /// per pass through `body`, and resolving a card measures every label and value in the ledger
    /// with Core Text to decide how many columns it can carry — a fifth of a millisecond each time.
    /// Recomputed per read, that comes to several milliseconds a frame while a finger is down, most
    /// of a 120 Hz frame before SwiftUI has drawn anything. None of it depends on the crop, so none
    /// of it belongs on the drag path.
    private func resolveCardContent() -> ShareCardContent? {
        guard let recipe = cardRecipe else { return nil }
        let number = chapters.lazy
            .compactMap { $0.recipeUUIDs.firstIndex(of: recipe.uuid) }
            .first
            .map { $0 + 1 }
        return ShareCardContent(recipe: recipe, recipeNumber: number)
    }

    /// The card is drawn exactly when a recipe is chosen for it — the recipe menu is the on/off
    /// switch, which is why that menu carries a "No Recipe Card" entry. Selecting the Recipe Card
    /// tab shows its controls and changes nothing about the output, the same as the other two tabs.
    private var activeCard: RecipeCard? { card.recipeUUID != nil ? card : nil }

    /// The layout the card dictates while it's on, if its style has one and the shape can hold it.
    /// While this is set the frame's grid, mat, gutter and carousel belong to the card, and the
    /// panels say so instead of offering controls that would do nothing.
    private var cardFramePlan: ShareCardFramePlan? {
        guard let active = activeCard, styleFits[active.options.style] ?? true else { return nil }
        return active.options.style.framePlan
    }

    /// Put the two options a plan overrides — and that the rest of the panel reads back — to what
    /// the plan needs. `.original` takes its shape from one photo and a grid is several, the rule
    /// `syncOptionsToPhotoCount` already applies; and a carousel of a grid card is nonsense.
    private func syncOptionsToCard() {
        guard cardFramePlan != nil else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            if !options.canvas.supportsMultiplePhotos { options.canvas = .post }
            options.tiles = 1
        }
    }

    /// The canvas shape the card will be resolved against, before the layout has run.
    private var cardAspect: CGFloat {
        if let aspect = options.canvas.tileAspect { return aspect }
        guard let size = sources.first?.slot.size, size.height > 0 else { return 4.0 / 5 }
        return size.width / size.height
    }

    /// Frame options with the card's paper bands folded in, which is what the preview and the export
    /// both lay out against. Everything else on the screen keeps working on `options` itself.
    ///
    /// Solved rather than calculated, because the two sides define each other: the band is a
    /// fraction of the canvas, and reserving it makes the canvas taller, which changes the fraction.
    /// A few passes settle it — each one shrinks the disagreement — and at the fixed point the hole
    /// the card leaves for the photograph and the cell the frame draws it into are the same
    /// rectangle. Skip this and they miss by a few percent, which shows up as a bare strip of paper
    /// between the picture and the words about it.
    private func resolveOptions(content: ShareCardContent?, fits: Bool) -> FrameOptions {
        var resolved = options
        guard let active = activeCard else { return resolved }

        // A plan is only applied for a card that will actually be drawn. A refused shape gets a
        // plain frame and the panel's note, not a grid with a hole where the recipe would go.
        if let plan = active.options.style.framePlan, fits {
            // The card dictates the grid: its mat, its gutter, and a cell held back for the recipe.
            // The frame's background only ever shows through a window with no photograph in it, so
            // it is the design's empty-slot paper rather than the card's own.
            resolved.arrangement = plan.arrangement
            resolved.border = plan.border
            resolved.gap = plan.gap
            resolved.reservedCells = plan.reservedCells
            resolved.tiles = 1
            if !resolved.canvas.supportsMultiplePhotos { resolved.canvas = .post }
            resolved.background = CardPalette.paper2
        } else if active.options.style.suppliesPaper {
            // The card is the mat here. Leaving the frame's border on as well would put a white
            // gutter between the photograph and the ledger that belongs to it, and the paper the
            // card draws would read as a second, mismatched margin.
            resolved.border = 0
            resolved.background = CardPalette.paper
        }

        let slots = sources.map(\.slot)
        var aspect = cardAspect
        for _ in 0..<5 {
            let bands = ShareCardRenderer.reservedBands(card: active, content: content, aspect: aspect)
            let settled = abs(bands.top - resolved.reservedTop) < 0.0005
                && abs(bands.bottom - resolved.reservedBottom) < 0.0005
            resolved.reservedTop = bands.top
            resolved.reservedBottom = bands.bottom
            if settled { break }
            let size = FrameRenderer.layout(slots: slots, options: resolved).tileSize
            guard size.height > 0 else { break }
            aspect = size.width / size.height
        }
        return resolved
    }

    /// True while the recipe card has taken the mat over, so the Style tab can say so instead of
    /// offering a border slider that does nothing.
    private var cardSuppliesPaper: Bool { activeCard?.options.style.suppliesPaper == true }

    @ViewBuilder
    private var cardControls: some View {
        VStack(spacing: 10) {
            recipeRow

            if card.recipeUUID != nil {
                cardStyleRow
                if card.options.style == .plain, cardFits { plainRow }
                if !cardFits {
                    Text("\(card.options.style.title) needs a taller frame than \(options.canvas.ratioText). "
                         + "Try \(card.options.style.nativeRatioText), or another style.")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let plan = cardFramePlan, sources.count > plan.photoCapacity {
                    Text("\(card.options.style.title) holds \(plan.photoCapacity) photos; the rest aren't drawn.")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Pick a recipe and its settings are laid over the frame. Leave it unset for a plain frame.")
                    .font(.footnote)
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Whether the chosen style can hold this recipe at this shape.
    private var cardFits: Bool { styleFits[card.options.style] ?? true }

    private func resolveStyleFits(content: ShareCardContent?) -> [ShareCardStyle: Bool] {
        guard let content else {
            return Dictionary(uniqueKeysWithValues: ShareCardStyle.allCases.map { ($0, true) })
        }
        // Any canvas of the right shape answers this: the card is scale-invariant, so whether it
        // fits depends on the proportions, not the pixels.
        return Dictionary(uniqueKeysWithValues: ShareCardStyle.allCases.map { style in
            // A style with a plan never lays out on `.original` — choosing it moves the canvas to
            // the default post — so it is probed at the shape it will actually take.
            let aspect = style.framePlan != nil && !options.canvas.supportsMultiplePhotos
                ? (FrameCanvas.post.tileAspect ?? cardAspect) : cardAspect
            let probe = CGSize(width: 1000, height: (1000 / aspect).rounded())
            return (style, style.metrics(canvas: probe, content: content) != nil)
        })
    }

    /// Recompute everything the card derives from the recipe and the frame. Cheap enough to run on
    /// any discrete change; far too expensive to run per frame.
    private func refreshCard() {
        cardRecipeRef = cardRecipe
        let content = resolveCardContent()
        cardContent = content
        styleFits = resolveStyleFits(content: content)
        effectiveOptions = resolveOptions(content: content, fits: styleFits[card.options.style] ?? true)
    }

    private var recipeRow: some View {
        HStack(spacing: 10) {
            Text("Recipe").font(.subheadline).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            Menu {
                // The way back off the card. This menu is the whole switch, so it has to be able to
                // say no as well as yes.
                if card.recipeUUID != nil {
                    Button(role: .destructive) { card.recipeUUID = nil } label: {
                        Label("No Recipe Card", systemImage: "xmark")
                    }
                    Divider()
                }
                ForEach(recipes) { recipe in
                    Button {
                        card.recipeUUID = recipe.uuid
                    } label: {
                        if recipe.uuid == card.recipeUUID {
                            Label(recipe.name, systemImage: "checkmark")
                        } else {
                            Text(recipe.name)
                        }
                    }
                }
                if recipes.isEmpty {
                    Text("No recipes in your library yet")
                }
            } label: {
                HStack(spacing: 5) {
                    Text(cardRecipe?.name ?? "Choose…")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold)).opacity(0.6)
                }
                .foregroundStyle(card.recipeUUID == nil ? Theme.accent : Theme.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Theme.paper2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .disabled(recipes.isEmpty)
        }
    }

    private var cardStyleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ShareCardStyle.allCases) { style in
                    // Dimmed rather than hidden when the shape can't hold it: a chip that vanishes
                    // as you change ratio reads as a bug, and the panel says why underneath.
                    let available = styleFits[style] ?? true
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { card.options.style = style }
                    } label: {
                        Text(style.title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(style == card.options.style ? Theme.accent : Theme.ink2)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(style == card.options.style ? Theme.accentSoft : Theme.paper2,
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(available ? 1 : 0.4)
                    .accessibilityAddTraits(style == card.options.style ? .isSelected : [])
                }
            }
        }
    }

    /// Plain's two extra decisions: which way the type runs, and which corner it sits in.
    private var plainRow: some View {
        HStack(spacing: 10) {
            Picker("Text", selection: $card.options.tone) {
                ForEach(PlainTone.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            PlainCornerPicker(selection: $card.options.corner)
        }
    }

    // MARK: Controls · Layout tab

    @ViewBuilder
    private var layoutControls: some View {
        VStack(spacing: 10) {
            canvasPresets

            // No section labels here: each control says what it is in its own options, and the
            // panel has to share a phone screen with the thing it's editing.
            if let plan = cardFramePlan {
                // The grid and the carousel are the card's while it's on; say so rather than show
                // controls that would do nothing.
                Text("\(card.options.style.title) sets the layout: \(plan.photoCapacity) photos on a "
                     + "\(plan.arrangement.rows) × \(plan.arrangement.columns) grid, with the recipe in the first cell.")
                    .font(.footnote)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                repositionHint
            } else {
                if options.canvas.supportsTiles {
                    Picker("Carousel", selection: $options.tiles) {
                        Text("1 image").tag(1)
                        Text("2 tiles").tag(2)
                        Text("3 tiles").tag(3)
                    }
                    .pickerStyle(.segmented)
                }

                if sources.count > 1 {
                    arrangementPresets
                }

                if options.tiles > 1 {
                    Text("Exported as \(options.tiles) images. Post them as a carousel in order — the photo runs across the seams.")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    repositionHint
                }
            }
        }
    }

    private var canvasPresets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(FrameCanvas.allCases) { canvas in
                    // `.original` is one photo's own shape, so it's off for a set — and for a card
                    // whose plan makes one photo into a grid.
                    let enabled = canvas.supportsMultiplePhotos || (sources.count == 1 && cardFramePlan == nil)
                    CanvasChip(canvas: canvas, selected: options.canvas == canvas) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            options.canvas = canvas
                            if !canvas.supportsTiles { options.tiles = 1 }
                            // A new ratio means a new crop; the old reposition no longer maps onto it.
                            recenterAll()
                        }
                    }
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.35)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private var arrangementPresets: some View {
        HStack(spacing: 8) {
            ForEach(FrameArrangement.options(for: sources.count)) { arrangement in
                ArrangementChip(arrangement: arrangement, selected: options.arrangement == arrangement) {
                    withAnimation(.easeOut(duration: 0.18)) { options.arrangement = arrangement }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var repositionHint: some View {
        if sources.contains(where: { $0.slot.isRepositioned }) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { recenterAll() }
            } label: {
                Label("Recenter All", systemImage: "arrow.counterclockwise")
                    .font(.footnote.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        } else if options.canvas != .original {
            Text(sources.count > 1 ? "Drag a photo to choose its crop, pinch to zoom in."
                                   : "Drag to choose the crop, pinch to zoom in.")
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
        }
    }

    // MARK: Controls · Style tab

    private var styleControls: some View {
        VStack(spacing: 14) {
            if cardFramePlan != nil {
                Text("\(card.options.style.title) brings its own paper and grid, so the frame's border "
                     + "and gap are set aside while it's on.")
                    .font(.footnote)
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if cardSuppliesPaper {
                Text("\(card.options.style.title) brings its own paper, so the frame's border is set "
                     + "aside while it's on.")
                    .font(.footnote)
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                percentSlider(title: "Border", value: $options.border, range: FrameRenderer.borderRange)
            }
            if sources.count > 1, cardFramePlan == nil {
                percentSlider(title: "Gap", value: $options.gap, range: FrameRenderer.gapRange)
            }
            backgroundRow
            // No trailing Spacer: the panel has layout priority, so a greedy spacer here would
            // claim the whole screen and leave the preview a sliver. The Group's minHeight is what
            // keeps the two tabs from bouncing.
        }
    }

    // MARK: Controls · Helpers

    private func percentSlider(title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
            }
            Slider(value: value, in: range, step: 0.01)
                .tint(Theme.amber)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) percent")
        }
    }

    private var backgroundRow: some View {
        HStack(spacing: 10) {
            Text("Background").font(.subheadline).foregroundStyle(Theme.ink)
            Spacer()
            swatch(.white, name: "White")
            swatch(.black, name: "Black")
            ColorPicker("Custom background color", selection: $options.background, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30, height: 30)
        }
    }

    private func swatch(_ color: Color, name: String) -> some View {
        SwatchButton(color: color, name: name, current: options.background) { options.background = color }
    }

    // MARK: Controls · Photo strip

    /// Where the *set* is managed: tap to replace, × to remove, drag to reorder, + to add. Keeping
    /// this out of the canvas means the canvas is only ever about framing.
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    PhotoThumb(image: source.proxy,
                               position: index + 1,
                               showsPosition: sources.count > 1,
                               onTap: {
                                   pickIntent = .replace(index)
                                   showPicker = true
                               },
                               onRemove: { remove(at: index) })
                        .draggable(source.id.uuidString)
                        .dropDestination(for: String.self) { payload, _ in
                            guard let raw = payload.first, let id = UUID(uuidString: raw) else { return false }
                            return move(id: id, to: index)
                        }
                }

                if photosRemaining > 0 {
                    Button {
                        pickIntent = .add
                        showPicker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                            .foregroundStyle(Theme.ink2)
                            .frame(width: 52, height: 52)
                            .background(Theme.paper2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add another photo")
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    // MARK: The exported dimensions, live

    /// The visible proof of the no-downsampling promise — the numbers only shrink when a canvas is
    /// extreme enough to hit `maxTilePixels`. With tiles it also states the deliverable plainly:
    /// this is not one image, it's several.
    private var outputRow: some View {
        let layout = FrameRenderer.layout(slots: sources.map(\.slot), options: effectiveOptions)
        let tile = layout.tileSize

        return HStack(spacing: 6) {
            Image(systemName: layout.tiles > 1 ? "square.grid.3x1.below.line.grid.1x2" : "arrow.up.left.and.arrow.down.right")
            if layout.tiles > 1 {
                Text("\(layout.tiles) images ·")
            }
            // Verbatim: pixel dimensions read as dimensions, not as grouped quantities.
            Text(verbatim: "\(Int(tile.width)) × \(Int(tile.height)) px")
                .monospacedDigit()
            if layout.tiles > 1 {
                Text("each")
            }
            if layout.wasCapped {
                Text("· scaled to stay within memory")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(Theme.ink3)
    }

    // MARK: Managing the set

    private func remove(at index: Int) {
        guard sources.indices.contains(index) else { return }
        withAnimation(.easeOut(duration: 0.18)) { _ = sources.remove(at: index) }
    }

    private func move(id: UUID, to index: Int) -> Bool {
        guard let from = sources.firstIndex(where: { $0.id == id }), from != index,
              sources.indices.contains(index) else { return false }
        withAnimation(.easeOut(duration: 0.18)) {
            let source = sources.remove(at: from)
            sources.insert(source, at: min(index, sources.count))
        }
        return true
    }

    private func recenterAll() {
        for index in sources.indices {
            sources[index].slot.zoom = 1
            sources[index].slot.offset = .zero
        }
    }

    /// Keep the options coherent with how many photos there now are. `.original` takes its shape
    /// from *the* photo, so it only means anything for one; and every arrangement holds exactly the
    /// current count, so adding or removing a photo always needs a new one.
    private func syncOptionsToPhotoCount() {
        guard !sources.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            if sources.count > 1 && !options.canvas.supportsMultiplePhotos {
                options.canvas = .post
            }
            if !FrameArrangement.options(for: sources.count).contains(options.arrangement) {
                options.arrangement = FrameArrangement.best(for: sources.map(\.slot.size))
            }
            if !options.canvas.supportsTiles { options.tiles = 1 }
        }
    }

    // MARK: Loading

    @MainActor
    private func load(_ items: [PhotosPickerItem], intent: PickIntent) async {
        isLoading = true
        defer { isLoading = false }

        var loaded: [Source] = []
        for item in items.prefix(FrameRenderer.maxPhotos) {
            if let source = await makeSource(item) { loaded.append(source) }
        }
        guard !loaded.isEmpty else {
            message = items.count == 1 ? "That photo couldn't be opened."
                                       : "Those photos couldn't be opened."
            return
        }

        switch intent {
        case .start:
            sources = loaded
            options.arrangement = FrameArrangement.best(for: loaded.map(\.slot.size))
            if loaded.count > 1 { options.canvas = .post }
        case .add:
            sources.append(contentsOf: loaded.prefix(photosRemaining))
        case .replace(let index):
            guard let replacement = loaded.first else { return }
            if sources.indices.contains(index) {
                sources[index] = replacement
            } else {
                sources.append(replacement)
            }
        }

        if loaded.count < items.count {
            message = "\(items.count - loaded.count) of those photos couldn't be opened."
        }
    }

    private func makeSource(_ item: PhotosPickerItem) async -> Source? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        // Proxy generation decodes the file; keep it off the main actor so the picker dismisses cleanly.
        let prepared = await Task.detached(priority: .userInitiated) { () -> (UIImage, CGSize)? in
            guard let proxy = FrameRenderer.proxy(from: data) else { return nil }
            return (proxy, FrameRenderer.pixelSize(of: data) ?? proxy.size)
        }.value
        guard let prepared else { return nil }
        return Source(data: data, proxy: prepared.0,
                      slot: FrameRenderer.FrameSlot(size: prepared.1))
    }

    // MARK: Export

    /// Full-resolution composite, off the main actor. One export per tile, in posting order.
    ///
    /// The type has to be laid out first, on this actor: `ImageRenderer` is main-actor only, and
    /// that's the point — running the export's type through the same SwiftUI view the preview draws
    /// is what makes them agree. Only the card's own box gets rasterised, so this stays small.
    @MainActor
    private func render() async -> [FrameRenderer.Export]? {
        let data = sources.map(\.data)
        let slots = sources.map(\.slot)
        let options = effectiveOptions
        let layout = FrameRenderer.layout(slots: slots, options: options)
        // `FrameRenderer` knows nothing about recipes; the card reaches it as a plain overlay.
        let overlays: [FrameRenderer.Overlay]
        do {
            overlays = try activeCard
                .flatMap { try ShareCardRenderer.layer(card: $0, content: cardContent, layout: layout) }
                .map { [$0] } ?? []
        } catch {
            AppLog.error(.kitchen, "Frame & Fit: the recipe card didn't rasterise, so nothing was exported")
            return nil
        }

        return await Task.detached(priority: .userInitiated) {
            FrameRenderer.render(sources: data, slots: slots, options: options, overlays: overlays)
        }.value
    }

    private func saveToPhotos() {
        Task {
            isExporting = true
            defer { isExporting = false }
            guard let exports = await render(), let first = exports.first else {
                message = "Couldn't render the framed photo."
                return
            }
            // Sequentially, so the assets land in the photo library in posting order.
            for export in exports {
                if let error = await save(export.jpeg) {
                    message = ImageSaver.message(for: error)
                    return
                }
            }

            let dimensions = "\(Int(first.size.width)) × \(Int(first.size.height))"
            let saved = exports.count > 1
                ? "Saved \(exports.count) images (\(dimensions) each) to your photo library. "
                    + "Post them as a carousel in the order they were saved."
                : "Saved \(dimensions) to your photo library."
            message = saved + (first.wasCapped
                ? " The canvas was scaled down slightly to stay within memory." : "")
        }
    }

    private func save(_ data: Data) async -> Error? {
        await withCheckedContinuation { continuation in
            saver.save(data: data) { continuation.resume(returning: $0) }
        }
    }

    private func share() {
        Task {
            isExporting = true
            defer { isExporting = false }
            guard let exports = await render() else {
                message = "Couldn't render the framed photo."
                return
            }
            do {
                shareItem = try .temporaryFiles(exports.map { ($0.jpeg, filename(for: $0)) })
            } catch {
                message = ShareItem.preparationFailure(error)
            }
        }
    }

    private func filename(for export: FrameRenderer.Export) -> String {
        let base: String
        switch options.canvas {
        case .original:
            base = "Framed-\(Int((options.border * 100).rounded()))pct"
        default:
            // "1.91:1" -> "1-91x1": the colon is illegal in a filename and the dot would read as an
            // extension boundary to anything downstream that parses the name rather than the UTI.
            base = "Framed-" + options.canvas.ratioText
                .replacingOccurrences(of: ":", with: "x")
                .replacingOccurrences(of: ".", with: "-")
        }
        // Numbered so the carousel order survives a trip through Files, Mail or AirDrop.
        return export.count > 1 ? "\(base)-\(export.index)of\(export.count).jpg" : "\(base).jpg"
    }
}

// MARK: - Canvas

/// The framed composition, drawn from proxies.
///
/// Deliberately knows nothing about type. The recipe card is drawn as its own layer on top, and
/// that separation is a performance boundary as much as a design one: if the backdrop took the
/// card as input, every change to it would invalidate this view and force the photo —
/// high-quality interpolation, clipping and drop shadow included — to be re-rendered along with
/// it. With stable inputs SwiftUI skips the whole subtree instead.
struct FramePreview: View {
    let proxies: [UIImage]
    let layout: FrameRenderer.Layout
    let scale: CGFloat
    let background: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(background)

            ForEach(Array(proxies.enumerated()), id: \.offset) { index, proxy in
                if index < layout.cells.count, !layout.cells[index].image.isNull {
                    let cell = layout.cells[index]
                    // Two nested frames: the inner one sizes the photo (which overflows when
                    // cropped), the outer is the opening that clips it. Mirrors the renderer exactly.
                    Image(uiImage: proxy)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: cell.image.width * scale, height: cell.image.height * scale)
                        .offset(x: (cell.image.minX - cell.opening.minX) * scale,
                                y: (cell.image.minY - cell.opening.minY) * scale)
                        .frame(width: cell.opening.width * scale,
                               height: cell.opening.height * scale,
                               alignment: .topLeading)
                        .clipped()
                        .offset(x: cell.opening.minX * scale, y: cell.opening.minY * scale)
                }
            }

            // Where the export cuts. Nothing is drawn here on export — it's a guide, so the user can
            // see what lands in which post before committing.
            ForEach(Array(layout.seams.enumerated()), id: \.offset) { _, seam in
                SeamMarker(height: layout.canvas.height * scale)
                    .offset(x: seam * scale - 0.5)
            }

        }
        .frame(width: layout.canvas.width * scale, height: layout.canvas.height * scale)
        // A passive backdrop. Its background rectangle is otherwise a hit-testable surface that
        // swallows every tap before the owning screen's own layers see one.
        .allowsHitTesting(false)
    }
}

// MARK: - Seam marker

/// The line an export will be cut along. Drawn as white dashes over a dark hairline so it reads on
/// any photo, without a blend mode that would have to survive the canvas's shadow and clipping.
/// A real dashed stroke rather than a stack of rectangles, so the dashes reach the bottom edge at
/// any canvas height instead of leaving a bare tail in the mat.
struct SeamMarker: View {
    let height: CGFloat

    var body: some View {
        let line = Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: height))
        }
        return ZStack {
            line.stroke(Color.black.opacity(0.35), lineWidth: 1)
            line.stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
        }
        .frame(width: 1, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Photo strip thumbnail

private struct PhotoThumb: View {
    let image: UIImage
    let position: Int
    let showsPosition: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            .overlay(alignment: .bottomLeading) {
                if showsPosition {
                    Text("\(position)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove photo \(position)")
                .offset(x: 5, y: -5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(showsPosition ? "Photo \(position)" : "Photo")
            .accessibilityHint("Double tap to swap in a different photo")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Preset chips

/// A `FrameCanvas` preset, drawn as a miniature of the canvas itself — a true-to-ratio glyph reads
/// faster than any icon, and can't drift out of sync with the numbers. The glyph shows one *tile*:
/// the tile is the post, and the preview above already shows how the tiles join up.
private struct CanvasChip: View {
    let canvas: FrameCanvas
    let selected: Bool
    let action: () -> Void

    private var glyph: CGSize {
        let edge: CGFloat = 24
        let aspect = canvas.glyphAspect(tiles: 1)
        return aspect >= 1 ? CGSize(width: edge, height: edge / aspect)
                           : CGSize(width: edge * aspect, height: edge)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(selected ? Theme.onAccent : Theme.ink3)
                    .frame(width: glyph.width, height: glyph.height)
                    .frame(width: 26, height: 26)
                Text(canvas.label)
                    .font(.caption2.weight(.semibold))
                Text(canvas.ratioText)
                    .font(.caption2)
                    .monospacedDigit()
                    .opacity(0.7)
            }
            .foregroundStyle(selected ? Theme.onAccent : Theme.ink2)
            .frame(width: 74)
            .padding(.vertical, 9)
            .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.paper2),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if !selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(canvas.label), \(canvas.ratioText)")
        .accessibilityHint(canvas.use)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An arrangement, drawn as the grid it is. Same reasoning as `CanvasChip`: the shape is the label.
private struct ArrangementChip: View {
    let arrangement: FrameArrangement
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                VStack(spacing: 2) {
                    ForEach(0..<arrangement.rows, id: \.self) { _ in
                        HStack(spacing: 2) {
                            ForEach(0..<arrangement.columns, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 1, style: .continuous)
                                    .fill(selected ? Theme.onAccent : Theme.ink3)
                            }
                        }
                    }
                }
                .frame(width: 18, height: 18)

                Text(arrangement.label)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(selected ? Theme.onAccent : Theme.ink2)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.paper2),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                if !selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.line)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(arrangement.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

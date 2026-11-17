import SwiftUI
import SwiftData
import UIKit

/// Read-only view of a saved recipe — the parameters it sets, its notes, which cameras run it and
/// its slot name — with its actions.
struct RecipeDetailView: View {
    @Bindable var recipe: Recipe
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(CameraServices.self) private var camera
    @Environment(AppRouter.self) private var router

    @State private var showingEditor = false
    @State private var showingDeleteConfirm = false
    @State private var shareItem: ShareItem?
    @State private var exportError: String?
    @State private var exportRunner = RecipeExportRunner()
    @State private var showingPush = false
    @State private var viewerIndex: Int?
    @State private var showingExportOptions = false
    @State private var showingCompare = false
    @State private var heroIndex = 0

    private var listRows: [(field: RecipeField, value: String)] {
        RecipeSettingsFormatter.rows(for: recipe.settings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroPhotos
                titleBlock

                if !listRows.isEmpty {
                    Theme.SectionLabel("Recipe Parameters")
                        .padding(.top, 18)
                        .padding(.bottom, 8)
                        .padding(.horizontal, 4)
                    parameterCard
                }

                Theme.SectionLabel("Works With")
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                    .padding(.horizontal, 4)
                RecipeWorksWithCard(settings: recipe.settings,
                                    hasPreservedFields: recipe.hasPreservedUnsupportedFields)

                if !recipe.notes.isEmpty {
                    Theme.SectionLabel("Notes")
                        .padding(.top, 18)
                        .padding(.bottom, 8)
                        .padding(.horizontal, 4)
                    Text(recipe.notes)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .themedCard(cornerRadius: 16)
                }

                if !recipe.tags.isEmpty {
                    ChipFlow(spacing: 6) {
                        ForEach(recipe.tags, id: \.self) { ParamChip(text: "#\($0)") }
                    }
                    .padding(.top, 14)
                }

                if recipe.hasPreservedUnsupportedFields {
                    preservedFieldsCard
                        .padding(.top, 18)
                }

                Theme.SectionLabel("Camera")
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                    .padding(.horizontal, 4)
                cameraSlotCard

                pushBar
                    .padding(.top, 18)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(Theme.paper.ignoresSafeArea())
        // The big serif name lives in the content; keep the bar title empty so it
        // doesn't appear twice.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { recipe.isFavorite.toggle(); recipe.touch() } label: {
                    Image(systemName: recipe.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(recipe.isFavorite ? Theme.star : .secondary)
                }
                .accessibilityLabel(recipe.isFavorite ? "Unfavorite" : "Favorite")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingEditor = true } label: { Label("Edit", systemImage: "pencil") }
                    Button { duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    // "Compare Settings", not "Compare": the Kitchen already offers to compare
                    // recipes, and means the developed images. This is the parameters.
                    Button { showingCompare = true } label: {
                        Label("Compare Settings…", systemImage: "arrow.left.arrow.right")
                    }
                    // The two sharing actions read as a pair: the visual card, then the file.
                    Button { openShareCard() } label: {
                        Label("Share Card…", systemImage: "photo.on.rectangle.angled")
                    }
                    Button { initiateShare() } label: { Label("Share / Export", systemImage: "square.and.arrow.up") }
                    Divider()
                    Button(role: .destructive) { showingDeleteConfirm = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(isPresented: $showingCompare) {
            RecipeCompareView(recipeA: recipe)
        }
        .sheet(isPresented: $showingEditor) {
            NavigationStack { RecipeEditorView(recipe: recipe, isNew: false) }
        }
        .sheet(item: $shareItem) { ShareSheet(items: $0.urls) }
        .sheet(isPresented: $showingPush) {
            NavigationStack { PushView(preselectedRecipe: recipe) }
        }
        .fullScreenCover(isPresented: Binding(isPresent: $viewerIndex)) {
            PhotoViewerView(photos: recipe.sortedPhotos, selection: viewerIndex ?? 0)
        }
        .confirmationDialog("Share Recipe", isPresented: $showingExportOptions, titleVisibility: .visible) {
            Button("Include Sample Photos") { share(includePhotos: true) }
            Button("Recipe Only") { share(includePhotos: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Embedding photos makes the shared file larger.")
        }
        .confirmationDialog("Delete “\(recipe.name)”?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Recipe", role: .destructive) {
                modelContext.delete(recipe)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .alert("Export Failed", isPresented: Binding(isPresent: $exportError)) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
        .exportProgress(exportRunner)
    }

    // MARK: Building blocks

    /// Paged hero of sample photos; tap opens the full viewer.
    ///
    /// Draws from `imageData`, not `thumbnailData`: the hero is full-width, so on a 3x phone it needs
    /// ~1200 device pixels across; the 240px thumbnail blown up 5× looks visibly grainy next to the
    /// crisp full-screen viewer.
    @ViewBuilder
    private var heroPhotos: some View {
        let photos = recipe.sortedPhotos
        if !photos.isEmpty {
            TabView(selection: $heroIndex) {
                ForEach(Array(photos.enumerated()), id: \.element.uuid) { index, photo in
                    if let image = UIImage(data: photo.imageData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 190)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { viewerIndex = index }
                            .accessibilityLabel("Sample photo \(index + 1)")
                            .accessibilityAddTraits(.isButton)
                            .tag(index)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.bottom, 14)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recipe.name)
                .font(Theme.serif(28))
                .foregroundStyle(Theme.ink)
            // Film Simulation reads from the parameters list below, so this row is free for
            // attribution — the thing you look at right after the name to see whose recipe this is.
            // The camera profile is not here: it is the editor's field filter, not a verdict, and
            // the Works With card says which bodies run the recipe.
            if let credit = recipe.displayCredit {
                Text("Recipe by \(credit)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var parameterCard: some View {
        SettingsTable(rows: listRows)
    }

    /// What the camera will actually show for this recipe, immediately above the button that sends
    /// it. Grey when the name is the generated default, ink when the user set it themselves — the
    /// same distinction the editor draws with a placeholder.
    private var cameraSlotCard: some View {
        let name = recipe.effectiveCameraName
        let isCustom = recipe.hasCustomCameraName
        return VStack(spacing: 0) {
            HStack {
                Text("Slot Name")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink2)
                Spacer()
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCustom ? Theme.ink : Theme.ink3)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isCustom ? "Camera slot name, \(name)"
                                         : "Camera slot name, \(name), from the recipe name")
        }
        .themedCard(cornerRadius: 16)
    }

    private var preservedFieldsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Preserved Fields", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.warning)
            ForEach(recipe.unsupportedFields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                HStack {
                    Text(key).font(.subheadline).foregroundStyle(Theme.ink2)
                    Spacer()
                    Text(value.displayString).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                }
            }
            Text("These came from another camera or app version, or from a camera that reported a value Fuji Cookbook doesn't recognize. Either way they're kept intact and re-exported unchanged, so nothing is silently lost — but they can't be shown properly or pushed back to a camera.")
                .font(.caption)
                .foregroundStyle(Theme.ink3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(cornerRadius: 16)
    }

    /// Push needs a connected body that we're allowed to write to, whose slot walk didn't fail — the
    /// same gate the Camera tab's Push tile uses, so the two screens never disagree about whether a
    /// push can happen.
    private var canPush: Bool { camera.slotWriter.canPush }

    /// The screen's primary action, always shown rather than kept in a list row. Dimmed and inert
    /// while a push can't happen, with a line underneath saying why, so a tap on a dead button is
    /// never the way the user finds out.
    private var pushBar: some View {
        VStack(spacing: 8) {
            Button { showingPush = true } label: {
                Label("Push to Camera", systemImage: canPush ? "arrow.up.to.line" : "cable.connector.slash")
                    .font(.headline)
                    .foregroundStyle(canPush ? Theme.onAccent : Theme.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(canPush ? Theme.accent : Theme.paper2,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        if !canPush {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(!canPush)
            pushHint
        }
    }

    /// Why the button is dim, and — when it's just a missing connection — the way to fix it.
    @ViewBuilder
    private var pushHint: some View {
        if !camera.session.isConnected {
            Button {
                router.selectedTab = .camera
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cable.connector")
                    Text("No camera connected.")
                    Text("Connect in the Camera tab")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.accent)
                }
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("No camera connected. Connect in the Camera tab.")
        } else if !canPush {
            Text(camera.slotWriter.pushBlockReason ?? "Push isn't available for \(camera.session.model?.displayName ?? "this camera").")
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    /// Hand Frame & Fit this recipe and switch to the Kitchen. The photographs are picked there:
    /// a share card is framed like any other post, so it gets the same canvases, crops and carousel
    /// tiles as the rest of the tool rather than a second, weaker copy of them.
    private func openShareCard() {
        router.frameSeed = FrameSeed(recipeUUID: recipe.uuid)
        router.selectedTab = .kitchen
    }

    private func duplicate() {
        let copy = Recipe(name: "\(recipe.name) Copy",
                          cameraName: recipe.cameraName,
                          notes: recipe.notes,
                          tags: recipe.tags,
                          isFavorite: false,
                          credit: recipe.credit,
                          authoredForModelID: recipe.authoredForModelID,
                          settings: recipe.settings,
                          unsupportedFields: recipe.unsupportedFields)
        modelContext.insert(copy)
        for photo in recipe.sortedPhotos {
            let copiedPhoto = RecipePhoto(imageData: photo.imageData,
                                          thumbnailData: photo.thumbnailData,
                                          sortOrder: photo.sortOrder)
            copiedPhoto.recipe = copy
            modelContext.insert(copiedPhoto)
        }
    }

    /// Ask whether to embed photos when the recipe has any; otherwise export straight away.
    private func initiateShare() {
        if recipe.sortedPhotos.isEmpty { share(includePhotos: false) }
        else { showingExportOptions = true }
    }

    private func share(includePhotos: Bool) {
        exportRunner.start(.single(recipe, includePhotos: includePhotos), named: recipe.name) { result in
            switch result {
            case .success(let url): shareItem = ShareItem(url: url)
            case .failure(let error): exportError = error.localizedDescription
            }
        }
    }
}

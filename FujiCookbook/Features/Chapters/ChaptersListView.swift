import SwiftUI
import SwiftData

/// Browse, create, and delete Chapters — ordered sets of up to `Chapter.maxSlots` recipes pushed to
/// the camera's custom slots in one go. Fully usable offline; pushing happens from a chapter's detail.
struct ChaptersListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Chapter.updatedAt, order: .reverse) private var chapters: [Chapter]
    @Query(Recipe.listFetch()) private var recipes: [Recipe]

    @State private var editTarget: Identified<Chapter>?
    @State private var splitSelection: PersistentIdentifier?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var isSplit: Bool { horizontalSizeClass == .regular }

    /// Fast lookup from a recipe's stable uuid to the recipe, for slot summaries.
    private var recipesByUUID: [UUID: Recipe] {
        Dictionary(recipes.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        if isSplit {
            // Balanced + visible-at-launch so the list shares the screen with the detail even on
            // the narrowest iPads (mini portrait) instead of hiding behind the sidebar toggle.
            NavigationSplitView(columnVisibility: $columnVisibility) {
                chaptersColumn
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380)
                    // iPadOS 26 hides this toggle under the tab pill; see LibraryView.
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                detailColumn
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack {
                chaptersColumn
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let id = splitSelection, let chapter = chapters.first(where: { $0.persistentModelID == id }) {
            NavigationStack { ChapterDetailView(chapter: chapter) }
        } else {
            ContentUnavailableView {
                Label("Select a Chapter", systemImage: "books.vertical")
            } description: {
                Text("Pick a chapter on the left to see its slots.")
            }
            .background(Theme.paper.ignoresSafeArea())
        }
    }

    private var chaptersColumn: some View {
        Group {
            if chapters.isEmpty {
                emptyState
            } else {
                chapterList
            }
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Chapters")
        .settingsToolbarItem()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { createChapter() } label: { Label("New Chapter", systemImage: "plus") }
            }
        }
        .navigationDestination(for: Chapter.self) { ChapterDetailView(chapter: $0) }
        // `Identified`: the chapter's persistentModelID changes on its first autosave.
        .sheet(item: $editTarget) { target in
            NavigationStack { ChapterEditorView(chapter: target.value, isNew: true) }
        }
    }

    private var chapterList: some View {
        // Built once per body pass: `recipesByUUID` walks the whole library, and reading it in each
        // card would rebuild it per row.
        let byUUID = recipesByUUID
        return List {
            ForEach(chapters) { chapter in
                chapterCard(for: chapter, recipesByUUID: byUUID)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { modelContext.delete(chapter) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .paperBackground()
    }

    /// One chapter card row — stack layout navigates via a hidden link; split layout selects into
    /// the detail pane with an accent ring on the chosen card.
    @ViewBuilder
    private func chapterCard(for chapter: Chapter, recipesByUUID: [UUID: Recipe]) -> some View {
        if isSplit {
            Button { splitSelection = chapter.persistentModelID } label: {
                ChapterRow(chapter: chapter, recipesByUUID: recipesByUUID)
            }
            .buttonStyle(.plain)
            .overlay {
                if splitSelection == chapter.persistentModelID {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                }
            }
        } else {
            ChapterRow(chapter: chapter, recipesByUUID: recipesByUUID)
                .overlay {
                    NavigationLink(value: chapter) { EmptyView() }.opacity(0)
                }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Chapters Yet", systemImage: "books.vertical")
        } description: {
            Text("A Chapter groups up to \(Chapter.maxSlots) recipes and pushes them to the camera's custom slots C1–C\(Chapter.maxSlots) all at once.")
        } actions: {
            Button("New Chapter") { createChapter() }
                .buttonStyle(.borderedProminent)
                .prominentOnAccentLabel()
                .disabled(recipes.isEmpty)
            if recipes.isEmpty {
                Text("Create some recipes in the Library first.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func createChapter() {
        let chapter = Chapter(name: "New Chapter")
        modelContext.insert(chapter)
        editTarget = Identified(value: chapter)
    }
}

/// A chapter's card. The slot strip mirrors the camera's custom slots so it's clear at a glance
/// which are filled.
private struct ChapterRow: View {
    let chapter: Chapter
    let recipesByUUID: [UUID: Recipe]

    private var recipeNames: String {
        let names = chapter.recipeUUIDs.map { recipesByUUID[$0]?.name ?? "Missing recipe" }
        return names.isEmpty ? "No recipes yet" : names.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(chapter.name)
                    .font(Theme.serif(20))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer()
                Text("\(chapter.recipeUUIDs.count) of \(Chapter.maxSlots)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
            }
            slotStrip
                .padding(.top, 14)
            Text(recipeNames)
                .font(.footnote)
                .foregroundStyle(Theme.ink2)
                .lineLimit(2)
                .padding(.top, 12)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chapter.name), \(chapter.recipeUUIDs.count) of \(Chapter.maxSlots) slots filled. \(recipeNames)")
    }

    private var slotStrip: some View {
        HStack(spacing: 6) {
            ForEach(1...Chapter.maxSlots, id: \.self) { index in
                let filled = index <= chapter.recipeUUIDs.count
                Text("C\(index)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(filled ? Theme.accent : Theme.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(filled ? Theme.accentSoft : Theme.paper2,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }
}

import SwiftUI

/// The top-level tabs. Any screen can switch tabs through `AppRouter.selectedTab` — the Kitchen
/// sends people to Camera to connect, for one.
enum AppTab: Hashable { case library, chapters, ideas, kitchen, camera }

/// A pre-filled request for the Ideas tab. Any screen can hand Ideas a starting point — a Chapter
/// asking to have its free slots filled, or a past result being refined — by setting
/// `AppRouter.ideaSeed` and switching to `.ideas`; `RecommenderView` applies it and clears it.
struct IdeaSeed: Equatable {
    /// Recipes the model must keep, in slot order.
    var anchorUUIDs: [UUID] = []
    /// The shooting brief to pre-fill; may be empty when the anchors are the whole request.
    var brief: String = ""
    /// How many slots the finished set should fill.
    var slotTarget: Int = Chapter.maxSlots
    /// Recipes that were in the result being refined. Any of these the user *doesn't* keep as an
    /// anchor is treated as rejected and withheld from the next request (see `RecommenderView`).
    var previousPickUUIDs: [UUID] = []
    /// The chapter this request came from, so the result can offer to write straight back to it.
    var sourceChapter: SourceChapter?

    /// A chapter a request came from: its id, which the result writes back to, and its name, which
    /// the composer shows.
    struct SourceChapter: Equatable {
        let uuid: UUID
        let name: String

        init(_ chapter: Chapter) {
            uuid = chapter.uuid
            name = chapter.name
        }
    }
}

/// A pre-filled request for Frame & Fit. The recipe screen hands the Kitchen a recipe to build a
/// share card from, and the Kitchen's viewer a developed photo with the recipe that made it, the
/// same way `IdeaSeed` hands the Ideas tab a starting point; `FrameAndFitView` applies it once and
/// clears it.
struct FrameSeed: Equatable {
    /// The recipe the card should start on; nil starts without a card.
    var recipeUUID: UUID?
    /// The developed version (`CookedVersion.uuid`) to start the frame from; nil leaves the photos
    /// to be picked.
    var developedVersionID: UUID?
}

/// A pre-filled request for Develop: the Library recipe to start on. The Kitchen's viewer hands it
/// over for a Test Kitchen preview worth developing at full resolution; `DevelopView` applies it
/// once and clears it. The RAW file isn't kept after a develop, so it is picked again.
struct DevelopSeed: Equatable {
    var recipeUUID: UUID
}

/// Shared navigation state for cross-tab deep-linking. `RootView` binds the `TabView`'s selection to
/// `selectedTab`; feature views read it from the environment and set it to jump between tabs.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab = .library

    /// A pending pre-filled Ideas request. Set alongside `selectedTab = .ideas`; the Ideas tab
    /// consumes it once and sets it back to nil.
    var ideaSeed: IdeaSeed?

    /// A pending pre-filled Frame & Fit request. Set alongside `selectedTab = .kitchen`; Frame & Fit
    /// consumes it once and sets it back to nil.
    var frameSeed: FrameSeed?

    /// A pending pre-filled Develop request. Set alongside `selectedTab = .kitchen`; Develop
    /// consumes it once and sets it back to nil.
    var developSeed: DevelopSeed?
}

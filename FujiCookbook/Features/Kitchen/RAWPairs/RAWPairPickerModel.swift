import Foundation

/// The RAW+JPEG sheet's state: which screen it shows, the shared photos, and the user's choice.
@MainActor
@Observable
final class RAWPairPickerModel: Identifiable {
    enum Screen: Equatable {
        case explainer
        case sharedPhotos
        case accessDenied
        case accessRestricted
    }

    /// What the sheet ends with, acted on once it has gone so the next presentation doesn't
    /// collide with its dismissal.
    enum Outcome: Equatable {
        case picked([String])
        /// Full access: the regular picker reads pairs, so the route hands over to it.
        case useRegularPicker
        case browseFiles
    }

    private(set) var screen: Screen
    private(set) var shared = SharedRAWPhotos()
    private(set) var selection: RAWPairSelection
    /// Shown under the grid after a tap past the limit; cleared by the next tap that works.
    private(set) var refusal: RAWPairSelection.Refusal?
    private(set) var hasLoaded = false
    private(set) var isRequestingAccess = false
    /// Counts taps on Continue. The sheet runs `requestAccess()` for each in a task it owns, so the
    /// request outlives the explainer it was tapped on, which gives way to the photos as it ends.
    private(set) var accessRequests = 0
    private(set) var outcome: Outcome?

    @ObservationIgnored private let library: any PhotoLibraryAccessing

    init(library: any PhotoLibraryAccessing, limit: Int?) {
        self.library = library
        self.selection = RAWPairSelection(limit: limit)
        self.screen = Self.screen(for: RAWPairRoute(library.access)) ?? .sharedPhotos
    }

    var chosenCount: Int { selection.chosen.count }

    func askForAccess() {
        accessRequests += 1
    }

    /// Asks for access from the explainer. Limited access goes straight to the photos just
    /// selected in the prompt, chosen when they all fit the limit; full access hands over.
    func requestAccess() async {
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        await apply(RAWPairRoute(await library.requestAccess()))
        // The prompt's own selection reports no identifiers, but every photo shared now was chosen
        // seconds ago; all of them are chosen when they fit, none when they don't.
        guard screen == .sharedPhotos, outcome == nil else { return }
        if let limit = selection.limit, shared.photos.count > limit { return }
        selection.chooseNewlyShared(shared.photos.map(\.id))
    }

    /// Reads access again, as when the user comes back from the Settings app.
    func refreshAccess() async {
        // The system prompt sends the app inactive and back; that return is `requestAccess`'s.
        guard !isRequestingAccess else { return }
        let route = RAWPairRoute(library.access)
        guard Self.screen(for: route) != screen || route == .photoPicker else { return }
        await apply(route)
    }

    func load() async {
        shared = await library.sharedRAWPhotos()
        selection.keepOnly(Set(shared.photos.map(\.id)))
        hasLoaded = true
    }

    /// Photos Apple's screen reports as newly selected: those with a RAF are chosen while there is
    /// room.
    func choose(newlyShared ids: [String]) async {
        await load()
        let withRAF = Set(shared.photos.map(\.id))
        selection.chooseNewlyShared(ids.filter(withRAF.contains))
        refusal = nil
    }

    func toggle(_ id: String) {
        refusal = selection.toggle(id)
    }

    /// Reloads whenever what the app can see changes, until the task is cancelled.
    func followChanges() async {
        for await _ in library.changes() {
            await load()
        }
    }

    func add() { outcome = .picked(selection.chosen) }
    func useBrowseFiles() { outcome = .browseFiles }

    private func apply(_ route: RAWPairRoute) async {
        guard let next = Self.screen(for: route) else {
            outcome = .useRegularPicker
            return
        }
        screen = next
        if next == .sharedPhotos { await load() }
    }

    /// Nil for full access, which leaves the sheet for the regular picker.
    private static func screen(for route: RAWPairRoute) -> Screen? {
        switch route {
        case .explainer: .explainer
        case .sharedPhotos: .sharedPhotos
        case .photoPicker: nil
        case .accessDenied: .accessDenied
        case .accessRestricted: .accessRestricted
        }
    }
}

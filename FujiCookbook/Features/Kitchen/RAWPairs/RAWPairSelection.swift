/// Which shared photos are chosen, in the order they were tapped, which is the order they develop in.
struct RAWPairSelection: Equatable {
    /// How many photos may be chosen; nil for no limit. With a limit of one, tapping another photo
    /// replaces the choice, as in the system picker.
    let limit: Int?
    private(set) var chosen: [String] = []

    /// Why a tap didn't choose a photo.
    enum Refusal: Equatable {
        case limitReached(Int)
    }

    init(limit: Int?) {
        self.limit = limit
    }

    func position(of id: String) -> Int? {
        chosen.firstIndex(of: id).map { $0 + 1 }
    }

    /// Chooses `id`, or un-chooses it if it was chosen. Returns why nothing changed, if it didn't.
    @discardableResult
    mutating func toggle(_ id: String) -> Refusal? {
        if let index = chosen.firstIndex(of: id) {
            chosen.remove(at: index)
            return nil
        }
        if limit == 1 {
            chosen = [id]
            return nil
        }
        if let limit, chosen.count >= limit {
            return .limitReached(limit)
        }
        chosen.append(id)
        return nil
    }

    /// Chooses photos the user has just shared, in the order given, while there is room. With a
    /// limit of one, the first of them replaces the choice. Photos already chosen stay chosen.
    mutating func chooseNewlyShared(_ ids: [String]) {
        let fresh = ids.filter { !chosen.contains($0) }
        guard let first = fresh.first else { return }
        if limit == 1 {
            chosen = [first]
            return
        }
        let room = limit.map { max(0, $0 - chosen.count) } ?? fresh.count
        chosen.append(contentsOf: fresh.prefix(room))
    }

    /// Forgets chosen photos that are no longer shared, keeping the order of the rest.
    mutating func keepOnly(_ visible: Set<String>) {
        chosen.removeAll { !visible.contains($0) }
    }
}

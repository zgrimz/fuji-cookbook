import Foundation

extension Array where Element == Recipe {
    /// The one Library recipe with this name, or nil when none or several have it. A developed
    /// version keeps the name of the recipe that made it, not its identity, so a name two recipes
    /// share can't say which one it was.
    func uniqueRecipe(named name: String) -> Recipe? {
        let matches = filter { $0.name == name }
        return matches.count == 1 ? matches.first : nil
    }
}

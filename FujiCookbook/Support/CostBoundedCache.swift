import Foundation

/// Values kept up to a total cost, the least recently used dropped first when an insert goes over.
/// Safe to use from any thread.
///
/// Unlike `NSCache`, it keeps its contents while the app is in the background; it lets go only when
/// told to, through `removeAll()`.
final class CostBoundedCache<Key: Hashable, Value>: @unchecked Sendable {
    private struct Entry {
        let value: Value
        let cost: Int
    }

    let costLimit: Int

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    /// Keys from least to most recently used.
    private var recency: [Key] = []
    private var totalCost = 0

    init(costLimit: Int) {
        self.costLimit = costLimit
    }

    /// The value for `key`, which also becomes the most recently used.
    func value(for key: Key) -> Value? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            markUsed(key)
            return entry.value
        }
    }

    /// Stores `value` as the most recently used, dropping the least recently used until the total
    /// fits. A value costing more than the whole limit isn't kept.
    func insert(_ value: Value, for key: Key, cost: Int) {
        lock.withLock {
            remove(key)
            guard cost <= costLimit else { return }
            entries[key] = Entry(value: value, cost: cost)
            recency.append(key)
            totalCost += cost
            while totalCost > costLimit, let oldest = recency.first {
                remove(oldest)
            }
        }
    }

    func removeAll() {
        lock.withLock {
            entries.removeAll()
            recency.removeAll()
            totalCost = 0
        }
    }

    private func markUsed(_ key: Key) {
        guard let index = recency.firstIndex(of: key) else { return }
        recency.remove(at: index)
        recency.append(key)
    }

    private func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalCost -= entry.cost
        recency.removeAll { $0 == key }
    }
}

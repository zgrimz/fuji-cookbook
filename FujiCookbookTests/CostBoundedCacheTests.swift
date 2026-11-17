import XCTest
@testable import FujiCookbook

final class CostBoundedCacheTests: XCTestCase {
    func testKeepsValuesWithinTheLimit() {
        let cache = CostBoundedCache<String, Int>(costLimit: 10)
        cache.insert(1, for: "a", cost: 4)
        cache.insert(2, for: "b", cost: 4)
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.value(for: "b"), 2)
    }

    func testDropsTheLeastRecentlyUsedWhenAnInsertGoesOver() {
        let cache = CostBoundedCache<String, Int>(costLimit: 10)
        cache.insert(1, for: "a", cost: 4)
        cache.insert(2, for: "b", cost: 4)
        _ = cache.value(for: "a")
        cache.insert(3, for: "c", cost: 4)
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "c"), 3)
    }

    func testReplacingAValueReplacesItsCost() {
        let cache = CostBoundedCache<String, Int>(costLimit: 10)
        cache.insert(1, for: "a", cost: 8)
        cache.insert(2, for: "a", cost: 2)
        cache.insert(3, for: "b", cost: 8)
        XCTAssertEqual(cache.value(for: "a"), 2)
        XCTAssertEqual(cache.value(for: "b"), 3)
    }

    func testDoesNotKeepAValueCostingMoreThanTheLimit() {
        let cache = CostBoundedCache<String, Int>(costLimit: 10)
        cache.insert(1, for: "a", cost: 4)
        cache.insert(2, for: "huge", cost: 11)
        XCTAssertNil(cache.value(for: "huge"))
        XCTAssertEqual(cache.value(for: "a"), 1)
    }

    func testRemoveAllEmptiesItAndFreesTheBudget() {
        let cache = CostBoundedCache<String, Int>(costLimit: 10)
        cache.insert(1, for: "a", cost: 10)
        cache.removeAll()
        XCTAssertNil(cache.value(for: "a"))
        cache.insert(2, for: "b", cost: 10)
        XCTAssertEqual(cache.value(for: "b"), 2)
    }
}

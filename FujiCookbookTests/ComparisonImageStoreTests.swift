import SwiftData
import UIKit
import XCTest
@testable import FujiCookbook

@MainActor
final class ComparisonImageStoreTests: XCTestCase {
    func testLoadsThroughTheLoaderAndMarksAVersionWithNoImageUnavailable() async throws {
        let container = try ModelContainer(for: SharedModelStore.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                              cloudKitDatabase: .none))
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 30, height: 20)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
        }.jpegData(compressionQuality: 0.8))
        let developed = CookedVersion(recipeName: "Portra 400", filmSimulation: nil, imageData: jpeg,
                                      thumbnailData: Data(), clampedFields: [], sortOrder: 0)
        let empty = CookedVersion(recipeName: "Tri-X Push", filmSimulation: nil, imageData: Data(),
                                  thumbnailData: Data(), clampedFields: [], sortOrder: 1)
        container.mainContext.insert(developed)
        container.mainContext.insert(empty)
        try container.mainContext.save()

        let store = ComparisonImageStore()
        XCTAssertTrue(store.isAvailable(empty.uuid), "Available until loading says otherwise")
        await store.load([developed.uuid, empty.uuid], with: DevelopedImageLoader(modelContainer: container))

        XCTAssertNotNil(store.image(for: developed.uuid))
        XCTAssertTrue(store.isAvailable(developed.uuid))
        XCTAssertNil(store.image(for: empty.uuid))
        XCTAssertFalse(store.isAvailable(empty.uuid))
    }
}

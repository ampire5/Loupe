import Foundation
import Testing
@testable import LoupeCore

@Suite struct PhotosAssetNamesTests {
    @Test func cancellationStopsResourceLookupsAndDoesNotPublishAPartialSnapshot() throws {
        var cache = PhotosAssetNames()
        let assets = (0..<100).map { PhotosAsset(id: "asset-\($0)", modified: .distantPast, created: nil, width: 1, height: 1) }
        var reads = 0
        #expect(throws: CancellationError.self) {
            _ = try cache.resolve(assets, isCancelled: { reads == 2 }) { value in reads += 1; return value.id }
        }
        #expect(reads == 2)
    }
    @Test func invalidationKeepsUnchangedResourceNames() throws {
        var cache = PhotosAssetNames()
        let assets = (0..<100).map { PhotosAsset(id: "asset-\($0)", modified: .distantPast, created: nil, width: 1, height: 1) }
        _ = try cache.resolve(assets) { $0.id }
        cache.invalidate(["asset-1"])
        var reads = 0
        _ = try cache.resolve(assets) { reads += 1; return $0.id }
        #expect(reads == 1)
    }
    @Test func unchangedCollectionDoesNotReadEveryResourceAgain() throws {
        var cache = PhotosAssetNames()
        var reads = 0
        let assets = (0..<100).map { PhotosAsset(id: "asset-\($0)", modified: .distantPast, created: nil, width: 16, height: 16) }
        for _ in 0..<2 {
            let names = try cache.resolve(assets) { asset in reads += 1; return asset.id + ".HEIC" }
            #expect(names.first?.filename == "asset-0.HEIC")
        }
        #expect(reads == 100)
    }
    @Test func changedResourceAndExplicitInvalidationRefreshNames() throws {
        var cache = PhotosAssetNames()
        var reads = 0
        func asset(_ date: Date) -> PhotosAsset { PhotosAsset(id: "same", modified: date, created: nil, width: 16, height: 16) }
        _ = try cache.resolve([asset(.distantPast)]) { _ in reads += 1; return "First.HEIC" }
        let updated = try cache.resolve([asset(.distantFuture)]) { _ in reads += 1; return "Updated.PNG" }
        #expect(updated.first?.filename == "Updated.PNG")
        #expect(reads == 2)
        cache.clear()
        _ = try cache.resolve([asset(.distantFuture)]) { _ in reads += 1; return "Renamed.PNG" }
        #expect(reads == 3)
    }
    @Test func removedRecordsDoNotAccumulateInTheCache() throws {
        var cache = PhotosAssetNames()
        let old = PhotosAsset(id: "old", modified: .distantPast, created: nil, width: 1, height: 1)
        let new = PhotosAsset(id: "new", modified: .distantPast, created: nil, width: 1, height: 1)
        _ = try cache.resolve([old, new]) { $0.id }
        _ = try cache.resolve([new]) { $0.id }
        var reads = 0
        _ = try cache.resolve([old]) { reads += 1; return $0.id }
        #expect(reads == 1)
    }
}

import Foundation
import HomeScreenModel
import Testing
@testable import LoupeCore

@Suite struct PhotosPersistenceTests {
    @Test @MainActor func sortSurvivesAStoreRecreationAndKeepsCollectionsIndependent() throws {
        let suite = "Loupe.PhotosSortTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = PhotosLocation.collection(PhotosLocation.library)
        let first = PhotosSortStore(defaults: defaults)
        first.setSort(BrowserSort(key: .name, ascending: false), for: source)
        let reopened = PhotosSortStore(defaults: defaults)
        #expect(reopened.sort(for: source) == BrowserSort(key: .name, ascending: false))
        #expect(reopened.sort(for: PhotosLocation.collection("other")) == BrowserSort(key: .date, ascending: true))
        reopened.setSort(BrowserSort(key: .date, ascending: false), for: source)
        #expect(PhotosSortStore(defaults: defaults).sort(for: source) == BrowserSort(key: .date, ascending: false))
    }

    @Test func namesSurviveAProcessCacheRecreationAndRevisionsStayFresh() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("names.json")
        let old = PhotosAsset(id: "asset", modified: .distantPast, created: nil, width: 2, height: 3)
        var first = PhotosAssetNames(file: file)
        _ = try first.resolve([old]) { _ in "Original.HEIC" }
        var reopened = PhotosAssetNames(file: file)
        var reads = 0
        let cached = try reopened.resolve([old]) { _ in reads += 1; return "Wrong.JPG" }
        #expect(cached.first?.filename == "Original.HEIC")
        #expect(reads == 0)
        let changed = PhotosAsset(id: "asset", modified: .distantFuture, created: nil, width: 4, height: 5)
        let fresh = try reopened.resolve([changed]) { _ in reads += 1; return "Changed.PNG" }
        #expect(reads == 1)
        #expect(fresh.first?.filename == "Changed.PNG")
        #expect(fresh.first?.width == 4)
        reopened.invalidate(["asset"])
        var afterInvalidation = PhotosAssetNames(file: file)
        _ = try afterInvalidation.resolve([changed]) { _ in reads += 1; return "Renamed.PNG" }
        #expect(reads == 2)
    }

    @Test func visitingAnAlbumDoesNotEvictTheLibraryNamesAfterRestart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("names.json")
        let assets = (0..<100).map { PhotosAsset(id: "asset-\($0)", modified: .distantPast, created: nil, width: 1, height: 1) }
        var cache = PhotosAssetNames(file: file)
        _ = try cache.resolve(assets) { $0.id + ".HEIC" }
        _ = try cache.resolve(Array(assets.prefix(2)), isLibrary: false) { $0.id + ".HEIC" }
        var reopened = PhotosAssetNames(file: file)
        var reads = 0
        _ = try reopened.resolve(assets) { reads += 1; return $0.id }
        #expect(reads == 0)
    }

    @Test func invalidDiskCacheFallsBackToPhotoKitMetadata() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("incomplete cache".utf8).write(to: file)
        var cache = PhotosAssetNames(file: file)
        let asset = PhotosAsset(id: "asset", modified: .distantPast, created: nil, width: 1, height: 1)
        let result = try cache.resolve([asset]) { _ in "Photo.HEIC" }
        #expect(result.first?.filename == "Photo.HEIC")
    }
}

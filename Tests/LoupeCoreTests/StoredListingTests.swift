import Foundation
import HomeScreenModel
import Testing
@testable import LoupeCore

/// A folder's last complete listing kept in the catalog (`StoredListing`, `folder_listings`): shown first when the
/// folder is next opened, before the share answers.
@Suite struct StoredListingTests {
    private let folder = URL(fileURLWithPath: "/Volumes/S/Album", isDirectory: true)

    private var entries: [BrowserEntry] {
        [BrowserEntry(url: folder.appendingPathComponent("Sub", isDirectory: true), name: "Sub", kind: .folder, count: 12,
                      canRename: true, canTrash: true),
         BrowserEntry(url: folder.appendingPathComponent("b.zip"), name: "b.zip", kind: .archive,
                      date: Date(timeIntervalSinceReferenceDate: 700_000_000.5), size: 42, canRename: true, canTrash: true),
         BrowserEntry(url: folder.appendingPathComponent("a é.jpg"), name: "a é.jpg", kind: .file,
                      date: Date(timeIntervalSinceReferenceDate: 700_000_001.25), size: 1_234_567,
                      canRename: true, canTrash: true)]
    }

    @Test func roundTripsUnderTheFolderItIsOpenedAt() throws {
        let data = try #require(StoredListing.encode(entries))
        #expect(StoredListing.decode(data, in: folder) == entries)
        // The same share mounted elsewhere: the entries are under the folder as it is opened now.
        let moved = URL(fileURLWithPath: "/Users/u/Volumes/S/Album", isDirectory: true)
        #expect(StoredListing.decode(data, in: moved)?.map(\.url.path)
                == entries.map { moved.path + "/" + $0.name })
    }

    /// Only what a folder's listing holds is kept: no places or collections, nor the app's subtitles and badges.
    @Test func keepsOnlyAFoldersOwnEntries() throws {
        var odd = entries
        odd[0].subtitle = "12 photos"
        odd.append(BrowserEntry(url: folder, name: "Recent", kind: .collection))
        let data = try #require(StoredListing.encode(odd))
        let back = try #require(StoredListing.decode(data, in: folder))
        #expect(back.count == 3)
        #expect(back[0].subtitle == nil)
    }

    @Test func garbageDecodesToNothing() {
        #expect(StoredListing.decode(Data([1, 2, 3]), in: folder) == nil)
    }

    /// Through the store: kept for the folder, found again by the next store on the same catalog, none for another.
    @Test func storeKeepsAFoldersListing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-listings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let locate: @Sendable (URL) -> ThumbnailLocation? = { url in
            ThumbnailLocation(volume: "net:test", folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
        }
        let store = ThumbnailStore(directory: dir, reader: ThumbReader(), thumbSize: 32, limitBytes: 1 << 30, locate: locate)
        await store.storeListing(entries, of: folder)
        #expect(await store.storedListing(folder) == entries)
        #expect(await store.storedListing(folder.appendingPathComponent("Sub")) == nil)
        let next = ThumbnailStore(directory: dir, reader: ThumbReader(), thumbSize: 32, limitBytes: 1 << 30, locate: locate)
        #expect(await next.storedListing(folder) == entries)
    }

    /// All of a folder's names without their dates (a cold share): kept, each with what the listing kept before knew of
    /// it; a name new since has none, one gone is gone.
    @Test func namesOnlyKeepWhatWasKnown() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-listings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let locate: @Sendable (URL) -> ThumbnailLocation? = { url in
            ThumbnailLocation(volume: "net:test", folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
        }
        let store = ThumbnailStore(directory: dir, reader: ThumbReader(), thumbSize: 32, limitBytes: 1 << 30, locate: locate)
        await store.storeListing(entries, of: folder)
        let new = BrowserEntry(url: folder.appendingPathComponent("c.jpg"), name: "c.jpg", kind: .file,
                               canRename: true, canTrash: true)
        var names = Array(entries.dropFirst()).map { e -> BrowserEntry in
            var e = e
            e.date = nil
            e.size = nil
            return e
        }
        names.append(new)
        await store.storeListing(names, of: folder, namesOnly: true)
        let kept = try #require(await store.storedListing(folder))
        #expect(kept == Array(entries.dropFirst()) + [new])
    }
}

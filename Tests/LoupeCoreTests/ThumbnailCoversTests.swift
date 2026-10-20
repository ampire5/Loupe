import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

/// Home's card covers (Home spec §2.5): a thumbnail for a file of a folder no window lists.
@Suite struct ThumbnailCoversTests {
    private let fm = FileManager.default

    private func tempDir() -> URL { fm.temporaryDirectory.appendingPathComponent("loupe-covers-\(UUID().uuidString)") }

    private static let locate: @Sendable (URL) -> ThumbnailLocation? = { url in
        ThumbnailLocation(volume: "test", folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
    }

    private func store(_ reader: ThumbReader, dir: URL) -> ThumbnailStore {
        ThumbnailStore(directory: dir, reader: reader, pool: DecodePool(), thumbSize: 32, limitBytes: 1 << 30,
                       locate: Self.locate, idleDelay: .zero, commitDelay: .seconds(3600))
    }

    private func photo(_ reader: ThumbReader, _ path: String = "/photos/a/1.jpg", width: Int = 40) -> URL {
        let url = URL(fileURLWithPath: path)
        reader.add(url, TestJPEGs.gradient(width: width, height: 30))
        return url
    }

    /// Review Focus 5: an empty Thumbs.db makes the cover from the file and keeps it; a later store reads nothing.
    @Test func peekAfterWipe() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let url = photo(reader)
        let first = await store(reader, dir: dir).cover(url, maxPixel: 64)
        #expect(first != nil)
        let reads = reader.readCount(url)
        #expect(reads > 0)
        let again = await store(reader, dir: dir).cover(url, maxPixel: 64)
        #expect(again != nil)
        #expect(reader.readCount(url) == reads)
    }

    /// Review Focus 5: a row whose stamp no longer matches the file is not used; the cover is made again.
    @Test func peekIgnoresStaleStamp() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let url = photo(reader, width: 40)
        let old = try #require(await store(reader, dir: dir).cover(url, maxPixel: 64))
        _ = photo(reader, width: 60)
        let reads = reader.readCount(url)
        let new = try #require(await store(reader, dir: dir).cover(url, maxPixel: 64))
        #expect(reader.readCount(url) > reads)
        #expect(Double(new.width) / Double(new.height) > Double(old.width) / Double(old.height))
    }

    @Test func coverUnreadable() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let url = photo(reader)
        reader.fail(url)
        #expect(await store(reader, dir: dir).cover(url, maxPixel: 64) == nil)
    }

    /// `addFile` adds one file to a folder without dropping its other files, as `sync` would.
    @Test func addFileKeepsSiblings() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try ThumbnailDatabase(directory: dir, thumbSize: 32)
        let folder = ThumbnailLocation(volume: "v", folder: "/f", name: "")
        let stamp = FileStamp(modified: Date(timeIntervalSinceReferenceDate: 1), size: 10)
        let ids = try db.sync(folder: folder, files: [("a.jpg", stamp), ("b.jpg", stamp), ("c.jpg", stamp)])
        let info = ImageInfo(pixelSize: PixelSize(width: 4, height: 3), typeIdentifier: "public.jpeg",
                             isProgressive: false, fileSize: 10, colorSpaceName: nil, orientation: .up)
        try db.put(ids.values.map { ($0, stamp, Data([1, 2, 3]), info) })
        let d = try db.addFile(ThumbnailLocation(volume: "v", folder: "/f", name: "d.jpg"), stamp: stamp)
        #expect(try db.hasThumbnail(Array(ids.values)) == Set(ids.values))
        #expect(try db.file(at: ThumbnailLocation(volume: "v", folder: "/f", name: "d.jpg"))?.id == d)
        #expect(try db.file(at: ThumbnailLocation(volume: "v", folder: "/f", name: "a.jpg"))?.stamp == stamp)
        #expect(try db.file(at: ThumbnailLocation(volume: "v", folder: "/f", name: "zz.jpg")) == nil)
        #expect(try db.addFile(ThumbnailLocation(volume: "v", folder: "/f", name: "a.jpg"), stamp: stamp) == ids["a.jpg"])
    }
}

/// The file browser's folder cards (file browser spec §4.2): how many photos the catalog knows in a folder.
@Suite struct ThumbnailKnownCountsTests {
    private let fm = FileManager.default

    @Test func knownCountsForListedFolder() async {
        let dir = fm.temporaryDirectory.appendingPathComponent("loupe-counts-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let locate: @Sendable (URL) -> ThumbnailLocation? = { url in
            ThumbnailLocation(volume: "test", folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
        }
        let store = ThumbnailStore(directory: dir, reader: reader, pool: DecodePool(), thumbSize: 32, limitBytes: 1 << 30,
                                   locate: locate, idleDelay: .zero, commitDelay: .seconds(3600))
        for name in ["1.jpg", "2.jpg"] {
            let url = URL(fileURLWithPath: "/photos/a/\(name)")
            reader.add(url, TestJPEGs.gradient(width: 40, height: 30))
            _ = await store.cover(url, maxPixel: 64)
        }
        let a = URL(fileURLWithPath: "/photos/a"), b = URL(fileURLWithPath: "/photos/b")
        let counts = await store.knownCounts([a, b])
        #expect(counts[a] == 2)
        #expect(counts[b] == nil)
    }
}

/// A folder card's mosaic comes from the catalog only: the photos of the folder that have a thumbnail.
@Suite struct ThumbnailFolderSamplesTests {
    private let fm = FileManager.default

    @Test func samplesFromTheCatalog() async {
        let dir = fm.temporaryDirectory.appendingPathComponent("loupe-samples-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let locate: @Sendable (URL) -> ThumbnailLocation? = { url in
            ThumbnailLocation(volume: "test", folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
        }
        let store = ThumbnailStore(directory: dir, reader: reader, pool: DecodePool(), thumbSize: 32, limitBytes: 1 << 30,
                                   locate: locate, idleDelay: .zero, commitDelay: .seconds(3600))
        for name in ["b.jpg", "a.jpg", "c.jpg", "d.jpg", "e.jpg"] {
            let url = URL(fileURLWithPath: "/photos/a/\(name)")
            reader.add(url, TestJPEGs.gradient(width: 40, height: 30))
            _ = await store.cover(url, maxPixel: 64)
        }
        let folder = URL(fileURLWithPath: "/photos/a")
        let samples = await store.folderSamples(folder, limit: 4)
        #expect(samples.map(\.lastPathComponent) == ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        #expect(await store.folderSamples(URL(fileURLWithPath: "/photos/none"), limit: 4).isEmpty)
        // A fresh store (no window lists the folder) still decodes them, from the catalog, reading no file.
        let fresh = ThumbnailStore(directory: dir, reader: reader, pool: DecodePool(), thumbSize: 32, limitBytes: 1 << 30,
                                   locate: locate, idleDelay: .zero, commitDelay: .seconds(3600))
        let reads = reader.readCount(samples[0])
        #expect(await fresh.catalogThumbnail(samples[0], maxPixel: 64) != nil)
        #expect(reader.readCount(samples[0]) == reads)
        #expect(await fresh.catalogThumbnail(URL(fileURLWithPath: "/photos/a/zz.jpg"), maxPixel: 64) == nil)
    }
}

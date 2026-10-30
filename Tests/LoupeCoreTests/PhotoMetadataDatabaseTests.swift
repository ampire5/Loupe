import Foundation
import Testing
import HomeScreenModel
@testable import LoupeCore

@Suite struct PhotoMetadataDatabaseTests {
    private let location = ThumbnailLocation(volume: "test-volume", folder: "/Examples", name: "cat.png")
    private let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1234), size: 2048)

    @Test func fullMetadataSurvivesReopenAndStampChangesInvalidateIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var metadata = PhotoMetadata(properties: [:], pngText: [:], created: Date(timeIntervalSince1970: 10), modified: stamp.modified)
        metadata.camera = "Example camera"; metadata.lens = "Example lens"
        metadata.focalLength = "50 mm (75 mm equiv.)"; metadata.aperture = "f/2.8"
        metadata.exposure = "1/250 s"; metadata.iso = "ISO 100"; metadata.captured = "2024-01-01 12:00:00"
        metadata.compensation = "+1 EV"
        metadata.gps = "12° N, 34° E"; metadata.software = "Example editor"
        metadata.description = "A cat"; metadata.generation = "A cat beside a window"
        metadata.comfyWorkflowBytes = 12345; metadata.bitDepth = 16; metadata.hasAlpha = true
        metadata.header = ImageInfo(pixelSize: PixelSize(width: 100, height: 200), typeIdentifier: "public.png",
                                    isProgressive: false, fileSize: stamp.size, colorSpaceName: "Display P3", orientation: .right)
        let db = try ThumbnailDatabase(directory: dir, thumbSize: 512)
        let id = try db.addFile(location, stamp: stamp)
        try db.putPhotoMetadata(metadata, id: id, stamp: stamp)
        db.close()
        let reopened = try ThumbnailDatabase(directory: dir, thumbSize: 512)
        #expect(try reopened.photoMetadata(id, stamp: stamp) == metadata)
        let changed = FileStamp(modified: stamp.modified.addingTimeInterval(1), size: stamp.size)
        #expect(try reopened.photoMetadata(id, stamp: changed) == nil)
        _ = try reopened.addFile(location, stamp: changed)
        // An old read finishing after replacement cannot write over the new file.
        try reopened.putPhotoMetadata(metadata, id: id, stamp: stamp)
        #expect(try reopened.photoMetadata(id, stamp: changed) == nil)
        try reopened.putPhotoMetadata(metadata, id: id, stamp: changed)
        #expect(try reopened.photoMetadata(id, stamp: changed) != nil)
        _ = try reopened.sync(folder: location, files: [(location.name, stamp)])
        #expect(try reopened.photoMetadata(id, stamp: stamp) == nil)
        reopened.close()
    }

    @Test func emptySuccessfulReadIsCachedButErrorsAndOversizedPayloadsAreNot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try ThumbnailDatabase(directory: dir, thumbSize: 512)
        let id = try db.addFile(location, stamp: stamp)
        var metadata = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
        try db.putPhotoMetadata(metadata, id: id, stamp: stamp)
        #expect(try db.photoMetadata(id, stamp: stamp) != nil)
        try db.deleteFiles([id])
        let newID = try db.addFile(location, stamp: stamp)
        #expect(try db.photoMetadata(newID, stamp: stamp) == nil)
        metadata.error = "Share unavailable"
        try db.putPhotoMetadata(metadata, id: newID, stamp: stamp)
        #expect(try db.photoMetadata(newID, stamp: stamp) == nil)
        metadata.error = nil
        metadata.description = String(repeating: "x", count: 300_000)
        try db.putPhotoMetadata(metadata, id: newID, stamp: stamp)
        #expect(try db.photoMetadata(newID, stamp: stamp) == nil)
        db.close()
    }
}

@MainActor @Suite struct PersistentInspectorMetadataTests {
    @Test func completedCatalogRecordSkipsSourceReadAndDebounce() async {
        let entry = BrowserEntry(url: URL(fileURLWithPath: "/Examples/cat.png"), name: "cat.png", kind: .file,
                                 date: Date(timeIntervalSince1970: 1234), size: 2048)
        var metadata = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
        metadata.description = "From disk catalog"
        let saved = metadata
        let loader = BrowserInspectorLoader(settleDelay: .seconds(60), catalog: { _ in
            BrowserInspectorSeed(metadata: saved)
        }, reader: { _ in
            Issue.record("A completed catalog hit must not read the source")
            return BrowserInspectorResult(metadata: saved)
        })
        loader.isActive = true
        loader.select(entry)
        let deadline = ContinuousClock.now + .seconds(2)
        while loader.result == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(loader.result?.metadata.description == "From disk catalog")
        #expect(loader.content.pendingSections.isEmpty)
        #expect(!loader.isReading)
        loader.isActive = false
    }
}

@Suite struct PhotoMetadataStoreTests {
    @Test func directlyOpenedFilesSharePersistentMetadataWithoutMixingFolderNames() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = URL(fileURLWithPath: "/Examples/cat.png"), b = URL(fileURLWithPath: "/Examples/dog.png")
        let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1234), size: 2048)
        let locate: @Sendable (URL) -> ThumbnailLocation? = { url in
            ThumbnailLocation(volume: "test-volume", folder: "/Examples", name: url.lastPathComponent)
        }
        let first = ThumbnailStore(directory: dir, reader: ThumbReader(), thumbSize: 32, limitBytes: 1 << 30, locate: locate)
        #expect(await first.photoMetadata(for: a, stamp: stamp) == nil)
        #expect(await first.photoMetadata(for: b, stamp: stamp) == nil)
        var metadata = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: stamp.modified)
        metadata.description = "cat"
        await first.keepPhotoMetadata(metadata, for: a, stamp: stamp)
        metadata.description = "dog"
        await first.keepPhotoMetadata(metadata, for: b, stamp: stamp)
        let second = ThumbnailStore(directory: dir, reader: ThumbReader(), thumbSize: 32, limitBytes: 1 << 30, locate: locate)
        #expect(await second.photoMetadata(for: a, stamp: stamp)?.description == "cat")
        #expect(await second.photoMetadata(for: b, stamp: stamp)?.description == "dog")
        // Disabling persistence must leave no database, even when metadata is explicitly requested.
        let disabledDir = dir.appendingPathComponent("disabled")
        let disabled = ThumbnailStore(directory: disabledDir, reader: ThumbReader(), thumbSize: 32, limitBytes: 0, locate: locate)
        #expect(await disabled.photoMetadata(for: a, stamp: stamp) == nil)
        await disabled.keepPhotoMetadata(metadata, for: a, stamp: stamp)
        #expect(!FileManager.default.fileExists(atPath: disabledDir.appendingPathComponent("Catalog.db").path))
    }
}

@Suite struct PhotoMetadataBudgetTests {
    @Test func boundedPayloadsEvictOldRecordsAndInvalidVersionsAreMisses() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1234), size: 2048)
        let db = try ThumbnailDatabase(directory: dir, thumbSize: 512)
        var metadata = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
        metadata.generation = String(repeating: "x", count: 230_000)
        var ids: [Int64] = []
        for i in 0..<80 {
            let id = try db.addFile(ThumbnailLocation(volume: "test-volume", folder: "/Examples", name: "cat-\(i).png"), stamp: stamp)
            ids.append(id)
            try db.putPhotoMetadata(metadata, id: id, stamp: stamp)
        }
        #expect(try db.photoMetadata(ids[0], stamp: stamp) == nil)
        #expect(try db.photoMetadata(ids[79], stamp: stamp)?.generation?.count == 230_000)
        let sql = try SQLiteConnection(path: dir.appendingPathComponent("Catalog.db").path, pragmas: [])
        var bytes: Int64 = 0
        try sql.query("SELECT sum(length(payload)) FROM photo_metadata", []) { bytes = $0.int(0) }
        #expect(bytes <= PhotoMetadataRecord.totalBytes)
        try sql.run("UPDATE photo_metadata SET reader = 999 WHERE file_id = ?", [.int(ids[79])])
        #expect(try db.photoMetadata(ids[79], stamp: stamp) == nil)
        try sql.run("UPDATE photo_metadata SET reader = ?, payload = ? WHERE file_id = ?",
                    [.int(Int64(PhotoMetadataRecord.readerVersion)), .blob(Data("broken".utf8)), .int(ids[79])])
        #expect(try db.photoMetadata(ids[79], stamp: stamp) == nil)
        sql.close(); db.close()
    }

    @Test func catalogLookupBenchmarkWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["LOUPE_METADATA_BENCH"] == "1" else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try ThumbnailDatabase(directory: dir, thumbSize: 512)
        let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1234), size: 2048)
        var metadata = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
        metadata.generation = String(repeating: "A cat beside a window. ", count: 200)
        var ids: [Int64] = []
        let start = ContinuousClock.now
        for i in 0..<2048 {
            let id = try db.addFile(ThumbnailLocation(volume: "test-volume", folder: "/Examples", name: "cat-\(i).png"), stamp: stamp)
            ids.append(id)
            try db.putPhotoMetadata(metadata, id: id, stamp: stamp)
        }
        print("METADATA BENCH fill 2048: \(start.duration(to: .now))")
        for round in 0..<3 {
            let start = ContinuousClock.now
            for id in ids { #expect(try db.photoMetadata(id, stamp: stamp) != nil) }
            print("METADATA BENCH lookup 2048 round \(round): \(start.duration(to: .now))")
        }
        db.close()
    }
}

@Suite struct PhotoMetadataCatalogResetTests {
    @Test func rebuildingCatalogFormatCannotReuseOldMetadataForANewFileID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1234), size: 2048)
        let first = try ThumbnailDatabase(directory: dir, thumbSize: 512)
        let id = try first.addFile(ThumbnailLocation(volume: "test-volume", folder: "/Examples", name: "cat.png"), stamp: stamp)
        var metadata = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: stamp.modified)
        metadata.description = "cat"
        try first.putPhotoMetadata(metadata, id: id, stamp: stamp)
        first.close()
        let sql = try SQLiteConnection(path: dir.appendingPathComponent("Catalog.db").path, pragmas: [])
        try sql.run("UPDATE meta SET value = '1' WHERE key = 'format_version'", [])
        sql.close()
        let next = try ThumbnailDatabase(directory: dir, thumbSize: 512)
        let newID = try next.addFile(ThumbnailLocation(volume: "test-volume", folder: "/Examples", name: "dog.png"), stamp: stamp)
        #expect(try next.photoMetadata(newID, stamp: stamp) == nil)
        next.close()
    }
}

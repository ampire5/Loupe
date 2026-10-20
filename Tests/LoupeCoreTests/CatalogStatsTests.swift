import Foundation
import Testing
@testable import LoupeCore

/// Settings › Catalog: what the thumbnail catalog holds, by volume.
@Suite struct CatalogStatsTests {
    private let fm = FileManager.default

    @Test func countsByVolume() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("loupe-stats-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let db = try ThumbnailDatabase(directory: dir, thumbSize: 32)
        let stamp = FileStamp(modified: Date(timeIntervalSinceReferenceDate: 1), size: 10)
        let info = ImageInfo(pixelSize: PixelSize(width: 4, height: 3), typeIdentifier: "public.jpeg",
                             isProgressive: false, fileSize: 10, colorSpaceName: nil, orientation: .up)
        let a = try db.sync(folder: ThumbnailLocation(volume: "net://u@pc/L%24", folder: "/x", name: ""),
                            files: [("1.jpg", stamp), ("2.jpg", stamp), ("3.jpg", stamp)])
        _ = try db.sync(folder: ThumbnailLocation(volume: "net://u@pc/L%24", folder: "/y", name: ""), files: [("4.jpg", stamp)])
        let b = try db.sync(folder: ThumbnailLocation(volume: "uuid:ABC", folder: "/z", name: ""), files: [("5.jpg", stamp)])
        try db.put([(a["1.jpg"]!, stamp, Data(count: 100), info), (a["2.jpg"]!, stamp, Data(count: 50), info),
                    (b["5.jpg"]!, stamp, Data(count: 7), info)])
        db.close()

        let stats = try #require(CatalogStats.read(directory: dir))
        #expect(stats.volumes.map(\.key) == ["net://u@pc/L%24", "uuid:ABC"])   // the most files first
        let l = stats.volumes[0]
        #expect((l.folders, l.files, l.thumbnails, l.thumbnailBytes) == (2, 4, 2, 150))
        let z = stats.volumes[1]
        #expect((z.folders, z.files, z.thumbnails, z.thumbnailBytes) == (1, 1, 1, 7))
        #expect(stats.total.files == 5 && stats.total.thumbnails == 3 && stats.total.folders == 3)
        #expect(stats.diskBytes > 0)
    }

    @Test func noCatalogIsNil() {
        #expect(CatalogStats.read(directory: fm.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")) == nil)
    }

    @Test func volumeTitles() {
        #expect(CatalogStats.title(forVolume: "net://alice@server/L%24", localNames: [:]) == "L$ · server")
        #expect(CatalogStats.title(forVolume: "uuid:ABC", localNames: ["ABC": "Macintosh HD"]) == "Macintosh HD")
        #expect(CatalogStats.title(forVolume: "uuid:DEF", localNames: [:]) == "Local disk")
        #expect(CatalogStats.title(forVolume: "mnt:/Volumes/Card", localNames: [:]) == "Card")
    }
}

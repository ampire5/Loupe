import Foundation
import ImageIO
import Testing
@testable import LoupeCore

@Suite struct ThumbnailEncodingTests {
    @Test func defaultsClampingAndUnavailableEncoder() {
        let name = "test.thumbnail-encoding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ThumbnailEncoding.configured(defaults) == .standard)
        defaults.set("avif", forKey: "thumbnail-format")
        defaults.set(200, forKey: "thumbnail-quality")
        let selected = ThumbnailEncoding.configured(defaults)
        #expect(selected.quality == 1)
        defaults.set(-5, forKey: "thumbnail-quality")
        #expect(ThumbnailEncoding.configured(defaults).quality == 0.1)
        defaults.set("unknown", forKey: "thumbnail-format")
        #expect(ThumbnailEncoding.configured(defaults).format == .jpeg)
        #expect(ThumbnailEncoding(format: .avif, quality: 0.8, availableTypes: ["public.jpeg"]).format == .jpeg)
        #expect(ThumbnailEncoding(format: .jpeg, quality: .nan).quality == 0.8)
    }

    @Test func configuredPayloadsDecodeThroughExistingCellPipeline() throws {
        let data = TestJPEGs.gradient(width: 128, height: 96)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        for format in ThumbnailEncoding.Format.allCases {
            let policy = ThumbnailEncoding(format: format, quality: 0.8)
            let encoded = try policy.encode(image)
            let cell = try #require(ThumbnailMaker.decodeCell(encoded, maxPixel: 64))
            #expect(cell.width == 64)
            #expect(cell.height == 48)
        }
    }

    @Test func changingEncodingInvalidatesOnlyThumbnails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1234), size: 2048)
        let location = ThumbnailLocation(volume: "test-volume", folder: "/Examples", name: "cat.png")
        let first = try ThumbnailDatabase(directory: dir, thumbSize: 512, encoding: .standard)
        let id = try first.addFile(location, stamp: stamp)
        let info = ImageInfo(pixelSize: PixelSize(width: 100, height: 200), typeIdentifier: "public.png",
                             isProgressive: false, fileSize: 2048, colorSpaceName: "sRGB")
        try first.put([(id: id, stamp: stamp, jpeg: Data([1, 2]), info: info)])
        let metadata = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: stamp.modified)
        try first.putPhotoMetadata(metadata, id: id, stamp: stamp)
        first.close()
        let unchanged = try ThumbnailDatabase(directory: dir, thumbSize: 512, encoding: .standard)
        #expect(try unchanged.thumbnail(id) != nil)
        unchanged.close()
        let changed = try ThumbnailDatabase(directory: dir, thumbSize: 512,
                                            encoding: ThumbnailEncoding(format: .jpeg, quality: 0.9))
        #expect(try changed.thumbnail(id) == nil)
        #expect(try changed.file(at: location)?.id == id)
        #expect(try changed.photoMetadata(id, stamp: stamp) != nil)
        changed.close()
    }
}

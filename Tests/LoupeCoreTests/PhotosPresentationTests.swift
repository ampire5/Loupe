import CoreGraphics
import Foundation
import HomeScreenModel
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LoupeCore

@Suite struct PhotosMetadataTests {
    @Test func originalNamesAndExtensionsReachTheGridAndViewerIdentity() {
        let assets = ["IMG_9.HEIC", "IMG_2.PNG", "IMG_9.HEIC"].enumerated().map { i, name in
            PhotosAsset(id: "asset-\(i)", modified: .distantPast, created: nil, width: 16, height: 16, filename: name)
        }
        let entries = PhotosAlbumListing.entries(assets, album: "album")
        #expect(entries.map(\.name) == ["IMG_9.HEIC", "IMG_2.PNG", "IMG_9.HEIC"])
        #expect(entries.map { $0.url.lastPathComponent } == entries.map(\.name))
        #expect(Set(entries.map(\.id)).count == 3)
        #expect(BrowserSort(key: .name, ascending: true).order(entries).map(\.name) == ["IMG_2.PNG", "IMG_9.HEIC", "IMG_9.HEIC"])
    }

    @Test @MainActor func sortingIsRememberedPerCollectionAndSharedWithNewViewers() {
        let sorts = PhotosSortStore()
        let library = PhotosLocation.collection(PhotosLocation.library)
        sorts.setSort(BrowserSort(key: .name, ascending: false), for: library)
        #expect(sorts.sort(for: library) == BrowserSort(key: .name, ascending: false))
        #expect(sorts.sort(for: PhotosLocation.collection("other")) == BrowserSort(key: .date, ascending: true))
    }

    @Test func heicBytesStayHeicThroughTheSourceReader() async throws {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(context.makeImage())
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let data = encoded as Data
        let stamp = FileStamp(modified: .distantPast, size: data.count)
        let reader = PhotosReader(load: { _, _ in FileBytes(data: data, stamp: stamp) }, sourceStamp: { _ in stamp })
        let asset = PhotosAsset(id: "asset", modified: .distantPast, created: nil, width: 64, height: 64, filename: "IMG_1.HEIC")
        let bytes = try await reader.read(asset.url(in: "album"), priority: 0)
        #expect(bytes.data == data)
        #expect(ImageFormat.detect(bytes.data) == .heic)
        let info = try DecoderRegistry.decoder(for: bytes.data).probe(bytes.data)
        #expect(info.typeIdentifier == UTType.heic.identifier)
        #expect(info.pixelSize == PixelSize(width: 64, height: 64))
    }
}

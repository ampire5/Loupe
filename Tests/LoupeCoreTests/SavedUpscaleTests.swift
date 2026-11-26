import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LoupeCore

struct SavedUpscaleTests {
    @Test(arguments: [UTType.png, .jpeg])
    func savesHiddenCopiesAndReplacesWithBackup(_ type: UTType) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.\(try #require(type.preferredFilenameExtension))")
        try writeOriginal(to: source, type: type)
        let original = try Data(contentsOf: source)
        let stamp = try #require(FileStamp(source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])))
        let copy = SavedUpscale(source: source, stamp: stamp)
        let size = PixelSize(width: 20, height: 12)
        let stride = DecodedImage.bytesPerRow(width: size.width)
        let buffer = try PageAlignedBuffer(minimumLength: stride * size.height)
        memset(buffer.bytes, 128, stride * size.height)
        let pixels = DecodedImage(pixelSize: size, bytesPerRow: stride, buffer: buffer,
                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, hasAlphaChannel: false)

        try FileManager.default.createDirectory(at: copy.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldPNG = copy.file.deletingPathExtension().appendingPathExtension("png")
        try writeOriginal(to: oldPNG, type: .png)
        #expect(!copy.exists)
        #expect(try BrowserListingSource.full(folder, archives: false).first?.badge == nil)
        #expect(throws: CancellationError.self) {
            try copy.write(pixels, orientation: .right, model: "test-model") { throw CancellationError() }
        }
        #expect(!copy.exists)
        try copy.write(pixels, orientation: .right, model: "test-model")
        #expect(copy.exists)
        #expect(copy.file.pathExtension == "avif")
        #expect(ImageFormat.detect(try Data(contentsOf: copy.file)) == .avif)
        let saved = try #require(CGImageSourceCreateWithURL(copy.file as CFURL, nil))
        let savedProperties = try #require(CGImageSourceCopyPropertiesAtIndex(saved, 0, nil) as? [CFString: Any])
        #expect(savedProperties[kCGImagePropertyOrientation] as? Int ?? 1 == ImageOrientation.up.rawValue)
        #expect(savedProperties[kCGImagePropertyPixelWidth] as? Int == size.height)
        #expect(savedProperties[kCGImagePropertyPixelHeight] as? Int == size.width)
        #expect(copy.metadata?.orientation == .right)
        let preview = try #require(ThumbnailMaker.decodeCell(try Data(contentsOf: copy.previewFile), maxPixel: 128))
        #expect(preview.width == size.height && preview.height == size.width)
        #expect(copy.matches(model: "test-model"))
        #expect(!copy.matches(model: "another-model"))
        #expect(try Data(contentsOf: source) == original)
        let listing = try BrowserListingSource.full(folder, archives: false)
        #expect(listing.map { $0.url.resolvingSymlinksInPath() } == [source.resolvingSymlinksInPath()])
        #expect(listing.first?.badge == "Upscale")

        try copy.replaceOriginal()
        #expect(!copy.exists)
        let newStamp = try await FileReader().stamp(source, priority: 0)
        #expect(SavedUpscale(source: source, stamp: newStamp).isPromoted)
        #expect(!copy.isPromoted)
        #expect(throws: (any Error).self) { try copy.replaceOriginal() }
        let after = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(after, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == size.width)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == size.height)
        #expect(properties[kCGImagePropertyOrientation] as? Int == ImageOrientation.right.rawValue)
        let backups = copy.file.deletingLastPathComponent().appendingPathComponent("Originals")
        let backup = try #require(FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func savesAndMarksArchiveEntriesWithoutChangingTheZip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("images.zip")
        let otherArchive = folder.appendingPathComponent("others.zip")
        let bytes = ZipFixture.make([
            .init(name: "one/frame.jpg", data: Data([1, 2, 3])),
            .init(name: "two/frame.jpg", data: Data([4, 5, 6]))
        ])
        try bytes.write(to: archive)
        try bytes.write(to: otherArchive)
        let entries = try ArchiveReader.shared.entries(of: archive)
        let first = try #require(entries.first)
        let second = try #require(entries.last)
        let other = try #require(ArchiveReader.shared.entries(of: otherArchive).first)
        let saved = SavedUpscale(source: first.url, stamp: first.stamp)
        try #require(SavedUpscale.supports(first.url))
        #expect(saved.replacementType == nil)
        #expect(saved.file != SavedUpscale(source: second.url, stamp: first.stamp).file)
        #expect(saved.file != SavedUpscale(source: other.url, stamp: first.stamp).file)
        let size = PixelSize(width: 20, height: 12)
        let stride = DecodedImage.bytesPerRow(width: size.width)
        let buffer = try PageAlignedBuffer(minimumLength: stride * size.height)
        let pixels = DecodedImage(pixelSize: size, bytesPerRow: stride, buffer: buffer,
                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, hasAlphaChannel: false)
        try saved.write(pixels, orientation: .up, model: "test-model")
        #expect(saved.exists)
        #expect(saved.file.deletingLastPathComponent().resolvingSymlinksInPath()
            == SavedUpscale.directory(in: folder).resolvingSymlinksInPath())
        #expect(try Data(contentsOf: archive) == bytes)
        let listing = try BrowserListingSource.full(archive, archives: true)
        #expect(listing.filter { $0.badge == "Upscale" }.map(\.name) == ["one/frame.jpg"])
        #expect(listing.allSatisfy { !$0.canRename && !$0.canTrash })
        try FileManager.default.setAttributes([.modificationDate: first.stamp.modified.addingTimeInterval(60)],
                                              ofItemAtPath: archive.path)
        #expect(!saved.exists)
        #expect(try BrowserListingSource.full(archive, archives: true).allSatisfy { $0.badge == nil })
    }

    private func writeOriginal(to url: URL, type: UTType) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: 10, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 6))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
    }
}

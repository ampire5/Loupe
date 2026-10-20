import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LoupeCore

/// Zip archives as folders (Stash spec §2.4): listing, sibling steps, metadata and the thumbnail clean-up.
@Suite struct ArchiveFolderTests {
    let root: URL
    let zip: URL
    let png: Data

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archivefolder-\(UUID().uuidString)")
        let fm = FileManager.default
        png = try Self.png(width: 3, height: 2)
        for dir in ["a", "c"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent("\(dir)/1.png"))
        }
        zip = try ZipFixture.write(ZipFixture.make([
            .init(name: "caps/10.png", data: png), .init(name: "caps/2.png", data: png, method: 0),
            .init(name: "readme.txt", data: Data([1])),
        ]), name: "b.zip", in: root)
    }

    static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    @Test func relistListsAnArchive() async throws {
        let first = try #require(ArchivePath.url(archive: zip, entry: "caps/10.png"))
        let list = try #require(await Playlist.relist(current: first))
        #expect(names(list.files) == ["caps\u{2215}2.png", "caps\u{2215}10.png"])
        #expect(list.current == first.standardizedFileURL)
        #expect(list.stamps.count == 2)
    }

    @Test func quickListListsAnArchive() async throws {
        let first = try #require(ArchivePath.url(archive: zip, entry: "caps/2.png"))
        let list = try #require(await Playlist.quickList(current: first))
        #expect(names(list.files) == ["caps\u{2215}2.png", "caps\u{2215}10.png"])
    }

    @Test func siblingsIncludeArchives() async throws {
        let nav = FolderNavigator()
        let next = try #require(try await nav.neighbour(of: root.appendingPathComponent("a"), step: 1))
        #expect(next.folder.lastPathComponent == "b.zip" && next.images.count == 2)
        let after = try #require(try await nav.neighbour(of: next.folder, step: 1))
        #expect(after.folder.lastPathComponent == "c")
        let back = try #require(try await nav.neighbour(of: root.appendingPathComponent("c"), step: -1))
        #expect(back.folder.lastPathComponent == "b.zip")
    }

    @Test func siblingsWithoutArchives() async throws {
        let nav = FolderNavigator()
        let next = try #require(try await nav.neighbour(of: root.appendingPathComponent("a"), step: 1, archives: false))
        #expect(next.folder.lastPathComponent == "c")
    }

    @Test func contentsOfFolderAndArchive() async throws {
        let nav = FolderNavigator()
        #expect(try await nav.contents(of: zip)?.images.count == 2)
        #expect(try await nav.contents(of: root.appendingPathComponent("a"))?.images.count == 1)
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(try await nav.contents(of: empty) == nil)
    }

    @Test func metadataOfAnEntry() throws {
        let entry = try #require(ArchivePath.url(archive: zip, entry: "caps/10.png"))
        let m = PhotoMetadata.read(entry)
        #expect(m.error == nil)
        #expect(m.header?.pixelSize.width == 3 && m.header?.pixelSize.height == 2)
        #expect(m.modified != nil)
    }

    @Test func archiveRowsSurviveCleanUp() throws {
        let names = try #require(MountedFiles.names(in: zip.path))
        #expect(names == ["caps\u{2215}10.png", "caps\u{2215}2.png"])
    }

    @Test func playlistForAnArchiveTarget() async throws {
        let target = try #require(try await FolderNavigator().contents(of: zip))
        let remembered = try #require(ArchivePath.url(archive: zip, entry: "caps/10.png")).standardizedFileURL
        let list = FolderRequest.playlist(for: target) { folder, files in
            folder == zip.standardizedFileURL ? files.first { $0 == remembered } : nil
        }
        #expect(list.current == remembered && names(list.files) == ["caps\u{2215}2.png", "caps\u{2215}10.png"])
        #expect(FolderRequest.listErrorText(FolderNavigationError.timedOut, name: "b.zip")
                == "Can't list “b.zip”: not responding")
    }
}

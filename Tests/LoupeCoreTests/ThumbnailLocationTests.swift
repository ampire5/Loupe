import Testing
import Foundation
@testable import LoupeCore

@Test func networkVolumeKeyIgnoresMountPoint() {
    let a = ThumbnailLocation.make(path: "/Volumes/L$/Album/a.jpg", mountPoint: "/Volumes/L$",
                                   mountFrom: "//user@server/L$", isLocal: false, volumeUUID: nil)
    let b = ThumbnailLocation.make(path: "/Volumes/L$-1/Album/a.jpg", mountPoint: "/Volumes/L$-1",
                                   mountFrom: "//user@server/L$", isLocal: false, volumeUUID: nil)
    #expect(a == b)
    #expect(a.volume == "net://user@server/L$")
    #expect(a.folder == "/Album")
    #expect(a.name == "a.jpg")
}

@Test func networkVolumeKeepsHostCaseAsReported() {
    let l = ThumbnailLocation.make(path: "/Volumes/X/a.jpg", mountPoint: "/Volumes/X",
                                   mountFrom: "//User@Server/X", isLocal: false, volumeUUID: "IGNORED")
    #expect(l.volume == "net://User@Server/X")
}

@Test func localVolumeUsesUUID() {
    let l = ThumbnailLocation.make(path: "/Volumes/Photos/2024/05/a.jpg", mountPoint: "/Volumes/Photos",
                                   mountFrom: "/dev/disk4s2", isLocal: true, volumeUUID: "ABCD-1234")
    #expect(l.volume == "uuid:ABCD-1234")
    #expect(l.folder == "/2024/05")
    #expect(l.name == "a.jpg")
}

@Test func localWithoutUUIDUsesMountPoint() {
    let l = ThumbnailLocation.make(path: "/Volumes/Photos/a.jpg", mountPoint: "/Volumes/Photos",
                                   mountFrom: "/dev/disk4s2", isLocal: true, volumeUUID: nil)
    #expect(l.volume == "mnt:/Volumes/Photos")
}

@Test func rootFolder() {
    let l = ThumbnailLocation.make(path: "/Volumes/Photos/a.jpg", mountPoint: "/Volumes/Photos",
                                   mountFrom: "/dev/disk4s2", isLocal: true, volumeUUID: "U")
    #expect(l.folder == "/")
    let r = ThumbnailLocation.make(path: "/a.jpg", mountPoint: "/", mountFrom: "/dev/disk3s1s1",
                                   isLocal: true, volumeUUID: "U")
    #expect(r.folder == "/")
    #expect(r.name == "a.jpg")
}

@Test func mountPointIsNotMistakenForPrefixOfSiblingName() {
    let l = ThumbnailLocation.make(path: "/Volumes/L$-1/a.jpg", mountPoint: "/Volumes/L$",
                                   mountFrom: "//s/L$", isLocal: false, volumeUUID: nil)
    #expect(l.folder == "/Volumes/L$-1")
}

@Test func pathOutsideMountPointKeepsFullFolder() {
    // Firmlinked paths (/Users/…) live on the Data volume mounted at /System/Volumes/Data.
    let l = ThumbnailLocation.make(path: "/Users/me/Pictures/a.jpg", mountPoint: "/System/Volumes/Data",
                                   mountFrom: "/dev/disk3s5", isLocal: true, volumeUUID: "U")
    #expect(l.folder == "/Users/me/Pictures")
}

@Test func resolveRealTempFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-loc-\(UUID().uuidString).jpg")
    try Data([0]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let l = try #require(ThumbnailLocation.resolve(url))
    #expect(l.volume.hasPrefix("uuid:") || l.volume.hasPrefix("mnt:"))
    #expect(l.name == url.lastPathComponent)
    #expect(l.folder.hasPrefix("/"))
}

@Test func resolveMissingFolderIsNil() {
    #expect(ThumbnailLocation.resolve(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/a.jpg")) == nil)
}

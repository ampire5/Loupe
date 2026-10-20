import Foundation
import Testing
@testable import LoupeCore

@Suite struct MountedFilesTests {
    private let fm = FileManager.default

    /// A real folder in the temp directory with `names` in it, and the location of `file` there.
    private func folder(_ names: [String]) throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("loupe-mounted-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        return dir
    }

    private func location(_ dir: URL, _ name: String) throws -> ThumbnailLocation {
        try #require(ThumbnailLocation.resolve(dir.appendingPathComponent(name)))
    }

    @Test func presentAndMissingFiles() throws {
        let dir = try folder(["a.jpg"])
        defer { try? fm.removeItem(at: dir) }
        let files = MountedFiles()
        #expect(files.isPresent(try location(dir, "a.jpg")) == true)
        #expect(files.isPresent(try location(dir, "b.jpg")) == false)
    }

    @Test func goneFolderMeansGoneFiles() throws {
        let dir = try folder(["a.jpg"])
        let a = try location(dir, "a.jpg")
        try fm.removeItem(at: dir)
        #expect(MountedFiles().isPresent(a) == false)
    }

    @Test func folderThatCannotBeListedIsKept() throws {
        let dir = try folder(["a.jpg"])
        let a = try location(dir, "a.jpg")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? fm.removeItem(at: dir)
        }
        #expect(MountedFiles().isPresent(a) == nil)
        #expect(MountedFiles.names(in: dir.path) == nil)
    }

    @Test func unmountedVolumeIsKept() {
        let elsewhere = ThumbnailLocation(volume: "net://user@nowhere/Gone$", folder: "/a", name: "b.jpg")
        #expect(MountedFiles().isPresent(elsewhere) == nil)
    }
}

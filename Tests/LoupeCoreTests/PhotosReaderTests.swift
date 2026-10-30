import Foundation
import Testing
@testable import LoupeCore

@Suite struct PhotosReaderTests {
    @Test func ordinaryFilesKeepTheirReaderAndPhotosUseTheSource() async throws {
        let stamp = FileStamp(modified: .distantPast, size: 3)
        let reader = PhotosReader(fallback: FixtureReader(), load: { url, _ in
            #expect(PhotosLocation.asset(in: url) == "asset")
            return FileBytes(data: Data([7, 8, 9]), stamp: stamp)
        }, sourceStamp: { _ in stamp })
        let file = try await reader.read(URL(fileURLWithPath: "/photo.jpg"), priority: 0)
        #expect(file.data == Data([1, 2]))
        let url = PhotosLocation.assetURL(album: "album", asset: "asset", revision: "1")
        let photo = try await reader.read(url, priority: 0)
        #expect(photo.data == Data([7, 8, 9]))
        #expect(try await reader.stamp(url, priority: 0) == stamp)
    }

    @Test func virtualPhotosNeverEnumerateTheirParentDirectory() async {
        let url = PhotosLocation.assetURL(album: "album", asset: "asset", revision: "1")
        #expect(await Playlist.relist(current: url) == nil)
        #expect(await Playlist.quickList(current: url) == nil)
    }

    @Test func sourceImagesAreReadOnlyWhenSelectedSoPromotionCannotReuseALocalOnlyRequest() async {
        let rig = Rig()
        let files = ["a", "b", "c"].map { PhotosLocation.assetURL(album: "album", asset: $0, revision: "1") }
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { atLeast(.preview, await rig.state(files[0])) })
        #expect(await rig.settle())
        #expect(rig.reader.readCount(files[0]) == 1)
        #expect(rig.reader.readCount(files[1]) == 0)
        await rig.focus(files, 1, dwelling: true)
        #expect(await eventually { atLeast(.preview, await rig.state(files[1])) })
        #expect(rig.reader.readCount(files[1]) == 1)
        await rig.clear()
    }
}

private struct FixtureReader: FileReading {
    func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes {
        FileBytes(data: Data([1, 2]), stamp: FileStamp(modified: .distantPast, size: 2))
    }
    func stamp(_ url: URL, priority: Int) async throws -> FileStamp { FileStamp(modified: .distantPast, size: 2) }
}

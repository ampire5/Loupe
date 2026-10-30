import Foundation
import HomeScreenModel
import Testing
@testable import LoupeCore

@Test func browseTargetPlainFolder() {
    let photo = URL(fileURLWithPath: "/Volumes/T/x/a.jpg")
    let (location, select) = BrowseTarget.location(for: photo)
    #expect(location == .folder(URL(fileURLWithPath: "/Volumes/T/x")))
    #expect(select == "/Volumes/T/x/a.jpg")
}

@Test func browseTargetInsideArchive() {
    let entry = ArchivePath.url(archive: URL(fileURLWithPath: "/Volumes/T/g.zip"), entry: "caps/1.jpg")!
    let (location, select) = BrowseTarget.location(for: entry)
    #expect(location == .folder(URL(fileURLWithPath: "/Volumes/T/g.zip")))
    #expect(select == entry.path)
}

@Test func browseTargetPhotosReturnsToItsSourceWithStableSelection() {
    let photo = PhotosLocation.assetURL(album: PhotosLocation.library, asset: "asset/one", revision: "edited")
    let (location, select) = BrowseTarget.location(for: photo)
    #expect(location == .source(PhotosLocation.collection(PhotosLocation.library)))
    #expect(select == photo.absoluteString)
}

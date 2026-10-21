import Testing
import Foundation
@testable import LoupeCore

private let size = CGSize(width: 6000, height: 4000)

@Test(arguments: [ZoomMode.fit, .fitWidth, .fitHeight, .fill, .actual(2), .actual(0.37), .free(1), .free(3.141592653589793)])
func savedViewTextRoundTrip(_ mode: ZoomMode) {
    let v = SavedView(mode: mode, center: CGPoint(x: 0.31, y: 0.62), imageSize: size)
    #expect(SavedView(text: v.text) == v)
}

@Test func savedViewTextSpelling() {
    #expect(SavedView(mode: .actual(2), center: CGPoint(x: 0.31, y: 0.62), imageSize: size).text == "actual:2.0 0.31 0.62 6000x4000")
    #expect(SavedView(mode: .fitWidth, center: CGPoint(x: 0.5, y: 0.5), imageSize: size).text == "fit-width 0.5 0.5 6000x4000")
    #expect(SavedView(text: "free:1.5 0.25 0.75 300x200")
            == SavedView(mode: .free(1.5), center: CGPoint(x: 0.25, y: 0.75), imageSize: CGSize(width: 300, height: 200)))
}

@Test(arguments: ["", "fit", "fit 0.5 0.5", "fit 0.5 0.5 6000x4000 extra", "zoom 0.5 0.5 6000x4000",
                  "actual 0.5 0.5 6000x4000", "actual:0 0.5 0.5 6000x4000", "free:-1 0.5 0.5 6000x4000",
                  "actual:nan 0.5 0.5 6000x4000", "fit:2 0.5 0.5 6000x4000", "fit x 0.5 6000x4000",
                  "fit 0.5 inf 6000x4000", "fit 0.5 0.5 6000", "fit 0.5 0.5 0x4000", "fit 0.5 0.5 6000x-4"])
func savedViewRejectsMalformedText(_ text: String) {
    #expect(SavedView(text: text) == nil)
}

@Test func savedViewAppliesOnlyToTheSameSize() {
    let v = SavedView(mode: .actual(2), center: CGPoint(x: 0.3, y: 0.6), imageSize: size)
    #expect(v.applies(to: size))
    #expect(!v.applies(to: CGSize(width: 4000, height: 6000)))     // rotated, or another photo under the name
    #expect(!v.applies(to: CGSize(width: 6000, height: 4001)))
}

// MARK: ViewRestore

private let photo = URL(fileURLWithPath: "/photos/f1/a.jpg")
private let saved = SavedView(mode: .actual(2), center: CGPoint(x: 0.3, y: 0.6), imageSize: size)
/// The transform at arrival: the previous photo's, at 100 % somewhere.
private let arrival = ViewTransform(imageSize: CGSize(width: 4000, height: 3000), viewSize: CGSize(width: 2000, height: 1200),
                                    mode: .actual(1), center: CGPoint(x: 0.2, y: 0.2))

@Test func restoreGivesTheSavedModeAndCentreAtTheSavedSize() {
    let r = ViewRestore(file: photo, view: saved, arrival: arrival)
    let t = r.transform(for: photo, imageSize: size, over: arrival)
    #expect(t == ViewTransform(imageSize: size, viewSize: arrival.viewSize, mode: .actual(2), center: CGPoint(x: 0.3, y: 0.6)))
}

@Test func restoreKeepsTheViewSizeOfNow() {
    let r = ViewRestore(file: photo, view: saved, arrival: arrival)
    let resized = arrival.withViewSize(CGSize(width: 1000, height: 700))     // the window changed meanwhile
    #expect(r.transform(for: photo, imageSize: size, over: resized)?.viewSize == resized.viewSize)
}

@Test func restoreDoesNotApplyToAnotherSize() {
    let r = ViewRestore(file: photo, view: saved, arrival: arrival)
    #expect(r.transform(for: photo, imageSize: CGSize(width: 5999, height: 4000), over: arrival) == nil)
}

@Test func restoreDoesNotApplyToAnotherPhoto() {
    let r = ViewRestore(file: photo, view: saved, arrival: arrival)
    #expect(r.transform(for: URL(fileURLWithPath: "/photos/f1/b.jpg"), imageSize: size, over: arrival) == nil)
}

@Test func restoreYieldsToAZoomOrPanSinceArrival() {
    let r = ViewRestore(file: photo, view: saved, arrival: arrival)
    #expect(r.transform(for: photo, imageSize: size, over: arrival.withMode(.fit)) == nil)
    #expect(r.transform(for: photo, imageSize: size, over: arrival.panned(by: CGVector(dx: 50, dy: 0))) == nil)
}

@Test func restoreOfAFitModeIsTheModeItself() {
    let fit = SavedView(mode: .fitHeight, center: CGPoint(x: 0.5, y: 0.1), imageSize: size)
    let t = ViewRestore(file: photo, view: fit, arrival: arrival).transform(for: photo, imageSize: size, over: arrival)
    #expect(t?.mode == .fitHeight)
    #expect(t?.center == CGPoint(x: 0.5, y: 0.1))
}

@Test func restoreIsNotPendingWithFolderViewMemoryOff() {
    let name = photo.lastPathComponent
    #expect(ViewRestore.pending(file: photo, savedFile: name, saved: saved, arrival: arrival, memory: .off) == nil)
    for memory in [FolderViewMemory.folder, .photo] {
        #expect(ViewRestore.pending(file: photo, savedFile: name, saved: saved, arrival: arrival, memory: memory)
                == ViewRestore(file: photo, view: saved, arrival: arrival))
        #expect(ViewRestore.pending(file: photo, savedFile: name, saved: nil, arrival: arrival, memory: memory) == nil)
    }
}

// MARK: Folder view memory (`folder`: any photo of the folder opens in its saved view)

private let other = URL(fileURLWithPath: "/photos/f1/b.jpg")
private let otherSize = CGSize(width: 5999, height: 4000)

private func pending(_ file: URL, _ memory: FolderViewMemory) -> ViewRestore? {
    ViewRestore.pending(file: file, savedFile: "a.jpg", saved: saved, arrival: arrival, memory: memory)
}

@Test func folderMemoryGivesAnotherPhotoOfTheSameSizeTheModeAndCentre() {
    let t = pending(other, .folder)?.transform(for: other, imageSize: size, over: arrival)
    #expect(t == ViewTransform(imageSize: size, viewSize: arrival.viewSize, mode: .actual(2), center: CGPoint(x: 0.3, y: 0.6)))
}

@Test func folderMemoryGivesAnotherSizeTheModeCentred() {
    let t = pending(other, .folder)?.transform(for: other, imageSize: otherSize, over: arrival)
    #expect(t == ViewTransform(imageSize: otherSize, viewSize: arrival.viewSize, mode: .actual(2),
                               center: CGPoint(x: 0.5, y: 0.5)))
}

@Test func folderMemoryOfTheSavedFileIsAsBefore() {
    let r = pending(photo, .folder)
    #expect(r?.transform(for: photo, imageSize: size, over: arrival)?.center == CGPoint(x: 0.3, y: 0.6))
    #expect(r?.transform(for: photo, imageSize: otherSize, over: arrival) == nil)      // size must match: no restore
}

@Test func photoMemoryRestoresOnlyTheSavedFile() {
    #expect(pending(other, .photo) == nil)
    let r = pending(photo, .photo)
    #expect(r?.transform(for: photo, imageSize: size, over: arrival)?.mode == .actual(2))
    #expect(r?.transform(for: photo, imageSize: otherSize, over: arrival) == nil)
    #expect(pending(photo, .off) == nil && pending(other, .off) == nil)
}

@Test(arguments: [FolderViewMemory.folder, .photo])
func aZoomOrPanSinceArrivalYieldsInEveryMemory(_ memory: FolderViewMemory) {
    for file in [photo, other] {
        guard let r = pending(file, memory) else { continue }
        #expect(r.transform(for: file, imageSize: size, over: arrival.withMode(.fit)) == nil)
        #expect(r.transform(for: file, imageSize: size, over: arrival.panned(by: CGVector(dx: 50, dy: 0))) == nil)
    }
    #expect(pending(photo, .off) == nil)
}

@Test func folderMemoryNamesTheRuleThatApplied() throws {
    #expect(try #require(pending(photo, .folder)).target(imageSize: size)?.rule == .samePhoto)
    #expect(try #require(pending(photo, .folder)).target(imageSize: otherSize) == nil)
    #expect(try #require(pending(other, .folder)).target(imageSize: size)?.rule == .folderMode)
    #expect(try #require(pending(other, .folder)).target(imageSize: otherSize)?.rule == .folderModeCentreDropped)
    #expect(ViewRestore.Rule.samePhoto.text == "same photo")
    #expect(ViewRestore.Rule.folderMode.text == "folder mode")
    #expect(ViewRestore.Rule.folderModeCentreDropped.text == "folder mode, centre dropped for size")
}

/// Review focus 5: a view saved before M3b for a rotated photo has its stored size (4000x3000); the photo is now laid
/// out at its oriented size (3000x4000), so the view simply does not apply rather than restoring sideways.
@Test func savedViewOfStoredSizeDoesNotApply() {
    let old = SavedView(mode: .actual(2), center: CGPoint(x: 0.2, y: 0.7), imageSize: CGSize(width: 4000, height: 3000))
    let oriented = CGSize(width: 3000, height: 4000)
    #expect(!old.applies(to: oriented))
    let r = ViewRestore(file: photo, view: old, arrival: arrival)
    #expect(r.transform(for: photo, imageSize: oriented, over: arrival) == nil)
}

/// A free zoom is saved with the scale it drew at; a view saved before that (four fields) still reads.
@Test func savedViewKeepsAFreeZoomsScale() {
    let t = ViewTransform(imageSize: size, viewSize: CGSize(width: 2000, height: 1000), mode: .free(2))
    let v = SavedView(t)
    #expect(v.scale == t.scale)
    #expect(SavedView(text: v.text) == v)
    #expect(SavedView(text: "free:2.0 0.5 0.5 6000x4000 0.5")?.scale == 0.5)
    #expect(SavedView(text: "free:2.0 0.5 0.5 6000x4000 -1") == nil)
    #expect(SavedView(ViewTransform(imageSize: size, viewSize: t.viewSize, mode: .fitWidth)).scale == nil)
}

/// Restored in a window of another size: `scale` comes back at the saved scale, `share` at its ratio to Fit.
@Test func restoreCarriesAFreeZoomByShareOrScale() {
    let saved = ViewTransform(imageSize: size, viewSize: CGSize(width: 2000, height: 1000), mode: .free(2))
    let file = URL(fileURLWithPath: "/p/a.jpg")
    let now = ViewTransform(imageSize: size, viewSize: CGSize(width: 1000, height: 500))
    let restore = ViewRestore(file: file, view: SavedView(saved), arrival: now)
    let byScale = restore.transform(for: file, imageSize: size, over: now, carry: .scale)
    #expect(abs((byScale?.scale ?? 0) - saved.scale) < 1e-9)
    #expect(restore.transform(for: file, imageSize: size, over: now, carry: .share)?.mode == .free(2))
}

import CoreGraphics
import Testing
@testable import LoupeCore

// The crop check (owner, 2026-10-28): Vision on the visible part of a zoomed photo, its boxes back in the photo's space.

@Test func cropRegionIsTheVisiblePartOfThePhoto() {
    var t = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 1000, height: 1000),
                          mode: .free(4), center: CGPoint(x: 0.3, y: 0.6))
    let r = SubjectCrop.region(t)!
    #expect(abs(r.minX - 0.175) < 1e-9 && abs(r.minY - 0.475) < 1e-9 && abs(r.width - 0.25) < 1e-9 && abs(r.height - 0.25) < 1e-9)
    t.mode = .fit
    #expect(SubjectCrop.region(t) == nil)   // the whole photo: no crop to look at
    t.mode = .free(1.05)
    #expect(SubjectCrop.region(t) == nil)   // most of it: the photo's own boxes say the same
}

@Test func cropProxyDrawsTheRegionWhole() {
    let image = CGSize(width: 4000, height: 3000)
    let region = CGRect(x: 0.5, y: 0.2, width: 0.25, height: 0.5)   // 1000 × 1500 px
    let size = SubjectCrop.proxySize(region, imageSize: image, side: 1536)
    #expect(size.width == 1000 && size.height == 1500)                 // never above the photo's own pixels
    let t = SubjectCrop.proxyTransform(region, imageSize: image, proxy: size)
    let a = t.viewPoint(forImage: CGPoint(x: 2000, y: 600)), b = t.viewPoint(forImage: CGPoint(x: 3000, y: 2100))
    #expect(abs(a.x) < 1e-6 && abs(a.y) < 1e-6 && abs(b.x - 1000) < 1e-6 && abs(b.y - 1500) < 1e-6)
    let small = SubjectCrop.proxySize(CGRect(x: 0, y: 0, width: 0.9, height: 0.6), imageSize: image, side: 1536)
    #expect(small.width == 1536 && small.height == 768)
}

@Test func cropBoxesGoBackToThePhoto() {
    let region = CGRect(x: 0.5, y: 0.2, width: 0.25, height: 0.5)
    let found = SubjectBoxes(faces: [CGRect(x: 0.2, y: 0.4, width: 0.4, height: 0.2)], people: [], objects: [], saliency: [],
                             searched: [.face], proxySide: 1500)
    let back = SubjectCrop.inPhoto(found, region: region)
    let f = back.faces[0]
    #expect(abs(f.minX - 0.55) < 1e-9 && abs(f.minY - 0.4) < 1e-9 && abs(f.width - 0.1) < 1e-9 && abs(f.height - 0.1) < 1e-9)
    #expect(back.searched == [.face] && back.proxySide == 1500)
}

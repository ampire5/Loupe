import CoreGraphics
import Testing
@testable import LoupeCore

// Smart zoom spec §5: Vision's rects into the photo's top-left space; nothing found where there is nothing.

@Test func visionRectsTurnTopLeft() {
    let r = SubjectDetector.normalised(CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2))
    #expect(abs(r.minX - 0.1) < 1e-12 && abs(r.minY - 0.1) < 1e-12 && r.width == 0.2 && r.height == 0.2)
}

private func image(_ side: Int, draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

@Test func detectorFindsNoFacesOrPeopleOnABlankImage() {
    let white = image(256) { $0.setFillColor(gray: 1, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256)) }
    let boxes = SubjectDetector.boxes(from: white, chain: [.face, .person])!
    #expect(boxes.faces.isEmpty && boxes.people.isEmpty)
    #expect(boxes.saliency.isEmpty && boxes.objects.isEmpty)   // kinds the chain does not name are not looked for
    #expect(boxes.searched == [.face, .person])
}

@Test func detectorFindsSaliencyOnAShape() {
    let disc = image(512) {
        $0.setFillColor(gray: 0, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        $0.setFillColor(red: 1, green: 0.2, blue: 0.1, alpha: 1); $0.fillEllipse(in: CGRect(x: 340, y: 200, width: 120, height: 120))
    }
    let boxes = SubjectDetector.boxes(from: disc, chain: [.saliency])!
    #expect(boxes.saliency.contains { $0.midX > 0.5 })
}

// Vision's attention box is one coarse rect over most of the photo, centred whatever the photo (DSCF0150–0154, a–c:
// 0.45–0.85 of each side): the heat map's hot spot is where the eye goes.
@Test func saliencyIsTheHeatMapsHotSpot() {
    // 10×10, a hot block at columns 6…7, rows 2…3; a warm cell under half the peak elsewhere.
    var heat = [Float](repeating: 0, count: 100)
    for y in 2...3 { for x in 6...7 { heat[y * 10 + x] = 0.8 } }
    heat[9 * 10 + 0] = 0.3
    let r = SubjectDetector.hotSpot(heat, width: 10, height: 10)!
    #expect(abs(r.minX - 0.6) < 1e-9 && abs(r.minY - 0.2) < 1e-9 && abs(r.width - 0.2) < 1e-9 && abs(r.height - 0.2) < 1e-9)
    #expect(SubjectDetector.hotSpot([Float](repeating: 0, count: 100), width: 10, height: 10) == nil)
}

// Two hot places apart (owner's report, 2026-10-28: a face at the top and another place at the bottom made one tall box
// whose centre was on neither): the hot spot is the one with the most heat, not the box round both.
@Test func twoHotPlacesApartGiveTheHotterOne() {
    // 10×20: a 2×2 block at the top (0.9), a 2×3 block at the bottom (0.8, more heat in all), nothing between.
    var heat = [Float](repeating: 0, count: 200)
    for y in 1...2 { for x in 4...5 { heat[y * 10 + x] = 0.9 } }
    for y in 15...17 { for x in 4...5 { heat[y * 10 + x] = 0.8 } }
    let r = SubjectDetector.hotSpot(heat, width: 10, height: 20)!
    #expect(abs(r.minY - 0.75) < 1e-9 && abs(r.height - 0.15) < 1e-9)
    // Cells touching by a corner are one place.
    var diagonal = [Float](repeating: 0, count: 100)
    diagonal[2 * 10 + 2] = 1; diagonal[3 * 10 + 3] = 1
    let d = SubjectDetector.hotSpot(diagonal, width: 10, height: 10)!
    #expect(abs(d.width - 0.2) < 1e-9 && abs(d.height - 0.2) < 1e-9)
}

// 4: the coarse saliency box gave way to the hot spot; 5, 6: boxes out of focus kept apart (gone in 8), the hot spot
// one place, not the box round every hot place; 7: the custom detector's boxes; 8: nothing kept apart for focus.
@Test func boxesVersionVoidsTheBoxesFoundBefore() {
    #expect(SubjectBoxes.version == 8)
}

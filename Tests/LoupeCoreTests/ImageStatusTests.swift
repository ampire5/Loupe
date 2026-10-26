import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

@Suite struct ImageStatusTests {
    private func info(type: String = "public.jpeg", orientation: ImageOrientation = .up, bytes: Int = 52_340_000) -> ImageInfo {
        ImageInfo(pixelSize: PixelSize(width: 10502, height: 14000), typeIdentifier: type, isProgressive: false,
                  fileSize: bytes, colorSpaceName: nil, orientation: orientation)
    }

    private func fit(_ width: CGFloat = 10502, _ height: CGFloat = 14000) -> ViewTransform {
        // 1050.2 × 1400 over 10502×14000: the fit scale is exactly 0.1.
        ViewTransform(imageSize: CGSize(width: width, height: height), viewSize: CGSize(width: width / 10, height: height / 10))
    }

    @Test func aLoadedPhotoHasOneFactOfEachKindInOrder() {
        let facts = ImageStatus.facts(index: 2, count: 150, info: info(), transform: fit())
        #expect(facts.map(\.kind) == ImageStatus.Kind.allCases)
        #expect(facts.map(\.value) == ["3 / 150", "10502×14000", "52.3 MB", "JPEG", "Fit 10 %"])
    }

    /// The size is the photo's as shown: an EXIF 6 photo stored 4000×3000 is 3000×4000 (spec M3b §2.1); as stored with
    /// `exif-orientation=no`.
    @Test func sizeIsTheOrientedOneUnlessTurnedOff() {
        let rotated = ImageInfo(pixelSize: PixelSize(width: 4000, height: 3000), typeIdentifier: "public.jpeg",
                                isProgressive: false, fileSize: 1_000_000, colorSpaceName: nil, orientation: .right)
        let t = ViewTransform(imageSize: CGSize(width: 3000, height: 4000), viewSize: CGSize(width: 300, height: 400))
        let shown = ImageStatus(facts: ImageStatus.facts(index: 0, count: 1, info: rotated, transform: t))
        #expect(shown.value(.size) == "3000×4000")
        let stored = ImageStatus(facts: ImageStatus.facts(index: 0, count: 1, info: rotated, applyingOrientation: false,
                                                          transform: t.withImageSize(CGSize(width: 4000, height: 3000))))
        #expect(stored.value(.size) == "4000×3000")
    }

    /// Until the folder's listing is in, the count is not known: `N / …`, not the interim playlist's `1 / 1`; a pair
    /// is a range.
    @Test func positionIsARangeForAPairAndOpenForAnUncountedFolder() {
        let uncounted = ImageStatus.facts(index: 0, count: 1, counted: false, info: info(), transform: fit())
        #expect(uncounted.first?.value == "1 / …")
        let pair = ImageStatus.facts(index: 11, companion: 12, count: 380, info: info(), transform: fit())
        #expect(pair.first?.value == "12–13 / 380")
    }

    /// Painted as a camera's screen is: yellow is what the user changed, so Fit is not; the weight is quiet; the decode
    /// time goes green, amber, red.
    @Test func tonesSayWhatTheUserChangedAndHowWellItGoes() {
        let fitted = ImageStatus.facts(index: 0, count: 1, info: info(), transform: fit())
        #expect(fitted.first { $0.kind == .zoom }?.tone == .normal)
        #expect(fitted.first { $0.kind == .fileSize }?.tone == .quiet)
        let zoomed = ImageStatus.facts(index: 0, count: 1, info: info(), transform: fit().withMode(.actual(1)))
        #expect(zoomed.first { $0.kind == .zoom }?.tone == .adjusted)
        #expect(ImageStatus.decodeTone(milliseconds: 90) == .good)
        #expect(ImageStatus.decodeTone(milliseconds: 600) == .caution)
        #expect(ImageStatus.decodeTone(milliseconds: 2400) == .warning)
    }

    @Test func fileSizesAreDecimalAndLocaleFree() {
        #expect(ImageStatus.fileSizeText(52_340_000) == "52.3 MB")
        #expect(ImageStatus.fileSizeText(1_300_000_000) == "1.3 GB")
        #expect(ImageStatus.fileSizeText(850_400) == "850 KB")
        #expect(ImageStatus.fileSizeText(512) == "512 bytes")
    }
}

private extension ImageStatus {
    init(facts: [Fact]) {
        self.init()
        self.facts = facts
    }
}

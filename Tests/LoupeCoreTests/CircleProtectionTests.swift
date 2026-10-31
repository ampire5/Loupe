import Foundation
import Testing
@testable import LoupeCore

@Suite(.serialized) struct CircleProtectionTests {
    let image = CGSize(width: 1000, height: 1000)
    let object = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.2)
    func composition(faces: [CGRect], configure: (inout CompositionOptions) -> Void = { _ in }) throws -> SubjectComposition {
        var options = CompositionOptions(); options.margin = 0; options.maxZoom = 4
        configure(&options)
        return try #require(SubjectFraming.composition(.init(faces: faces, people: [], objects: [object], saliency: []),
            kind: .object, options: options, imageSize: image))
    }
    var view: ViewTransform { .init(imageSize: image, viewSize: .init(width: 400, height: 200)) }

    @Test func faceOutsideTheSelectedGroupIsSavedByPanWithoutOutzoom() throws {
        let c = try composition(faces: [.init(x: 0.42, y: 0.36, width: 0.06, height: 0.08)])
        let result = c.transform(view, autoZoom: true, size: 0.5)
        #expect(abs(result.scale - 1) < 1e-9)
        #expect(abs(result.clamped.center.y - 0.46) < 1e-9)
        #expect(c.protectedRegions.count == 1)
    }

    @Test func onlyTheSmallestNecessaryOutzoomIsUsed() throws {
        let c = try composition(faces: [.init(x: 0.42, y: 0.2, width: 0.06, height: 0.08)])
        let result = c.transform(view, autoZoom: true, size: 0.5)
        // Group support ends at y=550, the protected face starts at y=200.
        #expect(abs(result.scale - 200.0 / 350) < 1e-9)
        #expect(abs(result.clamped.center.y - 0.375) < 1e-9)
    }

    @Test func cutAllowanceIsMeasuredPerEdge() throws {
        let c = try composition(faces: [.init(x: 0.42, y: 0.2, width: 0.06, height: 0.08)]) { $0.maxCrop[.face] = 0.05 }
        let result = c.transform(view, autoZoom: true, size: 0.5)
        // Five percent of the 80 px face is 4 px; at most those 4 px may be cut at the top.
        #expect(abs(result.scale - 200.0 / 346) < 1e-9)
        #expect(abs(result.visibleRect.minY - 204) < 1e-8)
    }

    @Test func softGroupMarginDoesNotForceOutzoomForProtection() throws {
        let c = try composition(faces: [.init(x: 0.42, y: 0.36, width: 0.06, height: 0.08)]) { $0.margin = 0.5 }
        let result = c.transform(view, autoZoom: true, size: 1)
        #expect(abs(result.scale - 1) < 1e-9)
        #expect(abs(result.clamped.center.y - 0.46) < 1e-9)
    }

    @Test func paddingIsPartOfTheProtectedRegion() throws {
        let c = try composition(faces: [.init(x: 0.42, y: 0.2, width: 0.06, height: 0.08)]) { $0.protectionMargins[.face] = 0.1 }
        let result = c.transform(view, autoZoom: true, size: 0.5)
        #expect(abs(result.scale - 200.0 / 358) < 1e-9)
    }

    @Test func selectedScopeAndExplicitOffDoNotProtectOtherClasses() throws {
        for configure: (inout CompositionOptions) -> Void in [
            { $0.protectionScope = .selected }, { $0.maxCrop[.face] = 1 }
        ] {
            let c = try composition(faces: [.init(x: 0.42, y: 0.2, width: 0.06, height: 0.08)], configure: configure)
            #expect(c.protectedRegions.isEmpty)
            #expect(abs(c.transform(view, autoZoom: true, size: 0.5).scale - 1) < 1e-9)
        }
    }

    @Test func everyFaceMustBePreservedIndependently() throws {
        let c = try composition(faces: [.init(x: 0.4, y: 0.05, width: 0.1, height: 0.05),
                                       .init(x: 0.4, y: 0.85, width: 0.1, height: 0.05)])
        let result = c.transform(view, autoZoom: true, size: 0.5)
        #expect(abs(result.scale - 200.0 / 850) < 1e-9)
        #expect(result.visibleRect.minY <= 50 + 1e-8)
        #expect(result.visibleRect.maxY >= 900 - 1e-8)
    }

    @Test func protectionNeverAsksForPixelsOutsideTheSource() throws {
        let c = try composition(faces: [.init(x: -0.03, y: -0.02, width: 0.12, height: 0.12)]) { $0.protectionMargin = 0.5 }
        let region = try #require(c.protectedRegions.first?.rect)
        #expect(region.minX == 0 && region.minY == 0)
        let result = c.transform(view, autoZoom: true, size: 0.5)
        #expect(result.scale >= view.fitScale)
        #expect(result.visibleRect.minY <= 1e-8)
    }

    @Test func keepZoomReportsAnImpossibleProtectionInsteadOfChangingScale() throws {
        let c = try composition(faces: [.init(x: 0.4, y: 0.05, width: 0.1, height: 0.05),
                                       .init(x: 0.4, y: 0.85, width: 0.1, height: 0.05)]) { $0.panOverflow = .keep }
        let result = c.resolve(view.withMode(.actual(1)), autoZoom: false, size: 0.5)
        #expect(result.transform.scale == 1)
        #expect(result.adjustment == .blocked)
    }

    @Test func diagnosticsDistinguishPanFromOutzoom() throws {
        let near = try composition(faces: [.init(x: 0.42, y: 0.36, width: 0.06, height: 0.08)])
        let far = try composition(faces: [.init(x: 0.42, y: 0.2, width: 0.06, height: 0.08)])
        #expect(near.resolve(view, autoZoom: true, size: 0.5).adjustment == .shifted)
        #expect(far.resolve(view, autoZoom: true, size: 0.5).adjustment == .zoomedOut)
    }

    @Test func randomizedProtectionHonoursEachEdgeAndNeverAddsZoom() throws {
        var seed: UInt64 = 42
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1
            return Double(seed >> 11) / Double(UInt64.max >> 11)
        }
        for _ in 0..<100 {
            let face = CGRect(x: random() * 0.8, y: random() * 0.8, width: 0.2, height: 0.2)
            let cut = random() * 0.2
            let protected = try composition(faces: [face]) { $0.maxCrop[.face] = cut }
            let unprotected = try composition(faces: [face]) { $0.maxCrop[.face] = 1 }
            let result = protected.resolve(view, autoZoom: true, size: 0.5).transform
            let plain = unprotected.transform(view, autoZoom: true, size: 0.5)
            let visible = result.visibleRect
            #expect(result.scale <= plain.scale + 1e-9)
            #expect(result.scale >= view.fitScale - 1e-9)
            #expect(visible.minX <= (face.minX + face.width * cut) * 1000 + 1e-7)
            #expect(visible.maxX >= (face.maxX - face.width * cut) * 1000 - 1e-7)
            #expect(visible.minY <= (face.minY + face.height * cut) * 1000 + 1e-7)
            #expect(visible.maxY >= (face.maxY - face.height * cut) * 1000 - 1e-7)
        }
    }
}

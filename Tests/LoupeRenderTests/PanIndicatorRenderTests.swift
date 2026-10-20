import CoreGraphics
import Foundation
import LoupeCore
import Metal
import Testing
@testable import LoupeRender

/// The pan indicator pass (M4b spec §5.3): a compute kernel composites the pills over the finished frame, in place, over
/// the pills' rects only, on the `_srgb` drawable and on its unorm view (the curve-table path), blending in the same
/// light on both.
@Suite struct PanIndicatorRenderTests {
    private static let size = 256
    /// One pill, 100 x 10 px (corner radius 5), well inside the frame.
    private static let pill = PanIndicatorPill(rect: CGRect(x: 60, y: 120, width: 100, height: 10))
    private static let backdropLight = 0.2   // linear light of the frame under the pill

    enum Kind: String, CaseIterable, Sendable { case srgb, unormView }

    /// A 256 x 256 `_srgb` texture that can be read and written by a kernel, and the target of `kind`: itself, or its
    /// unorm view, filled with the same light (the view with its sRGB-encoded value).
    private static func target(_ kind: Kind) throws -> (texture: MTLTexture, target: MTLTexture) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: size, height: size,
                                                         mipmapped: false)
        d.storageMode = .private
        d.usage = [.renderTarget, .shaderRead, .shaderWrite, .pixelFormatView]
        let texture = try #require(MetalContext.shared.device.makeTexture(descriptor: d))
        switch kind {
        case .srgb: return (texture, texture)
        case .unormView: return (texture, try #require(texture.makeTextureView(pixelFormat: .bgra8Unorm)))
        }
    }

    /// Fills `kind`'s target with the backdrop light, runs `body` after it in the same command buffer, reads the bytes.
    private static func frame(_ kind: Kind, _ body: (TileRenderer, MTLCommandBuffer, MTLTexture) -> Void) async throws -> [UInt8] {
        let (texture, target) = try target(kind)
        let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        let v = kind == .srgb ? backdropLight : MetalContext.srgbEncode(backdropLight)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: v, green: v, blue: v, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        try #require(commands.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
        body(TileRenderer(pixelFormat: .bgra8Unorm_srgb), commands, target)
        commands.commit()
        return try await TestImages.readTexture(texture)
    }

    private static func px(_ bytes: [UInt8], _ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int) {
        let o = (y * size + x) * 4
        return (Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2]))
    }

    @Test(arguments: Kind.allCases) func panIndicatorPassTouchesOnlyThePill(kind: Kind) async throws {
        let before = try await Self.frame(kind) { _, _, _ in }
        let after = try await Self.frame(kind) { r, c, t in
            r.encodePanIndicators([Self.pill], alpha: 1, backingScale: 2, into: c, target: t)
        }
        let base = Self.px(before, 10, 10).g
        // Well inside: darker (black at 50 %); on the rim row (an outline pixel): lighter (white at 60 %).
        #expect(Self.px(after, 110, 125).g < base)
        #expect(Self.px(after, 110, 120).g > base)
        // 2 px outside the rect on every side, and every pixel beyond 1 px of the rect: unchanged.
        #expect(Self.px(after, 110, 117) == Self.px(before, 110, 117))
        #expect(Self.px(after, 110, 133) == Self.px(before, 110, 133))
        #expect(Self.px(after, 57, 125) == Self.px(before, 57, 125))
        #expect(Self.px(after, 163, 125) == Self.px(before, 163, 125))
        var stray = 0
        for y in 0..<Self.size {
            for x in 0..<Self.size where !(x >= 59 && x < 161 && y >= 119 && y < 131) {
                if Self.px(after, x, y) != Self.px(before, x, y) { stray += 1 }
            }
        }
        #expect(stray == 0)
        // The rounded end: the corner pixel of the rect is outside the shape, so the frame shows through there.
        #expect(Self.px(after, 60, 120) == Self.px(before, 60, 120))
    }

    @Test(arguments: Kind.allCases) func nothingToDrawLeavesTheFrameAsItIs(kind: Kind) async throws {
        let before = try await Self.frame(kind) { _, _, _ in }
        let none = try await Self.frame(kind) { r, c, t in
            r.encodePanIndicators([], alpha: 1, backingScale: 2, into: c, target: t)
        }
        let clear = try await Self.frame(kind) { r, c, t in
            r.encodePanIndicators([Self.pill], alpha: 0, backingScale: 2, into: c, target: t)
        }
        #expect(none == before)
        #expect(clear == before)
    }

    @Test func bothTargetsBlendInTheSameLight() async throws {
        let a = try await Self.frame(.srgb) { r, c, t in
            r.encodePanIndicators([Self.pill], alpha: 1, backingScale: 2, into: c, target: t)
        }
        let b = try await Self.frame(.unormView) { r, c, t in
            r.encodePanIndicators([Self.pill], alpha: 1, backingScale: 2, into: c, target: t)
        }
        var worst = 0
        for i in 0..<a.count { worst = max(worst, abs(Int(a[i]) - Int(b[i]))) }
        #expect(worst <= 1, "the unorm view differs from the _srgb target by \(worst) codes")
        // Black at 50 % over light 0.2 in linear light: 0.1 -> sRGB byte 89, not the encoded-space 0.5 * 124 = 62.
        #expect(abs(Self.px(a, 110, 125).g - 89) <= 1)
    }

    @Test func halfAlphaIsHalfAsDark() async throws {
        let before = try await Self.frame(.srgb) { _, _, _ in }
        let full = try await Self.frame(.srgb) { r, c, t in
            r.encodePanIndicators([Self.pill], alpha: 1, backingScale: 2, into: c, target: t)
        }
        let half = try await Self.frame(.srgb) { r, c, t in
            r.encodePanIndicators([Self.pill], alpha: 0.5, backingScale: 2, into: c, target: t)
        }
        let b = Self.px(before, 110, 125).g, f = Self.px(full, 110, 125).g, h = Self.px(half, 110, 125).g
        #expect(f < h && h < b)
    }
}

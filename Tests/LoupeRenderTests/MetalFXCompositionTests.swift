import CoreGraphics
import LoupeCore
import Metal
import Testing
@testable import LoupeRender

@Suite struct MetalFXCompositionTests {
    private static func renderer() -> TileRenderer {
        let r = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
        r.resample = ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0)
        return r
    }

    private static func render(_ image: TiledImage, renderer: TileRenderer, scale: Double = 2,
                               orientation: ImageOrientation = .up,
                               center: CGPoint = CGPoint(x: 0.5, y: 0.5)) async throws -> [UInt8] {
        let size = orientation.orientedSize(image.grid.imageSize)
        let transform = ViewTransform(imageSize: CGSize(width: size.width, height: size.height),
                                      viewSize: CGSize(width: 640, height: 360), mode: .actual(scale), center: center)
        let target = TestImages.renderTarget(640, 360)
        let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
        renderer.encode(image: image, transform: transform, orientation: orientation, into: commands, target: target)
        commands.commit()
        return try await TestImages.readTexture(target)
    }

    @Test(arguments: [false, true], [false, true])
    func checkerRunsKeepOwnInput(convertedToP3: Bool, cleaned: Bool) async throws {
        guard MetalContext.shared.supportsMetalFX else { return }
        let image = try await TiledImage.make(from: TestImages.synthetic(400, 240) { x, y in
            let a = 128, v = x + y / 3 < 230 ? 30 : 180
            return (UInt8(v*a/255), UInt8((v+20)*a/255), UInt8((v+40)*a/255), UInt8(a))
        })
        let checker = Self.renderer()
        if cleaned { checker.resample.deband=DebandSettings(mode:.window) }
        let nodes = ColorCube.identity.values.enumerated().map { index,value in
            index%4 == 3 ? Half(1) : Half(Float(value)*0.8+0.05)
        }
        checker.color = ColorFrame(lut:try #require(ColorLUT.make(ColorCube(values:nodes))),mix:0.5)
        if convertedToP3 {
            checker.conversion = PairColorSpace.matrix(from: image.colorSpace, to: CGColorSpace(name: CGColorSpace.displayP3)!)
        }
        checker.transparency = TransparencySettings(colors: CheckerColors(.init(gray: 30), .init(gray: 220)))
        let result = try await Self.render(image,renderer:checker,scale:2.37)
        var expected: [[UInt8]] = []
        for gray in [30,220] {
            let solid = Self.renderer()
            solid.resample.deband=checker.resample.deband
            solid.conversion = checker.conversion
            solid.color = checker.color
            solid.transparency = TransparencySettings(mode:.background,background:.init(gray:UInt8(gray)))
            expected.append(try await Self.render(image,renderer:solid,scale:2.37))
        }
        var differences = 0, maximumDifference = 0
        // Image origin is (-154,-104.4); the default checker cells are 8 px.
        for y in 0..<360 { for x in 0..<640 {
            let cell = (Int(floor((Double(x)+0.5+154)/8)) + Int(floor((Double(y)+0.5+104.4)/8))) & 1
            let offset = (y*640+x)*4
            for c in 0..<4 where result[offset+c] != expected[cell][offset+c] {
                differences += 1
                maximumDifference = max(maximumDifference,abs(Int(result[offset+c])-Int(expected[cell][offset+c])))
            }
        }}
        print("Checker vs solid, P3 \(convertedToP3), deband \(cleaned): \(differences) channels, max \(maximumDifference) codes")
        // Checker and solid compositions may differ by one attachment-rounding code;
        // reject larger or widespread discrepancies, including with FP16 debanding.
        #expect(maximumDifference <= 1 && differences < result.count/1000)
    }

}

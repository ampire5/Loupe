import CoreGraphics
import LoupeCore
import Metal
import Testing
@testable import LoupeRender

@Suite struct DebandInteropTests {
    private static func render(_ image:TiledImage,_ r:TileRenderer,scale:Double=2,
        orientation:ImageOrientation = .up,center:CGPoint=CGPoint(x:0.5,y:0.5)) async throws -> [UInt8] {
        let size=orientation.orientedSize(image.grid.imageSize)
        let t=ViewTransform(imageSize:CGSize(width:size.width,height:size.height),
            viewSize:CGSize(width:320,height:240),mode:.actual(scale),center:center)
        let target=TestImages.renderTarget(320,240)
        let cb=try #require(MetalContext.shared.queue.makeCommandBuffer())
        r.encode(image:image,transform:t,orientation:orientation,into:cb,target:target)
        cb.commit()
        return try await TestImages.readTexture(target)
    }
    @Test(arguments:[ImageOrientation.upMirrored,.rightMirrored],[0.3,8.0])
    func oddCoarseAndNearestKeepStoredGeometry(orientation:ImageOrientation,scale:Double) async throws {
        let image=try await TiledImage.make(from:TestImages.synthetic(3073,2049) { x,y in
            (x/31+y/29)%2==0 ? (40,80,120,255):(210,170,190,255)
        })
        let r=TileRenderer(pixelFormat:.bgra8Unorm_srgb)
        r.resample=ResampleSettings(upscale:.bilinear,upscaleHighPercent:0,downscale:.bilinear,pixelArtPercent:400)
        let center=CGPoint(x:0.61,y:0.57)
        let off=try await Self.render(image,r,scale:scale,orientation:orientation,center:center)
        // Nonzero cleanup forces the FP16/cache path while the expected colour
        // correction remains below a byte, exposing coordinate mistakes.
        r.resample.deband=DebandSettings(mode:.window,strength:0.0001)
        let on=try await Self.render(image,r,scale:scale,orientation:orientation,center:center)
        #expect(r.lastDebandApplied)
        #expect(r.lastLevel == (scale<1 ? 1:0))
        #expect(r.drawnMode == (scale<1 ? .bilinear:.nearest))
        #expect(zip(off,on).allSatisfy { abs(Int($0)-Int($1))<=1 })
    }

    @Test(arguments:DebandRendererTests.filters,GrainStage.allCases)
    func cleanupDoesNotFilterGrainAndSurvivesColorCube(filter:UpscaleFilter,stage:GrainStage) async throws {
        if filter == .metalfx && !MetalContext.shared.supportsMetalFX { return }
        let image=try await TiledImage.make(from:TestImages.synthetic(1537,1025,
            colorSpace:CGColorSpace(name:CGColorSpace.rommrgb)!) { x,y in
            let v=UInt8(64+((x/32+y/64)%16)*4);return (v,v,v,255)
        })
        let r=TileRenderer(pixelFormat:.bgra8Unorm_srgb)
        r.resample=ResampleSettings(upscale:filter,upscaleHighPercent:0,pixelArtPercent:0,
            grain:GrainSettings(style:.fine,amount:2,size:1,stage:stage))
        let values=(0..<ColorCube.dimension*ColorCube.dimension*ColorCube.dimension*4).map { Half($0%4==3 ? 1:0.5) }
        r.color=ColorFrame(lut:try #require(ColorLUT.make(ColorCube(values:values))))
        let off=try await Self.render(image,r)
        r.resample.deband=DebandSettings(mode:.window,strength:1)
        let on=try await Self.render(image,r)
        #expect(r.lastDebandApplied && r.lastColorLUT && r.lastCurveTable)
        #expect(zip(off,on).allSatisfy { abs(Int($0)-Int($1))<=1 })
        #expect(Set(stride(from:0,to:on.count,by:4).map {on[$0]}).count>3)
    }

    @Test func cacheEvictsAndInvalidatesWithoutFollowingDisplaySettings() async throws {
        let a=try await TiledImage.make(from:TestImages.synthetic(800,600) { _,_ in (64,96,128,255) })
        let b=try await TiledImage.make(from:TestImages.synthetic(800,600) { _,_ in (128,64,96,255) })
        let c=try await TiledImage.make(from:TestImages.synthetic(800,600) { _,_ in (96,128,64,255) })
        let r=TileRenderer(pixelFormat:.bgra8Unorm_srgb)
        r.resample=ResampleSettings(upscale:.bilinear,upscaleHighPercent:0,pixelArtPercent:0,
            deband:DebandSettings(mode:.window))
        let first=try await Self.render(a,r)
        #expect(try await Self.render(a,r)==first)
        #expect(r.debandDispatchCount==1)
        #expect(try await Self.render(b,r) != first)
        #expect(try await Self.render(c,r) != first)
        #expect(r.debandDispatchCount==3)
        #expect(try await Self.render(a,r)==first)
        #expect(r.debandDispatchCount==4)
        r.resample.deband.radius=33
        _ = try await Self.render(a,r)
        #expect(r.debandDispatchCount==5)
        r.resample.grain=GrainSettings(style:.fine,amount:2,stage:.after)
        _ = try await Self.render(a,r)
        #expect(r.debandDispatchCount==5)
    }
}

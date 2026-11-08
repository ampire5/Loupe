import CoreGraphics
import LoupeCore
import Metal
import Testing
@testable import LoupeRender

@Suite struct DebandRendererTests {
    static let modes=DebandMode.allCases.filter { $0 != .off }
    static let filters:[UpscaleFilter]=[.bilinear,.kernel(.lanczos3),.ewaLanczos,.metalfx]
    private static func renderer(_ filter:UpscaleFilter = .bilinear) -> TileRenderer {
        let r=TileRenderer(pixelFormat:.bgra8Unorm_srgb)
        r.resample=ResampleSettings(upscale:filter,upscaleHighPercent:0,pixelArtPercent:0)
        return r
    }
    private static func render(_ image:TiledImage, _ r:TileRenderer, scale:Double=2,
        center:CGPoint=CGPoint(x:0.5,y:0.5),orientation:ImageOrientation = .up,
        viewport:CGRect?=nil) async throws -> [UInt8] {
        let size=orientation.orientedSize(image.grid.imageSize)
        let t=ViewTransform(imageSize:CGSize(width:size.width,height:size.height),
            viewSize:CGSize(width:320,height:240),mode:.actual(scale),center:center)
        let target=TestImages.renderTarget(320,240)
        let cb=try #require(MetalContext.shared.queue.makeCommandBuffer())
        r.encode(image:image,transform:t,orientation:orientation,into:cb,target:target,viewport:viewport)
        cb.commit()
        return try await TestImages.readTexture(target)
    }

    @Test(arguments:modes,filters)
    func smoothsQuantizedGradient(mode:DebandMode,filter:UpscaleFilter) async throws {
        if filter == .metalfx && !MetalContext.shared.supportsMetalFX { return }
        let image=try await TiledImage.make(from:TestImages.synthetic(1536,768) { x,_ in
            let v=UInt8(64+(x/64)*4+2);return (v,v,v,255)
        })
        let r=Self.renderer(filter)
        let off=try await Self.render(image,r)
        r.resample.deband=DebandSettings(mode:mode,strength:1,threshold:12,radius:32)
        let on=try await Self.render(image,r)
        #expect(r.lastDebandApplied && r.debandAllocatedBytes>0 && on != off)
        func error(_ bytes:[UInt8]) -> Double {
            var result=0.0
            for y in 80..<160 { for x in 0..<320 {
                let source=688.0+(Double(x)+0.5)/2-0.5
                let ideal=64+(source+0.5)/16
                result += pow(Double(bytes[(y*320+x)*4])-ideal,2)
            }}
            return result/(80*320)
        }
        let before=error(off),after=error(on)
        print("Deband \(mode) gradient MSE: \(before) -> \(after)")
        #expect(after<before*0.95)
        #expect(try await Self.render(image,r)==on,"Spatial sampling must not animate between frames")
    }

    @Test(arguments:filters)
    func compactWindowsKeepGeometryAndOffBypasses(filter:UpscaleFilter) async throws {
        if filter == .metalfx && !MetalContext.shared.supportsMetalFX { return }
        let image=try await TiledImage.make(from:TestImages.synthetic(3072,2048) { x,y in
            (x/7+y/11)%2==0 ? (40,80,120,255):(210,170,190,255)
        })
        let r=Self.renderer(filter)
        let center=CGPoint(x:0.6,y:0.6)
        let off=try await Self.render(image,r,center:center,orientation:.right)
        r.resample.deband=DebandSettings(mode:.window,strength:1)
        let first=try await Self.render(image,r,center:center,orientation:.right)
        #expect(r.lastDebandApplied)
        #expect(zip(off,first).allSatisfy { abs(Int($0)-Int($1))<=2 })
        let count=r.debandDispatchCount
        #expect(try await Self.render(image,r,center:center,orientation:.right)==first)
        #expect(r.debandDispatchCount==count)
        let clipped=try await Self.render(image,r,center:center,orientation:.right,
            viewport:CGRect(x:37,y:29,width:201,height:151))
        var errors=0
        for y in 29..<180 { for x in 37..<238 {
            for c in 0..<4 where abs(Int(first[(y*320+x)*4+c])-Int(clipped[(y*320+x)*4+c]))>1 { errors+=1 }
        }}
        #expect(errors==0)
        r.resample.deband.mode = .off
        #expect(try await Self.render(image,r,center:center,orientation:.right)==off)
        #expect(!r.lastDebandApplied && r.debandAllocatedBytes==0)
    }

    @Test(arguments:modes)
    func protectsSharpEdgeAndTransparentBackground(mode:DebandMode) async throws {
        let sharp=try await TiledImage.make(from:TestImages.synthetic(800,600) { x,_ in
            let v:UInt8=x<400 ? 40:210;return (v,v,v,255)
        })
        let alpha=try await TiledImage.make(from:TestImages.synthetic(800,600) { x,_ in
            x<400 ? (0,0,0,0):(75,75,75,128)
        })
        let r=Self.renderer()
        let edgeOff=try await Self.render(sharp,r)
        let alphaOff=try await Self.render(alpha,r)
        r.resample.deband=DebandSettings(mode:mode,strength:1,threshold:9,radius:32)
        let edgeOn=try await Self.render(sharp,r)
        let alphaOn=try await Self.render(alpha,r)
        #expect(zip(edgeOn,edgeOff).allSatisfy { abs(Int($0)-Int($1))<=1 })
        #expect(zip(alphaOn,alphaOff).allSatisfy { abs(Int($0)-Int($1))<=1 })
    }

    @Test func cacheBudgetAndUniformABI() async throws {
        #expect(MemoryLayout<DebandCache.Parameters>.stride==64)
        let image=try await TiledImage.make(from:TestImages.synthetic(800,600) { _,_ in (128,128,128,255) })
        let transform=ViewTransform(imageSize:CGSize(width:800,height:600),viewSize:CGSize(width:320,height:240),mode:.actual(2))
        let frame=try #require(LevelFrame(image:image,transform:transform,orientation:.up))
        let cache=DebandCache(byteLimit:1)
        let cb=try #require(MetalContext.shared.queue.makeCommandBuffer())
        #expect(cache.prepare(frame,settings:DebandSettings(mode:.window),context:.shared,commandBuffer:cb)==nil)
        #expect(cache.failure != nil && cache.allocatedBytes==0 && cache.dispatches==0)
        let failure=cache.failure
        #expect(cache.prepare(frame,settings:DebandSettings(mode:.window),context:.shared,commandBuffer:cb)==nil)
        #expect(cache.failure==failure && cache.dispatches==0)
        cache.clear()
        #expect(cache.failure==nil && cache.allocatedBytes==0)
        cb.commit()
        let context=MetalContext.shared
        var reflection:MTLComputePipelineReflection?
        _ = try context.device.makeComputePipelineState(function:context.debandFunction,
            options:[.bindingInfo,.bufferTypeInfo],reflection:&reflection)
        let binding=try #require(reflection?.bindings.first { $0.name=="p" } as? MTLBufferBinding)
        #expect(binding.bufferDataSize==64)
    }
}

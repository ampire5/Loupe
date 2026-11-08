import CoreGraphics
import LoupeCore
import Metal
import Testing
@testable import LoupeRender

@Suite struct DisplayGrainTests {
    @Test(arguments: filters)
    func afterStageStaysInScreenPixels(filter: UpscaleFilter) async throws {
        if filter == .metalfx && !MetalContext.shared.supportsMetalFX { return }
        let image=try await TiledImage.make(from:TestImages.synthetic(400,300) { _,_ in (128,128,128,255) })
        let (config,_)=Config.parse("grain=white\ngrain-amount=3\ngrain-stage=after")
        var settings=ResampleSettings(upscale:filter,upscaleHighPercent:0,pixelArtPercent:0)
        settings.grain=GrainSettings(config:config)
        let original=try await Self.render(image,settings:settings)
        let zoomed=try await Self.render(image,settings:settings,scale:4)
        let panned=try await Self.render(image,settings:settings,center:CGPoint(x:0.51,y:0.5),orientation:.right)
        #expect(zip(original,zoomed).allSatisfy { abs(Int($0)-Int($1))<=1 })
        #expect(zip(original,panned).allSatisfy { abs(Int($0)-Int($1))<=1 })
        let clipped=try await Self.render(image,settings:settings,viewport:CGRect(x:37,y:29,width:201,height:151))
        var errors=0
        for y in 29..<180 { for x in 37..<238 {
            if abs(Int(original[(y*320+x)*4])-Int(clipped[(y*320+x)*4]))>1 { errors+=1 }
        }}
        #expect(errors==0, "Post-upscale grain must preserve screen phase in a clipped page")
        let reduced=try await Self.render(image,settings:settings,scale:0.75)
        var reducedErrors=0
        for y in 90..<150 { for x in 120..<200 {
            if abs(Int(original[(y*320+x)*4])-Int(reduced[(y*320+x)*4]))>1 { reducedErrors+=1 }
        }}
        #expect(reducedErrors==0, "Post-upscale grain must keep its screen size below 100% too")
    }

    static func render(_ image: TiledImage, settings: ResampleSettings,
                       color: ColorFrame? = nil, scale: Double = 2,
                       center: CGPoint = CGPoint(x: 0.5, y: 0.5),
                       orientation: ImageOrientation = .up, viewport: CGRect? = nil) async throws -> [UInt8] {
        let r = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
        r.resample = settings; r.color = color
        let target = TestImages.renderTarget(320, 240)
        let cb = try #require(MetalContext.shared.queue.makeCommandBuffer())
        let size=orientation.orientedSize(image.grid.imageSize)
        let t = ViewTransform(imageSize: CGSize(width:size.width,height:size.height), viewSize: CGSize(width: 320, height: 240),
                              mode: .actual(scale), center: center)
        r.encode(image: image, transform: t, orientation:orientation, into: cb, target: target, viewport:viewport)
        cb.commit()
        return try await TestImages.readTexture(target)
    }

    /// A noise pattern painted onto the screen fails both comparisons: moving
    /// the image must carry its grain, and zooming must enlarge that same field.
    @Test(arguments: GrainStyle.allCases.filter { $0 != .off }, ["bilinear","lanczos3","ewa-lanczos","metalfx","nearest"])
    func grainFollowsSourceThroughPanAndZoom(style: GrainStyle, path: String) async throws {
        if path == "metalfx" && !MetalContext.shared.supportsMetalFX { return }
        let image = try await TiledImage.make(from: TestImages.synthetic(400,300) { _,_ in (128,128,128,255) })
        let settings = ResampleSettings(upscale:UpscaleFilter(text:path) ?? .bilinear,upscaleHighPercent:0,
                                       pixelArtPercent:path == "nearest" ? 100 : 0,
                                       grain:GrainSettings(style:style,amount:3,size:1))
        let original = try await Self.render(image,settings:settings)
        let panned = try await Self.render(image,settings:settings,center:CGPoint(x:0.5+1.0/400,y:0.5))
        // At x=160 the 2x sample is source x=200.25; the eighth-source-pixel
        // center adjustment aligns the 4x sample with it and every second pixel.
        let zoomed = try await Self.render(image,settings:settings,scale:4,
                                          center:CGPoint(x:0.5+0.125/400,y:0.5+0.125/300))
        var panErrors=0,zoomErrors=0
        for y in 100..<120 { for x in 140..<180 {
            let a=Int(original[(y*320+x)*4])
            if abs(a-Int(panned[(y*320+x-2)*4]))>1 { panErrors+=1 }
            let zx=160+(x-160)*2,zy=120+(y-120)*2
            if abs(a-Int(zoomed[(zy*320+zx)*4]))>1 { zoomErrors+=1 }
        }}
        #expect(panErrors==0)
        #expect(zoomErrors==0)
    }

    @Test(arguments: filters)
    func sourceFieldSurvivesOrientationAndCoarsePreview(filter: UpscaleFilter) async throws {
        if filter == .metalfx && !MetalContext.shared.supportsMetalFX { return }
        let full=try await TiledImage.make(from:TestImages.synthetic(1001,601) { _,_ in (128,128,128,255) })
        let preview=TiledImage.empty(grid:full.grid,colorSpace:full.colorSpace)
        try await preview.upload(LevelImage(image:TestImages.synthetic(501,301) { _,_ in (128,128,128,255) },level:1))
        let settings=ResampleSettings(upscale:filter,upscaleHighPercent:0,pixelArtPercent:0,
                                     grain:GrainSettings(style:.white,amount:3,size:1))
        let plain=try await Self.render(full,settings:settings)
        let turned=try await Self.render(full,settings:settings,orientation:.down)
        let right=try await Self.render(full,settings:settings,orientation:.right)
        for y in 100..<140 { for x in 140..<180 {
            #expect(abs(Int(turned[(y*320+x)*4])-Int(plain[((239-y)*320+319-x)*4]))<=1)
            let sx=160+y-120,sy=120-(x-160)-1
            #expect(abs(Int(right[(y*320+x)*4])-Int(plain[(sy*320+sx)*4]))<=1)
        }}
        for orientation in [ImageOrientation.up,.down,.right] {
            let fine=try await Self.render(full,settings:settings,scale:0.6,orientation:orientation)
            let coarse=try await Self.render(preview,settings:settings,scale:0.6,orientation:orientation)
            // On this uniform fixture, changing only resident level must not
            // change grain phase, frequency, or minification filtering.
            var errors=0
            for y in 70..<170 { for x in 110..<210 {
                if abs(Int(fine[(y*320+x)*4])-Int(coarse[(y*320+x)*4]))>1 { errors+=1 }
            }}
            #expect(errors==0)
        }
    }

    @Test func metalFXDoesNotReconstructGrain() async throws {
        guard MetalContext.shared.supportsMetalFX else { return }
        let image=try await TiledImage.make(from:TestImages.synthetic(400,300) { _,_ in (128,128,128,255) })
        var settings=ResampleSettings(upscale:.bilinear,upscaleHighPercent:0,pixelArtPercent:0,
                                     grain:GrainSettings(style:.white,amount:3,size:1))
        let plain=try await Self.render(image,settings:settings,scale:2.37,orientation:.right)
        settings.upscale = .metalfx
        let fx=try await Self.render(image,settings:settings,scale:2.37,orientation:.right)
        let limited=try await Self.render(image,settings:settings,scale:2.37,orientation:.right)
        #expect(zip(plain,fx).allSatisfy { abs(Int($0)-Int($1))<=1 })
        #expect(fx==limited)
    }

    @Test(arguments: GrainStyle.allCases.filter { $0 != .off }, [0.5,1.0,1.25,4.0])
    func sourceNoiseIsBilinearlyFiltered(style: GrainStyle, size: Double) async throws {
        let image=try await TiledImage.make(from:TestImages.synthetic(400,300) { _,_ in (128,128,128,255) })
        let settings=ResampleSettings(upscale:.bilinear,upscaleHighPercent:0,downscale:.bilinear,pixelArtPercent:0,
                                     grain:GrainSettings(style:style,amount:3,size:size))
        let source=try await Self.render(image,settings:settings,scale:1)
        let enlarged=try await Self.render(image,settings:settings,scale:2)
        var errors=0
        for y in 20..<220 { for x in 20..<300 {
            // Even output coordinates sample .75 of the next source pixel on
            // both axes. The 1x capture exposes the discrete source samples.
            let sx=159+(x-160)/2,sy=119+(y-120)/2
            if (x-160)%2 != 0 || (y-120)%2 != 0 { continue }
            let expected=Double(source[(sy*320+sx)*4]) * 0.0625
                + Double(source[(sy*320+sx+1)*4]) * 0.1875
                + Double(source[((sy+1)*320+sx)*4]) * 0.1875
                + Double(source[((sy+1)*320+sx+1)*4]) * 0.5625
            if abs(Double(enlarged[(y*320+x)*4])-expected)>1 { errors+=1 }
        }}
        #expect(errors==0)
    }

    @Test(arguments: filters)
    func sourceExtentClampsGrainAndLeavesBackground(filter: UpscaleFilter) async throws {
        if filter == .metalfx && !MetalContext.shared.supportsMetalFX { return }
        let image=try await TiledImage.make(from:TestImages.synthetic(1,1) { _,_ in (128,128,128,255) })
        var settings=ResampleSettings(upscale:filter,upscaleHighPercent:0,pixelArtPercent:0)
        let off=try await Self.render(image,settings:settings,scale:64)
        settings.grain=GrainSettings(style:.white,amount:3,size:1)
        let on=try await Self.render(image,settings:settings,scale:64)
        var imageValues=Set<UInt8>(),backgroundChanges=0
        for y in 0..<240 { for x in 0..<320 {
            let i=(y*320+x)*4
            if (128..<192).contains(x) && (88..<152).contains(y) { imageValues.insert(on[i]) }
            else if on[i] != off[i] { backgroundChanges+=1 }
        }}
        #expect(imageValues.count==1 && backgroundChanges==0)
    }

    @Test func minificationSuppressesUnresolvedNoise() async throws {
        let image=try await TiledImage.make(from:TestImages.synthetic(400,300) { _,_ in (128,128,128,255) })
        let settings=ResampleSettings(upscale:.bilinear,upscaleHighPercent:0,downscale:.bilinear,pixelArtPercent:0,
                                     grain:GrainSettings(style:.white,amount:3,size:1))
        let source=try await Self.render(image,settings:settings,scale:1)
        let reduced=try await Self.render(image,settings:settings,scale:0.25)
        var sourceEnergy=0.0,reducedEnergy=0.0
        for y in 90..<150 { for x in 120..<200 {
            let i=(y*320+x)*4
            sourceEnergy += pow(Double(source[i])-128,2)
            reducedEnergy += pow(Double(reduced[i])-128,2)
        }}
        #expect(reducedEnergy < sourceEnergy*0.35)
        #expect(reducedEnergy > 0)
    }

    @Test func minificationStartsContinuouslyAtActualSize() async throws {
        let image=try await TiledImage.make(from:TestImages.synthetic(400,300) { _,_ in (128,128,128,255) })
        let settings=ResampleSettings(upscale:.bilinear,upscaleHighPercent:0,downscale:.bilinear,pixelArtPercent:0,
                                     grain:GrainSettings(style:.white,amount:3,size:1))
        let actual=try await Self.render(image,settings:settings,scale:1)
        let justBelow=try await Self.render(image,settings:settings,scale:0.9999)
        var difference=0.0
        for y in 100..<140 { for x in 140..<180 {
            difference += abs(Double(actual[(y*320+x)*4])-Double(justBelow[(y*320+x)*4]))
        }}
        let mean=difference/1600
        print("Grain crossing 100% mean RGB8 change: \(mean)")
        #expect(mean < 0.15, "An infinitesimal zoom must not suddenly blur the source grain")
    }

    @Test(arguments: GrainStyle.allCases.filter { $0 != .off }, GrainStage.allCases)
    func stableMonochromeGrain(style: GrainStyle, stage: GrainStage) async throws {
        let image = try await TiledImage.make(from: TestImages.synthetic(400, 300) { _, _ in (128,128,128,255) })
        var settings = ResampleSettings(upscale: .bilinear, upscaleHighPercent: 0, pixelArtPercent: 0)
        let original = try await Self.render(image, settings: settings)
        settings.grain = GrainSettings(style: style, amount: 2, size: 1.25, stage:stage)
        let first = try await Self.render(image, settings: settings)
        #expect(first != original)
        #expect(try await Self.render(image, settings: settings) == first)
        var mean = 0.0, square = 0.0
        for i in stride(from: 0, to: first.count, by: 4) {
            #expect(first[i] == first[i+1] && first[i] == first[i+2] && first[i+3] == 255)
            let delta = Double(first[i])-128
            mean += delta; square += delta*delta
        }
        let n = Double(first.count/4), rms = (square/n).squareRoot()
        #expect(abs(mean/n) < 0.15 && (0.8...3).contains(rms))
    }

    static let filters: [UpscaleFilter] = [.bilinear, .kernel(.lanczos3), .ewaLanczos, .metalfx]

    @Test(arguments: filters, GrainStage.allCases)
    func alphaAndAfterColorOnEveryPath(filter: UpscaleFilter, stage: GrainStage) async throws {
        if filter == .metalfx && !MetalContext.shared.supportsMetalFX { return }
        let image = try await TiledImage.make(from: TestImages.synthetic(400,300) { x,_ in
            x < 200 ? (0,0,0,0) : (64,64,64,128)
        })
        var settings = ResampleSettings(upscale:filter,upscaleHighPercent:0,pixelArtPercent:0)
        let off = try await Self.render(image,settings:settings)
        settings.grain = GrainSettings(style:.soft,amount:3,size:1,stage:stage)
        let on = try await Self.render(image,settings:settings)
        var backgroundChanges = 0, imageChanges = 0
        for y in 0..<240 { for x in 0..<320 {
            let i=(y*320+x)*4
            if x < 100 && on[i] != off[i] { backgroundChanges += 1 }
            if x > 200 && on[i] != off[i] { imageChanges += 1 }
        }}
        #expect(backgroundChanges == 0 && imageChanges > 0)

        // A cube that makes every pixel middle gray. Grain must survive it;
        // applying grain before this cube would remove all variation.
        let opaque = try await TiledImage.make(from: TestImages.synthetic(400,300) { _,_ in (70,90,120,255) })
        let values = (0..<ColorCube.dimension*ColorCube.dimension*ColorCube.dimension*4).map { Half($0%4 == 3 ? 1 : 0.5) }
        let lut = try #require(ColorLUT.make(ColorCube(values:values)))
        let result = try await Self.render(opaque,settings:settings,color:ColorFrame(lut:lut))
        let levels = Set(stride(from:0,to:result.count,by:4).map { result[$0] })
        #expect(levels.count > 3)
        // Zero strength preserves the exact no-grain output even with a selected style.
        settings.grain.amount = 0
        let baseline = ResampleSettings(upscale:filter,upscaleHighPercent:0,pixelArtPercent:0)
        #expect(try await Self.render(opaque,settings:settings) == Self.render(opaque,settings:baseline))
    }

    @Test func stylesAndSizeAreDistinct() async throws {
        let image = try await TiledImage.make(from: TestImages.synthetic(400,300) { _,_ in (128,128,128,255) })
        var signatures = Set<UInt64>()
        for style in GrainStyle.allCases where style != .off {
            var s = ResampleSettings(upscale:.bilinear,upscaleHighPercent:0,pixelArtPercent:0,
                                     grain:GrainSettings(style:style,amount:3,size:1))
            let small = try await Self.render(image,settings:s)
            s.grain.size = 2
            let big = try await Self.render(image,settings:s)
            #expect(small != big)
            let signature = small.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            signatures.insert(signature)
        }
        #expect(signatures.count == 5)
    }

    @Test(arguments: [false,true], GrainStage.allCases)
    func nearestAndTableCurve(table: Bool, stage: GrainStage) async throws {
        let space = CGColorSpace(name: table ? CGColorSpace.rommrgb : CGColorSpace.sRGB)!
        let image = try await TiledImage.make(from:TestImages.synthetic(400,300,colorSpace:space) { _,_ in (120,120,120,255) })
        var s = ResampleSettings(pixelArtPercent:100)
        let off = try await Self.render(image,settings:s)
        s.grain = GrainSettings(style:.fine,amount:2,size:1,stage:stage)
        let on = try await Self.render(image,settings:s)
        let again = try await Self.render(image,settings:s)
        #expect(on != off && on == again)
        if stage == .after {
            let zoomed=try await Self.render(image,settings:s,scale:4,center:CGPoint(x:0.51,y:0.49))
            #expect(zip(on,zoomed).allSatisfy { abs(Int($0)-Int($1))<=1 })
        }
        s.grain.style = .off
        #expect(try await Self.render(image,settings:s) == off)
    }

    @Test func effectsUniformsMatchMetal() throws {
        #expect(MemoryLayout<GrainParams>.stride == 40)
        #expect(MemoryLayout<MetalFXSourceParams>.stride == 16)
        let c = MetalContext.shared, descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = c.library.makeFunction(name:"metalfxVertex")
        descriptor.fragmentFunction = MetalContext.function(c.library,"metalfxFragment",alpha:true,colorLUT:true)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        var reflection: MTLRenderPipelineReflection?
        _ = try c.device.makeRenderPipelineState(descriptor:descriptor,options:[.bindingInfo,.bufferTypeInfo],reflection:&reflection)
        let bindings = try #require(reflection?.fragmentBindings)
        let grain = try #require(bindings.first { $0.name == "grain" } as? MTLBufferBinding)
        let effects = try #require(bindings.first { $0.name == "sourceInfo" } as? MTLBufferBinding)
        #expect(grain.index == 3 && grain.bufferDataSize == MemoryLayout<GrainParams>.stride)
        let grainOffsets=Dictionary(uniqueKeysWithValues:grain.bufferStructType!.members.map { ($0.name,$0.offset) })
        #expect(grainOffsets == ["amount":0,"size":4,"seed":8,"filterRadius":12,"sourceSize":16,"levelFactor":24,"sourceFootprint":28,"stage":32,"pad":36])
        #expect(effects.index == 4 && effects.bufferDataSize == MemoryLayout<MetalFXSourceParams>.stride)
        let offsets = Dictionary(uniqueKeysWithValues: effects.bufferStructType!.members.map { ($0.name,$0.offset) })
        #expect(offsets == ["contentSize":0,"highPrecision":8,"pad":12])
    }
}

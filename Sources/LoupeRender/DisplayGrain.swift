import Foundation
import LoupeCore
import Metal

enum DisplayGrain {
    private final class Locator {}
    /// Same app/framework/CLI locations as SwiftPM's generated accessor, but a
    /// missing optional resource bundle must not call that accessor's fatalError.
    private static let resources: Bundle? = {
        [Bundle.main.resourceURL, Bundle(for: Locator.self).resourceURL, Bundle.main.bundleURL]
            .compactMap { $0 }.lazy.compactMap { Bundle(url: $0.appendingPathComponent("Loupe_LoupeRender.bundle")) }.first
    }()
    /// Called only by render-thread preparation. Each bank is 128 KiB; no
    /// per-frame synthesis, analysis, viewport-sized texture or temporal state.
    static func load(_ style: GrainStyle, device: MTLDevice) -> MTLTexture? {
        guard style != .off,
              let url = resources?.url(forResource: style.rawValue, withExtension: "r16f", subdirectory: "GrainTemplates"),
              let data = try? Data(contentsOf: url), data.count == 131072 else { return nil }
        let side = style == .av1 || style == .particles ? 64 : 128
        let layers = 65536 / (side*side)
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray; d.pixelFormat = .r16Float
        d.width = side; d.height = side; d.arrayLength = layers
        d.storageMode = .shared; d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        data.withUnsafeBytes { bytes in
            for layer in 0..<layers {
                texture.replace(region: MTLRegionMake2D(0,0,side,side), mipmapLevel: 0, slice: layer,
                    withBytes: bytes.baseAddress!.advanced(by: layer*side*side*2), bytesPerRow: side*2, bytesPerImage: side*side*2)
            }
        }
        texture.label = "display grain \(style.rawValue)"
        return texture
    }

    static let source = #"""
    struct GrainParams {
        float amount; float size; uint seed; float filterRadius;
        float2 sourceSize; float levelFactor; float sourceFootprint;
        uint stage; uint pad;
    };
    uint grainHash(uint v) { v^=v>>16;v*=0x7feb352du;v^=v>>15;v*=0x846ca68bu;return v^(v>>16); }
    float grainTile(texture2d_array<float,access::sample> t,int2 block,float2 local,uint seed) {
        constexpr sampler sm(coord::normalized,address::repeat,filter::linear);
        uint h=grainHash(as_type<uint>(block.x)*92821u+as_type<uint>(block.y)*68917u+seed);
        uint mask=t.get_width()-1u,bits=t.get_width()==64u?6u:7u;
        return t.sample(sm,(local+float2(h&mask,(h>>bits)&mask)+.5f)/float(t.get_width()),
                        (h>>(2u*bits))&(t.get_array_size()-1u)).r;
    }
    float grainPair(float a,float b,float t) { float x=1.f-t;return (a*x+b*t)*rsqrt(x*x+t*t); }
    float grainNoise(texture2d_array<float,access::sample> tex,float2 pos,uint seed) {
        int2 block=int2(floor(pos/64.f));float2 local=pos-float2(block)*64.f;
        float v=grainTile(tex,block,local,seed);
        float tx=smoothstep(0.f,4.f,local.x),ty=smoothstep(0.f,4.f,local.y);
        if(local.x<4.f)v=grainPair(grainTile(tex,block-int2(1,0),local+float2(64,0),seed),v,tx);
        if(local.y<4.f){float upper=grainTile(tex,block-int2(0,1),local+float2(0,64),seed);
            if(local.x<4.f)upper=grainPair(grainTile(tex,block-int2(1,1),local+float2(64,64),seed),upper,tx);
            v=grainPair(upper,v,ty);}
        return v;
    }
    // The field belongs to discrete full-resolution source pixels, even while
    // the image is drawn from a coarse pyramid. Interpolate its four values
    // independently: MetalFX and the image reconstruction never see the noise.
    float grainSourceValue(texture2d_array<float,access::sample> tex,float2 index,constant GrainParams& g) {
        index=clamp(index,float2(0.f),g.sourceSize-1.f);
        return grainNoise(tex,index/g.size,g.seed);
    }
    float grainBilinear(texture2d_array<float,access::sample> tex,float2 pos,constant GrainParams& g) {
        float2 b=floor(pos),f=fract(pos);
        float a=grainSourceValue(tex,b,g),b0=grainSourceValue(tex,b+float2(1,0),g);
        float c=grainSourceValue(tex,b+float2(0,1),g),d=grainSourceValue(tex,b+1.f,g);
        return mix(mix(a,b0,f.x),mix(c,d,f.x),f.y);
    }
    float grainFiltered(texture2d_array<float,access::sample> tex,float2 pos,constant GrainParams& g) {
        if(g.sourceFootprint<=1.f)return grainBilinear(tex,pos,g);
        // A fixed four-stratum box approximation bounds work at any reduction.
        // Beyond its sampling capacity, attenuate unresolved noise rather than
        // retaining a full-amplitude aliased field. Neither rule uses image data
        // or the selected pyramid level.
        // Add only the footprint beyond native size: the radius tends to zero
        // at 100%, avoiding an abrupt change from point to box filtering.
        float d=g.filterRadius;
        float n=grainBilinear(tex,pos+float2(-d,-d),g)+grainBilinear(tex,pos+float2(d,-d),g)
               +grainBilinear(tex,pos+float2(-d,d),g)+grainBilinear(tex,pos+float2(d,d),g);
        return n*.25f*min(1.f,2.f*g.size/g.sourceFootprint);
    }
    float4 displayGrain(float4 c,float coverage,float2 storedLevelCenter,float2 outputPosition,
                        texture2d_array<float,access::sample> tex,constant GrainParams& g) {
        if(g.amount<=0.f || coverage<=0.f)return c;
        float3 e=linearToSRGB(c.rgb);
        float n;
        if(g.stage==0u)n=grainFiltered(tex,storedLevelCenter*g.levelFactor-.5f,g);
        else n=grainNoise(tex,floor(outputPosition)/g.size,g.seed);
        n*=g.amount*(1.f/255.f)*saturate(coverage);
        float room=max(0.f,min(min(e.r,min(e.g,e.b)),1.f-max(e.r,max(e.g,e.b))));
        n=clamp(n,-room,room);
        return float4(srgbToLinear(e+n),c.a);
    }
    """#
}

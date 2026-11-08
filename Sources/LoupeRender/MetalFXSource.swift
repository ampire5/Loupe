/// Source geometry shared by MetalFX output sampling and grain alpha coverage.
enum MetalFXSource {
    static let source = #"""
    struct MetalFXSourceParams { uint2 contentSize; uint highPrecision; uint pad; };
    float4 metalfxSource(texture2d_array<float,access::read> slots,int2 q,
                          constant MetalFXComposeParams& p) {
        int2 j=p.origin+q;
        int2 s=int2(p.orient.x*j.x+p.orient.y*j.y,p.orient.z*j.x+p.orient.w*j.y)+p.shift;
        s=clamp(s,int2(0),int2(p.levelSize)-1);
        int2 tile=s/int(kTileSize);
        return slots.read(uint2(s-tile*int(kTileSize)+int(kApron)),uint(tile.y)*p.columns+uint(tile.x)-p.sliceOffset);
    }
    float metalfxCoverage(texture2d_array<float,access::read> slots,float2 position,
                           constant MetalFXComposeParams& p,constant MetalFXSourceParams& e) {
        int2 b=int2(floor(position));float2 f=fract(position);float a[4];
        for(int j=0;j<2;j++)for(int i=0;i<2;i++){
            int2 q=clamp(b+int2(i,j),int2(0),int2(e.contentSize)-1);
            a[j*2+i]=metalfxSource(slots,q,p).a;}
        return mix(mix(a[0],a[1],f.x),mix(a[2],a[3],f.x),f.y);
    }
    """#
}

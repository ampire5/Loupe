// Spatial debanding ported from FrameScrub; GPL-3.0 per the repository LICENSE.
// Reference mode is the separate LGPL adaptation in ReferenceDebandKernels.swift.

/// Compiled lazily in its own library; input/output are linear premultiplied tiles.
/// All filtering and thresholds operate on straight sRGB-encoded components.
/// Global stored-image coordinates keep random samples invariant across tiles/pans.
enum DebandKernels {
    static var librarySource: String {
        """
        #include <metal_stdlib>
        using namespace metal;
        constant uint kTileSize = 512;
        constant uint kApron = 8;
        constant uint kSlotSize = 528;
        \(Shaders.colorTransferSource)
        \(source)
        """
    }

    static let source = #"""
    struct DebandParams {
        uint2 levelSize;
        uint sourceColumns;
        uint sourceSliceOffset;
        uint2 outputTileOrigin;
        uint outputColumns;
        uint firstSlice;
        float strength;
        float threshold;
        float radius;
        float protection;
        uint mode;
        uint iterations;
        uint pad0;
        uint encodedInput;
    };
    static_assert(sizeof(DebandParams) == 64, "DebandParams ABI");

    static int2 dbBound(int2 q, constant DebandParams& p) {
        return clamp(q, int2(0), int2(p.levelSize) - 1);
    }
    // Returns straight encoded RGB plus unchanged source alpha. Missing slices
    // have zero coverage; the alpha gate below prevents transparent color bleed.
    static float4 dbLoad(texture2d_array<float, access::read> src,
                         int2 q, constant DebandParams& p) {
        q = dbBound(q, p);
        uint2 tile = uint2(q) / uint(kTileSize);
        uint absoluteSlice = tile.y * p.sourceColumns + tile.x;
        if (absoluteSlice < p.sourceSliceOffset) return float4(0);
        uint slice = absoluteSlice - p.sourceSliceOffset;
        if (slice >= src.get_array_size()) return float4(0);
        return src.read(uint2(q) % uint(kTileSize) + uint(kApron), slice);
    }
    static float4 dbStraight(float4 v, constant DebandParams& p) {
        if(v.a<=0.f)return float4(0);
        if(p.encodedInput!=0u){
            if(v.a==1.f)return v;
            return float4(linearToSRGB(srgbToLinear(v.rgb)/v.a),v.a);
        }
        return float4(linearToSRGB(v.rgb/v.a),v.a);
    }
    static float4 dbSampleRaw(texture2d_array<float, access::read> src,
                              int2 q, constant DebandParams& p) {
        return dbStraight(dbLoad(src,q,p),p);
    }
    static float3 dbSample(texture2d_array<float, access::read> src, int2 q,
                           float4 center, constant DebandParams& p) {
        float4 v=dbLoad(src,q,p);
        if(abs(v.a-center.a)>1.f/255.f)return center.rgb;
        return dbStraight(v,p).rgb;
    }
    static uint dbHash(uint v) {
        v ^= v >> 16; v *= 0x7feb352du; v ^= v >> 15;
        v *= 0x846ca68bu; return v ^ (v >> 16);
    }
    static float dbRandom(uint v) { return float(dbHash(v) & 0xffffu) / 65535.f; }
    static uint dbSeed(int2 q) { return uint(q.x) + uint(q.y) * 16381u; }
    static float dbDifference(float3 a, float3 b) {
        float3 d = abs(a - b); return max(d.r, max(d.g, d.b));
    }
    static float3 dbSingle(texture2d_array<float, access::read> src, int2 q,
                           float4 center, float radius, float threshold,
                           uint pass, constant DebandParams& p) {
        uint seed = dbSeed(q) + pass * 92821u;
        float angle = dbRandom(seed) * 6.2831853f;
        float distance = 1.f + dbRandom(seed + 71u) * radius;
        int2 a = int2(round(float2(cos(angle), sin(angle)) * distance));
        int2 b = int2(-a.y, a.x);
        float3 x = dbSample(src, q + a, center, p), y = dbSample(src, q - a, center, p);
        float3 z = dbSample(src, q + b, center, p), w = dbSample(src, q - b, center, p);
        float error = max(max(length(x - center.rgb), length(y - center.rgb)),
                          max(length(z - center.rgb), length(w - center.rgb)));
        float blend = (1.f - smoothstep(threshold * .6f, threshold, error)) * p.strength;
        return mix(center.rgb, (x + y + z + w) * .25f, blend);
    }
    static float4 dbFirst(texture2d_array<float, access::read> src, int2 q,
                          constant DebandParams& p) {
        q = dbBound(q, p);
        float4 center = dbSampleRaw(src, q, p);
        return float4(dbSingle(src, q, center, 8.f + 24.f * p.strength,
                               (2.f + 14.f * p.strength) / 255.f, 0u, p), center.a);
    }
    static float3 dbFirstNeighbor(texture2d_array<float, access::read> src, int2 q,
                                  float4 center, constant DebandParams& p) {
        // Apply the same coverage rule at both passes. Recompute from immutable
        // original tiles: a second pass never depends on dispatch order.
        float4 v = dbFirst(src, q, p);
        return abs(v.a - center.a) > 1.f / 255.f ? center.rgb : v.rgb;
    }
    static float3 dbDouble(texture2d_array<float, access::read> src, int2 q,
                           constant DebandParams& p) {
        float4 center = dbFirst(src, q, p);
        uint seed = dbSeed(q) + 92821u;
        float angle = dbRandom(seed) * 6.2831853f;
        float radius = (8.f + 24.f * p.strength) * 1.5f;
        float threshold = (2.f + 14.f * p.strength) / 255.f * .75f;
        float distance = 1.f + dbRandom(seed + 71u) * radius;
        int2 a = int2(round(float2(cos(angle), sin(angle)) * distance));
        int2 b = int2(-a.y, a.x);
        float3 x = dbFirstNeighbor(src, q + a, center, p), y = dbFirstNeighbor(src, q - a, center, p);
        float3 z = dbFirstNeighbor(src, q + b, center, p), w = dbFirstNeighbor(src, q - b, center, p);
        float error = max(max(length(x - center.rgb), length(y - center.rgb)),
                          max(length(z - center.rgb), length(w - center.rgb)));
        float blend = (1.f - smoothstep(threshold * .6f, threshold, error)) * p.strength;
        return mix(center.rgb, (x + y + z + w) * .25f, blend);
    }
    // Opposing gradients cancel on planes/monotone steps but preserve alternating
    // luma and chroma texture. All reads compare coverage to this output pixel.
    static float dbActivity(texture2d_array<float, access::read> src, int2 q,
                            float4 center, constant DebandParams& p) {
        float3 gx = 0, gy = 0, ax = 0, ay = 0;
        for (int j = -1; j <= 1; j++) for (int i = -1; i < 1; i++) {
            float3 dx = dbSample(src, q + int2(i + 1, j), center, p) - dbSample(src, q + int2(i, j), center, p);
            float3 dy = dbSample(src, q + int2(j, i + 1), center, p) - dbSample(src, q + int2(j, i), center, p);
            gx += dx; gy += dy; ax += abs(dx); ay += abs(dy);
        }
        float3 canceled = max(float3(0), (ax + ay - abs(gx) - abs(gy)) / 12.f);
        return max(canceled.r, max(canceled.g, canceled.b));
    }
    static float3 dbAdaptive(texture2d_array<float, access::read> src, int2 q,
                             float4 center, constant DebandParams& p) {
        float confidence = 1.f - p.protection * smoothstep(.15f / 255.f, 1.f / 255.f, dbActivity(src, q, center, p));
        if (confidence < .001f) return center.rgb;
        float3 sum = 0; float maxError = 0;
        int radius = max(1, int(round(p.radius))), inner = max(1, radius / 2 + 1);
        for (int ring = 0; ring < 2; ring++) {
            int r = ring == 0 ? radius : inner;
            int rx = min(r, min(q.x, int(p.levelSize.x) - 1 - q.x));
            int ry = min(r, min(q.y, int(p.levelSize.y) - 1 - q.y));
            float3 a = dbSample(src, q + int2(rx, 0), center, p), b = dbSample(src, q - int2(rx, 0), center, p);
            float3 c = dbSample(src, q + int2(0, ry), center, p), d = dbSample(src, q - int2(0, ry), center, p);
            sum += a + b + c + d;
            maxError = max(maxError, max(max(dbDifference(a, center.rgb), dbDifference(b, center.rgb)),
                                        max(dbDifference(c, center.rgb), dbDifference(d, center.rgb))));
        }
        float gate = 1.f - smoothstep(p.threshold * .6f, p.threshold, maxError);
        return mix(center.rgb, sum * .125f, p.strength * confidence * gate);
    }
    static float3 dbWindow(texture2d_array<float, access::read> src, int2 q,
                           float4 center, constant DebandParams& p) {
        float confidence = 1.f - p.protection * smoothstep(.15f / 255.f, 1.f / 255.f, dbActivity(src, q, center, p));
        if (confidence < .001f) return center.rgb;
        int radius = max(1, int(round(p.radius))), rx = 0, ry = 0; bool accepted = false;
        for (int attempt = 0; attempt < 7; attempt++) {
            rx = min(radius, min(q.x, int(p.levelSize.x) - 1 - q.x));
            ry = min(radius, min(q.y, int(p.levelSize.y) - 1 - q.y));
            float error = 0;
            for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
                if (i == 0 && j == 0) continue;
                error = max(error, dbDifference(dbSample(src, q + int2(i * rx, j * ry), center, p), center.rgb));
            }
            if (error < p.threshold * .9f) { accepted = true; break; }
            if (radius == 1) break;
            radius = max(1, radius / 2);
        }
        if (!accepted) return center.rgb;
        float3 sum = 0; float error = 0;
        for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) {
            int2 delta = int2(round(float2(float(i) * 2.f / 3.f - 1.f, float(j) * 2.f / 3.f - 1.f) * float2(rx, ry)));
            float3 v = dbSample(src, q + delta, center, p);
            sum += v; error = max(error, dbDifference(v, center.rgb));
        }
        float gate = 1.f - smoothstep(p.threshold * .6f, p.threshold, error);
        return mix(center.rgb, sum / 16.f, p.strength * confidence * gate);
    }
    """# + ReferenceDebandKernels.source + #"""
    kernel void debandTiles(texture2d_array<float, access::read> src [[texture(0)]],
                            texture2d_array<float, access::write> out [[texture(1)]],
                            constant DebandParams& p [[buffer(0)]],
                            uint3 gid [[thread_position_in_grid]]) {
        uint slice = gid.z + p.firstSlice;
        if (gid.x >= uint(kSlotSize) || gid.y >= uint(kSlotSize) ||
            gid.x >= out.get_width() || gid.y >= out.get_height() || slice >= out.get_array_size() ||
            p.outputColumns == 0 || p.sourceColumns == 0 || any(p.levelSize == uint2(0))) return;
        int2 tile = int2(p.outputTileOrigin) + int2(slice % p.outputColumns, slice / p.outputColumns);
        int2 q = dbBound(tile * int(kTileSize) + int2(gid.xy) - int(kApron), p);
        float4 center = dbSampleRaw(src, q, p);
        float3 result = center.rgb;
        switch (p.mode) {
            case 1: result = dbFirst(src, q, p).rgb; break;
            case 2: result = dbDouble(src, q, p); break;
            case 3: result = dbAdaptive(src, q, center, p); break;
            case 4: result = dbReference(src, q, center, p); break;
            case 5: result = dbWindow(src, q, center, p); break;
        }
        out.write(float4(srgbToLinear(result) * center.a, center.a), gid.xy, slice);
    }
    """#
}

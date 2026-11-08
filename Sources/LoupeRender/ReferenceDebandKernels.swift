// Reference mode adapted from libplacebo src/shaders/sampling.c, pl_shader_deband.
// Source revision and license: third_party/libplacebo/SOURCE and LICENSE.
// Modified 2026-11-08: tiled Metal reads, straight encoded-color filtering,
// alpha protection, deterministic spatial PRNG and strength blend. The reference
// mode reuses one spatial angle/radius factor across iterations, so it is not
// bit-exact libplacebo output. Grain is a separate renderer stage.
//
// This file contains libplacebo's shader adaptation.
// This code is free software; you can redistribute it and/or modify it under
// the GNU Lesser General Public License, version 2.1 or (at your option) later.
// Distributed WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the license above.

enum ReferenceDebandKernels {
    static let source = #"""
    // libplacebo reference-style component-wise iterative thresholding. All
    // iterations sample the original image, never the previous iteration's field.
    static float3 dbReference(texture2d_array<float, access::read> src, int2 q,
                              float4 center, constant DebandParams& p) {
        float3 result = center.rgb;
        uint seed = dbSeed(q);
        float angle = dbRandom(seed + 71u) * 6.2831853f;
        float2 direction = float2(cos(angle), sin(angle));
        for (uint i = 1; i <= min(p.iterations, 4u); i++) {
            float2 d = direction * (dbRandom(seed) * float(i) * p.radius);
            float3 avg = dbSample(src, q + int2(floor(float2(d.x, d.y) + .5f)), center, p)
                       + dbSample(src, q + int2(floor(float2(-d.x, d.y) + .5f)), center, p)
                       + dbSample(src, q + int2(floor(float2(-d.x, -d.y) + .5f)), center, p)
                       + dbSample(src, q + int2(floor(float2(d.x, -d.y) + .5f)), center, p);
            avg *= .25f;
            result = select(avg, result, abs(result - avg) > p.threshold / float(i));
        }
        return mix(center.rgb, result, p.strength);
    }
    """#
}

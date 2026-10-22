/// All Metal shader code, compiled at runtime by `MetalContext` because Command Line Tools ship
/// no `metal` compiler. The structs are mirrored in ShaderTypes.swift; keep the two in step.
///
/// Texture conventions (TileGrid geometry): a pyramid level is one `bgra8Unorm` `texture2d_array`
/// of 528×528 slots (512 content + 8 apron each side), created with `.pixelFormatView` usage so a
/// `bgra8Unorm_srgb` view of it exists. Slot texel (0, 0) is level pixel `slotOrigin` =
/// (column·512 − 8, row·512 − 8); slice = row·columns + column. Apron texels outside the level are
/// never initialised, so every shader clamps level positions into the level before reading.
///
/// Orientation (M3b spec §2.1): levels are stored as in the file. The view shows the oriented picture, so every path
/// maps view px to oriented level px through its scale and offset, then to stored level px with
/// `ImageOrientation.matrix` (int4 a, b, c, d) and `translation` (`shift`): stored = (a·x + b·y, c·x + d·y) + shift.
/// The matrix is 0 and ±1 only, so for orientation 1 every mapped value is bit-identical to the unmapped one.
///
/// Colour: pixels are in the image's own colour space, and every filter sums its linear light (M3b spec §4). A photo
/// whose transfer curve is sRGB's (`ColorCurve.srgb`: sRGB, Display P3, decoded CMYK and gray) keeps its encoded values;
/// the `_srgb` views linearise them in hardware and the `_srgb` drawable encodes the output. A photo with any other
/// curve (`.table`: Adobe RGB's γ 2.2, ProPhoto's γ 1.8, any ICC curve) is uploaded by `uploadPremultipliedLinear` (see
/// Transparency below; opaque or not): each texel becomes the sRGB encoding of its own curve's linear light,
/// `enc_srgb(lin_curve(s))`, so the very same `_srgb` reads, filters and pyramid kernels sum that light at no cost per
/// frame; its frames, the `CURVE_TABLE` variant, write the result through the curve's inverse table into the drawable's
/// `bgra8Unorm` view (`encodeOutput`), which the layer, tagged with the photo's space, shows as it is. Chosen by
/// measurement over linearising each tap through the forward table (6K Lanczos-3 at 100 %: 8.7 ms, and 3.1 ms with an
/// analytic gamma, against 1.7; docs/bench/2026-10-15-m3b-render.md). Its cost is the 8-bit storage: a code whose light
/// falls between two sRGB bytes moves to the nearer one: at 100 % γ 2.2's codes 1-4 come back 0 (code 1 is 5e-6
/// linear, the first sRGB byte 3e-4) and ~20 of 256 codes one off, in γ 2.2 and γ 1.8 alike
/// (`CurveRendererTests.codesAt100PercentKeepTheMeasuredStorageError`).
///
/// Transparency (M3b spec §3): the decoders' pixels are premultiplied on the encoded values (`e·a`), which the `_srgb`
/// view would linearise as stored, `lin(e·a)` instead of `lin(e)·a`: filtered, a soft edge darkens. So a level with
/// alpha < 1 anywhere (`TiledImage.hasAlpha`) is uploaded by `uploadPremultipliedLinear` instead of the blits: each
/// texel becomes `enc(lin(s / a) · a)`, the premultiplied colour in linear light, sRGB-encoded, alpha unchanged. Then
/// every read through the `_srgb` view returns premultiplied linear light in hardware, so the filters below (bilinear
/// sampling included) and both pyramid kernels sum the right values unchanged: per tap the same as unpremultiply,
/// linearise, premultiply, at no cost per frame, for one 8-bit rounding of each texel at upload. Opaque texels (a = 1)
/// are unchanged (for a `.table` curve, opaque texels become the sRGB byte of their light, as above). Frames of such a
/// photo use the `HAS_ALPHA` variant of their pipeline: the filtered alpha is kept
/// instead of 1, and the output is composited over the backdrop in linear light, `c + (1 − a) · back`
/// (`TransparencyParams`: a checkerboard anchored at the image's top-left on screen, or one colour). Photos without
/// alpha < 1 run the variant without it, which is the code of before.
///
/// Colour cube (M3c spec §4.1, §5): a frame whose photo has a colour correction (`TileRenderer.color`) uses the
/// `COLOR_LUT` variant of its pipelines, in every output path. Where the filtered colour is final (after antiringing),
/// `colorCube` corrects it: the straight colour (with `HAS_ALPHA`, the premultiplied one divided by its alpha where that
/// is > 0; a pixel with alpha 0 stays as it is) clamped to 0...1 and sRGB-encoded is the input of the photo's 33³ cube (`ColorLUT`, an
/// rgba16Float 3D texture sampled trilinearly at the texel centres, `e · 32/33 + 0.5/33`), whose nodes hold the corrected
/// light sRGB-encoded too (the lattice is even in perceived lightness, and encoded values interpolate closer to the
/// correction than linear ones); the sample is decoded with the exact sRGB curve once per pixel. During a transition
/// (`mix` < 1) the `from` cube is sampled and decoded as well and the two are mixed in linear light. Then alpha is
/// multiplied back in (as the change it makes, so the filters' overshoot stays as it was), the pixel composited over the
/// backdrop, which is never corrected, and written by `encodeOutput`.
/// For a `.table` curve the levels already hold `enc_srgb(lin_curve(s))`, so the encode gives the cube exactly its
/// input, and the corrected light leaves through the inverse table as any other. Pixels outside the picture are the
/// background, as before. A frame without a cube, or with the shared identity cube fully shown, uses the variant
/// without it, which is the code of before. MetalFX corrects in the pass that composites (see there).
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant uint kTileSize = 512;
    constant uint kApron = 8;
    constant uint kSlotSize = 528;

    // Oriented level position to stored, and back (the matrix is orthogonal: its inverse is its transpose).
    static float2 orientedToStored(int4 o, float2 shift, float2 u) {
        return float2(float(o.x) * u.x + float(o.y) * u.y, float(o.z) * u.x + float(o.w) * u.y) + shift;
    }

    static float2 storedToOriented(int4 o, float2 shift, float2 s) {
        float2 d = s - shift;
        return float2(float(o.x) * d.x + float(o.z) * d.y, float(o.y) * d.x + float(o.w) * d.y);
    }

    // HAS_ALPHA (index 2): the frame's photo has alpha < 1 somewhere (its levels hold premultiplied linear light, see
    // the header): keep the filtered alpha and composite over the backdrop. Undefined (every pipeline made without
    // constants) means false.
    constant bool HAS_ALPHA [[function_constant(2)]];
    constant bool kAlpha = is_function_constant_defined(HAS_ALPHA) && HAS_ALPHA;

    struct TransparencyParams {
        float4 first;      // linear; the cell at the image's top-left corner and every other one
        float4 second;     // linear; the cells between
        float2 anchor;     // view px of the image's top-left corner, where the cells start
        float invCell;     // 1 / cell side in drawable px
        float pad;
    };

    // CURVE_TABLE (index 3): the frame's photo has a `.table` curve (see the header): the levels hold its linear light,
    // and the output is written through its inverse table (`inverse`, texture 3 of every such function) into the
    // drawable's bgra8Unorm view. The background and the backdrop arrive in the target's terms: the background's
    // sRGB-encoded values (its bytes, as the _srgb drawable would store them), the backdrop in the photo's linear light.
    // Undefined means false.
    constant bool CURVE_TABLE [[function_constant(3)]];
    constant bool kCurveTable = is_function_constant_defined(CURVE_TABLE) && CURVE_TABLE;

    // The resample kernels' output on a GPU that cannot write _srgb textures from a shader (Intel and AMD
    // Macs): they get the drawable's unorm view and encode with the exact sRGB curve themselves. Undefined
    // means false.
    constant bool ENCODE_SRGB [[function_constant(5)]];
    constant bool kEncodeSRGB = is_function_constant_defined(ENCODE_SRGB) && ENCODE_SRGB;

    constexpr sampler kCurveLerp(coord::normalized, filter::linear, address::clamp_to_edge);

    static float3 linearToSRGB(float3 c);

    // An opaque output in linear light, as the target stores it: unchanged for the _srgb drawable (which encodes on
    // store), sRGB-encoded with ENCODE_SRGB; with CURVE_TABLE, the photo's encoded level of each channel from the inverse table, a 4096-entry r16Unorm
    // 1D texture indexed by the square root of the light, sampled at (sqrt(light) · 4095 + 0.5) / 4096. These three
    // samples are the variant's cost (+0.45 ms on a 6K Lanczos-3 frame at 100 %; pow() for a pure gamma would be free).
    static float4 encodeOutput(float4 c, texture1d<float, access::sample> inverse) {
        if (kEncodeSRGB) return float4(linearToSRGB(c.rgb), c.a);
        if (!kCurveTable) return c;
        float3 u = sqrt(saturate(c.rgb)) * (4095.0 / 4096.0) + 0.5 / 4096.0;
        return float4(inverse.sample(kCurveLerp, u.r).x, inverse.sample(kCurveLerp, u.g).x,
                      inverse.sample(kCurveLerp, u.b).x, 1.0);
    }

    // Exact piecewise sRGB encode (IEC 61966-2-1), not a 1/2.2 power; clamps to 0...1.
    static float3 linearToSRGB(float3 c) {
        c = saturate(c);
        float3 lo = c * 12.92;
        float3 hi = 1.055 * pow(c, 1.0 / 2.4) - 0.055;
        return select(hi, lo, c <= 0.0031308);
    }

    // Its inverse, exact too (to an ulp: the divisions are multiplications by the reciprocals, since in safe math a
    // division is a real one; the two in here made colorCube 0.25-0.3 ms dearer on a 6K Lanczos-3 frame).
    static float3 srgbToLinear(float3 e) {
        float3 lo = e * (1.0 / 12.92);
        float3 hi = pow(e * (1.0 / 1.055) + 0.055 / 1.055, 2.4);
        return select(hi, lo, e <= 0.04045);
    }

    // COLOR_LUT (index 4): the frame has a colour cube (see the header): every output path passes its filtered colour
    // through colorCube before the backdrop and encodeOutput. Undefined means false.
    constant bool COLOR_LUT [[function_constant(4)]];
    constant bool kColorLUT = is_function_constant_defined(COLOR_LUT) && COLOR_LUT;

    struct ColorLUTParams {
        float scale;    // (n - 1) / n, n = ColorCube.dimension: encoded light e is the cube's e * scale + offset
        float offset;   // 0.5 / n
        float mix;      // the cube's weight against from's, 0...1; 1: the cube alone
        float pad;
    };

    constexpr sampler kCubeLerp(coord::normalized, filter::linear, address::clamp_to_edge);

    // Filtered linear c (premultiplied with HAS_ALPHA) through the cube, in the same form; unchanged without COLOR_LUT.
    // The straight colour (with HAS_ALPHA divided by its alpha where that is > 0; a pixel with none is left as it is, so
    // nothing divides by 0), clamped to 0...1, is sRGB-encoded and sampled at the texel centres' scale; the sample,
    // sRGB-encoded light (ColorCube), is decoded once. While mix < 1 (a transition, uniform over the frame) `from` is
    // sampled and decoded too and the two are mixed in linear light. Opaque, that is the output (an overshoot past
    // 0...1 is clipped, as the target would clip it). With HAS_ALPHA the correction's change, times alpha, is added to c:
    // the filters' overshoot of the premultiplied colour past 0...a (Lanczos and EWA ringing on a soft edge, up to a
    // third of the light, which the composite turns into dark or bright specks) is kept as it was, so the identity cube
    // is the identity there too, and a correction fading out ends on the frame of the pipeline without the cube
    // (clamping it instead moved such pixels by up to 109 codes, ColorLUTRendererTests.identityCubeMatchesNoCube).
    //   lut [[texture(4)]], from [[texture(5)]]: rgba16Float 3D textures (ColorLUT); from is bound (to lut) even when
    //   unused. cube [[buffer(2)]] in the fragment functions, [[buffer(3)]] in the kernels: ColorLUTParams.
    static float4 colorCube(float4 c, texture3d<float, access::sample> lut, texture3d<float, access::sample> from,
                            constant ColorLUTParams& cube) {
        if (!kColorLUT || (kAlpha && c.a <= 0.0)) return c;
        float3 straight = saturate(kAlpha ? c.rgb * (1.0 / c.a) : c.rgb);   // one division, not three
        float3 u = linearToSRGB(straight) * cube.scale + cube.offset;
        float3 rgb = srgbToLinear(lut.sample(kCubeLerp, u).rgb);
        if (cube.mix < 1.0) rgb = mix(srgbToLinear(from.sample(kCubeLerp, u).rgb), rgb, cube.mix);
        return kAlpha ? float4(c.rgb + (rgb - straight) * c.a, c.a) : float4(rgb, c.a);
    }

    // Whether the drawable pixel centred on v lies on a `second` cell, cells counted from the anchor.
    static bool secondCell(constant TransparencyParams& t, float2 v) {
        float2 cell = floor((v - t.anchor) * t.invCell);
        return (int(cell.x + cell.y) & 1) != 0;
    }

    // The backdrop under the drawable pixel centred on v: the colour of its cell.
    static float3 backdrop(constant TransparencyParams& t, float2 v) {
        return secondCell(t, v) ? t.second.rgb : t.first.rgb;
    }

    // Premultiplied linear c over the backdrop at v, opaque. Alpha is not clamped: a filter's overshoot then cancels
    // between colour and alpha as it would on the composited picture (red over white stays exactly red).
    static float4 composite(float4 c, constant TransparencyParams& t, float2 v) {
        return float4(c.rgb + (1.0 - c.a) * backdrop(t, v), 1.0);
    }

    // ---- uploadPremultipliedLinear --------------------------------------------------------
    //
    // A level with alpha < 1 (see the header), in place of TiledImage's blits: one thread per destination slot texel,
    // dispatchThreads((528, 528, slices)); texels outside the level stay uninitialised, as the blits leave them, so the
    // apron holds the neighbours' pixels as before. Colour byte s with alpha byte a becomes table[a · 256 + s]
    // (MetalContext.premultipliedLinearTable, exact, built in double).
    //   src [[buffer(0)]]: the decoded level, BGRA bytes, rows `bytesPerRow` apart.
    //   p [[buffer(1)]]: AlphaUploadParams. table [[buffer(2)]]: 256 x 256 bytes.
    //   dst [[texture(0)]]: the level's bgra8Unorm texture (not the _srgb view: the bytes are written as they are).

    struct AlphaUploadParams {
        uint2 levelSize;
        uint columns;      // tile columns of the level (slice = row * columns + column)
        uint bytesPerRow;
        uint firstSlice;   // the dispatch's slice gid.z = 0 (an upload goes in pieces of slices)
    };

    kernel void uploadPremultipliedLinear(const device uchar* src [[buffer(0)]],
                                          constant AlphaUploadParams& p [[buffer(1)]],
                                          const device uchar* table [[buffer(2)]],
                                          texture2d_array<float, access::write> dst [[texture(0)]],
                                          uint3 gid [[thread_position_in_grid]])
    {
        uint slice = gid.z + p.firstSlice;
        if (gid.x >= kSlotSize || gid.y >= kSlotSize || slice >= dst.get_array_size() || p.columns == 0) return;
        uint2 tile = uint2(slice % p.columns, slice / p.columns);
        int2 g = int2(tile * kTileSize) - int(kApron) + int2(gid.xy);
        if (any(g < 0) || any(g >= int2(p.levelSize))) return;
        const device uchar* px = src + ulong(g.y) * p.bytesPerRow + ulong(g.x) * 4;   // B, G, R, A
        uint row = uint(px[3]) * 256;
        dst.write(float4(table[row + px[2]], table[row + px[1]], table[row + px[0]], px[3]) / 255.0, gid.xy, slice);
    }

    // ---- downsample2x ---------------------------------------------------------------------

    struct DownsampleParams {
        uint2 srcLevelSize;
        uint2 dstLevelSize;
        uint srcColumns;
        uint dstColumns;
        uint firstSlice;   // the destination slice of gid.z = 0 (a level is built in pieces of slices)
    };

    // Both pyramid kernels read the source level's _srgb view, so for a photo with alpha (levels in premultiplied linear
    // light, see the header) they average premultiplied linear light and write the next level in that same form
    // (linearToSRGB, above).

    // One source-level pixel, read from the tile that owns it (never from a neighbour's apron).
    static float4 readSource(texture2d_array<float, access::read> src, constant DownsampleParams& p, uint2 px) {
        uint2 tile = px / kTileSize;
        uint2 texel = px - tile * kTileSize + kApron;
        return src.read(texel, tile.y * p.srcColumns + tile.x);
    }

    // Dispatches of threadsPerGrid = (528, 528, slices) cover a destination level, a piece of its slices each. gid.xy is
    // the destination slot texel, gid.z + firstSlice the destination slice, so aprons are filled too. Each output is
    // the 2×2 box average of the source in linear light (alpha averaged as-is), sRGB-encoded.
    //   src [[texture(0)]]: SOURCE level, bgra8Unorm_srgb view — read() returns linear values.
    //   dst [[texture(1)]]: DESTINATION level, bgra8Unorm view — written with a manual sRGB encode.
    kernel void downsample2x(texture2d_array<float, access::read> src [[texture(0)]],
                             texture2d_array<float, access::write> dst [[texture(1)]],
                             constant DownsampleParams& p [[buffer(0)]],
                             uint3 gid [[thread_position_in_grid]])
    {
        uint slice = gid.z + p.firstSlice;
        if (gid.x >= kSlotSize || gid.y >= kSlotSize || slice >= dst.get_array_size()) return;
        if (any(p.dstLevelSize == 0) || any(p.srcLevelSize == 0) || p.dstColumns == 0) return;

        uint2 tile = uint2(slice % p.dstColumns, slice / p.dstColumns);
        // Global destination pixel (slotOrigin + gid.xy), clamped into the level so edge aprons
        // replicate the edge pixel instead of reading outside the source.
        int2 g = int2(tile * kTileSize) - int(kApron) + int2(gid.xy);
        uint2 d = uint2(clamp(g, int2(0), int2(p.dstLevelSize) - 1));

        uint2 last = p.srcLevelSize - 1;
        uint2 s0 = min(d * 2, last);
        uint2 s1 = min(d * 2 + 1, last);   // an odd source edge reuses its last pixel
        float4 sum = readSource(src, p, s0)
                   + readSource(src, p, uint2(s1.x, s0.y))
                   + readSource(src, p, uint2(s0.x, s1.y))
                   + readSource(src, p, s1);
        float4 avg = sum * 0.25;
        dst.write(float4(linearToSRGB(avg.rgb), avg.a), gid.xy, slice);
    }

    // ---- downsampleLanczos2x --------------------------------------------------------------
    //
    // pyramid-filter = lanczos3 (M3a spec §4): downsample2x's contract and grid (one thread per destination slot
    // texel, aprons filled, edges clamped, source read through readSource), but each output is a Lanczos-3 2x
    // decimation in linear light: destination px d is centred on source position 2d + 0.5 (texel-index units, as in
    // resample), the kernel is compressed by k = 0.5, so 12 taps per axis, source px 2d - 5 ... 2d + 6, at distances
    // ±0.25 ... ±2.75. The weights are the same for every output (normalised to sum 1); alpha is filtered as colour.
    // Separable through threadgroup memory: a 144-tap 2D loop reads every source texel 36 times, the two passes
    // ~8 times. Dispatch dispatchThreadgroups((33, 33, slices), (16, 16, 1)): 528 = 33 · 16, so every thread is a
    // slot texel and all reach the barrier.

    constant int kDecimateGroup = 16;
    constant int kDecimateTaps = 12;
    constant int kDecimateRows = 2 * (kDecimateGroup - 1) + kDecimateTaps;   // 42 source rows per group

    kernel void downsampleLanczos2x(texture2d_array<float, access::read> src [[texture(0)]],
                                    texture2d_array<float, access::write> dst [[texture(1)]],
                                    constant DownsampleParams& p [[buffer(0)]],
                                    uint3 gid [[thread_position_in_grid]],
                                    uint3 tid [[thread_position_in_threadgroup]],
                                    uint3 tg [[threadgroup_position_in_grid]])
    {
        threadgroup float4 rows[kDecimateRows][kDecimateGroup];
        // Uniform per group (tg.z + firstSlice is the group's slice), so the early return skips the barrier for all or none.
        uint slice = tg.z + p.firstSlice;
        if (slice >= dst.get_array_size()) return;
        if (any(p.dstLevelSize == 0) || any(p.srcLevelSize == 0) || p.dstColumns == 0) return;

        // Weights: Lanczos-3 at distance |t - 5.5| · 0.5 (never 0, so no special case at the centre), normalised.
        float w[kDecimateTaps];
        float sum = 0.0;
        for (int t = 0; t < kDecimateTaps; t++) {
            float x = abs(float(t) - 5.5) * 0.5;
            w[t] = 3.0 * sinpi(x) * sinpi(x / 3.0) / (M_PI_F * M_PI_F * x * x);
            sum += w[t];
        }
        for (int t = 0; t < kDecimateTaps; t++) w[t] /= sum;

        // Destination pixels as downsample2x: slotOrigin + slot texel, clamped into the level (edge aprons replicate
        // the edge pixel). d is monotone in the slot texel, so the group's rows span d0.y ... d0.y + 15 at most.
        uint2 tile = uint2(slice % p.dstColumns, slice / p.dstColumns);
        int2 levelMax = int2(p.dstLevelSize) - 1;
        int2 slot0 = int2(tile * kTileSize) - int(kApron);
        int2 d = clamp(slot0 + int2(gid.xy), int2(0), levelMax);
        int2 d0 = clamp(slot0 + int2(tg.xy) * kDecimateGroup, int2(0), levelMax);   // the group's first (smallest)
        int2 last = int2(p.srcLevelSize) - 1;

        // Horizontal pass: source rows 2·d0.y - 5 + r (clamped) at this thread's column's 12 taps.
        int rowBase = 2 * d0.y - kDecimateTaps / 2 + 1;
        int x0 = 2 * d.x - kDecimateTaps / 2 + 1;
        for (int r = int(tid.y); r < kDecimateRows; r += kDecimateGroup) {
            int sy = clamp(rowBase + r, 0, last.y);
            float4 acc = 0.0;
            for (int t = 0; t < kDecimateTaps; t++) {
                acc += w[t] * readSource(src, p, uint2(clamp(x0 + t, 0, last.x), sy));
            }
            rows[r][tid.x] = acc;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // Vertical pass: this thread's rows start 2·(d.y - d0.y) into the group's.
        int r0 = 2 * (d.y - d0.y);
        float4 acc = 0.0;
        for (int t = 0; t < kDecimateTaps; t++) acc += w[t] * rows[r0 + t][tid.x];
        dst.write(float4(linearToSRGB(acc.rgb), saturate(acc.a)), gid.xy, slice);
    }

    // ---- tileVertex / tileFragment --------------------------------------------------------

    struct TileInstance {
        float2 contentOrigin;   // level px
        float2 contentSize;     // level px
        float2 slotOrigin;      // level position of slot texel (0, 0)
        uint slice;
    };

    struct TileUniforms {
        float2 levelToViewScale;
        float2 levelToViewOffset;   // view px of oriented level px 0; view origin top-left, y down
        float2 viewSize;
        float2 levelSize;
        int4 orient;                // ImageOrientation.matrix
        float2 shift;               // stored level px
        float2 viewToLevelScale;    // 1 / levelToViewScale
        float2 extent;              // the image's stored extent in level px
        float bleed;                // > 0: corners on the image's edge move this many level px outwards (a viewport cut)
        float pad;
    };

    struct TileVarying {
        float4 position [[position]];
        float2 levelPos;
        float2 slotOrigin [[flat]];
        float2 levelSize [[flat]];
        uint slice [[flat]];
    };

    // Draw with a 4-vertex triangle strip per instance:
    //   drawPrimitives(.triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: tiles)
    //   instances [[buffer(0)]]: TileInstance array, uniforms [[buffer(1)]]: TileUniforms.
    // Instances are stored tiles; the corners go to the view through the orientation, so a turned or mirrored tile is
    // a turned or mirrored quad, and levelPos (stored) interpolates across it exactly (the map is affine). With a bleed
    // (a page cut by its viewport's scissor, TileRenderer.encode) the corners on the image's edge move outwards, the
    // quad and its levelPos together, so the picture covers every px of the viewport (the fragment clamps the samples
    // into the level: the edge texels repeat) and the scissor alone decides where it ends.
    vertex TileVarying tileVertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  const device TileInstance* instances [[buffer(0)]],
                                  constant TileUniforms& u [[buffer(1)]])
    {
        TileInstance t = instances[iid];
        float2 corner = float2(vid & 1, vid >> 1);
        float2 levelPos = t.contentOrigin + corner * t.contentSize;
        if (u.bleed > 0.0) {
            levelPos = select(levelPos, levelPos - u.bleed, levelPos <= 0.0);
            levelPos = select(levelPos, levelPos + u.bleed, levelPos >= u.extent - 1e-3);
        }
        float2 view = storedToOriented(u.orient, u.shift, levelPos) * u.levelToViewScale + u.levelToViewOffset;
        float2 ndc = view / u.viewSize * 2.0 - 1.0;

        TileVarying out;
        out.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
        out.levelPos = levelPos;
        out.slotOrigin = t.slotOrigin;
        out.levelSize = u.levelSize;
        out.slice = t.slice;
        return out;
    }

    // slots [[texture(0)]]: the level's bgra8Unorm_srgb view, so filtering happens in linear light
    // and an _srgb drawable re-encodes on store. The pipeline does not blend (opaque draw over the cleared
    // background): without HAS_ALPHA the output is the texel as stored (opaque), with it the premultiplied linear
    // sample composited over the backdrop (t [[buffer(1)]]). With CURVE_TABLE, written through inverse [[texture(3)]].
    // With COLOR_LUT, through the cube first (lut [[texture(4)]], from [[texture(5)]], cube [[buffer(2)]]).
    fragment float4 tileFragment(TileVarying in [[stage_in]],
                                 texture2d_array<float, access::sample> slots [[texture(0)]],
                                 constant TransparencyParams& t [[buffer(1), function_constant(kAlpha)]],
                                 texture1d<float, access::sample> inverse [[texture(3), function_constant(kCurveTable)]],
                                 texture3d<float, access::sample> lut [[texture(4), function_constant(kColorLUT)]],
                                 texture3d<float, access::sample> from [[texture(5), function_constant(kColorLUT)]],
                                 constant ColorLUTParams& cube [[buffer(2), function_constant(kColorLUT)]])
    {
        constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
        // Keep the bilinear footprint inside the level: beyond the edge the apron is uninitialised.
        float2 p = clamp(in.levelPos, float2(0.5), in.levelSize - 0.5);
        float4 c = colorCube(slots.sample(s, p - in.slotOrigin, in.slice), lut, from, cube);
        if (kAlpha) return encodeOutput(composite(c, t, in.position.xy), inverse);
        return encodeOutput(c, inverse);
    }

    // The pixel-art path (M3a spec §3.4): each level px is one hard block of view px. The level px is chosen in
    // oriented space, from the pixel centre itself: floor of the centre's oriented level position, on the oriented px
    // grid (which an odd-size level mirrored about the image's extent offsets by half a px, the fraction of `shift`),
    // mapped to stored as that px's centre. So a centre exactly on a block edge (a tie) goes to the block after it in
    // the view whatever the orientation, and every orientation draws the blocks `.up` draws of the shown picture.
    // Flooring the interpolated stored position instead would break ties the other way on a mirrored axis, and
    // interpolation rounding would break some at random. The clamp keeps the lookup out of the uninitialised apron.
    //   u [[buffer(0)]]: the draw's TileUniforms. t [[buffer(1)]]: with HAS_ALPHA, inverse [[texture(3)]]: with
    //   CURVE_TABLE, lut [[texture(4)]], from [[texture(5)]] and cube [[buffer(2)]]: with COLOR_LUT, as tileFragment.
    fragment float4 tileFragmentNearest(TileVarying in [[stage_in]],
                                        texture2d_array<float, access::sample> slots [[texture(0)]],
                                        constant TileUniforms& u [[buffer(0)]],
                                        constant TransparencyParams& t [[buffer(1), function_constant(kAlpha)]],
                                        texture1d<float, access::sample> inverse [[texture(3),
                                                                                   function_constant(kCurveTable)]],
                                        texture3d<float, access::sample> lut [[texture(4), function_constant(kColorLUT)]],
                                        texture3d<float, access::sample> from [[texture(5), function_constant(kColorLUT)]],
                                        constant ColorLUTParams& cube [[buffer(2), function_constant(kColorLUT)]])
    {
        constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::nearest);
        float2 f = fract(u.shift);
        float2 grid = abs(float2(float(u.orient.x) * f.x + float(u.orient.z) * f.y,
                                 float(u.orient.y) * f.x + float(u.orient.w) * f.y));
        // k = floor(x / m), x the centre's view distance from the oriented px grid's start: through the reciprocal
        // (a divide in safe math costs about 0.02 ms per 6K frame on M4 Max, 0.29 vs 0.27-0.28 ms), then the
        // remainder x - k·m (exact sign, one rounding in the fma) moves k by one where the reciprocal rounded across
        // a block edge (at 1025 %, k·m / m comes out below k for k = 4, 8, ...).
        float2 m = u.levelToViewScale;
        float2 x = in.position.xy - u.levelToViewOffset - grid * m;
        float2 k = floor(x * u.viewToLevelScale);
        float2 r = fma(-k, m, x);
        k += select(float2(0.0), float2(1.0), r >= m) - select(float2(0.0), float2(1.0), r < 0.0);
        float2 p = orientedToStored(u.orient, u.shift, k + grid + 0.5);
        p = clamp(p, float2(0.5), in.levelSize - 0.5);
        float4 c = colorCube(slots.sample(s, p - in.slotOrigin, in.slice), lut, from, cube);
        if (kAlpha) return encodeOutput(composite(c, t, in.position.xy), inverse);
        return encodeOutput(c, inverse);
    }

    // ---- resample -------------------------------------------------------------------------
    //
    // M3a spec §3.2: a separable filter in linear light over the drawable, 16×16 threads per group, dispatched with
    // dispatchThreadgroups(ceil(view / 16), 16×16). Per group: the 16 column and 16 row weights go to threadgroup
    // memory once (not per pixel), then a horizontal pass over the level rows the group needs into threadgroup
    // memory, then the vertical pass and the write. Positions follow tileFragment: level px i has its centre at
    // i + 0.5, so view px v samples the oriented level at (v + 0.5 - offset) / m; c is that point's stored position
    // less 0.5 (texel-index units). The matrix only swaps and mirrors axes, so the filter stays separable: each view
    // axis runs along one stored axis, forwards or backwards, and the weights are kept per stored axis (H: stored x,
    // V: stored y). The first pass always runs along stored x, as texture memory favours: for orientations 5...8,
    // whose view x runs along stored y, the group's threads are transposed instead (thread (i, j) draws view px
    // (j, i)), so those frames run the very loops of orientation 1 and cost the same (6K kernel frames of orientation 6
    // within 3 % of orientation 1 on M4 Max; the transposed writes cost nothing measurable).

    // The kernel, in ResampleKernel case order (0 Lanczos-3, 1 Lanczos-2, 2 Mitchell, 3 Catmull-Rom), and the taps
    // per axis: 2·support magnifying, 4·support reducing, which covers the kernel stretched by 1/m for m in (0.5, 1].
    constant int RESAMPLE_KERNEL [[function_constant(0)]];
    constant int RESAMPLE_TAPS [[function_constant(1)]];

    constant int kGroup = 16;          // threadgroup side in view px
    constant int kMaxTaps = 12;        // Lanczos-3 reducing
    constant int kGroupRows = 48;      // level rows a group needs, bV[15] - bV[0] + taps: <= 30 + 12 for m > 0.5

    // Slot texels are fetched with sample() through this sampler at texel centres, which returns the texel itself (no
    // filtering, the same bytes as read()) and on M4 Max is about 0.06–0.08 ms cheaper per 6K Lanczos-3 reducing frame
    // than read() with a computed slice (docs/bench/2026-10-15-m3a-render.md, «Оптимизация пути уменьшения»).
    // clamp_to_edge keeps a fetch inside its slot whatever happens.
    constexpr sampler kTexel(coord::pixel, address::clamp_to_edge, filter::nearest);

    // VIEWPORT_CUT (index 6): a page of a spread (TileRenderer.encode): the picture ends at ResampleParams.cut, the
    // page's viewport, not at its own view rect. Undefined means false: a single page's kernels are those of before.
    constant bool VIEWPORT_CUT [[function_constant(6)]];
    constant bool kViewportCut = is_function_constant_defined(VIEWPORT_CUT) && VIEWPORT_CUT;

    struct ResampleParams {
        float levelToViewScale;        // m: view px per level px
        float pad0;
        float2 levelToViewOffset;      // view px of oriented level px 0
        uint2 levelSize;               // stored
        float2 extent;                 // the image's oriented extent in level px (its view rect: offset + extent·m)
        uint2 viewSize;                // the dispatch's size: the drawable's, or a viewport's
        uint columns;                  // tile columns of the level (slice = row * columns + column)
        uint antiringing;
        float4 background;             // linear, alpha 1 (CURVE_TABLE: sRGB-encoded)
        int4 orient;                   // ImageOrientation.matrix
        float2 shift;                  // stored level px
        uint2 origin;                  // where the dispatch's px (0, 0) is written: (0, 0), or a viewport's corner
        float4 cut;                    // with VIEWPORT_CUT: the viewport, dispatch px (min x, min y, max x, max y)
    };
    // The kernels work in the dispatch's own px: a dispatch over a viewport (TileRenderer.encode, a page after the
    // first) gets levelToViewOffset and the backdrop's anchor less `origin`, and only its writes add `origin` back.

    // The kernel's weight at distance x (already compressed by k = min(1, m)).
    static float resampleWeight(float x) {
        x = abs(x);
        if (RESAMPLE_KERNEL <= 1) {
            float a = RESAMPLE_KERNEL == 0 ? 3.0 : 2.0;
            if (x < 1e-4) return 1.0;
            if (x >= a) return 0.0;
            // sinpi is exact at integers, so at m = 1 with integer alignment every tap but the centre weighs exactly
            // 0 and 100 % reproduces the source bytes.
            return a * sinpi(x) * sinpi(x / a) / (M_PI_F * M_PI_F * x * x);
        }
        // Mitchell-Netravali cubic: B = C = 1/3 (Mitchell), B = 0, C = 1/2 (Catmull-Rom).
        float B = RESAMPLE_KERNEL == 2 ? 1.0 / 3.0 : 0.0, C = RESAMPLE_KERNEL == 2 ? 1.0 / 3.0 : 0.5;
        if (x < 1.0) return ((12 - 9 * B - 6 * C) * x * x * x + (-18 + 12 * B + 6 * C) * x * x + (6 - 2 * B)) / 6;
        if (x < 2.0) return ((-B - 6 * C) * x * x * x + (6 * B + 30 * C) * x * x + (-12 * B - 48 * C) * x + (8 * B + 24 * C)) / 6;
        return 0.0;
    }

    // Level texel (x, y) as output column `col` reads it: clamped into the level (apron texels past the level edge
    // are never initialised), from the slot of tile column `col` and of the tile row that owns y. Callers stay within
    // 6 px of column col's centre, inside the 8 px apron; the slot clamp only keeps a read in bounds whatever happens.
    static float4 resampleTexel(texture2d_array<float, access::sample> slots, constant ResampleParams& p,
                                int col, int x, int y) {
        int2 q = clamp(int2(x, y), int2(0), int2(p.levelSize) - 1);
        int row = q.y / int(kTileSize);
        int2 texel = clamp(q - int2(col, row) * int(kTileSize) + int(kApron), int2(0), int2(kSlotSize - 1));
        return slots.sample(kTexel, float2(texel) + 0.5, uint(row) * p.columns + uint(col));
    }

    //   slots [[texture(0)]]: the level's bgra8Unorm_srgb view (fetches return linear light).
    //   out [[texture(1)]]: the bgra8Unorm_srgb drawable (encodes on store), access::write; with CURVE_TABLE its
    //   bgra8Unorm view, written through inverse [[texture(3)]].
    //   p [[buffer(0)]]: ResampleParams. t [[buffer(2)]]: with HAS_ALPHA, the backdrop (the filtered alpha is kept and
    //   the pixel composited over it; without, the output is opaque). With COLOR_LUT the filtered (and antiringing-
    //   clamped) colour goes through the cube: lut [[texture(4)]], from [[texture(5)]], cube [[buffer(3)]].
    kernel void resample(texture2d_array<float, access::sample> slots [[texture(0)]],
                         texture2d<float, access::write> out [[texture(1)]],
                         constant ResampleParams& p [[buffer(0)]],
                         constant TransparencyParams& t [[buffer(2), function_constant(kAlpha)]],
                         texture1d<float, access::sample> inverse [[texture(3), function_constant(kCurveTable)]],
                         texture3d<float, access::sample> lut [[texture(4), function_constant(kColorLUT)]],
                         texture3d<float, access::sample> from [[texture(5), function_constant(kColorLUT)]],
                         constant ColorLUTParams& cube [[buffer(3), function_constant(kColorLUT)]],
                         uint2 tid [[thread_position_in_threadgroup]],
                         uint2 tg [[threadgroup_position_in_grid]])
    {
        threadgroup float wH[kGroup][kMaxTaps], wV[kGroup][kMaxTaps];
        threadgroup int bH[kGroup], bV[kGroup];
        threadgroup half4 hbuf[kGroupRows][kGroup];

        // The view px this thread draws: transposed in the group when the orientation swaps the axes (see above).
        bool swap = p.orient.x == 0;
        uint2 gid = tg * kGroup + (swap ? tid.yx : tid);
        bool drawn = all(gid < p.viewSize);   // threads past the drawable's edge still reach every barrier
        float m = p.levelToViewScale;
        float2 imageMin = p.levelToViewOffset, imageMax = imageMin + p.extent * m;
        if (kViewportCut) {   // a viewport: px inside it are the picture (its edge repeated), the rest background
            imageMin = p.cut.xy;
            imageMax = p.cut.zw;
        }

        // 1. A group wholly outside the image's view rect writes background without a sample. The test is the same
        //    for every thread of the group and no barrier has been reached yet, so the early return is uniform.
        float2 groupMin = float2(tg * kGroup), groupMax = groupMin + float(kGroup);
        if (any(groupMax <= imageMin) || any(groupMin >= imageMax)) {
            if (drawn) out.write(p.background, gid + p.origin);
            return;
        }

        // 2. Weights: thread row 0 computes its view column's, row 1 its view row's (first tap b and TAPS weights
        //    summing to 1). View axis `axis` runs along stored axis `stored` (the other one when the orientation swaps
        //    them), with the matrix entry's sign, so c and b are stored texel-index positions on that axis, and the
        //    weights go to that axis's table: H for stored x, V for stored y.
        float k = min(1.0, m);
        if (tid.y < 2) {
            uint axis = tid.y, stored = swap ? 1 - axis : axis;
            float sign = float(p.orient[stored * 2 + axis]);
            float c = sign * ((float(tg[axis] * kGroup + tid.x) + 0.5 - p.levelToViewOffset[axis]) / m)
                    + p.shift[stored] - 0.5;
            int b = int(floor(c)) - RESAMPLE_TAPS / 2 + 1;
            float w[kMaxTaps];
            float sum = 0.0;
            for (int t = 0; t < RESAMPLE_TAPS; t++) {
                w[t] = resampleWeight((float(b + t) - c) * k);
                sum += w[t];
            }
            float inv = 1.0 / sum;
            if (stored == 0) {
                for (int t = 0; t < RESAMPLE_TAPS; t++) wH[tid.x][t] = w[t] * inv;
                bH[tid.x] = b;
            } else {
                for (int t = 0; t < RESAMPLE_TAPS; t++) wV[tid.x][t] = w[t] * inv;
                bV[tid.x] = b;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // 3. Horizontal pass over level rows bV[0] ... bV[15] + TAPS - 1 (from the smaller end: a mirrored axis runs
        //    backwards): thread column tid.x, rows tid.y, +16, ... All of a column's taps come from the slot of the tile
        //    column under its centre floor(c) = b + TAPS/2 - 1: they reach at most TAPS/2 <= 6 px from it, inside that
        //    slot's 8 px apron. The row's own tile is used.
        int row0 = min(bV[0], bV[kGroup - 1]);
        int rows = min(abs(bV[kGroup - 1] - bV[0]) + RESAMPLE_TAPS, kGroupRows);
        int bx = bH[tid.x];
        int2 last = int2(p.levelSize) - 1;
        int col = clamp((bx + RESAMPLE_TAPS / 2 - 1) / int(kTileSize), 0, int(p.columns) - 1);
        int slotX = int(kApron) - col * int(kTileSize);   // slot x of level x is x + slotX
        // The column's weights in registers, read from threadgroup memory once rather than at every tap of every row:
        // with them in threadgroup memory the 6K Lanczos-3 reducing frame cost 0.3–0.5 ms more through sample() and
        // 0.8–1.2 ms more through read() (same document).
        float w[kMaxTaps];
        for (int t = 0; t < RESAMPLE_TAPS; t++) w[t] = wH[tid.x][t];
        for (int r = int(tid.y); r < rows; r += kGroup) {
            int y = clamp(row0 + r, 0, last.y);
            int row = y / int(kTileSize);
            uint slice = uint(row) * p.columns + uint(col);
            float sy = float(y - row * int(kTileSize) + int(kApron)) + 0.5;
            float4 acc = 0.0;
            for (int t = 0; t < RESAMPLE_TAPS; t++) {
                float sx = float(clamp(bx + t, 0, last.x) + slotX) + 0.5;
                acc += w[t] * slots.sample(kTexel, float2(sx, sy), slice);
            }
            hbuf[r][tid.x] = half4(acc);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // 4. Vertical pass and write.
        if (!drawn) return;
        float2 centre = float2(gid) + 0.5;
        if (any(centre < imageMin) || any(centre >= imageMax)) {
            out.write(p.background, gid + p.origin);
            return;
        }
        int by = bV[tid.y] - row0;
        float4 acc = 0.0;
        for (int t = 0; t < RESAMPLE_TAPS; t++) acc += wV[tid.y][t] * float4(hbuf[min(by + t, kGroupRows - 1)][tid.x]);
        if (p.antiringing != 0 && m > 1.0) {
            // Clamp to the range of the 2×2 texels around the sample point, floor(c) and floor(c) + 1 per axis.
            // With HAS_ALPHA each channel is clamped on its own, alpha included, so the premultiplied colour may end a
            // little above its alpha; the composite adds (1 - a) · back to it, and the unorm write saturates.
            int2 f = int2(bx, bV[tid.y]) + RESAMPLE_TAPS / 2 - 1;
            float4 a0 = resampleTexel(slots, p, col, f.x, f.y), a1 = resampleTexel(slots, p, col, f.x + 1, f.y);
            float4 a2 = resampleTexel(slots, p, col, f.x, f.y + 1), a3 = resampleTexel(slots, p, col, f.x + 1, f.y + 1);
            acc = clamp(acc, min(min(a0, a1), min(a2, a3)), max(max(a0, a1), max(a2, a3)));
        }
        acc = colorCube(acc, lut, from, cube);
        if (kAlpha) {
            out.write(encodeOutput(composite(acc, t, centre), inverse), gid + p.origin);
            return;
        }
        out.write(encodeOutput(float4(acc.rgb, 1.0), inverse), gid + p.origin);   // opaque
    }

    // ---- resampleEWA / ewaWeightProbe -----------------------------------------------------
    //
    // upscale = ewa-lanczos (M3a spec §3.7): mpv's ewa_lanczossharp, a radial jinc-windowed jinc in linear light.
    // resample's dispatch, ResampleParams, sample positions (view px v samples the level at c: the stored position
    // of oriented (v + 0.5 - offset) / m, less 0.5), background and odd-size behaviour, but one 2D pass: all of it in
    // stored texel-index units, whose distances the orientation's turns and mirrors keep. Texel t weighs w(|t - c|),
    // the taps are every texel whose centre lies within the blurred radius R·b = 3.1776 level px of c, and the weights
    // are normalised to sum 1.
    // Magnifying only (m > 1). Every such texel lies in the 7 x 7 square around the nearest texel n = floor(c + 0.5)
    // (|t - c| >= 3.5 outside it), and the square's four corners never do (>= sqrt(2 · 2.5²) = 3.54), so 45 candidates.
    // Per group: the level texels its 16 x 16 outputs need, n of its first pixel - 3 to n of its last + 3 per axis (at
    // m > 1 at most 15 + 1 + 6 = 22), go to threadgroup memory once, clamped into the level and each read from the slot
    // of the tile that owns it (so no apron limit applies); after the barrier each thread sums its taps from there.
    //
    // w comes from a 1024-entry table over r^2 in [0, (R·b)^2] (MetalContext.ewaWeightTable), an r32Float 1D texture
    // sampled with linear filtering, so no sqrt, no Bessel function and no interpolation arithmetic per tap: on M4 Max
    // the texture sampler's lerp made the 6K frame ~25 % cheaper than the same table read from a constant buffer and
    // interpolated by hand (docs/bench/2026-10-15-m3a-render.md, «EWA Lanczos»). Taps beyond R·b are skipped by a
    // compare on the table coordinate; the table's last entry is exactly 0, so the clamp at its end is harmless.

    constant int kEWASpan = kGroup + 6;           // texels per axis a group can need at m > 1
    constant int kEWATable = 1024;                // entries of the weight table

    // The table coordinate of r^2 = dx^2 + dy^2 is u = r^2 · kEWAScale + kEWABias, normalised so that entry i is at its
    // texel centre (i + 0.5) / kEWATable when r^2 = i / (kEWATable - 1) · cutoff2.
    static float ewaScale(float cutoff2) { return float(kEWATable - 1) / (cutoff2 * float(kEWATable)); }
    constant float kEWABias = 0.5 / float(kEWATable);
    constexpr sampler kEWALerp(coord::normalized, filter::linear, address::clamp_to_edge);

    //   slots [[texture(0)]], out [[texture(1)]], p [[buffer(0)]]: as resample.
    //   weights [[texture(2)]]: the weight table, r32Float, kEWATable texels.
    //   cutoff2 [[buffer(1)]]: (R·b)^2 in level px^2. t [[buffer(2)]]: with HAS_ALPHA, inverse [[texture(3)]]: with
    //   CURVE_TABLE, lut [[texture(4)]], from [[texture(5)]] and cube [[buffer(3)]]: with COLOR_LUT, as resample.
    kernel void resampleEWA(texture2d_array<float, access::sample> slots [[texture(0)]],
                            texture2d<float, access::write> out [[texture(1)]],
                            texture1d<float, access::sample> weights [[texture(2)]],
                            constant ResampleParams& p [[buffer(0)]],
                            constant float& cutoff2 [[buffer(1)]],
                            constant TransparencyParams& t [[buffer(2), function_constant(kAlpha)]],
                            texture1d<float, access::sample> inverse [[texture(3), function_constant(kCurveTable)]],
                            texture3d<float, access::sample> lut [[texture(4), function_constant(kColorLUT)]],
                            texture3d<float, access::sample> from [[texture(5), function_constant(kColorLUT)]],
                            constant ColorLUTParams& cube [[buffer(3), function_constant(kColorLUT)]],
                            uint2 tid [[thread_position_in_threadgroup]],
                            uint2 tg [[threadgroup_position_in_grid]])
    {
        threadgroup half4 texels[kEWASpan][kEWASpan];

        uint2 gid = tg * kGroup + tid;
        bool drawn = all(gid < p.viewSize);   // threads past the drawable's edge still reach the barrier
        float m = p.levelToViewScale;
        float2 imageMin = p.levelToViewOffset, imageMax = imageMin + p.extent * m;
        if (kViewportCut) {   // a viewport: px inside it are the picture (its edge repeated), the rest background
            imageMin = p.cut.xy;
            imageMax = p.cut.zw;
        }

        // 1. A group wholly outside the image's view rect writes background without a sample (uniform, before the
        //    barrier, as in resample).
        float2 groupMin = float2(tg * kGroup), groupMax = groupMin + float(kGroup);
        if (any(groupMax <= imageMin) || any(groupMin >= imageMax)) {
            if (drawn) out.write(p.background, gid + p.origin);
            return;
        }

        // 2. The group's texel block: the nearest texels of its first and last pixel per axis, ±3. Positions are
        //    monotone in v, so every thread's n lies between; the span is clamped to the buffer whatever m is. Alpha is
        //    stored as 1 (the output is opaque), so the weighted sum's alpha is the sum of the weights; with HAS_ALPHA
        //    the texel's own alpha is kept and the weights are summed apart.
        //    Turned or mirrored, the first and last pixel are opposite corners of the block in stored px, either way
        //    round, so the block runs from their smaller to their larger position per axis.
        float2 c0 = orientedToStored(p.orient, p.shift, (groupMin + 0.5 - p.levelToViewOffset) / m) - 0.5;
        float2 c1 = orientedToStored(p.orient, p.shift, (groupMax - 0.5 - p.levelToViewOffset) / m) - 0.5;
        float2 cFirst = min(c0, c1), cLast = max(c0, c1);
        int2 base = int2(floor(cFirst + 0.5)) - 3;
        int2 span = min(int2(floor(cLast + 0.5)) + 4 - base, int2(kEWASpan));
        int2 last = int2(p.levelSize) - 1;
        for (int k = int(tid.y * kGroup + tid.x); k < span.x * span.y; k += kGroup * kGroup) {
            int2 local = int2(k % span.x, k / span.x);
            // Clamped into the level (apron texels past its edge are never initialised), read from the owning tile.
            int2 q = clamp(base + local, int2(0), last);
            int2 tile = q / int(kTileSize);
            float2 texel = float2(q - tile * int(kTileSize) + int(kApron)) + 0.5;
            float4 c = slots.sample(kTexel, texel, uint(tile.y) * p.columns + uint(tile.x));
            texels[local.y][local.x] = kAlpha ? half4(c) : half4(half3(c.rgb), 1.0h);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // 3. This pixel's taps and the write.
        if (!drawn) return;
        float2 centre = float2(gid) + 0.5;
        if (any(centre < imageMin) || any(centre >= imageMax)) {
            out.write(p.background, gid + p.origin);
            return;
        }
        float2 c = orientedToStored(p.orient, p.shift, (centre - p.levelToViewOffset) / m) - 0.5;
        int2 n = int2(floor(c + 0.5));
        int2 i0 = clamp(n - 3 - base, int2(0), int2(kEWASpan - 7));   // the 7 x 7 square, inside the buffer
        float2 d0 = float2(base + i0) - c;                             // its first texel's offset from c
        // The table coordinate split per axis, so a tap costs one add: u = ux[i] + uy[j].
        float scale = ewaScale(cutoff2), uEnd = cutoff2 * scale + kEWABias;
        float ux[7], uy[7];
        for (int i = 0; i < 7; i++) {
            float dx = d0.x + float(i), dy = d0.y + float(i);
            ux[i] = dx * dx * scale + kEWABias;
            uy[i] = dy * dy * scale;
        }
        float4 acc = 0.0;
        float sum = 0.0;   // HAS_ALPHA only: the weights' sum (without, acc.a is that, and this is dead code)
        // Rows 0 and 6 without their corners; constant loop bounds keep the loops unrolled.
        for (int i = 1; i < 6; i++) {
            float u = ux[i] + uy[0];
            if (u < uEnd) {
                float w = weights.sample(kEWALerp, u).x;
                acc += w * float4(texels[i0.y][i0.x + i]);
                sum += w;
            }
        }
        for (int j = 1; j < 6; j++) {
            for (int i = 0; i < 7; i++) {
                float u = ux[i] + uy[j];
                if (u < uEnd) {
                    float w = weights.sample(kEWALerp, u).x;
                    acc += w * float4(texels[i0.y + j][i0.x + i]);
                    sum += w;
                }
            }
        }
        for (int i = 1; i < 6; i++) {
            float u = ux[i] + uy[6];
            if (u < uEnd) {
                float w = weights.sample(kEWALerp, u).x;
                acc += w * float4(texels[i0.y + 6][i0.x + i]);
                sum += w;
            }
        }
        if (kAlpha) acc /= sum; else acc /= acc.a;
        if (p.antiringing != 0) {
            // Clamp to the range of the 2 x 2 texels around the sample point, floor(c) and floor(c) + 1 per axis
            // (n - 1 or n, so inside the square), as resample does, each channel on its own (alpha too, see there).
            int2 f = clamp(int2(floor(c)) - base, int2(0), int2(kEWASpan - 2));
            float4 a0 = float4(texels[f.y][f.x]), a1 = float4(texels[f.y][f.x + 1]);
            float4 a2 = float4(texels[f.y + 1][f.x]), a3 = float4(texels[f.y + 1][f.x + 1]);
            acc = clamp(acc, min(min(a0, a1), min(a2, a3)), max(max(a0, a1), max(a2, a3)));
        }
        acc = colorCube(acc, lut, from, cube);
        if (kAlpha) {
            out.write(encodeOutput(composite(acc, t, centre), inverse), gid + p.origin);
            return;
        }
        out.write(encodeOutput(float4(acc.rgb, 1.0), inverse), gid + p.origin);   // opaque
    }

    // Tests: the weight resampleEWA uses at r2[i] (level px^2, below cutoff2), as it looks it up.
    kernel void ewaWeightProbe(texture1d<float, access::sample> weights [[texture(0)]],
                               const device float* r2 [[buffer(0)]],
                               device float* w [[buffer(1)]],
                               constant float& cutoff2 [[buffer(2)]],
                               constant uint& count [[buffer(3)]],
                               uint i [[thread_position_in_grid]])
    {
        if (i >= count) return;
        w[i] = weights.sample(kEWALerp, r2[i] * ewaScale(cutoff2) + kEWABias).x;
    }

    // ---- panIndicators --------------------------------------------------------------------
    //
    // The pan position pills (M4b spec §5.3): composited over the finished frame, in the same command buffer, one
    // dispatch per pill over its rect only (dispatchThreads((width, height)), `origin` the rect's first pixel). Per
    // pixel: the distance from its centre to the rounded rectangle (rect, corner radius), 1 px anti-aliasing, a
    // `outline`-wide band inside the edge in the outline colour and the rest in the fill colour, then source-over.
    // The target is read and written (the drawable, framebufferOnly = false): an _srgb one blends in linear light in
    // hardware (read decodes, write encodes). On a non-_srgb target (`encoded` != 0, a defensive path: the app passes
    // the drawable itself) the kernel decodes and encodes as sRGB itself. A CURVE_TABLE frame's bytes are the photo's
    // own curve encoding, not sRGB, so they are blended as if sRGB-encoded, which is off by a few codes, invisible on
    // a neutral black and white pill. The target's alpha is kept.
    //   p [[buffer(0)]]: PanPillParams. target [[texture(0)]]: the finished frame.

    struct PanPillParams {
        float4 rect;      // view px: min x, min y, max x, max y
        float radius;     // corner radius, view px
        float outline;    // outline band width, view px
        float alpha;      // opacity of the whole pill, 0...1
        uint encoded;     // nonzero: the target holds sRGB-encoded values (not an _srgb view)
        uint2 origin;     // first pixel of the dispatch
        float2 pad;
        float4 fill;      // colour (light) and alpha of the body
        float4 line;      // colour and alpha of the outline
    };

    kernel void panIndicators(constant PanPillParams& p [[buffer(0)]],
                              texture2d<float, access::read_write> target [[texture(0)]],
                              uint2 gid [[thread_position_in_grid]])
    {
        uint2 px = p.origin + gid;
        if (px.x >= target.get_width() || px.y >= target.get_height()) return;
        float2 c = float2(px) + 0.5;
        float2 centre = (p.rect.xy + p.rect.zw) * 0.5, half_ = (p.rect.zw - p.rect.xy) * 0.5;
        float2 q = abs(c - centre) - (half_ - p.radius);
        float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - p.radius;   // < 0 inside
        float cover = saturate(0.5 - sd);
        if (cover <= 0.0) return;
        float edge = saturate(sd + p.outline + 0.5);   // how much of the pixel lies in the outline band
        float4 src = mix(p.fill, p.line, edge);
        float a = src.a * cover * p.alpha;
        float4 dst = target.read(px);
        if (p.encoded != 0) {
            float3 lin = srgbToLinear(dst.rgb) * (1.0 - a) + src.rgb * a;
            target.write(float4(linearToSRGB(lin), dst.a), px);
        } else {
            target.write(float4(dst.rgb * (1.0 - a) + src.rgb * a, dst.a), px);
        }
    }

    // ---- metalfxVertex / metalfxComposeFragment / metalfxFragment -------------------------
    //
    // upscale = metalfx (M3a spec §3.5), three passes. metalfxComposeFragment composes the view's region of the level
    // 1:1 and already oriented into the scaler's input (oriented level px origin + i at texel i), MTLFXSpatialScaler
    // magnifies the input's content region (inputContentWidth x Height texels) onto its whole output, and
    // metalfxFragment draws that output into the drawable with one bilinear sample: view position v is oriented level
    // position (v - offset) / m (plus the lead of a mirrored axis, TileRenderer.encodeMetalFX), input position that
    // minus the origin, output position that times output / content, folded into one scale and offset per axis. So the
    // pan's fractional part, and the content region's rounding up to whole texels, move no pixel. Pixels whose centre
    // is outside the image's view rect get the background exactly, as in resample. Draw with
    // drawPrimitives(.triangle, vertexStart: 0, vertexCount: 3).
    //
    // A photo with alpha (HAS_ALPHA): MTLFXSpatialScaler magnifies colour only (its output's alpha is 1, measured), so
    // the frame cannot composite after the scaler. The compose pass composites first, onto one backdrop colour
    // (`c + (1 - a) * first`), and the scaler magnifies that picture. A solid backdrop needs one run. The checkerboard
    // needs two: the picture over its first colour and over its second, each scaled on its own (TileRenderer
    // .encodeMetalFX), and the final pass takes each drawable pixel from the run of its cell's colour. So every pixel is
    // exactly what MetalFX makes of the picture over a solid backdrop of that colour, and the cells stay sharp and
    // anchored on screen. Two cheaper schemes were measured wrong: one run over the first colour with the second cells
    // corrected by `(1 - a) * (second - first)` from bilinear alpha (the scaler's edge is sharper than bilinear alpha:
    // 32-78 levels off at hard edges in the second cells), and the whole checkerboard composited before the scaler
    // (cells magnified, blurred and moved by up to m / 2 px).
    //
    // The colour cube (COLOR_LUT) goes where the frame composites, so the backdrop is never corrected: for an opaque
    // photo in the final pass, after the scaler (the compose pass and the scaler's input stay uncorrected); for a photo
    // with alpha in the compose pass, before the compositing onto the run's colour, since after the scaler there is no
    // alpha left to take the backdrop out with. The scaler then magnifies the corrected picture.

    struct MetalFXParams {
        float2 viewToOutputScale;    // output px per view px, per axis
        float2 viewToOutputOffset;   // output position of view position 0
        float2 imageMin;             // the image's view rect, as in resample
        float2 imageMax;
        float4 background;           // linear, alpha 1 (CURVE_TABLE: sRGB-encoded)
    };

    struct MetalFXComposeParams {
        int2 origin;      // oriented level px of input texel (0, 0)
        uint2 levelSize;  // stored
        uint columns;     // tile columns of the level (slice = row * columns + column)
        uint pad0;
        int2 shift;       // stored level px: levelSize - 1 on a mirrored axis
        int4 orient;      // ImageOrientation.matrix
    };

    struct MetalFXVarying {
        float4 position [[position]];
    };

    // One triangle covering the target: NDC (-1, -1), (3, -1), (-1, 3).
    vertex MetalFXVarying metalfxVertex(uint vid [[vertex_id]])
    {
        float2 c = float2((vid << 1) & 2, vid & 2);
        MetalFXVarying out;
        out.position = float4(c * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    // The compose pass, metalfxVertex scissored to the content region of the bgra8Unorm_srgb input: texel i is oriented
    // level px j = origin + i, stored px (a·j.x + b·j.y, c·j.x + d·j.y) + shift (whole px: on a mirrored axis oriented
    // px j is stored px levelSize - 1 - j), clamped into the level, read from the slot of the tile that owns it (as
    // resampleTexel). Around the image the input repeats the image's edge pixels, so no background reaches the scaler's
    // or the final pass's filters and the image's edge pixels stay the image's (the final pass cuts to the background
    // by pixel centre); at an odd size the level's overhanging last pixel is image, as in resample.
    //   slots [[texture(0)]]: the level's bgra8Unorm_srgb view (reads return linear light, the input re-encodes).
    //   p [[buffer(0)]]: MetalFXComposeParams. t [[buffer(1)]]: with HAS_ALPHA, the backdrop; the run composites onto
    //   its `first` colour (see above). With COLOR_LUT, which MetalContext gives this pass only with HAS_ALPHA (see
    //   above), each texel goes through the cube before it is composited: lut [[texture(4)]], from [[texture(5)]],
    //   cube [[buffer(2)]].
    fragment float4 metalfxComposeFragment(MetalFXVarying in [[stage_in]],
                                           texture2d_array<float, access::read> slots [[texture(0)]],
                                           constant MetalFXComposeParams& p [[buffer(0)]],
                                           constant TransparencyParams& t [[buffer(1), function_constant(kAlpha)]],
                                           texture3d<float, access::sample> lut [[texture(4), function_constant(kColorLUT)]],
                                           texture3d<float, access::sample> from [[texture(5), function_constant(kColorLUT)]],
                                           constant ColorLUTParams& cube [[buffer(2), function_constant(kColorLUT)]])
    {
        int2 j = p.origin + int2(in.position.xy);
        int2 s = int2(p.orient.x * j.x + p.orient.y * j.y, p.orient.z * j.x + p.orient.w * j.y) + p.shift;
        int2 q = clamp(s, int2(0), int2(p.levelSize) - 1);
        int2 tile = q / int(kTileSize);
        uint2 texel = uint2(q - tile * int(kTileSize) + int(kApron));
        float4 c = colorCube(slots.read(texel, uint(tile.y) * p.columns + uint(tile.x)), lut, from, cube);
        if (kAlpha) return float4(c.rgb + (1.0 - c.a) * t.first.rgb, 1.0);
        return c;
    }

    //   upscaled [[texture(0)]]: the scaler's bgra8Unorm_srgb output (samples return linear light).
    //   p [[buffer(0)]]: MetalFXParams. With HAS_ALPHA (upscaled: the run over the first colour): upscaledSecond
    //   [[texture(1)]], the run over the second colour (the same texture for a solid backdrop), and t [[buffer(1)]].
    //   With CURVE_TABLE (the target is the drawable's bgra8Unorm view): inverse [[texture(3)]], as resample.
    //   With COLOR_LUT, which MetalContext gives this pass only without HAS_ALPHA (see above), the sample goes through the
    //   cube: lut [[texture(4)]], from [[texture(5)]], cube [[buffer(2)]].
    fragment float4 metalfxFragment(MetalFXVarying in [[stage_in]],
                                    texture2d<float, access::sample> upscaled [[texture(0)]],
                                    texture2d<float, access::sample> upscaledSecond [[texture(1), function_constant(kAlpha)]],
                                    constant MetalFXParams& p [[buffer(0)]],
                                    constant TransparencyParams& t [[buffer(1), function_constant(kAlpha)]],
                                    texture1d<float, access::sample> inverse [[texture(3), function_constant(kCurveTable)]],
                                    texture3d<float, access::sample> lut [[texture(4), function_constant(kColorLUT)]],
                                    texture3d<float, access::sample> from [[texture(5), function_constant(kColorLUT)]],
                                    constant ColorLUTParams& cube [[buffer(2), function_constant(kColorLUT)]])
    {
        float2 v = in.position.xy;   // the pixel centre, view px, y down
        if (any(v < p.imageMin) || any(v >= p.imageMax)) return p.background;
        constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
        float2 o = v * p.viewToOutputScale + p.viewToOutputOffset;
        if (kAlpha && secondCell(t, v)) {
            return encodeOutput(colorCube(float4(upscaledSecond.sample(s, o).rgb, 1.0), lut, from, cube), inverse);
        }
        return encodeOutput(colorCube(float4(upscaled.sample(s, o).rgb, 1.0), lut, from, cube), inverse);
    }

    // ---- convertCube ----------------------------------------------------------------------
    //
    // A page of a spread in another colour space than the layer's (PairColorSpace): its colour cube, each node taken
    // through the matrix from the page's linear light to the layer's, so the frame converts at no cost of its own (the
    // cube is sampled anyway). Run once per cube and matrix (TileRenderer.convertedCube), never per frame. A node is
    // sRGB-encoded light (ColorCube); the converted one too, clipped to 0...1 as the drawable would clip it.
    //   src [[texture(0)]]: the page's cube (rgba16Float, n³). dst [[texture(1)]]: the converted one, the same size.
    //   m [[buffer(0)]]: the matrix (column-major, three float4-aligned columns, as simd_float3x3).
    //   dispatchThreads((n, n, n)).
    kernel void convertCube(texture3d<float, access::read> src [[texture(0)]],
                            texture3d<float, access::write> dst [[texture(1)]],
                            constant float3x3& m [[buffer(0)]],
                            uint3 gid [[thread_position_in_grid]])
    {
        if (any(gid >= uint3(dst.get_width(), dst.get_height(), dst.get_depth()))) return;
        float3 light = srgbToLinear(src.read(gid).rgb);
        dst.write(float4(linearToSRGB(m * light), 1.0), gid);
    }
    """
}

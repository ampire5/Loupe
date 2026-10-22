import LoupeCore

// Swift mirrors of the structs in `Shaders.source`. Field order, types and therefore layout must
// match the MSL declarations exactly (MetalContextTests pins the sizes and offsets): SIMD2 of a
// 4-byte scalar has the same 8-byte size and alignment as MSL `float2` / `uint2`.

/// Parameters of one `downsample2x` dispatch (compute buffer 0). Size 28, stride 32 (as MSL pads it), alignment 8.
struct DownsampleParams {
    var srcLevelSize: SIMD2<UInt32>   // source level size in pixels
    var dstLevelSize: SIMD2<UInt32>   // destination level size, ceil(src / 2)
    var srcColumns: UInt32            // tile columns of the source level (slice = row * columns + column)
    var dstColumns: UInt32            // tile columns of the destination level
    var firstSlice: UInt32 = 0        // the destination slice of the dispatch's first one (a level goes in pieces)
}

/// One tile to draw (vertex buffer 0, one element per instance). All positions in level pixels.
/// Size 28, stride 32 (4 bytes of tail padding, as in MSL): step instance buffers by `stride`.
struct TileInstance {
    var contentOrigin: SIMD2<Float>   // TileGrid.contentRect origin
    var contentSize: SIMD2<Float>     // TileGrid.contentRect size (clipped at the level edge)
    var slotOrigin: SIMD2<Float>      // TileGrid.slotOrigin: level position of slot texel (0, 0)
    var slice: UInt32                 // TileGrid.slice: index in the level's texture array
}

/// Per-draw uniforms (vertex buffer 1, and fragment buffer 0 of the nearest pass). 80 bytes, alignment 16. View
/// coordinates are physical pixels, origin top-left, y down: `view = oriented * levelToViewScale + levelToViewOffset`,
/// where the oriented level position is the stored one mapped back through the orientation:
/// `stored = matrix * oriented + shift`.
struct TileUniforms {
    var levelToViewScale: SIMD2<Float>
    var levelToViewOffset: SIMD2<Float>
    var viewSize: SIMD2<Float>        // drawable size in pixels
    var levelSize: SIMD2<Float>       // TileGrid.levelSize of the level being drawn
    var orient: SIMD4<Int32>          // ImageOrientation.matrix (a, b, c, d)
    var shift: SIMD2<Float>           // ImageOrientation.translation of the level's extent, stored level px
    var viewToLevelScale: SIMD2<Float> // 1 / levelToViewScale (the nearest pass's reciprocal)
    var extent = SIMD2<Float>(0, 0)   // the image's stored extent in level px (for `bleed`)
    var bleed: Float = 0              // > 0: the image's edge corners move this many level px outwards (a viewport cut)
    var pad: Float = 0
}

/// Parameters of one `resample` dispatch (compute buffer 0). 112 bytes, alignment 16 (`float4` aligns to 16 in MSL,
/// and `SIMD4<Float>` does in Swift). View coordinates as in `TileUniforms`: `view = oriented * levelToViewScale +
/// levelToViewOffset`, `stored = matrix * oriented + shift`, the same numbers the tile pass gets.
struct ResampleParams {
    var levelToViewScale: Float          // m: view px per level px
    var pad0: Float = 0                  // levelToViewOffset aligns to 8
    var levelToViewOffset: SIMD2<Float>  // view position of oriented level px 0
    var levelSize: SIMD2<UInt32>         // TileGrid.levelSize of the level being drawn (stored)
    var extent: SIMD2<Float>             // the image's oriented extent in level px (view rect offset + extent * m)
    var viewSize: SIMD2<UInt32>          // the dispatch's size: the drawable's, or a viewport's
    var columns: UInt32                  // tile columns of the level (slice = row * columns + column)
    var antiringing: UInt32              // nonzero: clamp magnified output to its 2x2 neighbourhood
    var background: SIMD4<Float>         // pixels whose centre is outside the image: `TileRenderer.background(for:)`
    var orient: SIMD4<Int32>             // ImageOrientation.matrix (a, b, c, d)
    var shift: SIMD2<Float>              // ImageOrientation.translation of the level's extent, stored level px
    var origin = SIMD2<UInt32>(0, 0)     // where dispatch px (0, 0) is written: (0, 0), or a viewport's corner; the
                                         // offset and the backdrop's anchor are then given less it (`encodeResample`)
    var cut = SIMD4<Float>(0, 0, 0, 0)   // VIEWPORT_CUT pipelines: the viewport in dispatch px (min x, min y, max x,
                                         // max y)
}

/// Parameters of the `metalfxComposeFragment` pass (fragment buffer 0). 48 bytes, alignment 16. Input texel i is
/// oriented level px `origin + i`, stored level px `matrix * (origin + i) + shift`.
struct MetalFXComposeParams {
    var origin: SIMD2<Int32>          // oriented level px of input texel (0, 0); negative when the view starts left of it
    var levelSize: SIMD2<UInt32>      // TileGrid.levelSize of the level being drawn (stored)
    var columns: UInt32               // tile columns of the level
    var pad0: UInt32 = 0
    var shift: SIMD2<Int32>           // levelSize - 1 on a stored axis the orientation mirrors, else 0
    var orient: SIMD4<Int32>          // ImageOrientation.matrix (a, b, c, d)
}

/// Parameters of the `metalfxFragment` pass (fragment buffer 0). 48 bytes, alignment 16. The drawable pixel centred on
/// view position v samples the scaler's output at `v * viewToOutputScale + viewToOutputOffset` (output px).
struct MetalFXParams {
    var viewToOutputScale: SIMD2<Float>   // output px per view px, per axis
    var viewToOutputOffset: SIMD2<Float>  // output position of view position 0
    var imageMin: SIMD2<Float>            // the image's view rect: pixels whose centre is outside get the background
    var imageMax: SIMD2<Float>
    var background: SIMD4<Float>          // `TileRenderer.background(for:)`
}

/// The backdrop of a photo with alpha (`HAS_ALPHA` pipelines: fragment buffer 1 of the tile and MetalFX passes, compute
/// buffer 2 of `resample` and `resampleEWA`). 48 bytes, alignment 16. The drawable pixel centred on v lies on cell
/// `floor((v - anchor) * invCell)`; cells whose coordinates sum to an even number are `first`. The colours are in the
/// photo's linear light (`TileRenderer.transparencyParams`).
struct TransparencyParams {
    var first: SIMD4<Float>     // linear, alpha 1: the cell at the image's top-left corner
    var second: SIMD4<Float>    // linear, alpha 1
    var anchor: SIMD2<Float>    // view px of the image's top-left corner
    var invCell: Float          // 1 / the cell side in drawable px
    var pad: Float = 0
}

/// Parameters of one `uploadPremultipliedLinear` dispatch (compute buffer 1). Size 20, stride 24, alignment 8.
struct AlphaUploadParams {
    var levelSize: SIMD2<UInt32>   // the level being uploaded
    var columns: UInt32            // its tile columns
    var bytesPerRow: UInt32        // of the decoded pixels
    var firstSlice: UInt32 = 0     // the slice of the dispatch's first one (an upload goes in pieces)
}

/// The colour cube of a `COLOR_LUT` pipeline (fragment buffer 2 of the tile and MetalFX passes, compute buffer 3 of
/// `resample` and `resampleEWA`; the cube itself at texture 4, the transition's `from` at texture 5). 16 bytes, alignment
/// 4. Encoded light e samples the cube at the normalised coordinate `e * scale + offset`, the centres of its first and
/// last texel at e = 0 and 1.
struct ColorLUTParams {
    var scale: Float                  // (n − 1) / n, n = ColorCube.dimension
    var offset: Float                 // 0.5 / n
    var mix: Float                    // the cube's weight against `from`'s, 0...1; 1: the cube alone, sampled once
    var pad: Float = 0

    init(mix: Float) {
        let n = Float(ColorCube.dimension)
        scale = (n - 1) / n
        offset = 0.5 / n
        self.mix = min(max(mix, 0), 1)
    }
}

/// Parameters of one `panIndicators` dispatch (compute buffer 0). 80 bytes, alignment 16. View coordinates are physical
/// pixels, origin top-left.
struct PanPillParams {
    var rect: SIMD4<Float>            // min x, min y, max x, max y
    var radius: Float                 // corner radius
    var outline: Float                // outline band width, inside the edge
    var alpha: Float                  // opacity of the whole pill
    var encoded: UInt32               // nonzero: the target holds sRGB-encoded values (not an _srgb view)
    var origin: SIMD2<UInt32>         // first pixel of the dispatch
    var pad = SIMD2<Float>(0, 0)
    var fill: SIMD4<Float>            // light and alpha of the body
    var line: SIMD4<Float>            // light and alpha of the outline
}

import LoupeCore
import Metal

/// A photo's colour cube on the GPU (M3c spec §4.1, §5): `ColorCube`'s nodes as a 3D `rgba16Float` texture of n³
/// texels (r along the width, g the height, b the depth; ~290 KB at n = 33), which the `COLOR_LUT` pipelines sample
/// trilinearly. Immutable once made, so frames on the render thread may share it with the window that built it.
public final class ColorLUT: @unchecked Sendable {
    public let texture: MTLTexture
    /// A cube whose texture the renderer made itself (`TileRenderer.convertedCube`): never the identity.
    static func made(_ texture: MTLTexture) -> ColorLUT { ColorLUT(texture: texture, isIdentity: false) }

    /// The context's shared identity cube (`identity(context:)`): a frame whose cube is it at `mix` 1 takes the
    /// pipelines without `COLOR_LUT`. A cube made by `make` is never taken for it, whatever its values (the tests draw
    /// one made from `ColorCube.identity` to measure the variant).
    public let isIdentity: Bool

    private init(texture: MTLTexture, isIdentity: Bool) {
        self.texture = texture
        self.isIdentity = isIdentity
    }

    /// `cube` uploaded; nil when the texture cannot be allocated.
    public static func make(_ cube: ColorCube, context: MetalContext = .shared) -> ColorLUT? {
        texture(cube, device: context.device).map { ColorLUT(texture: $0, isIdentity: false) }
    }

    /// The identity cube of `context`, made on first use and shared by every renderer: the "from" of a correction fading
    /// in and the target of one fading out.
    public static func identity(context: MetalContext = .shared) -> ColorLUT {
        context.identityColorLUT {
            guard let made = texture(.identity, device: context.device) else {
                fatalError("Metal: no texture for the identity colour cube")
            }
            made.label = "colour cube, identity"
            return ColorLUT(texture: made, isIdentity: true)
        }
    }

    private static func texture(_ cube: ColorCube, device: MTLDevice) -> MTLTexture? {
        let n = ColorCube.dimension
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba16Float
        d.width = n
        d.height = n
        d.depth = n
        d.storageMode = .shared
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        let texel = 4 * MemoryLayout<Half>.stride
        cube.values.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: n * texel, bytesPerImage: n * n * texel)
        }
        texture.label = "colour cube"
        return texture
    }
}

/// The colour cube of one frame (`TileRenderer.color`): `lut`, and while a correction changes (spec §2.2) the cube it
/// changes from, `from` (nil: the identity), weighted `1 − mix` against `lut`'s `mix` in linear light.
public struct ColorFrame: Sendable {
    public var lut: ColorLUT
    public var from: ColorLUT?
    /// 0...1 (clamped when drawn): 1 shows `lut` alone, and only then is a frame sampled once.
    public var mix: Float

    public init(lut: ColorLUT, from: ColorLUT? = nil, mix: Float = 1) {
        self.lut = lut
        self.from = from
        self.mix = mix
    }

    /// Whether the frame looks as it would without a cube, so it takes the pipelines of before: the shared identity,
    /// fully shown.
    var isIdentity: Bool { lut.isIdentity && mix >= 1 }
}

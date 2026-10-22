import Foundation
import LoupeCore
import Metal
import MetalFX

/// The process-wide Metal device, queue and pipelines. Shaders are compiled from source once at
/// first use (Command Line Tools have no offline `metal` compiler), so every texture upload, pyramid
/// build and render shares one compiled library instead of paying compilation per image.
public final class MetalContext: @unchecked Sendable {
    /// Created on first access. A Mac without Metal cannot show anything, so that is fatal.
    public static let shared = MetalContext()

    public let device: MTLDevice
    /// Frames (and anything a frame must see in order) go here.
    public let queue: MTLCommandQueue
    /// Texture uploads and pyramid builds (label "upload"): a separate queue, so a frame never waits behind
    /// a 100 MP upload (M2 spec §4.4). A separate queue alone is not enough on a discrete GPU, which ran a whole upload
    /// before the frames queued behind it: uploads go in pieces and yield to `frames` (`TiledImage.encodeAndRun`).
    public let uploadQueue: MTLCommandQueue
    /// The frames in flight on `queue`: whoever commits a frame tracks it here, so uploads yield to it.
    public let frames = FrameTraffic()
    /// `downsample2x`: builds pyramid level L+1 from level L (see `Shaders.source` for its contract).
    public let downsample: MTLComputePipelineState
    /// `downsampleLanczos2x`: the same with a Lanczos-3 2x decimation (`pyramid-filter = lanczos3`).
    public let downsampleLanczos: MTLComputePipelineState
    /// `uploadPremultipliedLinear`: uploads a level with alpha < 1, or of a `.table` curve, as premultiplied linear light
    /// (`Shaders.source`), through its curve's `CurveTables.upload()`.
    let uploadPremultipliedLinear: MTLComputePipelineState

    /// `ewaWeightTable()` for `resampleEWA`: a 1024-texel r32Float 1D texture (4 KiB), made once, which the shader
    /// samples with linear filtering.
    public let ewaWeights: MTLTexture
    /// Whether the GPU filters 32-bit float textures, which `ewaWeights` needs (every Mac GPU does; checked so a GPU
    /// without it draws Lanczos-3 instead of wrong weights, and the stats line says so through `drawnMode`).
    public let supportsEWA: Bool
    /// Whether shaders can write `_srgb` textures, which encode on store (Apple GPUs). Intel and AMD Macs
    /// cannot: there the resample kernels write the drawable's unorm view and encode themselves
    /// (`ENCODE_SRGB`), or their linear light would show as is, too dark.
    public let supportsSRGBWrites: Bool

    /// Whether this GPU has MetalFX's spatial scaler (`upscale = metalfx`, spec §3.5). Without it such a frame is
    /// drawn with Lanczos-3, and the stats line names what was drawn (`drawnMode`).
    public let supportsMetalFX: Bool

    let library: MTLLibrary   // internal: tests reflect on the compiled structs
    private let lock = NSLock()
    private var tilePipelines: [TileKey: MTLRenderPipelineState] = [:]
    private var resamplePipelines: [ResampleKey: MTLComputePipelineState] = [:]
    private var metalFXPipelines: [MetalFXKey: MTLRenderPipelineState] = [:]
    private var ewaPipelineStates: [EWAKey: MTLComputePipelineState] = [:]
    private var panIndicatorsState: MTLComputePipelineState?
    private var convertCubeState: MTLComputePipelineState?
    /// `curveTables(for:)`, oldest first; at most `curveTableLimit` curves.
    private var curveTables: [ColorCurve: CurveTables] = [:]
    private var curveOrder: [ColorCurve] = []
    /// Curves whose tables stay cached (72 KiB each at most). A photo holds its own tables, so dropping a curve from the
    /// cache only means the next photo with it makes them again.
    static let curveTableLimit = 16
    /// Set when a renderer could not make its MetalFX scaler or textures, cleared when one could (`drawnMode`).
    private var metalFXStageFailed = false
    /// `ColorLUT.identity(context:)`, made on first use.
    private var identityLUT: ColorLUT?

    private struct TileKey: Hashable {
        let pixelFormat: MTLPixelFormat
        let nearest: Bool
        let alpha: Bool
        let curveTable: Bool
        let colorLUT: Bool
    }

    private struct MetalFXKey: Hashable {
        let pixelFormat: MTLPixelFormat
        let compose: Bool
        let alpha: Bool
        let curveTable: Bool
        let colorLUT: Bool
    }

    private struct ResampleKey: Hashable {
        let kernel: ResampleKernel
        let upscale: Bool
        let alpha: Bool
        let curveTable: Bool
        let colorLUT: Bool
        let encodeSRGB: Bool
        let cut: Bool
    }

    private struct EWAKey: Hashable {
        let alpha: Bool
        let curveTable: Bool
        let colorLUT: Bool
        let encodeSRGB: Bool
        let cut: Bool
    }

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Loupe needs a Metal GPU, but MTLCreateSystemDefaultDevice() returned nil")
        }
        guard let queue = device.makeCommandQueue(), let uploadQueue = device.makeCommandQueue() else {
            fatalError("Metal: could not create a command queue")
        }
        queue.label = "frames"
        uploadQueue.label = "upload"
        self.device = device
        self.queue = queue
        self.uploadQueue = uploadQueue
        supportsMetalFX = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        supportsEWA = device.supports32BitFloatFiltering
        supportsSRGBWrites = device.supportsFamily(.apple2)
        let table = Self.ewaWeightTable()
        let lut = MTLTextureDescriptor()
        lut.textureType = .type1D
        lut.pixelFormat = .r32Float
        lut.width = table.count
        lut.storageMode = .shared
        lut.usage = .shaderRead
        guard let weights = device.makeTexture(descriptor: lut) else { fatalError("Metal: no EWA weight table texture") }
        weights.replace(region: MTLRegionMake1D(0, table.count), mipmapLevel: 0, withBytes: table,
                        bytesPerRow: table.count * MemoryLayout<Float>.stride)
        weights.label = "EWA weights"
        ewaWeights = weights

        let options = MTLCompileOptions()
        options.languageVersion = .version3_2
        options.mathMode = .safe   // the sRGB curve and averaging must not be approximated
        do {
            library = try device.makeLibrary(source: Shaders.source, options: options)
        } catch {
            fatalError("Metal shader compilation failed:\n\(error)")
        }
        downsample = Self.computePipeline(device: device, library: library, name: "downsample2x")
        downsampleLanczos = Self.computePipeline(device: device, library: library, name: "downsampleLanczos2x")
        uploadPremultipliedLinear = Self.computePipeline(device: device, library: library,
                                                         name: "uploadPremultipliedLinear")
    }

    /// The pan indicator pills' compositing kernel (`TileRenderer.encodePanIndicators`), compiled on first use (the first
    /// frame with pills on screen), like the resample pipelines, so the launch path does not compile it. Thread-safe.
    var panIndicators: MTLComputePipelineState {
        lock.lock()
        defer { lock.unlock() }
        if let panIndicatorsState { return panIndicatorsState }
        let state = Self.computePipeline(device: device, library: library, name: "panIndicators")
        panIndicatorsState = state
        return state
    }

    /// The kernel that converts a colour cube into another space (`TileRenderer.conversion`), compiled on first use (the
    /// first spread of two colour spaces). Thread-safe.
    var convertCube: MTLComputePipelineState {
        lock.lock()
        defer { lock.unlock() }
        if let convertCubeState { return convertCubeState }
        let state = Self.computePipeline(device: device, library: library, name: "convertCube")
        convertCubeState = state
        return state
    }

    // MARK: Colour curve (M3b spec §4)

    /// The GPU tables of `curve`, made on first use and shared by every photo with that curve; nil when the inverse
    /// table's texture cannot be allocated. Thread-safe.
    func curveTables(for curve: ColorCurve) -> CurveTables? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = curveTables[curve] { return cached }
        guard let made = CurveTables(curve: curve, device: device) else { return nil }
        curveTables[curve] = made
        curveOrder.append(curve)
        if curveOrder.count > Self.curveTableLimit { curveTables[curveOrder.removeFirst()] = nil }
        return made
    }

    // MARK: Colour cube (M3c spec §5)

    /// The shared identity cube (`ColorLUT.identity(context:)`), from `make` the first time. Thread-safe.
    func identityColorLUT(_ make: () -> ColorLUT) -> ColorLUT {
        lock.lock()
        defer { lock.unlock() }
        if let identityLUT { return identityLUT }
        let made = make()
        identityLUT = made
        return made
    }

    // MARK: Transparency (M3b spec §3)

    /// The sRGB curve, encoded level 0...1 to linear light and back (IEC 61966-2-1).
    static func srgbDecode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func srgbEncode(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// The upload of a level with alpha < 1 or of a `.table` curve (`uploadPremultipliedLinear`): entry `a * 256 + s` is
    /// the colour byte `s` of a pixel premultiplied on its encoded values with alpha byte `a`, rewritten as
    /// `encode(decode(s / a) · a)`, rounded: its premultiplied linear light, in the encoding the levels' `_srgb` views
    /// decode. Exact in double; 0 for a = 0, the straight colour clamped to 1 for an out-of-range s > a. `decode`
    /// linearises the photo's encoded values with its transfer curve: for sRGB, a = 255 gives every s itself (the round
    /// trip), so opaque pixels keep their bytes; for a `.table` curve, it gives the sRGB byte of the code's light (the
    /// levels' storage, `Shaders.source`). `encode` must stay the curve the level is read back with, sRGB as long as
    /// the `_srgb` view does it.
    static func premultipliedLinearTable(decode: (Double) -> Double = srgbDecode,
                                         encode: (Double) -> Double = srgbEncode) -> [UInt8] {
        var table = [UInt8](repeating: 0, count: 256 * 256)
        for a in 1..<256 {
            let alpha = Double(a) / 255
            for s in 0..<256 {
                let straight = min(Double(s) / Double(a), 1)
                table[a * 256 + s] = UInt8((encode(decode(straight) * alpha) * 255).rounded())
            }
        }
        return table
    }

    /// The tile draw pipeline (`tileVertex` with `tileFragment`, or with `tileFragmentNearest` when `nearest`: the
    /// pixel-art path) for a colour attachment format, compiled once per pair. Thread-safe, so a render thread may
    /// call it per frame.
    /// `alpha`: the `HAS_ALPHA` variant, for a photo with transparency (composites over the backdrop). `curveTable`: the
    /// `CURVE_TABLE` variant, for a photo with a `.table` curve (writes through its inverse table, into a unorm target).
    /// `colorLUT`: the `COLOR_LUT` variant, for a frame with a colour cube (samples it before the backdrop).
    public func tilePipeline(pixelFormat: MTLPixelFormat, nearest: Bool = false, alpha: Bool = false,
                             curveTable: Bool = false, colorLUT: Bool = false) -> MTLRenderPipelineState {
        let key = TileKey(pixelFormat: pixelFormat, nearest: nearest, alpha: alpha, curveTable: curveTable,
                          colorLUT: colorLUT)
        lock.lock()
        defer { lock.unlock() }
        if let cached = tilePipelines[key] { return cached }
        let d = MTLRenderPipelineDescriptor()
        d.label = "tile\(nearest ? " nearest" : "")\(alpha ? " alpha" : "")\(curveTable ? " table" : "")"
            + "\(colorLUT ? " cube" : "") \(pixelFormat.rawValue)"
        d.vertexFunction = Self.function(library, "tileVertex")
        d.fragmentFunction = Self.function(library, nearest ? "tileFragmentNearest" : "tileFragment", alpha: alpha,
                                           curveTable: curveTable, colorLUT: colorLUT)
        d.colorAttachments[0].pixelFormat = pixelFormat
        d.colorAttachments[0].isBlendingEnabled = false   // opaque tiles over a cleared background (M1)
        let state: MTLRenderPipelineState
        do {
            state = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            fatalError("Metal: tile pipeline for pixel format \(pixelFormat.rawValue) failed:\n\(error)")
        }
        tilePipelines[key] = state
        return state
    }

    /// The path a frame of `mode` really takes: `.metalfx` is drawn as Lanczos-3 magnification (`metalFXFallback`)
    /// on a GPU without a spatial scaler, and while the last attempt to make a renderer's scaler or textures failed;
    /// `.ewaLanczos` likewise on a GPU that cannot filter its weight table (`supportsEWA`): the rules
    /// `TileRenderer.encode` applies. For the stats line, so it names what is on screen. Thread-safe.
    public func drawnMode(_ mode: ResampleMode) -> ResampleMode {
        lock.lock()
        let failed = metalFXStageFailed
        lock.unlock()
        return Self.drawnMode(mode, supported: supportsMetalFX, stageFailed: failed, ewa: supportsEWA)
    }

    static func drawnMode(_ mode: ResampleMode, supported: Bool, stageFailed: Bool, ewa: Bool = true) -> ResampleMode {
        if mode == .ewaLanczos && !ewa { return metalFXFallback }
        return mode == .metalfx && (!supported || stageFailed) ? metalFXFallback : mode
    }

    /// Whether a renderer's attempt to make its MetalFX scaler and textures succeeded (`drawnMode`).
    func noteMetalFXStage(made: Bool) {
        lock.lock()
        metalFXStageFailed = !made
        lock.unlock()
    }

    /// What a MetalFX frame is drawn with when MetalFX cannot draw it (and an EWA Lanczos frame on a GPU without
    /// `supportsEWA`).
    public static let metalFXFallback = ResampleMode.kernel(.lanczos3, upscale: true)

    /// A pass of the MetalFX path for a colour attachment format, compiled once per pair: `metalfxVertex` with
    /// `metalfxFragment` (the scaler's output into the drawable), or with `metalfxComposeFragment` when `compose` (the
    /// level into the scaler's input). `alpha`: the pass's `HAS_ALPHA` variant; `curveTable`: the `CURVE_TABLE` variant
    /// of the final pass (the compose pass has none: it writes the scaler's `_srgb` input). `colorLUT`: the frame has a
    /// colour cube, which the pass that composites samples (Shaders, metalfxFragment): the final pass of an opaque photo,
    /// the compose pass of one with alpha; the other pass's variant is its plain one. Thread-safe.
    public func metalFXPipeline(pixelFormat: MTLPixelFormat, compose: Bool = false, alpha: Bool = false,
                                curveTable: Bool = false, colorLUT: Bool = false) -> MTLRenderPipelineState {
        let key = MetalFXKey(pixelFormat: pixelFormat, compose: compose, alpha: alpha, curveTable: curveTable && !compose,
                             colorLUT: colorLUT && compose == alpha)
        lock.lock()
        defer { lock.unlock() }
        if let cached = metalFXPipelines[key] { return cached }
        let d = MTLRenderPipelineDescriptor()
        d.label = "metalfx\(compose ? " compose" : "")\(alpha ? " alpha" : "")\(key.curveTable ? " table" : "")"
            + "\(key.colorLUT ? " cube" : "") \(pixelFormat.rawValue)"
        d.vertexFunction = Self.function(library, "metalfxVertex")
        d.fragmentFunction = Self.function(library, compose ? "metalfxComposeFragment" : "metalfxFragment", alpha: alpha,
                                           curveTable: key.curveTable, colorLUT: key.colorLUT)
        d.colorAttachments[0].pixelFormat = pixelFormat
        let state: MTLRenderPipelineState
        do {
            state = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            fatalError("Metal: metalfx pipeline for pixel format \(pixelFormat.rawValue) failed:\n\(error)")
        }
        metalFXPipelines[key] = state
        return state
    }

    /// The `resample` compute pipeline for a kernel and direction (`upscale`: `m > 1`, which halves the taps),
    /// compiled once per pair: 4 kernels x 2 directions = 8 at most, each on first use. Thread-safe, so a render
    /// thread may call it per frame. Limited to the kernel's 16 x 16 threadgroups, so the compiler sizes registers
    /// for exactly that and the dispatch can never be refused for too many threads. `alpha`: the `HAS_ALPHA` variant,
    /// `curveTable` the `CURVE_TABLE` one, `colorLUT` the `COLOR_LUT` one (64 at most, then).
    public func resamplePipeline(kernel: ResampleKernel, upscale: Bool, alpha: Bool = false,
                                 curveTable: Bool = false, colorLUT: Bool = false,
                                 encodeSRGB: Bool = false, cut: Bool = false) -> MTLComputePipelineState {
        let key = ResampleKey(kernel: kernel, upscale: upscale, alpha: alpha, curveTable: curveTable, colorLUT: colorLUT,
                              encodeSRGB: encodeSRGB, cut: cut)
        lock.lock()
        defer { lock.unlock() }
        if let cached = resamplePipelines[key] { return cached }
        let d = MTLComputePipelineDescriptor()
        d.label = "resample \(kernel.rawValue) \(upscale ? "up" : "down")\(alpha ? " alpha" : "")\(curveTable ? " table" : "")"
            + "\(colorLUT ? " cube" : "")\(encodeSRGB ? " encode" : "")\(cut ? " cut" : "")"
        d.computeFunction = Self.resampleFunction(library, kernel: kernel, upscale: upscale, alpha: alpha,
                                                  curveTable: curveTable, colorLUT: colorLUT, encodeSRGB: encodeSRGB,
                                                  cut: cut)
        d.maxTotalThreadsPerThreadgroup = 256
        let state: MTLComputePipelineState
        do {
            state = try device.makeComputePipelineState(descriptor: d, options: [], reflection: nil)
        } catch {
            fatalError("Metal: resample pipeline \(kernel.rawValue) up=\(upscale) failed:\n\(error)")
        }
        resamplePipelines[key] = state
        return state
    }

    /// `resample` specialised by its function constants: `RESAMPLE_KERNEL` (index 0) is the `ResampleKernel` case
    /// order, `RESAMPLE_TAPS` (index 1) the taps per axis, `support * 2` up and `support * 4` down (spec §3.2),
    /// `HAS_ALPHA` (index 2) `alpha`, `CURVE_TABLE` (index 3) `curveTable`, `COLOR_LUT` (index 4) `colorLUT`,
    /// `ENCODE_SRGB` (index 5) `encodeSRGB`. Internal so tests can reflect on it.
    static func resampleFunction(_ library: MTLLibrary, kernel: ResampleKernel, upscale: Bool,
                                 alpha: Bool = false, curveTable: Bool = false, colorLUT: Bool = false,
                                 encodeSRGB: Bool = false, cut: Bool = false) -> MTLFunction {
        let constants = MTLFunctionConstantValues()
        var index = Int32(ResampleKernel.allCases.firstIndex(of: kernel)!)
        var taps = Int32(kernel.support * (upscale ? 2 : 4))
        var hasAlpha = alpha, table = curveTable, cube = colorLUT, encode = encodeSRGB
        constants.setConstantValue(&index, type: .int, index: 0)
        constants.setConstantValue(&taps, type: .int, index: 1)
        constants.setConstantValue(&hasAlpha, type: .bool, index: 2)
        constants.setConstantValue(&table, type: .bool, index: 3)
        constants.setConstantValue(&cube, type: .bool, index: 4)
        constants.setConstantValue(&encode, type: .bool, index: 5)
        // Set only for a spread's page: unset, the kernel compiles as before (`VIEWPORT_CUT` undefined).
        var viewportCut = true
        if cut { constants.setConstantValue(&viewportCut, type: .bool, index: 6) }
        do {
            return try library.makeFunction(name: "resample", constantValues: constants)
        } catch {
            fatalError("Metal: shader function resample (\(kernel.rawValue), \(taps) taps) failed:\n\(error)")
        }
    }

    // MARK: EWA Lanczos (spec §3.7)

    /// mpv's `ewa_lanczossharp`: the kernel radius before blur (third zero of J1 over π), the jinc window's radius (its
    /// first zero, J1's over π) and the blur that narrows the kernel slightly for sharpness.
    static let ewaRadius = 3.2383154841662362
    static let ewaFirstZero = 1.2196698912665045
    static let ewaBlur = 0.9812505644269356
    /// Entries of the weight table (`kEWATable` in the shader).
    static let ewaTableCount = 1024
    /// The square of the kernel's blurred radius, `(R·b)^2` in level px^2: the table's range, the taps' cutoff.
    static let ewaCutoffSquared = Float((ewaRadius * ewaBlur) * (ewaRadius * ewaBlur))

    /// The weight `jinc(r / b) · jinc(r / (b·R / z1))` (the window stretched to the blurred radius, as mpv's
    /// `sample_filter`) at `r^2 = i / (count - 1) · (R·b)^2`, for i in 0 ..< `ewaTableCount`: indexed by r^2 so the
    /// shader needs no sqrt, and linearly interpolated there by the texture sampler (`ResampleRendererTests.ewaLUT…`
    /// measure the error against the formula). Evaluated in double with libm's `j1`. The last entry, r = R·b, is the
    /// kernel's zero (J1 at its third zero), stored as exactly 0.
    static func ewaWeightTable() -> [Float] {
        func jinc(_ x: Double) -> Double {
            if x == 0 { return 1 }
            let p = Double.pi * x
            return 2 * j1(p) / p
        }
        let cutoff = ewaRadius * ewaBlur, window = ewaBlur * ewaRadius / ewaFirstZero
        return (0..<ewaTableCount).map { i in
            guard i < ewaTableCount - 1 else { return 0 }
            let r = (Double(i) / Double(ewaTableCount - 1)).squareRoot() * cutoff
            return Float(jinc(r / ewaBlur) * jinc(r / window))
        }
    }

    /// `resampleEWA` (`upscale = ewa-lanczos`), compiled on first use (and its `HAS_ALPHA` variant when `alpha`, its
    /// `CURVE_TABLE` one when `curveTable`, its `COLOR_LUT` one when `colorLUT`). Thread-safe. Limited to 16 x 16
    /// threadgroups, as `resamplePipeline`.
    public func ewaPipeline(alpha: Bool = false, curveTable: Bool = false, colorLUT: Bool = false,
                            encodeSRGB: Bool = false, cut: Bool = false) -> MTLComputePipelineState {
        let key = EWAKey(alpha: alpha, curveTable: curveTable, colorLUT: colorLUT, encodeSRGB: encodeSRGB, cut: cut)
        lock.lock()
        defer { lock.unlock() }
        if let cached = ewaPipelineStates[key] { return cached }
        let d = MTLComputePipelineDescriptor()
        d.label = "resampleEWA\(alpha ? " alpha" : "")\(curveTable ? " table" : "")\(colorLUT ? " cube" : "")"
            + "\(encodeSRGB ? " encode" : "")\(cut ? " cut" : "")"
        d.computeFunction = Self.function(library, "resampleEWA", alpha: alpha, curveTable: curveTable, colorLUT: colorLUT,
                                          encodeSRGB: encodeSRGB, cut: cut)
        d.maxTotalThreadsPerThreadgroup = 256
        do {
            let state = try device.makeComputePipelineState(descriptor: d, options: [], reflection: nil)
            ewaPipelineStates[key] = state
            return state
        } catch {
            fatalError("Metal: resampleEWA pipeline failed:\n\(error)")
        }
    }

    private static func function(_ library: MTLLibrary, _ name: String) -> MTLFunction {
        guard let f = library.makeFunction(name: name) else { fatalError("Metal: shader function \(name) missing") }
        return f
    }

    /// A function with the `HAS_ALPHA` (index 2), `CURVE_TABLE` (index 3) and `COLOR_LUT` (index 4) constants, which
    /// those functions need set either way, and `ENCODE_SRGB` (index 5, the compute kernels'). Internal so tests can
    /// reflect on it.
    static func function(_ library: MTLLibrary, _ name: String, alpha: Bool, curveTable: Bool = false,
                         colorLUT: Bool = false, encodeSRGB: Bool = false, cut: Bool = false) -> MTLFunction {
        let constants = MTLFunctionConstantValues()
        var hasAlpha = alpha, table = curveTable, cube = colorLUT, encode = encodeSRGB
        constants.setConstantValue(&hasAlpha, type: .bool, index: 2)
        constants.setConstantValue(&table, type: .bool, index: 3)
        constants.setConstantValue(&cube, type: .bool, index: 4)
        constants.setConstantValue(&encode, type: .bool, index: 5)
        var viewportCut = true
        if cut { constants.setConstantValue(&viewportCut, type: .bool, index: 6) }   // `VIEWPORT_CUT`, EWA's
        do {
            return try library.makeFunction(name: name, constantValues: constants)
        } catch {
            fatalError("Metal: shader function \(name) (alpha \(alpha), table \(curveTable), cube \(colorLUT)) failed:\n\(error)")
        }
    }

    private static func computePipeline(device: MTLDevice, library: MTLLibrary, name: String) -> MTLComputePipelineState {
        do {
            return try device.makeComputePipelineState(function: function(library, name))
        } catch {
            fatalError("Metal: compute pipeline \(name) failed:\n\(error)")
        }
    }
}

/// The GPU side of a photo's `ColorCurve` (M3b spec §4), from `MetalContext.curveTables(for:)`: shared by every photo
/// with that curve, and held by each (`TiledImage`), so it outlives the context's cache.
final class CurveTables: @unchecked Sendable {
    let curve: ColorCurve
    /// A `.table` curve's inverse table (`ColorCurve.table`'s `inverse`): a 4096-texel r16Unorm 1D texture (8 KiB), which
    /// the `CURVE_TABLE` pipelines sample with linear filtering at `(√light · 4095 + 0.5) / 4096`. 16-bit unorm, 1/65535
    /// of a level (0.004 of a code), because it filters at full rate: as r32Float the 6K Lanczos-3 frame at 100 % cost
    /// 2.65 ms instead of 2.18 (docs/bench/2026-10-15-m3b-render.md). Nil for `.srgb`, whose frames the `_srgb` drawable
    /// encodes.
    let inverse: MTLTexture?
    private let device: MTLDevice
    private let lock = NSLock()
    private var uploadTable: MTLBuffer?

    /// Nil when the inverse table's texture cannot be allocated.
    init?(curve: ColorCurve, device: MTLDevice) {
        self.curve = curve
        self.device = device
        guard case .table(_, let table) = curve else {
            inverse = nil
            return
        }
        let d = MTLTextureDescriptor()
        d.textureType = .type1D
        d.pixelFormat = .r16Unorm
        d.width = table.count
        d.storageMode = .shared
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        let levels = table.map { UInt16((min(max($0, 0), 1) * 65535).rounded()) }
        texture.replace(region: MTLRegionMake1D(0, levels.count), mipmapLevel: 0, withBytes: levels,
                        bytesPerRow: levels.count * MemoryLayout<UInt16>.stride)
        texture.label = "inverse curve"
        inverse = texture
    }

    /// `MetalContext.premultipliedLinearTable(decode:)` with this curve's decode, as a 64 KiB shared buffer: made by the
    /// first upload that needs it (~0.85 ms; a photo with alpha, or any of a `.table` curve), not on the launch path.
    /// Nil if it cannot be allocated. Thread-safe.
    func upload() -> MTLBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if let uploadTable { return uploadTable }
        let curve = self.curve
        let table = curve == .srgb ? MetalContext.premultipliedLinearTable()
                                   : MetalContext.premultipliedLinearTable(decode: { Double(curve.decode(Float($0))) })
        uploadTable = device.makeBuffer(bytes: table, length: table.count, options: .storageModeShared)
        uploadTable?.label = "premultiplied linear\(curve == .srgb ? "" : ", table curve")"
        return uploadTable
    }
}

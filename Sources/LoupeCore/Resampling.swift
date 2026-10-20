import Foundation

/// A separable reconstruction kernel of the `resample` compute pass (spec §3.2).
public enum ResampleKernel: String, CaseIterable, Sendable {
    case lanczos3, lanczos2, mitchell
    case catmullRom = "catmull-rom"

    /// Taps per axis at upscale, `2 * support`: how many source pixels one output pixel reads (at downscale the
    /// kernel stretches, so it reads `support / m` times as many).
    public var support: Int { self == .lanczos3 ? 3 : 2 }

    /// The kernels in the order the filter cycles go through them (declaration order, which `allCases` follows too,
    /// but spelled out so reordering the cases cannot reorder the `S` key).
    static let cycle: [ResampleKernel] = [.lanczos3, .lanczos2, .mitchell, .catmullRom]
}

/// `upscale` / `upscale-high`: the filter for frames where one image pixel covers more than one screen pixel
/// (`m > 1`).
public enum UpscaleFilter: Equatable, Sendable {
    case kernel(ResampleKernel), bilinear
    /// MetalFX Spatial (spec §3.5): Apple's edge-adaptive upscaler. Magnifying only, so not a `DownscaleFilter`.
    case metalfx
    /// EWA Lanczos (spec §3.7, mpv's `ewa_lanczossharp`): a radial jinc-windowed jinc over the 2D neighbourhood, with
    /// no separable stairs on diagonals at strong magnification (user, Build 1 trial). Magnifying only.
    case ewaLanczos

    /// Case-insensitive; `ewa` is short for `ewa-lanczos`.
    public init?(text: String) {
        switch text.lowercased() {
        case "bilinear": self = .bilinear
        case "metalfx": self = .metalfx
        case "ewa-lanczos", "ewa": self = .ewaLanczos
        default:
            guard let kernel = ResampleKernel(filterText: text) else { return nil }
            self = .kernel(kernel)
        }
    }

    /// The order of the `S` key (spec §4): the kernels, bilinear, then the two magnifying-only filters.
    public static let cycle: [UpscaleFilter] = ResampleKernel.cycle.map { .kernel($0) } + [.bilinear, .metalfx, .ewaLanczos]

    /// The filter after this one in `cycle`, wrapping; a value outside it starts the cycle over.
    public func next() -> UpscaleFilter {
        guard let i = Self.cycle.firstIndex(of: self) else { return Self.cycle[0] }
        return Self.cycle[(i + 1) % Self.cycle.count]
    }

    /// The canonical spelling, as written back to loupe.conf.
    public var text: String {
        switch self {
        case .bilinear: return "bilinear"
        case .metalfx: return "metalfx"
        case .ewaLanczos: return "ewa-lanczos"
        case .kernel(let kernel): return kernel.rawValue
        }
    }
}

/// `downscale`: the filter for frames where one screen pixel covers one or more image pixels (`m <= 1`).
public enum DownscaleFilter: Equatable, Sendable {
    case kernel(ResampleKernel), bilinear

    /// Case-insensitive.
    public init?(text: String) {
        if text.lowercased() == "bilinear" { self = .bilinear }
        else if let kernel = ResampleKernel(filterText: text) { self = .kernel(kernel) }
        else { return nil }
    }

    /// The order of the `S` key (spec §4): the kernels, then bilinear.
    public static let cycle: [DownscaleFilter] = ResampleKernel.cycle.map { .kernel($0) } + [.bilinear]

    /// The filter after this one in `cycle`, wrapping; a value outside it starts the cycle over.
    public func next() -> DownscaleFilter {
        guard let i = Self.cycle.firstIndex(of: self) else { return Self.cycle[0] }
        return Self.cycle[(i + 1) % Self.cycle.count]
    }

    /// The canonical spelling, as written back to loupe.conf.
    public var text: String {
        switch self {
        case .bilinear: return "bilinear"
        case .kernel(let kernel): return kernel.rawValue
        }
    }
}

extension ResampleKernel {
    /// The spelling `upscale` and `downscale` share, so the two filter enums cannot drift apart: the raw value,
    /// case-insensitive.
    init?(filterText text: String) { self.init(rawValue: text.lowercased()) }
}

/// `pyramid-filter`: how each pyramid level is built from the next finer one (spec §4). Not a frame setting: a level
/// is built once at upload, so a change applies to photos uploaded after it.
public enum PyramidFilter: String, Sendable {
    /// 2x2 average in linear light (`downsample2x`).
    case box
    /// Lanczos-3 2x decimation in linear light, 12 taps per axis (`downsampleLanczos2x`).
    case lanczos3

    /// Case-insensitive.
    public init?(text: String) {
        self.init(rawValue: text.lowercased())
    }
}

/// The resampling keys of loupe.conf, as the renderer reads them.
public struct ResampleSettings: Equatable, Sendable {
    public var upscale: UpscaleFilter = .kernel(.lanczos3)
    /// `upscale-high`: the filter from `upscaleHighPercent` up (user, M3a trial: past ×3 Lanczos' rings and
    /// separable stairs grow with the zoom, a softer kernel can look better there).
    public var upscaleHigh: UpscaleFilter = .kernel(.mitchell)
    /// `upscale-high-from`: magnification in percent from which `upscaleHigh` replaces `upscale`; 0 is off.
    public var upscaleHighPercent = 300
    public var downscale: DownscaleFilter = .kernel(.lanczos3)
    /// `lanczos-antiring`: clamp Lanczos upscaling to the range of its neighbourhood (spec §3.2).
    public var antiringing = false
    /// `pixel-art`: zoom threshold in percent from which level 0 is drawn nearest-neighbour; 0 is off.
    public var pixelArtPercent = 400

    public init(upscale: UpscaleFilter = .kernel(.lanczos3), upscaleHigh: UpscaleFilter = .kernel(.mitchell),
                upscaleHighPercent: Int = 300, downscale: DownscaleFilter = .kernel(.lanczos3),
                antiringing: Bool = false, pixelArtPercent: Int = 400) {
        self.upscale = upscale
        self.upscaleHigh = upscaleHigh
        self.upscaleHighPercent = upscaleHighPercent
        self.downscale = downscale
        self.antiringing = antiringing
        self.pixelArtPercent = pixelArtPercent
    }

    public init(config: Config) {
        self.init(upscale: config.upscale, upscaleHigh: config.upscaleHigh, upscaleHighPercent: config.upscaleHighPercent,
                  downscale: config.downscale,
                  antiringing: config.lanczosAntiring, pixelArtPercent: config.pixelArtPercent)
    }
}

/// The filter keys of loupe.conf that a frame is drawn with: the frame's mode picks one (`activeKey`), and the `S` key
/// of the viewer cycles that one (folder settings spec §4).
public enum ResampleKey: String, Sendable {
    case downscale, upscale
    case upscaleHigh = "upscale-high"
}

/// Which path draws a frame (spec §3.1).
public enum ResampleMode: Equatable, Sendable {
    case nearest, bilinear
    /// The compute kernel; `upscale` is whether the frame magnifies (`m > 1`), which picks the tap count and
    /// whether antiringing applies.
    case kernel(ResampleKernel, upscale: Bool)
    /// MetalFX Spatial (spec §3.5); only ever a magnifying frame.
    case metalfx
    /// The `resampleEWA` compute kernel (spec §3.7); only ever a magnifying frame.
    case ewaLanczos
}

extension ResampleSettings {
    /// The path for a frame drawn from pyramid `level` at `scale` (screen px per image px). `m = scale * 2^level`
    /// is the magnification of the level actually drawn, which differs from `scale` when a coarse level is stretched
    /// or a coarser one than the screen needs is the finest resident.
    ///
    /// Nearest only applies to level 0: while only a preview is resident, a 400 % zoom would otherwise show giant
    /// blocks of a blurry level; the kernel path gives a smooth stretch until the real pixels arrive. `m < 0.5`
    /// is bilinear because past the coarsest level a tiny image is drawn from a level that is already smaller
    /// than the screen needs and a wide kernel would only cost time. `m = 1` counts as downscale. `upscale-high` is
    /// judged on `m` too: what a stretched preview level looks like depends on its own magnification.
    public func mode(scale: Double, level: Int) -> ResampleMode {
        if pixelArtPercent != 0, level == 0, scale >= Double(pixelArtPercent) / 100 { return .nearest }
        let m = scale * Double(1 << max(level, 0))
        if m < 0.5 { return .bilinear }
        if m > 1 {
            let high = upscaleHighPercent != 0 && m >= Double(upscaleHighPercent) / 100
            switch high ? upscaleHigh : upscale {
            case .bilinear: return .bilinear
            case .metalfx: return .metalfx
            case .ewaLanczos: return .ewaLanczos
            case .kernel(let kernel): return .kernel(kernel, upscale: true)
            }
        }
        switch downscale {
        case .bilinear: return .bilinear
        case .kernel(let kernel): return .kernel(kernel, upscale: false)
        }
    }

    /// The key whose filter draws a frame from pyramid `level` at `scale`, by the rules of `mode`; nil for the
    /// nearest-neighbour path, which no filter key affects. Below `m = 0.5` that is still `downscale`, although
    /// bilinear draws the frame.
    public func activeKey(scale: Double, level: Int) -> ResampleKey? {
        if mode(scale: scale, level: level) == .nearest { return nil }
        let m = scale * Double(1 << max(level, 0))
        if m > 1 {
            return upscaleHighPercent != 0 && m >= Double(upscaleHighPercent) / 100 ? .upscaleHigh : .upscale
        }
        return .downscale
    }
}

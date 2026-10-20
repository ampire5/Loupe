import CoreGraphics
import Darwin
import Foundation
import LoupeCore
import LoupeRender
import Metal

// LoupeBench render [--frames N] [--size WxH]… [--image WxH]… [--filter NAME]… [--orientation 1-8] [--alpha]
//                   [--table] [--lut] [--lut-mix X] [--pan-indicators] [--columns zoom]
//
// GPU time per frame of every resampling filter, through the real TileRenderer: a synthetic zone plate of 147 MP
// (14000x10502, landscape: a portrait one is too narrow to cover a 6144 px view at m = 0.51) and one of 12 MP
// (4000x3000), uploaded with their full pyramids, drawn into private bgra8Unorm_srgb targets (default 6144x3456
// and 3024x1964) at 800 %, 200 % and 125 % and at the downscale scales that give m = 0.75 / 0.66 / 0.51. One command buffer per frame, each waited for before the next:
// batched buffers overlap on the GPU and inflate the time of each 10-30 times (docs/bench/2026-10-15-m3a-resampling.md).
// Prints the median and p90 of gpuEndTime - gpuStartTime over N frames (after 5 warm-up frames) as Markdown tables.
// --image and --filter narrow a run to the images (default both) and filter rows (default all) named, for quick A/Bs.
// --orientation draws every frame with that EXIF orientation (M3b spec §2.1): the image is stored turned so that its
// oriented size is the --image size, so a run differs from orientation 1 only in how the renderer maps it.
// --alpha gives the zone plate a chirped alpha channel (0...1, premultiplied as a decoder stores it), so every frame
// takes the HAS_ALPHA pipelines over the default checkerboard (8 pt cells at backing scale 2; M3b spec §3); the upload
// line then includes the premultiplied-linear upload pass. --table tags the zone plate ROMM RGB (ProPhoto, a pure γ 1.8),
// so every frame takes the CURVE_TABLE pipelines (M3b spec §4) and the upload goes through the curve's table (the same
// pass). --lut draws every frame through a fixed colour cube (M3c spec §5: the COLOR_LUT pipelines; a contrast and
// colour-cast cube made in code, `benchCube`); --lut-mix X (0...1, implies --lut) draws it as a transition from the
// identity at that mix, two cube samples per pixel. --pan-indicators measures every cell twice on the same target, without and
// with the two position pills of M4b spec §5 at alpha 1 (`TileRenderer.encodePanIndicators`, a horizontal and a vertical one,
// their rects from a picture four times the view so both axes are pannable, the same in every column), and prints
// "frame → with pills (+cost)". --columns zoom measures 800 %, 400 %, 200 %, 125 %, 100 % and Fit
// instead of the default columns.

enum RenderBench {
    static let usage =
        "usage: LoupeBench render [--frames N] [--size WxH]… [--image WxH]… [--filter NAME]… [--orientation 1-8] "
        + "[--alpha] [--table] [--lut] [--lut-mix X] [--pan-indicators] [--columns zoom]"
    static let images = [PixelSize(width: 14000, height: 10502), PixelSize(width: 4000, height: 3000)]
    static let warmup = 5

    struct Options {
        var frames = 30
        var sizes: [PixelSize] = []
        var images: [PixelSize] = []
        var filters: [String] = []
        var orientation = ImageOrientation.up
        var alpha = false
        var table = false
        /// The cube's mix (`--lut`: 1, `--lut-mix`); nil: no cube.
        var lutMix: Float?
        /// `--pan-indicators`: every cell is the frame without and with the pills.
        var panIndicators = false
        var columns = RenderBench.columns
    }

    /// One filter row of a table: the name, and how it is set in the settings for an upscale / downscale frame.
    struct Filter {
        let name: String
        let upscale: UpscaleFilter?     // nil: not measured when magnifying
        let downscale: DownscaleFilter?
        let nearest: Bool
        /// `lanczos-antiring` for the magnifying frames.
        var antiringing = false

        static let all: [Filter] = [
            Filter(name: "lanczos3", upscale: .kernel(.lanczos3), downscale: .kernel(.lanczos3), nearest: false),
            Filter(name: "lanczos2", upscale: .kernel(.lanczos2), downscale: .kernel(.lanczos2), nearest: false),
            Filter(name: "mitchell", upscale: .kernel(.mitchell), downscale: .kernel(.mitchell), nearest: false),
            Filter(name: "catmull-rom", upscale: .kernel(.catmullRom), downscale: .kernel(.catmullRom), nearest: false),
            Filter(name: "bilinear", upscale: .bilinear, downscale: .bilinear, nearest: false),
            Filter(name: "metalfx", upscale: .metalfx, downscale: nil, nearest: false),   // magnifying only
            Filter(name: "ewa-lanczos", upscale: .ewaLanczos, downscale: nil, nearest: false),   // magnifying only
            Filter(name: "ewa-lanczos+antiring", upscale: .ewaLanczos, downscale: nil, nearest: false, antiringing: true),
            Filter(name: "nearest (800 % only)", upscale: nil, downscale: nil, nearest: true),
        ]
    }

    /// A column of a table: the scale and what it is (upscale columns run on every image, downscale ones are
    /// chosen on the 147 MP image, which covers the view at all of them).
    struct Column {
        let title: String
        let scale: Double
        let magnify: Bool
        /// Fit instead of `scale` (which then is 0); whether it magnifies depends on the image and view.
        var fit = false
    }

    static let columns = [
        Column(title: "800 %", scale: 8, magnify: true),
        Column(title: "200 %", scale: 2, magnify: true),
        Column(title: "125 %", scale: 1.25, magnify: true),
        Column(title: "m 0.75", scale: 0.75, magnify: false),
        Column(title: "m 0.66", scale: 0.66, magnify: false),
        Column(title: "m 0.51", scale: 0.51, magnify: false),
    ]

    /// `--columns zoom`: the zoom levels of the M3b rows (docs/bench/2026-10-15-m3b-render.md).
    static let zoomColumns = [
        Column(title: "800 %", scale: 8, magnify: true),
        Column(title: "400 %", scale: 4, magnify: true),
        Column(title: "200 %", scale: 2, magnify: true),
        Column(title: "125 %", scale: 1.25, magnify: true),
        Column(title: "100 %", scale: 1, magnify: false),
        Column(title: "Fit", scale: 0, magnify: false, fit: true),
    ]

    static func main(_ arguments: [String]) -> Never {
        let options = parse(arguments)
        Task {
            await run(options)
            exit(0)
        }
        dispatchMain()
    }

    private static func parse(_ arguments: [String]) -> Options {
        var o = Options()
        var args = arguments[...]
        while let arg = args.popFirst() {
            switch arg {
            case "--frames":
                guard let v = args.popFirst(), let n = Int(v), n >= 1 else { fail("--frames needs a positive integer") }
                o.frames = n
            case "--size", "--image":
                guard let v = args.popFirst() else { fail("\(arg) needs WxH") }
                let parts = v.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { fail("\(arg) needs WxH, e.g. 6144x3456") }
                let size = PixelSize(width: parts[0], height: parts[1])
                if arg == "--size" { o.sizes.append(size) } else { o.images.append(size) }
            case "--filter":
                guard let v = args.popFirst(), Filter.all.contains(where: { $0.name.hasPrefix(v) }) else {
                    fail("--filter needs one of " + Filter.all.map(\.name).joined(separator: ", "))
                }
                o.filters.append(v)
            case "--orientation":
                guard let v = args.popFirst(), let n = Int(v), let orientation = ImageOrientation(rawValue: n) else {
                    fail("--orientation needs an EXIF orientation, 1 to 8")
                }
                o.orientation = orientation
            case "--alpha":
                o.alpha = true
            case "--table":
                o.table = true
            case "--lut":
                o.lutMix = o.lutMix ?? 1
            case "--lut-mix":
                guard let v = args.popFirst(), let mix = Float(v), (0...1).contains(mix) else {
                    fail("--lut-mix needs a number from 0 to 1")
                }
                o.lutMix = mix
            case "--pan-indicators":
                o.panIndicators = true
            case "--columns":
                guard args.popFirst() == "zoom" else { fail("--columns needs zoom") }
                o.columns = zoomColumns
            default: fail("unknown option \(arg)\n\(usage)")
            }
        }
        if o.sizes.isEmpty { o.sizes = [PixelSize(width: 6144, height: 3456), PixelSize(width: 3024, height: 1964)] }
        if o.images.isEmpty { o.images = images }
        return o
    }

    private static func run(_ o: Options) async {
        print("# LoupeBench render: \(machine()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("frames: \(o.frames) after \(warmup) warm-up; cells are median / p90 of GPU ms; "
              + "orientation \(o.orientation.rawValue)\(o.alpha ? ", alpha over the checkerboard" : "")"
              + "\(o.table ? ", ProPhoto (table curve)" : "")"
              + "\(o.lutMix.map { $0 < 1 ? ", colour cube from the identity at mix \($0)" : ", colour cube" } ?? "")"
              + "\(o.panIndicators ? ", cells: frame → with two pan indicator pills (+cost)" : "")\n")
        // The cube is uploaded once, as the app does per photo.
        let color = o.lutMix.map { mix -> ColorFrame in
            guard let lut = ColorLUT.make(benchCube()) else { fail("cannot make the colour cube's texture") }
            return ColorFrame(lut: lut, from: mix < 1 ? ColorLUT.identity() : nil, mix: mix)
        }
        let filters = o.filters.isEmpty ? Filter.all : Filter.all.filter { f in o.filters.contains { f.name.hasPrefix($0) } }
        for imageSize in o.images {
            let start = DispatchTime.now().uptimeNanoseconds
            let decoded: DecodedImage
            let tiled: TiledImage
            var uploadGPU = 0.0
            do {
                // orientedSize is its own inverse on sizes: the stored size whose oriented size is imageSize.
                decoded = try zonePlate(o.orientation.orientedSize(imageSize), alpha: o.alpha,
                                        colorSpace: CGColorSpace(name: o.table ? CGColorSpace.rommrgb : CGColorSpace.sRGB)!)
                tiled = TiledImage.empty(grid: TileGrid(imageSize: decoded.pixelSize), colorSpace: decoded.colorSpace)
                // With the app's default pyramid filter, so the upload line is what opening the photo costs.
                uploadGPU = try await tiled.upload(LevelImage(image: decoded, level: 0), filter: Config().pyramidFilter) ?? 0
                if tiled.hasAlpha != o.alpha { fail("the test image's hasAlpha is \(tiled.hasAlpha)") }
            } catch {
                fail("cannot build the \(imageSize.width)x\(imageSize.height) test image: \(error)")
            }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            print("## image \(imageSize.width)x\(imageSize.height) (\(String(format: "%.1f", Double(imageSize.width * imageSize.height) / 1e6)) MP, "
                  + "\(tiled.grid.levelCount) levels, \(tiled.byteCount >> 20) MiB on the GPU, built in \(String(format: "%.1f", seconds)) s, "
                  + "upload \(String(format: "%.1f", uploadGPU * 1000)) ms of GPU with the \(Config().pyramidFilter.rawValue) "
                  + "pyramid)\n")
            // The upload's scan for alpha < 255 (TiledImage.hasAlpha): an opaque image is its worst case, every pixel.
            let scans = (0..<5).map { _ in
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = decoded.hasTransparentPixel()
                return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            }
            print("alpha scan of the decoded buffer: median \(String(format: "%.1f", median(scans))) ms of 5\n")
            for size in o.sizes {
                table(image: tiled, orientation: o.orientation, output: size, filters: filters, columns: o.columns,
                      frames: o.frames, color: color, panIndicators: o.panIndicators)
            }
        }
    }

    private static func table(image: TiledImage, orientation: ImageOrientation, output: PixelSize, filters: [Filter],
                              columns: [Column], frames: Int, color: ColorFrame?, panIndicators: Bool) {
        let renderer = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
        renderer.backingScale = 2   // the checkerboard of an --alpha image: 16 px cells, as on a Retina screen
        renderer.color = color
        let target = makeTarget(output, readable: panIndicators)
        let oriented = orientation.orientedSize(image.grid.imageSize)
        let imageSize = CGSize(width: oriented.width, height: oriented.height)
        let view = CGSize(width: output.width, height: output.height)
        // Fit becomes its scale for this image and view; whether it magnifies follows from it.
        let fitScale = ViewTransform(imageSize: imageSize, viewSize: view, mode: .fit).scale
        let resolved = columns.map { c in
            c.fit ? Column(title: c.title, scale: fitScale, magnify: fitScale > 1, fit: true) : c
        }
        // Downscale columns are only meaningful when the image covers the view at that scale (Fit always fits).
        // The pills' rects: a picture four times the view at 100 % is pannable on both axes, so the real geometry gives
        // both pills (they sit at the same place in every column; their cost does not depend on the frame under them).
        let pills = PanIndicators.pills(
            for: ViewTransform(imageSize: CGSize(width: view.width * 4, height: view.height * 4), viewSize: view,
                               mode: .actual(1)),
            backingScale: 2, bottomInsetPoints: 0)
        if panIndicators && pills.count != 2 { fail("expected two pills, got \(pills.count)") }
        let usable = resolved.filter { $0.magnify || $0.fit || coversView(imageSize, view, scale: $0.scale) }

        print("### output \(output.width)x\(output.height)\n")
        // A star marks an upscale column whose image does not fill the view (the rest is cheap background).
        let partial = usable.contains { !$0.fit && !coversView(imageSize, view, scale: $0.scale) }
        let titles = usable.map { $0.fit || coversView(imageSize, view, scale: $0.scale) ? $0.title : $0.title + " *" }
        print("| filter | " + titles.joined(separator: " | ") + " |")
        print("|---|" + usable.map { _ in "---|" }.joined())
        var levels: [String] = []
        for filter in filters {
            var cells: [String] = []
            for column in usable {
                var settings = ResampleSettings()
                if filter.nearest {
                    guard column.scale == 8 else { cells.append("—"); continue }
                    // defaults: pixel-art = 400, so 800 % is nearest
                } else if column.magnify {
                    guard let up = filter.upscale else { cells.append("—"); continue }
                    settings = ResampleSettings(upscale: up, upscaleHighPercent: 0, antiringing: filter.antiringing,
                                                pixelArtPercent: 0)
                } else {
                    guard let down = filter.downscale else { cells.append("—"); continue }
                    settings = ResampleSettings(downscale: down, antiringing: false, pixelArtPercent: 0)
                }
                renderer.resample = settings
                let transform = ViewTransform(imageSize: imageSize, viewSize: view,
                                              mode: column.fit ? .fit : .actual(column.scale))
                let level = image.grid.drawnLevel(forScale: transform.scale, finestResident: 0)
                let m = transform.scale * Double(1 << level)
                let mode = settings.mode(scale: transform.scale, level: level)
                if !modeMatches(mode, filter: filter, magnify: column.magnify) {
                    fail("\(filter.name) at \(column.title) would draw \(mode), not the filter under test")
                }
                if filter.name == filters[0].name { levels.append("\(column.title): level \(level), m \(String(format: "%.2f", m))") }
                let times = measure(renderer, image, transform, orientation, target, frames: frames)
                if renderer.lastColorLUT != (color != nil) { fail("\(filter.name) at \(column.title): the cube was not drawn") }
                if panIndicators {
                    let withPills = measure(renderer, image, transform, orientation, target, frames: frames, pills: pills)
                    let base = median(times), cost = median(withPills) - base
                    cells.append(String(format: "%.2f → %.2f (%+.2f)", base, median(withPills), cost))
                } else {
                    cells.append(String(format: "%.2f / %.2f", median(times), percentile(times, 0.9)))
                }
            }
            print("| \(filter.name) | " + cells.joined(separator: " | ") + " |")
        }
        print("\nlevel and m per column: " + levels.joined(separator: "; "))
        if partial { print("\n\\* the image does not fill the view at this scale") }
        print()
    }

    /// The row must really run the filter it is named for.
    private static func modeMatches(_ mode: ResampleMode, filter: Filter, magnify: Bool) -> Bool {
        switch mode {
        case .nearest: return filter.nearest
        case .bilinear: return filter.name == "bilinear"
        case .metalfx: return magnify && filter.name == "metalfx"
        case .ewaLanczos: return magnify && filter.name.hasPrefix("ewa-lanczos")
        case .kernel(let kernel, let upscale):
            return upscale == magnify && !filter.nearest && filter.name == kernel.rawValue
        }
    }

    /// Whether the image at `scale` is at least as large as the view on both axes.
    private static func coversView(_ image: CGSize, _ view: CGSize, scale: Double) -> Bool {
        image.width * scale >= view.width && image.height * scale >= view.height
    }

    /// GPU milliseconds of each of `frames` frames after the warm-up, one command buffer at a time.
    private static func measure(_ renderer: TileRenderer, _ image: TiledImage, _ transform: ViewTransform,
                                _ orientation: ImageOrientation, _ target: MTLTexture, frames: Int,
                                pills: [PanIndicatorPill] = []) -> [Double] {
        let queue = MetalContext.shared.queue
        var times: [Double] = []
        for i in 0..<(warmup + frames) {
            guard let commands = queue.makeCommandBuffer() else { fail("no command buffer") }
            renderer.encode(image: image, transform: transform, orientation: orientation, into: commands,
                            target: target)
            renderer.encodePanIndicators(pills, alpha: 1, backingScale: 2, into: commands, target: target)
            commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error { fail("GPU error: \(error)") }
            if i >= warmup { times.append((commands.gpuEndTime - commands.gpuStartTime) * 1000) }
        }
        return times
    }

    /// `readable`: the pills' kernel reads the frame it blends over (the app's drawable allows it too).
    private static func makeTarget(_ size: PixelSize, readable: Bool = false) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: size.width,
                                                         height: size.height, mipmapped: false)
        d.storageMode = .private
        d.usage = readable ? [.renderTarget, .shaderRead, .shaderWrite] : [.renderTarget, .shaderWrite]
        guard let texture = MetalContext.shared.device.makeTexture(descriptor: d) else { fail("cannot make a \(size.width)x\(size.height) target") }
        return texture
    }

    /// The chirped zone plate of the earlier stand (docs/bench/raw/2026-10-15-m3a-resampling): every spatial
    /// frequency up to Nyquist appears, so no filter is measured on an easy (flat) image. Written as sRGB bytes.
    /// `alpha`: with a chirped alpha channel too (from fully transparent to opaque), premultiplied. `colorSpace`: what the
    /// bytes are tagged with (their values stay the same).
    static func zonePlate(_ size: PixelSize, alpha: Bool = false,
                          colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> DecodedImage {
        let bytesPerRow = (size.width * 4 + 63) / 64 * 64
        let buffer = try PageAlignedBuffer(minimumLength: bytesPerRow * size.height)
        let base = buffer.bytes.assumingMemoryBound(to: UInt8.self)
        let period: Float = 2048
        DispatchQueue.concurrentPerform(iterations: size.height) { y in
            let qy = Float(y).truncatingRemainder(dividingBy: period) - period / 2
            let row = base + y * bytesPerRow
            for x in 0..<size.width {
                let qx = Float(x).truncatingRemainder(dividingBy: period) - period / 2
                let v = 0.5 + 0.5 * cos(Float.pi * (qx * qx + qy * qy) / period)
                let r = srgbByte(v), g = srgbByte(v * 0.8 + 0.1), b = srgbByte(1 - v)
                let o = x * 4
                if alpha {
                    let a = 0.5 + 0.5 * cos(Float.pi * qx * qy / period)
                    func premultiplied(_ c: UInt8) -> UInt8 { UInt8((Float(c) * a).rounded()) }
                    row[o] = premultiplied(b); row[o + 1] = premultiplied(g); row[o + 2] = premultiplied(r)
                    row[o + 3] = UInt8((a * 255).rounded())
                } else {
                    row[o] = b; row[o + 1] = g; row[o + 2] = r; row[o + 3] = 255
                }
            }
        }
        return DecodedImage(pixelSize: size, bytesPerRow: bytesPerRow, buffer: buffer, colorSpace: colorSpace,
                            hasAlphaChannel: alpha)
    }

    /// `--lut`'s cube: more contrast (×1.2 about the middle of the encoded values) and a warm cast (red +0.03, blue
    /// −0.03), clamped to 0...1. Any non-identity cube costs the same per frame; this one keeps the picture recognisable.
    static func benchCube() -> ColorCube {
        let n = ColorCube.dimension, last = Float(n - 1)
        var values = [Float16](repeating: 1, count: n * n * n * 4)
        func contrast(_ e: Float, _ shift: Float) -> Float16 { Float16(min(max(0.5 + 1.2 * (e - 0.5) + shift, 0), 1)) }
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let i = ((b * n + g) * n + r) * 4
                    values[i] = contrast(Float(r) / last, 0.03)
                    values[i + 1] = contrast(Float(g) / last, 0)
                    values[i + 2] = contrast(Float(b) / last, -0.03)
                }
            }
        }
        return ColorCube(values: values)
    }

    private static func srgbByte(_ linear: Float) -> UInt8 {
        let c = min(max(linear, 0), 1)
        let e = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8((e * 255).rounded())
    }

    static func median(_ values: [Double]) -> Double { percentile(values, 0.5) }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    static func machine() -> String {
        func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
            var bytes = [CChar](repeating: 0, count: size)
            sysctlbyname(name, &bytes, &size, nil, 0)
            return String(cString: bytes)
        }
        return "\(sysctl("machdep.cpu.brand_string")) (\(sysctl("hw.model")))"
    }
}

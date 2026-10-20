import CoreGraphics
import Foundation
import ImageIO
import LoupeCore
import LoupeRender
import Metal
import UniformTypeIdentifiers

// LoupeBench crops --out DIR [--scale S] [--size WxH] FILE@X,Y…
//
// Side-by-side crops of real photos as the renderer draws them, for judging upscale filters by eye: each FILE is
// decoded by the app's own decoders (DecoderRegistry, so colour handling matches), uploaded as a TiledImage and drawn
// at S (default 4.5) centred on image px (X, Y) into a WxH (default 480x320) bgra8Unorm_srgb target by every filter
// below, through the real TileRenderer. Writes DIR/<file>-<X>x<Y>-<filter>.png, tagged with the image's colour space,
// and DIR/index.html, which shows each row of crops at one PNG px per device px (no browser rescaling).

enum CropsBench {
    static let usage = "usage: LoupeBench crops --out DIR [--scale S] [--size WxH] FILE@X,Y…"

    /// The panels of a row: name and settings. `upscale-high` and pixel-art are off so each panel is its filter; the
    /// first panel is the source pixels (nearest) for reference.
    static let panels: [(name: String, settings: ResampleSettings)] = [
        ("nearest (source px)", ResampleSettings(upscaleHighPercent: 0, pixelArtPercent: 100)),
        ("lanczos3", up(.kernel(.lanczos3))),
        ("lanczos3+antiring", up(.kernel(.lanczos3), antiringing: true)),
        ("mitchell", up(.kernel(.mitchell))),
        ("catmull-rom", up(.kernel(.catmullRom))),
        ("ewa-lanczos", up(.ewaLanczos)),
        ("ewa-lanczos+antiring", up(.ewaLanczos, antiringing: true)),
    ]

    private static func up(_ filter: UpscaleFilter, antiringing: Bool = false) -> ResampleSettings {
        ResampleSettings(upscale: filter, upscaleHighPercent: 0, antiringing: antiringing, pixelArtPercent: 0)
    }

    struct Crop {
        let path: String
        let x: Double, y: Double
    }

    static func main(_ arguments: [String]) -> Never {
        var out: String?
        var scale = 4.5
        var size = PixelSize(width: 480, height: 320)
        var crops: [Crop] = []
        var args = arguments[...]
        while let arg = args.popFirst() {
            switch arg {
            case "--out":
                guard let v = args.popFirst() else { fail("--out needs a directory") }
                out = v
            case "--scale":
                guard let v = args.popFirst(), let s = Double(v), s > 1, s <= 64 else { fail("--scale needs 1 < S <= 64") }
                scale = s
            case "--size":
                let parts = (args.popFirst() ?? "").lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { fail("--size needs WxH") }
                size = PixelSize(width: parts[0], height: parts[1])
            default:
                let pieces = arg.split(separator: "@")
                let xy = pieces.count == 2 ? pieces[1].split(separator: ",").compactMap { Double($0) } : []
                guard xy.count == 2 else { fail("expected FILE@X,Y, got \(arg)\n\(usage)") }
                crops.append(Crop(path: String(pieces[0]), x: xy[0], y: xy[1]))
            }
        }
        guard let out, !crops.isEmpty else { fail(usage) }
        let outDir = URL(fileURLWithPath: out)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            fail("cannot create \(out): \(error)")
        }
        Task {
            await run(crops, outDir: outDir, scale: scale, size: size)
            exit(0)
        }
        dispatchMain()
    }

    private static func run(_ crops: [Crop], outDir: URL, scale: Double, size: PixelSize) async {
        var rows: [(title: String, files: [String])] = []
        for crop in crops {
            let url = URL(fileURLWithPath: crop.path)
            let decoded: DecodedImage
            let tiled: TiledImage
            do {
                let data = try Data(contentsOf: url)
                let decoder = DecoderRegistry.decoder(for: data)
                decoded = try decoder.decodeFull(data, info: try decoder.probe(data))
                tiled = try await TiledImage.make(from: decoded)
            } catch {
                fail("cannot decode \(crop.path): \(error)")
            }
            let imageSize = CGSize(width: decoded.pixelSize.width, height: decoded.pixelSize.height)
            let transform = ViewTransform(imageSize: imageSize, viewSize: CGSize(width: size.width, height: size.height),
                                          mode: .actual(scale),
                                          center: CGPoint(x: crop.x / imageSize.width, y: crop.y / imageSize.height))
            let stem = url.deletingPathExtension().lastPathComponent + "-\(Int(crop.x))x\(Int(crop.y))"
            var files: [String] = []
            for panel in panels {
                let renderer = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
                renderer.resample = panel.settings
                let bytes = render(tiled, transform, renderer: renderer, size: size)
                let name = "\(stem)-\(panel.name.replacingOccurrences(of: " ", with: "_").filter { $0.isLetter || $0.isNumber || "-+_".contains($0) }).png"
                writePNG(bytes, size: size, colorSpace: decoded.colorSpace, to: outDir.appendingPathComponent(name))
                files.append(name)
                print(name)
            }
            rows.append(("\(url.lastPathComponent) (\(decoded.pixelSize.width)×\(decoded.pixelSize.height), "
                         + "\(decoded.colorSpace.name.map { $0 as String } ?? "?")), centre (\(Int(crop.x)), \(Int(crop.y))), "
                         + String(format: "×%.2f", scale), files))
        }
        writeIndex(rows, scale: scale, size: size, to: outDir.appendingPathComponent("index.html"))
    }

    /// One frame through the real renderer, read back as BGRA bytes (row-major, tightly packed).
    private static func render(_ image: TiledImage, _ transform: ViewTransform, renderer: TileRenderer,
                               size: PixelSize) -> [UInt8] {
        let device = MetalContext.shared.device
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: size.width,
                                                         height: size.height, mipmapped: false)
        d.storageMode = .shared
        d.usage = [.renderTarget, .shaderWrite]
        guard let target = device.makeTexture(descriptor: d),
              let commands = MetalContext.shared.queue.makeCommandBuffer() else { fail("cannot make a render target") }
        renderer.encode(image: image, transform: transform, into: commands, target: target)
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { fail("GPU error: \(error)") }
        var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
        target.getBytes(&bytes, bytesPerRow: size.width * 4, from: MTLRegionMake2D(0, 0, size.width, size.height),
                        mipmapLevel: 0)
        return bytes
    }

    private static func writePNG(_ bytes: [UInt8], size: PixelSize, colorSpace: CGColorSpace, to url: URL) {
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: size.width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { fail("cannot write \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
    }

    private static func writeIndex(_ rows: [(title: String, files: [String])], scale: Double, size: PixelSize, to url: URL) {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        var body = ""
        for row in rows {
            body += "<section><h2>\(escape(row.title))</h2><div class=\"row\">\n"
            for (file, panel) in zip(row.files, panels) {
                body += "<figure><img src=\"\(file)\" width=\"\(size.width)\" height=\"\(size.height)\" alt=\"\">"
                    + "<figcaption>\(escape(panel.name))</figcaption></figure>\n"
            }
            body += "</div></section>\n"
        }
        let html = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Upscale Filter Crops</title>
        <style>
        :root { --bg: #f4f4f2; --fg: #1d1d1b; --muted: #6b6b66; }
        @media (prefers-color-scheme: dark) { :root { --bg: #161615; --fg: #e8e8e4; --muted: #9a9a94; } }
        body { margin: 0; padding: 16px; background: var(--bg); color: var(--fg);
               font: 14px/1.4 -apple-system, system-ui, sans-serif; }
        h1 { font-size: 18px; margin: 0 0 4px; } p { color: var(--muted); margin: 0 0 16px; max-width: 70ch; }
        h2 { font-size: 14px; font-weight: 600; margin: 24px 0 8px; }
        .row { display: flex; flex-wrap: wrap; gap: 12px; }
        figure { margin: 0; } figcaption { font-size: 13px; margin-top: 4px; font-variant-numeric: tabular-nums; }
        img { display: block; }
        </style></head><body>
        <h1>Upscale filters at \(String(format: "×%.2f", scale))</h1>
        <p>Rendered by Loupe's own TileRenderer (LoupeBench crops), \(size.width)×\(size.height) px each, in linear light.
        Every crop is shown at one PNG pixel per screen pixel, as Loupe draws in physical pixels: no browser scaling.
        The first panel is the source pixels (nearest) for reference.</p>
        \(body)
        <script>
        // One PNG px per device px: on a Retina screen the browser would otherwise upscale each crop 2x and blur it.
        const r = window.devicePixelRatio || 1;
        for (const img of document.querySelectorAll('img')) {
          img.style.width = (img.width / r) + 'px';
          img.style.height = (img.height / r) + 'px';
        }
        </script>
        </body></html>
        """
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fail("cannot write \(url.path): \(error)")
        }
    }
}

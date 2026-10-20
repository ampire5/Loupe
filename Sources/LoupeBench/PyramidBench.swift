import Foundation
import LoupeCore
import LoupeRender

// LoupeBench pyramid [--runs N] [--image WxH]…
//
// GPU time to build a full pyramid, pyramid-filter box against lanczos3 (M3a spec §4): a synthetic zone plate
// (default 10502x14000, 147 MP, the size the spec's rule is stated for) uploaded at level 0 into a fresh TiledImage,
// the way the cache uploads a decoded photo. The time is the upload command buffer's gpuEndTime - gpuStartTime, read
// in its completed handler on the upload queue: the level 0 blits plus every downsample dispatch. The blits are the
// same for both filters, so the difference of the medians is what the filter costs. Runs alternate box / lanczos3
// (after one warm-up of each), so a drift in GPU clocks or background load hits both alike. Prints the median, p90
// and min of N runs per filter and the median difference.

enum PyramidBench {
    static let usage = "usage: LoupeBench pyramid [--runs N] [--image WxH]…"
    static let filters: [PyramidFilter] = [.box, .lanczos3]

    static func main(_ arguments: [String]) -> Never {
        var runs = 10
        var images: [PixelSize] = []
        var args = arguments[...]
        while let arg = args.popFirst() {
            switch arg {
            case "--runs":
                guard let v = args.popFirst(), let n = Int(v), n >= 1 else { fail("--runs needs a positive integer") }
                runs = n
            case "--image":
                let parts = (args.popFirst() ?? "").lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { fail("--image needs WxH, e.g. 10502x14000") }
                images.append(PixelSize(width: parts[0], height: parts[1]))
            default: fail("unknown option \(arg)\n\(usage)")
            }
        }
        if images.isEmpty { images = [PixelSize(width: 10502, height: 14000)] }
        Task {
            await run(images: images, runs: runs)
            exit(0)
        }
        dispatchMain()
    }

    private static func run(images: [PixelSize], runs: Int) async {
        print("# LoupeBench pyramid: \(RenderBench.machine()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("runs: \(runs) per filter after 1 warm-up, alternating; GPU ms of the upload command buffer (blits + pyramid)\n")
        for size in images {
            let image: DecodedImage
            do {
                image = try RenderBench.zonePlate(size)
            } catch {
                fail("cannot make the \(size.width)x\(size.height) test image: \(error)")
            }
            let grid = TileGrid(imageSize: size)
            var times: [PyramidFilter: [Double]] = [:]
            for i in 0...runs {
                for filter in filters {
                    let ms = await upload(image, grid: grid, filter: filter)
                    if i > 0 { times[filter, default: []].append(ms) }
                }
            }
            print("## image \(size.width)x\(size.height) (\(String(format: "%.1f", Double(size.width * size.height) / 1e6)) MP, \(grid.levelCount) levels)\n")
            print("| pyramid-filter | median | p90 | min |")
            print("|---|---|---|---|")
            for filter in filters {
                let t = times[filter] ?? []
                print(String(format: "| \(filter.rawValue) | %.1f | %.1f | %.1f |",
                             RenderBench.median(t), RenderBench.percentile(t, 0.9), t.min() ?? 0))
            }
            let box = times[.box] ?? [], lanczos = times[.lanczos3] ?? []
            print(String(format: "\nlanczos3 - box: %+.1f ms (medians); per run: ", RenderBench.median(lanczos) - RenderBench.median(box))
                  + zip(lanczos, box).map { String(format: "%+.1f", $0 - $1) }.joined(separator: " ") + "\n")
        }
    }

    /// Milliseconds of GPU time to upload `image` and build its pyramid with `filter`, into a fresh image (an upload
    /// to an image whose level 0 is resident would be skipped).
    private static func upload(_ image: DecodedImage, grid: TileGrid, filter: PyramidFilter) async -> Double {
        let tiled = TiledImage.empty(grid: grid, colorSpace: image.colorSpace)
        do {
            guard let seconds = try await tiled.upload(LevelImage(image: image, level: 0), filter: filter) else {
                fail("the upload was skipped")
            }
            return seconds * 1000
        } catch {
            fail("upload failed: \(error)")
        }
    }
}

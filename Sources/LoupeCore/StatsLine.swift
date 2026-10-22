import Foundation
import UniformTypeIdentifiers

/// The text of the compact stats bar (spec §10), as a pure function so what the bar says is tested
/// without AppKit.
public enum StatsLine {
    /// `name   N / M   W×H   size MB   FORMAT[ progressive]   Mode NN %   decode NNNN ms`.
    /// `decodeMs` is nil while unknown. Sizes are decimal megabytes (1 MB = 1 000 000 bytes). W×H is the size as
    /// shown: oriented (M3b spec §2.1), stored when `applyingOrientation` is off (`exif-orientation=no`). `counted`
    /// false: the folder is still being listed, so M is `…` rather than the interim playlist's count. `companion`
    /// (the second page's index, spread) makes the position a range: `12–13 / 380`.
    public static func loaded(name: String, index: Int, companion: Int? = nil, count: Int, counted: Bool = true, info: ImageInfo,
                              applyingOrientation: Bool = true, transform: ViewTransform, decodeMs: Double?) -> String {
        let size = info.displaySize(applying: applyingOrientation)
        var parts = [
            name,
            position(index: index, companion: companion, count: count, counted: counted),
            "\(size.width)×\(size.height)",
            String(format: "%.1f MB", Double(info.fileSize) / 1_000_000),
            formatName(info.typeIdentifier) + (info.isProgressive ? " progressive" : ""),
            modeText(transform),
        ]
        if let decodeMs { parts.append("decode \(Int(decodeMs.rounded())) ms") }
        return parts.joined(separator: "   ")
    }

    /// `Loading name…   N / M`; the position is left out when the playlist is not known.
    public static func loading(name: String, position: (index: Int, count: Int)? = nil, companion: Int? = nil,
                               counted: Bool = true) -> String {
        guard let position else { return "Loading \(name)…" }
        return "Loading \(name)…   " + Self.position(index: position.index, companion: companion, count: position.count,
                                                                  counted: counted)
    }

    private static func position(index: Int, companion: Int? = nil, count: Int, counted: Bool) -> String {
        (companion.map { "\(index + 1)–\($0 + 1)" } ?? "\(index + 1)") + " / " + (counted ? "\(count)" : "…")
    }

    /// How much of the stats bar's width its progress fill covers (`stats-progress`): the folder position
    /// `(index + 1) / count`, so the last photo fills the bar; clamped to 0...1, 0 for an empty folder.
    public static func progress(index: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return min(max(Double(index + 1) / Double(count), 0), 1)
    }

    /// The name the bar shows for the open `folder` (`stats-folder-name`): its last path component, or the
    /// volume's name when the caller knows one for a volume's root ("/" would say nothing).
    public static func folderName(of folder: URL, volumeName: String?) -> String {
        if let volumeName, !volumeName.isEmpty { return volumeName }
        return folder.lastPathComponent
    }

    /// The width the centred folder name gets in a bar `barWidth` wide whose stats text ends at `textEnd`: as much
    /// of `nameWidth` as fits symmetrically about the middle while staying `gap` clear of the text and `inset` inside
    /// the bar's edges (the name truncates in the middle to it); nil when that is under `minimum`, or under the name's
    /// own width for a shorter name (no room: hidden).
    public static func folderNameWidth(barWidth: Double, textEnd: Double, nameWidth: Double, gap: Double,
                                       inset: Double, minimum: Double) -> Double? {
        let half = min(barWidth / 2 - textEnd - gap, barWidth / 2 - inset)
        let width = min(nameWidth, 2 * half)
        // A name shorter than `minimum` needs only its own width ("AI" must not count as "no room").
        return nameWidth > 0 && width >= min(minimum, nameWidth) ? width : nil
    }

    /// The Diagnostics rows of the info panel (the old second line of the extended bar): `Decoder` (`libjpeg-turbo`),
    /// `Colour space` (`Display P3`), `Load` (`read 98 · preview 112 · full 171 · upload 40 ms`), `Cache` (`full`),
    /// `Cache use` (`20 previews · 2 full · 2.7 / 3.0 GB`, then ` · other windows −3 (412 MB)` once eviction took from
    /// inactive windows), `Memory` (`RAM 3.4 GB · GPU 2.8 GB`), `Frame` (`GPU 1.2/1.9 ms · 0 dropped`, `–` before
    /// there are frame times).
    /// `Load` is "cached" when the photo was shown from the cache (its timings are from an earlier visit). The cache
    /// state is `thumb` while only the seeded thumbnail is resident (`isSeededOnly`, M2.5 spec §5.2), whatever goal that
    /// level counts for, and `–` when unknown. Rows whose input is unknown are left out. Memory is in GB of 2^30 bytes
    /// (so a `cache-memory` of 3G reads 3.0); under memory pressure the cache figure is the reduced limit, marked
    /// "(pressure)". `frames` is the GPU time median / 90th percentile and the dropped frames of the last 240 presented
    /// ones. The filter and the colour line belong to the panel's Display section, not here.
    public static func diagnostics(colorSpace: String?, decoder: String?, timings: LoadTimings, fromCache: Bool,
                                   state: CacheGoal?, isSeededOnly: Bool = false, cache: CacheStats, ramBytes: Int,
                                   gpuBytes: Int, frames: FrameStats) -> [InfoRow] {
        var rows: [InfoRow] = []
        if let decoder { rows.append(InfoRow(label: "Decoder", value: decoder)) }
        if let colorSpace { rows.append(InfoRow(label: "Colour space", value: colorSpace)) }
        if fromCache {
            rows.append(InfoRow(label: "Load", value: "cached"))
        } else {
            let stages: [(String, Double?)] = [("read", timings.readMs), ("preview", timings.previewMs),
                                               ("full", timings.fullMs), ("upload", timings.uploadMs)]
            let known = stages.compactMap { label, ms in ms.map { "\(label) \(Int($0.rounded()))" } }
            if !known.isEmpty { rows.append(InfoRow(label: "Load", value: known.joined(separator: " · ") + " ms")) }
        }
        rows.append(InfoRow(label: "Cache", value: isSeededOnly ? "thumb" : state.map(stateName) ?? "–"))
        let pressure = cache.effectiveLimitBytes != cache.limitBytes
        rows.append(InfoRow(label: "Cache use", value: "\(cache.previewCount) previews · \(cache.fullCount) full · "
                            + "\(gigabytes(cache.usedBytes)) / \(gigabytes(cache.effectiveLimitBytes)) GB"
                            + (pressure ? " (pressure)" : "") + otherWindows(cache.evictedInactive)))
        rows.append(InfoRow(label: "Memory", value: "RAM \(gigabytes(ramBytes)) GB · GPU \(gigabytes(gpuBytes)) GB"))
        if let p50 = frames.gpuP50, let p90 = frames.gpuP90 {
            rows.append(InfoRow(label: "Frame", value: String(format: "GPU %.1f/%.1f ms · %d dropped", p50, p90, frames.dropped)))
        } else {
            rows.append(InfoRow(label: "Frame", value: "–"))
        }
        return rows
    }

    /// The scaling regime and resampler of the frame being shown, for the panel's Display section:
    /// `downscale lanczos3 ×0.87 L1`, `upscale metalfx ×2.00`, `strong upscale mitchell ×4.50`, `pixel-art nearest ×8.00`.
    /// `regime` is the loupe.conf key behind the frame (`ResampleSettings.activeKey`; nil is the pixel-art path), so the
    /// line names the setting that chose the filter; `mode` is the path as drawn, a fallback (`metalfx` without
    /// MetalFX) showing under its own name. `m` is the magnification of the level actually drawn (`scale * 2^level`),
    /// the number that picked the path; ` L<n>` names the pyramid `level` when it is not 0. `fromFolder` appends
    /// ` · folder` when the window's filters come from a folder's record (folder settings spec §7).
    public static func filterName(regime: ResampleKey?, mode: ResampleMode, level: Int, m: Double,
                                  fromFolder: Bool = false) -> String {
        let regimeName = switch regime {
        case .downscale: "downscale"
        case .upscale: "upscale"
        case .upscaleHigh: "strong upscale"
        case nil: "pixel-art"
        }
        return regimeName + " " + resamplerName(mode) + String(format: " ×%.2f", m)
            + (level > 0 ? " L\(level)" : "") + (fromFolder ? " · folder" : "")
    }

    /// The Display section's colour row (M3c spec §2.3), for the photo on screen: `Colour: off`,
    /// `Colour: auto apple 0.42 · Δ 8.5` (method, share of the strength after the ramp, Δ), `Colour: auto · Δ 4.1, needs
    /// none`, `Colour: auto · Δ 8.5, nothing to apply`, `Colour: auto, too dark`, `Colour: auto, analysing`,
    /// `Colour: auto, no thumbnail`. `vibrance` is the window's amount while `vibrance=yes`
    /// (` · vibrance 0.5`); `fromFolder` appends ` · folder` when a colour value of the window comes from a folder.
    public static func colour(_ status: ColorStatus, vibrance: Double?, fromFolder: Bool) -> String {
        var text = switch status {
        case .off: "Colour: off"
        case .analysing: "Colour: auto, analysing"
        case .tooDark: "Colour: auto, too dark"
        case .needsNone(let delta): "Colour: auto · Δ \(String(format: "%.1f", delta)), needs none"
        case .nothingToApply(let delta): "Colour: auto · Δ \(String(format: "%.1f", delta)), nothing to apply"
        case .noThumbnail: "Colour: auto, no thumbnail"
        case .applied(let method, let share, let delta):
            "Colour: auto \(method.rawValue) \(shortNumber(share)) · Δ \(String(format: "%.1f", delta))"
        }
        if let vibrance { text += " · vibrance " + shortNumber(vibrance) }
        if fromFolder { text += " · folder" }
        return text
    }

    /// Two decimals at most, without trailing zeros: `0.42`, `0.5`, `1`, `0`.
    private static func shortNumber(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static func resamplerName(_ mode: ResampleMode) -> String {
        switch mode {
        case .nearest: "nearest"
        case .bilinear: "bilinear"
        case .metalfx: "metalfx"
        case .ewaLanczos: "ewa-lanczos"
        case .kernel(let kernel, _): kernel.rawValue
        }
    }

    /// The debug log's line for an activation (spec windows-and-tabs §3.8): `activate 2 state=full reads=0 · 2.7 / 3.0 GB
    /// · other windows −3 (412 MB)`; `reads` counts the reads and decodes it started, `state=none` when nothing of the
    /// current photo is held.
    public static func activationLog(session: Int, _ activation: CacheActivation) -> String {
        let stats = activation.stats
        return "activate \(session) state=\(activation.current.map(stateName) ?? "none") reads=\(activation.jobs) · "
            + "\(gigabytes(stats.usedBytes)) / \(gigabytes(stats.effectiveLimitBytes)) GB" + otherWindows(stats.evictedInactive)
    }

    private static func stateName(_ goal: CacheGoal) -> String {
        switch goal {
        case .bytes: "bytes"
        case .coarse: "coarse"
        case .preview: "preview"
        case .full: "full"
        }
    }

    /// ` · other windows −3 (412 MB)`: what eviction took from inactive windows (`CacheStats.evictedInactive`, MB of
    /// 2^20 bytes); empty while nothing was.
    private static func otherWindows(_ evicted: (count: Int, bytes: Int)) -> String {
        guard evicted.count > 0 else { return "" }
        return " · other windows −\(evicted.count) (\(Int((Double(evicted.bytes) / Double(1 << 20)).rounded())) MB)"
    }

    private static func gigabytes(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / Double(1 << 30))
    }

    /// "JPEG", "HEIC", … for the types the viewer reads; any other type shows its file extension.
    public static func formatName(_ typeIdentifier: String) -> String {
        switch typeIdentifier {
        case "public.jpeg": return "JPEG"
        case "public.heic": return "HEIC"
        case "public.avif": return "AVIF"
        case "public.jpeg-xl": return "JXL"
        case "org.webmproject.webp": return "WebP"
        case "public.png": return "PNG"
        default: return UTType(typeIdentifier)?.preferredFilenameExtension?.uppercased() ?? typeIdentifier
        }
    }

    /// "Fit 23 %", "100 %" (actual size names itself), "Zoom 310 %". The percentage is view pixels per
    /// image pixel (physical pixels, so 100 % is 1:1 even on a Retina display). A free zoom resting on fit width,
    /// fit height or 100 % (where a gesture halts, `ZoomStop`) is named by it.
    public static func modeText(_ transform: ViewTransform) -> String {
        let percent = percentText(transform.scale * 100)
        switch transform.mode {
        case .fit: return "Fit \(percent) %"
        case .fitWidth: return "Fit width \(percent) %"
        case .fitHeight: return "Fit height \(percent) %"
        case .fill: return "Fill \(percent) %"
        case .actual: return "\(percent) %"
        case .free:
            let s = transform.scale
            func on(_ mode: ZoomMode) -> Bool { abs(transform.withMode(mode).scale - s) <= s * 1e-9 }
            if on(.actual(1)) { return "\(percent) %" }
            if on(.fitWidth) { return "Fit width \(percent) %" }
            if on(.fitHeight) { return "Fit height \(percent) %" }
            return "Zoom \(percent) %"
        }
    }

    /// Whole percent, one decimal below 10 % so a thumbnail-sized zoom-out does not read "0 %".
    private static func percentText(_ percent: Double) -> String {
        percent < 10 ? String(format: "%.1f", percent) : String(format: "%.0f", percent)
    }
}

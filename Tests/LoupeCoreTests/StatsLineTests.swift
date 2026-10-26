import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

@Suite struct StatsLineTests {
    @Test func folderPositionSupportsSpreadsAndUncountedFolders() {
        #expect(StatsLine.position(index: 5, companion: 6, count: 20) == "6–7 / 20")
        #expect(StatsLine.position(index: 5, count: 20, counted: false) == "6 / …")
    }

    @Test func formatNames() {
        #expect(StatsLine.formatName("public.heic") == "HEIC")
        #expect(StatsLine.formatName("public.avif") == "AVIF")
        #expect(StatsLine.formatName("public.jpeg-xl") == "JXL")
        #expect(StatsLine.formatName("org.webmproject.webp") == "WebP")
        #expect(StatsLine.formatName("public.png") == "PNG")
        #expect(StatsLine.formatName("com.compuserve.gif") == "GIF")
    }

    @Test func modeNames() {
        let base = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 500, height: 500))
        #expect(StatsLine.modeText(base) == "Fit 50 %")
        #expect(StatsLine.modeText(base.withMode(.fill)) == "Fill 50 %")
        #expect(StatsLine.modeText(base.withMode(.fitWidth)) == "Fit width 50 %")
        #expect(StatsLine.modeText(base.withMode(.actual(2))) == "200 %")
        #expect(StatsLine.modeText(base.zoomed(toScale: 0.2, anchor: .zero)) == "Zoom 20 %")
        let huge = ViewTransform(imageSize: CGSize(width: 100_000, height: 100_000), viewSize: CGSize(width: 500, height: 500))
        #expect(StatsLine.modeText(huge) == "Fit 0.5 %")
    }

    private func frames(gpu: [Double] = [1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 1.9, 1.9]) -> FrameStats {
        var f = FrameStats()
        for g in gpu { f.record(gpuMs: g, interval: 0.0167, period: 0.0167) }
        return f
    }

    private let timings = LoadTimings(readMs: 98.2, firstLookMs: 12, previewMs: 111.6, fullMs: 171.4, uploadMs: 40.4)
    private let cache = CacheStats(bytesCount: 6, previewCount: 20, fullCount: 2, usedBytes: 2_899_102_925,
                                   limitBytes: 3 << 30, effectiveLimitBytes: 3 << 30)

    private func value(_ rows: [InfoRow], _ label: String) -> String? { rows.first { $0.label == label }?.value }

    @Test func diagnosticsFormatsTimings() {
        let rows = StatsLine.diagnostics(colorSpace: "Display P3", decoder: "libjpeg-turbo", timings: timings, fromCache: false,
                                         state: .full, cache: cache, ramBytes: 3_650_722_201, gpuBytes: 3_006_477_107, frames: frames())
        #expect(rows == [
            InfoRow(label: "Decoder", value: "libjpeg-turbo"),
            InfoRow(label: "Colour space", value: "Display P3"),
            InfoRow(label: "Load", value: "read 98 · preview 112 · full 171 · upload 40 ms"),
            InfoRow(label: "Cache", value: "full"),
            InfoRow(label: "Cache use", value: "20 previews · 2 full · 2.9 / 3.2 GB"),
            InfoRow(label: "Memory", value: "RAM 3.4 GB · GPU 2.8 GB"),
            InfoRow(label: "Frame", value: "GPU 1.2/1.9 ms · 0 dropped"),
        ])
    }

    @Test func colourLine() {
        let applied = ColorStatus.applied(method: .apple, share: 0.42, delta: 8.5)
        #expect(StatsLine.colour(.off, vibrance: nil, fromFolder: false) == "Colour: off")
        #expect(StatsLine.colour(applied, vibrance: nil, fromFolder: false) == "Colour: auto apple 0.42 · Δ 8.5")
        #expect(StatsLine.colour(.applied(method: .appleLuma, share: 1, delta: 14.04), vibrance: nil, fromFolder: false)
                == "Colour: auto apple-luma 1 · Δ 14.0")
        #expect(StatsLine.colour(.applied(method: .apple, share: 0, delta: 6), vibrance: nil, fromFolder: false)
                == "Colour: auto apple 0 · Δ 6.0")
        #expect(StatsLine.colour(.needsNone(delta: 4.1), vibrance: nil, fromFolder: false) == "Colour: auto · Δ 4.1, needs none")
        #expect(StatsLine.colour(.tooDark, vibrance: nil, fromFolder: false) == "Colour: auto, too dark")
        #expect(StatsLine.colour(.analysing, vibrance: nil, fromFolder: false) == "Colour: auto, analysing")
        #expect(StatsLine.colour(.nothingToApply(delta: 8.5), vibrance: nil, fromFolder: false)
                == "Colour: auto · Δ 8.5, nothing to apply")
        #expect(StatsLine.colour(.noThumbnail, vibrance: nil, fromFolder: false) == "Colour: auto, no thumbnail")
    }

    @Test func colourLineVibranceAndFolder() {
        #expect(StatsLine.colour(.off, vibrance: 0.5, fromFolder: false) == "Colour: off · vibrance 0.5")
        #expect(StatsLine.colour(.analysing, vibrance: 1, fromFolder: false) == "Colour: auto, analysing · vibrance 1")
        #expect(StatsLine.colour(.applied(method: .apple, share: 0.42, delta: 8.5), vibrance: 0.25, fromFolder: true)
                == "Colour: auto apple 0.42 · Δ 8.5 · vibrance 0.25 · folder")
        #expect(StatsLine.colour(.off, vibrance: nil, fromFolder: true) == "Colour: off · folder")
        #expect(StatsLine.colour(.nothingToApply(delta: 14.04), vibrance: 0.5, fromFolder: true)
                == "Colour: auto · Δ 14.0, nothing to apply · vibrance 0.5 · folder")
        #expect(StatsLine.colour(.noThumbnail, vibrance: 0.5, fromFolder: true) == "Colour: auto, no thumbnail · vibrance 0.5 · folder")
    }

    @Test func filterNames() {
        #expect(StatsLine.filterName(regime: nil, mode: .nearest, level: 0, m: 8) == "pixel-art nearest ×8.00")
        #expect(StatsLine.filterName(regime: .downscale, mode: .bilinear, level: 2, m: 0.31) == "downscale bilinear ×0.31 L2")
        #expect(StatsLine.filterName(regime: .upscale, mode: .kernel(.lanczos3, upscale: true), level: 0, m: 2)
                == "upscale lanczos3 ×2.00")
        #expect(StatsLine.filterName(regime: .upscaleHigh, mode: .kernel(.mitchell, upscale: true), level: 0, m: 4.5)
                == "strong upscale mitchell ×4.50")
        #expect(StatsLine.filterName(regime: .downscale, mode: .kernel(.lanczos3, upscale: false), level: 1, m: 0.87)
                == "downscale lanczos3 ×0.87 L1")
        #expect(StatsLine.filterName(regime: .downscale, mode: .kernel(.catmullRom, upscale: false), level: 0, m: 1)
                == "downscale catmull-rom ×1.00")
    }

    @Test func metalfxName() {
        #expect(StatsLine.filterName(regime: .upscale, mode: .metalfx, level: 0, m: 2) == "upscale metalfx ×2.00")
        #expect(StatsLine.filterName(regime: .upscale, mode: .metalfx, level: 1, m: 3.2449) == "upscale metalfx ×3.24 L1")
        // The fallback without MetalFX is drawn, and named, as Lanczos-3.
        #expect(StatsLine.filterName(regime: .upscale, mode: .kernel(.lanczos3, upscale: true), level: 0, m: 2)
                == "upscale lanczos3 ×2.00")
    }

    @Test func ewaLanczosName() {
        #expect(StatsLine.filterName(regime: .upscaleHigh, mode: .ewaLanczos, level: 0, m: 4.5)
                == "strong upscale ewa-lanczos ×4.50")
        #expect(StatsLine.filterName(regime: .upscale, mode: .ewaLanczos, level: 2, m: 16) == "upscale ewa-lanczos ×16.00 L2")
    }

    @Test func filterNameFolderSuffix() {
        #expect(StatsLine.filterName(regime: .upscale, mode: .ewaLanczos, level: 0, m: 4.5, fromFolder: true)
                == "upscale ewa-lanczos ×4.50 · folder")
        #expect(StatsLine.filterName(regime: .upscale, mode: .ewaLanczos, level: 0, m: 4.5, fromFolder: false)
                == "upscale ewa-lanczos ×4.50")
        #expect(StatsLine.filterName(regime: .downscale, mode: .bilinear, level: 2, m: 0.31, fromFolder: true)
                == "downscale bilinear ×0.31 L2 · folder")
    }

    /// Spec windows-and-tabs §3.8: what eviction took from other windows over the run, on the Cache use row.
    @Test func showsOtherWindowsEvictions() {
        let evicted = CacheStats(bytesCount: 6, previewCount: 20, fullCount: 2, usedBytes: 2_899_102_925,
                                 limitBytes: 3 << 30, effectiveLimitBytes: 3 << 30,
                                 evictedInactive: (count: 3, bytes: 412 << 20))
        let rows = StatsLine.diagnostics(colorSpace: nil, decoder: nil, timings: timings, fromCache: false, state: .full,
                                         cache: evicted, ramBytes: 0, gpuBytes: 0, frames: FrameStats())
        #expect(value(rows, "Cache use") == "20 previews · 2 full · 2.9 / 3.2 GB · other windows −3 (412 MB)")
    }

    /// Spec window-cache-ownership §1: what the other windows' keep sets hold, on the Cache use row and in the
    /// activation's log line; nothing while they hold nothing.
    @Test func showsKeptForOtherWindows() {
        let kept = CacheStats(bytesCount: 6, previewCount: 20, fullCount: 2, usedBytes: 2_899_102_925,
                              limitBytes: 3 << 30, effectiveLimitBytes: 3 << 30,
                              evictedInactive: (count: 3, bytes: 412 << 20), keptForOtherWindows: 96 << 20)
        let rows = StatsLine.diagnostics(colorSpace: nil, decoder: nil, timings: timings, fromCache: false, state: .full,
                                         cache: kept, ramBytes: 0, gpuBytes: 0, frames: FrameStats())
        #expect(value(rows, "Cache use")
                == "20 previews · 2 full · 2.9 / 3.2 GB · other windows −3 (412 MB) · kept for other windows 96 MB")
        #expect(StatsLine.activationLog(session: 2, CacheActivation(current: .full, jobs: 0, stats: kept))
                == "activate 2 state=full reads=0 · 2.7 / 3.0 GB · other windows −3 (412 MB) · kept 96 MB")
    }

    /// Spec window-cache-ownership §2: the re-reads since launch at the end of the activation's log line, once
    /// there are any.
    @Test func activationLogShowsRereads() {
        let stats = CacheStats(bytesCount: 6, previewCount: 20, fullCount: 2, usedBytes: 2_899_102_925,
                               limitBytes: 3 << 30, effectiveLimitBytes: 3 << 30, keptForOtherWindows: 96 << 20,
                               rereads: 4)
        #expect(StatsLine.activationLog(session: 3, CacheActivation(current: .bytes, jobs: 2, stats: stats))
                == "activate 3 state=bytes reads=2 · 2.7 / 3.0 GB · kept 96 MB · rereads 4")
    }

    /// Spec windows-and-tabs §3.8: the debug log's line for an activation.
    @Test func activationLog() {
        let evicted = CacheStats(bytesCount: 6, previewCount: 20, fullCount: 2, usedBytes: 2_899_102_925,
                                 limitBytes: 3 << 30, effectiveLimitBytes: 3 << 30,
                                 evictedInactive: (count: 3, bytes: 412 << 20))
        #expect(StatsLine.activationLog(session: 2, CacheActivation(current: .full, jobs: 0, stats: evicted))
                == "activate 2 state=full reads=0 · 2.7 / 3.0 GB · other windows −3 (412 MB)")
        #expect(StatsLine.activationLog(session: 1, CacheActivation(current: nil, jobs: 4, stats: cache))
                == "activate 1 state=none reads=4 · 2.7 / 3.0 GB")
    }

    @Test func hidesZero() {
        let rows = StatsLine.diagnostics(colorSpace: nil, decoder: nil, timings: timings, fromCache: false, state: .full,
                                         cache: cache, ramBytes: 0, gpuBytes: 0, frames: FrameStats())
        #expect(value(rows, "Cache use") == "20 previews · 2 full · 2.9 / 3.2 GB")
    }

    @Test func diagnosticsFrameRow() {
        let with = StatsLine.diagnostics(colorSpace: nil, decoder: nil, timings: timings, fromCache: false, state: .full,
                                         cache: cache, ramBytes: 0, gpuBytes: 0, frames: frames())
        #expect(value(with, "Frame") == "GPU 1.2/1.9 ms · 0 dropped")
        let none = StatsLine.diagnostics(colorSpace: nil, decoder: nil, timings: timings, fromCache: false, state: .full,
                                         cache: cache, ramBytes: 0, gpuBytes: 0, frames: FrameStats())
        #expect(value(none, "Frame") == "–")
        #expect(none.last?.label == "Frame")
    }

    @Test func diagnosticsCachedLabel() {
        let rows = StatsLine.diagnostics(colorSpace: "sRGB", decoder: nil, timings: timings, fromCache: true,
                                         state: .preview, cache: cache, ramBytes: 0, gpuBytes: 0, frames: FrameStats())
        #expect(rows.map(\.label) == ["Colour space", "Load", "Cache", "Cache use", "Memory", "Frame"])
        #expect(value(rows, "Load") == "cached")
        #expect(value(rows, "Cache") == "preview")
        #expect(value(rows, "Frame") == "–")
    }

    @Test func diagnosticsLeavesOutWhatIsUnknown() {
        let rows = StatsLine.diagnostics(colorSpace: nil, decoder: nil, timings: LoadTimings(readMs: 5), fromCache: false,
                                         state: nil, cache: cache, ramBytes: 0, gpuBytes: 0, frames: FrameStats())
        #expect(rows.map(\.label) == ["Load", "Cache", "Cache use", "Memory", "Frame"])
        #expect(value(rows, "Load") == "read 5 ms")
        #expect(value(rows, "Cache") == "–")
        // No timing known and not cached: no Load row.
        let blank = StatsLine.diagnostics(colorSpace: nil, decoder: nil, timings: LoadTimings(), fromCache: false,
                                          state: .full, cache: cache, ramBytes: 0, gpuBytes: 0, frames: FrameStats())
        #expect(value(blank, "Load") == nil)
    }

    /// Only the stretched thumbnail is on screen (M2.5 spec §5.2): the cache state reads `thumb`, whatever goal it
    /// reached.
    @Test func diagnosticsSaysThumbWhileOnlyTheSeedIsResident() {
        let rows = StatsLine.diagnostics(colorSpace: nil, decoder: nil, timings: LoadTimings(), fromCache: false,
                                         state: .coarse, isSeededOnly: true, cache: cache, ramBytes: 0, gpuBytes: 0,
                                         frames: FrameStats())
        #expect(value(rows, "Cache") == "thumb")
        let decoded = StatsLine.diagnostics(colorSpace: nil, decoder: nil, timings: LoadTimings(), fromCache: false,
                                            state: .coarse, cache: cache, ramBytes: 0, gpuBytes: 0, frames: FrameStats())
        #expect(value(decoded, "Cache") == "coarse")
    }

    @Test func diagnosticsShowTheLimitUnderMemoryPressure() {
        let squeezed = CacheStats(bytesCount: 1, previewCount: 3, fullCount: 0, usedBytes: 2_254_857_830,
                                  limitBytes: 3 << 30, effectiveLimitBytes: 3 << 29)
        let rows = StatsLine.diagnostics(colorSpace: nil, decoder: nil, timings: LoadTimings(), fromCache: false,
                                         state: .full, cache: squeezed, ramBytes: 0, gpuBytes: 0, frames: FrameStats())
        #expect(value(rows, "Cache use") == "3 previews · 0 full · 2.3 / 1.6 GB (pressure)")
    }

    /// On a discrete card the row's figures are the system tier's (`cache-memory`), followed by the graphics tier's.
    @Test func diagnosticsShowTheGraphicsTier() {
        let tiers = CacheStats(bytesCount: 24, previewCount: 20, fullCount: 2, usedBytes: 2_899_102_925,
                               limitBytes: 3 << 30, effectiveLimitBytes: 3 << 30,
                               evictedInactive: (count: 3, bytes: 412 << 20),
                               graphicsUsedBytes: 3_758_096_384, graphicsLimitBytes: 4_286_578_688)
        let rows = StatsLine.diagnostics(colorSpace: nil, decoder: nil, timings: LoadTimings(), fromCache: false,
                                         state: .full, cache: tiers, ramBytes: 0, gpuBytes: 0, frames: FrameStats())
        #expect(value(rows, "Cache use")
                == "20 previews · 2 full · 2.9 / 3.2 GB · GPU 3.8 / 4.3 GB · other windows −3 (412 MB)")
        // Unified memory: one budget, no GPU figure.
        let one = StatsLine.diagnostics(colorSpace: nil, decoder: nil, timings: LoadTimings(), fromCache: false,
                                        state: .full, cache: cache, ramBytes: 0, gpuBytes: 0, frames: FrameStats())
        #expect(value(one, "Cache use") == "20 previews · 2 full · 2.9 / 3.2 GB")
    }

    /// The stats bar's fill (Task 17b): the folder position `(index + 1) / count`, so the last photo fills the bar.
    @Test func progressIsThePositionInTheFolder() {
        #expect(StatsLine.progress(index: 0, count: 4) == 0.25)
        #expect(StatsLine.progress(index: 3, count: 4) == 1)
        #expect(StatsLine.progress(index: 136, count: 200) == 137.0 / 200)
        #expect(StatsLine.progress(index: 0, count: 1) == 1)
        // Nothing to show, or an index the playlist does not have: clamped, never outside the bar.
        #expect(StatsLine.progress(index: 0, count: 0) == 0)
        #expect(StatsLine.progress(index: 9, count: 4) == 1 && StatsLine.progress(index: -3, count: 4) == 0)
    }

    /// The folder's name in the middle of the bar: its last path component, a volume's name at a volume's root.
    @Test func folderNameIsTheLastComponentOrTheVolume() {
        #expect(StatsLine.folderName(of: URL(fileURLWithPath: "/Users/me/Pictures/Trip 2026", isDirectory: true),
                                     volumeName: nil) == "Trip 2026")
        #expect(StatsLine.folderName(of: URL(fileURLWithPath: "/Volumes/Photos$", isDirectory: true),
                                     volumeName: "Photos$") == "Photos$")
        #expect(StatsLine.folderName(of: URL(fileURLWithPath: "/", isDirectory: true),
                                     volumeName: "Macintosh HD") == "Macintosh HD")
        #expect(StatsLine.folderName(of: URL(fileURLWithPath: "/", isDirectory: true), volumeName: nil) == "/")
        #expect(StatsLine.folderName(of: URL(fileURLWithPath: "/Volumes/Photos$", isDirectory: true),
                                     volumeName: "") == "Photos$")
    }
}

/// A pair's status gives its first page's facts in reading order, whichever page is current.
@Test func pairFactsComeFromTheFirstPage() {
    #expect(!StatsLine.factsOfCompanion(current: 12, first: 12, companionRead: true))   // current is first
    #expect(StatsLine.factsOfCompanion(current: 13, first: 12, companionRead: true))    // companion is first
    #expect(!StatsLine.factsOfCompanion(current: 13, first: 12, companionRead: false))  // not read: the current's
}

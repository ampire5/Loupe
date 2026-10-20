import Testing
@testable import LoupeCore

// MARK: Frame path (spec §3.1)

@Test func modeTable() {
    let s = ResampleSettings()
    #expect(s.mode(scale: 2.99, level: 0) == .kernel(.lanczos3, upscale: true))
    #expect(s.mode(scale: 3, level: 0) == .kernel(.mitchell, upscale: true))       // upscale-high from 300 %
    #expect(s.mode(scale: 3.99, level: 0) == .kernel(.mitchell, upscale: true))
    #expect(s.mode(scale: 0.7, level: 0) == .kernel(.lanczos3, upscale: false))
    #expect(s.mode(scale: 0.3, level: 1) == .kernel(.lanczos3, upscale: false))   // m 0.6
    #expect(s.mode(scale: 1, level: 0) == .kernel(.lanczos3, upscale: false))     // m = 1 counts as downscale
    #expect(s.mode(scale: 4, level: 0) == .nearest)
}

@Test func pixelArtOnlyOnLevelZero() {
    // A stretched preview level at 800 % stays smooth; nearest waits for the real pixels.
    #expect(ResampleSettings().mode(scale: 8, level: 2) == .kernel(.mitchell, upscale: true))
    #expect(ResampleSettings().mode(scale: 8, level: 0) == .nearest)
}

@Test func pixelArtOff() {
    var s = ResampleSettings()
    s.pixelArtPercent = 0
    #expect(s.mode(scale: 40, level: 0) == .kernel(.mitchell, upscale: true))
    s.upscaleHighPercent = 0
    #expect(s.mode(scale: 40, level: 0) == .kernel(.lanczos3, upscale: true))
}

@Test func upscaleHigh() {
    var s = ResampleSettings(upscaleHigh: .bilinear, upscaleHighPercent: 250)
    #expect(s.mode(scale: 2.49, level: 0) == .kernel(.lanczos3, upscale: true))
    #expect(s.mode(scale: 2.5, level: 0) == .bilinear)
    // Judged on the drawn level's magnification: a preview level 1 at 150 % is stretched ×3.
    #expect(s.mode(scale: 1.5, level: 1) == .bilinear)
    #expect(s.mode(scale: 0.7, level: 0) == .kernel(.lanczos3, upscale: false))   // never on downscale
    #expect(s.mode(scale: 4, level: 0) == .nearest)                                // pixel-art still wins
    s.upscaleHigh = .kernel(.lanczos2)
    s.upscaleHighPercent = 100
    #expect(s.mode(scale: 1.01, level: 0) == .kernel(.lanczos2, upscale: true))
}

@Test func metalfxMode() {
    // MetalFX only magnifies (spec §3.5): below m = 1 the downscale kernel draws.
    var s = ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0)
    #expect(s.mode(scale: 2, level: 0) == .metalfx)
    #expect(s.mode(scale: 1.5, level: 1) == .metalfx)                                // a stretched level, m 3
    #expect(s.mode(scale: 0.7, level: 0) == .kernel(.lanczos3, upscale: false))
    #expect(s.mode(scale: 1, level: 0) == .kernel(.lanczos3, upscale: false))       // m = 1 is downscale
    #expect(s.mode(scale: 4, level: 0) == .nearest)                                  // pixel-art still wins
    // With upscale-high on (its default 300 %), upscale = metalfx draws only below the threshold.
    s.upscaleHighPercent = 300
    #expect(s.mode(scale: 2.99, level: 0) == .metalfx)
    #expect(s.mode(scale: 3, level: 0) == .kernel(.mitchell, upscale: true))
}

@Test func metalfxAsUpscaleHigh() {
    let s = ResampleSettings(upscaleHigh: .metalfx, upscaleHighPercent: 250, pixelArtPercent: 0)
    #expect(s.mode(scale: 2.49, level: 0) == .kernel(.lanczos3, upscale: true))
    #expect(s.mode(scale: 2.5, level: 0) == .metalfx)
    #expect(s.mode(scale: 8, level: 0) == .metalfx)
    #expect(s.mode(scale: 0.7, level: 0) == .kernel(.lanczos3, upscale: false))
}

@Test func ewaMode() {
    // EWA Lanczos only magnifies (an upscale / upscale-high value): below m = 1 the downscale kernel draws.
    var s = ResampleSettings()
    s.upscale = .ewaLanczos
    #expect(s.mode(scale: 2, level: 0) == .ewaLanczos)
    #expect(s.mode(scale: 0.7, level: 0) == .kernel(.lanczos3, upscale: false))
    s = ResampleSettings(upscaleHigh: .ewaLanczos, upscaleHighPercent: 300)
    #expect(s.mode(scale: 2, level: 0) == .kernel(.lanczos3, upscale: true))
    #expect(s.mode(scale: 3, level: 0) == .ewaLanczos)
    #expect(s.mode(scale: 4, level: 0) == .nearest)                                  // pixel-art 400 still wins
    #expect(s.mode(scale: 2, level: 1) == .ewaLanczos)                               // a stretched level, m 4
}

@Test func bilinearFilters() {
    var s = ResampleSettings()
    s.upscale = .bilinear
    #expect(s.mode(scale: 2, level: 0) == .bilinear)
    #expect(s.mode(scale: 0.7, level: 0) == .kernel(.lanczos3, upscale: false))
    s = ResampleSettings()
    s.downscale = .bilinear
    #expect(s.mode(scale: 0.7, level: 0) == .bilinear)
    #expect(s.mode(scale: 2, level: 0) == .kernel(.lanczos3, upscale: true))
}

@Test func otherKernelsPassThrough() {
    let s = ResampleSettings(upscale: .kernel(.mitchell), downscale: .kernel(.catmullRom))
    #expect(s.mode(scale: 2, level: 0) == .kernel(.mitchell, upscale: true))
    #expect(s.mode(scale: 0.7, level: 0) == .kernel(.catmullRom, upscale: false))
}

@Test func belowCoarsestLevelIsBilinear() {
    // A tiny image far out: the coarsest level (2) still draws at m 0.4.
    #expect(ResampleSettings().mode(scale: 0.1, level: 2) == .bilinear)
    #expect(ResampleSettings().mode(scale: 0.125, level: 2) == .kernel(.lanczos3, upscale: false))   // m 0.5
}

@Test func kernelSupport() {
    #expect(ResampleKernel.lanczos3.support == 3)
    for kernel in [ResampleKernel.lanczos2, .mitchell, .catmullRom] { #expect(kernel.support == 2) }
}

@Test func drawnLevel() {
    let grid = TileGrid(imageSize: PixelSize(width: 10000, height: 8000))
    #expect(grid.drawnLevel(forScale: 0.3, finestResident: 0) == 1)
    #expect(grid.drawnLevel(forScale: 0.3, finestResident: 3) == 3)
    #expect(grid.drawnLevel(forScale: 2, finestResident: 0) == 0)
}

@Test func filterTextParsing() {
    #expect(UpscaleFilter(text: "Lanczos3") == .kernel(.lanczos3) && UpscaleFilter(text: "lanczos") == nil)
    #expect(DownscaleFilter(text: "CATMULL-ROM") == .kernel(.catmullRom))
    #expect(UpscaleFilter(text: "bilinear") == .bilinear)
    #expect(DownscaleFilter(text: "bicubic") == nil)
    #expect(UpscaleFilter.kernel(.catmullRom).text == "catmull-rom")
    #expect(UpscaleFilter(text: "MetalFX") == .metalfx && UpscaleFilter.metalfx.text == "metalfx")
    #expect(DownscaleFilter(text: "metalfx") == nil)
    #expect(UpscaleFilter(text: "EWA-Lanczos") == .ewaLanczos && UpscaleFilter(text: "ewa") == .ewaLanczos)
    #expect(UpscaleFilter.ewaLanczos.text == "ewa-lanczos")
    #expect(DownscaleFilter(text: "ewa-lanczos") == nil && DownscaleFilter(text: "ewa") == nil)
}

@Test func settingsFromConfigAfterReload() {
    // What a reload does: parse the new text, build the settings again; only the changed key differs.
    let before = ResampleSettings(config: Config.parse("upscale=mitchell\n").0)
    let after = ResampleSettings(config: Config.parse("upscale=bilinear\n").0)
    #expect(before.upscale == .kernel(.mitchell))
    #expect(after.upscale == .bilinear)
    var expected = before
    expected.upscale = .bilinear
    #expect(after == expected)
    #expect(after.downscale == before.downscale && after.antiringing == before.antiringing
            && after.pixelArtPercent == before.pixelArtPercent)
}

// MARK: Active key and cycles (folder settings spec §4)

@Test func activeKeyRules() {
    var s = ResampleSettings(pixelArtPercent: 800)
    #expect(s.activeKey(scale: 8, level: 0) == nil)                     // nearest: nothing to cycle
    #expect(s.activeKey(scale: 2, level: 0) == .upscale)
    s.pixelArtPercent = 0
    #expect(s.activeKey(scale: 3, level: 0) == .upscaleHigh)            // m 3, upscale-high from 300 %
    s.upscaleHighPercent = 0
    #expect(s.activeKey(scale: 5, level: 0) == .upscale)                // upscale-high off
    #expect(s.activeKey(scale: 0.7, level: 0) == .downscale)
    #expect(s.activeKey(scale: 0.3, level: 0) == .downscale)            // m < 0.5 draws bilinear, still downscale's
    #expect(s.activeKey(scale: 1, level: 0) == .downscale)
    #expect(ResampleSettings().activeKey(scale: 0.3, level: 1) == .downscale)
    #expect(ResampleSettings().activeKey(scale: 1.5, level: 1) == .upscaleHigh)   // m 3 on a stretched level
}

@Test func cyclesWrap() {
    #expect(DownscaleFilter.cycle.count == 5)
    #expect(UpscaleFilter.cycle.count == 7)
    var d = DownscaleFilter.cycle[0]
    for expected in DownscaleFilter.cycle.dropFirst() + [DownscaleFilter.cycle[0]] {
        d = d.next()
        #expect(d == expected)
    }
    var u = UpscaleFilter.cycle[0]
    for expected in UpscaleFilter.cycle.dropFirst() + [UpscaleFilter.cycle[0]] {
        u = u.next()
        #expect(u == expected)
    }
    #expect(DownscaleFilter.cycle.map(\.text) == ["lanczos3", "lanczos2", "mitchell", "catmull-rom", "bilinear"])
    #expect(UpscaleFilter.cycle.map(\.text)
            == ["lanczos3", "lanczos2", "mitchell", "catmull-rom", "bilinear", "metalfx", "ewa-lanczos"])
}

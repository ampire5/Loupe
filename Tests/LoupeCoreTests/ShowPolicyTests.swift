import Foundation
import LoupeCore
import Testing

// Levels: 0 is full resolution; Lfit = 3 in these cases.

@Test func sharpEnoughShown() {
    #expect(ShowPolicy.shouldShow(finestResident: 3, neededLevel: 3, previewLevel: 3, mode: .no))
    #expect(ShowPolicy.shouldShow(finestResident: 0, neededLevel: 3, previewLevel: 3, mode: .no))
    #expect(ShowPolicy.shouldShow(finestResident: 0, neededLevel: 0, previewLevel: 3, mode: .no))
}

@Test func blurryHiddenByDefault() {
    #expect(!ShowPolicy.shouldShow(finestResident: 4, neededLevel: 3, previewLevel: 3, mode: .no))
    #expect(!ShowPolicy.shouldShow(finestResident: 3, neededLevel: 0, previewLevel: 3, mode: .no))
}

@Test func fitAllowsOneCoarserLevelInFit() {
    #expect(ShowPolicy.shouldShow(finestResident: 4, neededLevel: 3, previewLevel: 3, mode: .fit))
    // Zoomed out further than Fit: still one level of slack.
    #expect(ShowPolicy.shouldShow(finestResident: 5, neededLevel: 4, previewLevel: 3, mode: .fit))
    // Two levels coarser is too blurry even in Fit.
    #expect(!ShowPolicy.shouldShow(finestResident: 5, neededLevel: 3, previewLevel: 3, mode: .fit))
}

@Test func fitStillHidesBlurryAt100() {
    #expect(!ShowPolicy.shouldShow(finestResident: 3, neededLevel: 0, previewLevel: 3, mode: .fit))
    // Between 100 % and Fit (needed finer than Lfit): no slack either.
    #expect(!ShowPolicy.shouldShow(finestResident: 3, neededLevel: 2, previewLevel: 3, mode: .fit))
    #expect(ShowPolicy.shouldShow(finestResident: 0, neededLevel: 0, previewLevel: 3, mode: .fit))
}

@Test func alwaysShowsAnything() {
    #expect(ShowPolicy.shouldShow(finestResident: 7, neededLevel: 0, previewLevel: 3, mode: .always))
    #expect(ShowPolicy.shouldShow(finestResident: 0, neededLevel: 0, previewLevel: 3, mode: .always))
}

@Test func nothingResidentNeverShown() {
    for mode in [ShowBlurry.no, .fit, .always] {
        #expect(!ShowPolicy.shouldShow(finestResident: nil, neededLevel: 3, previewLevel: 3, mode: mode))
    }
}

/// A strip jump's seeded entry is shown stretched whatever `show-blurry` says; without the flag, as before.
@Test func jumpPreviewShowsAnyResident() {
    #expect(ShowPolicy.shouldShow(finestResident: 5, neededLevel: 2, previewLevel: 2, mode: .no, jumpPreview: true))
    #expect(!ShowPolicy.shouldShow(finestResident: 5, neededLevel: 2, previewLevel: 2, mode: .no))
    #expect(!ShowPolicy.shouldShow(finestResident: nil, neededLevel: 2, previewLevel: 2, mode: .no, jumpPreview: true))
}

/// A pyramid stand-in: `refinesShown` compares pyramids by identity.
private final class Pyramid: Sendable {}

private func view(_ name: String, _ pyramid: Pyramid?, seeded: Bool = false,
                  failure: String? = nil) -> CacheEntryView<Pyramid> {
    CacheEntryView(url: URL(fileURLWithPath: "/p/\(name)"), info: nil, pyramid: pyramid, failure: failure,
                   decoderName: nil, timings: LoadTimings(), state: nil, isSeededOnly: seeded)
}

/// The pyramid on screen gaining levels stays on screen; another photo, a failed one or no pyramid asks `shouldShow`.
@Test func samePyramidRefinesShown() {
    let p = Pyramid()
    #expect(ShowPolicy.refinesShown(view("a", p), shown: view("a", p)))
    #expect(!ShowPolicy.refinesShown(view("a", p), shown: nil))
    #expect(!ShowPolicy.refinesShown(view("b", p), shown: view("a", p)))
    #expect(!ShowPolicy.refinesShown(view("a", nil), shown: view("a", p)))
    #expect(!ShowPolicy.refinesShown(view("a", p), shown: view("a", p, failure: "x")))
    // A decoded pyramid replaced after a reset (the file changed) is a new picture: `shouldShow` decides.
    #expect(!ShowPolicy.refinesShown(view("a", Pyramid()), shown: view("a", p)))
}

/// The first decoded level replaces a seeded pyramid with a new object (`ImageCache.seed`): it takes the screen
/// at once, so the dropped thumbnail never lingers there, and so does a finer seed replacing a coarser one.
@Test func decodedPyramidReplacesShownSeed() {
    let seed = Pyramid()
    let shown = view("a", seed, seeded: true)
    #expect(ShowPolicy.refinesShown(view("a", Pyramid()), shown: shown))
    #expect(ShowPolicy.refinesShown(view("a", Pyramid(), seeded: true), shown: shown))
    #expect(!ShowPolicy.refinesShown(view("b", Pyramid()), shown: shown))
    #expect(!ShowPolicy.refinesShown(view("a", nil), shown: shown))
}

/// A wheel step that waits for its photo (`wheel-step`) shows more than `show-blurry` alone: `thumb` anything
/// resident (its seeded thumbnail, or a decoded level it already has), `coarse` any decoded level but not a
/// thumbnail; `sharp` and `any` add nothing (today's rule), and nothing resident is never shown.
@Test func stepShowsWhatItWaitsFor() {
    #expect(ShowPolicy.shownByStep(.thumb, finestResident: 5, seededOnly: true))
    #expect(ShowPolicy.shownByStep(.thumb, finestResident: 4, seededOnly: false))
    #expect(ShowPolicy.shownByStep(.coarse, finestResident: 4, seededOnly: false))
    #expect(!ShowPolicy.shownByStep(.coarse, finestResident: 5, seededOnly: true))
    for wait in [StepWait.sharp, .any] {
        #expect(!ShowPolicy.shownByStep(wait, finestResident: 4, seededOnly: false))
        #expect(!ShowPolicy.shownByStep(wait, finestResident: 5, seededOnly: true))
    }
    for wait in [StepWait?.none, .thumb, .coarse, .sharp, .any] {
        #expect(!ShowPolicy.shownByStep(wait, finestResident: nil, seededOnly: false))
    }
    #expect(!ShowPolicy.shownByStep(nil, finestResident: 4, seededOnly: false))
}

// MARK: - What the screen shows the moment a navigation lands (`switch-preview`)

/// Unless `switch-preview=keep`, a navigation never leaves another photo on screen: the new photo itself when it may
/// be shown, else a stand-in (its thumbnail when one is at hand, else a blank placeholder).
@Test func navigationNeverKeepsAnotherPhoto() {
    let a = URL(fileURLWithPath: "/p/a.jpg"), b = URL(fileURLWithPath: "/p/b.jpg")
    for setting in [SwitchPreview.thumb, .blank] {
        for seed in [false, true] {
            let action = ShowPolicy.atNavigation(shownURL: a, currentURL: b, showable: false, seedAvailable: seed,
                                                 setting: setting)
            #expect(action != .keep, "\(setting) seed \(seed)")
        }
        // Nothing on screen yet (a launch): a stand-in too.
        #expect(ShowPolicy.atNavigation(shownURL: nil, currentURL: b, showable: false, seedAvailable: false,
                                        setting: setting) == .placeholder)
    }
    // `keep`: the photo before stays until the new one may be shown (the old behaviour, now only on request).
    #expect(ShowPolicy.atNavigation(shownURL: a, currentURL: b, showable: false, seedAvailable: true,
                                    setting: .keep) == .keep)
}

/// `thumb` seeds the thumbnail when one is at hand, else the placeholder; `blank` always the placeholder.
@Test func navigationStandIn() {
    let a = URL(fileURLWithPath: "/p/a.jpg"), b = URL(fileURLWithPath: "/p/b.jpg")
    #expect(ShowPolicy.atNavigation(shownURL: a, currentURL: b, showable: false, seedAvailable: true,
                                    setting: .thumb) == .seed)
    #expect(ShowPolicy.atNavigation(shownURL: a, currentURL: b, showable: false, seedAvailable: false,
                                    setting: .thumb) == .placeholder)
    #expect(ShowPolicy.atNavigation(shownURL: a, currentURL: b, showable: false, seedAvailable: true,
                                    setting: .blank) == .placeholder)
}

/// A photo the cache can show at once (resident, sharp enough) needs no stand-in, so a cached photo appears within
/// a frame without a blank flash; nor does the photo already on screen.
@Test func navigationShowableOrShownNeedsNoStandIn() {
    let a = URL(fileURLWithPath: "/p/a.jpg"), b = URL(fileURLWithPath: "/p/b.jpg")
    for setting in [SwitchPreview.thumb, .blank, .keep] {
        #expect(ShowPolicy.atNavigation(shownURL: a, currentURL: b, showable: true, seedAvailable: true,
                                        setting: setting) == .keep)
        #expect(ShowPolicy.atNavigation(shownURL: b, currentURL: b, showable: false, seedAvailable: false,
                                        setting: setting) == .keep)
    }
}

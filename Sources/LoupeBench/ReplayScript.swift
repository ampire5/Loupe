import CoreGraphics
import Foundation
import LoupeCore

/// The zoom a replay script browses at: Fit, or 100 % (one image pixel per screen pixel, needs level 0).
enum ReplayZoom: String {
    case fit = "Fit"
    case actual = "100 %"

    /// The screen transform for an image of `size` on a screen of `screen` pixels.
    func transform(imageSize size: PixelSize, view: CGSize) -> ViewTransform {
        let image = CGSize(width: size.width, height: size.height)
        switch self {
        case .fit: return ViewTransform(imageSize: image, viewSize: view, mode: .fit)
        case .actual: return ViewTransform(imageSize: image, viewSize: view, mode: .actual(1))
        }
    }
}

/// One scripted navigation: move by `move` (+1 →, -1 ←) and stay `dwell` before the next step.
struct ReplayStep {
    let move: Int
    let dwell: Duration
    /// Part of a wheel spin (`burst`): reported apart from the dwelt-on steps.
    var burst = false
    /// The step a quick run of moves stops on (`jump10`): traced stage by stage (ReplayTrace.swift).
    var landing = false
    /// Reached by a click on the strip (`jumpfar`), as `ViewerSession.scrub(to:)` then `endScrub()`: a scrubbing
    /// focus, the thumbnail's seed with `--seed`, then the normal focus (ReplayDriver.begin).
    var strip = false
}

/// A navigation script from the folder's first file (Task 11b). Step 0 is opening that file, which is dwelt on
/// for `openDwell` before the first move, as a user looks at the first photo for a moment.
struct ReplayScript {
    let name: String
    let zoom: ReplayZoom
    let steps: [ReplayStep]
    var openDwell: Duration = .seconds(2)

    static let all = ["fit", "100", "burst", "pingpong"]
    static let known = all + ["jump10", "jump10-100", "jumpfar", "backfast"]

    /// From the first photo (3 s on it), five times: ten → 60 ms apart (key repeat or wheel), then 3 s on the photo
    /// it stops on, the landing.
    static func jump(_ name: String, zoom: ReplayZoom) -> ReplayScript {
        var steps: [ReplayStep] = []
        for _ in 0..<5 {
            steps += Array(repeating: ReplayStep(move: 1, dwell: .milliseconds(60), burst: true), count: 9)
            steps.append(ReplayStep(move: 1, dwell: .seconds(3), landing: true))
        }
        return ReplayScript(name: name, zoom: zoom, steps: steps, openDwell: .seconds(3))
    }

    /// From the first photo (3 s on it), five far jumps by strip clicks (M2.5 spec §5): +60, +60, −90, +100, −50,
    /// 3 s on each. Far beyond `cache-files`, so each landing is read from the share; with `--seed` its stored
    /// thumbnail is on screen meanwhile.
    static let jumpFar = ReplayScript(
        name: "jumpfar", zoom: .fit,
        steps: [60, 60, -90, 100, -50].map { ReplayStep(move: $0, dwell: .seconds(3), landing: true, strip: true) },
        openDwell: .seconds(3))

    static func named(_ key: String) -> ReplayScript? {
        let s = Duration.milliseconds(1500)
        switch key {
        case "fit":
            return ReplayScript(name: "fit-steps", zoom: .fit, steps: Array(repeating: ReplayStep(move: 1, dwell: s), count: 30))
        case "100":
            return ReplayScript(name: "100-steps", zoom: .actual,
                                steps: Array(repeating: ReplayStep(move: 1, dwell: s), count: 30)
                                    + Array(repeating: ReplayStep(move: -1, dwell: s), count: 10))
        case "backfast":
            // Forward through 15 photos, looking at each, then back through them faster than a decode.
            return ReplayScript(name: "back-fast", zoom: .actual,
                                steps: Array(repeating: ReplayStep(move: 1, dwell: s), count: 15)
                                    + Array(repeating: ReplayStep(move: -1, dwell: .milliseconds(600)), count: 14))
        case "burst":
            var steps = Array(repeating: ReplayStep(move: 1, dwell: .milliseconds(60), burst: true), count: 49)
            steps.append(ReplayStep(move: 1, dwell: .seconds(3), burst: true))
            steps += Array(repeating: ReplayStep(move: 1, dwell: s), count: 5)
            return ReplayScript(name: "burst", zoom: .fit, steps: steps)
        case "jump10":
            return jump("jump10", zoom: .fit)
        case "jump10-100":
            return jump("jump10-100", zoom: .actual)
        case "jumpfar":
            return jumpFar
        case "pingpong":
            let pair = [ReplayStep(move: 1, dwell: .milliseconds(400)), ReplayStep(move: -1, dwell: .milliseconds(400))]
            return ReplayScript(name: "pingpong", zoom: .actual, steps: Array(repeating: pair, count: 10).flatMap { $0 })
        default:
            return nil
        }
    }
}

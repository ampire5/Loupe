import CoreGraphics
import Foundation

/// How the image is sized in the view. `actual(1)` is 100 %: one image pixel per physical
/// screen pixel (spec §2).
public enum ZoomMode: Equatable, Sendable {
    case fit, fitWidth, fitHeight, fill
    case actual(Double)      // 1 = 100 %
    case free(Double)        // scale relative to fit
}

/// The transient zoom stretch past a zoom limit (M4b spec §3): the picture is drawn `factor` times larger (or smaller)
/// than `ViewTransform.scale` says, about `anchor` (view pixels), which stays where it is.
public struct ZoomStretch: Equatable, Sendable {
    public var factor: Double        // > 0; 1 = no stretch
    public var anchor: CGPoint       // view px

    public init(factor: Double, anchor: CGPoint) {
        self.factor = factor
        self.anchor = anchor
    }
}

/// The pure maths of the viewport: which part of the image is visible at which scale.
/// The position is stored as a *relative* centre (0…1 of the image) so it survives switching
/// to a photo of a different size and keeps its meaning when the window is resized.
/// View coordinates are physical pixels, origin top-left, y down. No AppKit or Metal here,
/// so the renderer and the app share one tested source of truth.
public struct ViewTransform: Equatable, Sendable {
    public var imageSize: CGSize     // image pixels
    public var viewSize: CGSize      // physical pixels
    public var mode: ZoomMode
    public var center: CGPoint       // relative 0…1 (spec §2)
    /// The rubber-band stretch past an image edge, in view pixels (M4a spec §2.1): the picture is drawn shifted
    /// by it. Transient state of a drag or bounce; only `withOffset` keeps it, every other operation returns zero.
    public var offset: CGVector = .zero
    /// The zoom rubber band past a zoom limit (M4b spec §3), modelled like `offset`: transient, only `withStretch` keeps
    /// it (and zeroes `offset`), `withOffset` and every other operation drop it. `scale`, `scaleLimits`, `mode`,
    /// `clamped` and `pannableAxes` do not see it; `drawnScale`, `visibleRect`, `viewPoint` and `imagePoint` do.
    public var stretch: ZoomStretch?
    /// Whether Fit may enlarge a photo smaller than the view (`fit-upscale`, M4b spec §4.3). When off, `fitScale` is
    /// at most 1: a small photo in Fit stands at 100 % in the middle. Every operation keeps it.
    public var fitUpscale: Bool

    public init(imageSize: CGSize, viewSize: CGSize, mode: ZoomMode = .fit, center: CGPoint = CGPoint(x: 0.5, y: 0.5),
                fitUpscale: Bool = true) {
        self.imageSize = imageSize
        self.viewSize = viewSize
        self.mode = mode
        self.center = center
        self.fitUpscale = fitUpscale
    }

    /// The view size as used for maths: a non-positive side (an NSView before its first layout
    /// has zero bounds) counts as 1 px, so every output stays finite instead of turning into NaN/inf.
    private var vw: Double { viewSize.width > 0 ? viewSize.width : 1 }
    private var vh: Double { viewSize.height > 0 ? viewSize.height : 1 }

    /// Largest scale at which the whole image is visible; also upscales images smaller than
    /// the view (`fitUpscale`; without it at most 1). Falls back to 1 for a degenerate image size, and a
    /// degenerate view size counts as 1 px, so nothing divides by zero.
    public var fitScale: Double {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let fitted = min(vw / imageSize.width, vh / imageSize.height)
        return fitUpscale ? fitted : min(fitted, 1)
    }

    /// View pixels per image pixel for the current mode, kept within the zoom limits
    /// `[min(fitScale, 1) × 0.25, 64]` so a huge photo can still be zoomed out to a thumbnail
    /// and a tiny one never shrinks to nothing.
    public var scale: Double { clampScale(rawScale) }

    /// The scale the picture is drawn at: `scale` times the stretch factor. The renderer and tile choice read this one;
    /// the zoom logic reads `scale`.
    public var drawnScale: Double { scale * (stretch?.factor ?? 1) }

    /// The zoom limits `scale` is kept within.
    public var scaleLimits: ClosedRange<Double> { min(fitScale, 1) * 0.25 ... 64 }

    /// The scale the mode asks for before the zoom limits, so zoom stops can tell a mode the limits
    /// would distort (a 10000 % stop, fit width of a tiny image) from one they leave alone.
    var rawScale: Double {
        switch mode {
        case .fit: return fitScale
        case .fitWidth: return imageSize.width > 0 ? vw / imageSize.width : 1
        case .fitHeight: return imageSize.height > 0 ? vh / imageSize.height : 1
        case .fill:
            return imageSize.width > 0 && imageSize.height > 0
                ? max(vw / imageSize.width, vh / imageSize.height) : 1
        case .actual(let k): return k
        case .free(let r): return r * fitScale
        }
    }

    /// The same transform with the centre pulled inside the image (spec §7): an axis on which
    /// the image fits in the view is centred, otherwise the view edge may not pass the image edge. Every way of moving
    /// the view keeps to it, a zoom at the pointer and a framing of the subject too (owner, 2026-10-28: past it the
    /// picture stood in an unnatural place off the middle).
    public var clamped: ViewTransform {
        var t = self
        let s = scale
        t.center = CGPoint(x: clampAxis(center.x, image: imageSize.width, view: vw, scale: s),
                           y: clampAxis(center.y, image: imageSize.height, view: vh, scale: s))
        return t
    }

    /// The part of the image shown in the view, in image pixels. It extends past the image
    /// when the image is smaller than the view on that axis.
    public var visibleRect: CGRect {
        let c = clamped
        let s = scale
        let w = vw / s, h = vh / s
        let plain = CGRect(x: c.center.x * imageSize.width - w / 2 - offset.dx / s,
                           y: c.center.y * imageSize.height - h / 2 - offset.dy / s,
                           width: w, height: h)
        guard let st = stretch else { return plain }
        // The view's corners map through the inverse stretch to a smaller or larger part of the plain view.
        let f = st.factor
        return CGRect(x: plain.minX + (st.anchor.x * (1 - 1 / f)) / s, y: plain.minY + (st.anchor.y * (1 - 1 / f)) / s,
                      width: w / f, height: h / f)
    }

    /// Whether a drag can move the picture: on some axis the image is larger than the view (half a
    /// pixel of slack, so a fit that rounds a hair over does not count).
    public var canPan: Bool { pannableAxes.x || pannableAxes.y }

    /// Per axis, whether the image is larger than the view (same half-pixel slack as `canPan`).
    public var pannableAxes: (x: Bool, y: Bool) {
        let s = scale
        return (imageSize.width * s > vw + 0.5, imageSize.height * s > vh + 0.5)
    }

    /// The same transform with the stretch set to `v` (view pixels); the zoom stretch is dropped.
    public func withOffset(_ v: CGVector) -> ViewTransform {
        var t = self
        t.offset = v
        t.stretch = nil
        return t
    }

    /// The same transform with the zoom stretch set to `s` (nil or a factor of 1 about any anchor draws as plain);
    /// the pan stretch is dropped.
    public func withStretch(_ s: ZoomStretch?) -> ViewTransform {
        var t = self
        t.offset = .zero
        t.stretch = s
        return t
    }

    /// The part of `delta` (view pixels) that `panned(by:)` cannot apply because the view edge meets the
    /// image edge. An axis on which the image fits cannot move, so all of its delta is left over.
    public func panLeftover(_ delta: CGVector) -> CGVector {
        let base = withOffset(.zero)
        let before = base.viewPoint(forImage: .zero), after = base.panned(by: delta).viewPoint(forImage: .zero)
        func left(_ d: Double, _ moved: Double, _ pannable: Bool) -> Double {
            if !pannable { return d }
            let r = d - moved
            return abs(r) < 1e-9 ? 0 : r
        }
        let axes = pannableAxes
        return CGVector(dx: left(delta.dx, after.x - before.x, axes.x), dy: left(delta.dy, after.y - before.y, axes.y))
    }

    public func viewPoint(forImage p: CGPoint) -> CGPoint {
        let c = clamped.center, s = scale
        let q = CGPoint(x: (p.x - c.x * imageSize.width) * s + vw / 2 + offset.dx,
                        y: (p.y - c.y * imageSize.height) * s + vh / 2 + offset.dy)
        guard let st = stretch else { return q }
        return CGPoint(x: st.anchor.x + st.factor * (q.x - st.anchor.x), y: st.anchor.y + st.factor * (q.y - st.anchor.y))
    }

    public func imagePoint(forView p: CGPoint) -> CGPoint {
        let c = clamped.center, s = scale
        var p = p
        if let st = stretch {
            p = CGPoint(x: st.anchor.x + (p.x - st.anchor.x) / st.factor, y: st.anchor.y + (p.y - st.anchor.y) / st.factor)
        }
        return CGPoint(x: (p.x - vw / 2 - offset.dx) / s + c.x * imageSize.width,
                       y: (p.y - vh / 2 - offset.dy) / s + c.y * imageSize.height)
    }

    /// Zooms to `s` with the image point `image` (image pixels) at `view` (view pixels), as near as `clamped` lets it:
    /// a gesture bringing the subject to the centre (`SubjectCentring`).
    public func zoomed(toScale s: Double, placing image: CGPoint, at view: CGPoint) -> ViewTransform {
        let newScale = clampScale(s)
        var t = self
        t.offset = .zero
        t.stretch = nil
        t.mode = .free(newScale / fitScale)
        t.center = CGPoint(x: relative(image.x - (view.x - vw / 2) / newScale, of: imageSize.width),
                           y: relative(image.y - (view.y - vh / 2) / newScale, of: imageSize.height))
        return t.clamped
    }

    /// Zooms to an absolute scale while the image point under `anchor` (view pixels) stays
    /// under it, so pinch and scroll-wheel zoom feel pinned to the cursor. The result is a
    /// `.free` mode relative to fit, which keeps it meaningful after a window resize. An axis on which the image is
    /// smaller than the view stays centred (`clamped`).
    public func zoomed(toScale s: Double, anchor: CGPoint) -> ViewTransform {
        zoomed(toScale: s, placing: imagePoint(forView: anchor), at: anchor)
    }

    /// Moves the image content by `delta` view pixels (it follows the finger: +dx moves the
    /// image right, so the visible rect moves left). An axis on which the image fits does not move.
    public func panned(by delta: CGVector) -> ViewTransform {
        let c = clamped.center, s = scale, axes = pannableAxes
        var t = self
        t.offset = .zero
        t.stretch = nil
        t.center = CGPoint(x: axes.x ? relative(c.x * imageSize.width - delta.dx / s, of: imageSize.width) : c.x,
                           y: axes.y ? relative(c.y * imageSize.height - delta.dy / s, of: imageSize.height) : c.y)
        return t.clamped
    }

    /// Keyboard zoom: the scale times √2 per step (two steps double it) about the view centre, within the
    /// zoom limits. The result is `.free`, like every zoom that is not one of the named modes.
    public func zoomedStep(_ steps: Int) -> ViewTransform {
        zoomed(toScale: scale * pow(2.0.squareRoot(), Double(steps)), anchor: CGPoint(x: vw / 2, y: vh / 2))
    }

    /// Keyboard pan: the visible area moves by `dx`, `dy` times the view size (positive = right / down),
    /// clamped like any pan.
    public func pannedByViewFraction(dx: Double, dy: Double) -> ViewTransform {
        panned(by: CGVector(dx: -dx * vw, dy: -dy * vh))
    }

    /// Fit ↔ 100 %: from 100 % back to Fit; from any other mode to 100 % with the image point under
    /// `anchor` (view pixels) staying under it.
    public func toggledFitActual(anchor: CGPoint) -> ViewTransform {
        if mode == .actual(1) { return withMode(.fit) }
        var t = zoomed(toScale: 1, anchor: anchor)
        t.mode = .actual(1)
        return t
    }

    /// Switches zoom mode, keeping the stored centre untouched. The centre is the *desired*
    /// relative position (spec §7); geometry reads `clamped.center`, so going fit -> 100 % again
    /// returns to where the user was instead of to a centre flattened by the fit view.
    public func withMode(_ m: ZoomMode) -> ViewTransform {
        var t = self
        t.offset = .zero
        t.stretch = nil
        t.mode = m
        return t
    }

    /// Next photo: keeps mode and the stored relative centre, so browsing at 100 % stays at the
    /// same spot, even across a small photo that is displayed centred.
    public func withImageSize(_ s: CGSize) -> ViewTransform {
        var t = self
        t.offset = .zero
        t.stretch = nil
        t.imageSize = s
        return t
    }

    /// `exif-orientation` toggled while the photo is shown (M3b spec §2.1): it is laid out at `newSize` now (its sides
    /// swapped, or turned in place), so the zoom mode stays and the centre goes back to the middle; the old relative
    /// centre would name another spot of the turned picture.
    public func reoriented(to newSize: CGSize) -> ViewTransform {
        var t = self
        t.offset = .zero
        t.stretch = nil
        t.imageSize = newSize
        t.center = CGPoint(x: 0.5, y: 0.5)
        return t
    }

    /// `fit-upscale` set to `on` for the photo on screen (M4b spec §4.3): the named modes take the new Fit, but a free
    /// zoom keeps the scale it draws at; its ratio to `fitScale` is converted, or toggling the flag would rescale a
    /// small photo the user zoomed. The zoom limits do not move (`min(fitScale, 1)` is the same either way).
    public func withFitUpscale(_ on: Bool) -> ViewTransform {
        var t = self
        t.offset = .zero
        t.stretch = nil
        t.fitUpscale = on
        if case .free(let r) = mode { t.mode = .free(r * fitScale / t.fitScale) }
        return t
    }

    /// Window resize: keeps mode and stored centre (clamping is applied when reading geometry). A free zoom keeps what
    /// `carry` (`keep-zoom-as`) says: `.share` its ratio to Fit, so the framing stays; `.scale` the scale it draws at;
    /// `.screen` the share of the view it covers. A view not laid out yet (a zero side) has nothing to keep.
    public func withViewSize(_ s: CGSize, carry: ZoomCarry = .share) -> ViewTransform {
        var t = self
        t.offset = .zero
        t.stretch = nil
        t.viewSize = s
        guard carry != .share, viewSize.width > 0, viewSize.height > 0 else { return t }
        return t.carryingZoom(from: self, carry)
    }

    /// The share of the view the picture covers (0…1, smart zoom spec §1): its on-screen rect clipped to the view, by
    /// area, at `scale` (the transient offset and stretch aside).
    /// Past Fill the picture covers the whole view, and the share goes on as its area over Fill's (owner's report: it
    /// stopped at 100 %, so every zoom past Fill showed `Screen 100 %` and the next photo opened at Fill).
    public var screenShare: Double {
        let s = scale, fill = fillScale
        guard s <= fill else { return (s / fill) * (s / fill) }
        return min(imageSize.width * s, vw) * min(imageSize.height * s, vh) / (vw * vh)
    }

    /// The scale at which the picture covers the view, both sides at least the view's.
    private var fillScale: Double {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return max(vw / imageSize.width, vh / imageSize.height)
    }

    /// The scale at which this transform's image covers `share` of the view, before the zoom limits. The covered area
    /// grows with the scale until Fill, so it is inverted piece by piece: both sides inside the view, then the side that
    /// fits first full and the other growing, then past Fill by the area (`screenShare`).
    public func scaleCovering(screenShare share: Double) -> Double {
        let w = Double(imageSize.width), h = Double(imageSize.height)
        guard w > 0, h > 0 else { return 1 }
        guard share < 1 else { return max(vw / w, vh / h) * share.squareRoot() }   // past Fill: by the area
        let both = (max(share, 0) * vw * vh / (w * h)).squareRoot()
        if both <= min(vw / w, vh / h) { return both }
        return vw / w <= vh / h ? share * vh / h : share * vw / w
    }

    /// This transform with a free zoom carried over from `old` (the previous photo, or this one at another view size)
    /// by `carry`: `.scale` keeps the scale `old` drew at; `.share` keeps the share of the picture's area in view, so
    /// a photo of the same pixel count keeps the scale whichever way it is turned (its ratio to Fit would change with
    /// the orientation), and one of four times the pixels takes twice the scale; `.screen` keeps the share of the view
    /// the picture covers (`screenShare`), so the empty space stays, cutting a photo of another shape where needed.
    /// Only a free zoom moves: Fit, the fit-family and `actual` are named modes and stay as they are.
    public func carryingZoom(from old: ViewTransform, _ carry: ZoomCarry) -> ViewTransform {
        guard case .free = old.mode, case .free = mode else { return self }
        var target = old.scale
        if carry == .screen {
            target = scaleCovering(screenShare: old.screenShare)
        } else if carry == .share {
            let before = Double(old.imageSize.width * old.imageSize.height)
            let after = Double(imageSize.width * imageSize.height)
            if before > 0, after > 0 { target *= (before / after).squareRoot() }
        }
        var t = self
        t.mode = .free(target / fitScale)
        return t
    }

    /// `v` image pixels as a 0…1 fraction of `side`; 0.5 for an empty image so nothing is NaN/inf.
    private func relative(_ v: Double, of side: Double) -> Double {
        side > 0 ? v / side : 0.5
    }

    /// Clamps to the zoom limits. `.free` stores `scale / fitScale`, and multiplying back can land
    /// an ulp off a limit, so a value that close to a limit snaps onto it exactly.
    private func clampScale(_ raw: Double) -> Double {
        let lo = scaleLimits.lowerBound, hi = scaleLimits.upperBound
        if abs(raw - hi) <= hi * 1e-12 { return hi }
        if abs(raw - lo) <= lo * 1e-12 { return lo }
        return min(max(raw, lo), hi)
    }

    private func clampAxis(_ c: Double, image: Double, view: Double, scale: Double) -> Double {
        let scaled = image * scale
        if scaled <= view { return 0.5 }
        let half = view / 2
        return min(max(c, half / scaled), 1 - half / scaled)
    }
}

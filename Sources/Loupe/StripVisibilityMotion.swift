import AppKit
import QuartzCore
import SlotModel

/// One visual transition, shared by the thumbnail row and its sibling tool capsule. AppKit keeps their layout.
@MainActor enum StripVisibilityMotion {
    static let key = "strip-visibility"
    private static let travel: CGFloat = -16

    struct State {
        let opacity: Float
        let y: CGFloat
    }

    static func state(of view: NSView, enteringFromEdge: Bool) -> State {
        if let layer = view.layer, layer.animation(forKey: key) != nil, let live = layer.presentation() {
            return State(opacity: live.opacity, y: live.transform.m42)
        }
        return State(opacity: Float(view.alphaValue), y: enteringFromEdge ? travel : 0)
    }

    static func animate(_ view: NSView, from state: State, shown: Bool, slides: Bool, duration: TimeInterval,
                        completion: (@MainActor @Sendable () -> Void)? = nil) {
        view.layer?.removeAnimation(forKey: key)
        guard let layer = view.layer, view.window != nil, duration > 0 else { completion?(); return }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let time = reduceMotion ? min(duration, SlotMotion.fade) : duration
        let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = state.opacity
        fade.toValue = shown ? 1 : 0
        fade.duration = time
        fade.timingFunction = curve
        let motion = CAAnimationGroup()
        motion.animations = [fade]
        motion.duration = time
        if slides && !reduceMotion {
            let slide: CABasicAnimation
            if shown {
                let spring = CASpringAnimation(keyPath: "transform.translation.y")
                let scale = SlotMotion.duration / time
                spring.mass = SlotMotion.mass
                spring.stiffness = SlotMotion.stiffness * scale * scale
                spring.damping = SlotMotion.damping * scale
                slide = spring
            } else {
                slide = CABasicAnimation(keyPath: "transform.translation.y")
                slide.timingFunction = curve
            }
            slide.fromValue = state.y
            slide.toValue = shown ? 0 : travel
            slide.duration = time
            motion.animations?.append(slide)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { completion?() }
        }
        layer.add(motion, forKey: key)
        CATransaction.commit()
    }
}

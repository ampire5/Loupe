public enum GrainStyle: String, CaseIterable, Sendable {
    case off, white, fine, soft, av1, particles
}

public enum GrainStage: String, CaseIterable, Sendable {
    case before, after
}

/// Nonadaptive, display-only grain. Amount is approximate encoded RGB8 RMS;
/// Size is in source pixels before upscale, physical output pixels after upscale.
/// The source field is filtered separately; MetalFX never processes the noise.
public struct GrainSettings: Equatable, Sendable {
    public var style: GrainStyle
    public var amount: Double
    public var size: Double
    public var stage: GrainStage
    public var active: Bool { style != .off && amount.isFinite && amount > 0 && size.isFinite && size > 0 }

    public init(style: GrainStyle = .off, amount: Double = 0.65, size: Double = 1, stage: GrainStage = .before) {
        self.style = style; self.amount = amount; self.size = size; self.stage = stage
    }
    public init(config: Config) { self.init(style: config.grain, amount: config.grainAmount, size: config.grainSize, stage: config.grainStage) }
}

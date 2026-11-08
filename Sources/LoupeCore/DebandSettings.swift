public enum DebandMode: String, CaseIterable, Sendable {
    case off, single, double, adaptive, reference, window
}

/// Display-only debanding before scaling. Threshold is in encoded RGB8 code
/// levels; radius is in pixels of the selected input level. Strong filtering can remove fine detail.
public struct DebandSettings: Equatable, Sendable {
    public var mode: DebandMode
    public var strength: Double
    public var threshold: Double
    public var radius: Double
    public var iterations: Int
    public var textureProtection: Double

    public var active: Bool {
        mode != .off && strength.isFinite && strength > 0 && threshold.isFinite
            && radius.isFinite && textureProtection.isFinite
    }

    public init(mode: DebandMode = .off, strength: Double = 0.5, threshold: Double = 9,
                radius: Double = 24, iterations: Int = 1, textureProtection: Double = 1) {
        self.mode = mode
        self.strength = strength
        self.threshold = threshold
        self.radius = radius
        self.iterations = iterations
        self.textureProtection = textureProtection
    }

    public init(config: Config) {
        self.init(mode: config.deband, strength: config.debandStrength, threshold: config.debandThreshold,
                  radius: config.debandRadius, iterations: config.debandIterations,
                  textureProtection: config.debandTextureProtection)
    }
}

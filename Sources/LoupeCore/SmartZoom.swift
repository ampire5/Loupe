import Foundation

public enum SmartZoomMode: String, CaseIterable, Sendable {
    case off, pan, frame
    public var title: String {
        switch self { case .off: return "Manual"; case .pan: return "Pan only"; case .frame: return "Auto framing" }
    }
}

/// Power remembers the last enabled behavior; first entry is Auto.
public struct SmartZoomState: Equatable, Sendable {
    public private(set) var mode = SmartZoomMode.off
    public private(set) var lastEnabled = SmartZoomMode.frame
    public static let preferenceKey = "loupe.last-smartzoom-state"
    public init() {}
    public init(restoring values: [String: String]?) {
        mode = values?["mode"].flatMap(SmartZoomMode.init(rawValue:)) ?? .off
        let enabled = values?["last-enabled"].flatMap(SmartZoomMode.init(rawValue:)) ?? .frame
        lastEnabled = enabled == .off ? .frame : enabled
        if mode != .off { lastEnabled = mode }
    }
    public var rememberedValues: [String: String] { ["mode": mode.rawValue, "last-enabled": lastEnabled.rawValue] }
    public enum Effect: Equatable, Sendable { case none, hold, reframe }
    @discardableResult public mutating func select(_ mode: SmartZoomMode) -> Effect {
        let previous = self.mode
        self.mode = mode
        if mode != .off { lastEnabled = mode }
        guard previous != mode else { return .none }
        return mode == .frame || mode == .pan && previous == .off ? .reframe : .hold
    }
    /// SmartZoom owns the analysis it needs; Off never schedules subject analysis.
    public func analysis(_ configured: SubjectAnalysis) -> SubjectAnalysis {
        mode == .off ? .off : (configured == .off ? .onDemand : configured)
    }
    public mutating func togglePower() { select(mode == .off ? lastEnabled : .off) }
    public mutating func activateAuto() { select(.frame) }
}

/// Pending detection belongs to an input revision as well as a photo. Any manual gesture invalidates it.
public struct SmartZoomRequest: Equatable, Sendable {
    public var photo: URL
    public var revision: UInt64
    public init(photo: URL, revision: UInt64) { self.photo = photo; self.revision = revision }
    public func matches(photo: URL?, revision: UInt64, enabled: Bool) -> Bool {
        enabled && photo == self.photo && revision == self.revision
    }
}

/// Observing a finer image level or a manually changed transform is not a new arrival.
public struct SmartZoomArrival: Sendable {
    private var observed: URL?
    public init() {}
    public mutating func observe(_ photo: URL) -> Bool {
        guard photo != observed else { return false }
        observed = photo
        return true
    }
}

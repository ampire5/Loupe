import Foundation
import SlotModel

/// Loupe owns its config vocabulary; the shared host knows only opaque tab IDs.
public enum FolderSlotSettings {
    public static let folders = SlotTabID(rawValue: "folders")
    public static let smartzoom = SlotTabID(rawValue: "smartzoom")
    public static let known: Set<SlotTabID> = [folders, smartzoom]
    public static var defaults: [SlotEdge: SlotConfiguration] {
        Dictionary(uniqueKeysWithValues: SlotEdge.allCases.map {
            ($0, SlotConfiguration(tabs: $0 == .right ? [folders] : [], size: $0 == .bottom ? 240 : 400))
        })
    }
    /// A saved configuration may name the singleton in several slots. The first keeps it, like FrameScrub.
    public static func normalized(_ settings: [SlotEdge: SlotConfiguration]) -> [SlotEdge: SlotConfiguration] {
        var result = settings, taken = Set<SlotTabID>()
        for edge in SlotEdge.allCases {
            guard var state = result[edge] else { continue }
            state.tabs = state.tabs.filter { known.contains($0) && taken.insert($0).inserted }
            result[edge] = state
        }
        return result
    }
    public static func parse(_ text: String, edge: SlotEdge) -> SlotConfiguration? {
        let parts = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 7 else { return nil }
        let tabs = parts[0] == "empty" ? [] : parts[0].components(separatedBy: "+").map { SlotTabID(rawValue: $0) }
        guard tabs.allSatisfy(known.contains), Set(tabs).count == tabs.count,
              let mode = SlotMode(rawValue: parts[1]), let backdrop = SlotBackdrop(rawValue: parts[2]),
              let hide = SlotAutoHide(rawValue: parts[3]), let size = Int(parts[4]),
              ["shown", "hidden"].contains(parts[5]), let reveal = SlotReveal(rawValue: parts[6]) else { return nil }
        return SlotConfiguration(tabs: tabs, mode: mode, backdrop: backdrop,
                                 autoHide: hide, size: size, shown: parts[5] == "shown", reveal: reveal).clamped(for: edge)
    }
    public static func text(_ state: SlotConfiguration) -> String {
        [state.tabs.isEmpty ? "empty" : state.tabs.map(\.rawValue).joined(separator: "+"), state.mode.rawValue, state.backdrop.rawValue,
         state.autoHide.rawValue, String(state.size), state.shown ? "shown" : "hidden", state.reveal.rawValue].joined(separator: ", ")
    }
}

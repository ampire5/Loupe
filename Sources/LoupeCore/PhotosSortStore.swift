import Foundation
import HomeScreenModel

/// Collection-specific source ordering shared by grids and viewer tabs. No filesystem settings are consulted.
@MainActor public final class PhotosSortStore {
    public static let shared = PhotosSortStore(defaults: .standard)
    private var choices: [String: BrowserSort] = [:]
    private let defaults: UserDefaults?
    private static let preferenceKey = "photos.collection-sorts.v1"

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        for (source, text) in defaults?.dictionary(forKey: Self.preferenceKey) ?? [:] {
            if let text = text as? String, let sort = BrowserSort(text: text), sort.key == .name || sort.key == .date {
                choices[source] = sort
            }
        }
    }

    public func sort(for source: String, default fallback: BrowserSort = BrowserSort(key: .date, ascending: true)) -> BrowserSort {
        choices[source] ?? fallback
    }

    public func setSort(_ sort: BrowserSort, for source: String) {
        guard sort.key == .name || sort.key == .date else { return }
        guard choices[source] != sort else { return }
        choices[source] = sort
        defaults?.set(choices.mapValues(\.text), forKey: Self.preferenceKey)
    }
}

import Foundation

@MainActor public enum WebImagesPreferences {
    public static let changed = Notification.Name("local.loupe.webImagesPreferencesChanged")
    public static let originalPrefetchChanged = Notification.Name("local.loupe.webImagesOriginalPrefetchChanged")
    public static let suggestedServer = "http://127.0.0.1:8888"
    private static let serverKey = "webImages.server"
    private static let folderKey = "webImages.saveFolder"
    private static let queryKey = "webImages.query"
    private static let minimumResolutionKey = "webImages.minimumResolution"
    nonisolated public static let originalPrefetchDepthRange = 1...3
    nonisolated public static let originalPrefetchConcurrencyRange = 1...max(1, min(3, Machine.physicalCores / 4))
    private static let preloadOriginalsKey = "webImages.preloadOriginals"
    private static let originalPrefetchDepthKey = "webImages.originalPrefetchDepth"
    private static let originalPrefetchConcurrencyKey = "webImages.originalPrefetchConcurrency"

    public static var server: URL? { UserDefaults.standard.string(forKey: serverKey).flatMap(SearXNGClient.serverURL) }
    public static var saveFolder: URL? { UserDefaults.standard.url(forKey: folderKey) }

    public static var query: String {
        get { UserDefaults.standard.string(forKey: queryKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: queryKey) }
    }

    public static var minimumResolution: WebImageMinimumResolution {
        get { UserDefaults.standard.string(forKey: minimumResolutionKey).flatMap(WebImageMinimumResolution.init(rawValue:)) ?? .any }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: minimumResolutionKey) }
    }

    public static var preloadOriginals: Bool {
        get { UserDefaults.standard.bool(forKey: preloadOriginalsKey) }
        set {
            guard newValue != preloadOriginals else { return }
            UserDefaults.standard.set(newValue, forKey: preloadOriginalsKey)
            NotificationCenter.default.post(name: originalPrefetchChanged, object: nil)
        }
    }

    public static var originalPrefetchDepth: Int {
        get { boundedOriginalPrefetchDepth(UserDefaults.standard.integer(forKey: originalPrefetchDepthKey)) }
        set {
            let depth = boundedOriginalPrefetchDepth(newValue)
            guard depth != originalPrefetchDepth else { return }
            UserDefaults.standard.set(depth, forKey: originalPrefetchDepthKey)
            NotificationCenter.default.post(name: originalPrefetchChanged, object: nil)
        }
    }

    public static var originalPrefetchConcurrency: Int {
        get { boundedOriginalPrefetchConcurrency(UserDefaults.standard.integer(forKey: originalPrefetchConcurrencyKey)) }
        set {
            let concurrency = boundedOriginalPrefetchConcurrency(newValue)
            guard concurrency != originalPrefetchConcurrency else { return }
            UserDefaults.standard.set(concurrency, forKey: originalPrefetchConcurrencyKey)
            NotificationCenter.default.post(name: originalPrefetchChanged, object: nil)
        }
    }

    nonisolated public static func boundedOriginalPrefetchDepth(_ depth: Int) -> Int {
        min(max(depth, originalPrefetchDepthRange.lowerBound), originalPrefetchDepthRange.upperBound)
    }

    nonisolated public static func boundedOriginalPrefetchConcurrency(_ concurrency: Int) -> Int {
        min(max(concurrency, originalPrefetchConcurrencyRange.lowerBound), originalPrefetchConcurrencyRange.upperBound)
    }

    public static func setServer(_ url: URL?) {
        guard server != url else { return }
        UserDefaults.standard.set(url?.absoluteString, forKey: serverKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    public static func setSaveFolder(_ url: URL?) {
        UserDefaults.standard.set(url, forKey: folderKey)
    }

    public static func selection(for server: URL) -> WebImageEngineSelection {
        UserDefaults.standard.data(forKey: engineKey(server))
            .flatMap { try? JSONDecoder().decode(WebImageEngineSelection.self, from: $0) } ?? .serverDefaults
    }

    public static func setSelection(_ selection: WebImageEngineSelection, for server: URL) {
        UserDefaults.standard.set(try? JSONEncoder().encode(selection), forKey: engineKey(server))
    }

    private static func engineKey(_ server: URL) -> String { "webImages.engines." + server.absoluteString }
}

import Foundation
import Observation

public enum WebImageMinimumResolution: String, CaseIterable, Sendable {
    case any, hd, fullHD, ultraHD

    func includes(_ size: PixelSize?) -> Bool {
        let minimum: PixelSize
        switch self {
        case .any: return true
        case .hd: minimum = PixelSize(width: 1280, height: 720)
        case .fullHD: minimum = PixelSize(width: 1920, height: 1080)
        case .ultraHD: minimum = PixelSize(width: 3840, height: 2160)
        }
        guard let size else { return false }
        return max(size.width, size.height) >= minimum.width && min(size.width, size.height) >= minimum.height
    }
}

/// One submitted query. The grid and any viewer opened from it can retain this sequence independently.
@MainActor @Observable public final class WebImageSearch {
    public let id = UUID()
    public let query: String
    public let selection: WebImageEngineSelection
    public let minimumResolution: WebImageMinimumResolution
    public private(set) var results: [WebImageResult] = []
    public private(set) var engineErrors: [String] = []
    public private(set) var error: String?
    public private(set) var loading = false
    public private(set) var hasMore = true
    public var hasLoadedPage: Bool { nextPage > 1 }
    @ObservationIgnored private let client: SearXNGClient
    @ObservationIgnored private var seen: Set<URL> = []
    @ObservationIgnored private var nextPage = 1
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var request: Task<Void, Never>?

    public init(client: SearXNGClient, query: String, selection: WebImageEngineSelection,
                minimumResolution: WebImageMinimumResolution = .any) {
        self.client = client
        self.query = query
        self.selection = selection
        self.minimumResolution = minimumResolution
    }

    /// Returns the in-flight request when grid prefetch and a navigation step ask for the same page.
    @discardableResult public func loadNext(retry: Bool = false) -> Task<Void, Never>? {
        if let request { return request }
        guard hasMore, retry || error == nil else { return nil }
        error = nil
        loading = true
        let id = UUID(), page = nextPage
        requestID = id
        let task = Task { [weak self, client, query, selection] in
            let response: Result<SearXNGImagePage, any Error>
            do { response = .success(try await client.searchImages(query: query, selection: selection, page: page)) }
            catch { response = .failure(error) }
            guard let self, !Task.isCancelled, requestID == id else { return }
            switch response {
            case .success(let page):
                let added = page.results.filter { seen.insert($0.id).inserted }
                // An outage with zero results is retryable. An ordinary empty or repeated page ends pagination.
                if page.results.isEmpty, !page.engineErrors.isEmpty {
                    error = page.engineErrors.joined(separator: "\n")
                } else {
                    hasMore = !added.isEmpty
                    results.append(contentsOf: added.filter { minimumResolution.includes($0.resolution) })
                    nextPage += 1
                }
                engineErrors = page.engineErrors
            case .failure(let failure):
                error = failure.localizedDescription
            }
            request = nil
            requestID = nil
            loading = false
        }
        request = task
        return task
    }

    public func cancel() {
        request?.cancel()
        request = nil
        requestID = nil
        loading = false
    }
}

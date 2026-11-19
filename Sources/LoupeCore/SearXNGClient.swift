import Foundation

public struct SearXNGImageEngine: Equatable, Sendable {
    public let name: String
    public let enabled: Bool
}

public enum WebImageEngineSelection: Codable, Equatable, Sendable {
    case serverDefaults
    case explicit([String])
}

public struct WebImageResult: Equatable, Identifiable, Sendable {
    public let originalURL: URL
    public let thumbnailURL: URL?
    public let sourceURL: URL?
    public let title: String
    public let engines: [String]
    public let resolution: PixelSize?
    public var id: URL { originalURL }
}

public struct SearXNGImagePage: Sendable {
    public let results: [WebImageResult]
    public let engineErrors: [String]
}

public struct SearXNGClient: Sendable {
    public enum RequestError: LocalizedError, Equatable {
        case invalidServer, noEngines, jsonForbidden, http(Int), invalidResponse, responseTooLarge

        public var errorDescription: String? {
            switch self {
            case .invalidServer: "Enter an HTTP or HTTPS SearXNG server address."
            case .noEngines: "Choose an available engine or Server Defaults."
            case .jsonForbidden: "SearXNG returned HTTP 403. Check access and enable JSON in its search formats."
            case .http(let status): "The server returned HTTP \(status)."
            case .invalidResponse: "The server did not return a valid SearXNG response."
            case .responseTooLarge: "The search response exceeded 8 MB."
            }
        }
    }

    public typealias Transport = @Sendable (URL) async throws -> (Data, Int)
    private let baseURL: URL
    private let transport: Transport

    public init(baseURL: URL, session: URLSession = .shared) {
        self.init(baseURL: baseURL) { url in
            var request = URLRequest(url: url, timeoutInterval: 25)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw RequestError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { return (Data(), http.statusCode) }
            let limit = 8 * 1024 * 1024
            guard response.expectedContentLength <= limit else { throw RequestError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw RequestError.responseTooLarge }
                data.append(byte)
            }
            return (data, http.statusCode)
        }
    }

    init(baseURL: URL, transport: @escaping Transport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public static func serverURL(_ text: String) -> URL? {
        guard let url = httpURL(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    public func imageEngines() async throws -> [SearXNGImageEngine] {
        let config: Configuration = try await request("config")
        return config.engines.filter { $0.categories.contains("images") }
            .map { .init(name: $0.name, enabled: $0.enabled) }
    }

    public func searchImages(query: String, selection: WebImageEngineSelection, page: Int) async throws -> SearXNGImagePage {
        var items = [URLQueryItem(name: "q", value: query), .init(name: "format", value: "json"),
                     .init(name: "pageno", value: String(page))]
        switch selection {
        case .serverDefaults: items.append(.init(name: "categories", value: "images"))
        case .explicit(let engines):
            guard !engines.isEmpty else { throw RequestError.noEngines }
            items.append(.init(name: "engines", value: engines.joined(separator: ",")))
        }
        let payload: SearchResponse = try await request("search", items: items)
        let results = payload.results.compactMap { raw -> WebImageResult? in
            guard let original = resourceURL(raw.img_src) else { return nil }
            return .init(originalURL: original, thumbnailURL: resourceURL(raw.thumbnail_src),
                         sourceURL: resourceURL(raw.url), title: raw.title ?? "", engines: raw.engines ?? [],
                         resolution: raw.resolution?.size)
        }
        let errors = (payload.unresponsive_engines ?? []).map { $0.joined(separator: ": ") }
        return .init(results: results, engineErrors: errors)
    }

    private func request<T: Decodable>(_ path: String, items: [URLQueryItem] = []) async throws -> T {
        guard Self.serverURL(baseURL.absoluteString) != nil,
              var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw RequestError.invalidServer }
        if !items.isEmpty {
            components.queryItems = items
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw RequestError.invalidServer }
        let (data, status) = try await transport(url)
        try Task.checkCancellation()
        if path == "search", status == 403 { throw RequestError.jsonForbidden }
        guard (200..<300).contains(status) else { throw RequestError.http(status) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw RequestError.invalidResponse }
    }

    private func resourceURL(_ text: String?) -> URL? {
        guard let text, !text.isEmpty else { return nil }
        // The scheme of the search server does not describe the result's host.
        if text.hasPrefix("//") { return Self.httpURL("https:" + text) }
        return Self.httpURL(text)
    }

    static func httpURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private struct Configuration: Decodable {
        struct Engine: Decodable {
            let name: String
            let categories: [String]
            let enabled: Bool
        }
        let engines: [Engine]
    }

    private struct Resolution: Decodable {
        let size: PixelSize?

        init(from decoder: any Decoder) throws {
            let text = try? decoder.singleValueContainer().decode(String.self)
            size = text.flatMap(Self.parse)
        }

        private static func parse(_ text: String) -> PixelSize? {
            let parts = text.split(omittingEmptySubsequences: false) { $0 == "×" || $0 == "x" || $0 == "X" }
            guard parts.count == 2,
                  let width = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)), width > 0,
                  let height = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)), height > 0
            else { return nil }
            return PixelSize(width: width, height: height)
        }
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let img_src: String?
            let thumbnail_src: String?
            let url: String?
            let title: String?
            let engines: [String]?
            let resolution: Resolution?
        }
        let results: [Result]
        let unresponsive_engines: [[String]]?
    }
}

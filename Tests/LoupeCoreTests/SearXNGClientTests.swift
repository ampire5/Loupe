import Foundation
import Testing
@testable import LoupeCore

@Suite struct SearXNGClientTests {
    private let base = URL(string: "https://search.example/tools/searx/")!

    @Test func explicitSearchKeepsBasePathAndUsesOnlyTheRequestedEngines() async throws {
        let localServer = URL(string: "http://localhost:8888/tools/searx/")!
        let client = SearXNGClient(baseURL: localServer) { url in
            #expect(url.scheme == "http")
            #expect(url.path == "/tools/searx/search")
            let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(parameters.contains(.init(name: "q", value: "рыжая лиса & cub")))
            #expect(parameters.contains(.init(name: "pageno", value: "2")))
            #expect(parameters.contains(.init(name: "engines", value: "engine one,engine two")))
            #expect(!parameters.contains { $0.name == "categories" })
            return (Data("""
                {"results":[{"img_src":"//a.example/original","thumbnail_src":"//a.example/thumb",
                "url":"https://a.example/article","title":"Fox","engines":["engine one"]},
                {"url":"https://a.example/other"},{"img_src":"file:///tmp/example"}],
                "unresponsive_engines":[["engine two","timeout"]]}
                """.utf8), 200)
        }
        let page = try await client.searchImages(query: "рыжая лиса & cub", selection: .explicit(["engine one", "engine two"]), page: 2)
        let result = try #require(page.results.first)
        #expect(page.results.count == 1)
        #expect(result.originalURL.absoluteString == "https://a.example/original")
        #expect(result.thumbnailURL?.absoluteString == "https://a.example/thumb")
        #expect(result.sourceURL?.absoluteString == "https://a.example/article")
        #expect(page.engineErrors == ["engine two: timeout"])
    }

    @Test func discoversDisabledImageEnginesAndReportsForbiddenJSON() async throws {
        let client = SearXNGClient(baseURL: base) { url in
            if url.lastPathComponent == "config" {
                return (Data("""
                    {"engines":[{"name":"fox","categories":["images"],"enabled":false},
                    {"name":"news","categories":["news"],"enabled":true}]}
                    """.utf8), 200)
            }
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "categories", value: "images")) == true)
            return (Data(), 403)
        }
        #expect(try await client.imageEngines() == [.init(name: "fox", enabled: false)])
        await #expect(throws: SearXNGClient.RequestError.jsonForbidden) {
            try await client.searchImages(query: "fox", selection: .serverDefaults, page: 1)
        }
    }
}

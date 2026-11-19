import Foundation
import Testing
@testable import LoupeCore

@MainActor @Suite struct WebImagesSearchTests {
    @Test func paginationPreservesOrderAndStopsAtRepeats() async throws {
        let client = SearXNGClient(baseURL: URL(string: "https://search.example")!) { url in
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageno" }?.value
            let names = switch page { case "1": ["one", "two"]; case "2": ["two", "three"]; default: ["three"] }
            let items = names.map { #"{"img_src":"https://images.example/\#($0).jpg","title":"\#($0)"}"# }
            return (Data(("{" + #""results":["# + items.joined(separator: ",") + "]}").utf8), 200)
        }
        let search = WebImageSearch(client: client, query: "fox", selection: .serverDefaults)
        #expect(search.results.isEmpty)
        await search.loadNext()?.value
        #expect(search.results.map(\.title) == ["one", "two"])
        await search.loadNext()?.value
        #expect(search.results.map(\.title) == ["one", "two", "three"])
        await search.loadNext()?.value
        #expect(!search.hasMore)
        #expect(search.loadNext() == nil)
    }

    @Test func minimumResolutionKeepsPagingPastNonmatchingResults() async {
        let client = SearXNGClient(baseURL: URL(string: "https://search.example")!) { url in
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageno" }?.value
            let json = switch page {
            case "1":
                """
                {"results":[{"img_src":"https://images.example/wide.jpg","resolution":"3840 x 700"},
                {"img_src":"https://images.example/unknown.jpg","resolution":""},
                {"img_src":"https://images.example/invalid.jpg","resolution":1234}]}
                """
            case "2":
                """
                {"results":[{"img_src":"https://images.example/portrait.jpg","resolution":"1080×1920"},
                {"img_src":"https://images.example/landscape.jpg","resolution":" 2560 x 1440 "},
                {"img_src":"https://images.example/portrait.jpg","resolution":"1080×1920"}]}
                """
            default: #"{"results":[]}"#
            }
            return (Data(json.utf8), 200)
        }
        let search = WebImageSearch(client: client, query: "fox", selection: .serverDefaults, minimumResolution: .fullHD)
        await search.loadNext()?.value
        #expect(search.error == nil)
        #expect(search.results.isEmpty)
        #expect(search.hasMore)
        await search.loadNext()?.value
        #expect(search.results.map { $0.originalURL.lastPathComponent } == ["portrait.jpg", "landscape.jpg"])
        #expect(search.results.map(\.resolution) == [PixelSize(width: 1080, height: 1920), PixelSize(width: 2560, height: 1440)])
        await search.loadNext()?.value
        #expect(!search.hasMore)
    }

    @Test func failedPageCanBeRetriedWithoutDiscardingResults() async throws {
        let attempts = Attempts()
        let client = SearXNGClient(baseURL: URL(string: "https://search.example")!) { _ in
            switch await attempts.next() {
            case 1: (Data(#"{"results":[{"img_src":"https://images.example/one.jpg"}]}"#.utf8), 200)
            case 2: (Data(), 503)
            default: (Data(#"{"results":[{"img_src":"https://images.example/two.jpg"}]}"#.utf8), 200)
            }
        }
        let search = WebImageSearch(client: client, query: "fox", selection: .serverDefaults)
        await search.loadNext()?.value
        await search.loadNext()?.value
        #expect(search.error != nil)
        #expect(search.results.count == 1)
        #expect(search.loadNext() == nil)
        await search.loadNext(retry: true)?.value
        #expect(search.error == nil)
        #expect(search.results.count == 2)
    }

    @Test func canceledResponseCannotPublish() async throws {
        let gate = ResponseGate()
        let client = SearXNGClient(baseURL: URL(string: "https://search.example")!) { _ in
            await gate.response()
        }
        let search = WebImageSearch(client: client, query: "fox", selection: .serverDefaults)
        let request = try #require(search.loadNext())
        await gate.waitUntilRequested()
        search.cancel()
        await gate.supply()
        await request.value
        #expect(search.results.isEmpty)
        #expect(!search.loading)
    }

    private actor Attempts {
        var count = 0
        func next() -> Int { count += 1; return count }
    }

    private actor ResponseGate {
        var waiting: CheckedContinuation<(Data, Int), Never>?
        var requested: CheckedContinuation<Void, Never>?

        func response() async -> (Data, Int) {
            await withCheckedContinuation { waiting = $0; requested?.resume(); requested = nil }
        }

        func waitUntilRequested() async {
            if waiting != nil { return }
            await withCheckedContinuation { requested = $0 }
        }

        func supply() {
            waiting?.resume(returning: (Data(#"{"results":[{"img_src":"https://images.example/one.jpg"}]}"#.utf8), 200))
            waiting = nil
        }
    }
}

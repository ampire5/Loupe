import Foundation
import Testing
@testable import Loupe

struct UpscaleLookaheadTests {
    @Test func followsTravelAndStopsAtPlaylistEnds() {
        let files = (0..<6).map { URL(fileURLWithPath: "/\($0).jpg") }
        #expect(UpscaleLookahead.urls(in: files, from: 1, direction: 1, depth: 3) == Array(files[2...4]))
        #expect(UpscaleLookahead.urls(in: files, from: 2, direction: -1, depth: 3) == [files[1], files[0]])
        #expect(UpscaleLookahead.urls(in: files, from: 5, direction: 1, depth: 3).isEmpty)
        #expect(UpscaleLookahead.urls(in: files, from: 2, direction: 1, depth: 0).isEmpty)
    }
}

import Foundation
import Testing
@testable import LoupeCore

/// The work ahead's subfolders of the cards in view (thumbs-ahead spec, stage 4): each card's entries made once when
/// its names come, an ask joining those of the cards in view in their order, up to a limit.
@Suite struct AheadSubfoldersTests {
    private static func loc(_ folder: String) -> ThumbnailLocation {
        ThumbnailLocation(volume: "test", folder: folder, name: "_")
    }

    @Test func askJoinsTheCardsInTheirOrder() throws {
        var ahead = AheadSubfolders()
        #expect(!ahead.has("/r/a"))
        ahead.set(AheadSubfolders.entries(["x", "y"], card: "/r/a", folder: URL(fileURLWithPath: "/r/a"),
                                          location: Self.loc("/r/a")), for: "/r/a")
        ahead.set(AheadSubfolders.entries(["z"], card: "/r/b", folder: URL(fileURLWithPath: "/r/b"), location: nil),
                  for: "/r/b")
        ahead.set(AheadSubfolders.entries([], card: "/r/c", folder: URL(fileURLWithPath: "/r/c"), location: nil),
                  for: "/r/c")
        #expect(ahead.has("/r/a") && ahead.has("/r/c"))
        let ids = ahead.ids(for: ["/r/b", "/r/missing", "/r/c", "/r/a"])
        #expect(ids.count == 3)
        let cards = try ids.map { try #require(ahead.card($0)) }
        #expect(cards.map(\.url.path) == ["/r/b/z", "/r/a/x", "/r/a/y"])
        #expect(cards.map(\.parent) == ["/r/b", "/r/a", "/r/a"])
        #expect(cards[1].location == Self.loc("/r/a").subfolder("x"))
        #expect(cards[1].parentLocation == Self.loc("/r/a"))
        #expect(cards[0].location == nil && cards[0].parentLocation == nil)
        #expect(cards[1].url.hasDirectoryPath)
        // An id the queue holds from before the folder changed finds nothing.
        #expect(ahead.card("/r/a/x") == nil)
        #expect(AheadSubfolders().card(ids[0]) == nil)
    }

    /// The total an ask sends is capped: the first cards' subfolders, the last card's cut where the limit falls.
    @Test func askIsCappedAtTheLimit() {
        var ahead = AheadSubfolders()
        for card in ["/r/a", "/r/b", "/r/c"] {
            let names = (0..<4).map { "s\($0)" }
            ahead.set(AheadSubfolders.entries(names, card: card, folder: URL(fileURLWithPath: card), location: nil),
                      for: card)
        }
        let ids = ahead.ids(for: ["/r/a", "/r/b", "/r/c"], limit: 6)
        #expect(ids.compactMap { ahead.card($0)?.url.path } ==
                ["/r/a/s0", "/r/a/s1", "/r/a/s2", "/r/a/s3", "/r/b/s0", "/r/b/s1"])
        #expect(ahead.ids(for: ["/r/a", "/r/b", "/r/c"]).count == 12)
        #expect(AheadSubfolders.limit == 1_000)
    }

    /// I4's measurement: the main thread's time per ask, the way it was (an entry per subfolder of every card in view
    /// made on every ask, and a dictionary of them) against the cards' entries made once and joined up to the limit.
    /// A synthetic tree of `cards` folders of `subfolders` empty subfolders each, made under LOUPE_AHEAD_BENCH (a
    /// scratch directory, removed after); the names are read from it once, as the store keeps them.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_AHEAD_BENCH"] != nil))
    func aheadAskBench() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOUPE_AHEAD_BENCH"]!)
            .appendingPathComponent("ahead-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let cards = 30, subfolders = 1_000, asks = 20
        for c in 0..<cards {
            for s in 0..<subfolders {
                try fm.createDirectory(at: root.appendingPathComponent("card\(c)/sub\(s)"),
                                       withIntermediateDirectories: true)
            }
        }
        let location = ThumbnailLocation(volume: "test", folder: root.path, name: "_")
        let ids = (0..<cards).map { root.appendingPathComponent("card\($0)").path }
        var names: [String: [String]] = [:]
        for id in ids { names[id] = ThumbnailStore.finderSorted(try fm.contentsOfDirectory(atPath: id)) }

        // Before: what `aheadCards` and `sendCovers` did on every ask.
        struct OldCard { var id: String; var parent: String; var url: URL; var location: ThumbnailLocation?
                         var parentLocation: ThumbnailLocation? }
        func oldAsk() -> Int {
            var list: [OldCard] = []
            for id in ids {
                let url = URL(fileURLWithPath: id), loc = location.subfolder(url.lastPathComponent)
                for name in names[id]! {
                    let sub = url.appendingPathComponent(name, isDirectory: true)
                    list.append(OldCard(id: sub.path, parent: id, url: sub, location: loc.subfolder(name),
                                        parentLocation: loc))
                }
            }
            let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return byID.count + list.map(\.id).count
        }
        // After: entries made once per card (off the main thread in the app), each ask joins the ids.
        var ahead = AheadSubfolders()
        let made = ContinuousClock.now
        for id in ids {
            let url = URL(fileURLWithPath: id)
            ahead.set(AheadSubfolders.entries(names[id]!, card: id, folder: url,
                                              location: location.subfolder(url.lastPathComponent)), for: id)
        }
        let madeTime = ContinuousClock.now - made
        func time(_ body: () -> Int) -> [Double] {
            (0..<asks).map { _ in
                let start = ContinuousClock.now
                _ = body()
                let d = ContinuousClock.now - start
                return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            }
        }
        let before = time(oldAsk).sorted(), after = time { ahead.ids(for: ids).count }.sorted()
        let uncapped = time { ahead.ids(for: ids, limit: .max).count }.sorted()
        print("ahead ask bench: \(cards) cards x \(subfolders) subfolders, \(asks) asks; median / max ms")
        print("  before (all entries every ask): \(before[asks / 2]) / \(before.last!)")
        print("  after, capped at \(AheadSubfolders.limit): \(after[asks / 2]) / \(after.last!)")
        print("  after, uncapped: \(uncapped[asks / 2]) / \(uncapped.last!)")
        print("  entries made once (all cards): \(madeTime)")
    }
}

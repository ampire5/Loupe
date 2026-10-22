import CoreGraphics
import Testing
@testable import LoupeCore

/// A browser's folder and zip cards (Task 4 review): the mosaics it made kept, within a byte limit, for the cards the
/// browser asks for again; the ones it lost from the cache forgotten by the queue so they are made again; delivered
/// ones no longer waiting.
@Suite struct CoverCardsTests {
    /// A picture of `side` × `side` pixels: `side * side * 4` bytes.
    private func image(_ side: Int) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    @Test func firstAskWaitsForAll() {
        var cards = CoverCards(limitBytes: 1 << 20)
        let ask = cards.ask(["a", "b", "c"], visible: 2)
        #expect(ask.cached.isEmpty && ask.forget.isEmpty)
        #expect(ask.queue == ["a", "b", "c"] && ask.visible == 2)
        #expect(cards.pending == ["a", "b", "c"] && cards.visiblePending == 2)
    }

    /// Asked again after a sort or a filter cleared the pictures: from the cache at once, not from the queue.
    @Test func askedAgainComesFromTheCache() {
        var cards = CoverCards(limitBytes: 1 << 20)
        _ = cards.ask(["a", "b"], visible: 2)
        let picture = image(8)
        cards.delivered("a", picture)
        let ask = cards.ask(["b", "a"], visible: 2)
        #expect(ask.cached.map(\.id) == ["a"] && ask.cached.first?.image === picture)
        #expect(ask.queue == ["b"] && ask.visible == 1 && ask.forget.isEmpty)
    }

    /// A cover the cache no longer holds: the queue must forget it made it, and make it again.
    @Test func evictedCoverIsForgottenAndQueued() {
        var cards = CoverCards(limitBytes: 2 * 8 * 8 * 4)
        _ = cards.ask(["a", "b", "c"], visible: 3)
        cards.delivered("a", image(8))
        cards.delivered("b", image(8))
        _ = cards.ask(["a"], visible: 1)            // a used last: b is the oldest
        cards.delivered("c", image(8))              // over the limit: b goes
        #expect(cards.bytes <= 2 * 8 * 8 * 4)
        let ask = cards.ask(["a", "b", "c"], visible: 3)
        #expect(Set(ask.cached.map(\.id)) == ["a", "c"])
        #expect(ask.queue == ["b"] && ask.forget == ["b"] && ask.visible == 1)
    }

    /// Delivered cards no longer wait: back from the viewer, only the rest is asked for again.
    @Test func deliveredLeavesThePending() {
        var cards = CoverCards(limitBytes: 1 << 20)
        _ = cards.ask(["v1", "v2", "m1", "m2"], visible: 2)
        cards.delivered("v1", image(4))
        cards.delivered("m2", image(4))
        #expect(cards.pending == ["v2", "m1"] && cards.visiblePending == 1)
    }

    /// The layout or the card size changed: no picture is kept, and every covered card is made again when asked.
    @Test func droppedImagesAreMadeAgain() {
        var cards = CoverCards(limitBytes: 1 << 20)
        _ = cards.ask(["a"], visible: 1)
        cards.delivered("a", image(4))
        cards.dropImages()
        #expect(cards.bytes == 0)
        let ask = cards.ask(["a"], visible: 1)
        #expect(ask.cached.isEmpty && ask.queue == ["a"] && ask.forget == ["a"])
    }

    /// Another folder: nothing of the last one is kept or forgotten.
    @Test func resetForgetsAll() {
        var cards = CoverCards(limitBytes: 1 << 20)
        _ = cards.ask(["a"], visible: 1)
        cards.delivered("a", image(4))
        cards.reset()
        let ask = cards.ask(["a"], visible: 1)
        #expect(ask.cached.isEmpty && ask.forget.isEmpty && ask.queue == ["a"])
    }

    /// A picture larger than the whole limit is not kept (it would push out everything else).
    @Test func tooLargeIsNotKept() {
        var cards = CoverCards(limitBytes: 100)
        _ = cards.ask(["a"], visible: 1)
        cards.delivered("a", image(8))
        #expect(cards.bytes == 0)
        #expect(cards.ask(["a"], visible: 1).forget == ["a"])
    }

    /// The budget follows the card count, between a floor and a ceiling.
    @Test func limitFollowsCardCount() {
        let each = 704 * 704 * 4
        #expect(CoverCards.limit(cards: 30, pixels: 704) == 30 * each)
        #expect(CoverCards.limit(cards: 1, pixels: 704) == 32 << 20)
        #expect(CoverCards.limit(cards: 0, pixels: 0) == 32 << 20)
        #expect(CoverCards.limit(cards: 100_000, pixels: 704) == CoverCards.maxLimitBytes)
        #expect(CoverCards.limit(cards: Int.max, pixels: 704) == CoverCards.maxLimitBytes)
    }

    /// A smaller budget lets the least recently used go at once.
    @Test func shrinkingTheLimitEvicts() {
        var cards = CoverCards(limitBytes: 1 << 20)
        _ = cards.ask(["a", "b"], visible: 2)
        cards.delivered("a", image(16))
        cards.delivered("b", image(16))
        cards.setLimit(16 * 16 * 4)
        #expect(cards.bytes == 16 * 16 * 4)
        #expect(cards.ask(["a", "b"], visible: 2).cached.map(\.id) == ["b"])
    }
}

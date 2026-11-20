import LoupeCore
import Testing

struct PlaybackTransportLayoutTests {
    @Test func floatingStripStartsAboveTheTransport() {
        let transport = PlaybackTransportLayout(height: 48)
        #expect(transport.stripClearance(reservesSpace: false, bottomInset: 0) == 48)
        #expect(transport.stripClearance(reservesSpace: false, bottomInset: 12) == 60)
        #expect(transport.stripClearance(reservesSpace: true, bottomInset: 12) == 0)
    }

    @Test func playbackRailHasItsOwnScrollRoute() {
        var input = PlaybackInput()
        #expect(input.scroll(.notch, eligible: false, overTransport: true) == .transport)
        #expect(input.scroll(.begin, eligible: false, overTransport: true) == .transport)
        #expect(input.scroll(.change, eligible: true) == .transport)
        #expect(input.scroll(.momentumEnd, eligible: false) == .transport)
        #expect(input.scroll(.notch, eligible: true) == .player)
    }
}

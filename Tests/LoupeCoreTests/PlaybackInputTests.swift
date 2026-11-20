import LoupeCore
import Testing

struct PlaybackInputTests {
    @Test func thirdFingerTakesOverAPlayerScrollAndKeepsItsTail() {
        var input = PlaybackInput()
        #expect(input.scroll(.begin, eligible: true) == .player)
        let interruptedPlayer = input.claimNavigation()
        #expect(interruptedPlayer)
        #expect(input.scroll(.change, eligible: true) == .discard)
        #expect(input.scroll(.momentumEnd, eligible: true) == .discard)
        #expect(input.scroll(.begin, eligible: true, trackingNavigation: true) == .discard)
        #expect(input.scroll(.begin, eligible: true) == .player)
    }

    @Test func keepsGestureWhenControlIsReleased() {
        var input = PlaybackInput()
        #expect(input.scroll(.begin, eligible: true) == .player)
        #expect(input.scroll(.change, eligible: false) == .player)
        #expect(input.scroll(.end, eligible: false) == .player)
        #expect(input.scroll(.momentum, eligible: false) == .player)
        #expect(input.scroll(.momentumEnd, eligible: false) == .player)
        #expect(input.scroll(.begin, eligible: false) == .viewer)
        #expect(input.scroll(.change, eligible: true) == .viewer)
    }

    @Test func exitingConsumesOnlyTheOldPlayerGesture() {
        var input = PlaybackInput()
        input.toggleLock()
        #expect(input.locked)
        #expect(input.scroll(.begin, eligible: true) == .player)
        input.exit()
        #expect(!input.locked)
        #expect(input.scroll(.momentum, eligible: false) == .discard)
        #expect(input.scroll(.begin, eligible: false) == .viewer)
        #expect(input.scroll(.notch, eligible: true) == .player)
        #expect(input.scroll(.notch, eligible: false) == .viewer)
    }

    @Test func pressingBothModifiersAloneTogglesOnceOnRelease() {
        var input = PlaybackInput()
        input.modifiers(lockChord: true, none: false)
        input.modifiers(lockChord: false, none: false)
        #expect(!input.locked)
        input.modifiers(lockChord: false, none: true)
        #expect(input.locked)
        input.modifiers(lockChord: true, none: false)
        input.cancelChord()
        input.modifiers(lockChord: false, none: true)
        #expect(input.locked)
    }
}

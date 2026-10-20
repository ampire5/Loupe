import Testing
@testable import LoupeCore

@Suite struct FrameStatsTests {
    @Test func frameStatsDropsAndPercentiles() {
        var s = FrameStats()
        #expect(s.gpuP50 == nil && s.gpuP90 == nil && s.dropped == 0)
        let period = 0.0167
        for i in 0..<10 { s.record(gpuMs: Double(i + 1), interval: 0.0167, period: period) }   // 1...10 ms
        for _ in 0..<2 { s.record(gpuMs: 1, interval: 0.040, period: period) }
        #expect(s.dropped == 2)
        // 12 samples sorted: 1 1 1 2 3 4 5 6 7 8 9 10: nearest rank p50 = 6th = 4, p90 = 11th = 9.
        #expect(s.gpuP50 == 4)
        #expect(s.gpuP90 == 9)
    }

    @Test func unknownIntervalIsNeverADrop() {
        var s = FrameStats()
        s.record(gpuMs: 2, interval: 0, period: 0.0167)   // the first frame after a pause
        #expect(s.dropped == 0)
        #expect(s.gpuP50 == 2)
    }

    /// A long gap while an update was waiting (its input came before the previous frame was presented) is a
    /// stall: every refresh it missed is a dropped frame. 0.5 s at 60 Hz: 30 periods, 29 missed.
    @Test func stallWithPendingUpdateCountsMissedFrames() {
        var s = FrameStats()
        s.record(gpuMs: 1, interval: 0.5, period: 1.0 / 60, pending: true)
        #expect(s.dropped == 29)
    }

    /// The same gap with nothing waiting is the link idling (frames are drawn only on change): no drop.
    @Test func idleGapIsNotADrop() {
        var s = FrameStats()
        s.record(gpuMs: 1, interval: 0.5, period: 1.0 / 60, pending: false)
        s.record(gpuMs: 1, interval: FrameStats.activeGap, period: 1.0 / 60, pending: false)
        #expect(s.dropped == 0)
    }

    /// A short late frame counts the refreshes it missed (at least one), pending or not.
    @Test func shortLateFrameCountsMissedRefreshes() {
        var s = FrameStats()
        s.record(gpuMs: 1, interval: 0.050, period: 1.0 / 60)   // 3 periods: 2 missed
        #expect(s.dropped == 2)
    }

    @Test func keepsOnlyTheLast240Frames() {
        var s = FrameStats()
        s.record(gpuMs: 50, interval: 0.1, period: 0.0167)   // a drop, but it will leave the window
        for _ in 0..<240 { s.record(gpuMs: 1, interval: 0.0167, period: 0.0167) }
        #expect(s.dropped == 0)
        #expect(s.gpuP90 == 1)
    }

    @Test func statsModeCycles() {
        #expect(StatsMode.hidden.next == .compact)
        #expect(StatsMode.compact.next == .hidden)
    }

    @Test func statsModeStartsFromTheStoredOne() {
        #expect(StatsMode.stored(nil) == .compact)
        #expect(StatsMode.stored("extended") == .compact)
        #expect(StatsMode.stored("hidden") == .hidden)
        #expect(StatsMode.stored("bogus") == .compact)
    }

    @Test func footprintIsPlausible() {
        #expect(ProcessMemory.footprint() > 1_000_000)
    }
}

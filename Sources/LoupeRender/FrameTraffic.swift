import Dispatch
import Metal
import os

/// The frames on the GPU right now, so uploads yield to them: a piece of an upload (`TiledImage.encodeAndRun`) is
/// committed only once no tracked frame is in flight, and the GPU, which runs the upload queue's work alongside the
/// frame queue's, then gives a frame drawn during an upload its whole time. Pieces sent while frames were in flight
/// stretched a 7 ms frame at 100 % to up to 20 ms and made half of them late (i7-10700K + Radeon Pro 5500 XT, 5120 x
/// 2880 at 60 Hz, `LoupeBench panload`).
public final class FrameTraffic: Sendable {
    /// Longest a piece waits for the frames: a frame tracked but never committed must not hold uploads up for good,
    /// and back-to-back frames (a 120 Hz pan, several windows) must not starve them. Two 60 Hz periods.
    static let longestWait = 0.034

    private struct State {
        var inFlight = 0
        var nextWaiter: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Counts `commands` (a frame's command buffer, before its commit) as in flight until it completes.
    public func track(_ commands: MTLCommandBuffer) {
        state.withLock { $0.inFlight += 1 }
        commands.addCompletedHandler { [self] _ in ended() }
    }

    /// Frames tracked and not yet completed.
    var inFlight: Int { state.withLock { $0.inFlight } }

    /// Uploads waiting in `quiet`.
    var waiting: Int { state.withLock { $0.waiters.count } }

    /// Returns once no tracked frame is in flight (at once when none is), or after `wait` seconds at most.
    func quiet(wait: Double = FrameTraffic.longestWait) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let id = state.withLock { s -> UInt64? in
                guard s.inFlight > 0 else { return nil }
                defer { s.nextWaiter += 1 }
                s.waiters[s.nextWaiter] = continuation
                return s.nextWaiter
            }
            guard let id else { return continuation.resume() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait) { [self] in
                state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
            }
        }
    }

    private func ended() {
        let ready = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.inFlight -= 1
            guard s.inFlight == 0 else { return [] }
            defer { s.waiters.removeAll() }
            return Array(s.waiters.values)
        }
        for waiter in ready { waiter.resume() }
    }
}

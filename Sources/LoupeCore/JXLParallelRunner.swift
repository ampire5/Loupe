import CJXL
import Dispatch
import Synchronization

/// libjxl's parallel runner on GCD, instead of `JxlThreadParallelRunner`.
///
/// libjxl's own runner starts its workers with `std::thread` at every decode, and a thread made with `pthread_create`
/// never inherits its creator's QoS: it runs at default, whatever work item made it. A thumbnail decoded in a utility
/// slot (`ThumbnailStore`) or a neighbour in a userInitiated one then spent its cores at the QoS of the photo the user
/// is waiting for, and the app's other background work, and every decode made its pool's threads anew (about 40 a
/// second while thumbnails came). Here the workers are the GCD workers of the caller's work item, so they keep its QoS,
/// and the caller's own thread works too. `threads` (`jxl-threads-current` / `jxl-threads-other`) caps the workers at
/// once; GCD may run fewer when the cores are busy, never more.
///
/// Measured on an i7-10700K (8 cores, 16 threads), `LoupeBench thumbs` over 600 local 40 MP JPEG XL files, threads
/// with at least 8 % CPU by QoS (utility / default): libjxl's runner 5–16 % / 61–94 %, this one 84–85 % / 14 % (the
/// bench's own threads); files per second and CPU seconds are the same (36 and 95 s against 37 and 93 s).
final class JXLParallelRunner: @unchecked Sendable {
    let threads: Int

    init(threads: Int) { self.threads = max(1, threads) }

    /// The `runner_opaque` of `JxlDecoderSetParallelRunner`, valid as long as this object is.
    var opaque: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// The next item of a run to hand out.
    private final class Cursor {
        let next = Atomic<Int>(0)
    }

    /// The `JxlParallelRunner` function of `JxlDecoderSetParallelRunner`: `initialize` with the workers it will use,
    /// then `body` once for each value in `start..<end`, each with the id (below that count) of the worker running it.
    static let run: JxlParallelRunner = { opaque, work, initialize, body, start, end in
        guard let opaque, let initialize, let body else { return JXL_PARALLEL_RET_RUNNER_ERROR }
        let runner = Unmanaged<JXLParallelRunner>.fromOpaque(opaque).takeUnretainedValue()
        let count = end > start ? Int(end - start) : 0
        let workers = max(1, min(runner.threads, count))
        let status = initialize(work, workers)
        guard status == JXL_PARALLEL_RET_SUCCESS, count > 0 else { return status }
        if workers == 1 {
            for value in start..<end { body(work, value, 0) }
            return JXL_PARALLEL_RET_SUCCESS
        }
        let cursor = Cursor()
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            while true {
                let item = cursor.next.add(1, ordering: .relaxed).oldValue
                if item >= count { return }
                body(work, start + UInt32(item), worker)
            }
        }
        return JXL_PARALLEL_RET_SUCCESS
    }
}

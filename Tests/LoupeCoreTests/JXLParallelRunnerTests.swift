import CJXL
import Darwin
import Foundation
import Testing
@testable import LoupeCore

/// What libjxl's callbacks saw during one run of the runner.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    let pause: TimeInterval
    private(set) var announced: [Int] = []
    private(set) var values: [UInt32] = []
    private(set) var threadIDs: [Int] = []
    private(set) var qos: Set<UInt32> = []
    private(set) var peak = 0
    private var running = 0

    init(pause: TimeInterval = 0) { self.pause = pause }

    var opaque: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func announce(_ threads: Int) { lock.withLock { announced.append(threads) } }

    func begin() {
        lock.withLock {
            running += 1
            peak = max(peak, running)
        }
    }

    func end(_ value: UInt32, _ threadID: Int) {
        lock.withLock {
            running -= 1
            values.append(value)
            threadIDs.append(threadID)
            qos.insert(qos_class_self().rawValue)
        }
    }
}

private let initialize: JxlParallelRunInit = { opaque, threads in
    Unmanaged<Recorder>.fromOpaque(opaque!).takeUnretainedValue().announce(threads)
    return 0
}

private let body: JxlParallelRunFunction = { opaque, value, threadID in
    let recorder = Unmanaged<Recorder>.fromOpaque(opaque!).takeUnretainedValue()
    recorder.begin()
    if recorder.pause > 0 { Thread.sleep(forTimeInterval: recorder.pause) }
    recorder.end(value, threadID)
}

/// One run of `JXLParallelRunner` over `items`, on a work item of `qos` (the caller's own thread when nil).
private func run(threads: Int, items: Range<UInt32>, pause: TimeInterval = 0,
                 qos: DispatchQoS.QoSClass? = nil) -> Recorder {
    let runner = JXLParallelRunner(threads: threads), recorder = Recorder(pause: pause)
    let work = { _ = JXLParallelRunner.run(runner.opaque, recorder.opaque, initialize, body, items.lowerBound, items.upperBound) }
    if let qos {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: qos).async {
            work()
            done.signal()
        }
        done.wait()
    } else {
        work()
    }
    withExtendedLifetime((runner, recorder)) {}
    return recorder
}

@Test func jxlRunnerVisitsEveryItemOnce() {
    let recorder = run(threads: 4, items: 3..<103)
    #expect(recorder.values.sorted() == Array(3..<103))
}

@Test func jxlRunnerAnnouncesNoMoreWorkersThanItemsOrThreads() {
    #expect(run(threads: 4, items: 0..<100).announced == [4])
    #expect(run(threads: 4, items: 0..<2).announced == [2])
    #expect(run(threads: 0, items: 0..<9).announced == [1])
}

@Test func jxlRunnerHandsOutThreadIDsBelowTheAnnouncedCount() {
    let recorder = run(threads: 3, items: 0..<60, pause: 0.001)
    #expect(recorder.threadIDs.count == 60)
    #expect(recorder.threadIDs.allSatisfy { (0..<3).contains($0) })
}

@Test func jxlRunnerEmptyRangeRunsNothing() {
    let recorder = run(threads: 4, items: 5..<5)
    #expect(recorder.values.isEmpty)
}

@Test func jxlRunnerNeverRunsMoreItemsAtOnceThanItsThreads() {
    #expect(run(threads: 2, items: 0..<40, pause: 0.002).peak <= 2)
    #expect(run(threads: 1, items: 0..<10, pause: 0.001).peak == 1)
}

/// libjxl's own runner starts its workers with `std::thread`, which never inherits the creator's QoS: a thumbnail
/// decoded in a utility slot ran on default-QoS threads, level with the photo the user waits for. This runner's workers
/// are the GCD workers of the caller's work item.
@Test(arguments: [DispatchQoS.QoSClass.utility, .userInitiated, .background])
func jxlRunnerWorkersKeepTheCallersQoS(qos: DispatchQoS.QoSClass) {
    let recorder = run(threads: 4, items: 0..<64, pause: 0.002, qos: qos)
    #expect(recorder.qos == [qos.rawValue.rawValue])
}

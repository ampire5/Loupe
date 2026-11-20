import CoreGraphics
import Foundation
import Testing
@testable import Loupe

struct FramingPreviewLoaderTests {
    @Test func replacesPendingRequestsWithoutAnUnboundedDecodeQueue() async {
        let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let reads = PreviewReadLog()
        let loader = FramingPreviewLoader(read: { source, _, _ in
            reads.append(source.lastPathComponent)
            if source.lastPathComponent == "first" { began.signal(); release.wait() }
            return nil
        })
        let completed = DispatchGroup()
        completed.enter()
        loader.request(source: URL(fileURLWithPath: "/first"), applied: true, revision: nil) { _ in completed.leave() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async { began.wait(); continuation.resume() }
        }
        for i in 0..<20 {
            completed.enter()
            loader.request(source: URL(fileURLWithPath: "/next-\(i)"), applied: true, revision: nil) { _ in completed.leave() }
        }
        release.signal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completed.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
        #expect(reads.count == 2)
    }
}

private final class PreviewReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func append(_ name: String) { lock.withLock { names.append(name) } }
    var count: Int { lock.withLock { names.count } }
}

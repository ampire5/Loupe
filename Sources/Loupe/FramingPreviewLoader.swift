import CoreGraphics
import Foundation
import ImageIO
import LoupeCore

/// One active decode and one replaceable pending request per window; a shared serial utility decoder.
final class FramingPreviewLoader: @unchecked Sendable {
    typealias Read = @Sendable (URL, Bool, FramingSourceRevision?) -> CGImage?
    private struct Request {
        var source: URL
        var applied: Bool
        var revision: FramingSourceRevision?
        var done: @Sendable (CGImage?) -> Void
    }
    private static let work = DispatchQueue(label: "loupe.learning-preview", qos: .utility)
    private let lock = NSLock()
    private var pending: Request?
    private var running = false
    private let read: Read
    init(read: Read? = nil) {
        if let read { self.read = read }
        else { self.read = { source, applied, revision in Self.readImage(source: source, applied: applied, revision: revision) } }
    }
    func image(source: URL, applied: Bool, revision: FramingSourceRevision?) async -> CGImage? {
        await withCheckedContinuation { continuation in
            request(source: source, applied: applied, revision: revision) { continuation.resume(returning: $0) }
        }
    }
    func request(source: URL, applied: Bool, revision: FramingSourceRevision?, done: @escaping @Sendable (CGImage?) -> Void) {
        let (old, start) = lock.withLock { () -> (Request?, Bool) in
            let old = pending; pending = .init(source: source, applied: applied, revision: revision, done: done)
            let start = !running; running = true; return (old, start)
        }
        old?.done(nil)
        if start { Self.work.async { self.next() } }
    }
    func cancelPending() {
        let old = lock.withLock { () -> Request? in defer { pending = nil }; return pending }
        old?.done(nil)
    }
    private func next() {
        let job = lock.withLock { () -> Request? in
            guard let next = pending else { running = false; return nil }; pending = nil; return next
        }
        guard let job else { return }
        let image = autoreleasepool { read(job.source, job.applied, job.revision) }
        job.done(image)
        Self.work.async { self.next() }
    }
    private static func readImage(source: URL, applied: Bool, revision: FramingSourceRevision?) -> CGImage? {
        if let revision, let now = try? FramingSourceRevision.read(source), revision != now { return nil }
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(image, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: applied, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary)
    }
}

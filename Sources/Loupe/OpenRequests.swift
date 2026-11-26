import Foundation
import LoupeCore

/// Resolves filesystem targets before AppKit routes them. The external queue publishes in arrival order,
/// even when a later event finishes first. A drop has its own lifetime and shares the blocking slots.
@MainActor final class OpenRequests {
    /// System callbacks cannot wait for a free slot. Keep a burst of events in order and reject newer arrivals
    /// once the queue is full, so a blocked mount cannot accumulate an unlimited backlog.
    static let maxPendingBatches = 64

    enum Request: Sendable {
        case finder([URL])
        case handover([String])
        case arguments([String])
    }

    enum PathKind: Sendable { case directory, regularFile, other }
    typealias Probe = @Sendable (String) -> PathKind?

    private struct Pending {
        let request: Request
        let deliver: ([OpenTarget]) -> Void
        var task: Task<[OpenTarget], Never>?
    }

    private final class ProbeCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }

        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }

    private let pool: DecodePool
    private let probe: Probe
    private let workerCount: Int
    private let pendingLimit: Int
    private var pending: [Pending] = []
    private var started = 0
    private var delivery: Task<Void, Never>?

    /// At most two independent open events get a probe slot, also capped at half the physical cores.
    init(workerCount: Int = min(2, max(1, Machine.physicalCores / 2)), maxPendingBatches: Int = OpenRequests.maxPendingBatches,
         probe: @escaping Probe = fileKind) {
        self.workerCount = max(1, workerCount)
        pendingLimit = max(1, maxPendingBatches)
        self.probe = probe
        pool = DecodePool(slots: workerCount, reserved: 0)
    }

    @discardableResult func submit(_ request: Request, deliver: @escaping ([OpenTarget]) -> Void) -> Bool {
        guard pending.count < pendingLimit else { return false }
        pending.append(Pending(request: request, deliver: deliver))
        startProbes()
        if delivery == nil { delivery = Task { [weak self] in await self?.deliverInOrder() } }
        return true
    }

    func resolveDrop(_ url: URL) async -> OpenTarget? {
        await resolve(.finder([url])).first
    }

    func cancel() {
        delivery?.cancel()
        delivery = nil
        for entry in pending { entry.task?.cancel() }
        pending.removeAll()
        started = 0
    }

    private func startProbes() {
        // Both in-flight work and results waiting behind a slow earlier event stay bounded.
        while started < min(workerCount, pending.count) {
            let request = pending[started].request
            pending[started].task = Task { [pool, probe] in
                await Self.resolve(request, pool: pool, probe: probe)
            }
            started += 1
        }
    }

    private func deliverInOrder() async {
        while let head = pending.first, let task = head.task {
            let targets = await task.value
            guard !Task.isCancelled else { return }
            pending.removeFirst()
            started -= 1
            head.deliver(targets)
            startProbes()
        }
        delivery = nil
    }

    private func resolve(_ request: Request) async -> [OpenTarget] {
        await Self.resolve(request, pool: pool, probe: probe)
    }

    private nonisolated static func resolve(_ request: Request, pool: DecodePool, probe: @escaping Probe) async -> [OpenTarget] {
        let cancellation = ProbeCancellation()
        let targets: [OpenTarget]? = await withTaskCancellationHandler {
            try? await pool.run(forCurrent: true, rank: 0) {
                switch request {
                case .finder(let urls): return try finderTargets(urls, probe: probe, cancellation: cancellation)
                case .handover(let paths):
                    // Anyone can post the distributed notification. Follow links, but accept only an absolute path
                    // to an existing directory or regular file. Keep the sender's path for routing.
                    let targets: [OpenTarget] = try paths.compactMap { path in
                        try cancellation.check()
                        guard path.hasPrefix("/"), !path.utf8.contains(0), let kind = probe(path), kind != .other else { return nil }
                        let url = URL(fileURLWithPath: path, isDirectory: kind == .directory)
                        return target(url, kind: kind)
                    }
                    return OpenRouter.firstPerFolder(targets)
                case .arguments(let arguments):
                    return try firstFileArgument(arguments, probe: probe, cancellation: cancellation).map { [$0] } ?? []
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return Task.isCancelled ? [] : targets ?? []
    }

    private nonisolated static func finderTargets(_ urls: [URL], probe: Probe,
                                                  cancellation: ProbeCancellation) throws -> [OpenTarget] {
        let targets = try urls.map { url in
            try cancellation.check()
            return target(url, kind: probe(url.path))
        }
        return OpenRouter.firstPerFolder(targets)
    }

    private nonisolated static func target(_ url: URL, kind: PathKind?) -> OpenTarget {
        let directory = kind == .directory
        if kind != nil { ArchivePath.noteDirectoryType(url, isDirectory: directory) }
        return directory ? .folder(url) : .file(url)
    }

    /// A token after -Key is a defaults override. The first existing non-directory argument wins.
    private nonisolated static func firstFileArgument(_ arguments: [String], probe: Probe,
                                                      cancellation: ProbeCancellation) throws -> OpenTarget? {
        var tokens = arguments.makeIterator()
        while let token = tokens.next() {
            try cancellation.check()
            if token.hasPrefix("-") { _ = tokens.next(); continue }
            guard let kind = probe(token), kind != .directory else { continue }
            return target(URL(fileURLWithPath: token, isDirectory: false), kind: kind)
        }
        return nil
    }

    nonisolated private static func fileKind(_ path: String) -> PathKind? {
        var info = stat()
        guard !path.utf8.contains(0), stat(path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .regularFile
        default: return .other
        }
    }
}

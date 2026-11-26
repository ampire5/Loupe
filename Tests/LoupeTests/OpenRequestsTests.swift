import AppKit
@testable import HomeScreenKit
import LoupeCore
import LoupeRender
import Testing
@testable import Loupe

@MainActor @Suite(.serialized) struct OpenRequestsTests {
    @Test func externalEventsRouteInArrivalOrderWhileTheMainActorCanHandleInput() async throws {
        let first = URL(fileURLWithPath: "/blocked/first.jpg", isDirectory: false)
        let sibling = URL(fileURLWithPath: "/blocked/sibling.jpg", isDirectory: false)
        let second = URL(fileURLWithPath: "/blocked/second.jpg", isDirectory: false)
        let gate = ProbeGate(blocking: first.path)
        defer { gate.release() }
        let requests = OpenRequests(workerCount: 2, probe: gate.probe)
        var delivered: [[OpenTarget]] = []
        requests.submit(.finder([first, sibling])) { delivered.append($0) }
        try await gate.waitUntilStarted(first.path)
        requests.submit(.finder([second])) { delivered.append($0) }
        try await gate.waitUntilFinished(second.path)
        // A main-queue event can run while the first filesystem call still owns its slot.
        await withCheckedContinuation { event in DispatchQueue.main.async { event.resume() } }
        #expect(delivered.isEmpty)
        gate.release()
        try await waitFor { delivered.count == 2 }
        #expect(delivered == [[.file(first)], [.file(second)]])
    }

    @Test func aBlockedBatchBoundsHowManyLaterEventsCanWait() async throws {
        let first = URL(fileURLWithPath: "/blocked/first.jpg", isDirectory: false)
        let second = URL(fileURLWithPath: "/blocked/second.jpg", isDirectory: false)
        let third = URL(fileURLWithPath: "/ready/third.jpg", isDirectory: false)
        let gate = ProbeGate(blocking: first.path)
        defer { gate.release() }
        let requests = OpenRequests(workerCount: 1, maxPendingBatches: 2, probe: gate.probe)
        var delivered: [[OpenTarget]] = []
        #expect(requests.submit(.finder([first])) { delivered.append($0) })
        try await gate.waitUntilStarted(first.path)
        #expect(requests.submit(.finder([second])) { delivered.append($0) })
        #expect(!requests.submit(.finder([third])) { delivered.append($0) })
        gate.release()
        try await waitFor { delivered.count == 2 }
        #expect(delivered == [[.file(first)], [.file(second)]])
        #expect(!gate.hasStarted(third.path))
    }

    @Test func cancellationStopsAStartedBatchBeforeItsNextPath() async throws {
        let first = URL(fileURLWithPath: "/blocked/first.jpg", isDirectory: false)
        let second = URL(fileURLWithPath: "/blocked/second.jpg", isDirectory: false)
        let gate = ProbeGate(blocking: first.path)
        defer { gate.release() }
        let requests = OpenRequests(workerCount: 1, probe: gate.probe)
        var delivered = false
        requests.submit(.finder([first, second])) { _ in delivered = true }
        try await gate.waitUntilStarted(first.path)
        requests.cancel()
        gate.release()
        await withCheckedContinuation { done in requests.submit(.finder([])) { _ in done.resume() } }
        #expect(!gate.hasStarted(second.path))
        #expect(!delivered)
    }

    @Test func startupSkipsDefaultsArgumentsAndChoosesFirstExistingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultValue = root.appending(path: "defaults.jpg", directoryHint: .notDirectory)
        let missing = root.appending(path: "missing.jpg", directoryHint: .notDirectory)
        let argument = root.appending(path: "argument.jpg", directoryHint: .notDirectory)
        let later = root.appending(path: "later.jpg", directoryHint: .notDirectory)
        for file in [defaultValue, argument, later] { try Data().write(to: file) }
        let requests = OpenRequests()
        let picked = await withCheckedContinuation { done in
            requests.submit(.arguments(["-Key", defaultValue.path, missing.path, root.path, argument.path, later.path])) { done.resume(returning: $0) }
        }
        #expect(picked == [.file(argument)])
        let fallback = await withCheckedContinuation { done in
            requests.submit(.arguments(["-Key", defaultValue.path, missing.path, root.path])) { done.resume(returning: $0) }
        }
        #expect(fallback.isEmpty)
    }

    @Test func classifiesZipDirectoryAndArchiveAndValidatesHandoverPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let folder = root.appending(path: "folder.zip", directoryHint: .isDirectory)
        let archive = root.appending(path: "archive.zip", directoryHint: .notDirectory)
        let link = root.appending(path: "alias.zip", directoryHint: .notDirectory)
        let missing = root.appending(path: "missing.jpg", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: archive)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archive)
        let requests = OpenRequests()
        let finder = await withCheckedContinuation { done in
            requests.submit(.finder([folder, archive, missing])) { done.resume(returning: $0) }
        }
        #expect(finder == [.folder(folder), .file(archive), .file(missing)])
        #expect(!ArchivePath.isArchive(folder))
        #expect(ArchivePath.isArchive(archive))
        let handover = await withCheckedContinuation { done in
            requests.submit(.handover(["relative.jpg", missing.path, "/dev/null", folder.path, link.path])) {
                done.resume(returning: $0)
            }
        }
        #expect(handover == [.folder(folder), .file(link)])
    }

    @Test func dropKeepsItsOriginWhenAnotherTabBecomesActive() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/photo.jpg",
                                                                    directoryHint: .notDirectory)
        let gate = ProbeGate(blocking: file.path)
        defer { gate.release() }
        let registry = WindowRegistry(openRequests: OpenRequests(workerCount: 1, probe: gate.probe))
        let origin = makeController(in: registry)
        let other = makeController(in: registry)
        defer { origin.window?.close(); other.window?.close() }
        origin.showHome(tab: .folders)
        try drop(file, on: origin)
        try await gate.waitUntilStarted(file.path)
        other.bringToFront()
        gate.release()
        try await waitFor { origin.session.playlist?.current.path == file.path }
        #expect(other.session.playlist == nil)
    }

    @Test func closingDropOriginDiscardsThePendingResult() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/photo.jpg",
                                                                    directoryHint: .notDirectory)
        let gate = ProbeGate(blocking: file.path)
        defer { gate.release() }
        let requests = OpenRequests(workerCount: 1, probe: gate.probe)
        let registry = WindowRegistry(openRequests: requests)
        let origin = makeController(in: registry)
        let other = makeController(in: registry)
        defer { origin.window?.close(); other.window?.close() }
        origin.showHome(tab: .folders)
        try drop(file, on: origin)
        try await gate.waitUntilStarted(file.path)
        origin.window?.close()
        gate.release()
        // Wait for the same worker to handle another request after the blocked stat exits.
        await withCheckedContinuation { done in requests.submit(.finder([])) { _ in done.resume() } }
        #expect(origin.session.playlist == nil)
        #expect(other.session.playlist == nil)
    }

    private func makeController(in registry: WindowRegistry) -> ViewerWindowController {
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
                                                thumbnailsReady: nil, positions: FolderPositions(database: nil),
                                                folderSettings: FolderSettings(database: nil), recent: nil)
        registry.add(controller)
        return controller
    }

    private func drop(_ file: URL, on controller: ViewerWindowController) throws {
        let browser = try #require(controller.window?.firstResponder as? HomeBrowserView)
        let home = try #require(sequence(first: browser as NSView, next: { $0.superview })
            .compactMap { $0 as? HomeView }.first)
        let onDrop = try #require(home.onDrop)
        onDrop(file)
    }
}

@MainActor private func waitFor(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    try #require(condition())
}

private final class ProbeGate: @unchecked Sendable {
    private let blockedPath: String
    private let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started: Set<String> = []
    private var finished: Set<String> = []

    init(blocking path: String) { blockedPath = path }

    func probe(_ path: String) -> OpenRequests.PathKind? {
        lock.withLock { _ = started.insert(path) }
        if path == blockedPath { _ = resume.wait(timeout: .now() + 5) }
        lock.withLock { _ = finished.insert(path) }
        return .regularFile
    }

    func release() { resume.signal() }

    func hasStarted(_ path: String) -> Bool { lock.withLock { started.contains(path) } }

    @MainActor func waitUntilStarted(_ path: String) async throws { try await waitFor { hasStarted(path) } }

    @MainActor func waitUntilFinished(_ path: String) async throws {
        try await waitFor { lock.withLock { finished.contains(path) } }
    }
}

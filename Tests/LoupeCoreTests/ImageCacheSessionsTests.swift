import Foundation
import Testing
@testable import LoupeCore

// ImageCache serving several sessions (spec windows-and-tabs §3.2–3.4): only the active one plans, the others keep
// what they have, a visible one keeps (or gets back) its current photo, and eviction goes by owner. Same rig and
// fakes as ImageCacheTests; each session has a folder of its own (`/fake/a/0…9.jpg`, `/fake/b/…`).

private let sessionA = CacheSessionID(1)
private let sessionB = CacheSessionID(2)
private let sessionC = CacheSessionID(3)

private func folder(_ name: String) -> [URL] { (0..<10).map { URL(fileURLWithPath: "/fake/\(name)/\($0).jpg") } }

private final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [URL] = []
    func add(_ url: URL) { lock.withLock { log.append(url) } }
    var urls: [URL] { lock.withLock { log } }
}

extension Rig {
    func focus(_ session: CacheSessionID, _ files: [URL], _ current: Int, dwelling: Bool = false,
               needsFull: Bool = false, companion: Int? = nil) async {
        let focus = CacheFocus(count: files.count, current: current, direction: 1, dwelling: dwelling,
                               needsFull: needsFull, screen: rigScreen, companion: companion,
                               step: companion == nil ? 1 : 2)
        await cache.setFocus(session, files: files, focus: focus)
    }

    /// Registers `session` (without a handler of interest) and sets its activity.
    func open(_ session: CacheSessionID, active: Bool, visible: Bool) async {
        await cache.register(session) { _ in }
        await cache.setActivity(session, active: active, visible: visible)
    }

    /// Makes `session` the active, visible one and hides `previous`.
    func switchTo(_ session: CacheSessionID, from previous: CacheSessionID) async {
        await cache.setActivity(session, active: true, visible: true)
        await cache.setActivity(previous, active: false, visible: false)
    }

    var readsSoFar: Int { reader.readOrder.count }
    var decodesSoFar: Int { decoder.calls.count }

    func states(_ files: [URL]) async -> [CacheGoal?] {
        var states: [CacheGoal?] = []
        for url in files { states.append(await state(url)) }
        return states
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ImageCacheSessionsTests {
    /// Each session's handler hears of its own folder's photos only, however many are registered.
    @Test func handlersDoNotOverride() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        let updatesA = Updates(), updatesB = Updates()
        await rig.cache.register(sessionA) { updatesA.add($0) }
        await rig.cache.register(sessionB) { updatesB.add($0) }
        await rig.cache.setActivity(sessionA, active: true, visible: true)
        await rig.cache.setActivity(sessionB, active: false, visible: true)
        await rig.focus(sessionB, b, 0)
        await rig.focus(sessionA, a, 0, dwelling: true)
        #expect(await eventually { await rig.state(a[0]) == .full })
        #expect(await eventually { atLeast(.preview, await rig.state(b[0])) })
        #expect(await rig.settle())
        #expect(updatesA.urls.contains(a[0]))
        #expect(updatesA.urls.allSatisfy { a.contains($0) })
        #expect(updatesB.urls.contains(b[0]))
        #expect(updatesB.urls.allSatisfy { b.contains($0) })
    }

    /// One budget (unified memory): a visible inactive window at 100 % wants its photo's full resolution (its short
    /// plan), which the active window plans only as a file (a neighbour past `cache-previews`). The `.bytes` listed
    /// first is no pyramid goal, so the full decode starts at once and waits for no preview, which nobody plans.
    @Test func shortPlanFullStartsBehindAPlannedFile() async {
        var limits = CacheLimits.at3G
        limits.previews = 1
        let rig = Rig(limits: limits)
        #expect(await rig.cache.limits.graphicsMemory == nil)
        let a = folder("a")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: true)
        await rig.focus(sessionA, a, 0)
        await rig.focus(sessionB, a, 1, needsFull: true)
        #expect(await rig.cache.inspect([a[1]])[0]?.planned.keys.sorted() == [.bytes, .full])
        #expect(await eventually { await rig.state(a[1]) == .full })
        #expect(await rig.settle())
        #expect(!rig.decoder.calls(a[1]).contains { if case .preview = $0 { true } else { false } })
    }

    /// With `keep-share=0` (no keep sets) an inactive (and invisible) session's focus starts no read and no decode.
    @Test func inactiveStartsNothing() async {
        var limits = CacheLimits.at3G
        limits.keepShare = 0
        let rig = Rig(limits: limits)
        let a = folder("a"), b = folder("b")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 0, dwelling: true)
        #expect(await eventually { await rig.state(a[0]) == .full })
        #expect(await rig.settle())
        let reads = rig.readsSoFar, decodes = rig.decodesSoFar
        await rig.focus(sessionB, b, 0, dwelling: true)
        #expect(await rig.settle())
        #expect(rig.readsSoFar == reads)
        #expect(rig.decodesSoFar == decodes)
        #expect(await rig.cache.entry(b[0]) == nil)
    }

    /// Spec §3.2: back to a window whose photos were not evicted, nothing is read or decoded again.
    @Test func returnWithoutWork() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 3, dwelling: true, needsFull: true)
        #expect(await eventually { await rig.state(a[3]) == .full })
        #expect(await rig.settle())
        let heldA = await rig.states(a)

        await rig.switchTo(sessionB, from: sessionA)
        await rig.focus(sessionB, b, 0, dwelling: true)
        #expect(await eventually { await rig.state(b[0]) == .full })
        #expect(await rig.settle())
        let reads = rig.readsSoFar, decodes = rig.decodesSoFar

        let activation = await rig.cache.setActivity(sessionA, active: true, visible: true)
        await rig.cache.setActivity(sessionB, active: false, visible: false)
        #expect(await rig.settle())
        #expect(rig.readsSoFar == reads)
        #expect(rig.decodesSoFar == decodes)
        #expect(await rig.state(a[3]) == .full)
        #expect(await rig.states(a) == heldA)
        // Spec §3.8: what the debug log's `activate` line says of it.
        #expect(activation?.current == .full)
        #expect(activation?.jobs == 0)
    }

    /// Spec §3.8: an activation reports the work it started; one only setting visibility reports nothing. Without
    /// keep sets (`keep-share=0`), so B has nothing loaded before it is made active.
    @Test func activationReportsItsWork() async {
        var limits = CacheLimits.at3G
        limits.keepShare = 0
        let rig = Rig(limits: limits)
        let a = folder("a"), b = folder("b")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 0, dwelling: true)
        await rig.focus(sessionB, b, 0, dwelling: true)
        #expect(await rig.settle())
        #expect(await rig.cache.setActivity(sessionA, active: false, visible: true, order: nil) == nil)
        let activation = await rig.cache.setActivity(sessionB, active: true, visible: true)
        #expect(activation?.current == nil)
        #expect((activation?.jobs ?? 0) > 0)
        #expect(await rig.settle())
    }

    /// A window that comes into view with its photo evicted gets a short plan: that photo up to its preview, read
    /// at once, and nothing of its neighbours. It is then protected like the active one's.
    @Test func visibleInactiveGetsItsPhoto() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        await rig.open(sessionB, active: true, visible: true)
        await rig.open(sessionA, active: false, visible: false)
        await rig.focus(sessionB, b, 5)
        #expect(await eventually { atLeast(.preview, await rig.state(b[5])) })
        #expect(await rig.settle())

        await rig.switchTo(sessionA, from: sessionB)
        await rig.setMemory(1)
        await rig.focus(sessionA, a, 0)
        #expect(await rig.settle())
        #expect(await rig.state(b[5]) == nil)
        let readsB = b.map { rig.reader.readCount($0) }

        await rig.cache.setActivity(sessionB, active: false, visible: true)
        #expect(await eventually { atLeast(.preview, await rig.state(b[5])) })
        #expect(await rig.settle())
        #expect(rig.reader.readCount(b[5]) == readsB[5] + 1)
        for i in b.indices where i != 5 {
            #expect(rig.reader.readCount(b[i]) == readsB[i], "neighbour \(i) read")
            #expect(await rig.cache.entry(b[i])?.state == nil, "neighbour \(i) loaded")
        }
        #expect(atLeast(.preview, await rig.state(a[0])))
        #expect(atLeast(.preview, await rig.state(b[5])))   // over the limit, yet kept
    }

    /// Spec §3.4: short of memory for the active session, the longest-unused session's photos go first; a more
    /// recent one keeps its photos, its current one included, while the older one still has levels to give beyond
    /// its keep set.
    @Test func evictsOldestInactiveFirst() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b"), c = folder("c")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.open(sessionC, active: false, visible: false)
        await rig.focus(sessionA, a, 0, dwelling: true)
        #expect(await eventually { await rig.state(a[0]) == .full })
        #expect(await rig.settle())

        await rig.switchTo(sessionB, from: sessionA)
        await rig.focus(sessionB, b, 0, dwelling: true)
        #expect(await eventually { await rig.state(b[0]) == .full })
        #expect(await rig.settle())
        let bytesA = await rig.pyramidBytes(a)
        let heldB = await rig.states(b)
        // Room for A, B and half of what C will want (as much as A holds).
        await rig.setMemory((await rig.cache.stats()).usedBytes + bytesA / 2)

        await rig.switchTo(sessionC, from: sessionB)
        await rig.focus(sessionC, c, 0, dwelling: true)
        #expect(await eventually { await rig.state(c[0]) == .full })
        #expect(await rig.settle())
        #expect(await rig.pyramidBytes(a) < bytesA)
        // Keep sets (spec window-cache-ownership §1): A gives all but its photo and its neighbour before B gives
        // anything, and B then its farthest photos; both keep sets stay.
        let nowA = await rig.states(a), nowB = await rig.states(b)
        #expect(atLeast(.preview, nowA[0]) && atLeast(.preview, nowA[1]))
        #expect(a.indices.dropFirst(2).allSatisfy { !atLeast(.coarse, nowA[$0]) })
        #expect(Array(nowB.prefix(5)) == Array(heldB.prefix(5)))
        #expect(await rig.state(b[0]) == .full)
    }

    /// The current photo of a visible window is never evicted, however small the limit: not even its full
    /// resolution, finer than its short plan (a preview) asks for.
    @Test func visibleCurrentNeverEvicted() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        await rig.open(sessionB, active: true, visible: true)
        await rig.open(sessionA, active: false, visible: false)
        await rig.focus(sessionB, b, 0, dwelling: true)
        #expect(await eventually { await rig.state(b[0]) == .full })
        #expect(await rig.settle())

        await rig.cache.setActivity(sessionA, active: true, visible: true)
        await rig.cache.setActivity(sessionB, active: false, visible: true)
        await rig.setMemory(1)
        await rig.focus(sessionA, a, 0)
        #expect(await eventually { atLeast(.preview, await rig.state(a[0])) })
        #expect(await rig.settle())
        #expect(await rig.state(b[0]) == .full)
        #expect(await rig.finest(b[0]) == 0)
        #expect(await rig.cache.entry(b[1])?.state == nil)   // a neighbour of B's: not protected
    }

    /// Two tabs on one folder share its entries: one per URL, each read once. Switching between them reads nothing
    /// already resident nor decodes it again at a stage it has, switching back does no work at all, and an update of
    /// a photo both list reaches both handlers.
    @Test func twoTabsOneFolder() async {
        let rig = Rig()
        let a = folder("a")
        let updatesA = Updates(), updatesB = Updates()
        await rig.cache.register(sessionA) { updatesA.add($0) }
        await rig.cache.register(sessionB) { updatesB.add($0) }
        await rig.cache.setActivity(sessionA, active: true, visible: true)
        await rig.cache.setActivity(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 3, dwelling: true)
        await rig.focus(sessionB, a, 6)
        #expect(await eventually { await rig.state(a[3]) == .full })
        #expect(await rig.settle())
        let heldA = await rig.states(a)
        let resident = a.indices.filter { heldA[$0] != nil }
        let readsA = a.map { rig.reader.readCount($0) }
        let decodesA = a.map { rig.decoder.calls($0) }

        await rig.switchTo(sessionB, from: sessionA)
        #expect(await eventually { atLeast(.preview, await rig.state(a[6])) })
        #expect(await rig.settle())
        for i in resident {
            #expect(rig.reader.readCount(a[i]) == readsA[i], "\(i) read again")
            // B's neighbours beyond A's may go up a stage; none is decoded again at a stage it had.
            let more = rig.decoder.calls(a[i]).dropFirst(decodesA[i].count)
            #expect(!more.contains { decodesA[i].contains($0) }, "\(i) decoded again")
        }
        let reads = rig.readsSoFar, decodes = rig.decodesSoFar

        await rig.switchTo(sessionA, from: sessionB)
        #expect(await rig.settle())
        #expect(rig.readsSoFar == reads)
        #expect(rig.decodesSoFar == decodes)
        #expect(await rig.state(a[3]) == .full)
        #expect(await rig.cache.entries.keys.allSatisfy { a.contains($0) })
        #expect(a.allSatisfy { rig.reader.readCount($0) <= 1 })

        // A photo both list, rewritten: B's activation reads it again, and both hear of it.
        let heardA = updatesA.urls.count, heardB = updatesB.urls.count
        rig.reader.setStamp(a[6], FileStamp(modified: Date(timeIntervalSince1970: 2), size: 2000))
        await rig.switchTo(sessionB, from: sessionA)
        #expect(await eventually { rig.reader.readCount(a[6]) == 2 })
        #expect(await rig.settle())
        #expect(updatesA.urls.dropFirst(heardA).contains(a[6]))
        #expect(updatesB.urls.dropFirst(heardB).contains(a[6]))
    }

    /// The active session closed: nothing is planned (no read starts) until another is made active; what only it
    /// listed is freed at once (window-cache-ownership spec, close release), the other window's photos untouched.
    @Test func unregisterActiveKeepsOthersIdle() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        await rig.open(sessionB, active: true, visible: true)
        await rig.open(sessionA, active: false, visible: false)
        await rig.focus(sessionB, b, 0, dwelling: true)
        #expect(await eventually { await rig.state(b[0]) == .full })
        #expect(await rig.settle())
        await rig.switchTo(sessionA, from: sessionB)
        await rig.focus(sessionA, a, 0, dwelling: true)
        #expect(await eventually { await rig.state(a[0]) == .full })
        #expect(await rig.settle())
        let reads = rig.readsSoFar, decodes = rig.decodesSoFar
        let heldB = await rig.states(b)

        await rig.cache.unregister(sessionA)
        #expect(await rig.settle())
        #expect(rig.readsSoFar == reads)
        #expect(rig.decodesSoFar == decodes)
        #expect(await rig.pyramidBytes(a) == 0)
        #expect(await rig.states(b) == heldB)
    }

    /// A closed window's entries that no other window lists are gone at once, and what the cache holds is the other
    /// window's alone.
    @Test func unregisterFreesWhatNobodyLists() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 3, dwelling: true)
        #expect(await eventually { await rig.state(a[3]) == .full })
        #expect(await rig.settle())
        await rig.switchTo(sessionB, from: sessionA)
        await rig.focus(sessionB, b, 0, dwelling: true)
        #expect(await eventually { await rig.state(b[0]) == .full })
        #expect(await rig.settle())

        await rig.cache.unregister(sessionA)
        #expect(await rig.settle())
        #expect(await rig.cache.entries.keys.allSatisfy { b.contains($0) })
        let files = await b.asyncReduce(0) { total, url in
            total + ((await rig.cache.inspect([url])[0]?.hasBytes ?? false) ? url.lastPathComponent.utf8.count : 0)
        }
        #expect(await rig.cache.stats().usedBytes == (await rig.pyramidBytes(b)) + files)
    }

    /// Two windows on one folder: closing one frees nothing the other lists.
    @Test func unregisterKeepsWhatAnotherLists() async {
        let rig = Rig()
        let a = folder("a")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 3, dwelling: true)
        await rig.focus(sessionB, a, 6)
        #expect(await eventually { await rig.state(a[3]) == .full })
        #expect(await rig.settle())
        let held = await rig.states(a)
        await rig.cache.setActivity(sessionB, active: true, visible: true)
        await rig.cache.unregister(sessionA)
        #expect(await rig.settle())
        let now = await rig.states(a)
        for i in a.indices where held[i] != nil { #expect(now[i] != nil, "a\(i) freed") }
    }

    /// Only `setActivity` changes the active session: an inactive session's focus leaves the active one planning.
    @Test func noActiveChangeWithoutRegistryCall() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 0)
        #expect(await rig.settle())
        await rig.focus(sessionB, b, 0, dwelling: true)
        await rig.focus(sessionA, a, 1)
        #expect(await eventually { atLeast(.preview, await rig.state(a[1])) })
        #expect(await rig.settle())
        #expect(rig.reader.readCount(b[0]) == 0)
        #expect(await rig.cache.entry(b[0]) == nil)
    }

    /// Each session calls the cache on its own chain, so an activation can arrive after a later one: B activated
    /// with order 2, then A's activation with order 1 arrives. B stays active and A's playlist is not planned.
    @Test func staleActivationIgnored() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        await rig.open(sessionA, active: false, visible: false)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 0, dwelling: true)
        await rig.cache.setActivity(sessionB, active: true, visible: true, order: 2)
        await rig.focus(sessionB, b, 0)
        #expect(await eventually { atLeast(.preview, await rig.state(b[0])) })
        #expect(await rig.settle())
        // Invisible, so that the short plan of a visible inactive window (`visibleInactiveGetsItsPhoto`) reads nothing.
        await rig.cache.setActivity(sessionA, active: true, visible: false, order: 1)
        #expect(await rig.settle())
        #expect(await rig.cache.active == sessionB)
        #expect(a.allSatisfy { rig.reader.readCount($0) == 0 })
        #expect(await rig.cache.entry(a[0]) == nil)
    }

    /// The active session activated again (its window key again): the newer order holds, so another session's older
    /// activation arriving after it is stale.
    @Test func reactivationRaisesOrder() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        await rig.open(sessionA, active: false, visible: false)
        await rig.open(sessionB, active: false, visible: false)
        await rig.cache.setActivity(sessionA, active: true, visible: true, order: 1)
        await rig.focus(sessionA, a, 0)
        await rig.focus(sessionB, b, 0, dwelling: true)
        #expect(await eventually { atLeast(.preview, await rig.state(a[0])) })
        await rig.cache.setActivity(sessionA, active: true, visible: true, order: 3)
        await rig.cache.setActivity(sessionB, active: true, visible: false, order: 2)
        #expect(await rig.settle())
        #expect(await rig.cache.active == sessionA)
        #expect(b.allSatisfy { rig.reader.readCount($0) == 0 })
    }

    /// The active window going off screen and back (a Space switch, occlusion): only its visibility changes; it stays
    /// active and nothing is checked or read again, as no activation is taken.
    @Test func activeVisibilityIsNoActivation() async {
        let rig = Rig()
        let a = folder("a")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 3)
        #expect(await eventually { atLeast(.preview, await rig.state(a[3])) })
        #expect(await rig.settle())
        let reads = rig.readsSoFar
        rig.reader.setStamp(a[3], FileStamp(modified: Date(timeIntervalSince1970: 2), size: 2000))

        await rig.cache.setVisibility(sessionA, visible: false)
        #expect(await rig.cache.sessions[sessionA]?.isVisible == false)
        await rig.cache.setVisibility(sessionA, visible: true)
        #expect(await rig.settle())
        #expect(await rig.cache.active == sessionA)
        #expect(await rig.cache.sessions[sessionA]?.isVisible == true)
        #expect(rig.readsSoFar == reads)
    }

    /// Back to a window whose photo was rewritten meanwhile: the activation itself checks the current photo's stamp
    /// (no `setFocus` follows it), as a focus that makes a photo current does (ImageCacheTests' `staleFileReset`).
    @Test func activationChecksStamp() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 3)
        #expect(await eventually { atLeast(.preview, await rig.state(a[3])) })
        #expect(await rig.settle())
        await rig.switchTo(sessionB, from: sessionA)
        await rig.focus(sessionB, b, 0)
        #expect(await rig.settle())
        #expect(rig.reader.readCount(a[3]) == 1)

        rig.reader.setStamp(a[3], FileStamp(modified: Date(timeIntervalSince1970: 2), size: 2000))
        await rig.switchTo(sessionA, from: sessionB)
        #expect(await eventually { rig.reader.readCount(a[3]) == 2 })
        #expect(await rig.settle())
        #expect(atLeast(.preview, await rig.state(a[3])))
    }

    /// The single-session API still serves one window as before (ImageCacheTests' `oneReadForPreviewAndFull` and
    /// `onUpdatePerStoredStage`).
    @Test func soloWrappersStillWork() async {
        let rig = Rig()
        let files = fileURLs(5)
        let updates = Updates()
        await rig.cache.setOnUpdate { updates.add($0) }
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { await rig.state(files[0]) == .full })
        #expect(await rig.settle())
        #expect(rig.reader.readCount(files[0]) == 1)
        #expect(rig.decoder.calls(files[0]).filter { $0 == .full }.count == 1)
        #expect(updates.urls.filter { $0 == files[0] }.count == 6)
        await rig.clear()
    }

    // MARK: Idle trim and evictions from other windows (spec §3.5, §3.8)

    /// Spec §3.5: a window inactive for longer than `cache-idle-trim` lets go of everything but its current photo,
    /// which `cache-idle-keep=full` leaves as it is; not before, and the active window's photos are not touched.
    @Test func idleTrimKeepsCurrentFull() async {
        let rig = Rig()
        let (a, b) = await idleSetup(rig)
        #expect(await rig.cache.idleTimer != nil)
        let heldA = await rig.states(a), heldB = await rig.states(b)
        #expect(heldA.filter { $0 != nil }.count > 1)

        await rig.cache.trimIdle(now: .now + .seconds(29 * 60))
        #expect(await rig.states(a) == heldA)

        await rig.cache.trimIdle(now: .now + .seconds(31 * 60))
        #expect(await rig.state(a[3]) == .full)
        #expect(await rig.finest(a[3]) == 0)
        #expect(await rig.cache.entry(a[3])?.pyramid != nil)
        for i in a.indices where i != 3 {
            #expect(await rig.state(a[i]) == nil, "\(i) kept")
            #expect(await rig.cache.entry(a[i])?.pyramid == nil, "\(i) kept levels")
        }
        #expect(await rig.states(b) == heldB)
    }

    /// A trimmed window showing two pages keeps both: the pair's other page is as current as the photo.
    @Test func idleTrimKeepsTheCompanion() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 2, dwelling: true, needsFull: true, companion: 3)
        #expect(await eventually {
            let first = await rig.state(a[2]), second = await rig.state(a[3])
            return first == .full && second == .full
        })
        #expect(await rig.settle())
        await rig.switchTo(sessionB, from: sessionA)
        await rig.focus(sessionB, b, 0, dwelling: true)
        #expect(await rig.settle())
        await rig.cache.trimIdle(now: .now + .seconds(31 * 60))
        #expect(await rig.state(a[2]) == .full)
        #expect(await rig.state(a[3]) == .full)
        #expect(await rig.state(a[4]) == nil)
    }

    /// `cache-idle-keep=preview`: the trimmed window's current photo goes down to its preview (Lfit).
    @Test func idleTrimPreviewKeep() async {
        var limits = CacheLimits.at3G
        limits.idleKeep = .preview
        let rig = Rig(limits: limits)
        let (a, _) = await idleSetup(rig)
        await rig.cache.trimIdle(now: .now + .seconds(31 * 60))
        #expect(await rig.state(a[3]) == .preview)
        #expect(await rig.finest(a[3]) == 1)
        for i in a.indices where i != 3 { #expect(await rig.state(a[i]) == nil, "\(i) kept") }
    }

    /// A visible window (on a second monitor, say) is never trimmed, however long it has been inactive.
    @Test func idleTrimSkipsVisible() async {
        let rig = Rig()
        let (a, _) = await idleSetup(rig)
        await rig.cache.setActivity(sessionA, active: false, visible: true)
        #expect(await rig.settle())
        let heldA = await rig.states(a)
        await rig.cache.trimIdle(now: .now + .seconds(31 * 60))
        #expect(await rig.states(a) == heldA)
    }

    /// A window inactive but on screen, then hidden: trimmed `cache-idle-trim` after it went off screen, not after it
    /// was last active.
    @Test func idleTrimCountsFromHiding() async {
        let rig = Rig()
        let (a, _) = await idleSetup(rig)
        await rig.cache.setActivity(sessionA, active: false, visible: true)
        let heldA = await rig.states(a)
        await rig.cache.trimIdle(now: .now + .seconds(60 * 60))
        #expect(await rig.states(a) == heldA)
        await rig.cache.setActivity(sessionA, active: false, visible: false)
        await rig.cache.trimIdle(now: .now + .seconds(29 * 60))
        #expect(await rig.states(a) == heldA)
        await rig.cache.trimIdle(now: .now + .seconds(31 * 60))
        #expect(await rig.state(a[3]) == .full)
        for i in a.indices where i != 3 { #expect(await rig.state(a[i]) == nil, "\(i) kept") }
    }

    /// An entry the active window lists too stays whole, even where that window's plan does not want it; only what
    /// the idle window alone lists goes.
    @Test func idleTrimSparesSharedWithActive() async {
        var limits = CacheLimits.at3G
        limits.previews = 3
        limits.files = 3
        let rig = Rig(limits: limits)
        let a = folder("a"), b = folder("b")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a + b, 7, dwelling: true)
        #expect(await eventually { await rig.state(a[7]) == .full })
        await rig.focus(sessionA, a + b, 10, dwelling: true)
        #expect(await eventually { await rig.state(b[0]) == .full })
        #expect(await rig.settle())

        await rig.switchTo(sessionB, from: sessionA)
        await rig.focus(sessionB, a, 0)
        #expect(await eventually { atLeast(.preview, await rig.state(a[0])) })
        #expect(await rig.settle())
        let heldA = await rig.states(a), heldB = await rig.states(b)
        #expect(heldA[7] != nil)              // A's, not in B's plan: spared only for being B's too
        #expect(heldB.filter { $0 != nil }.count > 1)

        await rig.cache.trimIdle(now: .now + .seconds(31 * 60))
        #expect(await rig.states(a) == heldA)
        #expect(await rig.state(b[0]) == heldB[0])   // A's current photo
        for i in b.indices.dropFirst() { #expect(await rig.state(b[i]) == nil, "\(i) kept") }
    }

    /// `cache-idle-trim=0`: no timer, and the trim does nothing.
    @Test func idleTrimOffWhenZero() async {
        var limits = CacheLimits.at3G
        limits.idleTrim = nil
        let rig = Rig(limits: limits)
        let (a, _) = await idleSetup(rig)
        #expect(await rig.cache.idleTimer == nil)
        let heldA = await rig.states(a)
        await rig.cache.trimIdle(now: .now + .seconds(24 * 60 * 60))
        #expect(await rig.states(a) == heldA)

        // Turned on: the timer runs while a window is inactive, and stops with none.
        await rig.cache.setLimits(CacheLimits.at3G)
        #expect(await rig.cache.idleTimer != nil)
        await rig.cache.unregister(sessionA)
        #expect(await rig.cache.idleTimer == nil)
    }

    /// Spec §3.8: what `evictToFit` takes from inactive windows is counted (entries and bytes, over the run); what
    /// it takes from the active one, and the idle trim, are not.
    @Test func evictedInactiveCounts() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 0, dwelling: true)
        #expect(await eventually { await rig.state(a[0]) == .full })
        #expect(await rig.settle())
        let bytesA = await rig.pyramidBytes(a)
        await rig.setMemory((await rig.cache.stats()).usedBytes + bytesA / 2)
        #expect(await rig.cache.stats().evictedInactive == (0, 0))

        await rig.switchTo(sessionB, from: sessionA)
        await rig.focus(sessionB, b, 0, dwelling: true)
        #expect(await eventually { await rig.state(b[0]) == .full })
        #expect(await rig.settle())
        let freed = bytesA - (await rig.pyramidBytes(a))
        let counted = await rig.cache.stats().evictedInactive
        #expect(freed > 0)
        #expect(counted.count > 0)
        #expect(counted.bytes >= freed)

        await rig.cache.trimIdle(now: .now + .seconds(31 * 60))
        #expect(await rig.cache.stats().evictedInactive == counted)
    }

    // MARK: Keep sets (spec window-cache-ownership §1–2)

    /// A at 3 (dwelling: 3 full, its neighbours previews), then B made active and A hidden, with room for the keep
    /// sets and B's photo but not for all of A: returns the size of one preview.
    private func leaveA(_ rig: Rig, _ a: [URL], _ b: [URL], previews: Int = 8) async -> Int {
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 3, dwelling: true)
        #expect(await eventually { await rig.state(a[3]) == .full })
        #expect(await rig.settle())
        let preview = await rig.pyramidBytes([a[2]])
        await rig.setMemory(preview * previews)
        await rig.switchTo(sessionB, from: sessionA)
        await rig.focus(sessionB, b, 0, dwelling: true)
        #expect(await eventually { await rig.state(b[0]) == .full })
        #expect(await rig.settle())
        return preview
    }

    /// A window left keeps its photo and one neighbour each side at their previews while the active one fills the
    /// rest of the limit: the rest of the window goes first, and the kept ones are not read again.
    @Test func inactiveSessionKeepsNeighbours() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        _ = await leaveA(rig, a, b)
        for i in [2, 3, 4] {
            #expect(atLeast(.preview, await rig.state(a[i])), "a\(i) kept")
            #expect(rig.reader.readCount(a[i]) == 1, "a\(i) read again")
        }
        #expect(!atLeast(.preview, await rig.state(a[7])), "a7 is beyond the keep set")
    }

    /// The active window steps through its whole folder: the other's keep set stays as it was, nothing of it read
    /// or decoded again.
    @Test func keepSetSurvivesOtherWindowsFill() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        _ = await leaveA(rig, a, b)
        // Traced, not counted by the fake decoder, which tells files apart by name (a's 2.jpg is b's too).
        let traced = Traced()
        await rig.cache.setTrace { traced.add($0) }
        for i in 1..<b.count {
            await rig.focus(sessionB, b, i, dwelling: true)
            #expect(await eventually { await rig.state(b[i]) == .full })
            #expect(await rig.settle())
        }
        for i in [2, 3, 4] {
            #expect(atLeast(.preview, await rig.state(a[i])), "a\(i) kept")
            #expect(rig.reader.readCount(a[i]) == 1, "a\(i) read again")
            #expect(!traced.events.contains { $0.url == a[i] && $0.kind == .jobLaunched }, "a\(i) decoded again")
        }
    }

    /// Under critical pressure (a quarter of the limit, and of the keep share) the keep sets are truncated, the
    /// longest unused window's neighbours first, the active window's photo untouched; back to normal, the neighbours
    /// come back from their bytes, not read again.
    @Test func keepSetsTruncateUnderPressure() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b"), c = folder("c")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.open(sessionC, active: false, visible: false)
        await rig.focus(sessionA, a, 3, dwelling: true)
        #expect(await eventually { await rig.state(a[3]) == .full })
        #expect(await rig.settle())
        let preview = await rig.pyramidBytes([a[2]])
        await rig.switchTo(sessionB, from: sessionA)
        await rig.focus(sessionB, b, 3, dwelling: true)
        #expect(await eventually { await rig.state(b[3]) == .full })
        #expect(await rig.settle())
        await rig.switchTo(sessionC, from: sessionB)
        await rig.focus(sessionC, c, 0, dwelling: true)
        #expect(await eventually { await rig.state(c[0]) == .full })
        #expect(await rig.settle())
        // Critical: the limit 10.75 previews, the keep share 5.375: A's and B's sets (3 + 3) lose A's neighbours.
        await rig.setMemory(preview * 43)
        await rig.cache.setMemoryPressure(.critical)
        #expect(await rig.settle())
        #expect(await rig.state(c[0]) == .full)
        for i in [2, 3, 4] { #expect(atLeast(.preview, await rig.state(b[i])), "b\(i) kept") }
        #expect(atLeast(.preview, await rig.state(a[3])))
        let a2 = await rig.state(a[2]), a4 = await rig.state(a[4])
        #expect(!atLeast(.preview, a2) && !atLeast(.preview, a4))

        await rig.cache.setMemoryPressure(.normal)
        #expect(await eventually {
            let a2 = await rig.state(a[2]), a4 = await rig.state(a[4])
            return atLeast(.preview, a2) && atLeast(.preview, a4)
        })
        #expect(await rig.settle())
        #expect(rig.reader.readCount(a[2]) == 1 && rig.reader.readCount(a[4]) == 1)
    }

    /// A neighbour's job of the window left, still waiting for its read, is not cancelled: it goes on in the keep
    /// class, behind the active window's work.
    @Test func keepJobsRunInKeepClass() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        let gate = AsyncGate()
        rig.reader.hang(a[4], on: gate)
        let traced = Traced()
        await rig.cache.setTrace { traced.add($0) }
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 3, dwelling: true)
        #expect(await eventually { traced.first(a[4], .readRequested) != nil })
        #expect(await rig.cache.inspect([a[4]])[0]?.jobClasses[.preview] == .foreground)

        await rig.switchTo(sessionB, from: sessionA)
        await rig.focus(sessionB, b, 0, dwelling: true)
        #expect(await rig.cache.inspect([a[4]])[0]?.jobClasses[.preview] == .keep)
        #expect(!traced.events.contains { $0.url == a[4] && $0.kind == .jobCancelled && $0.goal == .preview })
        gate.open()
        #expect(await eventually { atLeast(.preview, await rig.state(a[4])) })
        #expect(await rig.settle())
        #expect(rig.reader.readCount(a[4]) == 1)
    }

    /// A read nothing waits for any more is finished when more than `finishReadAbove` of the file is in (its bytes
    /// kept like any other, a later visit reads nothing), and stopped when less is.
    @Test(arguments: [(0.6, true), (0.3, false)]) func readPastHalfIsFinished(fraction: Double, finished: Bool) async {
        let rig = Rig()
        let a = folder("a"), c = folder("c")
        let gate = AsyncGate()
        rig.reader.hang(a[4], on: gate)
        rig.reader.setProgress(a[4], fraction)
        let traced = Traced()
        await rig.cache.setTrace { traced.add($0) }
        await rig.focus(a, 3, dwelling: true)
        #expect(await eventually { traced.first(a[4], .readRequested) != nil })
        await rig.focus(c, 0)   // a's photos leave the plan: a[4]'s jobs go, its read is left alone or stopped
        #expect((traced.first(a[4], .readCancelled) != nil) == !finished)
        gate.open()
        #expect(await rig.settle())
        #expect((await rig.cache.inspect([a[4]])[0]?.hasBytes ?? false) == finished)
    }

    /// `rereads`: a file read again after its bytes were evicted; nothing counted when a window comes back to what it
    /// kept.
    @Test func rereadCountedWhenBytesWereEvicted() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        await rig.open(sessionB, active: true, visible: true)
        await rig.open(sessionA, active: false, visible: false)
        await rig.focus(sessionB, b, 5)
        #expect(await eventually { atLeast(.preview, await rig.state(b[5])) })
        #expect(await rig.settle())
        #expect(await rig.cache.stats().rereads == 0)

        await rig.switchTo(sessionA, from: sessionB)
        await rig.setMemory(1)
        await rig.focus(sessionA, a, 0)
        #expect(await rig.settle())
        #expect(await rig.state(b[5]) == nil)

        await rig.cache.setActivity(sessionB, active: false, visible: true)
        #expect(await eventually { atLeast(.preview, await rig.state(b[5])) })
        #expect(await rig.settle())
        #expect(rig.reader.readCount(b[5]) == 2)
        #expect(await rig.cache.stats().rereads == 1)
    }

    /// `keptForOtherWindows`: what the entries of the inactive windows' keep sets hold now.
    @Test func keptForOtherWindowsCounted() async {
        let rig = Rig()
        let a = folder("a"), b = folder("b")
        await rig.open(sessionA, active: true, visible: true)
        await rig.open(sessionB, active: false, visible: false)
        await rig.focus(sessionA, a, 3, dwelling: true)
        #expect(await eventually { await rig.state(a[3]) == .full })
        #expect(await rig.settle())
        #expect(await rig.cache.stats().keptForOtherWindows == 0)
        await rig.switchTo(sessionB, from: sessionA)
        await rig.focus(sessionB, b, 0, dwelling: true)
        #expect(await rig.settle())
        let kept = [a[2], a[3], a[4]]
        let files = kept.reduce(0) { $0 + $1.lastPathComponent.utf8.count }
        #expect(await rig.cache.stats().keptForOtherWindows == (await rig.pyramidBytes(kept)) + files)
    }
}

/// A (folder a, at 3, full resolution) used, then B (folder b) made active and A hidden: A is the window to trim.
private func idleSetup(_ rig: Rig) async -> (a: [URL], b: [URL]) {
    let a = folder("a"), b = folder("b")
    await rig.open(sessionA, active: true, visible: true)
    await rig.open(sessionB, active: false, visible: false)
    await rig.focus(sessionA, a, 3, dwelling: true, needsFull: true)
    #expect(await eventually { await rig.state(a[3]) == .full })
    #expect(await rig.settle())
    await rig.switchTo(sessionB, from: sessionA)
    await rig.focus(sessionB, b, 0, dwelling: true)
    #expect(await eventually { await rig.state(b[0]) == .full })
    #expect(await rig.settle())
    return (a, b)
}

// MARK: - The current photo first (V7)

/// Stage boundaries the cache traced, from any thread.
private final class Traced: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CacheTraceEvent] = []
    func add(_ e: CacheTraceEvent) { lock.withLock { items.append(e) } }
    var events: [CacheTraceEvent] { lock.withLock { items } }
    func first(_ url: URL, _ kind: CacheTraceEvent.Kind) -> CacheTraceEvent? {
        events.first { $0.url == url && $0.kind == kind }
    }
}

/// A chunk reader that parks reads of every file but `free` until released (a share answering slowly for them).
private final class SlowShare: @unchecked Sendable {
    private let lock = NSLock()
    private let free: Set<String>
    private let gate = DispatchSemaphore(value: 0)
    private var released = false
    private var parked = 0

    init(free: Set<String>) { self.free = free }

    /// Reads parked right now.
    var parkedCount: Int { lock.withLock { parked } }

    func releaseAll() {
        lock.withLock { released = true }
        for _ in 0..<256 { gate.signal() }
    }

    var reader: @Sendable (Int32, UnsafeMutableRawPointer, Int, Int) -> Int {
        { fd, buf, count, offset in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let name = fcntl(fd, F_GETPATH, &path) != -1 ? URL(fileURLWithPath: String(cString: path)).lastPathComponent : ""
            let parks = !self.free.contains(name) && self.lock.withLock { () -> Bool in
                guard !self.released else { return false }
                self.parked += 1
                return true
            }
            if parks {
                self.gate.wait()
                self.lock.withLock { self.parked -= 1 }
            }
            return Darwin.pread(fd, buf, count, off_t(offset))
        }
    }
}

extension ImageCacheSessionsTests {
    /// After a dwell the neighbours read, and on a slow share their reads hang; a step to a photo not in flight still
    /// gets its read requested and delivered: neighbours keep to one of the viewer's two threads, the other is the
    /// current photo's.
    @Test func stepReadsPastBlockedNeighbours() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-v7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A file's bytes are its name, as the fake decoder expects.
        let files = try (0..<40).map { i -> URL in
            let url = dir.appendingPathComponent("\(i).jpg")
            try Data(url.lastPathComponent.utf8).write(to: url)
            return url
        }
        let share = SlowShare(free: ["0.jpg", "30.jpg"])
        defer { share.releaseAll() }
        let reader = FileReader(threads: 4, timeout: .seconds(30), isLocal: { _ in false }, chunkReader: share.reader)
        let decoder = FakeDecoder(size: rigPhoto)
        let cache = ImageCache(loader: FakeLoader(), reader: reader, pool: DecodePool(), decoder: { _ in decoder },
                               limits: CacheLimits.at3G)
        let traced = Traced()
        await cache.setTrace { traced.add($0) }
        func focus(_ current: Int, dwelling: Bool) async {
            await cache.setFocus(files: files, focus: CacheFocus(count: files.count, current: current, direction: 1,
                                                                 dwelling: dwelling, needsFull: false, screen: rigScreen))
        }
        await focus(0, dwelling: true)
        #expect(await eventually { share.parkedCount >= 1 })
        try await Task.sleep(for: .milliseconds(200))   // room for a second neighbour to take a thread, if it may

        await focus(30, dwelling: false)
        #expect(await eventually { traced.first(files[30], .readDelivered) != nil })
        #expect(traced.first(files[30], .readRequested) != nil)
        share.releaseAll()
        await cache.setFocus(files: [], focus: CacheFocus(count: 0, current: 0, direction: 1, dwelling: false,
                                                          needsFull: false, screen: rigScreen))
        #expect(await eventually { await cache.isIdle })
    }

    /// A share of `files` (`i.jpg` holding its name), a real FileReader over it whose reads of every file but `free`
    /// park, and a cache over that reader with a trace.
    private func slowShareRig(free: Set<String>, count: Int = 40) async throws
        -> (dir: URL, files: [URL], share: SlowShare, cache: ImageCache<FakeLoader>, traced: Traced) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-v7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = try (0..<count).map { i -> URL in
            let url = dir.appendingPathComponent("\(i).jpg")
            try Data(url.lastPathComponent.utf8).write(to: url)
            return url
        }
        let share = SlowShare(free: free)
        let reader = FileReader(threads: 4, timeout: .seconds(30), isLocal: { _ in false }, chunkReader: share.reader)
        let decoder = FakeDecoder(size: rigPhoto)
        let cache = ImageCache(loader: FakeLoader(), reader: reader, pool: DecodePool(), decoder: { _ in decoder },
                               limits: CacheLimits.at3G)
        let traced = Traced()
        await cache.setTrace { traced.add($0) }
        return (dir, files, share, cache, traced)
    }

    /// Fix round 1, I1: a step after a dwell takes the reserved thread with a read that then stays running when the
    /// user steps again (it is the next photo's neighbour now, its flag cleared): both viewer threads hold non-current
    /// reads. The second step's read still starts, on a thread of the pool the thumbnails would use.
    @Test func secondStepReadsPastARunningExCurrentRead() async throws {
        let rig = try await slowShareRig(free: ["0.jpg", "31.jpg"])
        defer { rig.share.releaseAll(); try? FileManager.default.removeItem(at: rig.dir) }
        func focus(_ current: Int, dwelling: Bool) async {
            await rig.cache.setFocus(files: rig.files, focus: CacheFocus(count: rig.files.count, current: current,
                                                                         direction: 1, dwelling: dwelling,
                                                                         needsFull: false, screen: rigScreen))
        }
        await focus(0, dwelling: true)
        #expect(await eventually { rig.share.parkedCount >= 1 })   // a neighbour holds one viewer thread
        await focus(30, dwelling: false)
        #expect(await eventually { rig.share.parkedCount >= 2 })   // 30's read the other one, parked too
        await focus(31, dwelling: false)
        #expect(await eventually { rig.traced.first(rig.files[31], .readDelivered) != nil })
        #expect(rig.share.parkedCount >= 2, "the others stay parked")
        rig.share.releaseAll()
        await rig.cache.setFocus(files: [], focus: CacheFocus(count: 0, current: 0, direction: 1, dwelling: false,
                                                              needsFull: false, screen: rigScreen))
        #expect(await eventually { await rig.cache.isIdle })
    }

    /// Fix round 1, I2: the stamp check of a cached photo stepped back to is the current photo's I/O: it does not wait
    /// behind a neighbour read holding the neighbours' thread (activity would stay `.current` meanwhile).
    @Test func stampCheckOfTheCurrentPhotoIsCurrent() async throws {
        let rig = try await slowShareRig(free: ["0.jpg", "30.jpg"])
        defer { rig.share.releaseAll(); try? FileManager.default.removeItem(at: rig.dir) }
        func focus(_ current: Int, dwelling: Bool) async {
            await rig.cache.setFocus(files: rig.files, focus: CacheFocus(count: rig.files.count, current: current,
                                                                         direction: 1, dwelling: dwelling,
                                                                         needsFull: false, screen: rigScreen))
        }
        await focus(0, dwelling: true)
        #expect(await eventually { rig.share.parkedCount >= 1 })   // a neighbour of 0 holds the neighbours' thread
        await focus(30, dwelling: false)
        #expect(await eventually { rig.traced.first(rig.files[30], .readDelivered) != nil })
        await focus(30, dwelling: true)   // 30's neighbours read: they park behind the share as well
        await focus(0, dwelling: false)   // back to a cached photo: its stamp is checked
        #expect(await eventually { await rig.cache.stampChecks == 0 })
        rig.share.releaseAll()
        await rig.cache.setFocus(files: [], focus: CacheFocus(count: 0, current: 0, direction: 1, dwelling: false,
                                                              needsFull: false, screen: rigScreen))
        #expect(await eventually { await rig.cache.isIdle })
    }

    /// Neighbours start reading only once the current photo's preview is up, not as soon as the dwell is: until then
    /// the share is the current photo's alone.
    @Test func neighboursReadAfterTheCurrentPreview() async {
        let rig = Rig()
        let files = folder("a")
        rig.decoder.setLatency(files[0], 0.2)
        let traced = Traced()
        await rig.cache.setTrace { traced.add($0) }
        await rig.focus(files, 0, dwelling: true)
        #expect(await rig.settle())
        let preview = traced.events.first { $0.url == files[0] && $0.kind == .uploadDone && $0.goal == .preview }
        let neighbour = traced.events.first { $0.url != files[0] && $0.kind == .readRequested }
        #expect(preview != nil && neighbour != nil)
        if let preview, let neighbour { #expect(neighbour.time > preview.time) }
    }
}

extension Sequence {
    /// `reduce` with an async step.
    func asyncReduce<T>(_ initial: T, _ next: (T, Element) async -> T) async -> T {
        var value = initial
        for element in self { value = await next(value, element) }
        return value
    }
}

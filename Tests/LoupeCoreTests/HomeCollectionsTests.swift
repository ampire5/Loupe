import Foundation
import HomeScreenModel
import Testing
@testable import LoupeCore

@Suite struct HomeCollectionsTests {
    /// Tuesday 2026-10-20 15:00 local time.
    private let now: Date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15))!

    private func entry(_ path: String, kind: RecentKind = .folder, gallery: RecentGallery? = nil, index: Int? = 136,
                       count: Int? = 2_719, ago: TimeInterval = 7_200) -> RecentEntry {
        RecentEntry(path: path, kind: kind, gallery: gallery, title: gallery == nil ? nil : "Tidy", file: "b.jpg",
                    index: index, count: count, opened: now.addingTimeInterval(-ago), hidden: false)
    }

    private func saved(_ id: Int64, last: Bool = false, ago: TimeInterval = 0) -> SavedSession {
        let tabs: [SessionSnapshot.Tab] = [.file(path: "/a/1.jpg", view: nil), .home(.recent)]
        let window = SessionSnapshot.Window(frame: .zero, screen: nil, fullScreen: false, selected: 0, tabs: tabs)
        return SavedSession(id: id, name: last ? "Last Session" : "Work \(id)", saved: now.addingTimeInterval(-ago),
                            isLast: last, snapshot: SessionSnapshot(windows: [window]))
    }

    @Test func recentEntriesMapFields() {
        let gallery = RecentGallery(id: "7", list: nil)
        let entries = HomeCollections.recentEntries([entry("/p/a"), entry("/p/g.zip", kind: .archive, gallery: gallery)],
                                                    dimmed: ["/p/g.zip"], now: now)
        let a = entries[0], g = entries[1]
        #expect(a.kind == .collection && a.id == "recent:/p/a" && a.url.path == "/p/a" && a.name == "a")
        #expect(a.date == now.addingTimeInterval(-7_200))
        #expect(a.subtitle == "137 / \(BrowserSummary.number(2_719)) · 2 h ago")
        #expect(a.progress == 137.0 / 2_719)
        #expect(a.badge == nil && !a.isDimmed && !a.leads)
        #expect(g.name == "Tidy" && g.badge == "Stash" && g.isDimmed)
    }

    @Test func recentLineTimes() {
        #expect(HomeCollections.recentLine(entry("/p", ago: 30), now: now) == "137 / \(BrowserSummary.number(2_719)) · now")
        #expect(HomeCollections.recentLine(entry("/p", index: nil, ago: 300), now: now) == "5 min ago")
        #expect(HomeCollections.recentLine(entry("/p", index: nil, ago: 7_200), now: now) == "2 h ago")
        #expect(HomeCollections.recentLine(entry("/p", index: nil, ago: 3 * 86_400), now: now) == "17 Oct")
        #expect(HomeCollections.recentLine(entry("/p", index: 4, count: nil, ago: 30), now: now) == "5 · now")
    }

    @Test func recentListsBeforeAvailability() async {
        let entries = [entry("/p/a"), entry("/p/b")]
        // An availability that never answers: the first listing still comes, undimmed.
        let stuck = HomeCollections.recentListings(entries, now: now) { _ in
            try? await Task.sleep(for: .seconds(3_600))
            return [:]
        }
        var it = stuck.makeAsyncIterator()
        let first = await it.next()
        #expect(first?.complete == true)
        #expect(first?.entries.map(\.isDimmed) == [false, false])

        let oneGone = HomeCollections.recentListings(entries, now: now) { _ in ["/p/a": true, "/p/b": false] }
        var all: [BrowserListing] = []
        for await listing in oneGone { all.append(listing) }
        #expect(all.count == 2)
        #expect(all.last?.entries.map(\.isDimmed) == [false, true])

        // One there, one that did not answer in time (nil): nothing to dim.
        let timedOut: [String: Bool?] = ["/p/a": true, "/p/b": Bool?.none]
        let allThere = HomeCollections.recentListings(entries, now: now) { _ in timedOut }
        var count = 0
        for await _ in allThere { count += 1 }
        #expect(count == 1)
    }

    @Test func sessionsLastLeads() {
        let entries = HomeCollections.sessionEntries([saved(5, ago: 60), saved(0, last: true, ago: 86_400)])
        #expect(entries.map(\.id) == ["session:5", "session:0"])
        let last = entries[1]
        #expect(last.leads && last.badge == "Last" && last.kind == .collection && last.name == "Last Session")
        #expect(last.url.absoluteString == "loupe-session:0")
        #expect(last.subtitle?.hasPrefix("1 window · 2 tabs · ") == true)
        #expect(!entries[0].leads && entries[0].badge == nil)
        #expect(BrowserSort(key: .date, ascending: false).order(entries).first?.id == "session:0")
        #expect(HomeCollections.sessionMenu(isLast: true).map(\.id) == ["open", "delete"])
        #expect(HomeCollections.sessionMenu(isLast: false).map(\.id) == ["open", "rename", "replace", "delete"])
        #expect(HomeCollections.recentMenu().map(\.id) == ["tab", "window", "finder", "copy", "remove"])
    }

    @Test func targetsRoundTrip() {
        #expect(HomeCollections.target("session:5") == .session(5))
        #expect(HomeCollections.target("recent:/p/a:b") == .recent("/p/a:b"))
        #expect(HomeCollections.target("/p/a") == nil)
    }

    @Test func tabsAndLocations() {
        #expect(HomeCollections.location(of: .recent) == .source("recent"))
        #expect(HomeCollections.location(of: .sessions) == .source("sessions"))
        #expect(HomeCollections.location(of: .stash) == .source("stash"))
        #expect(HomeCollections.location(of: .folders) == nil)
        for tab in [HomeTab.recent, .sessions, .stash] {
            #expect(HomeCollections.tab(of: HomeCollections.location(of: tab)!) == tab)
        }
        #expect(HomeCollections.tab(of: .places) == .folders)
        #expect(HomeCollections.tab(of: .folder(URL(fileURLWithPath: "/x"))) == .folders)
        #expect(WindowTitle.title(of: .sessions) == "Sessions")
    }
}

/// Recent's covers wait for the one reachability check of the list (≤ 1 s), so a share that does not answer is never
/// read for a cover (review finding 1).
@Suite struct RecentReachabilityTests {
    @Test func unreachableKnownBeforeCovers() async {
        let check = RecentReachability(paths: ["/p/a", "/p/gone", "/p/slow"]) { _ in
            ["/p/a": true, "/p/gone": false, "/p/slow": Bool?.none]
        }
        #expect(await check.unreachable == ["/p/gone"])
        #expect(await check.answers["/p/a"] == .some(true))
    }

    @Test func oneCheckForListingAndCovers() async {
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let check = RecentReachability(paths: ["/p/a"]) { _ in count.n += 1; return ["/p/a": false] }
        _ = await check.answers
        _ = await check.unreachable
        #expect(count.n == 1)
    }
}

/// `home-tab` follows the user's own moves between Home's tabs, not the window's reloads (review finding 4).
@Suite struct HomeTabMemoryTests {
    @Test func savesOnlyAUserMoveToAnotherTab() {
        var memory = HomeTabMemory()
        #expect(memory.moved(to: .recent, byUser: false, saved: .folders) == nil)   // the window's own show
        #expect(memory.moved(to: .folders, byUser: true, saved: .folders) == nil)   // already saved
        #expect(memory.moved(to: .sessions, byUser: true, saved: .folders) == .sessions)
        #expect(memory.moved(to: .sessions, byUser: true, saved: .recent) == nil)   // a reload: same tab
        #expect(memory.moved(to: .folders, byUser: true, saved: .recent) == .folders)
        #expect(memory.moved(to: .folders, byUser: true, saved: .recent) == nil)    // another folder, a remount
    }
}

@Suite struct PlacesFreeSpaceTests {
    /// External disks and shares give 0 for "important usage": the plain capacity is taken, and 0 is no answer.
    @Test func freeSpaceFallsBackToPlainCapacity() {
        #expect(BrowserPlaces.available(important: 5_000, plain: 7_000) == 5_000)
        #expect(BrowserPlaces.available(important: 0, plain: 7_000) == 7_000)
        #expect(BrowserPlaces.available(important: nil, plain: 7_000) == 7_000)
        #expect(BrowserPlaces.available(important: 0, plain: 0) == nil)
        #expect(BrowserPlaces.available(important: nil, plain: nil) == nil)
    }

    @Test func placesFreeSpaceTimesOut() async {
        let quick = URL(fileURLWithPath: "/Volumes/quick"), hung = URL(fileURLWithPath: "/Volumes/hung")
        let start = ContinuousClock.now
        let space = await BrowserPlaces.freeSpace(of: [quick, hung], timeout: .milliseconds(200)) { url in
            if url == hung { Thread.sleep(forTimeInterval: 6) }
            return 1_000
        }
        // Well under the hung volume's 6 s, with room for a test run that keeps the thread pool busy.
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(space == [quick: 1_000])
    }
}

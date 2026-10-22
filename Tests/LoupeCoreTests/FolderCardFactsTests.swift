import Foundation
import HomeScreenModel
import Testing
@testable import LoupeCore

/// A folder card's facts as Home draws them (folder cards spec, "Loupe"): the summary, the subfolders' photos, the
/// visit, the two-page keys and the problem, put together into the kit's `CardSummary`.
@Suite struct FolderCardFactsTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func dir(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    private var full: FolderSummary {
        FolderSummary(photos: 248, folders: 3, bytes: 4_200_000_000, first: t0, last: t0 + 86_400 * 900,
                      histogram: [255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], folderModified: t0, datesKnown: true)
    }

    @Test func summaryMapsToCard() {
        let facts = FolderCardFacts(summary: full, inside: ChildSummaries(count: 3, photos: 1_204))
        let card = facts.cardSummary(visit: nil, config: Config())
        #expect(card == CardSummary(photos: 248, folders: 3, insidePhotos: 1_204, insideIncomplete: false,
                                    bytes: 4_200_000_000, first: t0, last: t0 + 86_400 * 900,
                                    histogram: [255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        // Nothing known yet: an empty summary, the card shows its name alone.
        #expect(FolderCardFacts().cardSummary(visit: nil, config: Config()) == CardSummary())
    }

    /// R8: the subfolders' photos are the sum of the summaries found; fewer found than the folder has subfolders is
    /// "at least"; none found shows the subfolder count instead; a folder without subfolders has none.
    @Test func insideFromChildSummaries() {
        let some = FolderCardFacts(summary: full, inside: ChildSummaries(count: 2, photos: 90))
            .cardSummary(visit: nil, config: Config())
        #expect(some.insidePhotos == 90 && some.insideIncomplete)
        let none = FolderCardFacts(summary: full, inside: ChildSummaries(count: 0, photos: 0))
            .cardSummary(visit: nil, config: Config())
        #expect(none.insidePhotos == nil && !none.insideIncomplete && none.folders == 3)
        var flat = full
        flat.folders = 0
        let leaf = FolderCardFacts(summary: flat, inside: ChildSummaries(count: 1, photos: 7))
            .cardSummary(visit: nil, config: Config())
        #expect(leaf.insidePhotos == nil && !leaf.insideIncomplete)
        let unknown = FolderCardFacts(summary: full).cardSummary(visit: nil, config: Config())
        #expect(unknown.insidePhotos == nil && !unknown.insideIncomplete)
        // More rows than subfolders: some are of subfolders that went away, so the sum is no sure count either.
        let stale = FolderCardFacts(summary: full, inside: ChildSummaries(count: 4, photos: 1_300))
            .cardSummary(visit: nil, config: Config())
        #expect(stale.insidePhotos == 1_300 && stale.insideIncomplete)
    }

    /// B2: read to the end at 248, then 12 came: "248 / 260" (seen as counted at the visit, of the photos now), the
    /// bar full as at the visit, not done, "+12".
    @Test func seenKeepsTheVisitsCount() {
        let visit = FolderVisit(index: 247, count: 248, visited: t0 + 100)
        var grown = FolderSummary(photos: 260, folders: 0)
        grown.datesKnown = false
        let card = FolderCardFacts(summary: grown).cardSummary(visit: visit, config: Config())
        #expect(card.seen == 248 && card.viewed == 1)
        #expect(CardSummaryText.viewed(card) == "248 / 260")
        #expect(!card.done && card.new == 12)
    }

    /// D5: the first run after the update has no visits yet, but Recent has where each recent folder was: its
    /// progress comes from there (spec: from the one place it is in); a visit, once there, wins.
    @Test func recentStandsInForAMissingVisit() {
        let entry = RecentEntry(path: "/p/a", kind: .folder, gallery: nil, title: nil, file: "x.jpg", index: 9,
                                count: 40, opened: t0, hidden: false)
        #expect(FolderCardFacts.visit(nil, recent: entry) == FolderVisit(index: 9, count: 40, visited: t0))
        let visit = FolderVisit(index: 3, count: 40, visited: t0 + 10)
        #expect(FolderCardFacts.visit(visit, recent: entry) == visit)
        var unknown = entry
        unknown.count = nil
        #expect(FolderCardFacts.visit(nil, recent: unknown) == nil)
        #expect(FolderCardFacts.visit(nil, recent: nil) == nil)
        let card = FolderCardFacts(summary: full).cardSummary(visit: FolderCardFacts.visit(nil, recent: entry),
                                                              config: Config())
        #expect(card.seen == 10 && card.viewed == 0.25)
    }

    /// The visit's progress and check mark; new photos by the listing's dates (local) or by the count (a share).
    @Test func visitMapsToProgressAndNew() {
        let visit = FolderVisit(index: 136, count: 248, visited: t0 + 100)
        let dated = FolderCardFacts(summary: full, photoDates: NewPhotoDates([t0, t0 + 50, t0 + 150, t0 + 200], since: .distantPast))
            .cardSummary(visit: visit, config: Config())
        #expect(dated.viewed == visit.progress() && !dated.done && dated.new == 2)
        var grown = FolderSummary(photos: 260, folders: 0)
        grown.datesKnown = false
        let counted = FolderCardFacts(summary: grown).cardSummary(visit: visit, config: Config())
        #expect(counted.new == 12)
        // No visit: no progress, nothing new.
        let unvisited = FolderCardFacts(summary: full, photoDates: NewPhotoDates([t0 + 500], since: .distantPast)).cardSummary(visit: nil, config: Config())
        #expect(unvisited.viewed == nil && !unvisited.done && unvisited.new == 0)
        // A visit without a summary yet: the progress, nothing new.
        let early = FolderCardFacts().cardSummary(visit: visit, config: Config())
        #expect(early.viewed == visit.progress() && early.new == 0)
    }

    /// Photos deleted since the visit are not "new", and the count never goes below zero.
    @Test func deletedFilesNeverNegative() {
        let visit = FolderVisit(index: 9, count: 50, visited: t0)
        let fewer = FolderCardFacts(summary: FolderSummary(photos: 30, folders: 0)).cardSummary(visit: visit, config: Config())
        #expect(fewer.new == 0)
        let none = FolderCardFacts(summary: FolderSummary(photos: 30, folders: 0), photoDates: NewPhotoDates([], since: .distantPast))
            .cardSummary(visit: visit, config: Config())
        #expect(none.new == 0)
    }

    /// ✓ is the last photo reached, and only while nothing came since.
    @Test func doneOnlyWithoutNew() {
        let visit = FolderVisit(index: 247, count: 248, visited: t0 + 100)
        let read = FolderCardFacts(summary: full, photoDates: NewPhotoDates([t0, t0 + 50], since: .distantPast)).cardSummary(visit: visit, config: Config())
        #expect(read.done && read.viewed == 1 && read.new == 0)
        let more = FolderCardFacts(summary: full, photoDates: NewPhotoDates([t0, t0 + 150], since: .distantPast)).cardSummary(visit: visit, config: Config())
        #expect(!more.done && more.new == 1)
    }

    /// ⧉ and RTL: the folder's effective `spread` and `spread-direction` (its own, inherited or loupe.conf's); RTL only
    /// with two pages on.
    @Test func spreadBadgesFromFolderKeys() {
        let settings = FolderSettings(database: nil)
        settings.set("spread", "yes", for: dir("/comics"))
        settings.set("spread-direction", "rtl", for: dir("/comics/manga"))
        settings.set("spread-direction", "rtl", for: dir("/photos"))
        func card(_ path: String, base: Config = Config()) -> CardSummary {
            FolderCardFacts().cardSummary(visit: nil,
                                          config: FolderCardFacts.config(for: dir(path), base: base, settings: settings))
        }
        #expect(card("/comics/a").twoPages && !card("/comics/a").rightToLeft)
        #expect(card("/comics/manga/vol1").twoPages && card("/comics/manga/vol1").rightToLeft)
        #expect(!card("/photos").twoPages && !card("/photos").rightToLeft)
        var spread = Config()
        spread.spread = true
        #expect(card("/other", base: spread).twoPages)
        #expect(!card("/other").twoPages)
        #expect(FolderCardFacts.config(for: dir("/x"), base: spread, settings: nil).spread)
    }

    @Test func problemMaps() {
        #expect(FolderCardFacts(problem: .broken).cardSummary(visit: nil, config: Config()).problem == .broken)
        #expect(FolderCardFacts(problem: .offline).cardSummary(visit: nil, config: Config()).problem == .offline)
        #expect(FolderCardFacts().cardSummary(visit: nil, config: Config()).problem == nil)
    }

    /// `folder-cards` is kept like `browser-sort`: a folder's own, else its nearest ancestor's, else loupe.conf's.
    @Test func cardStyleInherits() {
        let settings = FolderSettings(database: nil)
        #expect(CardStyle.forFolder(dir("/photos/a"), settings: settings, fallback: .posters) == .posters)
        #expect(CardStyle.forFolder(dir("/photos/a"), settings: settings, fallback: .list) == .list)
        settings.set(CardStyle.settingKey, "cards", for: dir("/photos"))
        #expect(CardStyle.settingKey == "folder-cards")
        #expect(CardStyle.forFolder(dir("/photos"), settings: settings, fallback: .posters) == .cards)
        #expect(CardStyle.forFolder(dir("/photos/a/b"), settings: settings, fallback: .list) == .cards)
        settings.set(CardStyle.settingKey, "list", for: dir("/photos/a"))
        #expect(CardStyle.forFolder(dir("/photos/a/b"), settings: settings, fallback: .posters) == .list)
        #expect(CardStyle.forFolder(dir("/photos"), settings: settings, fallback: .posters) == .cards)
        // Text that is no style falls back.
        settings.set(CardStyle.settingKey, "huge", for: dir("/other"))
        #expect(CardStyle.forFolder(dir("/other"), settings: settings, fallback: .cards) == .cards)
        #expect(CardStyle.forFolder(dir("/photos"), settings: nil, fallback: .list) == .list)
    }
}

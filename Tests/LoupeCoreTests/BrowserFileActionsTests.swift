import Foundation
import Testing
@testable import LoupeCore

@Suite struct BrowserFileActionsTests {
    private let fm = FileManager.default

    private func folder() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("loupe-actions-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private final class Moves: PathMoving, @unchecked Sendable {
        var seen: [(String, String)] = []
        func movePaths(from: URL, to: URL) { seen.append((from.path, to.path)) }
    }

    @Test func validateRejects() {
        #expect(BrowserFileActions.validate("") == .empty)
        #expect(BrowserFileActions.validate("  ") == .empty)
        #expect(BrowserFileActions.validate("a/b") == .slash)
        #expect(BrowserFileActions.validate("a:b") == .colon)
        #expect(BrowserFileActions.validate(".x") == .leadingDot)
        #expect(BrowserFileActions.validate("ok.jpg") == nil)
        #expect(RenameProblem.allCases.allSatisfy { !$0.text.isEmpty })
    }

    @Test func renameFile() throws {
        let root = try folder()
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: a)
        let moves = Moves()
        let new = try BrowserFileActions(stores: [moves]).rename(a, to: "b.jpg")
        #expect(new.lastPathComponent == "b.jpg")
        #expect(fm.fileExists(atPath: new.path) && !fm.fileExists(atPath: a.path))
        #expect(moves.seen.map(\.1) == [new.path])
    }

    @Test func renameToExistingFails() throws {
        let root = try folder()
        defer { try? fm.removeItem(at: root) }
        for n in ["a.jpg", "b.jpg"] { try Data(n.utf8).write(to: root.appendingPathComponent(n)) }
        let moves = Moves()
        #expect(throws: RenameProblem.exists) {
            try BrowserFileActions(stores: [moves]).rename(root.appendingPathComponent("a.jpg"), to: "b.jpg")
        }
        #expect(moves.seen.isEmpty)
        #expect(throws: RenameProblem.slash) {
            try BrowserFileActions(stores: []).rename(root.appendingPathComponent("a.jpg"), to: "x/y")
        }
    }

    @Test func renameToSameNameDifferentCase() throws {
        let root = try folder()
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: a)
        let new = try BrowserFileActions(stores: []).rename(a, to: "A.jpg")
        #expect(try fm.contentsOfDirectory(atPath: root.path) == ["A.jpg"])
        #expect(new.lastPathComponent == "A.jpg")
    }

    @Test func renameFolderMovesNestedPositions() throws {
        let root = try folder()
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        try fm.createDirectory(at: old.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let positions = FolderPositions(database: nil)
        positions.record(folder: old.appendingPathComponent("sub"), file: "1.jpg")
        positions.record(folder: old, file: "2.jpg")
        _ = try BrowserFileActions(stores: [positions]).rename(old, to: "new")
        let new = root.appendingPathComponent("new")
        #expect(positions.fileName(in: new.appendingPathComponent("sub")) == "1.jpg")
        #expect(positions.fileName(in: new) == "2.jpg")
        #expect(positions.fileName(in: old) == nil)
    }

    @Test func renameMovesRecentSessionsSettingsPins() throws {
        let root = try folder()
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        let recent = RecentStore(database: nil)
        recent.entered(old, kind: .folder, gallery: nil, title: nil, clearsGallery: false)
        let settings = FolderSettings(database: nil)
        settings.set("browser-sort", "date", for: old)
        let places = BrowserPlaces(database: nil)
        places.pin(old)
        let sessions = SessionStore(database: nil)
        sessions.saveLast(SessionSnapshot(windows: [.init(frame: .zero, screen: nil, fullScreen: false, selected: 0, tabs: [.file(path: old.appendingPathComponent("1.jpg").path, view: nil)])]))
        _ = try BrowserFileActions(stores: [recent, settings, places, sessions]).rename(old, to: "new")
        #expect(recent.shown(limit: 10).map(\.path) == [new.path])
        #expect(settings.ownValues(for: new)["browser-sort"] == "date")
        #expect(settings.ownValues(for: old).isEmpty)
        #expect(places.pins().map(\.path) == [new.path])
        #expect(sessions.last()?.windows.first?.tabs.first == .file(path: new.appendingPathComponent("1.jpg").path, view: nil))
    }

    @Test func renamedFileFollowsInPositionsAndRecent() {
        let positions = FolderPositions(database: nil)
        positions.record(folder: URL(fileURLWithPath: "/x"), file: "a.jpg")
        let recent = RecentStore(database: nil)
        recent.entered(URL(fileURLWithPath: "/x"), kind: .folder, gallery: nil, title: nil, clearsGallery: false)
        recent.viewed(URL(fileURLWithPath: "/x"), file: "a.jpg", index: 0, count: 3)
        for store in [positions, recent] as [any PathMoving] {
            store.movePaths(from: URL(fileURLWithPath: "/x/a.jpg"), to: URL(fileURLWithPath: "/x/b.jpg"))
        }
        #expect(positions.fileName(in: URL(fileURLWithPath: "/x")) == "b.jpg")
        #expect(recent.shown(limit: 10).first?.file == "b.jpg")
    }

    @Test func trashUsesTrasher() throws {
        final class Trashed: @unchecked Sendable { var urls: [URL] = [] }
        let trashed = Trashed()
        let actions = BrowserFileActions(stores: [], trasher: { trashed.urls.append($0) })
        try actions.trash(URL(fileURLWithPath: "/x/a.jpg"), permanently: false)
        #expect(trashed.urls.map(\.path) == ["/x/a.jpg"])
    }

    @Test func noTrashOnVolume() {
        let actions = BrowserFileActions(stores: [], trasher: { _ in throw CocoaError(.featureUnsupported) })
        #expect(throws: BrowserTrashError.noTrash) { try actions.trash(URL(fileURLWithPath: "/x/a.jpg"), permanently: false) }
    }

    @Test func permanentDeleteRemoves() throws {
        let root = try folder()
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: a)
        try BrowserFileActions(stores: [], trasher: { _ in Issue.record("not to the Trash") }).trash(a, permanently: true)
        #expect(!fm.fileExists(atPath: a.path))
    }
}

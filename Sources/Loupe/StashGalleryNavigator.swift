import Foundation
import LoupeCore
import StashKitUI

/// Folder steps through the Stash gallery list a gallery was opened from (Stash spec §2.3): `StashGalleryList` pages
/// the list, `StashLibrary` maps each gallery's path (mounting its share), a plain `FolderNavigator` lists it. The end
/// and the skipped galleries are said in the viewer's toast.
enum StashGalleryNavigator {
    @MainActor static func make(list context: StashGalleryListContext, library: StashLibrary,
                                toast: ToastView) -> ListFolderNavigator {
        let list = StashGalleryList(variables: context.variables, finder: library.client)
        let lister = FolderNavigator()
        let tidy = Settings.shared.config.stashTitleTidy
        let say: @Sendable (String) -> Void = { text in Task { @MainActor in toast.show(text) } }
        return ListFolderNavigator(
            start: context.index,
            next: { index, step in
                switch try await list.step(from: index, step) {
                case .gallery(let gallery, let index, let count):
                    // `StashGalleryList` only gives galleries with a path.
                    let title = StashGalleryTitle.display(title: gallery.title, path: gallery.path, tidy: tidy)
                    return .item(title: title, path: gallery.path ?? "", index: index, count: count, id: gallery.id)
                case .end:
                    return .end
                }
            },
            resolve: { path in await library.resolve(path).mapError { $0 as Error } },
            contents: { url in try await lister.contents(of: url) },
            onEnd: { say("End of the Stash list") },
            onSkip: say)
    }
}

/// Bounded, server-ordered window of gallery pages for Loupe's folder filmstrip.
actor StashFolderStripSource: FolderStripSource {
    private let finder: StashGalleryFinding
    private let variables: Data
    private let initialIndex: Int
    private let resolve: @Sendable (String) async -> Result<URL, Error>
    private let fallback: @Sendable (String) async throws -> StashGallery?
    private let tidy: Bool
    private let disk = FolderStripListing()
    // Use the same page size as StashGalleryList; retain only the displayed page and its neighbours.
    private let pageSize = 40
    private var entries: [String: (gallery: StashGallery, index: Int, count: Int)] = [:]
    init(context: StashGalleryListContext, library: StashLibrary, tidy: Bool) {
        finder = library.client; variables = context.variables; initialIndex = context.index; self.tidy = tidy
        resolve = { path in await library.resolve(path).mapError { $0 as Error } }
        let client = library.client
        fallback = { try await client.gallery(id: $0) }
    }
    func rows(around id: FolderStripID) async throws -> [FolderStripEntry] {
        guard case .gallery(let id) = id else { return [] }
        let index = entries[id]?.index ?? initialIndex, page = index / pageSize + 1
        let center = try await finder.findGalleries(variables: variables, page: page, perPage: pageSize)
        try Task.checkCancellation()
        var pages = [page: center]
        for neighbour in [page - 1, page + 1] where neighbour > 0 && (neighbour - 1) * pageSize < center.count {
            try Task.checkCancellation()
            if let found = try? await finder.findGalleries(variables: variables, page: neighbour, perPage: pageSize) { pages[neighbour] = found }
        }
        try Task.checkCancellation()
        var next: [String: (gallery: StashGallery, index: Int, count: Int)] = [:]
        var rows: [FolderStripEntry] = []
        for n in pages.keys.sorted() {
            guard let found = pages[n] else { continue }
            for (offset, gallery) in found.galleries.enumerated() where gallery.path != nil {
                next[gallery.id] = (gallery, (n - 1) * pageSize + offset, found.count)
                rows.append(FolderStripEntry(id: .gallery(gallery.id), title: StashGalleryTitle.display(title: gallery.title, path: gallery.path, tidy: tidy)))
            }
        }
        entries = next
        return rows
    }
    func children(of id: FolderStripID) async throws -> [FolderStripEntry] { [] }
    func target(for id: FolderStripID) async throws -> FolderTarget? {
        guard case .gallery(let id) = id else { return nil }
        let record = entries[id]
        let gallery: StashGallery?
        if let record { gallery = record.gallery } else { gallery = try await fallback(id) }
        guard let gallery, let path = gallery.path else { return nil }
        let url = try await resolve(path).get()
        try Task.checkCancellation()
        guard var target = try await disk.target(for: .folder(url)) else { return nil }
        target.listID = id
        target.listIndex = record?.index
        let title = StashGalleryTitle.display(title: gallery.title, path: path, tidy: tidy)
        target.label = record.map { ListFolderNavigator.label(title: title, index: $0.index, count: $0.count) } ?? title
        return target
    }
    func index(of id: String) -> Int? { entries[id]?.index }
}

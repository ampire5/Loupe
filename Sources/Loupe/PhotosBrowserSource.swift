import AppKit
import HomeScreenKit
import HomeScreenModel
import LoupeCore

/// Photos is another Home source. The released browser handles history, scroll anchors and selection.
@MainActor final class PhotosBrowserSource {
    weak var view: HomeBrowserView?
    var onOpen: ((OpenTarget, HomeClick) -> Void)?
    private let library: any PhotosLibraryAccess
    private let sorts: PhotosSortStore
    private var displayedSorts: [String: BrowserSort] = [:]
    private var collections: [String: PhotosCollection] = [:]
    private var covers: [String: URL] = [:]
    private var pictures: Task<Void, Never>?
    private var observation: (any PhotosChangeObservation)?
    private var listingTask: Task<Void, Never>?
    private var generation = 0
    private var wanted: [String] = []
    private var requested = Set<String>()
    private var picturePixels = 0
    init(library: any PhotosLibraryAccess = PhotosLibrary.shared, sorts: PhotosSortStore? = nil) {
        self.library = library
        self.sorts = sorts ?? .shared
    }

    func sort(for source: String) -> BrowserSort {
        let id = PhotosLocation.collectionID(source)
        let folder = id == nil || id.flatMap { collections[$0]?.isFolder } == true
        let sort = sorts.sort(for: source, default: folder ? .standard : BrowserSort(key: .date, ascending: true))
        displayedSorts[source] = sort
        return sort
    }

    func setSort(_ sort: BrowserSort, for source: String) {
        displayedSorts[source] = sort
        sorts.setSort(sort, for: source)
    }
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused { stop() }
            else if case .source(let id) = view?.location, PhotosLocation.owns(id) { view?.reload() }
        }
    }

    func info(_ source: String) -> HomeSourceInfo {
        let id = PhotosLocation.collectionID(source)
        if id == PhotosLocation.library {
            return HomeSourceInfo(title: "Library", sortKeys: [.name, .date], noun: "photo", emptyHint: "No photos in your library")
        }
        let folder = id == nil || id.flatMap { collections[$0]?.isFolder } == true
        return HomeSourceInfo(title: id.flatMap { collections[$0]?.title } ?? "Photos",
                              sortKeys: folder ? [.name] : [.name, .date],
                              noun: folder ? "collection" : "photo",
                              emptyHint: folder ? "No albums in Photos" : "No photos in this album")
    }

    func list(_ source: String) -> AsyncThrowingStream<BrowserListing, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    try await library.authorize()
                    guard !Task.isCancelled else { continuation.finish(); return }
                    if observation == nil {
                        observation = library.observeChanges { [weak self] in
                            Task { @MainActor in
                                guard let self, self.view?.isHidden == false else { return }
                                self.stopPictures()
                                self.view?.reload()
                            }
                        }
                    }
                    let id = PhotosLocation.collectionID(source)
                    if id == nil || id.flatMap({ collections[$0]?.isFolder }) == true {
                        var children = try await library.collections(in: id)
                        if id == nil {
                            children.insert(PhotosCollection(id: PhotosLocation.library, title: "Library", isFolder: false), at: 0)
                        }
                        let listed = children
                        let entries = await Task.detached(priority: .userInitiated) {
                            listed.map { item in
                                BrowserEntry(url: URL(string: "loupe-photos://collection")!, name: item.title,
                                             kind: .collection, key: "photos-collection:" + item.id,
                                             subtitle: item.id == PhotosLocation.library ? "All Photos" : item.isFolder ? "Folder" : "Album",
                                             leads: item.id == PhotosLocation.library)
                            }
                        }.value
                        guard !Task.isCancelled else { continuation.finish(); return }
                        for item in children { collections[item.id] = item }
                        continuation.yield(BrowserListing(entries: entries, complete: true))
                    } else if let id {
                        let assets = try await library.assets(in: id)
                        let entries = await Task.detached(priority: .userInitiated) {
                            PhotosAlbumListing.entries(assets, album: id)
                        }.value
                        guard !Task.isCancelled else { continuation.finish(); return }
                        continuation.yield(BrowserListing(entries: entries, complete: true))
                    }
                    // Keep the stream alive only through the observer; reload replaces it when Photos changes.
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() } else { continuation.finish(throwing: error) }
                }
            }
            listingTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func open(_ entry: BrowserEntry, how: HomeClick, sort: BrowserSort? = nil) {
        if entry.id.hasPrefix("photos-collection:") {
            let id = String(entry.id.dropFirst("photos-collection:".count))
            stopPictures()
            view?.show(.source(PhotosLocation.collection(id)), selecting: nil)
        } else if let album = PhotosLocation.album(in: entry.url), let asset = PhotosLocation.asset(in: entry.url) {
            let source = PhotosLocation.collection(album)
            if let chosen = sort ?? displayedSorts[source] { sorts.setSort(chosen, for: source) }
            view?.lastOpenedID = entry.id
            onOpen?(.photos(album: album, asset: asset), how)
        }
    }

    func wantImages(_ ids: [String], width: CGFloat) {
        guard !isPaused else { return }
        let pixels = max(1, Int(width * (view?.window?.backingScaleFactor ?? 2)))
        let keep = Set(ids)
        if pixels != picturePixels {
            stopPictures()
            picturePixels = pixels
        }
        // Retain only the live area's IDs; revisiting a dropped cell asks for its cached PhotoKit picture again.
        requested.formIntersection(keep)
        wanted = ids.filter { !requested.contains($0) }
        if pictures != nil { return }
        let generation = self.generation
        pictures = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !wanted.isEmpty {
                let id = wanted.removeFirst()
                requested.insert(id)
                var url: URL?
                if id.hasPrefix("photos-collection:") {
                    let collection = String(id.dropFirst("photos-collection:".count))
                    if collections[collection]?.isFolder == false {
                        if let cover = covers[collection] { url = cover }
                        else if let first = try? await library.cover(in: collection) {
                            url = first
                            covers[collection] = url
                        }
                    }
                } else { url = URL(string: id) }
                let image = if let url { try? await library.thumbnail(url, pixels: pixels) } else { nil as CGImage? }
                guard !Task.isCancelled, self.generation == generation else { return }
                view?.setImage(image, for: id)
                view?.stopWaiting(for: [id])
            }
            if self.generation == generation { pictures = nil }
        }
    }

    func stopPictures() {
        generation += 1
        pictures?.cancel()
        pictures = nil
        wanted = []
        requested = []
        covers = [:]
    }

    func stop() {
        stopPictures()
        listingTask?.cancel()
        listingTask = nil
        observation = nil
    }
}

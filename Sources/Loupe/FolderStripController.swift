import AppKit
import Filmstrip
import FilmstripModel
import HomeScreenModel
import HomeScreenKit
import LoupeCore

@MainActor final class FolderStripController {
    let view = FolderStripSurface()
    private let strip = FilmstripRowsView()
    private let card = FolderStripCardView()
    private var source: any FolderStripSource
    private var rowsVersion: UInt64 = 0
    private let store: ThumbnailStore
    private var state = FolderStripState()
    private var actualOpened: FolderStripID?
    private var branchRoot: FolderStripID?
    private var scroll = FilmstripScroll()
    private var rows: [FolderStripEntry] = []
    private var visible = false
    private var load: Task<Void, Never>?
    private var opening: Task<Void, Never>?
    private var pictures: Task<Void, Never>?
    private var rest: Timer?
    private static var nextCoverClient = 1 << 48
    private let coverClient: Int
    private var coverWanted: [URL] = []
    private var coverSend: Task<Void, Never>?
    private var metadata: [FolderStripID: (text: String, images: [CGImage], count: Int?, progress: Double?)] = [:]
    var onPreview: ((FolderStripID?, CGImage?) -> Void)?
    var onOpen: ((FolderTarget, FolderStripID, UInt64) -> Void)?
    var onMessage: ((String) -> Void)?
    var visit: ((URL) -> FolderVisit?)?

    init(source: any FolderStripSource, store: ThumbnailStore) {
        coverClient = Self.nextCoverClient; Self.nextCoverClient += 1
        self.source = source; self.store = store
        strip.frame = view.bounds; strip.autoresizingMask = [.width, .height]
        view.addSubview(strip); strip.card = card
        strip.activeLabel = "Open folder"; strip.activeMarker = "●"
        strip.selectionHint = "Selected · click or Return to open"
        strip.onBrowse = { [weak self] row in
            guard let self else { return }; stopMotion(); scroll.settle(); browse(row); place(animated: false)
        }
        view.setAccessibilityElement(true); view.setAccessibilityRole(.list); view.setAccessibilityLabel("Folders")
        view.onLayout = { [weak self] in self?.relayout() }
        view.onKey = { [weak self] in self?.key($0) ?? false }
        strip.onVisibleChange = { [weak self] in self?.readPictures() }
        strip.onPress = { [weak self] in self?.press($0) }
        strip.onPressBegan = { [weak self] in self?.stopMotion() }
        strip.onDrag = { [weak self] in self?.drag($0) }
        strip.onDragEnd = { [weak self] in self?.settle() }
        strip.onStripScroll = { [weak self] in self?.scrolled($0) }
    }
    func replaceSource(_ source: any FolderStripSource, opened id: FolderStripID) {
        cancelInteraction(); load?.cancel(); pictures?.cancel()
        self.source = source; rows = []; rowsVersion &+= 1
        strip.forgetAll(); metadata.removeAll(); actualOpened = id; branchRoot = id; state.synchronize(id)
        if visible { reload() }
    }
    func setVisible(_ shown: Bool) {
        guard visible != shown else { return }
        visible = shown
        if shown { reload(); readPictures() } else { cancelInteraction(); load?.cancel(); load = nil; pictures?.cancel(); pictures = nil; sendCovers([]) }
    }
    func synchronize(opened id: FolderStripID) {
        guard actualOpened != id else { return }
        cancelInteraction()
        if let row = rows.first(where: { $0.id == id }) { branchRoot = row.parent ?? id }
        else if case .folder(let folder) = id, case .folder(let root) = branchRoot,
                folder.path.hasPrefix(root.path + "/") { /* A photo-less branch opened a deeper descendant. */ }
        else { branchRoot = id }
        actualOpened = id; state.synchronize(id)
        if visible { reload() }
    }
    func isWanted(_ id: FolderStripID, generation: UInt64) -> Bool {
        visible && state.generation == generation && state.browsed == id
    }
    private var index: Int? { rows.firstIndex { $0.id == state.browsed } }
    private func reload() {
        guard visible, let opened = state.opened else { return }
        load?.cancel()
        let source = self.source, root = branchRoot ?? opened
        load = Task { [weak self] in
            do {
                var rows = try await source.rows(around: root)
                try Task.checkCancellation()
                let children = try await source.children(of: root)
                try Task.checkCancellation()
                guard let self, visible, state.opened == opened else { return }
                if let i = rows.firstIndex(where: { $0.id == root }) { rows.insert(contentsOf: children, at: i + 1) }
                if rows.isEmpty, case .folder(let folder) = opened { rows = [FolderStripEntry(id: opened, title: folder.lastPathComponent)] }
                self.rows = rows; rowsVersion &+= 1
                if !rows.contains(where: { $0.id == opened }), case .folder(let folder) = actualOpened {
                    let ancestors = rows.filter {
                        guard case .folder(let candidate) = $0.id else { return false }
                        return folder.path.hasPrefix(candidate.path + "/")
                    }
                    if let closest = ancestors.max(by: { $0.depth < $1.depth }) { state.synchronize(closest.id) }
                }
                strip.forgetAll(); metadata.removeAll()

                relayout(); readPictures()
            } catch is CancellationError {} catch { self?.onMessage?("Cannot list folders: \(error.localizedDescription)") }
        }
    }
    private func title(_ row: FolderStripEntry) -> String { row.title }
    private func relayout() {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let width = max(0, Double(view.bounds.width) - 20), height = Double(view.bounds.height)
        let caption = FilmstripRowsView.currentCaptionHeight
        let cardHeight = min(Double(card.preferredHeight), max(0, height - caption - 48))
        let currentPicture = max(24, min(width - 16, (height - cardHeight - caption - 12) * 1.5))
        let layout = FilmstripRows(itemCount: rows.count, aspects: Array(repeating: 1.5, count: rows.count),
                                   length: height, width: width, rowPicture: max(16, currentPicture * 0.55),
                                   currentPicture: currentPicture, cardHeight: cardHeight,
                                   captionHeight: FilmstripRowsView.captionHeight,
                                   currentCaptionHeight: FilmstripRowsView.currentCaptionHeight)
        if let index { scroll.layoutChanged(keeping: index, layout: layout) }
        strip.layout = layout
        strip.indent = { [weak self] i in self?.rows.indices.contains(i) == true && self?.rows[i].depth == 1 ? 18 : 0 }
        place(animated: false)
    }
    private func place(animated: Bool) {
        guard let index, rows.indices.contains(index) else { return }
        let row = rows[index]
        view.setAccessibilityValue(row.title)
        let info = metadata[row.id]
        card.update(text: info?.text ?? "", images: info?.images ?? [])
        if abs(strip.layout.cardHeight - min(Double(card.preferredHeight), max(0, Double(view.bounds.height) - FilmstripRowsView.currentCaptionHeight - 48))) > 0.5 {
            relayout(); return
        }
        strip.playing = rows.firstIndex { $0.id == state.opened }
        strip.show(offset: scroll.offset ?? strip.layout.centre(of: index), current: index,
                   expansion: scroll.isMoving ? 0 : 1, animated: animated)
    }
    private func browse(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        let id = rows[i].id
        if state.browsed != id { _ = state.browse(id); opening?.cancel() }
    }
    private func stopMotion() {
        rest?.invalidate(); rest = nil
        scroll.takeOver()
    }
    func cancelInteraction() {
        stopMotion(); scroll.settle(); state.cancel()
        opening?.cancel(); opening = nil
        onPreview?(nil, nil); place(animated: false)
    }
    private func press(_ i: Int) { stopMotion(); scroll.settle(); browse(i); place(animated: true); commit() }
    private func scrolled(_ event: NSEvent) {
        guard visible, let index else { return }
        if !event.hasPreciseScrollingDeltas {
            if event.scrollingDeltaY != 0 {
                scroll.settle(); browse(max(0, min(rows.count - 1, index + (event.scrollingDeltaY > 0 ? -1 : 1))))
                place(animated: true)
            }
            return
        }
        let outcome = scroll.event(fingerDelta: Double(event.scrollingDeltaY), crossDelta: Double(event.scrollingDeltaX),
                                   phase: ScrollPhase(rawValue: event.phase.rawValue), momentum: ScrollPhase(rawValue: event.momentumPhase.rawValue),
                                   layout: strip.layout, current: index, now: event.timestamp)
        apply(outcome)
        rest?.invalidate()
        if scroll.isMoving {
            rest = Timer.scheduledTimer(withTimeInterval: FilmstripScroll.restDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.settle() }
            }
        }
    }
    private func drag(_ dy: CGFloat) {
        guard let index else { return }
        apply(scroll.drag(by: Double(dy), layout: strip.layout, current: index))
    }
    private func apply(_ outcome: FilmstripScroll.Outcome) {
        if let i = outcome.item { browse(i) }
        place(animated: false)
        if outcome.commit { settle() }
    }
    private func settle() {
        rest?.invalidate(); rest = nil
        if let found = scroll.settled(layout: strip.layout) { browse(found.item) }
        scroll.settle(); place(animated: true)
    }
    private func commit() {
        guard visible, let id = state.settle() else { return }
        opening?.cancel()
        let token = state.generation, source = self.source
        opening = Task { [weak self] in
            do {
                let target = try await source.target(for: id)
                try Task.checkCancellation()
                guard let self, isWanted(id, generation: token) else { return }
                if let target { onOpen?(target, id, token) }
                else { onMessage?("No photos in this folder"); cancelInteraction() }
            } catch is CancellationError {} catch {
                guard let self, isWanted(id, generation: token) else { return }
                onMessage?("Cannot open folder: \(error.localizedDescription)"); cancelInteraction()
            }
        }
    }
    private func key(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 53: cancelInteraction()
        case 36, 76: stopMotion(); commit()
        case 125, 126:
            guard let index else { return true }
            stopMotion(); scroll.settle(); browse(max(0, min(rows.count - 1, index + (event.keyCode == 125 ? 1 : -1))))
            place(animated: true)
        default: return false
        }
        return true
    }
    /// Coalesce wants; the existing queue owns admission, foreground pause and cancellation accounting.
    private func sendCovers(_ urls: [URL]) {
        coverWanted = urls
        guard coverSend == nil else { return }
        coverSend = Task { [weak self] in
            guard let self else { return }
            while true {
                let wanted = coverWanted, version = rowsVersion
                let store = self.store, client = coverClient
                let mosaicLayout = HomeMosaic.Layout(rawValue: Settings.shared.config.folderCover.rawValue) ?? .hero
                await store.coverQueue.want(wanted.map(\.path), visible: wanted.count, client: client,
                    // Conservatively share Home's measured single network lane even for local folders.
                    // Classification itself can block; resolving is done inside the admitted work below.
                    isNetwork: { _ in true }, work: { [weak self] path in
                        let folder = URL(fileURLWithPath: path)
                        let resolved = await store.folderLocation(folder)
                        let location: ThumbnailLocation?, network: Bool
                        switch resolved {
                        case .located(let found): location = found; network = found.isNetwork
                        case .unknown(let isNetwork): location = nil; network = isNetwork
                        case .notNow: return false
                        }
                        guard !Task.isCancelled else { return true }
                        guard let made = await store.folderCard(folder, archive: ArchivePath.isArchive(folder), in: location,
                                                               network: network, maxPixel: 320) else { return false }
                        guard !Task.isCancelled else { return true }
                        let cover = HomeMosaic.make(made.images, size: CGSize(width: 320, height: 320.0 / 1.5), layout: mosaicLayout)
                        await MainActor.run { [weak self] in
                            guard let self, visible, rowsVersion == version, coverWanted.contains(folder),
                                  let i = rows.firstIndex(where: { $0.id == .folder(folder) }) else { return }
                            var lines: [String] = []
                            if let summary = made.summary {
                                lines.append("\(summary.photos) photos · \(summary.folders) folders")
                                if let first = summary.first, let last = summary.last {
                                    lines.append(first.formatted(date: .abbreviated, time: .omitted) + " – " + last.formatted(date: .abbreviated, time: .omitted))
                                }
                            }
                            let visit = visit?(folder)
                            if let visit { lines.append(visit.done ? "Viewed" : "\(visit.index + 1) / \(visit.count)") }
                            let names = rows.filter { $0.parent == .folder(folder) }.map(\.title)
                            if !names.isEmpty { lines.append(names.joined(separator: " · ")) }
                            metadata[.folder(folder)] = (lines.joined(separator: "\n"), Array(made.images.prefix(5)), made.summary?.photos, visit?.progress())
                            strip.setImage(cover, forItem: i)
                            strip.setRow(i, title: title(rows[i]), detail: made.summary.map { "\($0.photos) photos" } ?? "", progress: visit?.progress())
                            if state.browsed == .folder(folder) { self.place(animated: false) }
                        }
                        return true
                    })
                if wanted == coverWanted { coverSend = nil; return }
            }
        }
    }
    private func readPictures() {
        pictures?.cancel()
        guard visible else { return }
        let wanted = strip.visibleItems.filter { rows.indices.contains($0) }
        let ids = Set(wanted.map { rows[$0].id })
        for id in metadata.keys where !ids.contains(id) {
            if let i = rows.firstIndex(where: { $0.id == id }) { strip.setImage(nil, forItem: i) }
        }
        for i in wanted { strip.setRow(i, title: title(rows[i]), detail: metadata[rows[i].id]?.count.map { "\($0) photos" } ?? "", progress: metadata[rows[i].id]?.progress) }
        sendCovers(wanted.compactMap { if case .folder(let url) = rows[$0].id { url } else { nil } })
        metadata = metadata.filter { ids.contains($0.key) }
        let snapshot = rows, version = rowsVersion
        pictures = Task { [weak self] in
            guard let self else { return }
            for i in wanted {
                guard !Task.isCancelled, visible, rowsVersion == version else { return }
                let row = snapshot[i]
                guard case .folder(let folder) = row.id else { continue }
                if metadata[row.id] != nil { continue }
                let urls = await store.folderSamples(folder, limit: 5)
                var images: [CGImage] = []
                for url in urls {
                    guard !Task.isCancelled else { return }
                    if let image = await store.catalogThumbnail(url, maxPixel: 320) { images.append(image) }
                }
                let counts = await store.knownCounts([folder])
                guard !Task.isCancelled, visible, rowsVersion == version else { return }
                if metadata[row.id] != nil { continue }
                let visit = visit?(folder), count = counts[folder]
                var lines = [row.title]
                if let count { lines.append("\(count) photos") }
                if let visit { lines.append(visit.done ? "Viewed" : "\(visit.index + 1) / \(visit.count)") }
                let children = snapshot.filter { $0.parent == row.id }.map(\.title)
                if !children.isEmpty { lines.append(children.joined(separator: " · ")) }
                metadata[row.id] = (lines.joined(separator: "\n"), images, count, visit?.progress())
                strip.setRow(i, title: title(row), detail: count.map { "\($0) photos" } ?? "", progress: visit?.progress())
                strip.setImage(images.first, forItem: i)
                if state.browsed == row.id { place(animated: false) }
            }
        }
    }
}

@MainActor final class FolderStripSurface: NSView {
    var onLayout: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
}

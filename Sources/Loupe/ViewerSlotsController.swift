import AppKit
import Slots
import SlotModel
import LoupeCore
import HomeScreenModel

/// Loupe's boundary: reserve the photo strip, persist slot settings, commit a still-current folder choice.
@MainActor final class ViewerSlotsController {
    let area = SlotOverlayArea()
    let preview = FolderPreviewView()
    private let host: SlotsController
    private let folders: FolderStripController
    private let session: ViewerSession
    private var smartPanel: SmartZoomPanel?
    private var active = true
    private var gallerySource: StashFolderStripSource?
    private var galleryFolder: URL?
    private var galleryID: String?
    private var diskSource: FolderStripListing
    private var archives = Settings.shared.config.archiveFolders
    var onInsets: ((ViewerSlotLayout.Insets) -> Void)?
    var onMessage: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onGallerySelected: ((String, URL, Int) -> Void)?
    private var appliedSlots = FolderSlotSettings.defaults
    private var insets = ViewerSlotLayout.Insets.zero

    init(container: NSView, above: NSView, session: ViewerSession, store: ThumbnailStore, positions: FolderPositions, makeSmartZoom: @escaping () -> SmartZoomPanel) {
        self.session = session
        let source = FolderStripListing(archives: Settings.shared.config.archiveFolders, sort: { folder in
            await MainActor.run { BrowserSort.forFolder(folder, settings: Settings.shared.folderSettings) }
        })
        diskSource = source
        folders = FolderStripController(source: source, store: store)
        folders.visit = { positions.visit(in: $0) }
        area.frame = container.bounds
        container.addSubview(area, positioned: .above, relativeTo: above)
        let backing = NSView(frame: area.bounds); area.addSubview(backing)
        host = SlotsController(container: area, above: backing)
        host.register(SlotTabDescriptor(id: FolderSlotSettings.folders, title: "Folders", symbol: "folder", singleton: true) { [weak folders, weak area] _ in
            guard let folders else { return nil }
            let page = SlotPage(view: folders.view, visibilityChanged: { [weak folders, weak area] shown in
                folders?.setVisible(shown && area?.isHidden == false)
            })
            page.cancelInteraction = { [weak folders] in folders?.cancelInteraction() }
            page.focus = { [weak folders] in guard let view = folders?.view else { return }; view.window?.makeFirstResponder(view) }
            return page
        })
        host.register(SlotTabDescriptor(id: FolderSlotSettings.smartzoom, title: "SmartZoom", symbol: "viewfinder", singleton: true) { [weak self] _ in
            guard let self else { return nil }
            let panel = smartPanel ?? makeSmartZoom()
            smartPanel = panel
            let page = SlotPage(view: panel.view, visibilityChanged: { [weak panel, weak area] shown in
                panel?.setVisible(shown && area?.isHidden == false)
            })
            page.isTyping = { [weak panel] in panel?.isInteracting == true }
            panel.interactionChanged = { [weak self] in self?.host.refreshLayout() }
            return page
        })
        appliedSlots = FolderSlotSettings.normalized(Settings.shared.config.slots)
        for edge in SlotEdge.allCases { host.configure(appliedSlots[edge] ?? SlotConfiguration(), edge: edge) }
        host.onLayout = { [weak self] video, _ in
            guard let self else { return }
            let next = ViewerSlotLayout.pinnedInsets(video: video, area: area.frame)
            guard next != insets else { return }; insets = next; onInsets?(next)
        }
        host.onPersist = { [weak self] edge, value in
            self?.appliedSlots[edge] = value
            Settings.shared.setSlot(edge, value)
        }
        host.onFocusContent = { [weak self] in self?.onFocus?() }
        host.onMessage = { [weak self] in self?.onMessage?($0) }
        folders.onMessage = { [weak self] in self?.onMessage?($0) }
        folders.onPreview = { [weak self] id, image in
            guard let self else { return }
            let title: String?
            switch id { case .folder(let url): title = url.lastPathComponent; case .gallery(let id): title = id; case nil: title = nil }
            preview.show(title: title, image: image)
        }
        folders.onOpen = { [weak self] target, id, generation in
            guard let self, folders.isWanted(id, generation: generation) else { return }
            if case .gallery(let galleryID) = id {
                if let index = target.listIndex { onGallerySelected?(galleryID, target.folder, index) }
                self.galleryID = galleryID; galleryFolder = target.folder.standardizedFileURL
            }
            session.openFolderStripTarget(target, isWanted: { [weak folders] in folders?.isWanted(id, generation: generation) ?? false }) { [weak self] opened in
                guard let self else { return }
                if opened {
                    preview.show(title: nil, image: nil)
                    if let edge = SlotEdge.allCases.first(where: { self.host.activeTab($0) == FolderSlotSettings.folders }) { host.choice(in: edge) }
                } else { folders.cancelInteraction() }
            }
        }
        host.start()
    }
    func applySettings(_ config: Config) {
        if config.archiveFolders != archives {
            archives = config.archiveFolders
            diskSource = FolderStripListing(archives: archives, sort: { folder in
                await MainActor.run { BrowserSort.forFolder(folder, settings: Settings.shared.folderSettings) }
            })
            if gallerySource == nil, let folder = session.playlist?.current.deletingLastPathComponent() {
                folders.replaceSource(diskSource, opened: .folder(folder))
            }
        }
        let incoming = FolderSlotSettings.normalized(config.slots)
        let changed = SlotEdge.allCases.filter { incoming[$0] != appliedSlots[$0] }
        appliedSlots = incoming
        for edge in changed { if let setting = incoming[edge] { host.configure(setting, edge: edge) } }
    }
    func useGalleries(_ source: StashFolderStripSource, id: String, folder: URL) {
        gallerySource = source; galleryID = id; galleryFolder = folder.standardizedFileURL
        folders.replaceSource(source, opened: .gallery(id))
    }
    func synchronize(folder: URL?) {
        guard let folder else { setActive(false); return }
        if gallerySource != nil, let galleryID, galleryFolder == folder.standardizedFileURL {
            folders.synchronize(opened: .gallery(galleryID))
        } else {
            if self.gallerySource != nil {
                self.gallerySource = nil; galleryID = nil; galleryFolder = nil
                folders.replaceSource(diskSource, opened: .folder(folder.standardizedFileURL))
            } else { folders.synchronize(opened: .folder(folder.standardizedFileURL)) }
        }
    }
    func setActive(_ enabled: Bool) {
        guard active != enabled else { return }; active = enabled
        area.isHidden = !enabled
        if !enabled { smartPanel?.setVisible(false); host.cancelInteraction(); folders.setVisible(false); preview.show(title: nil, image: nil) }
        else { host.refreshContents() }
    }
    func layout(in bounds: CGRect, top: CGFloat, bottom: CGFloat) {
        let frame = ViewerSlotLayout.area(in: bounds, top: top, bottom: bottom)
        if area.frame != frame { area.frame = frame; host.refreshLayout() }
    }
    func refreshSmartZoom() { smartPanel?.refresh() }
    func setSmartZoomEditing(_ editing: Bool) { smartPanel?.setProfileEditing(editing) }
    func showSmartZoom() {
        guard active else { return }
        let edge = SlotEdge.allCases.first(where: { host.tabIDs(in: $0).contains(FolderSlotSettings.smartzoom) }) ?? .right
        if !host.tabIDs(in: edge).contains(FolderSlotSettings.smartzoom) { host.add(FolderSlotSettings.smartzoom, edge: edge) }
        host.select(FolderSlotSettings.smartzoom, edge: edge)
        host.show(edge, focus: true)
    }
    func toggle(_ edge: SlotEdge) { if active { host.toggle(edge) } }
    func cancelInteraction() { folders.cancelInteraction() }
    func close() { host.cancelInteraction(); folders.setVisible(false); area.removeFromSuperview(); preview.removeFromSuperview() }
    func key(_ event: NSEvent) -> Bool {
        guard active else { return false }
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .control] {
            switch event.keyCode { case 123: toggle(.left); case 124: toggle(.right); case 125: toggle(.bottom); default: return false }
            return true
        }
        return false
    }
}

@MainActor final class SlotOverlayArea: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let found = super.hitTest(point)
        // Empty background is a positioning reference, never an input surface.
        return found === self || found?.superview === self && found?.subviews.isEmpty == true ? nil : found
    }
}

@MainActor final class FolderPreviewView: NSView {
    private let picture = CALayer()
    private let caption = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; isHidden = true
        picture.contentsGravity = .resizeAspect; layer?.addSublayer(picture)
        caption.textColor = .white; caption.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        caption.drawsBackground = true; caption.alignment = .center
        addSubview(caption)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func show(title: String?, image: CGImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.contents = image
        layer?.backgroundColor = image == nil ? NSColor.clear.cgColor : NSColor.black.cgColor
        caption.stringValue = title ?? ""; isHidden = title == nil
        CATransaction.commit()
    }
    override func layout() {
        super.layout(); picture.frame = bounds
        caption.frame = CGRect(x: max(8, bounds.midX - 150), y: bounds.maxY - 54, width: min(300, bounds.width - 16), height: 24)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

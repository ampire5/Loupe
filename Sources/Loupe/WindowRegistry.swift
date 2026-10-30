import AppKit
import LoupeCore
import StashKitUI

/// The viewer windows (each tab is a window of its own) and which one is in front (spec §2.1, §3.1). The session of
/// the last key viewer window is the cache's active one; it stays active while the app is in the background. Every
/// session is told whether its window can be seen. New tabs and windows (⌘T, ⌘N, the tab bar's +) are made here, and
/// every open from outside goes through `open` (spec §2.2).
@MainActor final class WindowRegistry {
    private struct Entry {
        let controller: ViewerWindowController
        var observers: [NSObjectProtocol]
        /// `activityRank`: larger = key more recently; 0 = never key.
        var rank = 0
        /// The visibility last sent to the session; nil before the first.
        var visible: Bool?
    }

    private var entries: [Entry] = []
    private var nextRank = 1
    /// The last key viewer window's controller; nil before the first and after the last closed. When it closes, the
    /// tab its group shows next or else the last key one left takes over (`closed`).
    private(set) var active: ViewerWindowController?
    /// The last viewer window closed (not when the app quits with windows open).
    var onLastClosed: (() -> Void)?
    /// The app is quitting (`applicationWillTerminate`): the windows closing then hand the active session to none.
    var isQuitting = false
    /// A new controller with the app's shared stores, already added (`AppDelegate.makeController`).
    var makeController: (() -> ViewerWindowController)?

    var controllers: [ViewerWindowController] { entries.map(\.controller) }

    /// The controller of the main window if it is a viewer, else `active` — for menu actions.
    var current: ViewerWindowController? {
        if let main = NSApp.mainWindow, let entry = entries.first(where: { $0.controller.window === main }) {
            return entry.controller
        }
        return active
    }

    /// Observes key, occlusion, miniaturize and close of the controller's window. The first one added becomes active at
    /// once: the launch's photo is planned without waiting for the window to become key.
    func add(_ controller: ViewerWindowController) {
        guard let window = controller.window, !entries.contains(where: { $0.controller === controller }) else { return }
        controller.registry = self
        controller.onStashPick = { [weak self, weak controller] pick in
            guard let self, let controller else { return false }
            return self.stashPick(pick, in: controller)
        }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name,
                     _ action: @escaping @MainActor (WindowRegistry, ViewerWindowController) -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak controller] _ in
                MainActor.assumeIsolated { if let self, let controller { action(self, controller) } }
            }
        }
        // A tab chosen in the tab bar becomes key; the one it hides may get no occlusion change of its own, so every
        // window is looked at again on each of these.
        let observers = [
            observe(NSWindow.didBecomeKeyNotification) { $0.becameKey($1) },
            observe(NSWindow.didChangeOcclusionStateNotification) { registry, _ in registry.refreshVisibility() },
            observe(NSWindow.didMiniaturizeNotification) { registry, _ in registry.refreshVisibility() },
            observe(NSWindow.didDeminiaturizeNotification) { registry, _ in registry.refreshVisibility() },
            observe(NSWindow.willCloseNotification) { $0.closed($1) },
            observe(NSWindow.didEnterFullScreenNotification) { registry, _ in registry.scheduleLastSave() },
            observe(NSWindow.didExitFullScreenNotification) { registry, _ in registry.scheduleLastSave() },
        ]
        entries.append(Entry(controller: controller, observers: observers))
        if active == nil { activate(controller) }
        scheduleLastSave()
    }

    /// `TabFacts.lastActive`: larger = key more recently.
    func activityRank(_ c: ViewerWindowController) -> Int {
        entries.first { $0.controller === c }?.rank ?? 0
    }

    func tabFacts() -> [TabFacts] {
        entries.map { $0.controller.tabFacts(rank: $0.rank) }
    }

    // MARK: Opening (spec §2.2)

    /// A file, folder or Stash gallery from outside the tab (Finder, `open`, the Dock, a hand-over, ⌘O): to the tab that
    /// already shows it, else to a new tab, a new window or the front tab by `open-in`; the tab it lands in comes
    /// forward, wherever it is (hidden, miniaturized, in a full-screen Space). `force`: a new tab or window whatever is
    /// open (`OpenForce`).
    /// `from`: the front tab (without: the current one, else the last key one left). The tab it lands in is made
    /// active before it is asked to open: its photo is read at once, not once the app is in front and its Space shown.
    /// `stashPick`: the click a Stash gallery is opened for (the tab it lands in enters it).
    /// `openIn`: instead of `open-in` (a Recent card's plain click: `.replace`, this tab). `returnTo`: the Home tab ⌘W
    /// goes back to when it lands in `from` itself.
    func open(_ target: OpenTarget, force: OpenForce? = nil, openIn: OpenIn? = nil, from: ViewerWindowController? = nil,
              stashPick: StashGalleryPick? = nil, returnTo: HomeTab? = nil) {
        let front = from ?? current ?? lastKey
        let decision = OpenRouter.route(target, tabs: tabFacts(), front: front.map(Self.tabID),
                                        openIn: openIn ?? Settings.shared.config.openIn, force: force)
        DebugLog.log("open \(Self.describe(target)): \(decision)")
        switch decision {
        case .focus(let tab, let url):
            guard let controller = tabController(tab) else { return }
            activate(controller)
            if let url { controller.open(url) }
            controller.bringToFront()
        case .newTab(let tab):
            guard let controller = makeTab(beside: tabController(tab) ?? front) else { return }
            activate(controller)
            controller.open(target, stashPick: stashPick)
            controller.bringToFront()
        case .newWindow:
            guard let (controller, fullScreen) = makeWindow(from: front) else { return }
            activate(controller)
            controller.open(target, stashPick: stashPick)
            controller.bringToFront()
            if fullScreen { controller.enterFullScreen() }
        case .replace(let tab):
            guard let controller = tabController(tab) else { return }
            activate(controller)
            controller.open(target, stashPick: stashPick, returnTo: controller === from ? returnTo : nil)
            controller.bringToFront()
        }
    }

    /// A gallery clicked in `controller`'s Stash: true when another tab takes it (spec §2.3) — a ⌘-click opens it in a
    /// new tab and a ⇧-click in a new window, whether it is open elsewhere or not; else the tab showing it, which then comes forward. Else the click
    /// opens it in its own tab, whatever `open-in` says.
    private func stashPick(_ pick: StashGalleryPick, in controller: ViewerWindowController) -> Bool {
        if pick.newWindow || pick.newTab {
            open(.stashGallery(id: pick.id), force: pick.newWindow ? .window : .tab, from: controller, stashPick: pick)
            return true
        }
        let decision = OpenRouter.route(.stashGallery(id: pick.id), tabs: tabFacts(), front: Self.tabID(controller),
                                        openIn: .replace)
        guard case .focus(let tab, _) = decision, tab != Self.tabID(controller),
              let shown = self.tabController(tab) else { return false }
        DebugLog.log("stash pick gallery \(pick.id): shown in another tab")
        shown.bringToFront()
        return true
    }

    private static func tabID(_ controller: ViewerWindowController) -> Int { controller.session.cacheID.raw }

    private func tabController(_ tab: Int) -> ViewerWindowController? {
        entries.first { Self.tabID($0.controller) == tab }?.controller
    }

    private static func describe(_ target: OpenTarget) -> String {
        switch target {
        case .file(let url): url.lastPathComponent
        case .folder(let url): url.lastPathComponent + "/"
        case .stashGallery(let id): "gallery \(id)"
        case .photos: "Photos album"
        }
    }

    // MARK: New tabs and windows

    /// ⌘T and the tab bar's +: a tab in `anchor`'s window (the current one's without), showing Stash or the Open panel
    /// (`startEmpty`). In full screen it joins the window in its Space.
    func newTab(beside anchor: ViewerWindowController? = nil) {
        guard (anchor ?? current)?.window != nil else {
            newWindow()
            return
        }
        makeTab(beside: anchor ?? current)?.startEmpty()
    }

    /// ⌘N: a window of its own, cascaded from `from`'s (the current one's without) at its size. From a window in full
    /// screen with `new-window-fullscreen=follow` it enters full screen in its own Space, and Stash or the Open panel
    /// comes once it is there.
    func newWindow(from anchor: ViewerWindowController? = nil) {
        guard let (controller, fullScreen) = makeWindow(from: anchor ?? current) else { return }
        if fullScreen {
            controller.enterFullScreen { [weak controller] in controller?.startEmpty() }
        } else {
            controller.startEmpty()
        }
    }

    // MARK: Browser tab keys

    /// The tabs closed lately, for File › Reopen Closed Tab (⇧⌘T).
    private var closedTabs = ClosedTabs()

    var canReopenTab: Bool { closedTabs.count > 0 }

    /// ⇧⌘T: the tab closed last, as a tab of the current window (a window of its own when none is left), restored as a
    /// session tab is: a file gone or a share down gives Home with a toast.
    func reopenClosedTab() {
        guard let tab = closedTabs.pop() else { return }
        let paths: [String] = if case .file(let path, _) = tab { [path] } else { [] }
        Task { [weak self] in
            let found = await HomeGrid.availability(of: paths, timeout: .seconds(1))
            guard let self else { return }
            let one = SessionSnapshot(windows: [.init(frame: .zero, screen: nil, fullScreen: false, selected: 0, tabs: [tab])])
            guard let step = SessionRestorePlan.steps(one, exists: { found[$0] ?? nil }).first?.tabs.first,
                  let controller = self.makeTab(beside: self.current) ?? self.makeWindow(from: self.current)?.0 else { return }
            DebugLog.log("reopen closed tab")
            controller.restore(step)
        }
    }

    /// Whether the key window is a viewer's showing Home on a folder: View › as Posters / as Cards / as List and
    /// ⌥⌘1–⌥⌘3 apply.
    var keyWindowCanChooseCardStyle: Bool {
        guard let window = NSApp.keyWindow else { return false }
        return entries.first { $0.controller.window === window }?.controller.canChooseCardStyle ?? false
    }

    /// ⌘1…⌘9, ⌥⌘→ / ⌥⌘←: a tab of the key window's group. False (the menu goes on) when the key window is not a
    /// viewer's; a key with no tab to go to does nothing.
    func tabKey(_ key: BrowserTabKeys.Key) -> Bool {
        guard let window = NSApp.keyWindow, entries.contains(where: { $0.controller.window === window }) else { return false }
        let tabs = window.tabGroup?.windows ?? [window]
        let selected = tabs.firstIndex { $0 === window } ?? 0
        guard let i = BrowserTabKeys.index(key, selected: selected, count: tabs.count), i != selected else { return true }
        tabs[i].makeKeyAndOrderFront(nil)
        return true
    }

    /// A new tab on screen in `anchor`'s window, empty.
    private func makeTab(beside anchor: ViewerWindowController?, key: Bool = true) -> ViewerWindowController? {
        guard let anchorWindow = anchor?.window, let controller = makeController?(), let window = controller.window else {
            return nil
        }
        anchorWindow.addTabbedWindow(window, ordered: .above)
        // `key` false: a tab of a restored session (`restoreWindow`), whose selected tab alone may be made key.
        if key { controller.showWindow(nil) } else { window.makeFirstResponder(controller.viewerView) }
        controller.syncFullScreen()   // a tab of a full-screen window is in full screen without entering it
        return controller
    }

    /// A new window on screen, empty, cascaded from `front`'s; `fullScreen`: it is to enter full screen (`front` is in
    /// it and `new-window-fullscreen=follow`).
    private func makeWindow(from front: ViewerWindowController?) -> (ViewerWindowController, fullScreen: Bool)? {
        let front = front?.window
        guard let controller = makeController?(), let window = controller.window else { return nil }
        let frontInFullScreen = front?.styleMask.contains(.fullScreen) ?? false
        if let front, !frontInFullScreen {
            window.setFrame(NSRect(origin: window.frame.origin, size: front.frame.size), display: false)
            // Its top left on the front window's, then one step down and right.
            window.cascadeTopLeft(from: window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        }
        window.tabbingMode = .disallowed   // `.preferred` would make it a tab of the main window as it is shown
        controller.showWindow(nil)
        window.tabbingMode = .preferred
        return (controller, frontInFullScreen && Settings.shared.config.newWindowFullScreen == .follow)
    }

    // MARK: Sessions (Home spec §2.6)

    /// Where Last Session and the named sessions are kept; nil: none (a secondary instance).
    var sessions: SessionStore?
    /// The file browser's pins and last folder, the positions it opens folders on, and every store a rename must
    /// update (file browser spec §4.3).
    var browserPlaces: BrowserPlaces?
    var positions: FolderPositions?
    var pathStores: [any PathMoving] = []
    private var lastSaveScheduled = false
    /// Session restores not done yet (`open(session:)`): their windows come one per turn, and a snapshot taken meanwhile
    /// would leave the ones not made yet out of Last Session (a quit during the restore keeps the one saved before).
    private var restoresUnderway = 0
    /// The windows as they were before the closes of this turn of the run loop (a window of several tabs closes them
    /// one by one): saved when they leave none, so Last Session keeps every tab of the last window.
    private var beforeCloses: SessionSnapshot?

    /// The viewer windows front to back, each with its tabs in the tab bar's order. Front to back is by the last time a
    /// window (any of its tabs) was key, then by `NSApp.orderedWindows`: for windows in full-screen Spaces that is the
    /// order they were made in, not the one on screen, and the window left in front would not be restored in front.
    func snapshot() -> SessionSnapshot {
        var seen = Set<ObjectIdentifier>()
        var groups: [(rank: Int, window: SessionSnapshot.Window)] = []
        let ours = Set(entries.compactMap { $0.controller.window.map(ObjectIdentifier.init) })
        let ordered = NSApp.orderedWindows.filter { ours.contains(ObjectIdentifier($0)) }
            + entries.compactMap(\.controller.window)
        for window in ordered {
            let group = window.tabGroup?.windows ?? [window]
            guard let first = group.first, seen.insert(ObjectIdentifier(first)).inserted else { continue }
            let controllers = group.compactMap { w in entries.first { $0.controller.window === w }?.controller }
            guard !controllers.isEmpty else { continue }
            let shown = window.tabGroup?.selectedWindow ?? window
            let selected = controllers.firstIndex { $0.window === shown } ?? 0
            groups.append((controllers.map(activityRank).max() ?? 0,
                           .init(frame: shown.frame, screen: shown.screen?.localizedName,
                                 fullScreen: shown.styleMask.contains(.fullScreen), selected: selected,
                                 tabs: controllers.map { $0.sessionTab() })))
        }
        // A stable sort: windows never key keep the system's order behind those that were.
        let windows = groups.enumerated().sorted { ($0.element.rank, -$0.offset) > ($1.element.rank, -$1.offset) }
            .map(\.element.window)
        return SessionSnapshot(windows: windows)
    }

    /// A tab's photo changed: Last Session follows.
    func contentChanged() { scheduleLastSave() }

    /// Last Session in 2 s (one snapshot for a burst of changes).
    private func scheduleLastSave() {
        guard sessions != nil, !lastSaveScheduled else { return }
        lastSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lastSaveScheduled = false
            guard !self.entries.isEmpty, self.restoresUnderway == 0 else { return }
            self.sessions?.saveLast(self.snapshot())
        }
    }

    /// Last Session now, written before returning: quitting, or the last window closing.
    func saveLastNow() {
        guard let sessions, !entries.isEmpty, restoresUnderway == 0 else { return }
        sessions.saveLast(snapshot())
        sessions.flush()
    }

    /// The windows of `session` next to those open (Home spec §2.6). `first`: an empty window to take the first
    /// session window (the launch's), whose full screen the launch restores itself. Only each window's selected tab
    /// opens at once; full-screen windows go to full screen one after another. `completion` once the windows are up.
    /// The session's front window is made first and alone made key (one activation, one plan for the cache); the others
    /// one per turn of the main thread, each ordered below the one made before it without becoming key, so a
    /// restore of many windows is no one long block and input gets through between them (spikes/rust/REPORT.md §3.4).
    func open(session: SessionSnapshot, first: ViewerWindowController? = nil, completion: (() -> Void)? = nil) {
        let paths = session.windows.flatMap(\.tabs).compactMap { tab -> String? in
            if case .file(let path, _) = tab { return path }
            return nil
        }
        restoresUnderway += 1
        Task { [weak self] in
            let found = await HomeGrid.availability(of: paths, timeout: .seconds(1))
            guard let self else { return }
            let steps = SessionRestorePlan.steps(session) { found[$0] ?? nil }
            let restore = Restore(steps: steps, tabCount: session.tabCount, completion: completion)
            restore.turn {
                guard let front = steps.first, let lead = self.restoreWindow(front, reused: first, below: nil, restore) else { return }
                lead.bringToFront()
                restore.lead = lead
                restore.below = lead.window
            }
            self.restoreNext(restore, index: 1)
        }
    }

    /// A session restore under way: what it made so far and the main thread's CPU time it took.
    private final class Restore {
        let steps: [SessionRestorePlan.WindowStep]
        let tabCount: Int
        let completion: (() -> Void)?
        let screens = NSScreen.screens.map(\.visibleFrame)
        let main: CGRect
        /// The window the next one goes under: the one made last.
        weak var below: NSWindow?
        /// The front window's selected tab.
        weak var lead: ViewerWindowController?
        /// In the order made, front to back.
        var fullScreen: [ViewerWindowController] = []
        var cpu = 0.0, longest = 0.0

        init(steps: [SessionRestorePlan.WindowStep], tabCount: Int, completion: (() -> Void)?) {
            self.steps = steps
            self.tabCount = tabCount
            self.completion = completion
            main = NSScreen.main?.visibleFrame ?? screens.first ?? .zero
        }

        func turn(_ work: () -> Void) {
            let started = ThreadCPU.milliseconds()
            work()
            let spent = ThreadCPU.milliseconds() - started
            cpu += spent
            longest = max(longest, spent)
        }
    }

    /// The session's window at `index` in this turn and the next one in the next turn; after the last, the full-screen
    /// ones go to full screen back to front, so the front one is the last to take its Space and stays in front.
    private func restoreNext(_ restore: Restore, index: Int) {
        guard index < restore.steps.count else {
            DebugLog.log("session opened: \(restore.steps.count) windows, \(restore.tabCount) tabs; main \(Int(restore.cpu)) ms "
                         + "CPU, longest turn \(Int(restore.longest)) ms")
            restoresUnderway -= 1
            scheduleLastSave()   // the windows as restored: each made one asked for it while the restore was out
            return enterFullScreenInTurn(Array(restore.fullScreen.reversed())) { [weak self] in
                self?.frontAfterFullScreen(restore)
                restore.completion?()
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            restore.turn {
                let lead = self.restoreWindow(restore.steps[index], reused: nil, below: restore.below, restore)
                if let window = lead?.window { restore.below = window }
            }
            self.restoreNext(restore, index: index + 1)
        }
    }

    /// One session window with its tabs, its selected tab the group's. `below` nil: the front window, shown and made
    /// key as any new window; else ordered below it, not key (no activation: it becomes active when the user goes
    /// to it). Returns the selected tab's controller.
    private func restoreWindow(_ step: SessionRestorePlan.WindowStep, reused: ViewerWindowController?, below: NSWindow?,
                               _ restore: Restore) -> ViewerWindowController? {
        guard let lead = reused ?? makeController?(), let window = lead.window else { return nil }
        if reused == nil {
            window.setFrame(SessionFrames.fit(step.frame, screens: restore.screens, main: restore.main), display: false)
            window.tabbingMode = .disallowed
            if let below {
                window.order(.below, relativeTo: below.windowNumber)
                window.makeFirstResponder(lead.viewerView)
            } else {
                lead.showWindow(nil)
            }
            window.tabbingMode = .preferred
            if step.fullScreen { restore.fullScreen.append(lead) }
        }
        var tabs = [lead]
        for _ in step.tabs.dropFirst() {
            // Not key either: the selected tab is made key by `bringToFront` (the front window) or none is.
            guard let tab = makeTab(beside: tabs.last, key: false) else { break }
            tabs.append(tab)
        }
        for (controller, tabStep) in zip(tabs, step.tabs) { controller.restore(tabStep) }
        guard tabs.indices.contains(step.selected) else { return lead }
        let selected = tabs[step.selected]
        if below != nil, let group = window.tabGroup, let shown = selected.window { group.selectedWindow = shown }
        return selected
    }

    /// The windows that went to full screen each took their Space and showed it, and the front window may not be the
    /// last of them: the launch's window enters full screen on its own, before the others are made. It is shown again
    /// unless the user went to another window meanwhile (its Space; it is key all along, so no activation comes of it).
    private func frontAfterFullScreen(_ restore: Restore) {
        guard !restore.fullScreen.isEmpty, let lead = restore.lead, active === lead else { return }
        lead.bringToFront()
    }

    /// Each of `controllers` into full screen after the previous one got there (each in its own Space).
    private func enterFullScreenInTurn(_ controllers: [ViewerWindowController], completion: (() -> Void)?) {
        guard let next = controllers.first else {
            completion?()
            return
        }
        next.enterFullScreen { [weak self] in self?.enterFullScreenInTurn(Array(controllers.dropFirst()), completion: completion) }
    }

    // MARK: Activity

    private func becameKey(_ controller: ViewerWindowController) {
        controller.openPending()
        scheduleLastSave()
        if active !== controller {
            activate(controller)
        } else if let i = index(of: controller) {
            entries[i].rank = bumpRank()
        }
        refreshVisibility()
        // The tab group's selection may settle after the key change.
        DispatchQueue.main.async { [weak self] in self?.refreshVisibility() }
    }

    /// `controller` becomes the active session, the previous one inactive (it keeps what it has).
    private func activate(_ controller: ViewerWindowController) {
        guard let i = index(of: controller) else { return }
        let previous = active
        active = controller
        entries[i].rank = bumpRank()
        if let previous, previous !== controller, let p = index(of: previous) {
            let visible = Self.isVisible(previous)
            entries[p].visible = visible
            previous.session.setActivity(active: false, visible: visible, lastActive: entries[p].rank)
            previous.photosVisibilityChanged(visible)
        }
        let visible = Self.isVisible(controller)
        entries[i].visible = visible
        controller.session.setActivity(active: true, visible: visible, lastActive: entries[i].rank)
        controller.photosVisibilityChanged(visible)
        if DebugLog.isEnabled { controller.viewerView.watchSharp(session: controller.session.cacheID.raw) }
        controller.rememberFullScreenAsActive()
    }

    /// Tells each session whose window's visibility changed.
    private func refreshVisibility() {
        for i in entries.indices {
            let controller = entries[i].controller
            let visible = Self.isVisible(controller)
            guard visible != entries[i].visible else { continue }
            entries[i].visible = visible
            controller.session.setActivity(active: controller === active, visible: visible, lastActive: entries[i].rank)
            controller.photosVisibilityChanged(visible)
        }
    }

    /// On screen, not miniaturized, and the selected tab of its group: the occlusion of a tab hidden behind another of
    /// its group is not documented.
    private static func isVisible(_ controller: ViewerWindowController) -> Bool {
        guard let window = controller.window else { return false }
        guard window.occlusionState.contains(.visible), !window.isMiniaturized else { return false }
        guard let group = window.tabGroup, group.windows.count > 1 else { return true }
        return group.selectedWindow === window
    }

    /// The window closed: its controller is let go (the session and the render loop went with `windowWillClose`).
    /// If it was the active one, another takes over at once — the next key window may be Settings, another app's or
    /// one in another Space, and none would make a viewer active: the tab its group selects (known once the close is
    /// done), else the last key one left. A later key change re-activates as usual.
    private func closed(_ controller: ViewerWindowController) {
        guard let i = index(of: controller) else { return }
        if sessions != nil, beforeCloses == nil {
            beforeCloses = snapshot()
            DispatchQueue.main.async { [weak self] in self?.beforeCloses = nil }
        }
        closedTabs.push(controller.sessionTab())
        let group = controller.window?.tabGroup
        entries[i].observers.forEach(NotificationCenter.default.removeObserver)
        entries.remove(at: i)
        if entries.isEmpty {
            // The last window (all its tabs) keeps its place in Last Session.
            if let sessions, let before = beforeCloses {
                sessions.saveLast(before)
                sessions.flush()
            }
            active = nil
            onLastClosed?()
            return
        }
        scheduleLastSave()
        guard active === controller, !isQuitting else { return }
        let selected = group?.selectedWindow.flatMap { selected in
            selected === controller.window ? nil : entries.first { $0.controller.window === selected }?.controller
        }
        guard let next = selected ?? lastKey else { return }
        activate(next)
        guard selected == nil, let group else { return }
        DispatchQueue.main.async { [weak self, weak next, weak group] in
            guard let self, let next, self.active === next,
                  !self.entries.contains(where: { $0.controller.window === NSApp.keyWindow }),
                  let shown = group?.selectedWindow, shown !== next.window,
                  let entry = self.entries.first(where: { $0.controller.window === shown }) else { return }
            self.activate(entry.controller)
        }
    }

    /// The controller that was key most recently.
    private var lastKey: ViewerWindowController? { entries.max { $0.rank < $1.rank }?.controller }

    private func index(of controller: ViewerWindowController) -> Int? {
        entries.firstIndex { $0.controller === controller }
    }

    private func bumpRank() -> Int {
        defer { nextRank += 1 }
        return nextRank
    }
}

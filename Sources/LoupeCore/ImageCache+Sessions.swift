import Foundation

// Sessions (spec windows-and-tabs §3): registration, activity, each session's focus and pinned photo, and the
// single-session API over them. Only the active session plans (`reconcile`); the others are kept for eviction
// order (`ownerFacts`) and for when they become active, and trimmed once idle for long (`trimIdle`).

extension ImageCache {
    /// The active session's playlist, focus and current photo: what the plan, the read priorities, the decode slot
    /// reserved for the current photo and the activity reported go by.
    var files: [URL] { active.flatMap { sessions[$0]?.files } ?? [] }
    var focus: CacheFocus? { active.flatMap { sessions[$0]?.focus } }
    var currentURL: URL? { active.flatMap { sessions[$0]?.currentURL } }
    /// The other page of the active session's pair on screen (spread), nil for one page.
    var companionURL: URL? { active.flatMap { sessions[$0]?.companionURL } }

    /// `url` is on screen in the active session: its current photo or the other page of its pair (spread spec,
    /// «Кэш»: both pages are current). Both read at once, first in the read queue, decode in the current class (the
    /// reserved slot, JXL's current threads, the first look) and count as `.current` activity.
    func isCurrent(_ url: URL) -> Bool { url == currentURL || url == companionURL }

    /// Adds a session, inactive and invisible until `setActivity`. `onUpdate` is called on every change of an entry
    /// its playlist lists or it pins (any thread); the session hops to main and re-reads. Registering again replaces
    /// the handler.
    public func register(_ session: CacheSessionID, onUpdate: @escaping @Sendable (URL) -> Void) {
        sessions[session, default: CacheSessionState()].onUpdate = onUpdate
    }

    /// Removes a session (its tab closed). What it listed or had on screen that no other session lists or has on
    /// screen is freed at once (spec window-cache-ownership, close release): its jobs and read cancelled, its levels,
    /// file and ready decode dropped, the entry forgotten, and the freed buffers handed back to the system. Entries it
    /// did not list (a folder it had left) are left to eviction as before. Removing the active one leaves none:
    /// nothing is planned until `setActivity` makes another active.
    public func unregister(_ session: CacheSessionID) {
        guard let state = sessions.removeValue(forKey: session) else { return }
        state.stampCheck?.cancel()
        if active == session { active = nil }
        let shownElsewhere = Set(sessions.values.flatMap(\.pinnedPages))
        var freed = 0
        for url in Set(state.files).union(state.pinnedPages) where !isListed(url) && !shownElsewhere.contains(url) {
            guard let e = entries[url] else { continue }
            e.jobs.values.forEach { $0.task.cancel() }
            e.read?.cancel()
            freed += pyramidBytes(e) + (e.data?.count ?? 0) + (e.ready?.image.buffer.length ?? 0)
            entries[url] = nil   // a job or read still running finds its entry gone and keeps nothing
        }
        reconcile()
        if freed > 0 {
            // As after memory pressure: the freed buffers go back to the system.
            Task.detached(priority: .utility) { _ = malloc_zone_pressure_relief(nil, 0) }
        }
    }

    /// active: this session becomes the active one (the previous active one gets lastActive = now);
    /// visible: on screen. Only this call changes which session is active.
    /// The active session called with `active: false` stops being active, and none is until another call makes one;
    /// `active: false` from any other session only sets its visibility.
    /// `order` puts activations from different callers (each session has its own call chain) in the order they were
    /// made: an `active: true` whose `order` is below that of an activation already taken is stale and only sets the
    /// visibility. Nil: taken in the order it arrives (a caller with one chain).
    /// Switching is like the current photo changing today: the one left drops its stamp check, and the one arriving
    /// has its current photo arrive again (a failed one retried, a cached one's stamp checked) without waiting for a
    /// `setFocus`; its plan goes on from what is in the cache, its current photo first, so a window whose photos were
    /// not evicted reads and decodes nothing. Returns what an activation taken found (`CacheActivation`), nil for any
    /// other call.
    @discardableResult
    public func setActivity(_ session: CacheSessionID, active isActive: Bool, visible: Bool,
                            order: UInt64? = nil) -> CacheActivation? {
        guard sessions[session] != nil else { return nil }
        if sessions[session]?.isVisible == true && !visible { sessions[session]?.hiddenSince = .now }
        sessions[session]?.isVisible = visible
        let launched = nextJobID
        var taken = false
        if isActive && active == session {
            // Already active: a newer activation still moves the mark, so another session's older one arriving later
            // stays stale.
            if let order, order > activationOrder { activationOrder = order }
            taken = true
        } else if isActive && (order ?? activationOrder) >= activationOrder {
            taken = true
            if let previous = active { deactivate(previous) }
            active = session
            if let order { activationOrder = order }
            if let s = sessions[session], !s.arrived, let current = s.currentURL, s.focus?.scrubbing == false {
                sessions[session]?.arrived = true
                becameCurrent(current, of: session)
            }
        } else if !isActive && active == session {
            deactivate(session)
            active = nil
        }
        reconcile()
        guard taken else { return nil }
        let current = sessions[session]?.currentURL.flatMap { url in entries[url].flatMap { state(of: url, $0) } }
        return CacheActivation(current: current, jobs: nextJobID - launched, stats: stats())
    }

    /// Only whether `session`'s window is on screen: the active one stays active (a Space switch or an occlusion
    /// change is no activation: no stamp check, no `CacheActivation`), an inactive one keeps or gets its photo.
    public func setVisibility(_ session: CacheSessionID, visible: Bool) {
        guard let s = sessions[session], s.isVisible != visible else { return }
        if s.isVisible { sessions[session]?.hiddenSince = .now }
        sessions[session]?.isVisible = visible
        reconcile()
    }

    private func deactivate(_ session: CacheSessionID) {
        sessions[session]?.stampCheck?.cancel()
        sessions[session]?.stampCheck = nil
        sessions[session]?.arrived = false
        sessions[session]?.lastActive = .now
    }

    /// The sessions as `CacheOwners` sees them, with what their keep sets hold: the photo on screen (and its pair's
    /// other page) at the level the zoom needs, and the photos either side of it.
    func ownerFacts() -> [CacheOwnerFacts] {
        let now = ContinuousClock.now
        return sessions.map { id, s in
            var facts = CacheOwnerFacts(id: id, fileIndex: s.fileIndex, current: s.currentURL == nil ? nil : s.focus?.current,
                                        direction: s.focus?.direction ?? 1, isActive: id == active, isVisible: s.isVisible,
                                        lastActive: id == active ? now : s.lastActive, hiddenSince: s.hiddenSince,
                                        currentURL: s.currentURL)
            if let focus = s.focus, s.currentURL != nil {
                let pages = [focus.current, focus.companion].compactMap { $0 }
                let before = (pages.min() ?? focus.current) - 1, after = (pages.max() ?? focus.current) + 1
                facts.previousURL = s.files.indices.contains(before) ? s.files[before] : nil
                facts.nextURL = s.files.indices.contains(after) ? s.files[after] : nil
                facts.currentGoal = focus.needsFull ? .full : .preview
                facts.companionURL = s.companionURL
            }
            return facts
        }
    }

    /// Whether any session's playlist lists `url`.
    func isListed(_ url: URL) -> Bool { sessions.values.contains { $0.fileIndex[url] != nil } }

    /// The single-session API (one window): `CacheSessionID.solo`, registered active and visible by the first call.
    /// Called on every change of an entry (any thread); the session hops to main and re-reads.
    public func setOnUpdate(_ handler: @escaping @Sendable (URL) -> Void) {
        soloRegistered()
        sessions[.solo]?.onUpdate = handler
    }

    public func setFocus(files: [URL], focus: CacheFocus) {
        soloRegistered()
        setFocus(.solo, files: files, focus: focus)
    }

    public func setPinned(_ url: URL?, companion: URL? = nil) {
        soloRegistered()
        setPinned(.solo, url, companion: companion)
    }

    private func soloRegistered() {
        guard sessions[.solo] == nil else { return }
        sessions[.solo] = CacheSessionState(isVisible: true)
        if let previous = active { deactivate(previous) }
        active = .solo
    }

    /// A session's playlist and position; replans, cancels waiting jobs no longer planned, starts missing ones,
    /// evicts what does not fit. Only the active session's focus is planned; an inactive one's is kept for when it
    /// becomes active, and for eviction order. A scrubbing focus plans nothing (`CacheFocus.scrubbing`): every
    /// waiting read and job is cancelled, none starts, and resident state is evicted only by the `cache-memory`
    /// ceiling, as always. An unregistered session's call is ignored.
    public func setFocus(_ session: CacheSessionID, files: [URL], focus: CacheFocus) {
        guard var s = sessions[session] else { return }
        if files != s.files {
            s.files = files
            s.fileIndex = Dictionary(files.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        }
        s.focus = focus
        let current = files.indices.contains(focus.current) ? files[focus.current] : nil
        s.companionURL = focus.companion.flatMap { files.indices.contains($0) ? files[$0] : nil }
        if current != s.currentURL {
            s.stampCheck?.cancel()
            s.stampCheck = nil
            s.currentURL = current
            s.arrived = false
        }
        let arrives = session == active && !s.arrived && !focus.scrubbing && current != nil
        if arrives { s.arrived = true }
        sessions[session] = s
        if arrives, let current { becameCurrent(current, of: session) }
        reconcile()
    }

    /// A session's photo on screen (nil: none). The viewer tells the cache whenever it changes; while the session is
    /// active or visible, its resident levels are never evicted, whatever the plan or the limit, so what is on screen
    /// is never degraded under it.
    /// `companion`: the second page of a pair on screen (spread), pinned the same way.
    public func setPinned(_ session: CacheSessionID, _ url: URL?, companion: URL? = nil) {
        guard let s = sessions[session], url != s.pinned || companion != s.pinnedCompanion else { return }
        sessions[session]?.pinned = url
        sessions[session]?.pinnedCompanion = companion
        reconcile()
    }

    // MARK: Idle trim (spec windows-and-tabs §3.5)

    /// Trims every session neither active nor visible for at least `cache-idle-trim` by `now` (`CacheOwners.idle`): the
    /// entries only such sessions list lose everything but their current photo, which keeps all its levels
    /// (`cache-idle-keep=full`) or goes down to its preview (`preview`, the Lfit of its holder's screen), and its file
    /// but not its ready decode (a discrete card's, `CacheEntry.ready`). An entry
    /// another session lists too, or that one has on screen, is spared whole; one nobody lists is left to
    /// `evictToFit`, as is whatever the plan wants. Not counted in `evictedInactive`. The timer calls it once a
    /// minute; the next step in a trimmed window reads its neighbours again.
    func trimIdle(now: ContinuousClock.Instant) {
        guard let after = limits.idleTrim else { return }
        let idle = Set(CacheOwners.idle(owners, now: now, after: after))
        guard !idle.isEmpty else { return }
        // The idle sessions' keep sets shrink to their current photos (`keepFacts`): replanned first, so their
        // neighbours are no longer planned and go below.
        reconcile(now: now)
        // The current photo and the other page of its pair, both on screen.
        let current = Set(idle.flatMap { id in [sessions[id]?.currentURL, sessions[id]?.companionURL].compactMap { $0 } })
        let spared = CacheOwners.protected(owners)
            .union(sessions.flatMap { id, s in idle.contains(id) ? [] : s.pinnedPages })
        var freed = 0
        for (url, e) in entries where e.uploadReserve == 0 && !spared.contains(url) {
            let listing = sessions.filter { $0.value.fileIndex[url] != nil }.keys
            guard !listing.isEmpty, listing.allSatisfy(idle.contains) else { continue }
            // The current photo keeps its levels as `cache-idle-keep` says, never its ready decode (system memory
            // a hidden window has no use for).
            let steps: [EvictionStep] = !current.contains(url) ? EvictionStep.allCases
                : limits.idleKeep == .preview ? [.ready, .finerThanPreview] : [.ready]
            for step in steps { freed += degrade(url, e, step) }
        }
        if freed > 0 {
            // As after memory pressure: the freed buffers go back to the system.
            Task.detached(priority: .utility) { _ = malloc_zone_pressure_relief(nil, 0) }
        }
    }

    /// Runs the idle trim's timer while `cache-idle-trim` is on and some session is inactive and invisible (one that
    /// can go idle), and stops it otherwise, so it never wakes the actor for nothing. Called whenever the sessions or
    /// the limits change.
    func updateIdleTimer() {
        guard limits.idleTrim != nil, sessions.contains(where: { $0.key != active && !$0.value.isVisible }) else {
            idleTimer?.cancel()
            idleTimer = nil
            return
        }
        guard idleTimer == nil else { return }
        idleTimer = Task { [weak self, clock] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                await self.trimIdle(now: .now)
            }
        }
    }
}

/// What `ImageCache` keeps of one session.
struct CacheSessionState {
    var onUpdate: (@Sendable (URL) -> Void)?
    var files: [URL] = []
    /// `files` by URL → playlist index, rebuilt only when the playlist changes: eviction order is by distance from
    /// the current index. Entries outside every playlist (a folder just left, the rest of the folder while a one-file
    /// playlist waits for its listing) are kept while they fit, are the first to go when they do not, and are pruned
    /// once empty.
    var fileIndex: [URL: Int] = [:]
    /// The photo on screen: while the session is active or visible its resident state is never evicted (it still
    /// counts in `usedBytes`). Only the viewer moves it (`setPinned`), also across playlists: the old folder's photo
    /// stays on screen until the new one shows.
    var pinned: URL?
    /// The other page of a pair on screen (spread), kept like `pinned`.
    var pinnedCompanion: URL?
    /// `pinned` and `pinnedCompanion`, those set.
    var pinnedPages: [URL] { [pinned, pinnedCompanion].compactMap { $0 } }
    var focus: CacheFocus?
    var currentURL: URL?
    /// The focus's `companion` (the other page of the pair on screen), as current as `currentURL`.
    var companionURL: URL?
    /// `becameCurrent` ran for `currentURL` while the session was active. A scrub only passes over photos, so it is
    /// put off until the focus stops scrubbing on one: the stamp check is I/O, which a scrub starts none of.
    var arrived = false
    /// The current photo's stamp check; cancelled when another photo becomes current or the session stops being
    /// active.
    var stampCheck: Task<Void, Never>?
    var isVisible = false
    /// When the session last stopped being active (or was registered).
    var lastActive = ContinuousClock.now
    /// When the session last went from visible to not; the idle trim counts from the later of the two.
    var hiddenSince: ContinuousClock.Instant?
}

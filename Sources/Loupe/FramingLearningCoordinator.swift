import Foundation
import LoupeCore

struct FramingCaptureOrigin: Sendable {
    var source: URL
    var profile: FramingProfile
    var behavior: FramingReference.Behavior
    var input: ViewTransform
    var automatic: ViewTransform?
    var selectedGroup: SubjectKind?
    /// Manual viewing has no automatic replay origin; use Fit as its explicit proposal baseline.
    static func forCapture(_ origin: Self?, source: URL, profile: FramingProfile, shown: ViewTransform) -> Self {
        if let origin, origin.source == source, origin.profile == profile,
           origin.input.imageSize == shown.imageSize, origin.input.viewSize == shown.viewSize { return origin }
        return .init(source: source, profile: profile, behavior: .auto, input: shown.withMode(.fit))
    }
    func reference(source: URL, target: ViewTransform, boxes: SubjectBoxes, evidence: FramingEvidence,
                   intent: FramingIntent) throws -> FramingReference {
        guard source == self.source, input.imageSize == target.imageSize, input.viewSize == target.viewSize else {
            throw FramingLearningError.stale
        }
        // Replay needs the incoming logical scale/pan, not a historical elastic animation residual.
        // That snapshot never changes when the live view settles later.
        var r = try FramingReference(source: source, profile: profile, behavior: behavior,
                                    input: input.withStretch(nil), target: target, boxes: boxes, evidence: evidence)
        r.intent = intent
        r.automatic = automatic.flatMap { try? FramingGeometry($0) }
        r.capturedGroup = selectedGroup
        return r
    }
}

/// Shared by the application: one fit at a time across all windows; no background work when idle.
@MainActor final class FramingLearningLibrary {
    let store: FramingReferenceStore
    let gate = FramingWorkGate()
    private let defaults: UserDefaults
    private static let rightClickKey = "smartZoom.objectFeedbackOnRightClick"
    private var activeRun: UUID?
    private(set) var policies: [FramingPolicy] = []
    init(store: FramingReferenceStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }
    var objectFeedbackOnRightClick: Bool {
        get { defaults.bool(forKey: Self.rightClickKey) }
        set { defaults.set(newValue, forKey: Self.rightClickKey) }
    }
    func reload() async throws { policies = try await store.savedPolicies() }
    func adopt(_ dataset: FramingDataset) { policies = dataset.policies }
    func acquire(_ id: UUID) -> Bool { guard activeRun == nil else { return false }; activeRun = id; return true }
    func release(_ id: UUID) { if activeRun == id { activeRun = nil } }
    func policy(profile: FramingProfile, intent: FramingIntent, evidence: FramingEvidence? = nil) -> FramingPolicy? {
        policies.last { $0.baseline.fingerprint == profile.fingerprint && $0.intent == intent && (evidence == nil || $0.evidence == evidence) }
    }
}

@MainActor final class FramingLearningCoordinator {
    let library: FramingLearningLibrary
    let profile: FramingProfile
    let intent: FramingIntent
    var currentProfile: () -> FramingProfile
    var currentPolicy: () -> FramingPolicy?
    var applyTab: (FramingProfile, FramingPolicy?) -> Void
    var currentEvidence: () -> FramingEvidence?
    var changed: (() -> Void)?
    private(set) var dataset = FramingDataset()
    private(set) var result: FramingFitResult?
    private(set) var running = false
    private(set) var isFitting = false
    private(set) var message = "Loading references…"
    private(set) var completed = 0
    private(set) var total = 0
    private var task: Task<Void, Never>?
    private var runToken = UUID()
    private var mutation: FramingMutationToken?
    private var fitRevision: UInt64?
    private var applied = false
    private var undoState: (active: FramingPolicy?, saved: FramingPolicy?, persisted: Bool)?
    var canUndo: Bool { undoState != nil && !running && currentProfile().fingerprint == profile.fingerprint && currentPolicy() == result?.policy }
    var canApply: Bool { result != nil && !applied && !running && fitRevision == dataset.revision && currentProfile().fingerprint == profile.fingerprint
        && (currentEvidence() == nil || currentEvidence() == result?.policy.evidence) }
    var references: [FramingReference] { dataset.references.filter { $0.profile.name == profile.name && $0.intent == intent } }
    init(library: FramingLearningLibrary, profile: FramingProfile, intent: FramingIntent,
         currentProfile: @escaping () -> FramingProfile, currentPolicy: @escaping () -> FramingPolicy?,
         applyTab: @escaping (FramingProfile, FramingPolicy?) -> Void, evidence: @escaping () -> FramingEvidence? = { nil }) {
        self.library = library; self.profile = profile; self.intent = intent; self.currentProfile = currentProfile
        self.currentPolicy = currentPolicy; self.applyTab = applyTab
        currentEvidence = evidence
    }
    private func begin() -> UUID {
        let token = UUID(); runToken = token; running = true; mutation = FramingMutationToken(); return token
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == runToken else { throw CancellationError() }
    }
    private func finish(_ token: UUID) {
        guard token == runToken else { return }; running = false; isFitting = false; mutation = nil; changed?()
    }
    func load() {
        guard !running else { return }
        let token = begin()
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish(token) }
            do {
                let next = try await library.store.snapshot(); try check(token)
                if next.revision != dataset.revision { result = nil; fitRevision = nil }
                dataset = next
                let usable = references.filter { currentEvidence() == nil || $0.evidence == currentEvidence() }.count
                message = "\(usable) usable of \(references.count) references · \(intent.title)"
            } catch { if runToken == token { message = error.localizedDescription } }
        }
    }
    func cancel() {
        // Atomic mutations are allowed to finish after their commit cutoff; Cancel fit never pretends to cancel a save.
        if mutation?.cancel() == false { message = "Finishing saved change…"; changed?(); return }
        task?.cancel(); runToken = UUID(); running = false; isFitting = false
        message = "Cancelled"; changed?()
    }
    func waitForCurrentOperation() async { await task?.value }
    func fit() {
        guard !running else { return }
        let token = begin()
        guard library.acquire(token) else { running = false; message = "Another window is fitting a profile."; changed?(); return }
        isFitting = true; result = nil; applied = false; undoState = nil
        message = "Fitting local crop preferences…"; changed?()
        let library = library, gate = library.gate
        task = Task { [weak self] in
            defer { library.release(token) }
            guard let self else { return }
            defer { finish(token) }
            do {
                let snapshot = try await library.store.snapshot(); try check(token); dataset = snapshot
                let revision = dataset.revision
                let compatible = references.filter { currentEvidence() == nil || $0.evidence == currentEvidence() }
                let result = try await FramingFitter.fit(profile: profile, references: compatible, intent: intent,
                    checkpoint: { try await gate.checkpoint() }, progress: { [weak self] done, total in
                        if done % 16 == 0 { Task { @MainActor in
                            guard let self, self.runToken == token else { return }
                            self.completed = done; self.total = total; self.changed?()
                        } }
                    })
                try check(token)
                guard try await library.store.snapshot().revision == revision else { throw FramingLearningError.stale }
                try check(token)
                self.result = result; fitRevision = revision
                message = result.exploratory ? "Exploratory fit · reserve independent series for validation." : "Fit ready · compare reserved images before applying."
            } catch { if runToken == token { message = error is CancellationError ? "Fit cancelled" : error.localizedDescription } }
        }
    }
    func remove(_ id: UUID) {
        edit { store, revision, cancellation in try await store.remove(id: id, expectedRevision: revision, cancellation: cancellation) }
    }
    func group(_ id: UUID, name: String, validation: Bool) {
        edit { store, revision, cancellation in try await store.updateGroup(id: id, group: name, validation: validation,
            expectedRevision: revision, cancellation: cancellation) }
    }
    private func edit(_ action: @escaping (FramingReferenceStore, UInt64, FramingMutationToken) async throws -> FramingDataset) {
        guard !running else { return }
        let token = begin(), cancellation = mutation!
        result = nil; fitRevision = nil; changed?()
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish(token) }
            do {
                try check(token)
                let next = try await action(library.store, dataset.revision, cancellation)
                guard runToken == token else { return }
                dataset = next; message = "References updated"
            } catch { if runToken == token { message = error.localizedDescription } }
        }
    }
    func vote(reference: UUID, choice: FramingComparisonVote.Choice, candidateFirst: Bool) {
        guard let result, !running, fitRevision == dataset.revision else { return }
        let token = begin(), cancellation = mutation!; changed?()
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish(token) }
            do {
                try check(token)
                let next = try await library.store.vote(.init(referenceID: reference, runID: result.id,
                    candidateFirst: candidateFirst, choice: choice,
                    referenceSnapshot: references.first { $0.id == reference },
                    baseline: result.samples.first { $0.id == reference }?.baselineView,
                    candidate: result.samples.first { $0.id == reference }?.candidateView,
                    datasetRevision: dataset.revision), expectedRevision: dataset.revision, cancellation: cancellation)
                guard runToken == token else { return }
                dataset = next; fitRevision = next.revision; message = "Comparison saved"
            } catch { if runToken == token { message = error.localizedDescription } }
        }
    }
    func apply(persist: Bool) {
        guard canApply, let result else { message = FramingLearningError.stale.localizedDescription; changed?(); return }
        let token = begin(), cancellation = mutation!
        let previous = (active: currentPolicy(), saved: library.policy(profile: profile, intent: intent, evidence: result.policy.evidence), persisted: persist)
        changed?()
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish(token) }
            do {
                let snapshot = try await library.store.snapshot(); try check(token)
                guard snapshot.revision == dataset.revision, currentProfile().fingerprint == profile.fingerprint else { throw FramingLearningError.stale }
                if persist {
                    // One atomic file contains learned geometry, coefficients, policy identity and all references.
                    let next = try await library.store.savePolicy(result.policy, replacing: profile.name,
                        intent: intent, baselineFingerprint: profile.fingerprint, evidence: result.policy.evidence,
                        expectedRevision: dataset.revision, cancellation: cancellation)
                    guard runToken == token else { return }
                    dataset = next; fitRevision = next.revision; library.adopt(next)
                } else { try check(token) }
                guard currentProfile().fingerprint == profile.fingerprint,
                      currentEvidence() == nil || currentEvidence() == result.policy.evidence else {
                    message = persist ? "Preferences saved for the original profile; viewer changed." : FramingLearningError.stale.localizedDescription
                    return
                }
                undoState = previous; applied = true
                // Numeric proposal parameters are private to each intention; the shared external profile stays stable.
                applyTab(profile, result.policy)
                message = persist ? "Learned profile saved" : "Learned preferences applied to this tab"
            } catch { if runToken == token { message = error.localizedDescription } }
        }
    }
    func undo() {
        guard canUndo, let previous = undoState else { return }
        let token = begin(), cancellation = mutation!; changed?()
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish(token) }
            do {
                try check(token)
                if previous.persisted {
                    let next = try await library.store.savePolicy(previous.saved, replacing: profile.name,
                        intent: intent, baselineFingerprint: profile.fingerprint, evidence: result?.policy.evidence,
                        expectedRevision: dataset.revision, cancellation: cancellation)
                    guard runToken == token else { return }
                    dataset = next; fitRevision = next.revision; library.adopt(next)
                } else { try check(token) }
                guard currentProfile().fingerprint == profile.fingerprint,
                      currentEvidence() == nil || currentEvidence() == result?.policy.evidence else { throw FramingLearningError.stale }
                applyTab(profile, previous.active); undoState = nil; applied = false; message = "Previous framing restored"
            } catch { if runToken == token { message = error.localizedDescription } }
        }
    }
}

import AppKit
import LoupeCore

struct FramingCaptureRequest {
    var origin: FramingCaptureOrigin
    var target: ViewTransform
    var evidence: FramingEvidence
    var expectedRevision: FramingSourceRevision
    var boxes: () async -> SubjectBoxes?
    var resumeAutomaticMode = true
}

struct FramingPredictionIdentity: Equatable {
    var source: URL
    var profile: FramingProfile
    var intent: FramingIntent
    var behavior: FramingReference.Behavior
    var input: FramingGeometry
    var boxes: SubjectBoxes
    var evidence: FramingEvidence
    var policy: FramingPolicy?
    var sourceStamp: FileStamp?
}

/// Keeps learning lifetime and transient learned policies out of the window controller.
@MainActor final class ViewerFramingLearning {
    let library: FramingLearningLibrary
    var profile: () -> FramingProfile
    var source: () -> URL?
    var captureRequest: () throws -> FramingCaptureRequest
    var applyProfile: (FramingProfile) -> Void
    var reframe: () -> Void
    var nextPhoto: () -> Void
    var resumeForNext: ((FramingReference.Behavior) -> Void)?
    var message: (String) -> Void
    var loadedStamp: () -> FileStamp?
    var currentEvidence: () -> FramingEvidence
    private(set) var intent = FramingIntent.detail
    private var policies: [FramingIntent: FramingPolicy] = [:]
    private var suppressed = Set<FramingIntent>()
    private var window: FramingLearningWindow?
    private var preparingFeedbackMenu = false
    private var feedbackUndo: (checkpoint: FramingDataset, revision: UInt64)?
    var canUndoFeedback: Bool { feedbackUndo != nil && saveTask == nil }
    private var saveTask: Task<Void, Never>?
    private var saveCancellation: FramingMutationToken?
    private var predictionTask: Task<Void, Never>?
    private var predictionKey: FramingPredictionIdentity?
    private var prediction: ViewTransform?
    init(library: FramingLearningLibrary, profile: @escaping () -> FramingProfile, source: @escaping () -> URL?,
         capture: @escaping () throws -> FramingCaptureRequest, apply: @escaping (FramingProfile) -> Void,
         reframe: @escaping () -> Void, next: @escaping () -> Void, message: @escaping (String) -> Void,
         stamp: @escaping () -> FileStamp? = { nil }, evidence: @escaping () -> FramingEvidence = { .init() }) {
        self.library = library; self.profile = profile; self.source = source; captureRequest = capture
        applyProfile = apply; self.reframe = reframe; nextPhoto = next; self.message = message
        loadedStamp = stamp
        currentEvidence = evidence
    }
    func bindObjectFeedback(to viewer: ViewerView) {
        viewer.onFramingFeedbackMenu = { [weak self] point in
            await self?.prepareFeedbackMenu(at: point)
        }
        viewer.onRightClick = { [weak self, weak viewer] event in
            viewer?.showFramingFeedbackMenu(at: event, isEnabled: { [weak self] in
                self?.library.objectFeedbackOnRightClick == true
            })
        }
    }
    func policy() -> FramingPolicy? {
        let current = profile()
        if let local = policies[intent], local.baseline.fingerprint == current.fingerprint, local.evidence == currentEvidence() { return local }
        return suppressed.contains(intent) ? nil : library.policy(profile: current, intent: intent, evidence: currentEvidence())
    }
    func selectIntent(_ value: FramingIntent) {
        guard value != intent else { return }
        window?.close(); window = nil; intent = value; invalidatePrediction(); reframe()
    }
    func close() { window?.close(); if saveCancellation?.cancel() != false { saveTask?.cancel() }; predictionTask?.cancel() }
    func waitForSave() async { await saveTask?.value }
    private func invalidatePrediction() { predictionTask?.cancel(); predictionKey = nil; prediction = nil }
    func predict(input: ViewTransform, boxes: SubjectBoxes, evidence: FramingEvidence,
                 behavior: FramingReference.Behavior) -> ViewTransform? {
        guard let url = source(), let policy = policy() else { return nil }
        let current = profile()
        guard let geometry = try? FramingGeometry(behavior == .auto ? input.withMode(.fit) : input.withOffset(.zero).withStretch(nil)) else { return nil }
        let key = FramingPredictionIdentity(source: url, profile: current, intent: intent, behavior: behavior,
                                           input: geometry, boxes: boxes, evidence: evidence, policy: policy, sourceStamp: loadedStamp())
        if predictionKey == key { return prediction }
        invalidatePrediction(); predictionKey = key
        let work = Task.detached(priority: .userInitiated) {
            policy.predict(input: input, boxes: boxes, evidence: evidence, profile: current, behavior: behavior)
        }
        predictionTask = Task { [weak self] in
            let output = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, predictionKey == key, source() == url,
                  profile().fingerprint == current.fingerprint else { return }
            prediction = output; if output != nil { reframe() }
        }
        return nil
    }
    func save(intent: FramingIntent, advance: Bool) {
        guard saveTask == nil else { message("A reference is already being saved"); return }
        let request: FramingCaptureRequest
        do { request = try captureRequest(); _ = try FramingGeometry(request.target) }
        catch { message(error.localizedDescription); return }
        message("Saving \(intent.title.lowercased()) reference…")
        let cancellation = FramingMutationToken(); saveCancellation = cancellation
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer { saveTask = nil; saveCancellation = nil }
            do {
                let url = request.origin.source
                let (revision, bookmark) = try await library.store.sourceMetadata(url)
                guard revision == request.expectedRevision else { throw FramingLearningError.source }
                guard let boxes = await request.boxes() else { throw FramingLearningError.detection }
                try Task.checkCancellation()
                guard boxes.analysisID == request.evidence.analysisID else { throw FramingLearningError.stale }
                guard try await library.store.sourceMetadata(url).0 == revision else { throw FramingLearningError.source }
                var reference = try request.origin.reference(source: url, target: request.target, boxes: boxes,
                    evidence: request.evidence, intent: intent)
                reference.sourceRevision = revision; reference.bookmark = bookmark
                let before = try await library.store.snapshot()
                let after = try await library.store.upsert(reference, expectedRevision: before.revision, cancellation: cancellation)
                feedbackUndo = (before, after.revision)
                window?.coordinator.load()
                let willAdvance = advance && source() == url && profile().fingerprint == request.origin.profile.fingerprint
                if willAdvance {
                    if request.resumeAutomaticMode { resumeForNext?(request.origin.behavior) }
                    nextPhoto()
                }
                message("\(intent.title) crop saved · \(url.lastPathComponent)" + (willAdvance ? " → next photo" : "") + " · Undo in Zoom menu")
            } catch { message(error.localizedDescription) }
        }
    }
    func recordObject(request: FramingCaptureRequest, boxes: SubjectBoxes, instance: FramingInstance,
                      reason: FramingObjectFeedback.Reason) {
        guard saveTask == nil else { message("Feedback is already being saved"); return }
        guard source() == request.origin.source, currentEvidence() == request.evidence,
              (boxes.analysisID ?? "vision") == request.evidence.analysisID else { message(FramingLearningError.stale.localizedDescription); return }
        let feedback = FramingObjectFeedback(source: request.origin.source, sourceRevision: request.expectedRevision,
            evidence: request.evidence, boxes: boxes, instance: instance, intent: intent, reason: reason)
        let cancellation = FramingMutationToken(); saveCancellation = cancellation
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer { saveTask = nil; saveCancellation = nil }
            do {
                guard try await library.store.sourceMetadata(feedback.source).0 == feedback.sourceRevision else { throw FramingLearningError.source }
                try Task.checkCancellation()
                let before = try await library.store.snapshot()
                let after = try await library.store.record(feedback, expectedRevision: before.revision, cancellation: cancellation)
                feedbackUndo = (before, after.revision)
                message("\(reason.title) · \(instance.kind.title) · saved · Undo in Zoom menu")
            } catch { message(error.localizedDescription) }
        }
    }
    func undoFeedback() {
        guard saveTask == nil, let undo = feedbackUndo else { message("No framing feedback to undo"); return }
        let cancellation = FramingMutationToken(); saveCancellation = cancellation
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer { saveTask = nil; saveCancellation = nil }
            do {
                _ = try await library.store.restore(undo.checkpoint, expectedRevision: undo.revision, cancellation: cancellation)
                feedbackUndo = nil; window?.coordinator.load(); message("Framing feedback undone")
            } catch {
                feedbackUndo = nil
                message("Cannot undo after another edit · " + error.localizedDescription)
            }
        }
    }
    /// URL caches are unsuitable here: a replaced source may still have cached detections.
    func prepareFeedbackMenu(at point: CGPoint?) async -> NSMenu? {
        guard !preparingFeedbackMenu else { message("Object feedback is being prepared"); return nil }
        preparingFeedbackMenu = true
        defer { preparingFeedbackMenu = false }
        do {
            let request = try captureRequest()
            let url = request.origin.source
            message("Preparing object feedback…")
            guard try await library.store.sourceMetadata(url).0 == request.expectedRevision else { throw FramingLearningError.source }
            guard let boxes = await request.boxes() else { throw FramingLearningError.detection }
            try Task.checkCancellation()
            guard try await library.store.sourceMetadata(url).0 == request.expectedRevision else { throw FramingLearningError.source }
            guard source() == url, currentEvidence() == request.evidence,
                  profile().fingerprint == request.origin.profile.fingerprint,
                  boxes.analysisID == request.evidence.analysisID else { throw FramingLearningError.stale }
            return feedbackMenu(at: point, boxes: boxes, request: request)
        } catch is CancellationError { return nil }
        catch { message(error.localizedDescription); return nil }
    }
    func feedbackMenu(at point: CGPoint?, boxes: SubjectBoxes?, request capturedRequest: FramingCaptureRequest? = nil) -> NSMenu {
        let menu = NSMenu(title: "Framing feedback")
        menu.addItem(FramingFeedbackMenuItem("Comfortable detail view · ⌥1") { [weak self] in self?.save(intent: .detail, advance: false) })
        menu.addItem(FramingFeedbackMenuItem("Good overview composition · ⌥2") { [weak self] in self?.save(intent: .overview, advance: false) })
        menu.addItem(.separator())
        let heading = NSMenuItem(title: "Object feedback · " + intent.title, action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        if let point, let boxes, let request = capturedRequest ?? (try? captureRequest()),
           (boxes.analysisID ?? "vision") == request.evidence.analysisID {
            let hits = FramingInstance.at(point, in: boxes)
            for object in hits.prefix(32) {
                let rect = object.rect
                let title = String(format: "%@ · %@ · centre %.0f%%, %.0f%% · size %.0f%% × %.0f%%", object.kind.title, object.id,
                    rect.midX * 100, rect.midY * 100, rect.width * 100, rect.height * 100)
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)
                for reason in FramingObjectFeedback.Reason.allCases {
                    submenu.addItem(FramingFeedbackMenuItem(reason.title) { [weak self] in
                        self?.recordObject(request: request, boxes: boxes, instance: object, reason: reason)
                    })
                }
                item.submenu = submenu; menu.addItem(item)
            }
            if hits.isEmpty { menu.addItem(NSMenuItem(title: "No detected object under pointer", action: nil, keyEquivalent: "")) }
        } else { menu.addItem(NSMenuItem(title: "Object feedback unavailable for this image", action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        menu.addItem(FramingFeedbackMenuItem("Compare framing variants…") { [weak self] in self?.show() })
        let undo = FramingFeedbackMenuItem("Undo Last Framing Feedback") { [weak self] in self?.undoFeedback() }
        undo.isEnabled = canUndoFeedback; menu.addItem(undo)
        menu.autoenablesItems = false
        return menu
    }
    func show() {
        if let window { window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil); return }
        let baseline = profile(), selectedIntent = intent
        let coordinator = FramingLearningCoordinator(library: library, profile: baseline, intent: intent,
            currentProfile: profile, currentPolicy: { [weak self] in self?.policy() },
            applyTab: { [weak self] profile, policy in
                guard let self, intent == selectedIntent else { return }
                policies[intent] = policy
                if policy == nil { suppressed.insert(intent) } else { suppressed.remove(intent) }
                invalidatePrediction(); applyProfile(profile); reframe()
            }, evidence: { [weak self] in self?.currentEvidence() })
        let learning = FramingLearningWindow(coordinator: coordinator)
        learning.capture = { [weak self] advance in self?.save(intent: selectedIntent, advance: advance) }
        learning.nextPhoto = nextPhoto
        learning.didClose = { [weak self] in self?.window = nil }
        window = learning; learning.showWindow(nil); learning.window?.makeKeyAndOrderFront(nil); coordinator.load()
    }
}

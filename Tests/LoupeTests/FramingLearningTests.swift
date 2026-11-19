import AppKit
import Testing
import LoupeCore
@testable import Loupe

@Suite(.serialized) @MainActor struct FramingLearningTests {
    @Test func explicitObjectFeedbackDoesNotCreateCropAndCanBeUndone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.jpg")
        try Data("source".utf8).write(to: source)
        let revision = try FramingSourceRevision.read(source)
        let store = FramingReferenceStore(directory: dir.appendingPathComponent("learning"))
        let profile = FramingProfile(name: "vision", chain: [.face])
        let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 400, height: 400))
        var boxes = SubjectBoxes(faces: [.init(x: 0.2, y: 0.2, width: 0.2, height: 0.2)], people: [], objects: [], saliency: [])
        boxes.analysisID = "vision"
        let request = FramingCaptureRequest(origin: .init(source: source, profile: profile, behavior: .auto, input: t),
            target: t, evidence: .init(), expectedRevision: revision, boxes: { boxes })
        let helper = ViewerFramingLearning(library: .init(store: store), profile: { profile }, source: { source },
            capture: { request }, apply: { _ in }, reframe: {}, next: {}, message: { _ in })
        helper.recordObject(request: request, boxes: boxes, instance: FramingInstance.all(in: boxes)[0], reason: .blurred)
        await helper.waitForSave()
        #expect(try await store.snapshot().references.isEmpty)
        #expect(try await store.snapshot().objectFeedback.count == 1)
        #expect(helper.canUndoFeedback)
        helper.undoFeedback(); await helper.waitForSave()
        #expect(try await store.snapshot().objectFeedback.isEmpty)
        #expect(!helper.canUndoFeedback)
        helper.save(intent: .detail, advance: false); await helper.waitForSave()
        #expect(helper.canUndoFeedback)
        helper.undoFeedback(); await helper.waitForSave()
        #expect(try await store.snapshot().references.isEmpty)
    }
    @Test func feedbackCommandsAreAssignableToMouseButtons() {
        for name in ["confirm-detail", "confirm-overview", "confirm-detail-and-next", "confirm-overview-and-next",
                     "undo-framing-feedback", "show-framing-feedback", "compare-framing", "toggle-framing-intent"] {
            #expect(KeyAction.allCases.contains { InputConf.actionName($0) == name })
        }
    }
    @Test func feedbackMenuOffersOverlappingObjectsAndNeverInfersLabels() throws {
        let source = URL(fileURLWithPath: "/source.jpg")
        let profile = FramingProfile(name: "vision", chain: [.face])
        let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 400, height: 400))
        let boxes = SubjectBoxes(faces: [.init(x: 0.2, y: 0.2, width: 0.2, height: 0.2)],
            people: [.init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)], objects: [], saliency: [])
        let helper = ViewerFramingLearning(library: .init(store: .init(directory: .temporaryDirectory.appendingPathComponent(UUID().uuidString))),
            profile: { profile }, source: { source }, capture: {
                .init(origin: .init(source: source, profile: profile, behavior: .auto, input: t), target: t,
                    evidence: .init(), expectedRevision: .init(bytes: 10, modified: .distantPast), boxes: { boxes })
            }, apply: { _ in }, reframe: {}, next: {}, message: { _ in })
        let menu = helper.feedbackMenu(at: .init(x: 0.3, y: 0.3), boxes: boxes)
        let objects = menu.items.filter { $0.submenu != nil }
        #expect(objects.count == 2)
        #expect(objects[0].title.hasPrefix("Face"))
        #expect(objects.allSatisfy { $0.submenu?.items.count == 4 })
        #expect(!helper.canUndoFeedback)
        let empty = helper.feedbackMenu(at: .init(x: 0.95, y: 0.95), boxes: boxes)
        #expect(empty.items.allSatisfy { $0.submenu == nil })
    }
    @Test func objectMenuUsesFreshCapturedDetectionsAndRejectsReplacedSource() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.jpg")
        try Data("original".utf8).write(to: source)
        let revision = try FramingSourceRevision.read(source)
        let profile = FramingProfile(name: "vision", chain: [.face])
        let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 400, height: 400))
        var calls = 0
        var boxes = SubjectBoxes(faces: [], people: [.init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)], objects: [], saliency: [])
        boxes.analysisID = "vision"
        let helper = ViewerFramingLearning(library: .init(store: .init(directory: dir.appendingPathComponent("learning"))),
            profile: { profile }, source: { source }, capture: {
                .init(origin: .init(source: source, profile: profile, behavior: .auto, input: t), target: t,
                    evidence: .init(), expectedRevision: revision, boxes: { calls += 1; return boxes })
            }, apply: { _ in }, reframe: {}, next: {}, message: { _ in })
        let menu = await helper.prepareFeedbackMenu(at: .init(x: 0.3, y: 0.3))
        #expect(calls == 1)
        #expect(menu?.items.filter { $0.submenu != nil }.first?.title.hasPrefix("Person") == true)
        try Data("new replacement pixels".utf8).write(to: source)
        #expect(await helper.prepareFeedbackMenu(at: .init(x: 0.3, y: 0.3)) == nil)
        #expect(calls == 1)
    }
    @Test func manualViewingCapturesWithoutAnAutomaticOrigin() throws {
        let source = URL(fileURLWithPath: "/sample.jpg")
        let profile = FramingProfile(name: "vision", chain: [.face])
        let shown = ViewTransform(imageSize: .init(width: 1000, height: 1500), viewSize: .init(width: 400, height: 400), mode: .actual(1))
        let origin = FramingCaptureOrigin.forCapture(nil, source: source, profile: profile, shown: shown)
        let reference = try origin.reference(source: source, target: shown,
            boxes: .init(faces: [], people: [], objects: [], saliency: []), evidence: .init(), intent: .detail)
        #expect(reference.target.transform == shown.clamped)
        #expect(reference.input.isFit)
        #expect(reference.source == source)
        var stale = origin; stale.source = URL(fileURLWithPath: "/other.jpg")
        #expect(FramingCaptureOrigin.forCapture(stale, source: source, profile: profile, shown: shown).source == source)
    }
    @Test func cropShortcutsMatchIntentShiftAndRejectOtherModifiersAndRepeat() throws {
        let menu = Settings.shared.makeZoomMenu()
        func match(_ code: UInt16, _ flags: NSEvent.ModifierFlags, repeatKey: Bool = false) throws -> Selector? {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "!", charactersIgnoringModifiers: "!",
                isARepeat: repeatKey, keyCode: code))
            return Settings.framingShortcut(in: menu, event: event)?.action
        }
        #expect(try match(18, [.option]) == #selector(ViewerWindowController.saveDetailCrop(_:)))
        #expect(try match(19, [.option]) == #selector(ViewerWindowController.saveOverviewCrop(_:)))
        #expect(try match(18, [.option, .shift]) == #selector(ViewerWindowController.saveDetailCropAndNext(_:)))
        #expect(try match(19, [.option, .shift]) == #selector(ViewerWindowController.saveOverviewCropAndNext(_:)))
        #expect(try match(18, []) == nil)
        #expect(try match(1, [.command]) == nil)
        #expect(try match(2, [.command]) == nil)
        #expect(try match(18, [.command]) == nil)
        #expect(try match(18, [.command, .option, .control]) == nil)
        #expect(try match(18, [.command, .control]) == nil)
        #expect(try match(20, [.option]) == nil)
        #expect(try match(18, [.option], repeatKey: true) == nil)
    }
    @Test func mainMenuDoesNotInterceptCropKeysAsTabOrCardCommands() throws {
        _ = NSApplication.shared
        let root = MainMenu(), zoom = Settings.shared.makeZoomMenu(), receiver = FramingShortcutReceiver()
        zoom.delegate = nil
        for item in zoom.items where item.identifier?.rawValue == "framing.save" {
            item.target = receiver; item.action = #selector(FramingShortcutReceiver.save(_:))
        }
        let parent = NSMenuItem(); parent.submenu = zoom; root.addItem(parent)
        for (code, letter) in [(UInt16(18), "1"), (UInt16(19), "2")] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option],
                timestamp: 0, windowNumber: 0, context: nil, characters: letter, charactersIgnoringModifiers: letter,
                isARepeat: false, keyCode: code))
            #expect(root.performKeyEquivalent(with: event))
        }
        #expect(receiver.count == 2)
    }
    @Test func transientOriginDoesNotKeepRejectingAnAlreadySettledCrop() throws {
        let source = URL(fileURLWithPath: "/sample.jpg")
        var input = ViewTransform(imageSize: .init(width: 1000, height: 1500), viewSize: .init(width: 800, height: 600), mode: .actual(1))
        input.offset = .init(dx: 12, dy: -4)
        let origin = FramingCaptureOrigin(source: source, profile: .init(name: "test", chain: [.face]), behavior: .pan, input: input)
        let target = input.withOffset(.zero).clamped
        let reference = try origin.reference(source: source, target: target,
            boxes: .init(faces: [], people: [], objects: [], saliency: []), evidence: .init(), intent: .detail)
        #expect(reference.input.transform == target)
        #expect(reference.input.scale == input.scale)
    }
    @Test func originSurvivesManualModeButRejectsAnotherPhoto() throws {
        let source = URL(fileURLWithPath: "/sample.jpg")
        let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 400, height: 400), mode: .actual(1))
        let origin = FramingCaptureOrigin(source: source, profile: .init(name: "test", chain: [.face]), behavior: .pan, input: t)
        let boxes = SubjectBoxes(faces: [], people: [], objects: [], saliency: [])
        let reference = try origin.reference(source: source, target: t, boxes: boxes, evidence: .init(), intent: .detail)
        #expect(reference.behavior == .pan && reference.input.scale == 1)
        #expect(throws: Error.self) { try origin.reference(source: URL(fileURLWithPath: "/other.jpg"), target: t,
            boxes: boxes, evidence: .init(), intent: .detail) }
    }
    @Test func librarySerializesFitsAndTabPoliciesRemainLocal() {
        let store = FramingReferenceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = FramingLearningLibrary(store: store)
        let first = UUID(), other = UUID()
        #expect(library.acquire(first))
        #expect(!library.acquire(other))
        library.release(other)
        #expect(!library.acquire(other))
        library.release(first)
        #expect(library.acquire(other))
    }
    @Test func smartZoomRightClickCheckboxIsOptInAndPersistsAcrossLibraryInstances() throws {
        _ = NSApplication.shared
        let name = "LoupeFramingTest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = FramingReferenceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        let library = FramingLearningLibrary(store: store, defaults: defaults)
        let panel = SmartZoomPanel()
        panel.feedbackSettings = { library }
        panel.setVisible(true)
        let stack = try #require(panel.view.documentView as? NSStackView)
        let checkbox = try #require(stack.arrangedSubviews.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "smartzoom.object-feedback-on-right-click"
        })
        #expect(checkbox.state == .off)
        #expect(!library.objectFeedbackOnRightClick)
        checkbox.performClick(nil)
        let reopened = FramingLearningLibrary(store: store, defaults: try #require(UserDefaults(suiteName: name)))
        #expect(reopened.objectFeedbackOnRightClick)
        reopened.objectFeedbackOnRightClick = false
        panel.refreshObjectFeedbackBinding()
        #expect(checkbox.state == .off)
        #expect(!library.objectFeedbackOnRightClick)
    }
    @Test func foregroundWaitCanBeCancelled() async throws {
        let gate = FramingWorkGate()
        await gate.setBusy(true)
        let waiting = Task { try await gate.checkpoint() }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await gate.setBusy(false)
        try await gate.checkpoint()
    }
    @Test func predictionIdentityIncludesVisionAndDetectorEvidence() async throws {
        let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 400, height: 400))
        let profile = FramingProfile(name: "test", chain: [.face])
        let boxes = SubjectBoxes(faces: [.init(x: 0.1, y: 0.1, width: 0.1, height: 0.1)], people: [], objects: [], saliency: [])
        var a = FramingPredictionIdentity(source: URL(fileURLWithPath: "/sample.jpg"), profile: profile,
            intent: .detail, behavior: .auto, input: try FramingGeometry(t), boxes: boxes, evidence: .init())
        var b = a; b.boxes.faces[0].origin.x += 0.1
        #expect(a != b)
        b = a; b.evidence.analysisID = "replacement"
        #expect(a != b)
        b = a; b.boxes.applied = false
        #expect(a != b)
        let reference = try FramingReference(source: a.source, profile: profile, behavior: .auto, input: t, target: t, boxes: boxes)
        a.policy = try await FramingFitter.fit(profile: profile, references: [reference], budget: .testing).policy
        b = a; b.policy?.coefficients[0] = 1
        #expect(a != b)
    }
    @Test func visionPolicyPersistsAndUndoRestoresThePriorPolicy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FramingReferenceStore(directory: dir)
        let baseline = FramingProfile(name: "vision", chain: [.face])
        let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 400, height: 400))
        let sample = try FramingReference(source: URL(fileURLWithPath: "/sample.jpg"), profile: baseline,
            behavior: .auto, input: t, target: t, boxes: .init(faces: [.init(x: 0.3, y: 0.2, width: 0.2, height: 0.2)], people: [], objects: [], saliency: []))
        _ = try await store.upsert(sample)
        let library = FramingLearningLibrary(store: store)
        var active: FramingPolicy?, appliedProfile = baseline
        let model = FramingLearningCoordinator(library: library, profile: baseline, intent: .detail,
            currentProfile: { appliedProfile }, currentPolicy: { active }, applyTab: { p, policy in appliedProfile = p; active = policy })
        model.load(); await model.waitForCurrentOperation()
        model.fit(); await model.waitForCurrentOperation()
        #expect(model.result != nil)
        model.apply(persist: true); await model.waitForCurrentOperation()
        #expect(appliedProfile == baseline && active != nil && !model.canApply)
        let reopened = FramingLearningLibrary(store: .init(directory: dir))
        try await reopened.reload()
        #expect(reopened.policy(profile: baseline, intent: .detail) == active)
        model.undo(); await model.waitForCurrentOperation()
        #expect(active == nil && appliedProfile == baseline)
        #expect(try await store.savedPolicies().isEmpty)
        model.apply(persist: false); model.cancel(); await model.waitForCurrentOperation()
        #expect(active == nil)
    }
    @Test func replacedSourceIsRejectedBeforeRunningDetectionOrSaving() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.jpg")
        try Data("replacement bytes".utf8).write(to: source)
        let store = FramingReferenceStore(directory: dir.appendingPathComponent("references"))
        let profile = FramingProfile(name: "vision", chain: [.face])
        let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 400, height: 400))
        var calledDetector = false
        let helper = ViewerFramingLearning(library: .init(store: store), profile: { profile }, source: { source }, capture: {
            .init(origin: .init(source: source, profile: profile, behavior: .auto, input: t), target: t, evidence: .init(),
                expectedRevision: .init(bytes: 1, modified: .distantPast), boxes: { calledDetector = true; return nil })
        }, apply: { _ in }, reframe: {}, next: {}, message: { _ in })
        helper.save(intent: .detail, advance: false); await helper.waitForSave()
        #expect(!calledDetector)
        #expect(try await store.snapshot().references.isEmpty)
    }
    @Test func rememberAndNextRestoresAutoOnlyAfterPersistenceSucceeds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.jpg")
        try Data("captured source".utf8).write(to: source)
        let revision = try FramingSourceRevision.read(source)
        let store = FramingReferenceStore(directory: dir.appendingPathComponent("references"))
        let profile = FramingProfile(name: "vision", chain: [.face])
        let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 400, height: 400))
        var resumed = false, advanced = false
        var messages: [String] = []
        var boxes = SubjectBoxes(faces: [], people: [], objects: [], saliency: []); boxes.analysisID = "vision"
        let helper = ViewerFramingLearning(library: .init(store: store), profile: { profile }, source: { source }, capture: {
            .init(origin: .init(source: source, profile: profile, behavior: .auto, input: t), target: t, evidence: .init(),
                expectedRevision: revision, boxes: { boxes })
        }, apply: { _ in }, reframe: {}, next: { advanced = true }, message: { messages.append($0) })
        helper.resumeForNext = { behavior in resumed = behavior == .auto }
        helper.save(intent: .detail, advance: true)
        #expect(!advanced && !resumed)
        await helper.waitForSave()
        #expect(advanced && resumed)
        #expect(messages.last == "Detail crop saved · source.jpg → next photo · Undo in Zoom menu")
        #expect(try await store.snapshot().references.count == 1)
        resumed = false; advanced = false
        helper.save(intent: .overview, advance: false); await helper.waitForSave()
        #expect(!advanced && !resumed)
        #expect(messages.last == "Overview crop saved · source.jpg · Undo in Zoom menu")
        #expect(try await store.snapshot().references.count == 2)
        let manual = ViewerFramingLearning(library: .init(store: store), profile: { profile }, source: { source }, capture: {
            .init(origin: .forCapture(nil, source: source, profile: profile, shown: t), target: t, evidence: .init(),
                expectedRevision: revision, boxes: { boxes }, resumeAutomaticMode: false)
        }, apply: { _ in }, reframe: {}, next: { advanced = true }, message: { _ in })
        manual.resumeForNext = { _ in resumed = true }
        resumed = false; advanced = false
        manual.save(intent: .detail, advance: true); await manual.waitForSave()
        #expect(advanced && !resumed)

    }
}

@MainActor private final class FramingShortcutReceiver: NSObject {
    var count = 0
    @objc func save(_ sender: Any?) { count += 1 }
}

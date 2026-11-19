import AppKit
import Foundation
import Testing
import LoupeCore
@testable import Loupe

@Suite(.serialized) @MainActor struct FramingLearningWindowTests {
    func coordinator() -> FramingLearningCoordinator {
        let profile = FramingProfile(name: "test", chain: [.face])
        return FramingLearningCoordinator(library: .init(store: .init(directory:
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))), profile: profile,
            intent: .detail, currentProfile: { profile }, currentPolicy: { nil }, applyTab: { _, _ in })
    }
    @Test func nativeWindowHasDirectTrainingControls() {
        let learning = FramingLearningWindow(coordinator: coordinator())
        defer { learning.close() }
        let ids = Set(descendants(learning.window!.contentView!).compactMap { $0.identifier?.rawValue })
        #expect(ids.isSuperset(of: ["learning.save", "learning.save-next", "learning.fit", "learning.cancel",
            "learning.remove", "learning.apply", "learning.undo", "learning.references"]))
    }
    @Test func comparisonAssignmentIsBalancedAndStable() {
        let id = UUID()
        #expect(FramingLearningWindow.candidateFirst(index: 0, run: id) != FramingLearningWindow.candidateFirst(index: 1, run: id))
        #expect(FramingLearningWindow.candidateFirst(index: 0, run: id) == FramingLearningWindow.candidateFirst(index: 0, run: id))
    }
    @Test func closingCancelsAndCallsOwner() {
        let model = coordinator(), learning = FramingLearningWindow(coordinator: coordinator())
        var closed = false
        learning.didClose = { closed = true }
        learning.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(closed && !model.running)
    }
    @Test func cropPreviewsClipTheirDrawingToTheirOwnBounds() {
        let learning = FramingLearningWindow(coordinator: coordinator())
        defer { learning.close() }
        let previews = descendants(learning.window!.contentView!).filter { $0.identifier?.rawValue.hasPrefix("learning.preview") == true }
        #expect(previews.count == 3)
        let clipped = previews.allSatisfy { $0.clipsToBounds }
        #expect(clipped)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

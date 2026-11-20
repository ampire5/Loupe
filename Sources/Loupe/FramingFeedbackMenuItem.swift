import AppKit

/// A menu item retains its own action for the lifetime of a native tracking menu.
@MainActor final class FramingFeedbackMenuItem: NSMenuItem {
    private let invoke: () -> Void
    init(_ title: String, invoke: @escaping () -> Void) {
        self.invoke = invoke
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { invoke() }
}

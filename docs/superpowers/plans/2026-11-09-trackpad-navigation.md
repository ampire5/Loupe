# Trackpad navigation implementation plan

**Goal:** Separate photo navigation, folder navigation, and panel controls by finger count. Keep tabs on keyboard shortcuts.

- [x] Let two-finger pans follow the fingers. Pinch around the pointer. Two-finger double tap switches Fit / 100%.
- [x] Use three fingers for photo swipes, directional filmstrip visibility and distinct Fit Height / Fit Width scales on double tap. A held click and two other fingers step folders horizontally and show or hide the toolbar vertically.
- [x] Keep information on one-finger Force Click. Double light tap toggles status. Double physical click opens the current folder browser. Force presses do not count toward either pair. Slots reveal at the edges.
- [x] Let horizontal photo and folder swipes reverse before lift without switching axes.
- [x] Show the filmstrip candidate during motion and commit only at rest. Default to left for next.
- [x] Mark panel and mode changes, zoom stops and limits, photo boundaries, and successful folder changes with AppKit feedback. Let the test build select a system pattern.
- [ ] Confirm reversal while a physical click is held, and compare the pulse patterns on Magic Trackpad.

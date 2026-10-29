import Testing
@testable import LoupeCore

// A photo to be framed waits a moment for its subjects instead of showing at Fit and gliding (owner, 2026-10-28).
@Test func onlyAPhotoToBeFramedWithItsSubjectsUnknownWaits() {
    #expect(FramingHold.holds(framing: true, known: false, seeded: false, byStep: false, opened: false))
    #expect(!FramingHold.holds(framing: false, known: false, seeded: false, byStep: false, opened: false))
    #expect(!FramingHold.holds(framing: true, known: true, seeded: false, byStep: false, opened: false))
    #expect(!FramingHold.holds(framing: true, known: false, seeded: true, byStep: false, opened: false))
    #expect(!FramingHold.holds(framing: true, known: false, seeded: false, byStep: true, opened: false))
    #expect(!FramingHold.holds(framing: true, known: false, seeded: false, byStep: false, opened: true))
    #expect(FramingHold.wait > 0 && FramingHold.wait <= 0.25)
}

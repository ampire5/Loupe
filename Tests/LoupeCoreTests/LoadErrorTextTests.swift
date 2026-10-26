import Foundation
import Testing
@testable import LoupeCore

@Test func decodeErrorsAreShortAndNameTheFileOnce() {
    let size = PixelSize(width: 24000, height: 24000)
    #expect(LoadErrorText.message(name: "a.jpg", error: DecodeError.unreadable, size: nil) == "a.jpg: unreadable or unsupported image")
    #expect(LoadErrorText.message(name: "a.jpg", error: DecodeError.outOfMemory, size: nil) == "a.jpg: not enough memory")
    #expect(LoadErrorText.message(name: "a.jpg", error: DecodeError.tooLarge, size: size) == "a.jpg: too large to display (24000×24000)")
    #expect(LoadErrorText.message(name: "a.jpg", error: DecodeError.tooLarge, size: nil) == "a.jpg: too large to display")
}

@Test func fileErrorsUseTheReasonNotTheSystemSentence() {
    let url = URL(fileURLWithPath: "/nonexistent-dir/x.jpg")
    do {
        _ = try Data(contentsOf: url)
        Issue.record("the read should have failed")
    } catch {
        let text = LoadErrorText.message(name: "x.jpg", error: error, size: nil)
        #expect(text.components(separatedBy: "x.jpg").count == 2, "\(text)")   // the name once
        #expect(!text.contains("\n"))
        #expect(!text.contains("couldn"))
    }
    #expect(LoadErrorText.message(name: "x.jpg", error: CocoaError(.fileReadUnknown), size: nil).hasPrefix("x.jpg: "))
    struct Other: Error {}
    #expect(LoadErrorText.message(name: "x.jpg", error: Other(), size: nil) == "x.jpg: can’t be displayed")
}

/// Only a file the decoders cannot read is broken; one too large, out of memory or not read at all may be shown later.
@Test func onlyAnUnreadableImageIsABrokenFile() {
    let size = PixelSize(width: 24000, height: 24000)
    #expect(LoadErrorText.isBroken(LoadErrorText.message(name: "a.jpg", error: DecodeError.unreadable, size: nil)))
    #expect(!LoadErrorText.isBroken(LoadErrorText.message(name: "a.jpg", error: DecodeError.outOfMemory, size: nil)))
    #expect(!LoadErrorText.isBroken(LoadErrorText.message(name: "a.jpg", error: DecodeError.tooLarge, size: size)))
    #expect(!LoadErrorText.isBroken(LoadErrorText.message(name: "a.jpg", error: CocoaError(.fileReadNoSuchFile), size: nil)))
}

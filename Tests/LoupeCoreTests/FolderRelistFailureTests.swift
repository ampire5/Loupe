import Foundation
import Testing
@testable import LoupeCore

/// A relist of the open folder that failed: gone only when the system says there is no such folder and its parent
/// still answers; a share's error, a time out or a volume that does not answer keeps the folder.
@Suite struct FolderRelistFailureTests {
    @Test func noSuchFolderOnAnAnsweringVolumeIsGone() {
        #expect(FolderRelistFailure(POSIXError(.ENOENT), parentAnswers: true) == .gone)
        #expect(FolderRelistFailure(POSIXError(.ENOTDIR), parentAnswers: true) == .gone)
        #expect(FolderRelistFailure(CocoaError(.fileReadNoSuchFile), parentAnswers: true) == .gone)
        #expect(FolderRelistFailure(CocoaError(.fileNoSuchFile), parentAnswers: true) == .gone)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOENT)])
        #expect(FolderRelistFailure(wrapped, parentAnswers: true) == .gone)
    }

    @Test func shareErrorsAreNotAnswering() {
        for code in [POSIXErrorCode.ETIMEDOUT, .EIO, .ENOTCONN, .EHOSTDOWN, .ENETDOWN, .EACCES] {
            #expect(FolderRelistFailure(POSIXError(code), parentAnswers: true) == .notAnswering, "\(code)")
        }
        #expect(FolderRelistFailure(CocoaError(.fileReadUnknown), parentAnswers: true) == .notAnswering)
    }

    /// No such folder, but the parent does not answer either (the share dropped): not taken as gone.
    @Test func offlineVolumeIsNotAnswering() {
        #expect(FolderRelistFailure(POSIXError(.ENOENT), parentAnswers: false) == .notAnswering)
    }
}

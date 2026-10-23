import Foundation
import Testing
@testable import LoupeCore

/// A relist of the open folder that failed: gone only when the system says there is no such folder and the nearest
/// ancestor that is there answers (missing ancestors are walked past); a share's error, a time out or a volume that
/// does not answer keeps the folder.
@Suite struct FolderRelistFailureTests {
    typealias Probe = FolderRelistFailure.Probe

    @Test func noSuchFolderOnAnAnsweringVolumeIsGone() {
        #expect(FolderRelistFailure(POSIXError(.ENOENT), ancestors: [.answers]) == .gone)
        #expect(FolderRelistFailure(POSIXError(.ENOTDIR), ancestors: [.answers]) == .gone)
        #expect(FolderRelistFailure(CocoaError(.fileReadNoSuchFile), ancestors: [.answers]) == .gone)
        #expect(FolderRelistFailure(CocoaError(.fileNoSuchFile), ancestors: [.answers]) == .gone)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOENT)])
        #expect(FolderRelistFailure(wrapped, ancestors: [.answers]) == .gone)
    }

    /// The parent gone too (an ancestor trashed or renamed): the grandparent answering is the witness.
    @Test func parentMissingAndGrandparentAnsweringIsGone() {
        #expect(FolderRelistFailure(POSIXError(.ENOENT), ancestors: [.missing, .answers]) == .gone)
        #expect(FolderRelistFailure(POSIXError(.ENOENT), ancestors: [.missing, .missing, .answers]) == .gone)
    }

    @Test func shareErrorsAreNotAnswering() {
        for code in [POSIXErrorCode.ETIMEDOUT, .EIO, .ENOTCONN, .EHOSTDOWN, .ENETDOWN, .EACCES] {
            #expect(FolderRelistFailure(POSIXError(code), ancestors: [.answers]) == .notAnswering, "\(code)")
        }
        #expect(FolderRelistFailure(CocoaError(.fileReadUnknown), ancestors: [.answers]) == .notAnswering)
    }

    @Test func parentTimingOutIsNotAnswering() {
        #expect(FolderRelistFailure(POSIXError(.ENOENT), ancestors: [.noAnswer]) == .notAnswering)
    }

    @Test func parentMissingAndGrandparentTimingOutIsNotAnswering() {
        #expect(FolderRelistFailure(POSIXError(.ENOENT), ancestors: [.missing, .noAnswer]) == .notAnswering)
        #expect(FolderRelistFailure(POSIXError(.ENOENT), ancestors: [.missing]) == .notAnswering)   // none answered
        #expect(FolderRelistFailure(POSIXError(.ENOENT), ancestors: []) == .notAnswering)          // no probe
    }
}

/// The ancestors' probe: walked up from the parent until one is there (or does not answer), one probe at a time.
@Suite struct AncestorProbeTests {
    @Test func walksUpPastMissingFolders() async {
        let probe = AncestorProbe { path in path == "/v/a" ? .answers : .missing }
        let result = await probe.run(URL(fileURLWithPath: "/v/a/b/c"), timeout: .seconds(5))
        #expect(result == [.missing, .answers])
    }

    @Test func stopsAtANoAnswer() async {
        let probe = AncestorProbe { _ in .noAnswer }
        #expect(await probe.run(URL(fileURLWithPath: "/v/a/b"), timeout: .seconds(5)) == [.noAnswer])
    }

    /// A probe that hangs answers "no answer" at its deadline, and while it is still out no other one starts.
    @Test func oneProbeInFlight() async {
        let gate = HoldGate()
        let calls = Locked(0)
        let probe = AncestorProbe { _ in
            calls.update { $0 += 1 }
            let done = DispatchSemaphore(value: 0)
            Task { try? await gate.wait(); done.signal() }
            done.wait()
            return .answers
        }
        let folder = URL(fileURLWithPath: "/v/a/b")
        #expect(await probe.run(folder, timeout: .milliseconds(50)) == [.noAnswer])
        #expect(await probe.run(folder, timeout: .milliseconds(50)) == nil)   // the first still out: skipped
        #expect(calls.get == 1)
        gate.open()
        for _ in 0..<200 where await probe.isBusy { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.run(folder, timeout: .seconds(5)) == [.answers])
    }
}

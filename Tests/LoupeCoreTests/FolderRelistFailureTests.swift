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

    /// A first listing that failed on a share that does not answer is tried again one unwatched poll later, stretched
    /// by how long the failure took to come.
    @Test func failedFirstListingIsRetriedAtThePoll() {
        #expect(FolderRelistFailure.retryFirstListing(after: POSIXError(.ETIMEDOUT), ancestors: [.noAnswer],
                                                      pollMilliseconds: 3000, took: .milliseconds(50)) == .seconds(3))
        #expect(FolderRelistFailure.retryFirstListing(after: POSIXError(.ETIMEDOUT), ancestors: [.answers],
                                                      pollMilliseconds: 3000, took: .seconds(2)) == .seconds(20))
    }

    /// Not again: the folder is gone, a permission refused gets the same answer, polling is off.
    @Test func failedFirstListingNotRetried() {
        #expect(FolderRelistFailure.retryFirstListing(after: POSIXError(.ENOENT), ancestors: [.answers],
                                                      pollMilliseconds: 3000, took: .milliseconds(5)) == nil)
        #expect(FolderRelistFailure.retryFirstListing(after: POSIXError(.EACCES), ancestors: [.answers],
                                                      pollMilliseconds: 3000, took: .milliseconds(5)) == nil)
        #expect(FolderRelistFailure.retryFirstListing(after: CocoaError(.fileReadNoPermission), ancestors: [.answers],
                                                      pollMilliseconds: 3000, took: .milliseconds(5)) == nil)
        #expect(FolderRelistFailure.retryFirstListing(after: POSIXError(.ETIMEDOUT), ancestors: [.noAnswer],
                                                      pollMilliseconds: 0, took: .milliseconds(5)) == nil)
    }
}

/// The ancestors' probe: walked up from the parent until one is there (or does not answer), never above the folder's
/// mount point, one probe at a time.
@Suite struct AncestorProbeTests {
    @Test func walksUpPastMissingFolders() async {
        let probe = AncestorProbe(open: { path in path == "/v/a" ? .answers : .missing }, mountPoints: { ["/", "/v"] })
        let result = await probe.run(URL(fileURLWithPath: "/v/a/b/c"), mountPoint: "/v", timeout: .seconds(5))
        #expect(result == [.missing, .answers])
    }

    @Test func stopsAtANoAnswer() async {
        let probe = AncestorProbe(open: { _ in .noAnswer }, mountPoints: { ["/", "/v"] })
        #expect(await probe.run(URL(fileURLWithPath: "/v/a/b"), mountPoint: "/v", timeout: .seconds(5)) == [.noAnswer])
    }

    /// A share dropped: everything under it, its mount point too, is missing, and the volume above answers. The walk
    /// stops at the mount point, so the folder is not answering, not gone.
    @Test func droppedShareIsNotGone() async {
        let probe = AncestorProbe(open: { $0.hasPrefix("/mnt/photos") ? .missing : .answers },
                                  mountPoints: { ["/", "/mnt/photos"] })
        let error = POSIXError(.ENOENT)
        let result = await probe.run(URL(fileURLWithPath: "/mnt/photos/a/b"), mountPoint: "/mnt/photos",
                                     timeout: .seconds(5))
        #expect(result == [.missing, .missing, .noAnswer])
        #expect(FolderRelistFailure(error, ancestors: result ?? []) == .notAnswering)
    }

    /// The share's mount point is out of the mount table: its folder left behind (a custom mount point) answers, but
    /// it is not the share, so nothing under it is asked.
    @Test func unmountedShareIsNotGone() async {
        let calls = Locked(0)
        let probe = AncestorProbe(open: { path in calls.update { $0 += 1 }; return path == "/mnt/photos" ? .answers : .missing },
                                  mountPoints: { ["/"] })
        let result = await probe.run(URL(fileURLWithPath: "/mnt/photos/a/b"), mountPoint: "/mnt/photos",
                                     timeout: .seconds(5))
        #expect(result == [.noAnswer])
        #expect(calls.get == 0)
        #expect(FolderRelistFailure(POSIXError(.ENOENT), ancestors: result ?? []) == .notAnswering)
    }

    /// The folder and its parent gone while the share's mount point answers: gone.
    @Test func folderAndParentGoneOnAnAnsweringShareIsGone() async {
        let probe = AncestorProbe(open: { $0 == "/mnt/photos" ? .answers : .missing },
                                  mountPoints: { ["/", "/mnt/photos"] })
        let result = await probe.run(URL(fileURLWithPath: "/mnt/photos/a/b"), mountPoint: "/mnt/photos",
                                     timeout: .seconds(5))
        #expect(result == [.missing, .answers])
        #expect(FolderRelistFailure(POSIXError(.ENOENT), ancestors: result ?? []) == .gone)
    }

    /// An ejected local disk follows the same rule: its mount point gone (or out of the table) is not a witness.
    @Test func ejectedDiskIsNotGone() async {
        let probe = AncestorProbe(open: { $0.hasPrefix("/Volumes/Disk") ? .missing : .answers },
                                  mountPoints: { ["/", "/Volumes/Disk"] })
        let folder = URL(fileURLWithPath: "/Volumes/Disk/a")
        let result = await probe.run(folder, mountPoint: "/Volumes/Disk", timeout: .seconds(5))
        #expect(result == [.missing, .noAnswer])
        #expect(FolderRelistFailure(POSIXError(.ENOENT), ancestors: result ?? []) == .notAnswering)
        let ejected = AncestorProbe(open: { $0.hasPrefix("/Volumes/Disk") ? .missing : .answers },
                                    mountPoints: { ["/"] })
        #expect(await ejected.run(folder, mountPoint: "/Volumes/Disk", timeout: .seconds(5)) == [.noAnswer])
    }

    /// No mount point known for the folder: no witness.
    @Test func noMountPointIsNoAnswer() async {
        let probe = AncestorProbe(open: { _ in .answers }, mountPoints: { ["/"] })
        #expect(await probe.run(URL(fileURLWithPath: "/v/a"), mountPoint: nil, timeout: .seconds(5)) == [.noAnswer])
    }

    /// The folder's mount point, from the mount table as written: the longest that holds it, at any path.
    @Test func mountPointIsTheLongestInTheTable() {
        let table = ["/", "/System/Volumes/Data", "/mnt/photos"]
        #expect(AncestorProbe.mountPoint(of: "/mnt/photos/a/b", in: table) == "/mnt/photos")
        #expect(AncestorProbe.mountPoint(of: "/mnt/photosx/a", in: table) == "/")
        #expect(AncestorProbe.mountPoint(of: "/mnt/photos", in: table) == "/mnt/photos")
        #expect(AncestorProbe.mountPoint(of: "/mnt/photos/a", in: []) == nil)
    }

    /// A probe that hangs answers "no answer" at its deadline, and while it is still out no other one starts.
    @Test func oneProbeInFlight() async {
        let gate = HoldGate()
        let calls = Locked(0)
        let probe = AncestorProbe(open: { _ in
            calls.update { $0 += 1 }
            let done = DispatchSemaphore(value: 0)
            Task { try? await gate.wait(); done.signal() }
            done.wait()
            return .answers
        }, mountPoints: { ["/", "/v"] })
        let folder = URL(fileURLWithPath: "/v/a/b")
        #expect(await probe.run(folder, mountPoint: "/v", timeout: .milliseconds(50)) == [.noAnswer])
        #expect(await probe.run(folder, mountPoint: "/v", timeout: .milliseconds(50)) == nil)   // the first still out
        #expect(calls.get == 1)
        gate.open()
        for _ in 0..<200 where await probe.isBusy { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.run(folder, mountPoint: "/v", timeout: .seconds(5)) == [.answers])
    }
}

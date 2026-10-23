import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

// ImageCache against fakes (CacheFakes.swift) through the rig (ImageCacheRig.swift). Each test ends by clearing the
// playlist, which cancels whatever is left.

@Suite(.timeLimit(.minutes(1)))
struct ImageCacheTests {
    /// Every decode is held during the burst, so the jobs started for passed photos are either still waiting
    /// (and must be cancelled: never decoded) or decoding on one of the three slots (lazy eviction, spec §11.1:
    /// their result is uploaded if it fits). Nothing passed is decoded at full resolution.
    /// `cache-previews = 3` keeps files 0…7 out of the final plan (9 dwelling: 9, n1 = 10, p1 = 8).
    @Test func burstShowsOnlyLast() async {
        var limits = CacheLimits.at3G
        limits.previews = 3
        let rig = Rig(limits: limits)
        let files = fileURLs(20)
        rig.distinctWidths(files)
        let gate = BlockingGate()
        rig.decoder.gateAllDecodes(gate)
        for i in 0...9 {
            await rig.focus(files, i)
            try? await Task.sleep(for: .milliseconds(5))
        }
        await rig.focus(files, 9, dwelling: true)
        rig.decoder.gateAllDecodes(nil)
        gate.open()
        #expect(await eventually { await rig.state(files[9]) == .full })
        #expect(await rig.settle())
        // The gate held every slot through the burst, so only the decodes it held ever started for passed photos.
        let decodingAtTheEnd = Set((0...7).filter { i in
            rig.decoder.calls(files[i]).contains { if case .preview = $0 { true } else { false } }
        })
        #expect(rig.loader.uploadedLevels(width: rig.width(9)).contains(0))
        #expect(decodingAtTheEnd.count <= 3, "more passed decodes than slots: \(decodingAtTheEnd)")
        for i in 0...7 {
            #expect(!rig.decoder.calls(files[i]).contains(.full), "file \(i)")
            if !decodingAtTheEnd.contains(i) {
                #expect(rig.decoder.calls(files[i]).allSatisfy { $0 == .probe }, "file \(i) decoded after it was passed")
                #expect(rig.loader.uploadedLevels(width: rig.width(i)).isEmpty, "file \(i) reached the GPU")
            }
        }
        await rig.clear()
    }

    /// Both shared slots held by neighbour decodes that do not finish until the end of the test: the new current
    /// photo still gets its preview (on the reserved slot), and setFocus returns meanwhile. Held by a gate rather than
    /// by 300 ms sleeps against a 150 ms budget, which measured the machine as much as the pool: GitHub's virtual
    /// machines stall for hundreds of ms now and then.
    @Test func currentNotBlockedByNeighbours() async {
        let rig = Rig()
        let files = fileURLs(60)
        let neighbours = BlockingGate()
        for (i, url) in files.enumerated() where i != 0 && i != 40 { rig.decoder.gateDecodes(url, neighbours) }
        await rig.focus(files, 0, dwelling: true)   // neighbours read only once the user stays
        #expect(await eventually { atLeast(.preview, await rig.state(files[0])) })
        // Both shared slots busy with neighbour decodes that wait for the gate.
        #expect(await eventually {
            rig.decoder.calls.filter { if case .preview = $0.kind { $0.name != "0.jpg" } else { false } }.count >= 2
        })

        await rig.focus(files, 40)   // returns although the neighbours' decodes are still held
        #expect(await eventually { atLeast(.preview, await rig.state(files[40])) })
        neighbours.open()
        await rig.clear()
    }

    @Test func oneReadForPreviewAndFull() async {
        let rig = Rig()
        let files = fileURLs(5)
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { await rig.state(files[0]) == .full })
        #expect(await rig.settle())
        #expect(rig.reader.readCount(files[0]) == 1)
        #expect(rig.decoder.calls(files[0]).contains(.preview(1)))
        #expect(rig.decoder.calls(files[0]).filter { $0 == .full }.count == 1)
        await rig.clear()
    }

    @Test func stuckReadDoesNotBlockOthers() async {
        let rig = Rig()
        let files = fileURLs(10)
        let gate = AsyncGate()
        rig.reader.hang(files[5], on: gate)
        await rig.focus(files, 5, dwelling: true)
        #expect(await eventually {
            let four = await rig.state(files[4]), six = await rig.state(files[6])
            return atLeast(.preview, four) && atLeast(.preview, six)
        })
        #expect(await rig.cache.entry(files[5])?.failure == nil)
        gate.open(.failure(ReadError.notResponding))
        #expect(await eventually { await rig.cache.entry(files[5])?.failure != nil })
        #expect(await rig.cache.entry(files[5])?.pyramid == nil)
        await rig.clear()
    }

    /// Spec §11.1: moving away keeps what fits under `cache-memory`; what does not is evicted farthest first.
    /// 147 MP photos, 3 GB: the old neighbourhood (91…110 with two fulls) cannot all stay next to the new one.
    @Test func evictsOutsidePlan() async {
        var limits = CacheLimits.at3G
        limits.memory = 3 << 30
        limits.previews = 20
        let rig = Rig(size: CachePlan.defaultPixelSize, limits: limits)
        let files = fileURLs(200)
        let screen = PixelSize(width: 2560, height: 1600)
        let lfit = TileGrid(imageSize: CachePlan.defaultPixelSize).previewLevel(forScreen: screen)

        await rig.focus(files, 100, dwelling: true, screen: screen)
        #expect(await eventually { await rig.state(files[100]) == .full })
        #expect(await rig.settle())
        #expect(await rig.state(files[101]) == .full)   // n1 at full resolution

        await rig.focus(files, 130, dwelling: true, screen: screen)
        #expect(await rig.settle())
        let stats = await rig.cache.stats()
        #expect(stats.usedBytes <= stats.limitBytes)
        #expect(stats.limitBytes == 3 << 30)
        #expect(await rig.finest(files[129]) == lfit)
        #expect(await rig.state(files[129]) == .preview)
        // Farthest first: no old photo has lost its levels while a farther one still holds some. (Compressed bytes go
        // only after every candidate's levels, and some went already while 100 was current, farthest from it.)
        var nearestEmptied = Int.max
        var farthestKept = 0
        for i in 91...110 {
            let held = atLeast(.coarse, await rig.state(files[i]))
            if held { farthestKept = max(farthestKept, 130 - i) } else { nearestEmptied = min(nearestEmptied, 130 - i) }
        }
        #expect(farthestKept <= nearestEmptied, "kept distance \(farthestKept), emptied \(nearestEmptied)")
        #expect(nearestEmptied != Int.max, "nothing of the old neighbourhood was evicted")
        await rig.clear()
    }

    /// A preview that came back finer than planned (PNG-like level 0) is kept while it fits (spec §11.1) and trimmed
    /// to the planned level once `cache-memory` leaves no room for it.
    @Test func previewFinerThanLfitIsTrimmed() async {
        let rig = Rig()
        rig.decoder.previewAtLevel0 = true
        let files = fileURLs(10)
        await rig.focus(files, 0, dwelling: true)   // neighbours are read once the user stays...
        #expect(await rig.settle())
        await rig.focus(files, 0)                   // ...and the plan below is the one without fulls
        #expect(await rig.settle())
        #expect(await rig.finest(files[1]) == 0)   // fits under 3 GB: kept

        // Room for the plan (0, 1 previews at Lfit, 2 and 3 near previews, 4…9 coarse) plus 1 MB, less than any level 0.
        let grid = TileGrid(imageSize: rigPhoto)
        let planned = 4 * grid.byteCount(levels: 1..<3) + 6 * grid.byteCount(levels: 2..<3) + 7 * 1000
        await rig.setMemory(planned + (1 << 20))
        #expect(await rig.settle())
        // n1 (planned preview): uploaded at level 0, trimmed to Lfit = 1.
        #expect(await rig.cache.entry(files[1])?.pyramid?.uploadedLevels.contains(0) == true)
        #expect(await rig.finest(files[1]) == 1)
        #expect(await rig.state(files[1]) == .preview)
        // n5 (distance 5, planned coarse): trimmed to Lfit + 1 = 2.
        #expect(await rig.finest(files[5]) == 2)
        #expect(await rig.state(files[5]) == .coarse)
        await rig.clear()
    }

    /// An opened photo's full decode runs next to its preview instead of waiting for the preview to be up; a dwelt-on
    /// photo's waits.
    @Test func openedDecodesFullAlongsidePreview() async {
        let rig = Rig()
        let files = fileURLs(5)
        let gate = BlockingGate()
        rig.decoder.gateDecodes(files[0], gate)
        await rig.cache.setFocus(files: files, focus: CacheFocus(count: files.count, current: 0, direction: 1, dwelling: false,
                                                                 needsFull: false, screen: rigScreen, opened: true))
        #expect(await eventually {
            let calls = rig.decoder.calls(files[0])
            return calls.contains(.preview(1)) && calls.contains(.full)
        })
        gate.open()
        #expect(await eventually { await rig.state(files[0]) == .full })
        await rig.clear()
    }

    @Test func dwellingFullWaitsForPreview() async {
        let rig = Rig()
        let files = fileURLs(5)
        let gate = BlockingGate()
        rig.decoder.gateDecodes(files[0], gate)
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { rig.decoder.calls(files[0]).contains(.preview(1)) })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!rig.decoder.calls(files[0]).contains(.full))
        gate.open()
        #expect(await eventually { await rig.state(files[0]) == .full })
        await rig.clear()
    }

    @Test func needsFullSkipsPreview() async {
        let rig = Rig()
        let files = fileURLs(5)
        await rig.focus(files, 0, needsFull: true)
        #expect(await eventually { await rig.state(files[0]) == .full })
        #expect(await rig.settle())
        let calls = rig.decoder.calls(files[0])
        #expect(!calls.contains { if case .preview = $0 { true } else { false } })
        #expect(calls.filter { $0 == .full }.count == 1)
        await rig.clear()
    }

    @Test func staleFileReset() async {
        let rig = Rig()
        let files = fileURLs(5)
        await rig.focus(files, 0)
        #expect(await rig.settle())
        await rig.focus(files, 1)
        #expect(await rig.settle())
        #expect(rig.reader.readCount(files[0]) == 1)   // kept as p1's bytes

        rig.reader.setStamp(files[0], FileStamp(modified: Date(timeIntervalSince1970: 2), size: 2000))
        await rig.focus(files, 0, direction: -1)
        #expect(await eventually { rig.reader.readCount(files[0]) == 2 })
        #expect(await rig.settle())
        #expect(atLeast(.preview, await rig.state(files[0])))
        // The check queues behind the current photo's read, not level with it.
        #expect(!rig.reader.stampPriorities.isEmpty && rig.reader.stampPriorities.allSatisfy { $0 == 1 })
        await rig.clear()
    }

    @Test func failureRetriedWhenCurrentAgain() async {
        let rig = Rig()
        let files = fileURLs(10)
        rig.decoder.failOnce(files[3])
        await rig.focus(files, 3)
        #expect(await eventually { await rig.cache.entry(files[3])?.failure != nil })
        await rig.focus(files, 4)
        #expect(await rig.settle())
        #expect(await rig.cache.entry(files[3])?.failure != nil)   // kept while not current

        await rig.focus(files, 3, direction: -1)
        #expect(await eventually { atLeast(.preview, await rig.state(files[3])) })
        #expect(await rig.cache.entry(files[3])?.failure == nil)
        await rig.clear()
    }

    @Test func tooLargeRefusedBeforeDecode() async {
        let rig = Rig()
        let files = fileURLs(5)
        rig.decoder.setSize(files[0], PixelSize(width: 30000, height: 30000))
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { await rig.cache.entry(files[0])?.failure != nil })
        #expect(await rig.settle())
        let entry = await rig.cache.entry(files[0])
        #expect(entry?.failure?.contains("too large") == true)
        #expect(entry?.info?.pixelSize == PixelSize(width: 30000, height: 30000))
        #expect(rig.decoder.calls(files[0]) == [.probe])
        await rig.clear()
    }

    /// Fix round 1: the priority is read when a job queues for a slot, not when it was launched. A (ex-current,
    /// now p1) finishes its probe after the flip to B; its decode must queue as a neighbour, behind B's.
    @Test func exCurrentDoesNotTakeTheReservedSlot() async {
        let rig = Rig(pool: DecodePool(slots: 2, reserved: 1))
        let files = fileURLs(30)
        let a = files[10], b = files[9], n1 = files[11]
        let probeGate = BlockingGate(), neighbourGate = BlockingGate()
        rig.decoder.gateProbe(a, probeGate)
        rig.decoder.gateDecodes(n1, neighbourGate)   // holds the only shared slot
        await rig.focus(files, 10, dwelling: true)
        #expect(await eventually {
            rig.decoder.calls(a).contains(.probe) && rig.decoder.calls(n1).contains(.preview(1))
        })

        await rig.focus(files, 9, direction: -1)
        probeGate.open()
        #expect(await eventually { atLeast(.preview, await rig.state(b)) })
        #expect(!rig.decoder.calls(a).contains(.preview(1)), "A decoded ahead of the current photo")
        neighbourGate.open()
        #expect(await eventually { atLeast(.preview, await rig.state(a)) })
        #expect(await rig.settle())
        await rig.clear()
    }

    /// Flipping away from a photo whose full decode is running and coming back reuses that decode.
    @Test func flipBackReusesRunningFullDecode() async {
        let rig = Rig()
        let files = fileURLs(10)
        let gate = BlockingGate()
        rig.decoder.gateFull(files[0], gate)
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { rig.decoder.calls(files[0]).contains(.full) })
        await rig.focus(files, 1)                                  // full of 0 no longer planned
        await rig.focus(files, 0, direction: -1, dwelling: true)   // planned again
        gate.open()
        #expect(await eventually { await rig.state(files[0]) == .full })
        #expect(await rig.settle())
        #expect(rig.decoder.calls(files[0]).filter { $0 == .full }.count == 1)
        await rig.clear()
    }

    /// A neighbour whose decode is running when it leaves the plan: the decode finishes and, as it fits under
    /// `cache-memory`, is uploaded and kept (spec §11.1).
    @Test func unplannedResultKeptWhenItFits() async {
        let rig = Rig()
        let files = fileURLs(60)
        rig.distinctWidths(files)
        let gate = BlockingGate()
        rig.decoder.gateDecodes(files[1], gate)
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { rig.decoder.calls(files[1]).contains(.preview(1)) })
        await rig.focus(files, 40)
        gate.open()
        #expect(await rig.settle())
        #expect(await rig.state(files[40]) == .preview)
        #expect(rig.loader.uploadedLevels(width: rig.width(1)) == [1])
        #expect(await rig.state(files[1]) == .preview)
        await rig.clear()
    }

    /// The same, but the cache is full when the decode finishes: the result is dropped, never uploaded.
    @Test func unplannedResultDroppedWhenOverLimit() async {
        let rig = Rig()
        let files = fileURLs(60)
        rig.distinctWidths(files)
        let gate = BlockingGate()
        rig.decoder.gateDecodes(files[1], gate)
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { rig.decoder.calls(files[1]).contains(.preview(1)) })
        await rig.focus(files, 40)
        await rig.setMemory(1)   // only the current photo (exempt) is planned; nothing else fits
        #expect(await eventually { await rig.state(files[40]) == .preview })
        gate.open()
        #expect(await rig.settle())
        #expect(rig.loader.uploadedLevels(width: rig.width(1)).isEmpty)
        #expect(await rig.cache.entry(files[1])?.pyramid == nil)
        await rig.clear()
    }

    /// The plan drops the full resolution while its upload is in flight: the upload is not disturbed and lands;
    /// with room it is kept, and once the limit leaves no room the entry is evicted.
    @Test func planChangeDuringUploadKeptUntilOverLimit() async {
        let rig = Rig()
        let files = fileURLs(10)
        rig.distinctWidths(files)
        let gate = AsyncGate()
        rig.loader.gateNextUpload(width: rig.width(0), level: 0, gate)
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { rig.loader.gatedUploadStarted })
        await rig.focus(files, 1)   // 0 becomes p1: preview only
        gate.open()
        #expect(await rig.settle())
        #expect(rig.loader.uploadedLevels(width: rig.width(0)).contains(0))
        #expect(await rig.finest(files[0]) == 0)   // fits: kept
        await rig.setMemory(1)
        #expect(await rig.settle())
        #expect(await rig.cache.entry(files[0])?.pyramid == nil)
        await rig.clear()
    }

    /// A↔B at full resolution: both stay full (the one left behind is unplanned but fits), so each is decoded once.
    @Test func pingpongKeepsBothFulls() async {
        let rig = Rig()
        let files = fileURLs(10)
        let a = files[4], b = files[5]
        await rig.focus(files, 4, dwelling: true)
        #expect(await eventually { await rig.state(a) == .full })
        #expect(await rig.settle())
        await rig.focus(files, 5, dwelling: true)
        #expect(await eventually { await rig.state(b) == .full })
        #expect(await rig.settle())
        await rig.focus(files, 4, direction: -1, dwelling: true)
        #expect(await rig.state(a) == .full)
        #expect(await rig.settle())
        await rig.focus(files, 5, dwelling: true)
        #expect(await rig.state(b) == .full)
        #expect(await rig.settle())
        #expect(rig.decoder.calls(a).filter { $0 == .full }.count == 1)
        #expect(rig.decoder.calls(b).filter { $0 == .full }.count == 1)
        await rig.clear()
    }

    /// Spec §11.1.7, Anna's case: 14204×10652 photos (Lfit 1 on 6144×3456, 20 previews ≈ 2 GB) at 3 GB with
    /// `cache-full = 1`. Flipping A↔B at 100 % ten times, each lands at full resolution at once: the photo just
    /// left keeps its full resolution ahead of n1's, so neither is decoded twice.
    @Test func pingpongKeepsFullAtAnnaSize() async {
        let size = PixelSize(width: 14204, height: 10652), screen = PixelSize(width: 6144, height: 3456)
        let rig = Rig(size: size)
        let files = fileURLs(44)
        let a = 10, b = 11
        await rig.focus(files, a, needsFull: true, screen: screen)
        await rig.focus(files, a, dwelling: true, needsFull: true, screen: screen)
        #expect(await eventually { await rig.state(files[a]) == .full })
        #expect(await rig.settle())
        var here = a
        for flip in 1...10 {
            let there = here == a ? b : a
            await rig.focus(files, there, direction: there - here, needsFull: true, screen: screen, previous: here)
            if flip > 1 { #expect(await rig.state(files[there]) == .full, "flip \(flip): \(there) lost its full resolution") }
            await rig.focus(files, there, direction: there - here, dwelling: true, needsFull: true, screen: screen,
                            previous: here)
            #expect(await eventually { await rig.state(files[there]) == .full })
            #expect(await rig.settle())
            #expect(await rig.state(files[here]) == .full, "flip \(flip): \(here) lost its full resolution")
            let stats = await rig.cache.stats()
            #expect(stats.usedBytes <= stats.limitBytes + (1 << 30), "used \(stats.usedBytes >> 20) MB")
            here = there
        }
        #expect(rig.decoder.calls(files[a]).filter { $0 == .full }.count == 1)
        #expect(rig.decoder.calls(files[b]).filter { $0 == .full }.count == 1)
        await rig.clear()
    }

    /// Over the limit, unplanned state goes farthest from the current photo first, degrading step by step (§3.3),
    /// and on a tie the photo behind the direction of travel goes first. Levels go before any compressed bytes.
    @Test func evictsFarthestWhenOverLimit() async {
        var limits = CacheLimits.at3G
        limits.previews = 3
        limits.full = 0
        let rig = Rig(limits: limits)
        let files = fileURLs(41)
        await rig.focus(files, 20, dwelling: true)
        #expect(await rig.settle())
        await rig.focus(files, 30, dwelling: true)
        #expect(await rig.settle())
        await rig.focus(files, 25, direction: -1, dwelling: true)   // plans 25, 24, 26; 19…21, 29…31 unplanned but fit
        #expect(await rig.settle())
        for i in [19, 21, 29, 31] { #expect(await rig.state(files[i]) == .preview, "file \(i)") }
        for i in [20, 30] { #expect(await rig.state(files[i]) == .full, "file \(i)") }

        // 31 (distance 6, behind the travel) loses its levels, then 19 (6), then 30 (5, behind) its level 0 and
        // goes down to coarse; their bytes stay.
        let grid = TileGrid(imageSize: rigPhoto)
        let preview = grid.byteCount(levels: 1..<3), coarse = grid.byteCount(levels: 2..<3)
        let free = 2 * preview + grid.byteCount(levels: 0..<1) + (preview - coarse) / 2
        let used = await rig.cache.stats().usedBytes
        await rig.setMemory(used - free)
        #expect(await rig.settle())
        #expect(await rig.cache.entry(files[31])?.state == .bytes)
        #expect(await rig.cache.entry(files[19])?.state == .bytes)
        #expect(await rig.state(files[30]) == .coarse)
        for i in [21, 29, 24, 26] { #expect(await rig.state(files[i]) == .preview, "file \(i)") }
        for i in [20, 25] { #expect(await rig.state(files[i]) == .full, "file \(i)") }
        let stats = await rig.cache.stats()
        #expect(stats.usedBytes <= stats.limitBytes)
        await rig.clear()
    }

    /// The photo on screen keeps its levels whatever the limit, and is evicted once unpinned.
    @Test func pinnedNeverEvicted() async {
        let rig = Rig()
        let files = fileURLs(10)
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { await rig.state(files[0]) == .full })
        #expect(await rig.settle())
        await rig.cache.setPinned(files[0])
        await rig.setMemory(1)
        await rig.focus(files, 5)
        #expect(await rig.settle())
        #expect(await rig.state(files[0]) == .full)
        #expect(await rig.cache.entry(files[1])?.state == nil)   // ex-n1 full: unplanned, evicted
        #expect(await rig.state(files[5]) == .preview)
        await rig.cache.setPinned(nil)
        #expect(await rig.settle())
        #expect(await rig.cache.entry(files[0])?.state == nil)
        await rig.clear()
    }

    /// The pair's other page (spread) is as current as the photo: it reads at once while the user flips (not after the
    /// dwell, as a neighbour), at the front of the read queue, and its busy read reports `.current`.
    @Test func companionReadsAtOnceAsCurrent() async {
        let rig = Rig()
        let files = fileURLs(10)
        let gate = AsyncGate()
        rig.reader.hang(files[1], on: gate)
        await rig.cache.setFocus(files: files, focus: CacheFocus(count: files.count, current: 0, direction: 1,
                                                                 dwelling: false, needsFull: false, screen: rigScreen,
                                                                 companion: 1, step: 2))
        #expect(await eventually { rig.reader.readCount(files[1]) == 1 })
        #expect(rig.reader.priorities(files[1]) == [0])
        #expect(await rig.cache.isCurrent(files[1]))
        #expect(await rig.cache.currentActivity() == .current)
        #expect(rig.reader.readCount(files[2]) == 0)   // a neighbour still waits for the dwell
        gate.open()
        #expect(await eventually { await rig.state(files[1]) == .preview })
        await rig.clear()
    }

    /// The second page of a pair on screen (spread) is pinned like the first: it keeps its levels whatever the limit.
    @Test func pinnedCompanionNeverEvicted() async {
        let rig = Rig()
        let files = fileURLs(10)
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { await rig.state(files[1]) == .full })
        #expect(await rig.settle())
        await rig.cache.setPinned(files[0], companion: files[1])
        await rig.setMemory(1)
        await rig.focus(files, 5)
        #expect(await rig.settle())
        #expect(await rig.state(files[0]) == .full)
        #expect(await rig.state(files[1]) == .full)
        await rig.cache.setPinned(files[0])
        #expect(await rig.settle())
        #expect(await rig.cache.entry(files[1])?.state == nil)
        await rig.clear()
    }

    /// A pin outlives a playlist change (another folder opened: the old photo stays on screen until the new one
    /// shows); once the viewer moves it, the old folder's photo goes first under the limit.
    @Test func pinMovesOnlyWhenTheViewerMovesIt() async {
        let rig = Rig()
        let files = fileURLs(10)
        await rig.focus(files, 0)
        #expect(await rig.settle())
        await rig.cache.setPinned(files[0])
        await rig.setMemory(1)
        let other = (100..<110).map(fileURL)
        await rig.focus(other, 0)
        #expect(await rig.settle())
        #expect(atLeast(.preview, await rig.state(files[0])))
        await rig.cache.setPinned(other[0])
        #expect(await rig.settle())
        await rig.focus(other, 1)
        #expect(await rig.settle())
        #expect(await rig.cache.entry(files[0]) == nil)
        await rig.clear()
    }

    /// Opening a file of the folder already shown sends a one-file playlist until the listing arrives: the
    /// neighbours it briefly leaves out keep their bytes and levels, so nothing is read again when they come back.
    @Test func openInSameFolderKeepsTheCache() async {
        let rig = Rig()
        let files = fileURLs(20)
        await rig.focus(files, 5, dwelling: true)
        #expect(await rig.settle())
        let held = (0..<20).filter { rig.reader.readCount(files[$0]) == 1 }
        #expect(held.count >= 6)
        await rig.focus([files[8]], 0)
        #expect(await rig.settle())
        await rig.focus(files, 8, dwelling: true)
        #expect(await rig.settle())
        for i in held where i != 8 {
            #expect(rig.reader.readCount(files[i]) == 1, "file \(i) read again")
        }
        await rig.clear()
    }

    /// Switching to a sibling folder and back (`[` then `]`) finds the folder just left as it was while memory
    /// allows: its photos are kept, not read or decoded again.
    @Test func folderSwitchKeepsTheFolderLeft() async {
        let rig = Rig()
        let a = fileURLs(20)
        let b = (0..<20).map { URL(fileURLWithPath: "/fake/b/\($0).jpg") }
        await rig.focus(a, 5, dwelling: true)
        #expect(await rig.settle())
        let held = (0..<20).filter { rig.reader.readCount(a[$0]) == 1 }
        let states = await (0..<20).asyncMap { await rig.state(a[$0]) }
        await rig.focus(b, 0, dwelling: true)
        #expect(await rig.settle())
        for i in held { #expect(await rig.state(a[i]) == states[i], "file \(i) degraded while away") }
        await rig.focus(a, 5, dwelling: true)
        #expect(await rig.settle())
        for i in held { #expect(rig.reader.readCount(a[i]) == 1, "file \(i) read again") }
        await rig.clear()
    }

    /// Out of the playlist, entries go only through the memory limit, farthest (infinitely far) first.
    @Test func entriesLeftBehindGoFirstUnderTheLimit() async {
        let rig = Rig()
        let a = fileURLs(20)
        let b = (0..<20).map { URL(fileURLWithPath: "/fake/b/\($0).jpg") }
        await rig.focus(a, 5, dwelling: true)
        #expect(await rig.settle())
        await rig.focus(b, 0, dwelling: true)
        #expect(await rig.settle())
        var bUsed = 0
        let used = await rig.cache.stats().usedBytes
        bUsed = await rig.pyramidBytes(b)
        // Room for b's pyramids (and its few bytes of data) but none of a's.
        await rig.setMemory(bUsed + (used - bUsed - (await rig.pyramidBytes(a))) + 64)
        #expect(await rig.settle())
        for url in a { #expect(await rig.cache.entry(url)?.pyramid == nil, "\(url.lastPathComponent) kept") }
        #expect(await rig.pyramidBytes(b) == bUsed)
        await rig.clear()
    }

    /// `usedBytes` counts every resident level (the pinned photo's too) plus the levels an upload is building.
    @Test func usedBytesIncludesPinnedAndInFlight() async {
        var limits = CacheLimits.at3G
        limits.full = 0   // no neighbour full upload in flight next to the gated one
        let rig = Rig(limits: limits)
        let files = fileURLs(10)
        rig.distinctWidths(files)
        let tolerance = 1024   // the fake file data: a few bytes per file
        let gate = AsyncGate()
        rig.loader.gateNextUpload(width: rig.width(0), level: 0, gate)
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { rig.loader.gatedUploadStarted })
        let upload = TileGrid(imageSize: PixelSize(width: rig.width(0), height: 1500)).byteCount(levels: 0..<3)
        var used = 0, resident = 0
        // The neighbours' previews (read once dwelling) may still be uploading next to the gated full; once they are
        // done, only the gated upload is in flight.
        #expect(await eventually {
            used = await rig.cache.stats().usedBytes
            resident = await rig.pyramidBytes(files)
            return abs(used - (resident + upload)) < tolerance
        }, "used \(used), resident \(resident) + upload \(upload)")
        gate.open()
        #expect(await rig.settle())

        await rig.cache.setPinned(files[0])
        await rig.setMemory(1)
        await rig.focus(files, 5)
        #expect(await rig.settle())
        #expect(await rig.state(files[0]) == .full)
        used = await rig.cache.stats().usedBytes
        resident = await rig.pyramidBytes(files)
        #expect(abs(used - resident) < tolerance)
        #expect(resident >= TileGrid(imageSize: PixelSize(width: rig.width(0), height: 1500)).byteCount(levels: 0..<3))
        await rig.cache.setPinned(nil)
        await rig.clear()
    }

    /// Progressive JPEG full decodes (≈ 1.5 GB of libjpeg buffers each at 147 MP) run at most two at a time, one
    /// slot reserved for the current photo (spec §11.1.6): with the neighbours' (n1 = 6, p1 = 4 with
    /// `cache-full = 2`) held, only one of them runs, and the current photo's full still starts and finishes.
    @Test func progressiveFullDecodesLimited() async {
        var limits = CacheLimits.at3G
        limits.full = 2
        let rig = Rig(limits: limits)
        let files = fileURLs(10)
        let neighbours = BlockingGate(), current = BlockingGate()
        for url in files { rig.decoder.setProgressive(url) }
        rig.decoder.gateFull(files[4], neighbours)
        rig.decoder.gateFull(files[6], neighbours)
        rig.decoder.gateDecodes(files[5], current)   // the current photo comes after a neighbour holds the gate
        await rig.focus(files, 5, dwelling: true)
        #expect(await eventually { rig.decoder.calls(files[4]).contains(.full) || rig.decoder.calls(files[6]).contains(.full) })
        current.open()
        #expect(await eventually { await rig.state(files[5]) == .full }, "the current full waited for a neighbour's")
        try? await Task.sleep(for: .milliseconds(50))   // every chance for the second neighbour to start
        let started = [4, 6].filter { rig.decoder.calls(files[$0]).contains(.full) }
        #expect(started.count == 1, "neighbour fulls running together: \(started)")
        neighbours.open()
        #expect(await eventually {
            let four = await rig.state(files[4]), six = await rig.state(files[6])
            return four == .full && six == .full
        })
        #expect(await rig.settle())
        #expect(rig.decoder.peakConcurrentFulls <= 2, "peak \(rig.decoder.peakConcurrentFulls)")
        await rig.clear()
    }

    /// Previews that decode the whole image (a JXL without a DC image, ~590 MB of buffer at 147 MP) share the gate of
    /// progressive full decodes: with every decode held, two start, not the pool's three.
    @Test func fullDecodePreviewsLimited() async {
        let rig = Rig()
        let files = fileURLs(10)
        let gate = BlockingGate()
        for url in files { rig.decoder.setPreviewNeedsFull(url) }
        rig.decoder.gateAllDecodes(gate)
        await rig.focus(files, 5, dwelling: true)
        #expect(await eventually { rig.decoder.calls.filter { if case .preview = $0.kind { true } else { false } }.count >= 2 })
        try? await Task.sleep(for: .milliseconds(50))   // every chance for a third to start
        let started = rig.decoder.calls.filter { if case .preview = $0.kind { true } else { false } }.count
        #expect(started == 2, "full-decode previews started together: \(started)")
        rig.decoder.gateAllDecodes(nil)
        gate.open()
        #expect(await rig.settle())
        #expect(rig.decoder.peakConcurrentFulls <= 2, "peak \(rig.decoder.peakConcurrentFulls)")
        await rig.clear()
    }

    /// One notification per stored stage: read, probe, preview decoded, preview uploaded, full decoded, full uploaded.
    @Test func onUpdatePerStoredStage() async {
        let rig = Rig()
        let files = fileURLs(1)
        let log = UpdateLog()
        await rig.cache.setOnUpdate { log.add($0) }
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { await rig.state(files[0]) == .full })
        #expect(await rig.settle())
        #expect(log.urls == Array(repeating: files[0], count: 6))
        await rig.clear()
    }

    // MARK: Reads by priority (Task 11e)

    /// One read slot, held by the current photo's read, with its neighbours' reads queued behind it. Focus jumps to
    /// one of them: its queued read is moved to priority 0 and is the next to get the slot (FIFO would run 1…4 first).
    @Test func currentReadJumpsTheQueue() async {
        let queue = QueueReader(slots: 1)
        let rig = Rig(queueReader: queue)
        let files = fileURLs(20)
        let log = TraceEvents()
        await rig.cache.setTrace { log.add($0) }
        queue.hold(files[0])
        // The current read takes the slot first; only then does dwelling queue the neighbours behind it (on a slow
        // machine their reads could otherwise reach the reader first and run through the free slot).
        await rig.focus(files, 0)
        #expect(await eventually { queue.started == [files[0]] })
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { queue.queuedCount >= 6 })
        #expect(queue.queuedPriority(files[5]).map { $0 > 0 } == true)
        await rig.focus(files, 5)
        #expect(await eventually { queue.queuedPriority(files[5]) == 0 })
        #expect(log.events.contains { $0.url == files[5] && $0.kind == .readReprioritized && $0.priority == 0 })
        queue.release(files[0])
        #expect(await eventually { queue.started.count >= 2 })
        #expect(queue.started.prefix(2) == [files[0], files[5]], "\(queue.started.map(\.lastPathComponent))")
        #expect(await eventually { atLeast(.preview, await rig.state(files[5])) })
        await rig.clear()
    }

    /// A read reprioritised after the cache asked for it but before it reached the reader's queue (the hop off the
    /// actor) is still queued at its new rank: the photo landed on goes next, not after the neighbours ahead of it.
    @Test func reprioritizedBeforeSubmitKeepsNewRank() async {
        let queue = QueueReader(slots: 1)
        let rig = Rig(queueReader: queue)
        let files = fileURLs(20)
        queue.hold(files[0])
        let gap = queue.delaySubmit(files[5])
        // The current read first, then the neighbours (as in currentReadJumpsTheQueue): asked for together, a
        // neighbour's read could reach the free slot ahead of it.
        await rig.focus(files, 0)
        #expect(await eventually { queue.started == [files[0]] })
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { queue.queuedCount >= 5 && queue.hasArrived(files[5]) })
        await rig.focus(files, 5)
        gap.open()
        #expect(await eventually { queue.queuedPriority(files[5]) != nil })
        queue.release(files[0])
        #expect(await eventually { queue.started.count >= 2 })
        #expect(queue.started.prefix(2) == [files[0], files[5]], "\(queue.started.map(\.lastPathComponent))")
        await rig.clear()
    }

    /// Flipping without dwelling reads only the photos landed on; the neighbours' reads start once the user stays.
    @Test func noNeighbourReadsWhileFlipping() async {
        let rig = Rig()
        let files = fileURLs(20)
        for i in 0..<5 {
            await rig.focus(files, i)
            #expect(await eventually { atLeast(.preview, await rig.state(files[i])) })
        }
        #expect(await rig.settle())
        #expect(rig.reader.readOrder == Array(files[0..<5]), "\(rig.reader.readOrder.map(\.lastPathComponent))")
        #expect(rig.reader.priorities(files[4]) == [0])
        await rig.focus(files, 4, dwelling: true)
        #expect(await eventually { rig.reader.readCount(files[5]) == 1 && rig.reader.readCount(files[6]) == 1 })
        #expect(rig.reader.priorities(files[5]).allSatisfy { $0 > 0 })
        #expect(await rig.settle())
        await rig.clear()
    }

    // MARK: Activity and cached bytes (Task 7)

    /// The current photo's read gated: `.current` (after the `.idle` the handler gets on registration); once the
    /// read and the jobs it feeds are done, `.idle`.
    @Test func activityGoesCurrentThenIdle() async {
        let rig = Rig()
        let files = fileURLs(3)
        let log = ActivityLog()
        await rig.cache.setOnActivity { log.add($0) }
        let gate = AsyncGate()
        rig.reader.hang(files[0], on: gate)
        await rig.focus(files, 0)
        #expect(await eventually { log.values == [.idle, .current] })
        gate.open()
        #expect(await rig.settle())
        #expect(log.values == [.idle, .current, .idle])
        await rig.clear()
    }

    /// The current photo resident and the rest of its work done; a neighbour's gated read is `.neighbours`.
    @Test func activityNeighboursWhileOnlyNeighboursWork() async {
        let rig = Rig()
        let files = fileURLs(3)
        let gate = AsyncGate()
        rig.reader.hang(files[1], on: gate)
        await rig.focus(files, 0, needsFull: true)
        #expect(await eventually { atLeast(.full, await rig.state(files[0])) })
        #expect(await rig.settle())
        let log = ActivityLog()
        await rig.cache.setOnActivity { log.add($0) }
        await rig.focus(files, 0, dwelling: true, needsFull: true)
        #expect(await eventually { rig.reader.readCount(files[1]) == 1 })
        #expect(await eventually { log.values.last == .neighbours })
        gate.open()
        #expect(await rig.settle())
        #expect(log.values == [.idle, .neighbours, .idle])
        await rig.clear()
    }

    /// A replan that changes nothing reports nothing.
    @Test func activityDeduplicated() async {
        let rig = Rig()
        let files = fileURLs(3)
        await rig.focus(files, 0)
        #expect(await rig.settle())
        let log = ActivityLog()
        await rig.cache.setOnActivity { log.add($0) }
        #expect(log.values == [.idle])
        await rig.focus(files, 0)
        await rig.focus(files, 0)
        await rig.cache.setLimits(await rig.cache.limits)
        #expect(log.values == [.idle])
        await rig.clear()
    }

    @Test func cachedBytesReturnsResidentData() async {
        let rig = Rig()
        let files = fileURLs(2)
        let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1), size: 1000)   // FakeReader's default
        #expect(await rig.cache.cachedBytes(files[0], stamp: stamp) == nil)
        await rig.focus(files, 0)
        #expect(await eventually { await rig.cache.cachedBytes(files[0], stamp: stamp) != nil })
        #expect(await rig.cache.cachedBytes(files[0], stamp: stamp) == Data(files[0].lastPathComponent.utf8))
        #expect(await rig.cache.cachedBytes(files[1], stamp: stamp) == nil)
        #expect(await rig.settle())
        await rig.clear()
    }

    /// A file rewritten since its bytes were read (a new listing stamp): the resident bytes are its old content,
    /// so they are not handed out, and a thumbnail made from them is not saved under the new stamp.
    @Test func cachedBytesOfAnotherStampAreWithheld() async {
        let rig = Rig()
        let files = fileURLs(2)
        let old = FileStamp(modified: Date(timeIntervalSince1970: 1), size: 1000)
        let resaved = FileStamp(modified: Date(timeIntervalSince1970: 2), size: 1200)
        await rig.focus(files, 0)
        #expect(await eventually { await rig.cache.cachedBytes(files[0], stamp: old) != nil })
        rig.reader.setStamp(files[0], resaved)
        #expect(await rig.cache.cachedBytes(files[0], stamp: resaved) == nil)
        #expect(await rig.cache.cachedBytes(files[0], stamp: FileStamp(modified: old.modified, size: 1200)) == nil)
        #expect(await rig.cache.cachedBytes(files[0], stamp: FileStamp(modified: resaved.modified, size: 1000)) == nil)
        #expect(await rig.settle())
        await rig.clear()
    }

    /// Over the limit, the walk drops pyramid levels of every candidate before any candidate's compressed bytes:
    /// bytes cost an SMB re-read to get back, a level only a decode. 2 is farthest, so the old order (2's levels,
    /// then 2's bytes) would have left 1's preview alone.
    @Test func bytesOutliveLevelsUnderPressure() async {
        var limits = CacheLimits.at3G
        limits.full = 0
        limits.previews = 3
        limits.files = 2
        let rig = Rig(limits: limits)
        let files = fileURLs(10)
        let grid = TileGrid(imageSize: rigPhoto)
        let levelBytes = grid.byteCount(levels: 1..<grid.levelCount)
        for i in [1, 2] { rig.reader.pad(files[i], 10 * levelBytes) }
        await rig.focus(files, 0, dwelling: true)
        #expect(await rig.settle())
        for i in [1, 2] { #expect(await rig.state(files[i]) == .preview, "file \(i)") }
        #expect(await rig.cache.stats().bytesCount == 3)
        // Nothing of 1 and 2 is planned any more, but all of it fits.
        var unplanned = limits
        unplanned.files = 0
        unplanned.previews = 1
        await rig.cache.setLimits(unplanned)
        #expect(await rig.settle())
        #expect(await rig.state(files[2]) == .preview)
        let used = await rig.cache.stats().usedBytes
        await rig.setMemory(used - levelBytes - levelBytes / 2)
        #expect(await rig.settle())
        #expect(await rig.state(files[2]) == .bytes)
        #expect(await rig.state(files[1]).map { $0 < .preview } ?? true)
        await rig.clear()
    }

    /// Nine photos resident (a preview each, the current one full, all planned), `cache-memory` 1.5x what they hold, the current one pinned.
    private func pressureRig(restoreAfter: Duration = .seconds(30)) async -> (rig: Rig, files: [URL], memory: Int)? {
        var limits = CacheLimits.at3G
        limits.full = 0
        limits.previews = 9
        limits.files = 0
        limits.farPreviewsCoarse = false   // equal costs: a smaller limit cannot make a far coarse preview fit instead
        let rig = Rig(limits: limits, pressureRestoreAfter: restoreAfter)
        let files = fileURLs(20)
        await rig.focus(files, 10, dwelling: true)
        await rig.cache.setPinned(files[10])
        guard await rig.settle() else { return nil }
        let used = await rig.cache.stats().usedBytes
        let memory = used * 3 / 2
        await rig.setMemory(memory)
        guard await rig.settle() else { return nil }
        return (rig, files, memory)
    }

    /// Under a warning the effective limit is cache-memory / 2: the cache evicts down to it (farthest first, the
    /// pinned photo untouched) and does not re-plan what it just evicted. `.normal` restores the limit, and the plan
    /// made against it wants the neighbours back, so they are loaded again then and not before.
    @Test func pressureHalvesThenRestores() async {
        guard let (rig, files, memory) = await pressureRig() else { Issue.record("fill timed out"); return }
        let before = await rig.cache.stats()
        #expect(before.effectiveLimitBytes == memory)
        #expect(before.usedBytes > memory / 2, "fixture: the pressure limit must bite")
        let calls = rig.decoder.calls.count
        let pinnedBytes = await rig.pyramidBytes([files[10]])

        await rig.cache.setMemoryPressure(.warning)
        #expect(await rig.settle())
        var stats = await rig.cache.stats()
        #expect(stats.limitBytes == memory)
        #expect(stats.effectiveLimitBytes == memory / 2)
        #expect(stats.usedBytes <= memory / 2, "used \(stats.usedBytes) over \(memory / 2)")
        #expect(await rig.state(files[10]) == .full)
        #expect(await rig.pyramidBytes([files[10]]) == pinnedBytes)
        #expect(stats.previewCount < before.previewCount)
        // Farthest first: whatever kept its levels is no farther than anything that lost them.
        var keptDistances: [Int] = [], lostDistances: [Int] = []
        for i in files.indices {
            if atLeast(.coarse, await rig.state(files[i])) { keptDistances.append(abs(i - 10)) } else { lostDistances.append(abs(i - 10)) }
        }
        #expect(keptDistances.count < 9, "something must have been evicted")
        #expect((keptDistances.max() ?? 0) <= (lostDistances.min() ?? 0), "kept \(keptDistances) lost \(lostDistances)")
        // Nothing was re-decoded to refill what was just evicted.
        #expect(rig.decoder.calls.count == calls, "re-decoded under pressure")

        await rig.cache.setMemoryPressure(.normal)
        #expect(await rig.settle())
        stats = await rig.cache.stats()
        #expect(stats.effectiveLimitBytes == memory)
        #expect(stats.previewCount == before.previewCount, "the plan wants the neighbours back")
        #expect(rig.decoder.calls.count > calls)
        await rig.clear()
    }

    @Test func criticalQuarters() async {
        guard let (rig, files, memory) = await pressureRig() else { Issue.record("fill timed out"); return }
        await rig.cache.setMemoryPressure(.critical)
        #expect(await rig.settle())
        let stats = await rig.cache.stats()
        #expect(stats.effectiveLimitBytes == memory / 4)
        #expect(stats.usedBytes <= memory / 4, "used \(stats.usedBytes) over \(memory / 4)")
        #expect(await rig.state(files[10]) == .full)
        // Warning after critical: back up to a half (the limit follows the latest level, not the worst).
        await rig.cache.setMemoryPressure(.warning)
        #expect(await rig.cache.stats().effectiveLimitBytes == memory / 2)
        await rig.clear()
    }

    /// The pinned photo is never evicted, however low the limit goes.
    @Test func pressureNeverEvictsPinned() async {
        guard let (rig, files, _) = await pressureRig() else { Issue.record("fill timed out"); return }
        await rig.setMemory(1)
        await rig.cache.setMemoryPressure(.critical)
        #expect(await rig.settle())
        #expect(await rig.state(files[10]) == .full)
        await rig.clear()
    }

    /// No `.normal` event: the limit returns on its own once the interval after the last pressure event passes,
    /// and a newer event postpones it. Seconds, not milliseconds: a loaded CI runner oversleeps by hundreds of ms.
    @Test func pressureRestoresByItself() async {
        guard let (rig, _, memory) = await pressureRig(restoreAfter: .seconds(2)) else {
            Issue.record("fill timed out"); return
        }
        await rig.cache.setMemoryPressure(.warning)
        try? await Task.sleep(for: .milliseconds(1300))
        await rig.cache.setMemoryPressure(.critical)   // restarts the clock
        try? await Task.sleep(for: .milliseconds(1300))
        #expect(await rig.cache.stats().effectiveLimitBytes == memory / 4, "restored too early")
        #expect(await eventually { await rig.cache.stats().effectiveLimitBytes == memory })
        await rig.clear()
    }

    /// An explicit `.normal` cancels the pending restore, so a later pressure level is not undone by a stale timer.
    @Test func normalCancelsPendingRestore() async {
        guard let (rig, _, memory) = await pressureRig(restoreAfter: .seconds(2)) else {
            Issue.record("fill timed out"); return
        }
        await rig.cache.setMemoryPressure(.warning)
        await rig.cache.setMemoryPressure(.normal)
        try? await Task.sleep(for: .milliseconds(1000))
        await rig.cache.setMemoryPressure(.warning)
        try? await Task.sleep(for: .milliseconds(1300))   // the first timer would have fired by now (2 s in), the second not yet
        #expect(await rig.cache.stats().effectiveLimitBytes == memory / 2)
        await rig.clear()
    }

    /// A restore timer that already woke when a fresh event cancelled it (its restore queued on the actor behind
    /// that event) must not undo the fresh event: warning, warning, then the first timer's late restore.
    @Test func lateTimerOfAnEarlierEventDoesNotRestore() async {
        guard let (rig, _, memory) = await pressureRig() else { Issue.record("fill timed out"); return }
        await rig.cache.setMemoryPressure(.warning)
        let first = await rig.cache.pressureGeneration
        await rig.cache.setMemoryPressure(.warning)
        await rig.cache.pressureTimerFired(generation: first)
        #expect(await rig.cache.stats().effectiveLimitBytes == memory / 2)
        // The latest event's own timer still restores.
        await rig.cache.pressureTimerFired(generation: await rig.cache.pressureGeneration)
        #expect(await rig.cache.stats().effectiveLimitBytes == memory)
        await rig.clear()
    }

    // MARK: Two memory tiers (a discrete card)

    /// The stamp `FakeReader` gives every file it reads.
    private let fakeStamp = FileStamp(modified: Date(timeIntervalSince1970: 1), size: 1000)

    /// Stepping through four photos at 100 % with a graphics tier of two full pyramids: the uploads make room by
    /// evicting the photos left behind down to the tier, and leave their compressed files alone, which the system
    /// tier has room for (each as heavy as a full pyramid, so evicting them would look like it helps).
    @Test func uploadsEvictPyramidsNotBytes() async {
        let full = TileGrid(imageSize: rigPhoto).byteCount(levels: 0..<TileGrid(imageSize: rigPhoto).levelCount)
        var limits = CacheLimits.at3G
        limits.graphicsMemory = 2 * full
        limits.files = 0   // the files of the photos left behind are not planned: kept only while they fit
        let rig = Rig(limits: limits)
        let files = fileURLs(10)
        for url in files { rig.reader.pad(url, full) }
        for i in 0..<4 {
            await rig.focus(files, i, needsFull: true, previous: i > 0 ? i - 1 : nil)
            await rig.focus(files, i, dwelling: true, needsFull: true, previous: i > 0 ? i - 1 : nil)
            #expect(await eventually { await rig.state(files[i]) == .full }, "photo \(i)")
            #expect(await rig.settle())
        }
        let graphics = await rig.cache.usedGraphicsBytes()
        #expect(graphics <= 2 * full, "graphics \(graphics) over \(2 * full)")
        #expect(await rig.pyramidBytes(Array(files[0..<3])) < 3 * full, "fixture: the photos left behind lost levels")
        for i in 0..<3 {
            #expect(await rig.cache.cachedBytes(files[i], stamp: fakeStamp) != nil, "file \(i) lost its bytes")
        }
        let stats = await rig.cache.stats()
        #expect(stats.graphicsLimitBytes == 2 * full)
        #expect(stats.graphicsUsedBytes == graphics)
        #expect(stats.usedBytes == (await rig.cache.usedSystemBytes()))
        #expect(stats.usedBytes >= 3 * full)
        await rig.clear()
    }

    /// Memory pressure divides the system tier only: the compressed files go down to half of it, the pyramids (in
    /// graphics memory, which pressure does not free) all stay, and nothing is decoded again. Both tiers are set
    /// 1.5x what they hold, so halving either would evict from it.
    @Test func pressureLeavesTheGraphicsTier() async {
        var limits = CacheLimits.at3G
        limits.full = 0
        limits.previews = 9
        limits.files = 0
        limits.farPreviewsCoarse = false
        limits.graphicsMemory = 1 << 30
        let rig = Rig(limits: limits)
        let files = fileURLs(20)
        let preview = TileGrid(imageSize: rigPhoto).byteCount(levels: 1..<TileGrid(imageSize: rigPhoto).levelCount)
        for url in files { rig.reader.pad(url, preview) }
        await rig.focus(files, 10, dwelling: true)
        await rig.cache.setPinned(files[10])
        #expect(await rig.settle())
        let memory = await rig.cache.usedSystemBytes() * 3 / 2
        let graphicsLimit = await rig.cache.usedGraphicsBytes() * 3 / 2
        limits.memory = memory
        limits.graphicsMemory = graphicsLimit
        await rig.cache.setLimits(limits)
        #expect(await rig.settle())
        let before = await rig.cache.stats()
        let graphics = await rig.cache.usedGraphicsBytes()
        let pyramids = await rig.pyramidBytes(files)
        #expect(before.usedBytes > memory / 2, "fixture: the pressure limit must bite")
        #expect(graphics > graphicsLimit / 2, "fixture: halving the graphics tier would bite")
        let calls = rig.decoder.calls.count

        await rig.cache.setMemoryPressure(.warning)
        #expect(await rig.settle())
        let stats = await rig.cache.stats()
        #expect(stats.limitBytes == memory)
        #expect(stats.effectiveLimitBytes == memory / 2)
        #expect(stats.usedBytes <= memory / 2, "system \(stats.usedBytes) over \(memory / 2)")
        #expect(stats.graphicsLimitBytes == graphicsLimit)
        #expect(await rig.cache.usedGraphicsBytes() == graphics)
        #expect(await rig.pyramidBytes(files) == pyramids, "pyramids evicted under pressure")
        #expect(stats.previewCount == before.previewCount)
        #expect(rig.decoder.calls.count == calls, "re-decoded under pressure")
        await rig.clear()
    }

    // MARK: Ready decodes (a discrete card)

    /// 2048×1536: rows of 8192 bytes, so a full decode (12 582 912 bytes) fills whole 16 KiB pages and its buffer is
    /// exactly what the plan charges for it.
    private let readyPhoto = PixelSize(width: 2048, height: 1536)
    private var readyBytes: Int { 2048 * 4 * 1536 }

    /// Forward five photos at 100 % with a dwell on each, on a card whose graphics tier holds two full pyramids, then
    /// back four: each photo's full decode was kept ready in system memory, so a photo whose levels the card gave up
    /// comes back by an upload of that decode, never by decoding the file again.
    @Test func stepBackUploadsTheReadyDecode() async {
        let rig = Rig(limits: CacheLimits.at3G)
        let files = fileURLs(10)
        rig.distinctWidths(files)
        let widest = TileGrid(imageSize: PixelSize(width: rig.width(9), height: 1500))
        var limits = CacheLimits.at3G
        limits.graphicsMemory = 2 * widest.byteCount(levels: 0..<widest.levelCount)
        await rig.cache.setLimits(limits)
        for i in 0..<5 {
            await rig.focus(files, i, needsFull: true, previous: i > 0 ? i - 1 : nil)
            await rig.focus(files, i, dwelling: true, needsFull: true, previous: i > 0 ? i - 1 : nil)
            #expect(await eventually { await rig.state(files[i]) == .full }, "photo \(i)")
            #expect(await rig.settle())
        }
        #expect(await rig.cache.stats().readyCount >= 5)
        for i in [3, 2, 1, 0] {
            await rig.focus(files, i, direction: -1, needsFull: true, previous: i + 1)
            await rig.focus(files, i, direction: -1, dwelling: true, needsFull: true, previous: i + 1)
            #expect(await eventually { await rig.state(files[i]) == .full }, "photo \(i)")
            #expect(await rig.settle())
        }
        for i in 0..<5 {
            #expect(rig.decoder.calls(files[i]).filter { $0 == .full }.count == 1, "photo \(i) decoded again")
        }
        let reuploaded = (0..<3).filter { i in
            rig.loader.uploadedLevels(width: rig.width(i)).filter { $0 == 0 }.count >= 2
        }
        #expect(!reuploaded.isEmpty, "fixture: the card gave up some photo's full resolution")
        await rig.clear()
    }

    /// The photo the user steps onto has its ready decode running: its full job waits for that decode and uploads
    /// it rather than decoding the file a second time.
    @Test func fullJobWaitsForReadyInFlight() async {
        var limits = CacheLimits.at3G
        limits.graphicsMemory = 1 << 30
        limits.full = 0   // no neighbour's full resolution: n2's full decode can only be its ready one
        let rig = Rig(limits: limits)
        let files = fileURLs(10)
        let log = TraceEvents()
        await rig.cache.setTrace { log.add($0) }
        let gate = BlockingGate()
        rig.decoder.gateFull(files[2], gate)
        await rig.focus(files, 0, dwelling: true, needsFull: true)
        #expect(await eventually { rig.decoder.calls(files[2]).contains(.full) })
        await rig.focus(files, 2, needsFull: true, previous: 0)
        #expect(await eventually { log.events.contains { $0.url == files[2] && $0.kind == .readyAwait } })
        gate.open()
        #expect(await eventually { await rig.state(files[2]) == .full })
        #expect(await rig.settle())
        #expect(rig.decoder.calls(files[2]).filter { $0 == .full }.count == 1)
        await rig.clear()
    }

    /// A ready job that ran its own probe and then queues for the single ready slot (behind n1's ready decode, held)
    /// is only waiting: stepping onto its photo, the full job gives it up and decodes at once rather than wait for a
    /// decode that has not begun. One decode of that photo in all.
    @Test func queuedReadyDecodeIsAbandonedNotAwaited() async {
        var limits = CacheLimits.at3G
        limits.graphicsMemory = 1 << 30
        limits.full = 0
        limits.previews = 2   // the current photo and n1: n2 has no preview job, so its ready job probes it
        let rig = Rig(limits: limits)
        let files = fileURLs(10)
        let log = TraceEvents()
        await rig.cache.setTrace { log.add($0) }
        let held = BlockingGate()
        rig.decoder.gateFullCalls(files[1], [held])
        await rig.focus(files, 0, dwelling: true, needsFull: true)
        #expect(await eventually { rig.decoder.calls(files[1]).contains(.full) })
        #expect(await eventually {
            log.events.contains { $0.url == files[2] && $0.kind == .decodeWait && $0.goal == .ready }
        })
        #expect(log.events.contains { $0.url == files[2] && $0.kind == .probeWait && $0.goal == .ready },
                "fixture: the ready job probed n2 itself")
        await rig.focus(files, 2, needsFull: true, previous: 0)
        #expect(await eventually { await rig.state(files[2]) == .full }, "sharp while n1's ready decode is held")
        #expect(!log.events.contains { $0.url == files[2] && $0.kind == .readyAwait })
        #expect(log.events.contains { $0.url == files[2] && $0.kind == .jobCancelled && $0.goal == .ready })
        #expect(log.events.contains { $0.url == files[2] && $0.kind == .decodeDone && $0.goal == .full })
        #expect(!log.events.contains { $0.url == files[1] && $0.kind == .decodeDone && $0.goal == .ready },
                "fixture: n1's ready decode still held")
        held.open()
        #expect(await rig.settle())
        #expect(rig.decoder.calls(files[2]).filter { $0 == .full }.count == 1)
        await rig.clear()
    }

    /// Memory pressure takes the ready decodes first: at a quarter of `cache-memory` the files all still fit and
    /// stay, the current photo's included, and no ready decode does, so none is left (not even the current photo's:
    /// the screen never draws from it). Three of the files are held but no longer planned (`cache-files` lowered to 1
    /// beforehand): taking files first would drop them before the ready decodes and still have to take those.
    @Test func pressureDropsReadyBeforeBytes() async {
        var limits = CacheLimits.at3G
        limits.graphicsMemory = 1 << 30
        limits.full = 0
        let file = 1_000_000
        limits.memory = 4 * (5 * file + 4_000_000)   // normal: the files and two ready decodes; critical: the files
        let rig = Rig(size: readyPhoto, limits: limits)
        rig.decoder.fullSizedBuffers = true
        let files = fileURLs(5)
        for url in files { rig.reader.pad(url, file) }
        await rig.focus(files, 2, dwelling: true, needsFull: true)
        #expect(await eventually { await rig.cache.stats().readyCount == 2 })
        #expect(await rig.settle())
        limits.files = 1   // only n1's file stays planned besides the current one: 0, 1 and 4 are held, unplanned
        await rig.cache.setLimits(limits)
        #expect(await rig.settle())
        #expect(await rig.cache.stats().bytesCount == 5)
        #expect(await rig.cache.stats().readyCount == 2)
        #expect(await rig.cache.inspect([files[0], files[1], files[4]]).allSatisfy { $0?.planned[.bytes] == nil })
        let calls = rig.decoder.calls.count

        await rig.cache.setMemoryPressure(.critical)
        #expect(await rig.settle())
        let stats = await rig.cache.stats()
        #expect(stats.readyCount == 0)
        #expect(stats.bytesCount == 5)
        #expect(await rig.cache.cachedBytes(files[2], stamp: fakeStamp) != nil)
        #expect(stats.usedBytes <= limits.memory / 4, "system \(stats.usedBytes) over \(limits.memory / 4)")
        #expect(await rig.state(files[2]) == .full)
        #expect(rig.decoder.calls.count == calls, "decoded again under pressure")
        await rig.clear()
    }

    /// A ready decode that fails is dropped quietly: the photo is not marked failed and no ready decode of it
    /// restarts (n1 of photo 0). Stepping onto a photo whose ready decode is running (n2 of photo 28), its full job
    /// waits for it; when that fails the full job decodes the file itself, and that decode succeeds.
    @Test func failedReadyDecodeLeavesThePhotoAlone() async {
        var limits = CacheLimits.at3G
        limits.graphicsMemory = 1 << 30
        limits.full = 0
        let rig = Rig(limits: limits)
        let files = fileURLs(40)   // 30 lies beyond what photo 0's dwell reads
        let log = TraceEvents()
        await rig.cache.setTrace { log.add($0) }
        rig.decoder.failFullOnce(files[1])
        await rig.focus(files, 0, dwelling: true, needsFull: true)
        #expect(await eventually { log.events.contains { $0.url == files[1] && $0.kind == .readyFailed } })
        #expect(await rig.settle())
        #expect(await rig.cache.entry(files[1])?.failure == nil)
        #expect(rig.decoder.calls(files[1]).filter { $0 == .full }.count == 1, "n1's ready decode restarted")
        #expect(await rig.state(files[1]).map { $0 >= .preview } == true)
        #expect(rig.decoder.calls(files[30]).isEmpty, "fixture: photo 30 untouched so far")

        rig.decoder.failFullOnce(files[30])
        let gate = BlockingGate()
        rig.decoder.gateFull(files[30], gate)
        await rig.focus(files, 28, dwelling: true, needsFull: true, previous: 0)
        #expect(await eventually { rig.decoder.calls(files[30]).contains(.full) })
        await rig.focus(files, 30, needsFull: true, previous: 28)
        #expect(await eventually { log.events.contains { $0.url == files[30] && $0.kind == .readyAwait } })
        gate.open()
        #expect(await eventually { await rig.state(files[30]) == .full })
        #expect(await rig.settle())
        #expect(log.events.contains { $0.url == files[30] && $0.kind == .readyFailed })
        #expect(rig.decoder.calls(files[30]).filter { $0 == .full }.count == 2)
        #expect(await rig.cache.entry(files[30])?.failure == nil)
        await rig.clear()
    }

    /// Two neighbours not yet probed are planned ready at the size of the one photo known; their probes report four
    /// times the pixels, the plan drops them, and the cache holds no more than `cache-memory`: neither is decoded.
    @Test func readyReplannedWhenProbedLarger() async {
        var limits = CacheLimits.at3G
        limits.graphicsMemory = 1 << 30
        limits.full = 0
        limits.memory = 3 * readyBytes + 1_000_000
        let rig = Rig(size: readyPhoto, limits: limits)
        rig.decoder.fullSizedBuffers = true
        let files = fileURLs(3)
        let gate = BlockingGate()
        for url in files[1...] {
            rig.decoder.setSize(url, PixelSize(width: 2 * readyPhoto.width, height: 2 * readyPhoto.height))
            rig.decoder.gateProbe(url, gate)
        }
        await rig.focus(files, 0, dwelling: true, needsFull: true)
        #expect(await eventually {
            await rig.cache.inspect(Array(files[1...])).allSatisfy { $0?.planned[.ready] != nil }
        }, "fixture: the neighbours are planned ready at the estimate")
        gate.open()
        #expect(await rig.settle())
        #expect(await rig.cache.usedSystemBytes() <= limits.memory)
        #expect(await rig.cache.inspect(Array(files[1...])).allSatisfy { $0?.planned[.ready] == nil })
        for url in files[1...] { #expect(!rig.decoder.calls(url).contains(.full)) }
        #expect(await rig.cache.stats().readyCount == 1)
        await rig.clear()
    }

    /// A ready decode is background work: while one runs for the photo on screen (n1's, held, which the user stepped
    /// onto at Fit) the cache reports `.neighbours`, not `.current`, so thumbnails and Home covers keep going. A
    /// ready fill of a 147 MP photo takes seconds.
    @Test func readyDecodeIsNeverCurrentActivity() async {
        var limits = CacheLimits.at3G
        limits.graphicsMemory = 1 << 30
        limits.full = 0
        let rig = Rig(limits: limits)
        let files = fileURLs(10)
        let held = BlockingGate()
        rig.decoder.gateFullCalls(files[1], [held])
        await rig.focus(files, 0, dwelling: true, needsFull: true)
        #expect(await eventually { rig.decoder.calls(files[1]).contains(.full) })
        #expect(await eventually { atLeast(.preview, await rig.state(files[1])) })
        await rig.focus(files, 1, previous: 0)
        #expect(await rig.cache.inspect([files[1]])[0]?.jobs[.ready] == false, "fixture: n1's ready decode runs")
        // The step itself is the viewer's work (the photo's stamp check, say); once that is done, only the ready
        // decode is left.
        #expect(await eventually { await rig.cache.activity == .neighbours })
        let log = ActivityLog()
        await rig.cache.setOnActivity { log.add($0) }
        held.open()
        #expect(await rig.settle())
        #expect(log.values == [.neighbours, .idle])
        await rig.clear()
    }

    /// The full job's own check (`awaitReadyDecode`), not the replan's: n1's ready job is queued for the ready slot
    /// (n2's ready decode holds it) in the right class and still planned, so the replan that raises `cache-full` to 1
    /// keeps it, launches n1's full job, and that job gives the queued one up and decodes itself. One decode of n1.
    @Test func fullJobAbandonsAQueuedReadyJob() async {
        var limits = CacheLimits.at3G
        limits.graphicsMemory = 1 << 30
        limits.full = 0
        let rig = Rig(limits: limits)
        let files = fileURLs(10)
        let log = TraceEvents()
        await rig.cache.setTrace { log.add($0) }
        let read = AsyncGate(), held = BlockingGate()
        rig.reader.hang(files[1], on: read)
        rig.decoder.gateFullCalls(files[2], [held])
        await rig.focus(files, 0, dwelling: true, needsFull: true)
        #expect(await eventually { rig.decoder.calls(files[2]).contains(.full) }, "fixture: n2's ready decode holds the slot")
        read.open()
        #expect(await eventually {
            log.events.contains { $0.url == files[1] && $0.kind == .decodeWait && $0.goal == .ready }
        })
        #expect(await eventually { atLeast(.preview, await rig.state(files[1])) })
        #expect(await rig.cache.inspect([files[1]])[0]?.jobs[.ready] == true, "fixture: n1's ready job is queued")

        limits.full = 1
        await rig.cache.setLimits(limits)
        #expect(await eventually { await rig.state(files[1]) == .full }, "sharp while n2's ready decode is held")
        let events = log.events.filter { $0.url == files[1] }
        let launched = events.firstIndex { $0.kind == .jobLaunched && $0.goal == .full }
        let cancelled = events.firstIndex { $0.kind == .jobCancelled && $0.goal == .ready }
        #expect(launched != nil && cancelled != nil && cancelled! > launched!, "given up by the full job, after its launch")
        #expect(!events.contains { $0.kind == .readyAwait })
        held.open()
        #expect(await rig.settle())
        #expect(rig.decoder.calls(files[1]).filter { $0 == .full }.count == 1)
        await rig.clear()
    }

    /// A ready decode that finishes after its photo left the plan, with no full job waiting for it, is dropped: n1's,
    /// held while the user jumps far away, is not kept.
    @Test func lateUnplannedReadyDecodeIsDropped() async {
        var limits = CacheLimits.at3G
        limits.graphicsMemory = 1 << 30
        limits.full = 0
        let rig = Rig(limits: limits)
        let files = fileURLs(40)
        let log = TraceEvents()
        await rig.cache.setTrace { log.add($0) }
        let held = BlockingGate()
        rig.decoder.gateFullCalls(files[1], [held])
        await rig.focus(files, 0, dwelling: true, needsFull: true)
        #expect(await eventually { rig.decoder.calls(files[1]).contains(.full) })
        await rig.focus(files, 30, previous: 0)
        #expect(await rig.cache.inspect([files[1]])[0]?.planned[.ready] == nil, "fixture: n1 left the plan")
        #expect(await rig.cache.inspect([files[1]])[0]?.jobs[.ready] == false, "fixture: its ready decode runs")
        let ready = await rig.cache.stats().readyCount
        held.open()
        #expect(await rig.settle())
        #expect(log.events.contains { $0.url == files[1] && $0.kind == .uploadSkipped && $0.goal == .ready })
        #expect(await rig.cache.stats().readyCount == ready)
        await rig.clear()
    }
}

private final class TraceEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CacheTraceEvent] = []
    func add(_ e: CacheTraceEvent) { lock.withLock { items.append(e) } }
    var events: [CacheTraceEvent] { lock.withLock { items } }
}

private final class ActivityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CacheActivity] = []
    func add(_ a: CacheActivity) { lock.withLock { items.append(a) } }
    var values: [CacheActivity] { lock.withLock { items } }
}

private final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    func add(_ url: URL) { lock.withLock { items.append(url) } }
    var urls: [URL] { lock.withLock { items } }
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var out: [T] = []
        for e in self { out.append(await transform(e)) }
        return out
    }
}

// MARK: - Seeding from a thumbnail (spec M2.5 §5.1)

/// 10502×14000 on the rig's 1000×750 screen: Lfit 4, coarse 5, six levels; a 512 px thumbnail seeds level 5.
private let tall = PixelSize(width: 10502, height: 14000)

private func seedInfo(_ size: PixelSize = tall, type: String = "public.jpeg") -> ImageInfo {
    ImageInfo(pixelSize: size, typeIdentifier: type, isProgressive: false, fileSize: 0, colorSpaceName: nil)
}

/// A level of `size`'s pyramid with a one-page buffer, like the fake decoder's (nothing reads the pixels).
private func seedLevel(_ level: Int, of size: PixelSize = tall, space: CFString = CGColorSpace.sRGB) throws -> LevelImage {
    let levelSize = TileGrid(imageSize: size).levelSize(level)
    let pixels = DecodedImage(pixelSize: levelSize, bytesPerRow: levelSize.width * 4,
                              buffer: try PageAlignedBuffer(minimumLength: 1),
                              colorSpace: CGColorSpace(name: space)!)
    return LevelImage(image: pixels, level: level)
}

/// The entry's seeded flag and whether it has a pending pyramid, read on the cache's actor (nil: no entry).
private func seedState(_ cache: isolated ImageCache<FakeLoader>, _ url: URL) -> (seeded: Bool, pending: Bool)? {
    cache.entries[url].map { ($0.seeded, $0.pending != nil) }
}

extension ImageCacheTests {
    @Test func seedMakesEntryResident() async throws {
        let rig = Rig(size: tall)
        let url = fileURL(0)
        await rig.cache.seed(url, info: seedInfo(), level: try seedLevel(5))
        let entry = try #require(await rig.cache.entry(url))
        #expect(entry.pyramid != nil)
        #expect(entry.pyramid?.finest == 5)
        #expect(entry.isSeededOnly)
        #expect(entry.info == seedInfo())
        #expect(rig.loader.uploadedLevels(width: tall.width) == [5])
        await rig.clear()
    }

    /// The thumbnail is made turned (spec M3b §2.2), so an EXIF 6 photo stored 14000x10502 is seeded with a level of
    /// its oriented (10502x14000) pyramid, which the viewer draws with `.up`; a level in stored layout is refused.
    @Test func seedOfARotatedPhotoIsInOrientedLayout() async throws {
        let rig = Rig(size: PixelSize(width: tall.height, height: tall.width))
        let url = fileURL(0)
        let rotated = ImageInfo(pixelSize: PixelSize(width: tall.height, height: tall.width), typeIdentifier: "public.jpeg",
                                isProgressive: false, fileSize: 0, colorSpaceName: nil, orientation: .right)
        await rig.cache.seed(url, info: rotated, level: try seedLevel(5, of: PixelSize(width: tall.height, height: tall.width)))
        #expect(await rig.cache.entry(url) == nil)
        await rig.cache.seed(url, info: rotated, level: try seedLevel(5))
        let entry = try #require(await rig.cache.entry(url))
        #expect(entry.isSeededOnly && entry.pyramidIsSeeded && entry.info == rotated)
        #expect(entry.pyramid?.grid.imageSize == tall)
        await rig.clear()
    }

    @Test func seedDoesNotReadFile() async throws {
        let rig = Rig(size: tall)
        let url = fileURL(0)
        await rig.cache.seed(url, info: seedInfo(), level: try seedLevel(5))
        #expect(await rig.settle())
        #expect(rig.reader.readCount(url) == 0)
        #expect(rig.reader.stampPriorities.isEmpty)
        #expect(rig.decoder.calls.isEmpty)
        await rig.clear()
    }

    /// The decoded preview replaces the thumbnail with a pyramid in the decoder's colour space (a P3 thumbnail, an
    /// sRGB decode here): the entry is no longer only the thumbnail, and a second seed (the user jumps back) does not
    /// put the thumbnail over it.
    @Test func previewArrivingClearsSeededOnly() async throws {
        let rig = Rig(size: tall)
        let url = fileURL(0)
        await rig.cache.seed(url, info: seedInfo(), level: try seedLevel(5, space: CGColorSpace.displayP3))
        #expect(await rig.cache.entry(url)?.isSeededOnly == true)
        #expect(await rig.cache.entry(url)?.pyramidIsSeeded == true)
        await rig.focus([url], 0)
        #expect(await eventually { atLeast(.preview, await rig.state(url)) })
        let entry = try #require(await rig.cache.entry(url))
        #expect(!entry.isSeededOnly)
        #expect(!entry.pyramidIsSeeded)   // the decoded pyramid is drawn with the photo's orientation
        #expect(entry.pyramid?.finest ?? 99 <= 4)
        #expect(entry.pyramid?.colorSpace?.name == CGColorSpace.sRGB)
        #expect(rig.loader.pyramids.count == 2, "the thumbnail's pyramid and the decoded one")
        #expect(await seedState(rig.cache, url).map { !$0.seeded && !$0.pending } == true)
        #expect(await rig.settle())

        let uploads = rig.loader.uploadedLevels(width: tall.width)
        await rig.cache.seed(url, info: seedInfo(), level: try seedLevel(5))
        #expect(rig.loader.uploadedLevels(width: tall.width) == uploads)
        #expect(await rig.cache.entry(url)?.isSeededOnly == false)
        await rig.clear()
    }

    /// The thumbnail described another file (replaced since): the probe's size or type differs, so the entry starts
    /// over from the real header, keeping the bytes it just read.
    @Test func probeMismatchResetsSeed() async throws {
        let rig = Rig(size: rigPhoto)
        let files = fileURLs(2)
        await rig.cache.seed(files[0], info: seedInfo(), level: try seedLevel(5))
        await rig.cache.seed(files[1], info: seedInfo(rigPhoto, type: "public.heic"), level: try seedLevel(2, of: rigPhoto))
        #expect(await rig.cache.entry(files[0])?.isSeededOnly == true)
        #expect(await rig.cache.entry(files[1])?.isSeededOnly == true)
        for (i, url) in files.enumerated() {
            await rig.focus(files, i)
            #expect(await eventually { atLeast(.preview, await rig.state(url)) }, "file \(i)")
            let entry = try #require(await rig.cache.entry(url))
            #expect(entry.info?.pixelSize == rigPhoto)
            #expect(entry.info?.typeIdentifier == "public.jpeg")
            #expect(!entry.isSeededOnly)
            #expect(rig.reader.readCount(url) == 1, "file \(i): the bytes read survive the reset")
        }
        // A fresh pyramid for each reset entry (two seeded, two real), no level decoded into the 14000 px one.
        #expect(rig.loader.pyramids.count == 4)
        #expect(rig.loader.uploadedLevels(width: tall.width) == [5])
        await rig.clear()
    }

    /// A photo no larger than the thumbnail seeds level 0, which is all its pyramid has: it must still be read and
    /// decoded (the thumbnail is a JPEG 0.8 re-encode), and the decode replaces it.
    @Test func seedAtLevel0StillDecodesTheFile() async throws {
        let small = PixelSize(width: 400, height: 300)
        let rig = Rig(size: small)
        let url = fileURL(0)
        await rig.cache.seed(url, info: seedInfo(small), level: try seedLevel(0, of: small))
        #expect(await rig.cache.entry(url)?.isSeededOnly == true)
        #expect(await rig.state(url) == .coarse, "a seeded level satisfies .coarse at most")
        await rig.focus([url], 0, dwelling: true)
        #expect(await eventually { await rig.cache.entry(url)?.isSeededOnly == false })
        #expect(await eventually { await rig.state(url) == .full })
        #expect(await rig.settle())
        #expect(rig.reader.readCount(url) == 1)
        #expect(rig.decoder.calls(url).contains(.probe))
        #expect(rig.loader.uploadedLevels(width: small.width) == [0, 0], "the seed, then the decoded level 0")
        #expect(rig.loader.pyramids.count == 2)
        await rig.clear()
    }

    /// The seed's upload is still running when the decoded preview lands: the thumbnail is dropped, never put over
    /// the decoded levels.
    @Test func seedNeverOverwritesADecodedLevel() async throws {
        let rig = Rig(size: tall)
        let url = fileURL(0)
        let gate = AsyncGate()
        rig.loader.gateNextUpload(width: tall.width, level: 5, gate)
        let level = try seedLevel(5)
        let seeding = Task { await rig.cache.seed(url, info: seedInfo(), level: level) }
        #expect(await eventually { rig.loader.gatedUploadStarted })
        await rig.focus([url], 0)
        #expect(await eventually { atLeast(.preview, await rig.state(url)) })
        gate.open()
        await seeding.value
        let entry = try #require(await rig.cache.entry(url))
        #expect(!entry.isSeededOnly)
        #expect(entry.pyramid?.finest ?? 99 <= 4)
        #expect(entry.pyramid !== rig.loader.pyramids.first, "the thumbnail's pyramid stayed out")
        #expect(await seedState(rig.cache, url).map { !$0.seeded } == true)
        await rig.clear()
    }

    /// A seeded entry is evicted like any other (here: the farthest, beyond any plan), and its seeded state goes
    /// with the pyramid; the entry itself stays, being in the playlist.
    @Test func evictingASeedClearsIt() async throws {
        let rig = Rig(size: tall)
        let files = fileURLs(60)
        let far = files[59]
        await rig.cache.seed(far, info: seedInfo(), level: try seedLevel(5))
        #expect(await seedState(rig.cache, far).map(\.seeded) == true)
        await rig.focus(files, 0)
        #expect(await rig.cache.entry(far)?.pyramid?.finest == 5, "it fits: kept")
        await rig.setMemory(1)
        #expect(await eventually { await rig.cache.entry(far)?.pyramid == nil })
        let state = try #require(await seedState(rig.cache, far))
        #expect(!state.seeded && !state.pending)
        #expect(await rig.cache.entry(far)?.isSeededOnly == false)
        await rig.clear()
    }

    /// The thumbnail never replaces decoded levels, not even coarser ones (a seed finer than Lfit: `thumb-size` 1024 in
    /// a small window): they would be thrown away and the preview decoded again on every jump back. A finer thumbnail
    /// does replace a coarser seed.
    @Test func seedNeverReplacesDecodedLevels() async throws {
        let rig = Rig(size: tall)
        let files = fileURLs(2)
        await rig.focus([files[0]], 0)
        #expect(await eventually { atLeast(.preview, await rig.state(files[0])) })
        #expect(await rig.settle())
        let decoded = try #require(await rig.cache.entry(files[0])?.pyramid)
        #expect(decoded.finest == 4)
        await rig.cache.seed(files[0], info: seedInfo(), level: try seedLevel(3))
        let after = try #require(await rig.cache.entry(files[0]))
        #expect(after.pyramid === decoded)
        #expect(!after.isSeededOnly)
        #expect(await rig.state(files[0]) == .preview, "the preview stays satisfied: nothing to decode again")
        #expect(rig.loader.pyramids.count == 1, "the seed was refused before its upload")

        await rig.cache.seed(files[1], info: seedInfo(), level: try seedLevel(5))
        await rig.cache.seed(files[1], info: seedInfo(), level: try seedLevel(4))
        #expect(await rig.cache.entry(files[1])?.pyramid?.finest == 4)
        #expect(await rig.cache.entry(files[1])?.isSeededOnly == true)
        await rig.clear()
    }

    /// A refused seed (a level that is not one of the photo's) leaves no entry behind.
    @Test func refusedSeedLeavesNoEntry() async throws {
        let rig = Rig(size: tall)
        let url = fileURL(0)
        await rig.cache.seed(url, info: seedInfo(), level: try seedLevel(2, of: rigPhoto))
        #expect(await rig.cache.entry(url) == nil)
        await rig.cache.seed(url, info: seedInfo(), level: try seedLevel(9))
        #expect(await rig.cache.entry(url) == nil)
        await rig.clear()
    }

    @Test func seedCountsTowardMemory() async throws {
        let rig = Rig(size: tall)
        #expect(await rig.cache.stats().usedBytes == 0)
        await rig.cache.seed(fileURL(0), info: seedInfo(), level: try seedLevel(5))
        let oneSlot = TileGrid.slotSize * TileGrid.slotSize * 4
        #expect(await rig.cache.stats().usedBytes == oneSlot)
        #expect(TileGrid(imageSize: tall).byteCount(levels: 5..<6) == oneSlot)
        await rig.clear()
    }
}

// MARK: - Scrubbing (spec M2.5 §5.3)

/// Whether any entry has a read or a job registered, read on the cache's actor.
private func hasWork(_ cache: isolated ImageCache<FakeLoader>) -> Bool {
    cache.entries.values.contains { $0.read != nil || !$0.jobs.isEmpty }
}

extension ImageCacheTests {
    /// Neighbour reads queued behind a held one are cancelled when a scrubbing focus arrives, and nothing new is
    /// read or decoded, not even for the photo under the cursor; once the flag drops, its read starts at once.
    @Test func scrubbingCancelsWaitingReads() async {
        let queue = QueueReader(slots: 1)
        let rig = Rig(queueReader: queue)
        let files = fileURLs(40)   // 30 and 31 lie beyond the dwelling neighbourhood of 0: never read before
        let log = TraceEvents()
        await rig.cache.setTrace { log.add($0) }
        queue.hold(files[0])
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually { queue.queuedCount >= 6 })
        let waiting = Set(files.filter { queue.queuedPriority($0) != nil })

        await rig.focus(files, 30, scrubbing: true)
        #expect(await eventually { queue.queuedCount == 0 })
        let cancelled = Set(log.events.filter { $0.kind == .readCancelled }.map(\.url))
        #expect(waiting.isSubset(of: cancelled), "\(cancelled.map(\.lastPathComponent))")
        #expect(!(await hasWork(rig.cache)))
        await rig.focus(files, 31, scrubbing: true)
        #expect(!(await hasWork(rig.cache)))
        let passed: Set = [files[30], files[31]]
        let started = log.events.filter { passed.contains($0.url) && ($0.kind == .readRequested || $0.kind == .jobLaunched) }
        #expect(started.isEmpty, "\(started.map { "\($0.url.lastPathComponent) \($0.kind)" })")
        #expect(!queue.hasArrived(files[30]) && !queue.hasArrived(files[31]))

        await rig.focus(files, 31)
        #expect(await eventually { queue.queuedPriority(files[31]) == 0 })
        queue.release(files[0])
        #expect(await eventually { atLeast(.preview, await rig.state(files[31])) })
        await rig.clear()
    }

    /// The plan wants nothing while scrubbing, but that is no reason to drop anything: a resident neighbour keeps its
    /// levels and bytes, a seeded photo (35: beyond the dwelling neighbourhood, never read) its thumbnail.
    @Test func scrubbingKeepsResidentState() async throws {
        let rig = Rig()
        let files = fileURLs(40)
        await rig.focus(files, 0, dwelling: true)
        #expect(await eventually {
            let current = await rig.state(files[0]), next = await rig.state(files[1])
            return current == .full && atLeast(.preview, next)
        })
        #expect(await rig.settle())
        await rig.cache.seed(files[35], info: seedInfo(rigPhoto), level: try seedLevel(2, of: rigPhoto))
        #expect(await rig.cache.entry(files[35])?.isSeededOnly == true)

        await rig.focus(files, 30, scrubbing: true)
        await rig.focus(files, 35, scrubbing: true)
        #expect(await rig.settle())
        #expect(await rig.state(files[0]) == .full)
        #expect(atLeast(.preview, await rig.state(files[1])))
        #expect(await rig.cache.cachedBytes(files[1], stamp: FileStamp(modified: Date(timeIntervalSince1970: 1), size: 1000)) != nil)
        #expect(await rig.cache.entry(files[35])?.isSeededOnly == true)
        #expect(rig.reader.readCount(files[35]) == 0)
        await rig.clear()
    }

    /// The photo under the cursor is only passing through: a cached one is checked against the disk (the stamp check)
    /// once the scrub settles on it, not on the way.
    @Test func scrubbingDefersStampCheck() async {
        let rig = Rig()
        let files = fileURLs(5)
        await rig.focus(files, 0)
        #expect(await rig.settle())
        await rig.focus(files, 1)
        #expect(await rig.settle())
        let checks = rig.reader.stampPriorities.count

        await rig.focus(files, 0, direction: -1, scrubbing: true)
        #expect(await rig.settle())
        #expect(rig.reader.stampPriorities.count == checks)
        await rig.focus(files, 0, direction: -1)
        #expect(await rig.settle())
        #expect(rig.reader.stampPriorities.count == checks + 1)
        await rig.clear()
    }
}

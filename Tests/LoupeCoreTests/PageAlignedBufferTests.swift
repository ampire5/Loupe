import Darwin
import Foundation
import Testing
@testable import LoupeCore

/// `phys_footprint` of this process (what Activity Monitor calls Memory).
func physFootprint() -> Int { ProcessMemory.footprint() }

/// Other suites run in parallel and allocate too, so a footprint check gets a few attempts: a real retention
/// fails every one of them, a neighbour's allocation landing inside the window does not repeat.
func passesOnSomeAttempt(_ attempts: Int = 3, _ check: () -> (Bool, String)) -> (Bool, String) {
    var notes: [String] = []
    for _ in 0..<attempts {
        let (ok, note) = check()
        if ok { return (true, note) }
        notes.append(note)
    }
    return (false, notes.joined(separator: "; "))
}

/// The bench fixture (git-ignored, so it may be absent): a 147 MP HEIC.
private let bigHEIC = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/bench/big.heic")

/// Tests that measure the process's `phys_footprint`. Serialized, so they never disturb each other; other suites
/// still run in parallel, hence the retries.
@Suite(.serialized) struct FootprintTests {
    /// Spec §11.3: a released pixel buffer goes back to the system at once (mmap/munmap), not into a malloc
    /// free list that keeps it resident and counted in `phys_footprint`.
    @Test func returnsMemoryOnDeinit() throws {
        let size = 512 << 20
        let (ok, note) = passesOnSomeAttempt {
            var buffer: PageAlignedBuffer? = try? PageAlignedBuffer(minimumLength: size)
            guard let length = buffer?.length, let bytes = buffer?.bytes else { return (false, "allocation failed") }
            // Touch every page so all of it is resident.
            for offset in stride(from: 0, to: length, by: 4096) { bytes.storeBytes(of: 1, toByteOffset: offset, as: UInt8.self) }
            let held = physFootprint()
            buffer = nil
            let released = physFootprint()
            let dropped = held - released
            return (dropped >= size * 9 / 10, "dropped \(dropped >> 20) MB of \(size >> 20) MB")
        }
        #expect(ok, "\(note)")
    }

    /// Spec §11.3: nothing of a decode outlives it. A 147 MP HEIC (548 MB of BGRA per decode), probed and then
    /// decoded three times, leaves the footprint where it was. Before the fix one freed 548 MB frame stayed
    /// resident in malloc (+576 MB, then reused), which is what the replay saw as "ImageIO keeps ~548 MB per
    /// decode". Smaller HEICs and PNGs do not tell the two apart (a 24 MP HEIC grows ~95 MB either way: the HEVC
    /// decoder's own state), hence the fixture; skipped without it.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: bigHEIC.path)))
    func imageIODecodeDoesNotCache() throws {
        let data = try Data(contentsOf: bigHEIC)
        #expect(try ImageIODecoder.probe(data).pixelSize.width == 10502)
        let (ok, note) = passesOnSomeAttempt {
            let before = physFootprint()
            for _ in 0..<3 {
                guard (try? ImageIODecoder.decodeFull(data)) != nil else { return (false, "decode failed") }
            }
            let growth = physFootprint() - before
            return (growth < 300 << 20, "grew \(growth >> 20) MB")
        }
        #expect(ok, "\(note)")
    }
}

struct PageAlignedBufferTests {
    @Test func pageAlignedAndZeroed() throws {
        let b = try PageAlignedBuffer(minimumLength: 100_000)
        #expect(Int(bitPattern: b.bytes) % PageAlignedBuffer.pageSize == 0)
        #expect(b.length % PageAlignedBuffer.pageSize == 0 && b.length >= 100_000)
        let bytes = UnsafeRawBufferPointer(start: b.bytes, count: b.length)
        #expect(bytes.allSatisfy { $0 == 0 })
    }
}

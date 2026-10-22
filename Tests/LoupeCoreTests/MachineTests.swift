import Testing
@testable import LoupeCore

@Test func machineReadsItsCoresAndMemory() {
    #expect(Machine.physicalCores >= 1)
    #expect(Machine.memoryBytes >= 1 << 30)
}

/// A fifth of the memory in 256 MB steps, 1 to 4 GB: 16 GB keeps the 3 GB Loupe always had.
@Test func cacheMemoryFollowsTheMemory() {
    let gb = 1 << 30
    #expect([4, 8, 16, 18, 24, 36, 64, 128].map { Machine.cacheMemory(memoryBytes: $0 * gb) }
            == [gb, 1536 << 20, 3 * gb, 3584 << 20, 4 * gb, 4 * gb, 4 * gb, 4 * gb])
    #expect(Config().cacheMemory == Machine.cacheMemory(memoryBytes: Machine.memoryBytes))
}

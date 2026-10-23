import Testing
@testable import LoupeCore

private let gib = 1 << 30
private let imac = MachineProfile(physicalCores: 8, performanceCores: 8, memoryBytes: 64 * gib,
                                  gpu: GPUProfile(unifiedMemory: false, workingSetBytes: 8_573_157_376,
                                                  name: "AMD Radeon Pro 5500 XT"))
private let card4 = MachineProfile(physicalCores: 4, performanceCores: 4, memoryBytes: 16 * gib,
                                   gpu: GPUProfile(unifiedMemory: false, workingSetBytes: 4_294_967_296, name: "Card"))
private let m4max = MachineProfile(physicalCores: 16, performanceCores: 12, memoryBytes: 64 * gib,
                                   gpu: GPUProfile(unifiedMemory: true, workingSetBytes: 48 * gib, name: "Apple GPU"))
private let m1 = MachineProfile(physicalCores: 8, performanceCores: 4, memoryBytes: 8 * gib,
                                 gpu: GPUProfile(unifiedMemory: true, workingSetBytes: 5_726_623_744, name: "Apple GPU"))
private let intelIGPU = MachineProfile(physicalCores: 4, performanceCores: 4, memoryBytes: 16 * gib,
                                       gpu: GPUProfile(unifiedMemory: true, workingSetBytes: 1_610_612_736, name: "iGPU"))

@Test func graphicsTierIsHalfTheCardsWorkingSet() {
    #expect(HardwareAdvice.graphicsMemory(imac) == 4_286_578_688)
    #expect(HardwareAdvice.graphicsMemory(card4) == 2_147_483_648)
    #expect([m4max, m1, intelIGPU].map { HardwareAdvice.graphicsMemory($0) } == [nil, nil, nil])
}

@Test func cacheMemoryDefaultFollowsTheTier() {
    #expect(HardwareAdvice.defaultCacheMemory(imac) == 13_690_208_256)
    #expect(HardwareAdvice.defaultCacheMemory(card4) == 3_221_225_472)
    #expect(HardwareAdvice.defaultCacheMemory(m4max) == 4 << 30)
    #expect(HardwareAdvice.defaultCacheMemory(m1) == 1536 << 20)
    // A discrete card with little memory: a fifth would be under 1 GiB (819 MiB of 4 GiB, 409 MiB of 2 GiB).
    for memory in [2 * gib, 4 * gib] {
        let small = MachineProfile(physicalCores: 4, performanceCores: 4, memoryBytes: memory,
                                   gpu: GPUProfile(unifiedMemory: false, workingSetBytes: 2 * gib, name: "Card"))
        #expect(HardwareAdvice.defaultCacheMemory(small) == gib)
    }
}

@Test func neighbourThreadsAreAQuarterOfTheCores() {
    #expect([imac, card4, m4max, m1].map { HardwareAdvice.defaultJXLThreadsOther($0) } == [2, 1, 2, 2])
    #expect(HardwareAdvice.effectiveJXLThreadsOther(8, imac) == 2)
    #expect(HardwareAdvice.effectiveJXLThreadsOther(1, imac) == 1)
    #expect(HardwareAdvice.effectiveJXLThreadsOther(4, m4max) == 4)
    #expect(HardwareAdvice.effectiveJXLThreadsOther(5, m4max) == 4)
}

@Test func notesNameTheRuleAndTheRecommendedValue() {
    typealias Note = HardwareAdvice.Note
    #expect(HardwareAdvice.note(forKey: "jxl-threads-other", value: "8", on: imac)
            == Note(severity: .harmful,
                    text: "Effective 2 on this Mac: more would take over a quarter of its 8 cores in the background.",
                    recommended: "2"))
    #expect(HardwareAdvice.note(forKey: "jxl-threads-current", value: "16", on: imac)
            == Note(severity: .suboptimal, text: "More threads than this Mac's 8 cores only burn CPU.", recommended: "8"))
    #expect(HardwareAdvice.note(forKey: "cache-memory", value: "40G", on: imac)
            == Note(severity: .suboptimal,
                    text: "Over half of this Mac's 68.7 GB of memory: macOS would squeeze other apps before the cache gives way.",
                    recommended: "13056M"))
    #expect(HardwareAdvice.note(forKey: "jxl-threads-other", value: "2", on: imac) == nil)
    #expect(HardwareAdvice.note(forKey: "cache-memory", value: "20G", on: imac) == nil)
    #expect(HardwareAdvice.note(forKey: "zoom-stops", value: "x", on: imac) == nil)
    #expect(HardwareAdvice.note(forKey: "jxl-threads-other", value: "abc", on: imac) == nil)
}

@Test func harmfulValueWarnsOnceAndKeepsTheFile() {
    let (config, _) = Config.parse("jxl-threads-other=8\njxl-threads-current=16\n")
    #expect(HardwareAdvice.warnings(for: config, on: imac) == ["jxl-threads-other=8: using 2 on this Mac (8 cores)"])
    #expect(config.jxlThreadsOther == 8)
}

@Test func defaultsNeverNote() {
    for key in ["jxl-threads-other", "jxl-threads-current", "cache-memory"] {
        #expect(HardwareAdvice.note(forKey: key, value: Config().text(forKey: key)!, on: .current) == nil)
    }
}

@Test func limitsCarryTheGraphicsTier() {
    #expect(CacheLimits(config: Config(), profile: imac).graphicsMemory == 4_286_578_688)
    #expect(CacheLimits(config: Config(), profile: m4max).graphicsMemory == nil)
    // Without a config, the same tier as with one: this Mac's.
    #expect(CacheLimits().graphicsMemory == CacheLimits(config: Config()).graphicsMemory)
}

@Test func neighbourThreadsTakeEffectClamped() {
    let (config, _) = Config.parse("jxl-threads-other=8\n")
    #expect(JXLOptions(config: config, profile: imac).threadsOther == 2)
    #expect(JXLOptions(config: config, profile: m4max).threadsOther == 4)
}

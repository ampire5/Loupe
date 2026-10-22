import Testing
import Foundation
import SettingsKit
import LoupeCore
@testable import LoupeSettings

private let gib = 1 << 30
private let imac = MachineProfile(physicalCores: 8, performanceCores: 8, memoryBytes: 64 * gib,
                                  gpu: GPUProfile(unifiedMemory: false, workingSetBytes: 8_573_157_376,
                                                  name: "AMD Radeon Pro 5500 XT"))
private let m4max = MachineProfile(physicalCores: 16, performanceCores: 12, memoryBytes: 64 * gib,
                                   gpu: GPUProfile(unifiedMemory: true, workingSetBytes: 48 * gib,
                                                   name: "Apple M4 Max"))

/// The Performance page and its store judged against a given Mac (hardware defaults, spec «Где видно»).
@MainActor
struct MachineNotesTests {
    private func store(_ text: String, on profile: MachineProfile) throws -> (ConfigSettingsStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("loupe.conf")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let config = Config.load(from: file).0
        return (ConfigSettingsStore(fileURL: file, current: { config }, reload: {}, profile: profile), dir)
    }

    @Test func writtenHarmfulValueHasANote() throws {
        let (store, dir) = try store("jxl-threads-other=8\n", on: imac)
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = store.machineNote(forKey: "jxl-threads-other")
        #expect(note?.severity == .harmful)
        #expect(note?.recommended == "2")
        #expect(note?.text.hasPrefix("Effective 2 on this Mac") == true)
        #expect(store.machineNote(forKey: "jxl-threads-current") == nil)
    }

    @Test func graphicsRowOnlyOnADiscreteCard() {
        let discrete = SettingsPanel.performancePage(on: imac).rows.map(\.title)
        let unified = SettingsPanel.performancePage(on: m4max).rows.map(\.title)
        #expect(discrete.contains("Graphics memory"))
        #expect(!unified.contains("Graphics memory"))
    }

    @Test func cacheMemoryDescriptionNamesTheTier() {
        let row = SettingsPanel.performancePage(on: imac).rows.first { $0.key == "cache-memory" }
        #expect(row?.description?.contains("decoded") == true)
        #expect(row?.description?.contains("graphics memory is Loupe's") == true)
        let unified = SettingsPanel.performancePage(on: m4max).rows.first { $0.key == "cache-memory" }
        #expect(unified?.description?.contains("graphics memory") == false)
    }

    @Test func graphicsTextNamesTierWorkingSetAndCard() {
        #expect(GraphicsMemoryView.text(for: imac)
                == "4.3 GB of 8.6 GB on AMD Radeon Pro 5500 XT, set by Loupe for this card")
    }
}

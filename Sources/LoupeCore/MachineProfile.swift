import Foundation
import Metal

/// The graphics side of a Mac: whether the card shares the system's memory, and how much of it the system lets one
/// app use.
public struct GPUProfile: Equatable, Sendable {
    /// An Apple chip or an Intel integrated GPU: the card uses the system's memory. A discrete card has its own.
    public var unifiedMemory: Bool
    /// `recommendedMaxWorkingSetSize`: what the system lets one app keep on the card (8.57 GB on a Radeon Pro 5500 XT).
    public var workingSetBytes: Int
    public var name: String

    public init(unifiedMemory: Bool, workingSetBytes: Int, name: String) {
        self.unifiedMemory = unifiedMemory
        self.workingSetBytes = workingSetBytes
        self.name = name
    }
}

/// The figures a default or a note depends on, in one value so tests can stand in any Mac.
public struct MachineProfile: Equatable, Sendable {
    public var physicalCores: Int
    public var performanceCores: Int
    public var memoryBytes: Int
    public var gpu: GPUProfile

    public init(physicalCores: Int, performanceCores: Int, memoryBytes: Int, gpu: GPUProfile) {
        self.physicalCores = physicalCores
        self.performanceCores = performanceCores
        self.memoryBytes = memoryBytes
        self.gpu = gpu
    }

    /// This Mac. Without a Metal device the memory counts as unified, with the whole of it as the working set.
    public static let current: MachineProfile = {
        let gpu: GPUProfile
        if let device = MTLCreateSystemDefaultDevice() {
            gpu = GPUProfile(unifiedMemory: device.hasUnifiedMemory,
                             workingSetBytes: Int(clamping: device.recommendedMaxWorkingSetSize), name: device.name)
        } else {
            gpu = GPUProfile(unifiedMemory: true, workingSetBytes: Machine.memoryBytes, name: "")
        }
        return MachineProfile(physicalCores: Machine.physicalCores, performanceCores: Machine.performanceCores,
                              memoryBytes: Machine.memoryBytes, gpu: gpu)
    }()
}

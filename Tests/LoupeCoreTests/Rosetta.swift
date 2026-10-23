import Darwin

/// Whether the tests run translated by Rosetta: CI's x86_64 job runs the tests on Apple Silicon, where timing
/// tests get some slack (enough for emulation, short of the delays they guard against).
let runsUnderRosetta: Bool = {
    var translated: Int32 = 0, size = MemoryLayout<Int32>.size
    return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
}()

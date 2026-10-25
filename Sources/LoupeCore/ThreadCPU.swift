import Darwin

/// The calling thread's CPU time (`CLOCK_THREAD_CPUTIME_ID`): what a main-thread budget is measured in (CLAUDE.md,
/// interface responsiveness), not the wall clock, which counts the time the thread waited too.
public enum ThreadCPU {
    public static func milliseconds() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
    }
}

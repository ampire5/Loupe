import Darwin
import LoupeCore

/// Collects per-method timings and renders them as a markdown table.
struct Report {
    private struct Row {
        var wall = Samples()
        var cpu = Samples()
        var mps = Samples()
        var failures = 0
    }

    private var order: [String] = []
    private var rows: [String: Row] = [:]

    /// Registers a new row. A labelled variant ("turbo-full (progressive)") goes right after the
    /// rows of the same method so a mixed folder's table stays grouped by method.
    private mutating func register(_ method: String) {
        let base = method.split(separator: " (").first.map(String.init) ?? method
        if let last = order.lastIndex(where: { $0 == base || $0.hasPrefix(base + " (") }) {
            order.insert(method, at: last + 1)
        } else {
            order.append(method)
        }
    }

    /// Records one call. `megapixels` is the decoded image size; leave it nil for methods that
    /// decode nothing (the `read` method), which then show no MP/s.
    mutating func add(method: String, ms: Double, cpuMs: Double, megapixels: Double? = nil) {
        if rows[method] == nil { register(method) }
        rows[method, default: Row()].wall.add(ms)
        rows[method, default: Row()].cpu.add(cpuMs)
        if let megapixels, ms > 0 { rows[method, default: Row()].mps.add(megapixels / (ms / 1000)) }
    }

    /// Records a call that threw, so a method that fails on some files shows it instead of a quietly smaller `n`.
    mutating func addFailure(method: String) {
        if rows[method] == nil { register(method) }
        rows[method, default: Row()].failures += 1
    }

    func markdown() -> String {
        var lines = [
            "| method | n | fail | median ms | p90 ms | median cpu ms | MP/s (median) |",
            "|---|---:|---:|---:|---:|---:|---:|",
        ]
        for method in order {
            let row = rows[method]!
            lines.append("| \(method) | \(row.wall.count) | \(row.failures) | \(fmt(row.wall.median)) | \(fmt(row.wall.percentile(90))) | \(fmt(row.cpu.median)) | \(fmt(row.mps.median)) |")
        }
        return lines.joined(separator: "\n")
    }

    private func fmt(_ v: Double?) -> String {
        v.map { String(format: "%.1f", $0) } ?? "-"
    }
}

/// Process CPU time (user + system) in milliseconds. A hardware decode shows far less CPU than wall time.
func cpuTimeMs() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func ms(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
    return ms(usage.ru_utime) + ms(usage.ru_stime)
}

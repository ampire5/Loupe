import Darwin
import Foundation
import LoupeCore

// LoupeBench [--limit N] [--methods a,b,…] [--jxl-threads N] <folder-or-file>…
// LoupeBench replay … (see Replay.swift)
// LoupeBench thumbs … (see ThumbsBench.swift)
// LoupeBench render … (see RenderBench.swift)
// LoupeBench pyramid … (see PyramidBench.swift)
// LoupeBench crops … (see CropsBench.swift)
// LoupeBench autocolour … (see AutoColourBench.swift)
// LoupeBench browser … (see BrowserBench.swift)
// LoupeBench strip … (see StripBench.swift)
// LoupeBench panload … (see PanLoadBench.swift)
// LoupeBench sharesim … (see ShareSimBench.swift)

let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "avif", "jxl", "webp", "tif", "tiff", "gif", "bmp"]
/// Every decode method by name. Each declares the formats it accepts; ImageIO takes all of them.
let decoders = [ImageIOBench.methods, TurboBench.methods, HeifBench.methods, JXLBench.methods]
    .reduce(into: [String: BenchMethod]()) { all, table in all.merge(table) { first, _ in first } }
let knownMethods = ["read"] + decoders.keys.sorted()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("LoupeBench: \(message)\n".utf8))
    exit(2)
}

// The app runs with libmalloc's large-block cache off (Info.plist LSEnvironment, spec M2 §11.1.8); the bench
// re-executes itself the same way, so its memory numbers always match the app's. An explicit setting is kept.
if getenv("MallocLargeCache") == nil {
    setenv("MallocLargeCache", "0", 1)
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    var size = UInt32(path.count)
    if _NSGetExecutablePath(&path, &size) == 0 {
        execv(path, CommandLine.unsafeArgv)
    }
    fail("cannot re-execute with MallocLargeCache=0 (errno \(errno)); run with MallocLargeCache=0 set")
}

if CommandLine.arguments.dropFirst().first == "replay" {
    Replay.main(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.dropFirst().first == "thumbs" {
    ThumbsBench.main(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.dropFirst().first == "render" {
    RenderBench.main(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.dropFirst().first == "pyramid" {
    PyramidBench.main(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.dropFirst().first == "crops" {
    CropsBench.main(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.dropFirst().first == "autocolour" {
    AutoColourBench.main(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.dropFirst().first == "browser" {
    BrowserBench.main(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.dropFirst().first == "panload" {
    PanLoadBench.main(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.dropFirst().first == "sharesim" {
    ShareSimBench.main(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.dropFirst().first == "strip" {
    StripBench.main(Array(CommandLine.arguments.dropFirst(2)))
}

var limit = Int.max
var methods = knownMethods
var inputs: [String] = []

var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--limit":
        guard let v = args.popFirst(), let n = Int(v), n > 0 else { fail("--limit needs a positive integer") }
        limit = n
    case "--methods":
        guard let v = args.popFirst() else { fail("--methods needs a comma-separated list") }
        methods = v.split(separator: ",").map(String.init)
    case "--jxl-threads":
        guard let v = args.popFirst(), let n = Int(v), n > 0 else { fail("--jxl-threads needs a positive integer") }
        JXLBench.threads = n
    case _ where arg.hasPrefix("--"):
        fail("unknown option \(arg)")
    default:
        inputs.append(arg)
    }
}
if inputs.isEmpty { fail("usage: LoupeBench [--limit N] [--methods a,b,…] [--jxl-threads N] <folder-or-file>…") }
if let unknown = methods.first(where: { !knownMethods.contains($0) }) {
    fail("unknown method \(unknown) (available: \(knownMethods.joined(separator: ", ")))")
}

/// Image files of a folder (non-recursive, hidden files skipped) in Finder order, or the file itself.
func imageFiles(at path: String) -> [URL] {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { fail("no such path: \(path)") }
    guard isDir.boolValue else { return [url] }
    let entries: [URL]
    do {
        entries = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    } catch {
        fail("cannot list \(path): \(error)")
    }
    return entries
        .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

/// Runs `decode` once and records wall time, CPU time and MP/s under the row `label`.
func timeDecode(_ label: String, _ decode: (Data) throws -> PixelSize, _ data: Data, into report: inout Report) throws {
    let cpu0 = cpuTimeMs()
    let start = DispatchTime.now().uptimeNanoseconds
    let size = try decode(data)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    report.add(method: label, ms: ms, cpuMs: cpuTimeMs() - cpu0, megapixels: Double(size.width * size.height) / 1e6)
}

// Each file is read once (uncached); every decode method then works on those in-memory bytes.
// The first accepted file of each input also runs each method once, untimed, so one-time
// framework setup (and the first touch of a new folder) is not measured. Failures are counted per method.
func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

for input in inputs {
    let files = Array(imageFiles(at: input).prefix(limit))
    var report = Report()
    var warmed: Set<String> = []  // "method/format" pairs already warmed up in this folder
    for file in files {
        let data: Data
        do {
            let cpu0 = cpuTimeMs()
            let (bytes, ms) = try ReadTimer.read(file)
            data = bytes
            if methods.contains("read") { report.add(method: "read", ms: ms, cpuMs: cpuTimeMs() - cpu0) }
        } catch {
            warn("skipped \(error)")
            for method in methods { report.addFailure(method: method) }
            continue
        }
        // A file no method recognises (wrong extension, corrupt header) is a failure for every
        // requested decoder, not a silent skip that still counts in the file total.
        if ImageFormat.detect(data) == nil {
            warn("unrecognised image format: \(file.lastPathComponent)")
            for method in methods where decoders[method] != nil { report.addFailure(method: method) }
            continue
        }
        for method in methods {
            guard let entry = decoders[method] else { continue }
            // Methods skip formats they do not handle; that is not a failure.
            guard entry.accepts(data) else { continue }
            let label = entry.label(method, data)
            // Untimed warm-up on the first file of each format in this folder that the method accepts,
            // so one-time setup (per codec for libheif) is not measured even when the folder starts
            // with a different format.
            if warmed.insert("\(method)/\(String(describing: ImageFormat.detect(data)))").inserted {
                _ = try? entry.decode(data)
            }
            do {
                try timeDecode(label, entry.decode, data, into: &report)
            } catch {
                warn("\(method) failed on \(file.lastPathComponent): \(error)")
                report.addFailure(method: label)
            }
        }
    }
    print("### \(input) (\(files.count) files)\n")
    print(report.markdown())
    print()
}

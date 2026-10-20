import Foundation

/// Your own `app-icon` as an Icon Composer package (`<name>.icon`, a folder): the app compiles it with Xcode's actool,
/// as make-app.sh does the bundled alternates, into an .icns kept in ~/Library/Caches/<bundle id>/AppIcons. The
/// compiled file is named by the package's newest modification, so an edited package is compiled again (~2.5 s, off
/// the main thread) and the stale file goes. Without Xcode nothing compiles; the caller says so.
enum IconPackage {
    static let pathExtension = "icon"

    /// Where the compiled icons are kept.
    static var cache: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Loupe", isDirectory: true)
            .appendingPathComponent("AppIcons", isDirectory: true)
    }

    /// Whether `url` is a package (a folder with the `.icon` extension).
    static func isPackage(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return url.pathExtension.lowercased() == pathExtension
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }

    /// The compiled .icns of the package as it is now; nil until it is compiled (`compile`).
    static func compiled(_ package: URL) -> URL? {
        guard let url = target(package) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Compiles the package unless its current .icns is there; the .icns, or nil when actool is missing or fails (its
    /// output goes to stderr). Older compiles of the same package are removed.
    static func compile(_ package: URL) async -> URL? {
        if let done = compiled(package) { return done }
        guard let target = target(package) else { return nil }
        return await Task.detached(priority: .utility) { () -> URL? in
            let files = FileManager.default
            let name = package.deletingPathExtension().lastPathComponent
            let work = cache.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
            defer { try? files.removeItem(at: work) }
            do { try files.createDirectory(at: work, withIntermediateDirectories: true) } catch { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["actool", package.path, "--compile", work.path, "--platform", "macosx",
                                 "--minimum-deployment-target", "26.0", "--app-icon", name,
                                 "--output-partial-info-plist", work.appendingPathComponent("partial.plist").path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do { try process.run() } catch { return nil }
            let log = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let icns = work.appendingPathComponent("\(name).icns")
            guard process.terminationStatus == 0, files.fileExists(atPath: icns.path) else {
                FileHandle.standardError.write(Data("loupe: actool could not compile \(package.path) (Xcode needed)\n".utf8))
                FileHandle.standardError.write(log)
                return nil
            }
            for old in (try? files.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix(Self.prefix(package)) {
                try? files.removeItem(at: old)
            }
            do { try files.moveItem(at: icns, to: target) } catch { return nil }
            return target
        }.value
    }

    /// `<name>-<hash of the package's path>-`: the start of every compile of this package.
    private static func prefix(_ package: URL) -> String {
        let path = package.standardizedFileURL.path
        let hash = path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return "\(package.deletingPathExtension().lastPathComponent)-\(String(hash, radix: 36))-"
    }

    /// The .icns for the package's newest modification (of the folder or any file in it); nil if it cannot be read.
    private static func target(_ package: URL) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: package, includingPropertiesForKeys: keys) else { return nil }
        var newest = (try? package.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
        for case let file as URL in walker {
            if let date = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate, date > newest {
                newest = date
            }
        }
        return cache.appendingPathComponent("\(prefix(package))\(Int(newest.timeIntervalSince1970)).icns")
    }
}

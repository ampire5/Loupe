import CoreGraphics
import Foundation

/// Home's card covers (Home spec §2.5): the thumbnail of a file whose folder no window lists, from the catalog without
/// opening the folder, else made from the file and kept in the database like any thumbnail.
extension ThumbnailStore {
    /// The cover of `url` at most `maxPixel` on its long side; nil when the file cannot be read. A folder some window
    /// lists answers from the strip's thumbnails; else a stored thumbnail whose stamp is still the file's; else one
    /// made now, one at a time, behind every viewer read.
    public func cover(_ url: URL, maxPixel: Int) async -> CGImage? {
        if ids[url] != nil, let cell = await cell(url, maxPixel: maxPixel) { return cell }
        let locate = self.locate
        // `resolve` may block on a slow share: never on the actor.
        let location = await Self.offActor { locate(url) }
        guard let stamp = try? await reader.stamp(url, priority: ReadPriority.background) else { return nil }
        if let location, let row = perform("cover", { try $0.file(at: location) }) ?? nil, row.stamp == stamp,
           let stored = perform("cover", { try $0.thumbnail(row.id) }) ?? nil {
            return await Self.offActor { ThumbnailMaker.decodeCell(stored.jpeg, maxPixel: maxPixel) }
        }
        try? await coverLimit.acquireSlot(forCurrent: false, rank: Self.readPriority)
        defer { coverLimit.releaseSlot(forCurrent: false) }
        let recipe = Recipe(url: url, listedStamp: stamp, maxSide: thumbSize, reader: reader,
                            decodeLimit: decodeLimit, decoder: decoder, cachedBytes: cachedBytes,
                            readEnded: {}, readAgain: {})
        var timing = Timing()
        guard case .made(let jpeg, let info, let madeStamp) = await Self.generate(recipe, &timing) else { return nil }
        if let location {
            _ = perform("cover") { db in
                let id = try db.addFile(location, stamp: madeStamp)
                try db.put([(id, madeStamp, jpeg, info)])
            }
        }
        return await Self.offActor { ThumbnailMaker.decodeCell(jpeg, maxPixel: maxPixel) }
    }

    /// The file browser's folder cards (file browser spec §4.2): how many photos the catalog knows in each folder, from
    /// rows earlier listings left; a folder never listed has no count (it is not listed for one).
    public func knownCounts(_ folders: [URL]) async -> [URL: Int] {
        let locate = self.locate
        var counts: [URL: Int] = [:]
        for folder in folders {
            // `resolve` may block on a slow share: never on the actor.
            guard let location = await Self.offActor({ locate(folder.appendingPathComponent("_")) }),
                  let count = perform("counts", { try $0.fileCount(in: location) }) ?? nil else { continue }
            counts[folder] = count
        }
        return counts
    }

    /// A folder card's mosaic (file browser, second round): up to `limit` photos of the folder that already have a
    /// thumbnail, by name, from the catalog alone — no listing and no read of the folder, which on a slow share would
    /// queue in front of what the user clicked.
    public func folderSamples(_ folder: URL, limit: Int) async -> [URL] {
        let locate = self.locate
        guard let location = await Self.offActor({ locate(folder.appendingPathComponent("_")) }),
              let names = perform("samples", { try $0.namesWithThumbnails(in: location, limit: limit) }) else { return [] }
        return names.map { folder.appendingPathComponent($0) }
    }

    /// The stored thumbnail of `url` at most `maxPixel` on its long side, from the catalog alone: no stat and no read
    /// of the file (a folder card's mosaic on a slow share). Nil when the catalog has none; it may be older than the
    /// file, which only a folder card can afford.
    public func catalogThumbnail(_ url: URL, maxPixel: Int) async -> CGImage? {
        let locate = self.locate
        guard let location = await Self.offActor({ locate(url) }),
              let row = perform("catalog", { try $0.file(at: location) }) ?? nil,
              let stored = perform("catalog", { try $0.thumbnail(row.id) }) ?? nil else { return nil }
        return await Self.offActor { ThumbnailMaker.decodeCell(stored.jpeg, maxPixel: maxPixel) }
    }
}

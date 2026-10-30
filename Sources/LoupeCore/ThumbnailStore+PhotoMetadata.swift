import Foundation

extension ThumbnailStore {
    /// Establish the file version before its source read. Runs on the store actor; volume resolution is off-actor.
    /// Directly opened photos work without first generating a thumbnail or listing their folder.
    public func photoMetadata(for url: URL, stamp: FileStamp) async -> PhotoMetadata? {
        guard wantsDisk, let location = await location(of: url.deletingLastPathComponent(), sample: url) else { return nil }
        return perform("photo metadata", { db in
            let file = ThumbnailLocation(volume: location.volume, folder: location.folder, name: url.lastPathComponent)
            let row = try db.file(at: file)
            let id: Int64
            if let row, row.stamp == stamp { id = row.id }
            else { id = try db.addFile(file, stamp: stamp) }
            return try db.photoMetadata(id, stamp: stamp)
        }) ?? nil
    }

    /// Only the previously established version may be filled. A source read finishing after a new listing is ignored.
    public func keepPhotoMetadata(_ metadata: PhotoMetadata, for url: URL, stamp: FileStamp) {
        guard metadata.error == nil, let location = locations[url.deletingLastPathComponent()] else { return }
        _ = perform("photo metadata", { db in
            guard let row = try db.file(at: ThumbnailLocation(volume: location.volume, folder: location.folder, name: url.lastPathComponent)), row.stamp == stamp else { return }
            try db.putPhotoMetadata(metadata, id: row.id, stamp: stamp)
        })
    }
}

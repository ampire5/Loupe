import Foundation
import HomeScreenModel

/// Source metadata for the standard grid sorts. IDs stay unique even when several assets share a filename.
public enum PhotosAlbumListing {
    public static func entries(_ assets: [PhotosAsset], album: String) -> [BrowserEntry] {
        assets.map { asset in
            let url = asset.url(in: album)
            return BrowserEntry(url: url, name: asset.filename, kind: .file, date: asset.created,
                                key: url.absoluteString, subtitle: "\(asset.width) × \(asset.height)")
        }
    }
}

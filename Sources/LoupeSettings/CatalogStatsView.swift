import LoupeCore
import SwiftUI

/// Settings › Performance › Catalog: what the thumbnail catalog holds, by volume, read off the main thread each time
/// the card is shown.
struct CatalogStatsView: View {
    let directory: URL?
    @State private var stats: CatalogStats?
    @State private var names: [String: String] = [:]
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let stats {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Volume").gridColumnAlignment(.leading)
                        Text("Folders")
                        Text("Files")
                        Text("Thumbnails")
                        Text("Size")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(stats.volumes, id: \.key) { volume in
                        row(CatalogStats.title(forVolume: volume.key, localNames: names), volume)
                    }
                    Divider()
                    row("All", stats.total).fontWeight(.semibold)
                }
                .monospacedDigit()
                Text("On disk: \(bytes(stats.diskBytes)) (Caches/Loupe)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(loaded ? "No catalog yet: thumbnails are kept only in memory." : "Counting…")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            let directory = directory
            let result = await Task.detached(priority: .userInitiated) {
                (directory.flatMap(CatalogStats.read), CatalogStats.mountedLocalNames())
            }.value
            stats = result.0
            names = result.1
            loaded = true
        }
    }

    private func row(_ title: String, _ v: CatalogStats.Volume) -> some View {
        GridRow {
            Text(title).lineLimit(1).truncationMode(.middle)
            Text(count(v.folders))
            Text(count(v.files))
            Text(count(v.thumbnails))
            Text(bytes(v.thumbnailBytes))
        }
    }

    private func count(_ n: Int) -> String { n.formatted(.number) }
    private func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}

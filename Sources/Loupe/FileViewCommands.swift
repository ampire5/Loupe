import AppKit
import HomeScreenKit
import LoupeCore

extension Notification.Name {
    static let fileViewListingChanged = Notification.Name("local.loupe.fileViewListingChanged")
}

/// The system clipboard carries file URLs so Finder and other windows can participate.
@MainActor enum FileViewCommands {
    static func files(_ selection: [BrowserEntry]) -> [URL] {
        selection.compactMap { entry in
            guard entry.url.isFileURL, entry.kind != .place, entry.kind != .collection,
                  ArchivePath.split(entry.url) == nil else { return nil }
            return entry.url
        }
    }

    static func images(_ selection: [BrowserEntry]) -> [URL] {
        selection.compactMap { entry in
            guard entry.isFile, SavedUpscale.supports(entry.url),
                  Playlist.imageExtensions.contains(entry.url.pathExtension.lowercased()) else { return nil }
            return entry.url
        }
    }

    static func destination(in location: BrowserLocation) -> URL? {
        guard case .folder(let folder) = location, folder.isFileURL,
              !ArchivePath.isArchive(folder) else { return nil }
        return folder
    }

    static var hasClipboardFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: fileURLOptions)
    }

    static func clipboardFiles(from pasteboard: NSPasteboard = .general) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLOptions) ?? []
        return objects.compactMap { $0 as? URL }.filter(\.isFileURL)
    }

    static func copy(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    private static var fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] { [.urlReadingFileURLsOnly: true] }
}

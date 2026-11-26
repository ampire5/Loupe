import AppKit
import LoupeCore

@MainActor final class UpscaleReplacement {
    static let shared = UpscaleReplacement()

    private var busy = false

    func confirmFolder(_ folder: URL, in window: NSWindow) {
        guard !busy, window.attachedSheet == nil else { return }
        busy = true
        Task { [weak window] in
            let found = await Task.detached(priority: .utility) {
                Result {
                    let entries = try BrowserListingSource.full(folder, archives: false)
                    return entries.compactMap { entry -> SavedUpscale? in
                        guard entry.isFile, entry.badge == SavedUpscale.badge, let date = entry.date, let size = entry.size
                        else { return nil }
                        let copy = SavedUpscale(source: entry.url, stamp: .init(modified: date, size: Int(size)))
                        return copy.replacementType == nil ? nil : copy
                    }
                }
            }.value
            busy = false
            guard let window, window.isVisible, window.attachedSheet == nil else { return }
            switch found {
            case .failure(let error):
                report("Couldn’t Read the Folder", details: error.localizedDescription, in: window)
            case .success(let copies) where copies.isEmpty:
                report("No Originals to Replace", details: "This folder has no JPEG or PNG photos with a saved upscale.", in: window)
            case .success(let copies):
                confirm(copies, in: window, folder: folder)
            }
        }
    }

    func confirm(_ copies: [SavedUpscale], in window: NSWindow, folder: URL? = nil) {
        guard !busy, let first = copies.first, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let folder {
            alert.messageText = "Replace \(copies.count) Originals?"
            alert.informativeText = "Loupe will replace the JPEG and PNG photos with saved upscales in “\(folder.lastPathComponent)”. Subfolders are excluded. A backup of every original will be kept in the hidden .loupe-upscales/Originals folder."
        } else {
            alert.messageText = "Replace Original?"
            alert.informativeText = "“\(first.source.lastPathComponent)” will be replaced by its saved upscale. A backup of the original will be kept in the hidden .loupe-upscales/Originals folder."
        }
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Replace").hasDestructiveAction = true
        busy = true
        alert.beginSheetModal(for: window) { [weak window] response in
            guard response == .alertSecondButtonReturn, let window else { self.busy = false; return }
            self.replace(copies, in: window)
        }
    }

    private func replace(_ copies: [SavedUpscale], in window: NSWindow) {
        Task { [weak window] in
            let outcome = await Task.detached(priority: .utility) {
                var completed = 0
                var firstError: String?
                for copy in copies {
                    do {
                        try autoreleasepool { try copy.replaceOriginal() }
                        completed += 1
                    } catch {
                        if firstError == nil { firstError = "\(copy.source.lastPathComponent) — \(error.localizedDescription)" }
                    }
                }
                return (completed, firstError)
            }.value
            busy = false
            guard let window, window.isVisible else { return }
            let title = outcome.0 == 1 ? "Replaced 1 Original" : "Replaced \(outcome.0) Originals"
            let details = outcome.1.map { "\(copies.count - outcome.0) could not be replaced.\n\n\($0)" }
                ?? "Originals are backed up in .loupe-upscales/Originals."
            report(title, details: details, in: window)
        }
    }

    private func report(_ title: String, details: String, in window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = details
        alert.beginSheetModal(for: window)
    }
}

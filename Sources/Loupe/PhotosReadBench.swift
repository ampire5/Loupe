import AppKit
import Photos
import LoupeCore
import LoupeRender
import HomeScreenKit
import HomeScreenModel

/// Explicit, read-only PhotoKit diagnostic. Logs timings and errors, never asset IDs, names or pixels.
@MainActor enum PhotosReadBench {
    static func run() async -> Never {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        func report(_ message: String) {
            FileHandle.standardError.write(Data(("PHOTOS_READ " + message + "\n").utf8))
        }
        func elapsed(_ start: ContinuousClock.Instant) -> Double {
            let value = start.duration(to: .now).components
            return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
        }
        if CommandLine.arguments.contains("--sort-write") || CommandLine.arguments.contains("--sort-read") {
            let suite = "local.loupe.photos-persistence-check"
            guard let defaults = UserDefaults(suiteName: suite) else { exit(1) }
            let source = PhotosLocation.collection(PhotosLocation.library)
            let sorts = PhotosSortStore(defaults: defaults)
            if CommandLine.arguments.contains("--sort-write") {
                sorts.setSort(BrowserSort(key: .name, ascending: false), for: source)
                guard defaults.synchronize() else { report("FAIL preference flush"); exit(1) }
                report("sort-write PASS")
            } else {
                guard sorts.sort(for: source) == BrowserSort(key: .name, ascending: false) else {
                    report("FAIL sort did not survive process restart"); exit(1)
                }
                defaults.removePersistentDomain(forName: suite)
                _ = defaults.synchronize()
                report("sort-read-after-restart PASS")
            }
            exit(0)
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            report("authorization=\(status.rawValue); authorize the normal Photos browser first")
            exit(3)
        }
        Task {
            try? await Task.sleep(for: .seconds(60))
            report("timeout=60s")
            exit(2)
        }
        do {
            let clock = ContinuousClock.now
            report("asset-query begin")
            let id = await Task.detached(priority: .userInitiated) {
                let options = PHFetchOptions()
                options.fetchLimit = 1
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                return PHAsset.fetchAssets(with: .image, options: options).firstObject?.localIdentifier
            }.value
            guard let id else { report("empty-library"); exit(0) }
            report("asset-query ms=\(elapsed(clock))")
            let url = PhotosLocation.assetURL(album: PhotosLocation.library, asset: id, revision: "diagnostic")
            let priority = ReadPriority(0)
            priority.isCurrent = true
            let start = ContinuousClock.now
            report("read begin")
            let bytes = try await PhotosLibrary.shared.read(url, priority: priority)
            report("read ms=\(elapsed(start)) bytes=\(bytes.data.count)")
            let probeStart = ContinuousClock.now
            let info = try await Task.detached(priority: .userInitiated) {
                try DecoderRegistry.decoder(for: bytes.data).probe(bytes.data)
            }.value
            report("probe ms=\(elapsed(probeStart)) type=\(info.typeIdentifier) size=\(info.pixelSize)")
            let metadataStart = ContinuousClock.now
            report("library-metadata begin")
            let records = try await PhotosLibrary.shared.assets(in: PhotosLocation.library)
            report("library-metadata ms=\(elapsed(metadataStart)) count=\(records.count)")
            if CommandLine.arguments.contains("--list-only") { report("PASS list-only"); exit(0) }
            let reader = PhotosReader()
            let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader)
            let thumbs = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
            let controller = ViewerWindowController(cache: cache, thumbnails: thumbs, thumbnailsReady: nil,
                positions: FolderPositions(database: nil), folderSettings: FolderSettings(database: nil), recent: nil)
            let registry = WindowRegistry()
            registry.add(controller)
            controller.showHome(tab: .recent)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            func findBrowser(_ view: NSView?) -> HomeBrowserView? {
                guard let view else { return nil }
                return (view as? HomeBrowserView) ?? view.subviews.lazy.compactMap { findBrowser($0) }.first
            }
            guard let browser = findBrowser(controller.window?.contentView), let selected = records.first(where: { $0.id == id }) else {
                report("grid missing"); exit(1)
            }
            let collection = BrowserLocation.source(PhotosLocation.collection(PhotosLocation.library))
            let selection = selected.url(in: PhotosLocation.library).absoluteString
            let gridStart = ContinuousClock.now
            browser.show(.source(PhotosLocation.collection(PhotosLocation.library)), selecting: selected.url(in: PhotosLocation.library).absoluteString)
            while browser.liveIDs.isEmpty, elapsed(gridStart) < 20_000 { try await Task.sleep(for: .milliseconds(20)) }
            report("grid ms=\(elapsed(gridStart)) ready=\(!browser.liveIDs.isEmpty)")
            guard !browser.liveIDs.isEmpty else { report("FAIL grid not ready"); exit(1) }
            let viewerStart = ContinuousClock.now
            report("viewer begin")
            guard let openEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { exit(1) }
            browser.show(collection, selecting: selection)
            _ = browser.handleKey(openEvent)
            var listed = false
            while elapsed(viewerStart) < 45_000 {
                if !listed, controller.session.playlist != nil {
                    listed = true
                    report("viewer-playlist ms=\(elapsed(viewerStart))")
                }
                if let entry = controller.session.entry {
                    if let error = entry.failure { report("viewer FAIL \(error)"); exit(1) }
                    if let pyramid = entry.pyramid, pyramid.finestResidentLevel != nil {
                        guard controller.session.playlist.map(\.current).flatMap(PhotosLocation.asset(in:)) == id else {
                            report("FAIL selected asset changed before opening"); exit(1)
                        }
                        report("viewer-ready ms=\(elapsed(viewerStart))")
                        controller.browseFolder(nil)
                        let returnStart = ContinuousClock.now
                        while browser.liveIDs.isEmpty, elapsed(returnStart) < 10_000 {
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        let repeatStart = ContinuousClock.now
                        browser.show(collection, selecting: selection)
                        _ = browser.handleKey(openEvent)
                        while controller.isShowingHome, elapsed(repeatStart) < 10_000 {
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        report("viewer-return-and-reopen ms=\(elapsed(repeatStart)) ready=\(!controller.isShowingHome)")
                        guard !controller.isShowingHome else { report("FAIL reopen did not start"); exit(1) }
                        let cold = PhotosLibrary(nameCacheURL: nil)
                        let obsolete = Task { try await cold.assets(in: PhotosLocation.library) }
                        try await Task.sleep(for: .milliseconds(100))
                        let cancellationStart = ContinuousClock.now
                        obsolete.cancel()
                        _ = await obsolete.result
                        report("bulk-cancel ms=\(elapsed(cancellationStart))")
                        let selectedStart = ContinuousClock.now
                        _ = try await cold.read(url, priority: priority)
                        report("selected-after-bulk-cancel ms=\(elapsed(selectedStart))")
                        controller.window?.close()
                        report("PASS")
                        exit(0)
                    }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            report("viewer timeout listed=\(listed) hasEntry=\(controller.session.entry != nil)")
            controller.window?.close()
            exit(2)
            exit(0)
        } catch {
            let error = error as NSError
            report("FAIL domain=\(error.domain) code=\(error.code) description=\(error.localizedDescription)")
            exit(1)
        }
    }
}

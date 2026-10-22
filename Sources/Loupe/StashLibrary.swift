import AppKit
import HomeChrome
import LoupeCore
import StashKitUI

/// Why a gallery picked in Stash did not open (Stash spec §2.2), as the bar over Stash says it.
enum StashOpenError: LocalizedError, Equatable {
    case noShare(String)
    case cannotConnect(String, String)
    case notFound(String)
    case notResponding(String)
    case noAnswer(String)

    var errorDescription: String? {
        switch self {
        case .noShare(let path): "No share for \(path)"
        case .cannotConnect(let share, let reason): "Cannot connect \(share): \(reason)"
        case .notFound(let path): "Not found: \(path)"
        case .notResponding(let path): "Not responding: \(path)"
        case .noAnswer(let reason): "Stash does not answer: \(reason)"
        }
    }
}

/// The Stash WebUI in the viewer window (Stash spec §2.1, §3.2): made on first show, kept until the window goes or
/// the address, key or path rules change. It turns a gallery click into a local folder or zip (`resolve`: the path
/// map, mounting a share when needed) and shows what went wrong in a bar over the page.
@MainActor final class StashLibrary {
    /// What it was made from: a change of any of them makes a new library.
    struct Source: Equatable {
        let url: URL
        let apiKey: String
        let rules: String

        @MainActor static var current: Source? {
            let config = Settings.shared.config
            return config.stashURL.map { Source(url: $0, apiKey: config.stashAPIKey, rules: config.stashPathMap) }
        }
    }

    let source: Source
    let client: StashClient
    /// The page and the bar over it; the window puts it over the viewer.
    let container = NSView()
    private(set) lazy var page: StashLibraryView = makePage()
    private let bar = NSTextField(labelWithString: "")
    private let barBox = ChromeGlass(style: .window, cornerRadius: Chrome.Radius.card)
    private var barTask: Task<Void, Never>?
    private let onPick: (StashGalleryPick) -> Void
    /// Shares whose mount failed lately, with why: a list step past many galleries on a switched-off PC must not wait
    /// 15 s (and maybe a sign-in dialog) for each of them.
    private var failedMounts: [String: (at: Date, reason: String)] = [:]
    private static let failedMountMemory: TimeInterval = 60

    init(source: Source, onPick: @escaping (StashGalleryPick) -> Void) {
        self.source = source
        self.onPick = onPick
        client = StashClient(baseURL: source.url, apiKey: source.apiKey)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
    }

    /// Puts the page in (once) and gives it the keys.
    func attachPage() {
        guard page.superview == nil else { return }
        page.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(page)
        barBox.translatesAutoresizingMaskIntoConstraints = false
        barBox.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.font = Chrome.Text.font(.body, weight: .medium)
        bar.textColor = Chrome.Palette.window.label
        bar.lineBreakMode = .byTruncatingMiddle
        barBox.contentView.addSubview(bar)
        container.addSubview(barBox)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            page.topAnchor.constraint(equalTo: container.topAnchor),
            page.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            barBox.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            barBox.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            barBox.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -48),
            bar.leadingAnchor.constraint(equalTo: barBox.leadingAnchor, constant: Chrome.Space.xl),
            bar.trailingAnchor.constraint(equalTo: barBox.trailingAnchor, constant: -Chrome.Space.xl),
            bar.topAnchor.constraint(equalTo: barBox.topAnchor, constant: Chrome.Space.m),
            bar.bottomAnchor.constraint(equalTo: barBox.bottomAnchor, constant: -Chrome.Space.m),
        ])
    }

    /// The bar over the page for `seconds` (nil: until the next message or `hideMessage`).
    func showMessage(_ text: String, seconds: Double? = 6) {
        barTask?.cancel()
        bar.stringValue = text
        barBox.isHidden = false
        DebugLog.log("stash: \(text)")
        guard let seconds else { return }
        barTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.barBox.isHidden = true
        }
    }

    func hideMessage() {
        barTask?.cancel()
        barBox.isHidden = true
    }

    /// The local folder or zip for a path as Stash wrote it: the path rules, then the mounted shares; a share that
    /// is not mounted is mounted (the bar says so meanwhile) and the path mapped again.
    func resolve(_ path: String) async -> Result<URL, StashOpenError> {
        for attempt in 0..<2 {
            let map = StashPathMap(mounts: SMBMount.current(), rules: StashPathRule.parse(source.rules))
            switch map.resolve(path) {
            case .local(let url):
                switch await FileCheck.exists(url, timeout: .seconds(10)) {
                case true?: return .success(url)
                case false?: return .failure(.notFound(path))
                case nil: return .failure(.notResponding(path))
                }
            case .needsMount(let smb) where attempt == 0:
                let share = smb.host.map { "\\\\\($0)\\\(smb.lastPathComponent)" } ?? smb.absoluteString
                if let failed = failedMounts[share], Date().timeIntervalSince(failed.at) < Self.failedMountMemory {
                    return .failure(.cannotConnect(share, failed.reason))
                }
                showMessage("Connecting \(share)…", seconds: nil)
                let result = await withCheckedContinuation { c in ShareMounter.mount(smb) { c.resume(returning: $0) } }
                hideMessage()
                if case .failure(let error) = result {
                    failedMounts[share] = (Date(), error.localizedDescription)
                    return .failure(.cannotConnect(share, error.localizedDescription))
                }
                failedMounts[share] = nil
            case .needsMount, .unmapped:
                return .failure(.noShare(path))
            }
        }
        return .failure(.noShare(path))
    }

    private func makePage() -> StashLibraryView {
        let view = StashLibraryView(url: source.url, interceptors: [
            .galleryOpener(interceptsNewTabClicks: true) { [weak self] pick in self?.onPick(pick) },
        ])
        var picked = false
        view.onPageLoaded = { [weak self] in
            DebugLog.log("stash page loaded")
            // `LOUPE_STASH_PICK=<gallery id>[:<list index>]` (debug): once the first page is in, a click on that gallery
            // (with the Galleries list's default variables when an index is given), to run an open without a mouse.
            guard DebugLog.isEnabled, !picked, let spec = ProcessInfo.processInfo.environment["LOUPE_STASH_PICK"] else { return }
            picked = true
            let parts = spec.split(separator: ":").map(String.init)
            var body: [String: Any] = ["type": "gallery", "id": parts[0]]
            if parts.count > 1, let index = Int(parts[1]) {
                let filter: [String: Any] = ["q": "", "page": index / 40 + 1, "per_page": 40, "sort": "path", "direction": "ASC"]
                body["list"] = ["index": index, "variables": ["filter": filter, "gallery_filter": [String: Any]()]]
            }
            if let pick = StashGalleryPick(message: body) { self?.onPick(pick) }
        }
        return view
    }
}

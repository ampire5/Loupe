import AppKit
import LoupeCore
import SwiftUI

@MainActor @Observable private final class WebImagesPageState {
    var active = false
    var searchFocus = 0
    var server = WebImagesPreferences.server
    var query = WebImagesPreferences.query
    private(set) var minimumResolution = WebImagesPreferences.minimumResolution
    var selection: WebImageEngineSelection = .serverDefaults
    var engines: [SearXNGImageEngine]?
    var engineError: String?
    var search: WebImageSearch?
    let open: (WebImageResult, WebImageSearch) -> Void

    init(open: @escaping (WebImageResult, WebImageSearch) -> Void) {
        self.open = open
        if let server { selection = WebImagesPreferences.selection(for: server) }
    }

    func refreshServer() {
        let current = WebImagesPreferences.server
        guard current != server else { return }
        invalidateSearch()
        server = current
        engines = nil
        engineError = nil
        selection = current.map { WebImagesPreferences.selection(for: $0) } ?? .serverDefaults
    }

    func discoverEngines() async {
        guard let server else { return }
        engineError = nil
        do {
            let result = try await SearXNGClient(baseURL: server).imageEngines()
            guard !Task.isCancelled, server == self.server else { return }
            engines = result
        } catch {
            guard !Task.isCancelled, server == self.server else { return }
            engineError = error.localizedDescription
        }
    }

    func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let server else { return }
        let effective: WebImageEngineSelection
        switch selection {
        case .serverDefaults: effective = .serverDefaults
        case .explicit(let saved):
            guard let engines else { return }
            let names = Set(engines.map(\.name))
            let available = saved.filter { names.contains($0) }
            guard !available.isEmpty else { return }
            effective = .explicit(available)
        }
        DebugLog.measureTurn("submit Web Images query")
        invalidateSearch()
        WebImagesPreferences.query = text
        let next = WebImageSearch(client: SearXNGClient(baseURL: server), query: text, selection: effective,
                                  minimumResolution: minimumResolution)
        search = next
        next.loadNext()
    }

    func choose(_ next: WebImageEngineSelection) {
        guard let server, selection != next else { return }
        selection = next
        WebImagesPreferences.setSelection(next, for: server)
        invalidateSearch()
    }

    func chooseMinimumResolution(_ next: WebImageMinimumResolution) {
        guard minimumResolution != next else { return }
        minimumResolution = next
        WebImagesPreferences.minimumResolution = next
        if search != nil { submit() }
    }

    func invalidateSearch() {
        search?.cancel()
        search = nil
    }
}

@MainActor final class WebImagesPage: NSView {
    private let state: WebImagesPageState
    var tabVisible = true { didSet { updateActivity() } }

    init(open: @escaping (WebImageResult, WebImageSearch) -> Void) {
        state = WebImagesPageState(open: open)
        super.init(frame: .zero)
        let content = NSHostingView(rootView: WebImagesContent(state: state))
        content.sizingOptions = []
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self, window?.firstResponder === self, !isHiddenOrHasHiddenAncestor else { return }
            state.searchFocus += 1
        }
        return true
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateActivity() }
    override func viewDidHide() { super.viewDidHide(); updateActivity() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateActivity() }

    func preferencesChanged() { state.refreshServer() }

    private func updateActivity() {
        let active = window != nil && tabVisible && !isHiddenOrHasHiddenAncestor
        guard active != state.active else { return }
        if !active { state.search?.cancel() }
        state.active = active
    }
}

private struct WebImagesContent: View {
    let state: WebImagesPageState
    @FocusState private var searchFocused: Bool
    @State private var discoveryRetry = 0
    @AppStorage("webImages.thumbnailSize") private var thumbnailSize = WebImageThumbnailSize.medium
    @AppStorage("webImages.showCaptions") private var showCaptions = true

    private var selected: [String] {
        if case .explicit(let names) = state.selection { return names }
        return []
    }

    private var unavailable: [String] {
        guard let engines = state.engines else { return [] }
        let known = Set(engines.map(\.name))
        return selected.filter { !known.contains($0) }
    }

    private var canSearch: Bool {
        guard state.server != nil, !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return state.selection == .serverDefaults || (state.engines != nil && selected.count > unavailable.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Search images", text: Binding(get: { state.query }, set: { text, _ in
                    guard state.query != text else { return }
                    state.query = text
                    state.invalidateSearch()
                }))
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onChange(of: state.searchFocus) { _, _ in searchFocused = true }
                .onSubmit { if canSearch { state.submit() } }
                engineMenu
                resolutionMenu
                viewMenu
                Button("Search", action: state.submit).disabled(!canSearch)
            }
            .padding(12)
            if let error = state.engineError {
                HStack {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry Engines") { discoveryRetry += 1 }
                }.padding(.horizontal, 12)
            }
            if !unavailable.isEmpty {
                Text("Unavailable engines: \(unavailable.joined(separator: ", "))")
                    .foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            Divider()
            if let search = state.search {
                results(search).id(search.id)
            } else {
                ContentUnavailableView(state.server == nil ? "Set a SearXNG server in Settings" : "Search for images",
                                       systemImage: "photo")
            }
        }
        .task(id: Discovery(server: state.active ? state.server : nil, retry: discoveryRetry)) {
            guard state.active, state.engines == nil else { return }
            await state.discoverEngines()
        }
    }

    private struct Discovery: Equatable {
        var server: URL?
        var retry: Int
    }

    private var engineMenu: some View {
        Menu {
            Toggle("Server Defaults", isOn: Binding(get: { state.selection == .serverDefaults },
                                                     set: { enabled, _ in if enabled { state.choose(.serverDefaults) } }))
            if let engines = state.engines, !engines.isEmpty {
                Divider()
                ForEach(engines, id: \.name) { engine in
                    Toggle(engine.name, isOn: Binding(get: { selected.contains(engine.name) }, set: { enabled, _ in
                        var names = selected.filter { $0 != engine.name }
                        if enabled { names.append(engine.name) }
                        state.choose(names.isEmpty ? .serverDefaults : .explicit(names))
                    }))
                }
            }
        } label: {
            Text(state.selection == .serverDefaults ? "Server Defaults" : "Engines (\(selected.count))")
        }
        .fixedSize()
    }

    private var resolutionMenu: some View {
        Menu {
            Picker("Minimum resolution", selection: Binding(get: { state.minimumResolution },
                                                            set: { value, _ in state.chooseMinimumResolution(value) })) {
                ForEach(WebImageMinimumResolution.allCases, id: \.self) { resolution in
                    Text(resolution.title).tag(resolution)
                }
            }
        } label: {
            Text(state.minimumResolution == .any ? "Resolution" : state.minimumResolution.title)
        }
        .fixedSize()
        .accessibilityLabel("Minimum resolution")
        .accessibilityValue(state.minimumResolution.title)
    }

    private var viewMenu: some View {
        Menu("View") {
            Picker("Thumbnail size", selection: $thumbnailSize) {
                ForEach(WebImageThumbnailSize.allCases, id: \.self) { size in
                    Text(size.title).tag(size)
                }
            }
            Toggle("Show Captions", isOn: $showCaptions)
        }
        .fixedSize()
        .accessibilityLabel("Image grid options")
    }

    private func results(_ search: WebImageSearch) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize.width), spacing: 10)], spacing: 12) {
                ForEach(search.results) { result in
                    Button { state.open(result, search) } label: {
                        WebImageCard(result: result, active: state.active,
                                     thumbnailHeight: thumbnailSize.height, showCaptions: showCaptions)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(result.displayTitle)
                    .accessibilityValue(result.displayResolution ?? "")
                    .onAppear {
                        if state.active, search.results.suffix(3).contains(where: { $0.id == result.id }) {
                            search.loadNext()
                        }
                    }
                }
            }
            if search.loading {
                ProgressView().controlSize(.small).padding()
            } else if let error = search.error {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Retry") { search.loadNext(retry: true) }.padding(.bottom, 10)
            } else {
                if search.results.isEmpty {
                    if search.minimumResolution == .any {
                        ContentUnavailableView("No images found", systemImage: "photo")
                    } else {
                        ContentUnavailableView("No images at this resolution", systemImage: "photo",
                                               description: Text("Results without a reported resolution are hidden."))
                    }
                }
                if search.hasMore {
                    Button("Load More") { search.loadNext() }.padding(.vertical, 10)
                }
            }
            if search.error == nil, !search.engineErrors.isEmpty {
                Text(search.engineErrors.joined(separator: "\n"))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12)
        .onChange(of: state.active) { _, active in
            if active, !search.hasLoadedPage { search.loadNext() }
        }
    }
}

private extension WebImageMinimumResolution {
    var title: String {
        switch self {
        case .any: "Any resolution"
        case .hd: "720p or larger"
        case .fullHD: "1080p or larger"
        case .ultraHD: "4K or larger"
        }
    }
}

private enum WebImageThumbnailSize: String, CaseIterable {
    case small, medium, large, huge

    var width: CGFloat {
        switch self {
        case .small: 100
        case .medium: 155
        case .large: 240
        case .huge: 360
        }
    }

    var height: CGFloat { (width * 125 / 155).rounded() }

    var title: String { rawValue.capitalized }
}

private struct WebImageCard: View {
    let result: WebImageResult
    let active: Bool
    let thumbnailHeight: CGFloat
    let showCaptions: Bool
    @State private var preview: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                if let preview {
                    Image(decorative: preview, scale: 1).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(height: thumbnailHeight)
            .clipShape(.rect(cornerRadius: 5))
            if showCaptions {
                Text(result.displayTitle).lineLimit(1)
                if let resolution = result.displayResolution {
                    Text(verbatim: resolution).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .task(id: active, priority: .utility) {
            guard active, preview == nil, let url = result.thumbnailURL else { return }
            let loaded = try? await WebImageFiles.preview(url)
            if !Task.isCancelled { preview = loaded }
        }
        .onDisappear { preview = nil }
    }
}

private extension WebImageResult {
    var displayTitle: String {
        title.isEmpty ? (sourceURL?.host ?? originalURL.lastPathComponent) : title
    }

    var displayResolution: String? {
        resolution.map { "\($0.width) × \($0.height)" }
    }
}

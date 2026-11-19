import AppKit
import LoupeCore
import SettingsKit
import SwiftUI

extension SettingsPanel {
    static let webImages = SettingsPage("web-images", "Web Images", symbol: "photo.badge.magnifyingglass", sections: [
        SettingsSection("SearXNG", rows: [
            .custom("Web Images", searchTexts: { ["Web Images", "SearXNG", "Test Connection", "Save Originals", "Preload neighboring originals", "Original prefetch depth", "Concurrent original downloads"] }) {
                WebImagesSettings()
            },
        ]),
    ])
}

private struct WebImagesSettings: View {
    @State private var address = WebImagesPreferences.server?.absoluteString ?? ""
    @State private var folder = WebImagesPreferences.saveFolder
    @State private var status = ""
    @State private var preloadOriginals = WebImagesPreferences.preloadOriginals
    @State private var originalPrefetchDepth = WebImagesPreferences.originalPrefetchDepth
    @State private var originalPrefetchConcurrency = WebImagesPreferences.originalPrefetchConcurrency
    @State private var connectionCheck: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Server address", text: $address, prompt: Text(WebImagesPreferences.suggestedServer))
                .onSubmit(applyAddress)
                .onChange(of: address) { _, _ in
                    connectionCheck?.cancel()
                    connectionCheck = nil
                    status = ""
                }
            HStack {
                Button("Apply", action: applyAddress)
                Button("Test Connection", action: testConnection).disabled(connectionCheck != nil)
            }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Save originals to")
                    Text(folder?.path(percentEncoded: false) ?? "Choose a folder")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Choose…", action: chooseFolder)
            }
            Divider()
            Toggle("Preload neighboring originals", isOn: $preloadOriginals)
                .onChange(of: preloadOriginals) { _, enabled in WebImagesPreferences.preloadOriginals = enabled }
            Stepper(value: $originalPrefetchDepth, in: WebImagesPreferences.originalPrefetchDepthRange) {
                Text("Original prefetch depth: \(originalPrefetchDepth) per direction")
            }
            .disabled(!preloadOriginals)
            .onChange(of: originalPrefetchDepth) { _, depth in WebImagesPreferences.originalPrefetchDepth = depth }
            Stepper(value: $originalPrefetchConcurrency, in: WebImagesPreferences.originalPrefetchConcurrencyRange) {
                Text("Concurrent original downloads: \(originalPrefetchConcurrency)")
            }
            .disabled(!preloadOriginals)
            .onChange(of: originalPrefetchConcurrency) { _, concurrency in
                WebImagesPreferences.originalPrefetchConcurrency = concurrency
            }
            Text("Download neighboring originals in the background while viewing an image.")
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .onDisappear { connectionCheck?.cancel(); connectionCheck = nil }
    }

    private func applyAddress() {
        let empty = address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let server = SearXNGClient.serverURL(address)
        guard empty || server != nil else {
            status = SearXNGClient.RequestError.invalidServer.localizedDescription
            return
        }
        WebImagesPreferences.setServer(server)
        status = empty ? "Web Images removed from Home." : "Server saved."
    }

    private func testConnection() {
        guard let server = SearXNGClient.serverURL(address) else {
            status = SearXNGClient.RequestError.invalidServer.localizedDescription
            return
        }
        status = "Checking connection…"
        connectionCheck = Task {
            let client = SearXNGClient(baseURL: server)
            do {
                let engines = try await client.imageEngines()
                _ = try await client.searchImages(query: "fox", selection: .serverDefaults, page: 1)
                guard !Task.isCancelled else { return }
                status = "Connected. SearXNG advertises \(engines.count) image engines."
            } catch {
                guard !Task.isCancelled else { return }
                status = error.localizedDescription
            }
            connectionCheck = nil
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            WebImagesPreferences.setSaveFolder(url)
            folder = url
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
}

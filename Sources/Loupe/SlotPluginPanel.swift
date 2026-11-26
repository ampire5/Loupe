import AppKit
import CoreFoundation
import LoupeCore
import WebKit

enum SlotPluginScope: String {
    case viewer, fileView
}

struct SlotPluginAction: Equatable {
    let name: String
    let label: String
    let scope: SlotPluginScope

    init?(_ fields: [String: Any]) {
        guard let name = fields["name"] as? String, (1...32).contains(name.utf8.count),
              name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let label = fields["label"] as? String, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.count <= 60, !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let value = fields["scope"] as? String, let scope = SlotPluginScope(rawValue: value) else { return nil }
        self.name = name
        self.label = label
        self.scope = scope
    }
}

struct SlotPluginItem {
    let path: String
    let name: String
    let kind: String

    init(url: URL, name: String, kind: String) {
        self.path = kind == "file" ? ArchivePath.copyText(url) : url.path
        self.name = name
        self.kind = kind
    }

    var payload: [String: String] { ["path": path, "name": name, "kind": kind] }
}

/// An assigned slot retains its page and actions when hidden. Only a committed replacement page can declare actions.
@MainActor final class SlotPluginPanel: NSView, WKNavigationDelegate {
    private let web: WKWebView
    private let plugin: SlotPluginConfiguration
    private let origin: SlotPluginOrigin
    private let handler = SlotPluginMessageHandler()
    private let reloadButton = NSButton(title: "Reload Plugin", target: nil, action: nil)
    private var document: String?
    private var committed = false
    private(set) var isTyping = false
    private var reloadedAfterTermination = false
    private var pending: (id: String, action: SlotPluginAction, expiry: Task<Void, Never>)?
    private(set) var actions: [SlotPluginAction] = []
    var onMessage: ((String) -> Void)?

    init(plugin: SlotPluginConfiguration) {
        self.plugin = plugin
        self.origin = plugin.origin
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(handler, contentWorld: .page, name: "loupe")
        config.userContentController.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        self.web = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web)
        reloadButton.target = self
        reloadButton.action = #selector(reloadPressed)
        reloadButton.bezelStyle = .rounded
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.isHidden = true
        addSubview(reloadButton)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: leadingAnchor), web.trailingAnchor.constraint(equalTo: trailingAnchor),
            web.topAnchor.constraint(equalTo: topAnchor), web.bottomAnchor.constraint(equalTo: bottomAnchor),
            reloadButton.centerXAnchor.constraint(equalTo: centerXAnchor), reloadButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        handler.panel = self
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func focusPage() {
        window?.makeFirstResponder(reloadButton.isHidden ? web : reloadButton)
    }

    @objc private func reloadPressed() { reload() }

    func reload() {
        reloadButton.isHidden = true
        reloadedAfterTermination = false
        web.load(URLRequest(url: plugin.url))
    }

    func stop() {
        clearDocument()
        web.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "loupe", contentWorld: .page)
    }

    func invoke(_ action: SlotPluginAction, items: [SlotPluginItem]) {
        guard let document, actions.contains(action), !items.isEmpty else { return }
        guard pending == nil else {
            onMessage?("\(plugin.name) is already running an action")
            return
        }
        let id = UUID().uuidString
        let detail: [String: Any] = ["id": id, "name": action.name, "scope": action.scope.rawValue, "items": items.map(\.payload)]
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.finish(id: id, message: "\(action.label) timed out")
        }
        pending = (id, action, expiry)
        web.callAsyncJavaScript("return window.loupe?._dispatch(documentToken, detail) === true",
                                arguments: ["documentToken": document, "detail": detail], in: nil, in: .page) { [weak self] result in
            guard (try? result.get() as? Bool) != true else { return }
            self?.finish(id: id, message: "\(action.label) could not reach the plugin")
        }
    }

    fileprivate func receive(_ message: WKScriptMessage) -> String? {
        let frame = message.frameInfo
        let security = frame.securityOrigin
        guard committed, message.webView === web, frame.isMainFrame,
              security.protocol == "https", security.host.lowercased() == origin.host,
              (security.port == 0 ? 443 : security.port) == origin.port,
              let url = frame.request.url, SlotPluginOrigin(url) == origin,
              let fields = message.body as? [String: Any],
              let document = fields["document"] as? String, UUID(uuidString: document) != nil,
              self.document == nil || self.document == document,
              let command = fields["command"] as? String else { return "Untrusted plugin document" }
        switch command {
        case "actions":
            guard let raw = fields["actions"] as? [[String: Any]], raw.count <= 64 else { return "Expected up to 64 actions" }
            let parsed = raw.compactMap(SlotPluginAction.init)
            guard parsed.count == raw.count, Set(parsed.map(\.name)).count == parsed.count else {
                return "Each action needs a unique name, label and valid scope"
            }
            self.document = document
            actions = parsed
        case "editing":
            isTyping = fields["editing"] as? Bool == true
        case "openExternal":
            guard let address = fields["url"] as? String, let destination = URL(string: address),
                  SlotPluginOrigin(destination) == origin else { return "Expected an HTTPS URL on the plugin origin" }
            guard NSWorkspace.shared.open(destination) else { return "The browser could not open this address" }
        case "complete":
            guard let id = fields["id"] as? String, let pending, pending.id == id,
                  let result = fields["result"] as? [String: Any],
                  let ok = result["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID() else {
                return "Expected a pending action and an outcome"
            }
            let supplied = (result["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = pending.action.label + (ok.boolValue ? " completed" : " failed")
            finish(id: id, message: supplied.flatMap { $0.isEmpty ? nil : String($0.prefix(500)) } ?? fallback)
        default:
            return "Unknown plugin command"
        }
        return nil
    }

    private func finish(id: String, message: String) {
        guard let pending, pending.id == id else { return }
        pending.expiry.cancel()
        self.pending = nil
        onMessage?(message)
    }

    private func clearDocument() {
        committed = false
        isTyping = false
        document = nil
        actions.removeAll()
        if let pending { finish(id: pending.id, message: "\(pending.action.label) was interrupted") }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }
        guard let url = action.request.url, SlotPluginOrigin(url) == origin else {
            decisionHandler(.cancel)
            return
        }
        if action.targetFrame == nil {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        clearDocument()
        committed = true
        reloadButton.isHidden = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if !committed, (error as NSError).code != NSURLErrorCancelled { reloadButton.isHidden = false }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        clearDocument()
        if reloadedAfterTermination {
            reloadButton.isHidden = false
        } else {
            reloadedAfterTermination = true
            webView.load(URLRequest(url: plugin.url))
        }
    }

    private static let bridgeScript = """
    (() => {
      if (location.protocol !== 'https:') return;
      const documentToken = crypto.randomUUID();
      const post = (command, args) => window.webkit.messageHandlers.loupe
          .postMessage({command, document: documentToken, ...args});
      const nonEditingInput = new Set(['button', 'checkbox', 'color', 'file', 'image', 'radio', 'range', 'reset', 'submit']);
      let editing = false;
      const focusChanged = () => {
        let element = document.activeElement;
        while (element?.shadowRoot?.activeElement) element = element.shadowRoot.activeElement;
        const next = !!element && (element.isContentEditable || element.matches('textarea, select, iframe')
            || (element.matches('input') && !nonEditingInput.has(element.type)));
        if (next === editing) return;
        editing = next;
        post('editing', {editing}).catch(() => {});
      };
      window.addEventListener('focusin', focusChanged);
      window.addEventListener('focusout', () => queueMicrotask(focusChanged));
      Object.defineProperty(window, 'loupe', {value: Object.freeze({
        version: 1,
        actions: actions => post('actions', {actions}),
        openExternal: url => post('openExternal', {url: new URL(url, location.href).href}),
        complete: (id, result) => post('complete', {id, result}),
        _dispatch: (token, detail) => {
          if (token !== documentToken) return false;
          window.dispatchEvent(new CustomEvent('loupeaction', {detail}));
          return true;
        }
      })});
    })();
    """
}

// The content controller retains its message handler. The handler holds no retain cycle with the web view.
@MainActor private final class SlotPluginMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var panel: SlotPluginPanel?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let panel else {
            replyHandler(nil, "This plugin slot is closed")
            return
        }
        replyHandler(nil, panel.receive(message))
    }
}

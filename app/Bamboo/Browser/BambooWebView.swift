import AppKit
import WebKit

/// The web view used by every tab. A subclass so the browser can customise the
/// context menu and other AppKit behaviour.
final class BambooWebView: WKWebView {
    weak var tab: Tab?

    /// WebKit's identifiers for its own context menu items.
    private enum MenuItemID {
        static let openInNewWindow: Set<String> = [
            "WKMenuItemIdentifierOpenLinkInNewWindow",
            "WKMenuItemIdentifierOpenImageInNewWindow",
            "WKMenuItemIdentifierOpenMediaInNewWindow",
            "WKMenuItemIdentifierOpenFrameInNewWindow",
        ]
        static let copy = "WKMenuItemIdentifierCopy"
        static let lookUp = "WKMenuItemIdentifierLookUp"
    }

    private static let selectionWorld = WKContentWorld.world(name: "BambooContextMenu")
    private static let maxQuotedLength = 40

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            guard let id = item.identifier?.rawValue, MenuItemID.openInNewWindow.contains(id) else { continue }
            // WebKit opens these through createWebView, which Bamboo turns into a tab.
            item.title = item.title.replacingOccurrences(of: "New Window", with: "New Tab")
        }

        // WebKit offers Copy only when text is selected.
        guard tab != nil,
              let copyIndex = menu.items.firstIndex(where: { $0.identifier?.rawValue == MenuItemID.copy })
        else { return }
        let ask = NSMenuItem(title: askClaudeTitle(menu), action: #selector(askClaudeAboutSelection(_:)), keyEquivalent: "")
        ask.target = self
        ask.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)
        menu.insertItem(ask, at: copyIndex)
        menu.insertItem(.separator(), at: copyIndex + 1)
    }

    /// "Ask Claude about “…”", quoting the selection the way WebKit's Look Up item does.
    private func askClaudeTitle(_ menu: NSMenu) -> String {
        if let lookUp = menu.items.first(where: { $0.identifier?.rawValue == MenuItemID.lookUp }),
           let open = lookUp.title.firstIndex(of: "“"), let close = lookUp.title.lastIndex(of: "”"), open < close {
            var quoted = String(lookUp.title[lookUp.title.index(after: open)..<close])
            if quoted.count > Self.maxQuotedLength {
                quoted = String(quoted.prefix(Self.maxQuotedLength)) + "…"
            }
            return "Ask Claude about “\(quoted)”"
        }
        return "Ask Claude about Selection"
    }

    @objc private func askClaudeAboutSelection(_ sender: NSMenuItem) {
        guard let tab, let window = AppServices.shared.windows.windowModel(containing: tab) else { return }
        Task {
            let selection: String
            do {
                selection = try await evaluateJavaScript("getSelection().toString()", in: nil, contentWorld: Self.selectionWorld) as? String ?? ""
            } catch {
                AppServices.shared.reportNonFatal(error, "Reading the selection for Claude")
                return
            }
            let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let page = tab.title.isEmpty ? (tab.url?.host() ?? "this page") : tab.title
            window.pendingAssistantPrompt = "From “\(page)”:\n\n\(text)\n\nExplain this."
            window.isAssistantVisible = true
        }
    }
}

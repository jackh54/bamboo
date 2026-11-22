import AppKit
import SwiftUI
import WebKit

/// One browser window. Menu commands reach it through the responder chain
/// (menu items have a nil target), so they always act on the key window.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: BrowserWindowModel

    init(model: BrowserWindowModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.title = model.isPrivate ? "Private Browsing" : "Bamboo"
        window.contentView = NSHostingView(rootView: BrowserWindowView(model: model))
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrowserWindowController is created in code")
    }

    private var windows: WindowManager { AppServices.shared.windows }
    private var tab: Tab? { model.selectedTab }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        windows.windowDidBecomeKey(self)
    }

    func windowWillClose(_ notification: Notification) {
        windows.windowWillClose(self)
    }

    func windowDidMove(_ notification: Notification) {
        windows.sessionDidChange()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        windows.sessionDidChange()
    }

    // MARK: - Tabs

    @objc func newTab(_ sender: Any?) {
        model.newTab()
        model.addressBarFocusRequest += 1
    }

    @objc func closeTab(_ sender: Any?) {
        if let tab {
            model.close(tab)
        } else {
            window?.performClose(sender)
        }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        model.reopenLastClosedTab()
    }

    @objc func openLocation(_ sender: Any?) {
        model.addressBarFocusRequest += 1
    }

    @objc func selectNextTab(_ sender: Any?) {
        model.selectAdjacentTab(offset: 1)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        model.selectAdjacentTab(offset: -1)
    }

    /// Menu items ⌘1…⌘9 carry their index in `tag`.
    @objc func selectTabByIndex(_ sender: NSMenuItem) {
        model.selectTab(atShortcutIndex: sender.tag)
    }

    @objc func togglePinTab(_ sender: Any?) {
        if let tab { model.togglePin(tab) }
    }

    @objc func duplicateTab(_ sender: Any?) {
        if let tab { model.duplicate(tab) }
    }

    @objc func toggleAgentControl(_ sender: Any?) {
        guard let tab, !tab.isPrivate else { return }
        tab.isAgentControlled.toggle()
    }

    // MARK: - Navigation

    @objc func goBack(_ sender: Any?) { tab?.goBack() }
    @objc func goForward(_ sender: Any?) { tab?.goForward() }
    @objc func reloadPage(_ sender: Any?) { tab?.reload() }
    @objc func reloadFromOrigin(_ sender: Any?) { tab?.reload(fromOrigin: true) }
    @objc func stopLoading(_ sender: Any?) { tab?.stopLoading() }

    @objc func copyPageURL(_ sender: Any?) {
        guard let url = tab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    // MARK: - Page

    @objc func zoomIn(_ sender: Any?) { setZoom { $0 + 0.1 } }
    @objc func zoomOut(_ sender: Any?) { setZoom { $0 - 0.1 } }
    @objc func actualSize(_ sender: Any?) { setZoom { _ in 1 } }

    private func setZoom(_ change: (Double) -> Double) {
        guard let webView = tab?.webView else { return }
        webView.pageZoom = min(max(change(webView.pageZoom), 0.3), 3)
    }

    @objc func printPage(_ sender: Any?) {
        guard let webView = tab?.webView, let window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func showFindBar(_ sender: Any?) {
        model.isFindBarVisible = true
    }

    @objc func findNext(_ sender: Any?) { find(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(backwards: true) }

    /// Steps through matches of `model.findQuery`, which the find bar edits.
    func find(backwards: Bool) {
        guard let webView = tab?.webView, !model.findQuery.isEmpty else {
            model.isFindBarVisible = true
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        let query = model.findQuery
        Task {
            do {
                let result = try await webView.find(query, configuration: configuration)
                model.findQueryMatched = result.matchFound
            } catch {
                AppServices.shared.reportNonFatal(error, "Find in page")
            }
        }
    }

    @objc func toggleReader(_ sender: Any?) {
        tab?.isReaderActive.toggle()
    }

    /// Opens WebKit's inspector through its private `_inspector` object; the
    /// menu item is disabled unless developer tools are on in Settings.
    @objc func showWebInspector(_ sender: Any?) {
        let inspectorSelector = NSSelectorFromString("_inspector")
        let showSelector = NSSelectorFromString("show")
        guard let webView = tab?.webView, webView.responds(to: inspectorSelector),
              let inspector = webView.perform(inspectorSelector)?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: showSelector)
        else {
            NSSound.beep()
            return
        }
        inspector.perform(showSelector)
    }

    // MARK: - Panels

    @objc func toggleBrowserSidebar(_ sender: Any?) {
        withAnimation(.snappy) { model.isSidebarVisible.toggle() }
    }

    @objc func toggleAssistant(_ sender: Any?) {
        withAnimation(.snappy) { model.isAssistantVisible.toggle() }
    }

    @objc func showCommandPalette(_ sender: Any?) {
        model.isCommandPaletteVisible = true
    }

    @objc func showHistory(_ sender: Any?) { model.libraryPanel = .history }
    @objc func showBookmarks(_ sender: Any?) { model.libraryPanel = .bookmarks }
    @objc func showDownloads(_ sender: Any?) { model.libraryPanel = .downloads }

    @objc func bookmarkPage(_ sender: Any?) {
        guard let tab, let url = tab.url else { return }
        let store = tab.profile.store
        do {
            if let existing = try store.bookmarksForUrl(url: url.absoluteString).first {
                try store.deleteBookmark(id: existing.id)
            } else {
                _ = try store.addBookmark(parentId: nil, title: tab.title.isEmpty ? url.absoluteString : tab.title, url: url.absoluteString)
            }
        } catch {
            presentError(error)
        }
    }

    // MARK: - Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return tab?.canGoBack ?? false
        case #selector(goForward(_:)): return tab?.canGoForward ?? false
        case #selector(reopenClosedTab(_:)): return model.canReopenClosedTab
        case #selector(togglePinTab(_:)):
            menuItem.title = tab?.isPinned == true ? "Unpin Tab" : "Pin Tab"
            return tab != nil
        case #selector(toggleAgentControl(_:)):
            menuItem.title = tab?.isAgentControlled == true ? "Take Tab Back from Agents" : "Let Agents Control This Tab"
            return tab.map { !$0.isPrivate && $0.url != nil } ?? false
        case #selector(toggleBrowserSidebar(_:)):
            menuItem.title = model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            return true
        case #selector(toggleAssistant(_:)):
            menuItem.title = model.isAssistantVisible ? "Hide Claude" : "Ask Claude"
            return true
        case #selector(showWebInspector(_:)):
            return tab?.webView != nil && AppServices.shared.settings.developerToolsEnabled
        case #selector(toggleReader(_:)):
            menuItem.title = tab?.isReaderActive == true ? "Hide Reader" : "Show Reader"
            return tab?.url != nil
        case #selector(reloadPage(_:)), #selector(reloadFromOrigin(_:)), #selector(stopLoading(_:)),
             #selector(copyPageURL(_:)), #selector(printPage(_:)), #selector(showFindBar(_:)),
             #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)),
             #selector(findNext(_:)), #selector(findPrevious(_:)),
             #selector(duplicateTab(_:)), #selector(bookmarkPage(_:)):
            return tab?.url != nil
        default:
            return true
        }
    }
}

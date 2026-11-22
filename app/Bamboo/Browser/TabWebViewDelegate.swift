import AppKit
import WebKit

/// Navigation and UI delegate for one tab's web view. Handles behaviour every
/// browser needs and forwards the rest to the registered `TabExtension`s.
@MainActor
final class TabWebViewDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private unowned let tab: Tab

    /// WKNavigationAction.buttonNumber uses NSEvent button masks: 1 left, 2 right, 4 middle.
    private static let middleMouseButton = 4

    init(tab: Tab) {
        self.tab = tab
    }

    private var extensions: [any TabExtension] { AppServices.shared.tabExtensions }
    private var window: BrowserWindowModel? { AppServices.shared.windows.windowModel(containing: tab) }

    // MARK: - Navigation policy

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload {
            return (.download, preferences)
        }

        let opensNewTab = navigationAction.modifierFlags.contains(.command)
            || navigationAction.buttonNumber == Self.middleMouseButton
        if navigationAction.navigationType == .linkActivated, opensNewTab,
           let url = navigationAction.request.url, let window {
            let select = navigationAction.modifierFlags.contains(.shift)
            window.newTab(url: url, after: tab, select: select)
            return (.cancel, preferences)
        }

        for tabExtension in extensions {
            switch await tabExtension.decidePolicy(for: navigationAction, preferences: preferences, in: tab) {
            case .allow:
                continue
            case .cancel:
                return (.cancel, preferences)
            case .redirect(let url):
                webView.load(URLRequest(url: url))
                return (.cancel, preferences)
            }
        }
        return (.allow, preferences)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if !navigationResponse.canShowMIMEType {
            return .download
        }
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        AppServices.shared.downloads.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        AppServices.shared.downloads.track(download)
    }

    /// WebKit's private callback for content blocker actions (WKNavigationDelegatePrivate),
    /// the one Safari's tracker count uses. Blocked requests never reach the page, so this
    /// is the only exact count. `action` is a `_WKContentRuleListAction`.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String, performedAction action: NSObject, for url: URL) {
        guard identifier.hasPrefix(ShieldsManager.ruleListPrefix),
              action.responds(to: NSSelectorFromString("blockedLoad")),
              action.value(forKey: "blockedLoad") as? Bool == true
        else { return }
        AppServices.shared.shields.recordBlockedLoad(of: url, in: tab)
    }

    // MARK: - Navigation progress

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab.navigationStarted()
        extensions.forEach { $0.didStartNavigation(in: tab) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        extensions.forEach { $0.didCommitNavigation(in: tab) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        extensions.forEach { $0.didFinishNavigation(in: tab) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error, url: webView.url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let failingURL = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
        navigationFailed(error, url: failingURL)
    }

    private func navigationFailed(_ error: Error, url: URL?) {
        let nsError = error as NSError
        // Cancelled loads and loads turned into downloads are not failures.
        let isCancellation = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        let isPolicyChange = nsError.domain == "WebKitErrorDomain" && nsError.code == 102
        guard !isCancellation, !isPolicyChange else { return }
        tab.navigationFailed(PageLoadError(
            url: url, domain: nsError.domain, code: nsError.code, message: nsError.localizedDescription))
        extensions.forEach { $0.didFailNavigation(in: tab, error: error) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tab.webContentProcessDidTerminate()
        if window?.selectedTab === tab {
            tab.reload()
        }
    }

    func webView(
        _ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
              challenge.previousFailureCount < 3, let hostWindow = webView.window
        else { return (.performDefaultHandling, nil) }

        let alert = NSAlert()
        alert.messageText = "Sign in to \(challenge.protectionSpace.host)"
        alert.informativeText = challenge.protectionSpace.realm.map { "The site says: “\($0)”" } ?? ""
        let username = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        username.placeholderString = "Username"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "Password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(username)
        fields.addSubview(password)
        alert.accessoryView = fields
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = username

        let response = await alert.beginSheetModal(for: hostWindow)
        guard response == .alertFirstButtonReturn else { return (.cancelAuthenticationChallenge, nil) }
        let credential = URLCredential(user: username.stringValue, password: password.stringValue, persistence: .forSession)
        return (.useCredential, credential)
    }

    // MARK: - Windows and dialogs

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let window else { return nil }
        let popup = Tab(popupConfiguration: configuration, opener: tab)
        window.insert(popup, after: tab, select: true)
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        window?.close(tab)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        _ = await presentDialog(.alert, message: message, frame: frame)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        await presentDialog(.confirm, message: message, frame: frame).accepted
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?, initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let response = await presentDialog(.prompt(defaultText: defaultText ?? ""), message: prompt, frame: frame)
        return response.accepted ? (response.text ?? "") : nil
    }

    private func presentDialog(_ kind: JavaScriptDialog.Kind, message: String, frame: WKFrameInfo) async -> JavaScriptDialog.Response {
        // A page that opens a dialog while another is pending gets an immediate dismissal.
        guard tab.pendingDialog == nil else { return JavaScriptDialog.Response(accepted: false, text: nil) }
        let origin = frame.securityOrigin.host
        let response = await withCheckedContinuation { continuation in
            tab.pendingDialog = JavaScriptDialog(kind: kind, message: message, origin: origin, continuation: continuation)
        }
        tab.pendingDialog = nil
        return response
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let hostWindow = webView.window else { return nil }
        return await panel.beginSheetModal(for: hostWindow) == .OK ? panel.urls : nil
    }

    func webView(
        _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        for tabExtension in extensions {
            if let decision = await tabExtension.mediaCapturePermission(for: origin, type: type, in: tab) {
                return decision
            }
        }
        return .prompt
    }
}

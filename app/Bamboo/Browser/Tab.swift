import AppKit
import Observation
import WebKit

struct PageLoadError: Equatable, Sendable {
    var url: URL?
    var domain: String
    var code: Int
    var message: String
}

struct PasswordSaveOffer: Equatable, Sendable {
    var host: String
    var username: String
    var password: String
}

/// What session restore saves for a tab.
struct TabSessionState: Codable, Sendable {
    var id: UUID
    var url: URL?
    var title: String
    var isPinned: Bool
    /// `WKWebView.interactionState`: back/forward history and scroll position.
    var interactionState: Data?
}

/// One browser tab. The web view is created lazily and can be dropped to free
/// memory ("hibernation"); `interactionState` keeps the back/forward history so
/// the tab comes back where it was.
@MainActor
@Observable
final class Tab: Identifiable {
    let id: UUID
    let profile: Profile
    let isPrivate: Bool
    @ObservationIgnored let dataStore: WKWebsiteDataStore

    private(set) var url: URL?
    private(set) var title: String
    var favicon: NSImage?
    private(set) var isLoading = false
    private(set) var estimatedProgress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var hasOnlySecureContent = false
    /// The page's web content process died; the UI offers a reload.
    var webContentProcessCrashed = false
    var isPinned = false
    /// Opened by an AI agent, or handed over to agents by the user.
    var isAgentControlled = false
    var lastActivatedAt = Date.now
    /// Requests shields matched on the current page and the hosts they went to.
    var blockedRequestCount = 0
    var blockedHosts: Set<String> = []
    /// Image of the page taken when it hibernated, shown until it reloads.
    var hibernationSnapshot: NSImage?
    /// Showing the page in Reader (article text only).
    var isReaderActive = false
    /// A JavaScript dialog the page is waiting on, rendered over the page.
    var pendingDialog: JavaScriptDialog?
    /// Credentials the page just submitted that the user hasn't saved yet.
    var passwordSaveOffer: PasswordSaveOffer?
    /// Why the last main-frame load failed; cleared when the next one starts.
    var loadError: PageLoadError?

    private(set) var webView: WKWebView?

    @ObservationIgnored private var pendingPopupConfiguration: WKWebViewConfiguration?
    @ObservationIgnored private var restorationState: Data?
    @ObservationIgnored private var delegate: TabWebViewDelegate?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(profile: Profile, isPrivate: Bool, dataStore: WKWebsiteDataStore, url: URL?) {
        id = UUID()
        self.profile = profile
        self.isPrivate = isPrivate
        self.dataStore = dataStore
        self.url = url
        title = ""
    }

    init(restoring state: TabSessionState, profile: Profile, dataStore: WKWebsiteDataStore) {
        id = state.id
        self.profile = profile
        isPrivate = false
        self.dataStore = dataStore
        url = state.url
        title = state.title
        isPinned = state.isPinned
        restorationState = state.interactionState
    }

    /// A tab for a `window.open` popup. WebKit requires the popup's web view to
    /// use the configuration it hands us, so the web view is created right away.
    init(popupConfiguration: WKWebViewConfiguration, opener: Tab) {
        id = UUID()
        profile = opener.profile
        isPrivate = opener.isPrivate
        dataStore = opener.dataStore
        title = ""
        isAgentControlled = opener.isAgentControlled
        pendingPopupConfiguration = popupConfiguration
        ensureWebView()
    }

    var isHibernated: Bool { webView == nil }

    var sessionState: TabSessionState {
        TabSessionState(
            id: id, url: url, title: title, isPinned: isPinned,
            interactionState: webView.flatMap { $0.interactionState as? Data } ?? restorationState)
    }

    /// Returns the web view, creating it (and loading or restoring the page) if needed.
    @discardableResult
    func ensureWebView() -> WKWebView {
        if let webView { return webView }

        let isPopup = pendingPopupConfiguration != nil
        let configuration = pendingPopupConfiguration ?? WebViewFactory.makeConfiguration(for: self)
        pendingPopupConfiguration = nil

        let webView = WebViewFactory.makeWebView(for: self, configuration: configuration)
        let delegate = TabWebViewDelegate(tab: self)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        self.delegate = delegate
        self.webView = webView
        observe(webView)
        webContentProcessCrashed = false

        for tabExtension in AppServices.shared.tabExtensions {
            tabExtension.didCreate(webView, for: self)
        }

        // WebKit loads a popup's first page itself.
        guard !isPopup else { return webView }
        if let restorationState {
            webView.interactionState = restorationState
            self.restorationState = nil
        } else if let url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func load(_ url: URL) {
        if let webView {
            webView.load(URLRequest(url: url))
        } else {
            self.url = url
            restorationState = nil
            ensureWebView()
        }
    }

    func goBack() { ensureWebView().goBack() }
    func goForward() { ensureWebView().goForward() }
    func stopLoading() { webView?.stopLoading() }

    func reload(fromOrigin: Bool = false) {
        let webView = ensureWebView()
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
    }

    /// Frees the web view if the tab is idle: not loading, not using the camera
    /// or microphone, and not playing media. Returns whether it hibernated.
    @discardableResult
    func hibernate() async -> Bool {
        guard let webView, !isLoading,
              webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none
        else { return false }
        guard await webView.requestMediaPlaybackState() != .playing else { return false }

        do {
            hibernationSnapshot = try await webView.takeSnapshot(configuration: nil)
        } catch {
            // The snapshot is cosmetic; without it the sidebar shows the favicon instead.
            hibernationSnapshot = nil
        }
        // The tab may have been selected or closed while we awaited.
        guard self.webView === webView else { return false }
        restorationState = webView.interactionState as? Data
        tearDownWebView()
        return true
    }

    /// Called by the window model when the tab is closed for good.
    func close() {
        for tabExtension in AppServices.shared.tabExtensions {
            tabExtension.willClose(self)
        }
        tearDownWebView()
    }

    // MARK: - Updates from TabWebViewDelegate

    func navigationStarted() {
        webContentProcessCrashed = false
        blockedRequestCount = 0
        blockedHosts = []
        loadError = nil
    }

    func navigationFailed(_ error: PageLoadError) {
        loadError = error
    }

    func webContentProcessDidTerminate() {
        webContentProcessCrashed = true
        isLoading = false
    }

    // MARK: - Private

    private func observe(_ webView: WKWebView) {
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] _, change in
                guard let newURL = change.newValue ?? nil else { return }
                MainActor.assumeIsolated { self?.url = newURL }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] _, change in
                let newTitle = (change.newValue ?? nil) ?? ""
                MainActor.assumeIsolated {
                    guard let self, !newTitle.isEmpty else { return }
                    self.title = newTitle
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new, .old]) { [weak self] _, change in
                let loading = change.newValue ?? false
                let finished = change.oldValue == true && !loading
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoading = loading
                    // The page is back, so the picture of it can go.
                    if finished { self.hibernationSnapshot = nil }
                }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] _, change in
                let progress = change.newValue ?? 0
                MainActor.assumeIsolated { self?.estimatedProgress = progress }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated { self?.canGoBack = value }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated { self?.canGoForward = value }
            },
            webView.observe(\.hasOnlySecureContent, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated { self?.hasOnlySecureContent = value }
            },
        ]
    }

    private func tearDownWebView() {
        observations.forEach { $0.invalidate() }
        observations = []
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
        }
        webView = nil
        delegate = nil
        isLoading = false
        estimatedProgress = 0
    }
}

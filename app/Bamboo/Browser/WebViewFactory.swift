import WebKit

@MainActor
enum WebViewFactory {
    /// Safari's application name for the user agent. Without it WKWebView's
    /// user agent has no "Version/… Safari/…" token and many sites serve a
    /// degraded page. Safari's major version matched macOS + 3 until macOS 26,
    /// when both moved to the same number.
    static let safariApplicationName: String = {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let safariMajor = major >= 26 ? major : major + 3
        return "Version/\(safariMajor).0 Safari/605.1.15"
    }()

    static func makeConfiguration(for tab: Tab) -> WKWebViewConfiguration {
        let settings = AppServices.shared.settings
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = tab.dataStore
        configuration.userContentController = WKUserContentController()
        configuration.applicationNameForUserAgent = safariApplicationName
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if settings.developerToolsEnabled {
            // Adds "Inspect Element" to the context menu; there is no public API for it.
            configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        configuration.mediaTypesRequiringUserActionForPlayback = switch settings.autoplayPolicy {
        case .allow: []
        case .blockAudible: .audio
        case .blockAll: .all
        }
        for tabExtension in AppServices.shared.tabExtensions {
            tabExtension.configure(configuration, for: tab)
        }
        return configuration
    }

    static func makeWebView(for tab: Tab, configuration: WKWebViewConfiguration) -> BambooWebView {
        let webView = BambooWebView(frame: .zero, configuration: configuration)
        webView.tab = tab
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = AppServices.shared.settings.developerToolsEnabled
        return webView
    }
}

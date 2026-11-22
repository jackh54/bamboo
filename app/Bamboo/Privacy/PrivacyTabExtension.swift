import Foundation
import WebKit

/// Tracking-parameter stripping, Global Privacy Control and HTTPS upgrades for every tab.
///
/// HTTPS-Only mode first retries an http:// page over HTTPS. If that fails, the tab shows an
/// interstitial; "Continue to Site" allows plain HTTP for that host until Bamboo quits.
@MainActor
final class PrivacyTabExtension: TabExtension {
    /// Links on the interstitial page use this scheme; `decidePolicy` handles them.
    private static let interstitialScheme = "bamboo-https-only"

    private struct Interstitial {
        let url: URL
        let token: String
    }

    private let gpcScript = WKUserScript(
        bundled: "privacy-gpc", injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    /// Hosts the user allowed over plain HTTP this session.
    private var allowedHTTPHosts: Set<String> = []
    /// The http:// URL each tab is retrying over HTTPS.
    private var upgrades: [Tab.ID: URL] = [:]
    private var interstitials: [Tab.ID: Interstitial] = [:]
    /// Tabs about to load their interstitial page, which must not be upgraded again.
    private var loadingInterstitial: Set<Tab.ID> = []

    private var settings: AppSettings { AppServices.shared.settings }

    func configure(_ configuration: WKWebViewConfiguration, for tab: Tab) {
        // WKWebView can't add the Sec-GPC header to every request, so sites only get the
        // JavaScript signal. Like other per-configuration settings it applies to new tabs.
        if settings.globalPrivacyControl {
            configuration.userContentController.addUserScript(gpcScript)
        }
    }

    func decidePolicy(for action: WKNavigationAction, preferences: WKWebpagePreferences, in tab: Tab) async -> NavigationPolicy {
        guard action.targetFrame?.isMainFrame ?? false, let url = action.request.url else { return .allow }
        if url.scheme == Self.interstitialScheme {
            return interstitialAction(url, in: tab)
        }
        if let attempt = upgrades[tab.id], attempt.host() != url.host() {
            // The user went somewhere else before the HTTPS retry finished.
            upgrades[tab.id] = nil
        }
        // The redirect reloads the URL as a browser-started navigation, which loses the referrer
        // and sends SameSite=Strict cookies the original cross-site navigation would not have.
        // WebKit has no public way to rewrite a navigation in place; GET-only limits the effect
        // to requests that shouldn't change state anyway.
        if settings.stripTrackingParameters, isGet(action),
           let stripped = TrackingParameters.strip(url) {
            return .redirect(stripped)
        }
        switch settings.httpsMode {
        case .upgrade:
            // upgradeKnownHostsToHTTPS (set on every configuration) covers HSTS-preloaded hosts;
            // this tries every other http:// page over HTTPS first, falling back when it fails.
            if #available(macOS 15.2, *) {
                preferences.preferredHTTPSNavigationPolicy = .automaticFallbackToHTTP
            }
            return .allow
        case .httpsOnly:
            return httpsOnlyPolicy(for: action, url: url, in: tab)
        }
    }

    private func isGet(_ action: WKNavigationAction) -> Bool {
        (action.request.httpMethod ?? "GET").uppercased() == "GET"
    }

    func didCommitNavigation(in tab: Tab) {
        upgrades[tab.id] = nil
        loadingInterstitial.remove(tab.id)
    }

    func didFailNavigation(in tab: Tab, error: Error) {
        if let original = upgrades.removeValue(forKey: tab.id) {
            showInterstitial(for: original, in: tab)
        }
    }

    func willClose(_ tab: Tab) {
        upgrades[tab.id] = nil
        interstitials[tab.id] = nil
        loadingInterstitial.remove(tab.id)
    }

    // MARK: - HTTPS-Only

    private func httpsOnlyPolicy(for action: WKNavigationAction, url: URL, in tab: Tab) -> NavigationPolicy {
        guard url.scheme == "http", let host = url.host(), !allowedHTTPHosts.contains(host), !Self.isLocal(host)
        else { return .allow }
        if loadingInterstitial.remove(tab.id) != nil, interstitials[tab.id]?.url == url {
            return .allow
        }
        // A server redirect from the HTTPS retry back to http:// (redirects arrive as `.other`
        // while the tab is still loading). Any other navigation means the retry was abandoned.
        if let attempt = upgrades.removeValue(forKey: tab.id), attempt.host() == host,
           action.navigationType == .other, tab.webView?.isLoading == true {
            showInterstitial(for: url, in: tab)
            return .cancel
        }
        // Retrying a form post over HTTPS would turn it into an empty GET; ask first instead.
        guard isGet(action) else {
            showInterstitial(for: url, in: tab)
            return .cancel
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .cancel }
        components.scheme = "https"
        if components.port == 80 {
            components.port = nil
        }
        guard let secureURL = components.url else { return .cancel }
        upgrades[tab.id] = url
        return .redirect(secureURL)
    }

    private func interstitialAction(_ url: URL, in tab: Tab) -> NavigationPolicy {
        guard let interstitial = interstitials[tab.id],
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "token" })?.value == interstitial.token
        else { return .cancel }
        switch url.host() {
        case "continue":
            interstitials[tab.id] = nil
            if let host = interstitial.url.host() {
                allowedHTTPHosts.insert(host)
            }
            return .redirect(interstitial.url)
        case "back":
            tab.goBack()
            return .cancel
        default:
            return .cancel
        }
    }

    private func showInterstitial(for url: URL, in tab: Tab) {
        guard let webView = tab.webView else { return }
        let interstitial = Interstitial(url: url, token: UUID().uuidString)
        interstitials[tab.id] = interstitial
        loadingInterstitial.insert(tab.id)
        webView.loadSimulatedRequest(
            URLRequest(url: url), responseHTML: Self.interstitialHTML(interstitial, canGoBack: tab.canGoBack))
    }

    /// Local names and IP addresses rarely have certificates; HTTPS-Only leaves them alone.
    static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func interstitialHTML(_ interstitial: Interstitial, canGoBack: Bool) -> String {
        let host = escapeHTML(interstitial.url.host() ?? interstitial.url.absoluteString)
        let link = { (action: String) in "\(interstitialScheme)://\(action)?token=\(interstitial.token)" }
        let back = canGoBack ? #"<a class="button" href="\#(link("back"))">Go Back</a>"# : ""
        return """
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="color-scheme" content="light dark">
            <title>Not secure: \(host)</title>
            <style>
              :root { --accent: #2FA36B; --text: #1d1d1f; --muted: #6e6e73; --surface: #f5f5f7; }
              @media (prefers-color-scheme: dark) { :root { --text: #f5f5f7; --muted: #a1a1a6; --surface: #2c2c2e; } }
              body { font: 15px/1.5 -apple-system, system-ui; color: var(--text); margin: 0;
                     min-height: 100vh; display: grid; place-items: center; }
              main { max-width: 34rem; padding: 2rem; }
              h1 { font-size: 1.6rem; line-height: 1.25; margin: 0 0 .75rem; }
              p { color: var(--muted); margin: 0 0 1.5rem; }
              .actions { display: flex; gap: .75rem; flex-wrap: wrap; }
              .button { padding: .5rem 1.1rem; border-radius: 8px; text-decoration: none;
                        background: var(--surface); color: var(--text); }
              .button.primary { background: var(--accent); color: white; }
            </style>
            </head>
            <body>
            <main>
              <h1>\(host) doesn't offer a secure connection</h1>
              <p>Bamboo tried HTTPS and it didn't work. Over plain HTTP, anyone on your network can see and change \
            what you send and receive on this site, including passwords.</p>
              <div class="actions">
                \(back)
                <a class="button primary" href="\(link("continue"))">Continue to Site</a>
              </div>
            </main>
            </body>
            </html>
            """
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

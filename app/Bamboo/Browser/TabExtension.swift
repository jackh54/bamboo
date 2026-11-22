import WebKit

enum NavigationPolicy: Equatable {
    case allow
    case cancel
    case redirect(URL)
}

/// A feature that hooks into every tab's web view (shields, history, password
/// autofill, agent tools, ...). Extensions are registered once in
/// `AppServices.start()` and called in registration order; every method has a
/// no-op default.
///
/// Script message handlers added in `configure` must find their tab through
/// `AppServices.shared.windows.tab(for: message.webView)` rather than capturing
/// `tab`: popups opened with `window.open` reuse their opener's configuration,
/// so one user content controller can serve several tabs.
@MainActor
protocol TabExtension: AnyObject {
    /// Called once for each new configuration, before its web view exists.
    /// Not called for popups, which inherit their opener's configuration.
    func configure(_ configuration: WKWebViewConfiguration, for tab: Tab)
    /// Called once the web view exists, before its first load.
    func didCreate(_ webView: WKWebView, for tab: Tab)
    /// The first extension returning something other than `.allow` decides.
    /// Extensions may adjust `preferences` (per-site JavaScript, lockdown mode).
    func decidePolicy(for action: WKNavigationAction, preferences: WKWebpagePreferences, in tab: Tab) async -> NavigationPolicy
    func didStartNavigation(in tab: Tab)
    func didCommitNavigation(in tab: Tab)
    func didFinishNavigation(in tab: Tab)
    func didFailNavigation(in tab: Tab, error: Error)
    /// Camera and microphone requests. The first non-nil answer wins; with no
    /// answer WebKit asks the user.
    func mediaCapturePermission(for origin: WKSecurityOrigin, type: WKMediaCaptureType, in tab: Tab) async -> WKPermissionDecision?
    func willClose(_ tab: Tab)
}

extension TabExtension {
    func configure(_ configuration: WKWebViewConfiguration, for tab: Tab) {}
    func didCreate(_ webView: WKWebView, for tab: Tab) {}
    func decidePolicy(for action: WKNavigationAction, preferences: WKWebpagePreferences, in tab: Tab) async -> NavigationPolicy { .allow }
    func didStartNavigation(in tab: Tab) {}
    func didCommitNavigation(in tab: Tab) {}
    func didFinishNavigation(in tab: Tab) {}
    func didFailNavigation(in tab: Tab, error: Error) {}
    func mediaCapturePermission(for origin: WKSecurityOrigin, type: WKMediaCaptureType, in tab: Tab) async -> WKPermissionDecision? { nil }
    func willClose(_ tab: Tab) {}
}

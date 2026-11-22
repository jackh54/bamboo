import WebKit

/// The web view used by every tab. A subclass so the browser can customise the
/// context menu and other AppKit behaviour.
final class BambooWebView: WKWebView {
    weak var tab: Tab?
}

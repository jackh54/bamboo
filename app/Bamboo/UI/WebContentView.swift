import AppKit
import SwiftUI
import WebKit

/// Hosts the selected tab's web view. A web view can only have one superview,
/// so the container swaps it in when the selected tab changes.
struct WebContentView: NSViewRepresentable {
    let tab: Tab
    /// Matches the page card's corners; zero when the page fills the window.
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> WebContainerView {
        WebContainerView()
    }

    func updateNSView(_ container: WebContainerView, context: Context) {
        container.layer?.cornerRadius = cornerRadius
        container.show(tab.webView)
    }
}

final class WebContainerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        // SwiftUI's clip shape doesn't reach into AppKit views, so the card's
        // rounded corners are applied to the layer as well.
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WebContainerView is created in code")
    }

    func show(_ webView: WKWebView?) {
        guard let webView else {
            subviews.forEach { $0.removeFromSuperview() }
            return
        }
        guard webView.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}

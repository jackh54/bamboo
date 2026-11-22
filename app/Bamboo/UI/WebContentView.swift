import AppKit
import SwiftUI
import WebKit

/// Hosts the selected tab's web view. A web view can only have one superview,
/// so the container swaps it in when the selected tab changes.
struct WebContentView: NSViewRepresentable {
    let tab: Tab

    func makeNSView(context: Context) -> WebContainerView {
        WebContainerView()
    }

    func updateNSView(_ container: WebContainerView, context: Context) {
        container.show(tab.webView)
    }
}

final class WebContainerView: NSView {
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
